import PDFKit
import PDFium
import UIKit

enum RedactTools {
    static let presets: [String: String] = [
        "email": #"[\w.+-]+@[\w-]+(\.[\w-]+)+"#,
        "phone": #"(\+?90[\s-]?)?\(?0?5\d{2}\)?[\s-]?\d{3}[\s-]?\d{2}[\s-]?\d{2}|\+?\d{1,3}[\s-]?\(?\d{3}\)?[\s-]?\d{3}[\s-]?\d{2,4}[\s-]?\d{0,4}"#,
        "tckn": #"(?<!\d)[1-9]\d{10}(?!\d)"#,
        "iban": #"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,7}(?:\s?[A-Z0-9]{1,4})?\b"#,
        "card": #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#,
        "url": #"https?://\S+|www\.\S+"#,
        "date": #"\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#,
    ]

    /// Editörden gelen elle seçilmiş alanlar (görünür koordinatlar).
    struct Area: Codable {
        var page: Int
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    static func regexes(_ options: OptionValues) throws -> [NSRegularExpression] {
        var result: [NSRegularExpression] = []
        let terms = options.string("terms_text").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for term in terms {
            result.append(try TextSurgery.regex(term, caseSensitive: options.bool("case"), wholeWord: options.bool("whole_word")))
        }
        for key in options.list("presets") {
            if let pattern = presets[key], let regex = try? NSRegularExpression(pattern: pattern) {
                result.append(regex)
            }
        }
        return result
    }

    /// Eşleşmelerin görünür sayfa koordinatlarındaki kutuları.
    static func search(_ document: PDFiumDocument, regexes: [NSRegularExpression]) throws -> [Int: [CGRect]] {
        guard !regexes.isEmpty else { return [:] }
        var found: [Int: [CGRect]] = [:]
        for index in 0..<document.pageCount {
            for line in try document.text(page: index).lines {
                let scalars = line.text.unicodeScalars
                guard scalars.count == line.chars.count else { continue }
                for regex in regexes {
                    for match in regex.matches(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) {
                        guard let range = Range(match.range, in: line.text), !range.isEmpty else { continue }
                        let lower = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
                        let upper = scalars.distance(from: scalars.startIndex, to: range.upperBound)
                        let rect = line.chars[lower..<upper].reduce(CGRect.null) { $1.isNull ? $0 : $0.union($1) }
                        if !rect.isNull { found[index, default: []].append(rect.insetBy(dx: -0.5, dy: -0.5)) }
                    }
                }
            }
        }
        return found
    }

