import PDFKit
import SwiftUI

/// Sayfa küçük resimleriyle seçme, bölme, döndürme ve sıralama (masaüstündeki sayfa çalışma alanıyla aynı işlevler).
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
    @State private var original: [Item] = []
    @State private var documents: [Int: PDFDocument] = [:]
    @State private var selected: Set<UUID> = []
    @State private var cuts: Set<Int> = []
    @State private var dragging: Item?

    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .brown]
    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 12)]

    var body: some View {
        let groups = splitGroups()
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cell(item, index: index, group: groups?[index], dimmed: groups != nil && groups?[index] == nil)
                }
            }
            .animation(.snappy, value: items)
        }
        .padding(.vertical, 6)
        .task(id: files.map(\.id)) { await load() }
        .onChange(of: values.string("pages")) { _, spec in adoptSelection(spec) }
    }

    // MARK: Görünüm

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            switch mode {
            case .select:
                Text(selected.isEmpty ? "Sayfalara dokunarak seç" : "\(selected.count) / \(items.count) sayfa seçili")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Button { select { _ in true } } label: { Label("Tümünü seç", systemImage: "checkmark.circle") }
                    Button { select { $0 % 2 == 0 } } label: { Label("Tek sayfalar", systemImage: "1.circle") }
                    Button { select { $0 % 2 == 1 } } label: { Label("Çift sayfalar", systemImage: "2.circle") }
                    Button {
                        let current = selected
                        select { !current.contains(items[$0].id) }
                    } label: { Label("Seçimi ters çevir", systemImage: "arrow.left.arrow.right") }
                    Button(role: .destructive) { select { _ in false } } label: { Label("Temizle", systemImage: "xmark.circle") }
                } label: {
                    Label("Seç", systemImage: "checklist")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .split:
                Text(cuts.isEmpty ? "Yeni parçanın başlayacağı sayfaya dokun" : "\(cuts.count + 1) parça")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if !cuts.isEmpty {
                    Button("Temizle") {
                        cuts = []
                        values["ranges"] = .string("")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .rotate:
                Text("Döndürmek için sayfaya dokun").font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Button { rotateAll(by: 90) } label: { Label("Tümünü sağa", systemImage: "rotate.right") }
                    Button { rotateAll(by: 270) } label: { Label("Tümünü sola", systemImage: "rotate.left") }
                    Button(role: .destructive) {
                        for index in items.indices { items[index].rotate = 0 }
                        sync()
                    } label: { Label("Sıfırla", systemImage: "arrow.counterclockwise") }
                } label: {
                    Label("Tümü", systemImage: "rotate.right")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .organize:
                Text("Sürükleyerek sırala, basılı tutarak düzenle").font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Button {
                        items.append(Item(file: -1, page: 0, blank: true))
                        sync()
                    } label: { Label("Sona boş sayfa", systemImage: "plus.square.dashed") }
                    Button {
                        items.reverse()
                        sync()
                    } label: { Label("Ters çevir", systemImage: "arrow.up.arrow.down") }
                    Button(role: .destructive) {
                        items = original
                        sync()
                    } label: { Label("Sıfırla", systemImage: "arrow.counterclockwise") }
                } label: {
                    Label("Düzenle", systemImage: "square.grid.2x2")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func cell(_ item: Item, index: Int, group: Int?, dimmed: Bool) -> some View {
        let isSelected = mode == .select && selected.contains(item.id)
        let isCut = mode == .split && cuts.contains(index)
        let tint = group.map { Self.palette[$0 % Self.palette.count] }
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                PageThumbnail(document: item.blank ? nil : documents[item.file], page: item.page, extraRotation: item.rotate)
                    .frame(height: 124)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(tint ?? Color.primary.opacity(0.1)),
                                      lineWidth: isSelected ? 3 : tint == nil ? 1 : 2))
                    .opacity(dragging?.id == item.id ? 0.4 : dimmed ? 0.35 : 1)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, TintShapeStyle())
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
                if isCut {
                    Image(systemName: "scissors.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(TintShapeStyle()))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            HStack(spacing: 5) {
                if mode == .organize, files.count > 1, !item.blank {
                    Circle().fill(Self.palette[item.file % Self.palette.count]).frame(width: 7, height: 7)
                }
                Text(item.blank ? "Boş" : mode == .organize ? "\(index + 1)" : "\(item.page + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let group, let tint {
                    Text("Parça \(group + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(item) }
        .sensoryFeedback(.selection, trigger: isSelected || isCut)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.blank ? "Boş sayfa" : "Sayfa \(item.page + 1)")
        .accessibilityAddTraits(isSelected || isCut ? .isSelected : [])
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

    /// Bölme önizlemesi: her sayfanın düşeceği parça (seçilen bölme şekline göre); dahil olmayan sayfalar soluk.
    private func splitGroups() -> [Int: Int]? {
        guard mode == .split, !items.isEmpty else { return nil }
        let count = items.count
        var map: [Int: Int] = [:]
        switch values.string("mode", "ranges") {
        case "ranges":
            let spec = values.string("ranges")
            guard !spec.trimmingCharacters(in: .whitespaces).isEmpty,
                  let groups = try? PageRanges.groups(spec, count: count) else { return nil }
            for (number, group) in groups.enumerated() {
                for page in group where map[page] == nil { map[page] = number }
            }
        case "every":
            let every = max(1, values.int("every", 2))
            for page in 0..<count { map[page] = page / every }
        case "all":
            for page in 0..<count { map[page] = page }
        default:
            return nil
        }
        return map
    }

    // MARK: Eylemler

    private func tap(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        switch mode {
        case .select:
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
            sync()
        case .split:
            guard index > 0 else { return }
            if cuts.contains(index) { cuts.remove(index) } else { cuts.insert(index) }
            sync()
        case .rotate:
            rotate(item, by: 90)
        case .organize:
            break
        }
    }

    private func select(_ include: (Int) -> Bool) {
        selected = Set(items.indices.filter(include).map { items[$0].id })
        sync()
    }

    /// Kullanıcı "Sayfalar" alanına elle yazdığında seçimi günceller.
    private func adoptSelection(_ spec: String) {
        guard mode == .select, !items.isEmpty else { return }
        let current = items.indices.filter { selected.contains(items[$0].id) }
        guard PageRanges.human(current) != spec else { return }
        if spec.trimmingCharacters(in: .whitespaces).isEmpty {
            selected = []
            return
        }
        guard let pages = try? PageRanges.pages(spec, count: items.count) else { return }
        selected = Set(pages.map { items[$0].id })
    }

    private func rotate(_ item: Item, by angle: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].rotate = (items[index].rotate + angle) % 360
        sync()
    }

    private func rotateAll(by angle: Int) {
        for index in items.indices { items[index].rotate = (items[index].rotate + angle) % 360 }
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
            let pages = items.indices.filter { selected.contains(items[$0].id) }
            values["pages"] = .string(PageRanges.human(pages))
        case .split:
            let starts = [0] + cuts.sorted()
            let ranges = starts.enumerated().map { number, start -> String in
                let end = (number + 1 < starts.count ? starts[number + 1] : items.count) - 1
                return start == end ? "\(start + 1)" : "\(start + 1)-\(end + 1)"
            }
            values["mode"] = .string("ranges")
            values["ranges"] = .string(ranges.joined(separator: ", "))
        case .rotate:
            var perPage: [String: Int] = [:]
            for (index, item) in items.enumerated() where item.rotate != 0 { perPage[String(index)] = item.rotate }
            values["per_page"] = .string(perPage.isEmpty ? "" : String(data: (try? JSONEncoder().encode(perPage)) ?? Data(), encoding: .utf8) ?? "")
        case .organize:
            // Boş sayfa, kendinden önceki sayfanın boyutunu alır (masaüstündeki gibi).
            var size = CGSize(width: 595, height: 842)
            let sequence = items.map { item -> PageTools.SequenceItem in
                if item.blank {
                    return PageTools.SequenceItem(blank: true, w: Double(size.width), h: Double(size.height))
                }
                if let bounds = documents[item.file]?.page(at: item.page)?.bounds(for: .cropBox) { size = bounds.size }
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
        original = list
        selected = []
        cuts = []
        if mode == .organize || mode == .rotate { sync() }
        if mode == .select { adoptSelection(values.string("pages")) }
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
