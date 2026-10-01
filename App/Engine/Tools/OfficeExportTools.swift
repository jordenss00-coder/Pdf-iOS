import PDFKit
import PDFium
import UIKit

/// Sayfadaki gömülü görsel ve görünür konumu.
struct PageImage {
    var data: Data
    var jpeg: Bool
    var rect: CGRect
}

extension PDFiumDocument {
    func images(page index: Int, minimumPixels: UInt32 = 32) throws -> [PageImage] {
        try withPage(index) { page in
            let geometry = PDFiumDocument.geometry(page)
            var result: [PageImage] = []
            for k in 0..<FPDFPage_CountObjects(page) {
                guard let object = FPDFPage_GetObject(page, k), FPDFPageObj_GetType(object) == 3 else { continue }
                var width: UInt32 = 0, height: UInt32 = 0
                guard FPDFImageObj_GetImagePixelSize(object, &width, &height) != 0, width >= minimumPixels, height >= minimumPixels else { continue }
                var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
                let rect = geometry.visual(left: Double(left), bottom: Double(bottom), right: Double(right), top: Double(top))
                if PDFiumImages.isPlainJPEG(object) {
                    let length = FPDFImageObj_GetImageDataRaw(object, nil, 0)
                    var raw = [UInt8](repeating: 0, count: Int(length))
                    _ = FPDFImageObj_GetImageDataRaw(object, &raw, length)
                    result.append(PageImage(data: Data(raw), jpeg: true, rect: rect))
                } else if let bitmap = FPDFImageObj_GetBitmap(object) {
                    defer { FPDFBitmap_Destroy(bitmap) }
                    if let image = PDFiumImages.cgImage(bitmap), let png = try? ImageCoding.encode(image, as: .png) {
                        result.append(PageImage(data: png, jpeg: false, rect: rect))
                    }
                }
            }
            return result
        }
    }

    /// Belgenin metinsiz kopyası (PowerPoint arka planı için).
    func withoutText() throws -> PDFiumDocument {
        let copy = try PDFiumDocument(data: try save())
        for index in 0..<copy.pageCount {
            try copy.withPage(index) { page in
                let chars = TextSurgery.characters(page)
                var plan = TextSurgery.Plan()
                plan.remove = Set(chars.map(\.index))
                _ = TextSurgery.apply(plan, chars: chars, page: page, document: copy.handle)
            }
        }
        return copy
    }
}

enum OfficeExportTools {
    // MARK: Word