    static func redact(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try PDFiumDocument(data: try await c.pdfData(input))
        var areas: [Int: [CGRect]] = [:]
        if let data = c.options.string("areas").data(using: .utf8), !data.isEmpty,
           let list = try? JSONDecoder().decode([Area].self, from: data) {
            for area in list where area.page >= 0 && area.page < document.pageCount {
                areas[area.page, default: []].append(CGRect(x: area.x, y: area.y, width: area.w, height: area.h))
            }
        }
        for (page, rects) in try search(document, regexes: try regexes(c.options)) {
            areas[page, default: []] += rects
        }
        guard !areas.isEmpty else {
            throw ToolError(c.options.string("areas").isEmpty && c.options.list("presets").isEmpty && c.options.string("terms_text").isEmpty
                            ? "Karartılacak alanları seç ya da aranacak metin ekle." : "Karartılacak bir şey bulunamadı.")
        }
        let color = UIColor(hex: c.options.string("color", "#000000"))
        let rasterize = try Redactor.apply(document, areas: areas, color: color)
        var output = try document.save()
        if !rasterize.isEmpty {
            output = try PageRasterizer.rasterize(output, pages: rasterize, grayscale: false, dpi: 220, excluding: areas)
            c.notes.append("\(rasterize.count) sayfa güvenlik için görüntüye çevrildi.")
        }
        if c.options.bool("clean_metadata", true), let kit = PDFDocument(data: output) {
            kit.documentAttributes = [:]
            if let cleaned = kit.dataRepresentation() { output = cleaned }
        }
        let count = areas.values.reduce(0) { $0 + $1.count }
        c.notes.append("\(count) alan kalıcı olarak karartıldı; altındaki içerik dosyadan silindi.")
        let url = c.out("\(stem(input.name))_karartilmis.pdf")
        try output.write(to: url)
        return [url]
    }
}

enum Redactor {
    /// Alanlardaki metni, görsel piksellerini, şekilleri ve notları siler, üstüne renkli kutu çizer.
    /// Güvenle düzenlenemeyen (iç içe içerikli) sayfaların listesini döndürür.
    static func apply(_ document: PDFiumDocument, areas: [Int: [CGRect]], color: UIColor) throws -> [Int] {
        var unsafe: [Int] = []
        for (index, rects) in areas.sorted(by: { $0.key < $1.key }) {
            let secure = try document.withPage(index) { page -> Bool in
                let geometry = PDFiumDocument.geometry(page)
                let targets = rects.map { geometry.page($0) }
                let chars = TextSurgery.characters(page)
                var plan = TextSurgery.Plan()
                for char in chars where !char.box.isNull {
                    let center = CGPoint(x: char.box.midX, y: char.box.midY)
                    if targets.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(center) }) {
                        plan.remove.insert(char.index)
                    }
                }
                var secure = !TextSurgery.apply(plan, chars: chars, page: page, document: document.handle).nested
                var changed = false
                var k = FPDFPage_CountObjects(page) - 1
                while k >= 0 {
                    defer { k -= 1 }
                    guard let object = FPDFPage_GetObject(page, k) else { continue }
                    var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                    guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
                    let bounds = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom))
                    let hits = targets.filter { $0.intersects(bounds) }
                    guard !hits.isEmpty else { continue }
                    switch FPDFPageObj_GetType(object) {
                    case 2:
                        if hits.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(bounds) }), FPDFPage_RemoveObject(page, object) != 0 {
                            FPDFPageObj_Destroy(object)
                            changed = true
                        }
                    case 3:
                        if blackOut(object, page: page, bounds: bounds, rects: hits) {
                            changed = true
                        } else {
                            secure = false
                        }
                    case 5:
                        secure = false
                    default:
                        break
                    }
                }
                if changed { _ = FPDFPage_GenerateContent(page) }
                var annotation = FPDFPage_GetAnnotCount(page) - 1
                while annotation >= 0 {
                    if let handle = FPDFPage_GetAnnot(page, annotation) {
                        var rect = FS_RECTF(left: 0, top: 0, right: 0, bottom: 0)
                        let hit = FPDFAnnot_GetRect(handle, &rect) != 0 && targets.contains {
                            $0.intersects(CGRect(x: CGFloat(min(rect.left, rect.right)), y: CGFloat(min(rect.top, rect.bottom)),
                                                 width: CGFloat(abs(rect.right - rect.left)), height: CGFloat(abs(rect.top - rect.bottom))))
                        }
                        FPDFPage_CloseAnnot(handle)
                        if hit { _ = FPDFPage_RemoveAnnot(page, annotation) }
                    }
                    annotation -= 1
                }
                return secure
            }
            if !secure { unsafe.append(index) }
        }
        try document.stamp(pages: areas.keys.sorted()) { index, _, context in
            context.setFillColor(color.cgColor)
            for rect in areas[index] ?? [] { context.fill(rect) }
        }
        return unsafe
    }

    /// Görselin alanlara denk gelen piksellerini boyar (eksenlere hizalı görseller için).
    static func blackOut(_ object: FPDF_PAGEOBJECT, page: FPDF_PAGE, bounds: CGRect, rects: [CGRect]) -> Bool {
        var matrix = FS_MATRIX(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
        _ = FPDFPageObj_GetMatrix(object, &matrix)
        guard abs(matrix.b) < 0.001, abs(matrix.c) < 0.001, bounds.width > 0, bounds.height > 0,
              let bitmap = FPDFImageObj_GetBitmap(object) else { return false }
        defer { FPDFBitmap_Destroy(bitmap) }
        guard FPDFBitmap_GetFormat(bitmap) != 4, let image = PDFiumImages.cgImage(bitmap),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in rects {
            let clipped = rect.intersection(bounds)
            guard !clipped.isNull else { continue }
            var x0 = (clipped.minX - bounds.minX) / bounds.width * width
            var x1 = (clipped.maxX - bounds.minX) / bounds.width * width
            var y0 = (clipped.minY - bounds.minY) / bounds.height * height
            var y1 = (clipped.maxY - bounds.minY) / bounds.height * height
            if matrix.a < 0 { (x0, x1) = (width - x1, width - x0) }
            if matrix.d < 0 { (y0, y1) = (height - y1, height - y0) }
            context.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -1, dy: -1))
        }
        guard let edited = context.makeImage(), let jpeg = try? ImageCoding.encode(edited, as: .jpeg, quality: 0.9) else { return false }
        return PDFiumImageEdit.replace(object, on: page, jpeg: jpeg)
    }
}

