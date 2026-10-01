import PDFKit
import SwiftUI

/// Sayfa küçük resimleriyle seçme, bölme, döndürme ve sıralama.
struct PagesWorkspace: View {
    let files: [InputFile]
    let mode: PageMode
    @Binding var values: OptionValues

    struct Item: Identifiable, Hashable {
        let id = UUID()
        var file: Int
        var page: Int
        var rotate = 0
        var blank = false
    }

    @State private var items: [Item] = []
    @State private var documents: [Int: PDFDocument] = [:]
    @State private var selected: Set<UUID> = []
    @State private var dragging: Item?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    cell(item)
                }
            }
            .animation(.snappy, value: items)
        }
        .padding(.vertical, 6)
        .task(id: files.map(\.id)) { await load() }
    }

    // MARK: Görünüm

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            switch mode {
            case .select, .split:
                Text(selected.isEmpty ? "Sayfalara dokunarak seç" : "\(selected.count) sayfa seçili")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(selected.count == items.count ? "Hiçbiri" : "Tümü") {
                    selected = selected.count == items.count ? [] : Set(items.map(\.id))
                    sync()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .rotate:
                Text("Döndürmek için sayfaya dokun").font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    for index in items.indices { items[index].rotate = (items[index].rotate + 90) % 360 }
                    sync()
                } label: {
                    Label("Tümü", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .organize:
                Text("Sürükleyerek sırala, basılı tutarak düzenle").font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    items.append(Item(file: -1, page: 0, blank: true))
                    sync()
                } label: {
                    Label("Boş sayfa", systemImage: "plus.square.dashed")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        let isSelected = selected.contains(item.id)
        let number = (items.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                PageThumbnail(document: item.blank ? nil : documents[item.file], page: item.page, extraRotation: item.rotate)
                    .frame(height: 124)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 3 : 1))
                    .opacity(dragging?.id == item.id ? 0.4 : 1)
                if isSelected {
                    Image(systemName: mode == .select ? "checkmark.circle.fill" : "scissors.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
                if item.rotate != 0 {
                    Text("\(item.rotate)°")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            Text(item.blank ? "Boş" : files.count > 1 && mode == .organize ? "\(item.file + 1)·\(item.page + 1)" : "\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(item) }
        .sensoryFeedback(.selection, trigger: isSelected)
        .contextMenu {
            if mode == .organize || mode == .rotate {
                Button { rotate(item, by: 90) } label: { Label("Sağa döndür", systemImage: "rotate.right") }
                Button { rotate(item, by: 270) } label: { Label("Sola döndür", systemImage: "rotate.left") }
            }
            if mode == .organize {
                Button { duplicate(item) } label: { Label("Kopyala", systemImage: "plus.square.on.square") }
                Button { insertBlank(after: item) } label: { Label("Arkasına boş sayfa", systemImage: "plus.square.dashed") }
                Button(role: .destructive) { remove(item) } label: { Label("Sil", systemImage: "trash") }
            }
        }
        .draggable(item.id.uuidString) {
            PageThumbnail(document: documents[item.file], page: item.page, extraRotation: item.rotate)
                .frame(width: 80, height: 104)
                .onAppear { dragging = item }
        }
        .dropDestination(for: String.self) { _, _ in
            dragging = nil
            return true
        } isTargeted: { targeted in
            guard targeted, mode == .organize, let dragging, dragging.id != item.id,
                  let from = items.firstIndex(where: { $0.id == dragging.id }), let to = items.firstIndex(where: { $0.id == item.id }) else { return }
            withAnimation(.snappy) {
                items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
            sync()
        }
    }

    // MARK: Eylemler

    private func tap(_ item: Item) {
        switch mode {
        case .select, .split:
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        case .rotate:
            rotate(item, by: 90)
            return
        case .organize:
            return
        }
        sync()
    }

    private func rotate(_ item: Item, by angle: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].rotate = (items[index].rotate + angle) % 360
        sync()
    }

    private func duplicate(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.insert(Item(file: item.file, page: item.page, rotate: item.rotate, blank: item.blank), at: index + 1)
        sync()
    }

    private func insertBlank(after item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.insert(Item(file: -1, page: 0, blank: true), at: index + 1)
        sync()
    }

    private func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        sync()
    }

    /// Görsel seçimleri aracın seçeneklerine yazar (masaüstüyle aynı anahtarlar).
    private func sync() {
        switch mode {
        case .select:
            let pages = items.enumerated().filter { selected.contains($0.element.id) }.map(\.offset)
            values["pages"] = .string(PageRanges.human(pages))
        case .split:
            let pages = items.enumerated().filter { selected.contains($0.element.id) }.map(\.offset).sorted()
            var groups: [[Int]] = []
            for page in pages {
                if let last = groups.last?.last, last == page - 1 { groups[groups.count - 1].append(page) } else { groups.append([page]) }
            }
            values["mode"] = .string("ranges")
            values["ranges"] = .string(groups.map { PageRanges.human($0) }.joined(separator: ", "))
        case .rotate:
            var perPage: [String: Int] = [:]
            for (index, item) in items.enumerated() where item.rotate != 0 { perPage[String(index)] = item.rotate }
            values["per_page"] = .string(perPage.isEmpty ? "" : String(data: (try? JSONEncoder().encode(perPage)) ?? Data(), encoding: .utf8) ?? "")
        case .organize:
            let sequence = items.map { item -> PageTools.SequenceItem in
                if item.blank {
                    return PageTools.SequenceItem(blank: true, w: 595, h: 842)
                }
                return PageTools.SequenceItem(file: item.file, page: item.page, rotate: item.rotate)
            }
            values["sequence"] = .string(String(data: (try? JSONEncoder().encode(sequence)) ?? Data(), encoding: .utf8) ?? "")
        }
    }

    private func load() async {
        var loaded: [Int: PDFDocument] = [:]
        var list: [Item] = []
        for (index, file) in files.enumerated() {
            let document: PDFDocument?
            switch file.kind {
            case .pdf:
                let pdf = PDFDocument(url: file.url)
                if let pdf, pdf.isLocked, let password = file.password { _ = pdf.unlock(withPassword: password) }
                document = pdf
            case .image:
                document = (try? ImageConverter.pdf(from: [file.url], options: OptionValues())).flatMap { PDFDocument(data: $0) }
            default:
                document = nil
            }
            loaded[index] = document
            list += (0..<(document?.pageCount ?? 0)).map { Item(file: index, page: $0) }
        }
        documents = loaded
        items = list
        selected = []
        if mode == .organize || mode == .rotate { sync() }
    }
}

struct PageThumbnail: View {
    let document: PDFDocument?
    let page: Int
    var extraRotation = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .rotationEffect(.degrees(Double(extraRotation)))
                    .animation(.snappy, value: extraRotation)
            } else if document == nil {
                Image(systemName: "doc")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .task(id: page) {
            guard let document, let pdfPage = document.page(at: page) else { return }
            image = pdfPage.thumbnail(of: CGSize(width: 220, height: 280), for: .cropBox)
        }
    }
}
