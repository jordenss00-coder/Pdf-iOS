import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct ResultBox: Identifiable, Hashable {
    let id = UUID()
    let tool: Tool
    let result: ToolResult

    static func == (lhs: ResultBox, rhs: ResultBox) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ToolView: View {
    let tool: Tool
    @EnvironmentObject private var model: AppModel
    @State private var files: [InputFile]
    @State private var values: OptionValues
    @State private var running = false
    @State private var progress = 0.0
    @State private var progressText: String?
    @State private var errorText: String?
    @State private var result: ResultBox?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var scanning = false
    @State private var locked: [InputFile] = []
    @State private var password = ""

    init(tool: Tool, inputs: [InputFile] = []) {
        self.tool = tool
        _files = State(initialValue: inputs)
        _values = State(initialValue: OptionValues(defaultsOf: tool.options))
    }

    var body: some View {
        Form {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if acceptsFiles {
                Section {
                    if files.isEmpty {
                        dropZone
                    } else {
                        ForEach(files) { file in
                            FileRow(file: file)
                        }
                        .onDelete { files.remove(atOffsets: $0) }
                        .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                        addButtons
                    }
                } header: {
                    Text(files.count > 1 ? "Dosyalar (\(files.count))" : "Dosya")
                } footer: {
                    if tool.sortable && files.count > 1 {
                        Text("Sırayı değiştirmek için dosyayı basılı tutup sürükle.")
                    }
                }
            }

            if case .pages(let mode) = tool.workspace, !files.isEmpty {
                Section {
                    PagesWorkspace(files: files, mode: mode, values: $values)
                } header: {
                    Text("Sayfalar")
                }
            }

            if !visibleOptions.isEmpty {
                Section("Seçenekler") {
                    ForEach(visibleOptions) { option in
                        OptionRow(option: option, values: $values)
                    }
                }
            }

            if !Engine.available.contains(tool.id) {
                Section {
                    Label("Bu araç bir sonraki güncellemede geliyor.", systemImage: "hammer.fill")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Section {
                    Banner(kind: .error, text: errorText)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .safeAreaInset(edge: .bottom) { runBar }
        .navigationTitle(tool.name)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: contentTypes,
                      allowsMultipleSelection: tool.multi || tool.minFiles > 1) { outcome in
            if case .success(let urls) = outcome { add(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentCamera { images in
                scanning = false
                addScans(images)
            }
            .ignoresSafeArea()
        }
        .navigationDestination(item: $result) { box in
            ResultView(box: box)
        }
        .alert("Parola gerekli", isPresented: Binding(get: { !locked.isEmpty }, set: { if !$0 { locked = [] } })) {
            SecureField("Parola", text: $password)
            Button("Aç") { unlockNext() }
            Button("Vazgeç", role: .cancel) {
                files.removeAll { file in locked.contains { $0.id == file.id } }
                locked = []
                password = ""
            }
        } message: {
            Text("'\(locked.first?.name ?? "")' parola korumalı.")
        }
        .sensoryFeedback(.error, trigger: errorText)
    }

    // MARK: Görünüm parçaları

    private var header: some View {
        HStack(spacing: 14) {
            GradientIcon(symbol: tool.symbol, colors: tool.categoryInfo.colors, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.categoryInfo.name.uppercased(with: Locale(identifier: "tr_TR")))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tool.categoryInfo.colors.first ?? .secondary)
                Text(tool.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: tool.workspace.isScan ? "doc.viewfinder" : "plus.rectangle.on.folder")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(tool.categoryInfo.gradient)
                .symbolEffect(.pulse, options: .repeating)
            Text(dropTitle)
                .font(.headline)
            Text("Kabul edilen: \(tool.accepts.map(\.label).joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
            addButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var dropTitle: String {
        if tool.workspace.isScan { return "Belgeni tara ya da fotoğraf seç" }
        return tool.multi || tool.minFiles > 1 ? "Dosyaları ekle" : "Bir dosya seç"
    }

    @ViewBuilder
    private var addButtons: some View {
        let images = tool.accepts.contains(.image)
        HStack(spacing: 10) {
            if images && VNDocumentCameraViewController.isSupported {
                sourceButton("Tara", "camera.fill") { scanning = true }
            }
            if images {
                PhotosPicker(selection: $photoItems, maxSelectionCount: tool.multi ? 50 : 1, matching: .images) {
                    sourceLabel("Fotoğraflar", "photo.on.rectangle")
                }
                .buttonStyle(PressableStyle())
            }
            if !(tool.workspace.isScan) || !images {
                sourceButton("Dosyalar", "folder.fill") { importing = true }
            }
        }
    }

    private func sourceButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { sourceLabel(title, symbol) }
            .buttonStyle(PressableStyle())
    }

    private func sourceLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tool.categoryInfo.colors.first ?? .accentColor)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill((tool.categoryInfo.colors.first ?? .blue).opacity(0.12)))
    }

    private var runBar: some View {
        VStack(spacing: 8) {
            if running {
                ProgressView(value: progress) {
                    Text(progressText ?? "Çalışıyor…").font(.caption).foregroundStyle(.secondary)
                }
                .tint(tool.categoryInfo.colors.first)
            }
            Button(action: run) {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(running ? "Hazırlanıyor…" : tool.action)
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tool.categoryInfo.gradient))
                .opacity(canRun ? 1 : 0.45)
            }
            .buttonStyle(PressableStyle())
            .disabled(!canRun || running)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: Durum

    private var acceptsFiles: Bool { !tool.accepts.isEmpty }

    private var visibleOptions: [ToolOption] {
        tool.options.filter { $0.visible(values) }
    }

    private var canRun: Bool {
        Engine.available.contains(tool.id) && (files.count >= tool.minFiles || tool.minFiles == 0)
    }

    private var contentTypes: [UTType] {
        tool.accepts.flatMap(\.contentTypes)
    }

    // MARK: Eylemler

    private func add(_ urls: [URL]) {
        var added: [InputFile] = []
        for url in urls {
            do {
                added.append(try InputFile.importing(url))
            } catch {
                errorText = error.localizedDescription
            }
        }
        accept(added)
    }

    private func accept(_ added: [InputFile]) {
        let usable = added.filter { tool.accepts.contains($0.kind) }
        if usable.count < added.count {
            errorText = "Bazı dosyalar bu araç için uygun değil."
        }
        if tool.multi || tool.minFiles > 1 {
            files += usable
        } else if let first = usable.first {
            files = [first]
        }
        if let max = tool.maxFiles, files.count > max {
            files = Array(files.prefix(max))
        }
        locked += usable.filter { $0.kind == .pdf && (PDFDocument(url: $0.url)?.isLocked ?? false) && !tool.allowsLocked }
        if tool.id == "metadata", let first = files.first {
            for (key, value) in DocumentTools.currentMetadata(first.url, password: first.password).values {
                values[key] = value
            }
        }
    }

    private func unlockNext() {
        guard let file = locked.first else { return }
        if let document = PDFDocument(url: file.url), document.unlock(withPassword: password),
           let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index].password = password
        } else {
            errorText = "'\(file.name)' için parola yanlış."
            files.removeAll { $0.id == file.id }
        }
        password = ""
        locked.removeFirst()
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var added: [InputFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            if let file = try? InputFile.saving(data, name: "Fotoğraf \(index + 1).\(ext)", kind: .image) {
                added.append(file)
            }
        }
        photoItems = []
        accept(added)
    }

    private func addScans(_ images: [UIImage]) {
        var added: [InputFile] = []
        for (index, image) in images.enumerated() {
            if let data = image.jpegData(compressionQuality: 0.9),
               let file = try? InputFile.saving(data, name: "Tarama \(index + 1).jpg", kind: .image) {
                added.append(file)
            }
        }
        accept(added)
    }

    private func run() {
        errorText = nil
        running = true
        progress = 0
        progressText = nil
        let tool = self.tool, inputs = files, options = values
        Task { @MainActor in
            do {
                let output = try await Engine.run(tool: tool, inputs: inputs, options: options) { fraction, message in
                    Task { @MainActor in
                        progress = fraction
                        if let message { progressText = message }
                    }
                }
                let kept = model.keep(output.files)
                result = ResultBox(tool: tool, result: ToolResult(files: kept, warnings: output.warnings, notes: output.notes, text: output.text))
            } catch {
                errorText = error.localizedDescription
            }
            running = false
        }
    }
}

extension Workspace {
    var isScan: Bool {
        if case .scan = self { return true }
        return false
    }
}

struct FileRow: View {
    let file: InputFile
    @State private var pages: Int?

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(url: file.url, size: CGSize(width: 40, height: 50))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(file.size.fileSize)
                    if let pages { Text("· \(pages) sayfa") }
                    if file.password != nil { Image(systemName: "lock.open.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task {
            if file.kind == .pdf, let document = PDFDocument(url: file.url) {
                pages = document.pageCount
            }
        }
    }
}

/// Dosyanın küçük önizlemesi (PDF ilk sayfası, görsel ya da tür simgesi).
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(2)
            } else {
                Image(systemName: (FileKind.detect(url) ?? .pdf).symbol)
                    .font(.system(size: min(size.width, size.height) * 0.38))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .task(id: url) {
            image = await Thumbnailer.image(for: url, size: CGSize(width: size.width * 2, height: size.height * 2))
        }
    }
}

enum Thumbnailer {
    static func image(for url: URL, size: CGSize) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            switch FileKind.detect(url) {
            case .pdf:
                return PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: size, for: .cropBox)
            case .image:
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            default:
                return nil
            }
        }.value
    }
}

struct DocumentCamera: UIViewControllerRepresentable {
    let completion: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: ([UIImage]) -> Void
        init(completion: @escaping ([UIImage]) -> Void) { self.completion = completion }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            completion((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion([])
        }
    }
}