enum TextTools {
    struct Insertion {
        var origin: CGPoint
        var text: String
        var style: TextSurgery.Style
    }

    static func findReplace(_ c: ToolContext) async throws -> [URL] {
        let pairs = c.options.pairs("pairs").filter { !$0.find.isEmpty }
        guard !pairs.isEmpty else { throw ToolError("Aranacak metni yaz.") }
        let rules = try pairs.map { (try TextSurgery.regex($0.find, caseSensitive: c.options.bool("case"), wholeWord: c.options.bool("whole_word")), $0.replace) }
        var urls: [URL] = []
        var total = 0
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            var insertions: [Int: [Insertion]] = [:]
            var rotations: [Int: Int] = [:]
            for index in 0..<document.pageCount {
                let (count, inserts, rotation) = try document.withPage(index) { page -> (Int, [Insertion], Int) in
                    let geometry = PDFiumDocument.geometry(page)
                    let chars = TextSurgery.characters(page)
                    var plan = TextSurgery.Plan()
                    var inserts: [Insertion] = []
                    var count = 0
                    for line in TextSurgery.lines(chars) {
                        var hits: [(Range<Int>, String)] = []
                        for (regex, replacement) in rules {
                            for range in TextSurgery.matches(regex, in: line) where !hits.contains(where: { $0.0.overlaps(range) }) {
                                hits.append((range, replacement))
                            }
                        }
                        guard !hits.isEmpty else { continue }
                        hits.sort { $0.0.lowerBound < $1.0.lowerBound }
                        count += hits.count
                        var shift: CGFloat = 0
                        var next = 0
                        for (position, char) in line.chars.enumerated() {
                            if next < hits.count && position == hits[next].0.lowerBound {
                                let (range, replacement) = hits[next]
                                let matched = Array(line.chars[range])
                                let style = TextSurgery.style(of: matched[0])
                                let font = Fonts.font(style.family, size: style.size, bold: style.bold, italic: style.italic)
                                let newWidth = replacement.isEmpty ? 0 : (replacement as NSString).size(withAttributes: [.font: font]).width
                                let start = matched[0].origin.x
                                let end = matched.map(\.box).filter { !$0.isNull }.map(\.maxX).max() ?? start
                                inserts.append(Insertion(origin: CGPoint(x: start + shift, y: matched[0].origin.y), text: replacement, style: style))
                                for item in matched { plan.remove.insert(item.index) }
                                shift += newWidth - (end - start)
                                next += 1
                            }
                            if !plan.remove.contains(char.index), shift != 0 {
                                plan.shift[char.index] = shift
                            }
                        }
                    }
                    guard count > 0 else { return (0, [], geometry.rotation) }
                    _ = TextSurgery.apply(plan, chars: chars, page: page, document: document.handle)
                    let visual = inserts.map { insertion -> Insertion in
                        var moved = insertion
                        moved.origin = geometry.visual(insertion.origin)
                        return moved
                    }
                    return (count, visual, geometry.rotation)
                }
                total += count
                if !inserts.isEmpty {
                    insertions[index] = inserts
                    rotations[index] = rotation
                }
            }
            if !insertions.isEmpty {
                try document.stamp(pages: insertions.keys.sorted()) { index, _, context in
                    for insertion in insertions[index] ?? [] {
                        let style = insertion.style
                        TextDrawing.draw(insertion.text, baseline: insertion.origin, rotation: rotations[index] ?? 0,
                                         font: Fonts.font(style.family, size: style.size, bold: style.bold, italic: style.italic),
                                         color: style.color, in: context)
                    }
                }
            }
            let url = c.out("\(stem(input.name))_duzeltilmis.pdf")
            try document.save().write(to: url)
            urls.append(url)
        }
        guard total > 0 else {
            throw ToolError("Aranan metin belgede bulunamadı. Taranmış bir belgeyse önce OCR uygula.")
        }
        c.notes.append("\(total) yerde değiştirildi.")
        return urls
    }
}