    static func pdfToWord(_ c: ToolContext) async throws -> [URL] {
        let imageMode = c.options.string("mode", "flow") == "image"
        var urls: [URL] = []
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            let writer = DocxWriter()
            if document.pageCount > 0 {
                writer.pageSize = try document.geometry(page: 0).visualSize
            }
            let usable = Double(writer.pageSize.width) - 2 * 56.7
            for index in 0..<document.pageCount {
                c.progress(Double(index) / Double(max(1, document.pageCount)), "Sayfa \(index + 1)")
                if index > 0 { writer.pageBreak() }
                let text = try document.text(page: index)
                if imageMode {
                    let image = try document.render(page: index, scale: 150 / 72)
                    let jpeg = try ImageCoding.encode(image, as: .jpeg, quality: 0.85)
                    let height = usable * Double(text.size.height / max(1, text.size.width))
                    writer.image(jpeg, jpeg: true, width: usable, height: height)
                    writer.pageBreak()
                }
                flow(text, images: imageMode ? [] : try document.images(page: index), into: writer, usableWidth: usable)
            }
            let url = c.out("\(stem(input.name)).docx")
            try writer.data().write(to: url)
            urls.append(url)
        }
        return urls
    }

    private struct Paragraph {
        var lines: [TextLine]
        var text: String
    }

    /// Satırları paragraflara, başlıklara, listelere ve tablolara çevirir; görselleri dikey konumlarına göre yerleştirir.
    static func flow(_ page: PageText, images: [PageImage], into writer: DocxWriter, usableWidth: Double) {
        let lines = page.lines
        let sizes = lines.map(\.fontSize).filter { $0 > 0 }.sorted()
        let body = sizes.isEmpty ? 11 : sizes[sizes.count / 2]
        var pendingImages = images.sorted { $0.rect.minY < $1.rect.minY }
        func emitImages(before y: CGFloat) {
            while let image = pendingImages.first, image.rect.minY <= y {
                pendingImages.removeFirst()
                let width = min(usableWidth, Double(image.rect.width))
                let height = width * Double(image.rect.height / max(1, image.rect.width))
                writer.image(image.data, jpeg: image.jpeg, width: width, height: height)
            }
        }
        var paragraph: [TextLine] = []
        func flushParagraph() {
            guard let first = paragraph.first else { return }
            var text = ""
            for line in paragraph {
                let piece = line.text.trimmingCharacters(in: .whitespaces)
                if text.hasSuffix("-"), let next = piece.first, next.isLowercase {
                    text.removeLast()
                    text += piece
                } else {
                    text += text.isEmpty ? piece : " " + piece
                }
            }
            let bullets: Set<Character> = ["•", "●", "▪", "◦", "–", "-"]
            var style: String?
            var size: Double? = first.fontSize > 0 ? min(72, first.fontSize) : nil
            if paragraph.count == 1 && first.fontSize >= body * 1.6 {
                style = "Heading1"
                size = nil
            } else if paragraph.count <= 2 && first.fontSize >= body * 1.2 {
                style = "Heading2"
                size = nil
            } else if let mark = text.first, bullets.contains(mark), text.count > 1 {
                style = "ListParagraph"
                text = "• " + text.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            let center = abs(first.rect.midX - page.size.width / 2) < page.size.width * 0.08 && first.rect.width < page.size.width * 0.7
            writer.paragraph([DocxWriter.Run(text: text, size: size, bold: first.bold && style == nil, italic: first.italic,
                                             color: first.color)],
                             style: style, alignment: center && paragraph.count == 1 ? "center" : nil)
            paragraph = []
        }
        var index = 0
        while index < lines.count {
            // Tablo: en az üç ardışık satırda aynı sayıda (≥2) hizalı sütun.
            var rows: [[String]] = []
            var k = index
            while k < lines.count {
                let cells = MarkdownLayout.cells(lines[k])
                guard cells.count >= 2, rows.isEmpty || cells.count == rows[0].count else { break }
                rows.append(cells)
                k += 1
            }
            if rows.count >= 3 {
                flushParagraph()
                emitImages(before: lines[index].rect.minY)
                writer.table(rows)
                index = k
                continue
            }
            let line = lines[index]
            emitImages(before: line.rect.minY)
            if let previous = paragraph.last {
                let gap = line.rect.minY - previous.rect.maxY
                let similar = abs(line.fontSize - previous.fontSize) <= max(1, previous.fontSize * 0.1) && line.bold == previous.bold
                let aligned = abs(line.rect.minX - paragraph[0].rect.minX) < max(previous.fontSize * 2, 12)
                let startsList = line.text.first.map { "•●▪◦".contains($0) } ?? false
                if !(similar && aligned && gap < previous.rect.height * 0.9 && gap > -previous.rect.height * 0.5) || startsList {
                    flushParagraph()
                }
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        emitImages(before: .greatestFiniteMagnitude)
    }

    // MARK: Excel

    static func number(_ text: String, style: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "₺", with: "").replacingOccurrences(of: "TL", with: "")
            .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        switch style {
        case "tr":
            guard cleaned.range(of: #"^-?\d{1,3}(\.\d{3})*(,\d+)?$|^-?\d+(,\d+)?$"#, options: .regularExpression) != nil else { return nil }
            return Double(cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
        case "en":
            guard cleaned.range(of: #"^-?\d{1,3}(,\d{3})*(\.\d+)?$|^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            return Double(cleaned.replacingOccurrences(of: ",", with: ""))
        default:
            return nil
        }
    }

    static func pdfToExcel(_ c: ToolContext) async throws -> [URL] {
        let style = c.options.string("numbers", "tr")
        let single = c.options.string("layout", "per_table") == "single"
        var urls: [URL] = []
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            let writer = XlsxWriter()
            var combined: [[XlsxWriter.Cell]] = []
            var combinedBold: Set<Int> = []
            var textRows: [[XlsxWriter.Cell]] = []
            var found = 0
            func cell(_ text: String) -> XlsxWriter.Cell {
                if let value = number(text, style: style) { return .number(value) }
                return text.isEmpty ? .empty : .text(text)
            }
            for index in 0..<document.pageCount {
                let lines = try document.text(page: index).lines
                var tableNumber = 0
                var k = 0
                while k < lines.count {
                    var rows: [[String]] = []
                    var j = k
                    while j < lines.count {
                        let cells = MarkdownLayout.cells(lines[j])
                        guard cells.count >= 2, rows.isEmpty || cells.count == rows[0].count else { break }
                        rows.append(cells)
                        j += 1
                    }
                    if rows.count >= 2 {
                        found += 1
                        tableNumber += 1
                        let mapped = rows.enumerated().map { r, row in row.map { r == 0 ? XlsxWriter.Cell.text($0) : cell($0) } }
                        if single {
                            combinedBold.insert(combined.count)
                            combined.append([.text("Sayfa \(index + 1) – Tablo \(tableNumber)")])
                            combinedBold.insert(combined.count)
                            combined += mapped
                            combined.append([])
                        } else {
                            writer.addSheet("S\(index + 1)-T\(tableNumber)", rows: mapped)
                        }
                        k = j
                    } else {
                        textRows.append(MarkdownLayout.cells(lines[k]).map(cell))
                        k += 1
                    }
                }
            }
            if single && found > 0 {
                writer.addSheet("Tablolar", rows: combined, boldRows: combinedBold)
            }
            if found == 0 {
                writer.addSheet("Metin", rows: textRows, boldRows: [])
                c.warnings.append("\(input.name): tablo bulunamadı; metin satırlar halinde aktarıldı.")
            }
            let url = c.out("\(stem(input.name)).xlsx")
            try writer.data().write(to: url)
            urls.append(url)
        }
        return urls
    }

    // MARK: PowerPoint

    static func pdfToPowerPoint(_ c: ToolContext) async throws -> [URL] {
        let editable = c.options.string("mode", "editable") == "editable"
        var urls: [URL] = []
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            guard document.pageCount > 0 else { throw ToolError("'\(input.name)' içinde sayfa yok.") }
            let slide = try document.geometry(page: 0).visualSize
            let writer = PptxWriter(slideSize: slide)
            let background = try editable ? document.withoutText() : document
            for index in 0..<document.pageCount {
                c.progress(Double(index) / Double(document.pageCount), "Slayt \(index + 1)")
                let size = try document.geometry(page: index).visualSize
                let sx = slide.width / max(1, size.width), sy = slide.height / max(1, size.height)
                let image = try background.render(page: index, scale: (editable ? 170 : 200) / 72)
                let jpeg = try ImageCoding.encode(image, as: .jpeg, quality: 0.88)
                var boxes: [PptxWriter.TextBox] = []
                if editable {
                    for line in try document.text(page: index).lines where !line.rect.isNull {
                        let frame = CGRect(x: line.rect.minX * sx, y: line.rect.minY * sy,
                                           width: (line.rect.width + 4) * sx, height: max(line.rect.height, CGFloat(line.fontSize)) * sy)
                        boxes.append(PptxWriter.TextBox(frame: frame, text: line.text, size: max(1, line.fontSize * Double(sy)),
                                                        bold: line.bold, italic: line.italic, color: line.color))
                    }
                }
                writer.addSlide(background: jpeg, jpeg: true, boxes: boxes)
            }
            let url = c.out("\(stem(input.name)).pptx")
            try writer.data().write(to: url)
            urls.append(url)
        }
        return urls
    }
}
