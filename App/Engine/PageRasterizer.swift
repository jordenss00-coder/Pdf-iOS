import CoreText
import PDFKit
import UIKit

/// Sayfaları görüntüye çevirir; orijinal metni (istenmeyen alanlar hariç) görünmez katman olarak korur.
enum PageRasterizer {
    static func rasterize(_ data: Data, pages: [Int], grayscale: Bool, dpi: CGFloat = 200,
                          excluding hidden: [Int: [CGRect]] = [:]) throws -> Data {
        let renderer = try PDFiumDocument(data: data)
        guard let kit = PDFDocument(data: data) else { throw ToolError("PDF okunamadı.") }
        var words: [Int: [RecognizedWord]] = [:]
        for index in pages {
            let size = try renderer.geometry(page: index).visualSize
            let image = try renderer.render(page: index, scale: dpi / 72, grayscale: grayscale)
            let blocked = hidden[index] ?? []
            words[index] = try renderer.text(page: index).lines.flatMap { split($0) }
                .filter { word in !blocked.contains { $0.intersects(word.rect) } }
            let jpeg = try ImageCoding.encode(image, as: .jpeg, quality: 0.82)
            let pageData = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                context.beginPage()
                UIImage(data: jpeg)?.draw(in: CGRect(origin: .zero, size: size))
            }
            if let page = PDFDocument(data: pageData)?.page(at: 0) {
                kit.removePage(at: index)
                kit.insert(page, at: index)
            }
        }
        guard let rebuilt = kit.dataRepresentation() else { throw ToolError("PDF kaydedilemedi.") }
        let stamped = try PDFiumDocument(data: rebuilt)
        try stamped.stamp(pages: pages) { index, _, context in
            OCRTools.drawInvisible(words[index] ?? [], in: context)
        }
        return try stamped.save()
    }

    /// Satırı karakter kutularından kelimelere böler.
    static func split(_ line: TextLine) -> [RecognizedWord] {
        let scalars = Array(line.text.unicodeScalars)
        guard scalars.count == line.chars.count else { return [RecognizedWord(text: line.text, rect: line.rect)] }
        var words: [RecognizedWord] = []
        var text = String.UnicodeScalarView()
        var rect = CGRect.null
        func flush() {
            if !text.isEmpty, !rect.isNull { words.append(RecognizedWord(text: String(text), rect: rect)) }
            text = String.UnicodeScalarView()
            rect = .null
        }
        for (scalar, box) in zip(scalars, line.chars) {
            if scalar.properties.isWhitespace {
                flush()
                continue
            }
            text.append(scalar)
            if !box.isNull { rect = rect.union(box) }
        }
        flush()
        return words
    }
}

enum TextDrawing {
    /// Metni görünür koordinatlarda taban çizgisinden çizer; sayfa dönüşüne göre döndürür.
    static func draw(_ text: String, baseline: CGPoint, rotation: Int, font: UIFont, color: UIColor, in context: CGContext) {
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.translateBy(x: baseline.x, y: baseline.y)
        context.rotate(by: CGFloat(rotation) * .pi / 2)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
