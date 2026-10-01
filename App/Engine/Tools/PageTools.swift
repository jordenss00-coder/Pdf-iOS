import PDFKit
import UIKit

enum PageTools {
    static func merge(_ c: ToolContext) async throws -> [URL] {
        guard c.inputs.count >= 2 else { throw ToolError("Birleştirmek için en az 2 dosya ekle.") }
        let output = PDFDocument()
        let root = PDFOutline()
        var sources: [PDFDocument] = []
        for (k, input) in c.inputs.enumerated() {
            c.progress(Double(k) / Double(c.inputs.count), input.name)
            let source = try await c.pdf(input)
            sources.append(source)
            let start = output.pageCount
            PDFKitIO.copyPages(from: source, Array(0..<source.pageCount), into: output)
            if c.options.bool("bookmarks", true), let first = output.page(at: start) {
                let item = PDFOutline()
                item.label = stem(input.name)
                item.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .cropBox).maxY))
                if let sourceRoot = source.outlineRoot {
                    copyOutline(sourceRoot, into: item, source: source, target: output, offset: start)
                }
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        if root.numberOfChildren > 0 { output.outlineRoot = root }
        let url = c.out("birlestirilmis.pdf")
        try PDFKitIO.write(output, to: url)
        return [url]
    }

    private static func copyOutline(_ node: PDFOutline, into parent: PDFOutline, source: PDFDocument, target: PDFDocument, offset: Int) {
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            if let destination = child.destination, let page = destination.page,
               let mapped = target.page(at: offset + source.index(for: page)) {
                copy.destination = PDFDestination(page: mapped, at: destination.point)
            }
            parent.insertChild(copy, at: parent.numberOfChildren)
            copyOutline(child, into: copy, source: source, target: target, offset: offset)
        }
    }

    static func split(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try await c.pdf(input)
        let n = document.pageCount
        var groups: [[Int]]
        switch c.options.string("mode", "ranges") {
        case "ranges":
            groups = try PageRanges.groups(c.options.string("ranges"), count: n)
        case "every":
            let k = max(1, c.options.int("every", 1))
            groups = stride(from: 0, to: n, by: k).map { Array($0..<min($0 + k, n)) }
        case "all":
            groups = (0..<n).map { [$0] }
        case "selected":
            groups = try PageRanges.pages(c.options.string("pages"), count: n).map { [$0] }
        case "bookmarks":
            guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
                throw ToolError("Bu PDF'te yer imi (içindekiler) yok.")
            }
            var starts = Set<Int>()
            for i in 0..<root.numberOfChildren {
                if let page = root.child(at: i)?.destination?.page {
                    starts.insert(document.index(for: page))
                }
            }
            var sorted = starts.filter { $0 >= 0 && $0 < n }.sorted()
            if sorted.first != 0 { sorted.insert(0, at: 0) }
            groups = sorted.enumerated().map { k, start in
                Array(start..<(k + 1 < sorted.count ? sorted[k + 1] : n))
            }
        case "size":
            let limit = Int(c.options.number("max_mb", 5) * 1024 * 1024)
            groups = []
            var current: [Int] = []
            for i in 0..<n {
                c.progress(Double(i) / Double(n), "Sayfa \(i + 1)")
                let trial = current + [i]
                let size = PDFKitIO.document(from: document, pages: trial).dataRepresentation()?.count ?? 0
                if size > limit && !current.isEmpty {
                    groups.append(current)
                    current = [i]
                } else {
                    current = trial
                }
            }
            if !current.isEmpty { groups.append(current) }
        default:
            throw ToolError("Bilinmeyen bölme türü.")
        }
        groups = groups.filter { !$0.isEmpty }
        let base = stem(input.name)
        if c.options.bool("merge_output") {
            let url = c.out("\(base)_secilen.pdf")
            try PDFKitIO.write(PDFKitIO.document(from: document, pages: Array(groups.joined())), to: url)
            return [url]
        }
        var urls: [URL] = []
        for group in groups {
            let url = c.out("\(base)_\(PageRanges.human(group).replacingOccurrences(of: ",", with: "_")).pdf")
            try PDFKitIO.write(PDFKitIO.document(from: document, pages: group), to: url)
            urls.append(url)
        }
        return urls
    }

    static func removePages(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try await c.pdf(input)
        guard !c.options.string("pages").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("Silinecek sayfaları seç.")
        }
        let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
        guard pages.count < document.pageCount else {
            throw ToolError("Tüm sayfalar silinemez; en az bir sayfa kalmalı.")
        }
        for index in pages.sorted(by: >) {
            document.removePage(at: index)
        }
        let url = c.out("\(stem(input.name))_duzenlenmis.pdf")
        try PDFKitIO.write(document, to: url)
        return [url]
    }

    static func extractPages(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try await c.pdf(input)
        guard !c.options.string("pages").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("Çıkarılacak sayfaları seç.")
        }
        let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
        let base = stem(input.name)
        if c.options.bool("separate") {
            return try pages.map { page in
                let url = c.out("\(base)_sayfa_\(page + 1).pdf")
                try PDFKitIO.write(PDFKitIO.document(from: document, pages: [page]), to: url)
                return url
            }
        }
        let url = c.out("\(base)_\(PageRanges.human(pages).replacingOccurrences(of: ",", with: "_")).pdf")
        try PDFKitIO.write(PDFKitIO.document(from: document, pages: pages), to: url)
        return [url]
    }

    /// Sayfa sırası: [{"file": dosyaSırası, "page": n, "rotate": derece} | {"blank": true, "w": 595, "h": 842}]
    struct SequenceItem: Codable {
        var file: Int?
        var page: Int?
        var rotate: Int?
        var blank: Bool?
        var w: Double?
        var h: Double?
    }

    static func organize(_ c: ToolContext) async throws -> [URL] {
        var documents: [PDFDocument] = []
        for input in c.inputs {
            documents.append(try await c.pdf(input))
        }
        var sequence: [SequenceItem] = []
        if let data = c.options.string("sequence").data(using: .utf8), !data.isEmpty {
            sequence = (try? JSONDecoder().decode([SequenceItem].self, from: data)) ?? []
        }
        if sequence.isEmpty {
            for (file, document) in documents.enumerated() {
                sequence += (0..<document.pageCount).map { SequenceItem(file: file, page: $0) }
            }
        }
        let output = PDFDocument()
        for item in sequence {
            if item.blank == true {
                let size = CGSize(width: item.w ?? 595, height: item.h ?? 842)
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
                if let page = PDFDocument(data: data)?.page(at: 0) {
                    output.insert(page, at: output.pageCount)
                }
                continue
            }
            guard let file = item.file, file >= 0, file < documents.count else {
                throw ToolError("Sıralamada bilinmeyen bir dosya var.")
            }
            guard let index = item.page, let page = documents[file].page(at: index)?.copy() as? PDFPage else { continue }
            if let rotate = item.rotate, rotate % 360 != 0 {
                page.rotation = ((page.rotation + rotate) % 360 + 360) % 360
            }
            output.insert(page, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw ToolError("Sonuçta hiç sayfa kalmadı.") }
        let name = c.inputs.count == 1 ? "\(stem(c.inputs[0].name))_duzenlenmis.pdf" : "duzenlenmis.pdf"
        let url = c.out(name)
        try PDFKitIO.write(output, to: url)
        return [url]
    }

    static func rotate(_ c: ToolContext) async throws -> [URL] {
        var perPage: [String: Int] = [:]
        if let data = c.options.string("per_page").data(using: .utf8), !data.isEmpty {
            perPage = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        let angle = ((c.options.int("angle", 90) % 360) + 360) % 360
        var urls: [URL] = []
        for input in c.inputs {
            let document = try await c.pdf(input)
            if !perPage.isEmpty && c.inputs.count == 1 {
                for (key, value) in perPage {
                    if let index = Int(key), let page = document.page(at: index), value % 360 != 0 {
                        page.rotation = ((page.rotation + value) % 360 + 360) % 360
                    }
                }
            } else {
                for index in try PageRanges.pages(c.options.string("pages"), count: document.pageCount) {
                    if let page = document.page(at: index) {
                        page.rotation = (page.rotation + angle) % 360
                    }
                }
            }
            let url = c.out("\(stem(input.name))_dondurulmus.pdf")
            try PDFKitIO.write(document, to: url)
            urls.append(url)
        }
        return urls
    }

    static func nUp(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let source = try await c.pdf(input)
        guard let firstPage = source.page(at: 0) else { throw ToolError("PDF'te sayfa yok.") }
        let perSheet = c.options.int("per_sheet", 2)
        let grids: [Int: (Int, Int)] = [2: (2, 1), 4: (2, 2), 6: (3, 2), 8: (4, 2), 9: (3, 3), 16: (4, 4)]
        var (columns, rows) = grids[perSheet] ?? (2, 1)
        let firstSize = PDFDraw.visualSize(firstPage)
        let landscapeSource = firstSize.width > firstSize.height
        let landscape: Bool
        switch c.options.string("orientation", "auto") {
        case "landscape": landscape = true
        case "portrait": landscape = false
        default: landscape = [2, 6, 8].contains(perSheet) != landscapeSource
        }
        let sheet = Paper.size(c.options.string("paper", "A4"), landscape: landscape)
        if (landscape && columns < rows) || (!landscape && columns > rows) {
            swap(&columns, &rows)
        }
        let margin: CGFloat = 18, gap: CGFloat = 8
        let cellWidth = (sheet.width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = (sheet.height - 2 * margin - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let vertical = c.options.string("order", "horizontal") == "vertical"
        let border = c.options.bool("border")
        let count = source.pageCount
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sheet)).pdfData { context in
            for i in 0..<count {
                let k = i % perSheet
                if k == 0 { context.beginPage() }
                let column = vertical ? k / rows : k % columns
                let row = vertical ? k % rows : k / columns
                let cell = CGRect(x: margin + CGFloat(column) * (cellWidth + gap), y: margin + CGFloat(row) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
                if let page = source.page(at: i) {
                    PDFDraw.draw(page, in: cell, context: context.cgContext)
                }
                if border {
                    context.cgContext.setStrokeColor(UIColor(white: 0.6, alpha: 1).cgColor)
                    context.cgContext.setLineWidth(0.5)
                    context.cgContext.stroke(cell)
                }
            }
        }
        let url = c.out("\(stem(input.name))_\(perSheet)lu.pdf")
        try data.write(to: url)
        return [url]
    }

    static func resize(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let source = try await c.pdf(input)
        let paperName = c.options.string("paper", "A4")
        let orientation = c.options.string("orientation", "auto")
        let margin = CGFloat(c.options.number("margin", 0))
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: Paper.size(paperName))).pdfData { context in
            for i in 0..<source.pageCount {
                guard let page = source.page(at: i) else { continue }
                let size = PDFDraw.visualSize(page)
                let landscape = orientation == "auto" ? size.width > size.height : orientation == "landscape"
                let sheet = Paper.size(paperName, landscape: landscape)
                let bounds = CGRect(origin: .zero, size: sheet)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                PDFDraw.draw(page, in: bounds.insetBy(dx: margin, dy: margin), context: context.cgContext)
            }
        }
        let url = c.out("\(stem(input.name))_\(paperName).pdf")
        try data.write(to: url)
        return [url]
    }
}
