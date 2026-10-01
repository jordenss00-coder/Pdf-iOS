import QuickLook
import SwiftUI
import UIKit

struct ResultView: View {
    let box: ResultBox
    @EnvironmentObject private var model: AppModel
    @State private var preview: URL?
    @State private var exporting = false
    @State private var zipURL: URL?
    @State private var choosingTool = false
    @State private var appeared = false
    @State private var copied = false

    private var files: [URL] { box.result.files }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                ForEach(box.result.warnings, id: \.self) { Banner(kind: .warning, text: $0) }
                ForEach(box.result.notes, id: \.self) { Banner(kind: .info, text: $0) }
                if let text = box.result.text { textCard(text) }
                VStack(spacing: 10) {
                    ForEach(files, id: \.self) { url in
                        Button { preview = url } label: { fileCard(url) }
                            .buttonStyle(PressableStyle())
                    }
                }
                actions
                Text("Sonuçlar ayrıca Dosyalar › iPhone'umda › PDF Atölye klasörüne kaydedildi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(18)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sonuç")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview, in: files)
        .sheet(isPresented: $exporting) {
            DocumentExporter(urls: files).ignoresSafeArea()
        }
        .sheet(isPresented: $choosingTool) {
            ToolChooser(title: "Sonuçla devam et", kinds: files.compactMap(FileKind.detect)) { tool in
                choosingTool = false
                let inputs = files.compactMap { try? InputFile.importing($0) }
                model.open(tool, with: inputs)
            }
            .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear { appeared = true }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(box.tool.categoryInfo.gradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: (box.tool.categoryInfo.colors.first ?? .blue).opacity(0.4), radius: 16, y: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            Text("Hazır!")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var summary: String {
        let total = files.reduce(Int64(0)) { $0 + $1.fileSize }
        let count = files.count == 1 ? "1 dosya" : "\(files.count) dosya"
        return "\(box.tool.name) · \(count) · \(total.fileSize)"
    }

    private func textCard(_ text: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Kopyalandı" : "Metni kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .sensoryFeedback(.success, trigger: copied)
            }
        }
    }

    private func fileCard(_ url: URL) -> some View {
        HStack(spacing: 14) {
            FileThumbnail(url: url, size: CGSize(width: 52, height: 64))
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(url.fileSize.fileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            ShareLink(items: files) {
                actionLabel(files.count > 1 ? "Tümünü paylaş" : "Paylaş", "square.and.arrow.up", primary: true)
            }
            .buttonStyle(PressableStyle())
            HStack(spacing: 10) {
                Button { exporting = true } label: {
                    actionLabel("Dosyalar'a kaydet", "folder.badge.plus", primary: false)
                }
                .buttonStyle(PressableStyle())
                if files.count > 1 {
                    if let zipURL {
                        ShareLink(item: zipURL) { actionLabel("ZIP paylaş", "doc.zipper", primary: false) }
                            .buttonStyle(PressableStyle())
                    } else {
                        Button(action: makeZip) { actionLabel("ZIP yap", "doc.zipper", primary: false) }
                            .buttonStyle(PressableStyle())
                    }
                }
            }
            if !Catalog.tools(for: files.compactMap(FileKind.detect)).isEmpty {
                Button { choosingTool = true } label: {
                    actionLabel("Başka araçla devam et", "arrow.triangle.turn.up.right.diamond", primary: false)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func actionLabel(_ title: String, _ symbol: String, primary: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(box.tool.categoryInfo.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                }
            }
    }

    private func makeZip() {
        let name = "\(stem(files.first?.lastPathComponent ?? "sonuc"))_ve_digerleri.zip"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        if (try? Zip.archive(files, to: url)) != nil {
            zipURL = url
        }
    }
}

/// Dosya türlerine uygun araçların listesi.
struct ToolChooser: View {
    let title: String
    let kinds: [FileKind]
    let choose: (Tool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Catalog.categories) { category in
                    let tools = Catalog.tools(for: kinds).filter { $0.category == category.id && Engine.available.contains($0.id) }
                    if !tools.isEmpty {
                        Section(category.name) {
                            ForEach(tools) { tool in
                                Button { choose(tool) } label: {
                                    HStack(spacing: 12) {
                                        GradientIcon(symbol: tool.symbol, colors: category.colors, size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tool.name).foregroundStyle(.primary)
                                            Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}

struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
