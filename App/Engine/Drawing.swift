import PDFKit
import UIKit

enum Paper {
    static let sizes: [String: CGSize] = [
        "A3": CGSize(width: 842, height: 1191),
        "A4": CGSize(width: 595, height: 842),
        "A5": CGSize(width: 420, height: 595),
        "Letter": CGSize(width: 612, height: 792),
        "Legal": CGSize(width: 612, height: 1008),
    ]

    static func size(_ name: String, landscape: Bool = false) -> CGSize {
        let size = sizes[name] ?? sizes["A4"]!
        return landscape ? CGSize(width: size.height, height: size.width) : size
    }
}

enum Fonts {
    static let families = ["Helvetica", "Arial", "Avenir Next", "Times New Roman", "Georgia", "Courier New", "Verdana", "Gill Sans", "Menlo"]

    static func font(_ family: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let name = family.lowercased() == "arial" ? "Arial" : family
        var descriptor = UIFontDescriptor(fontAttributes: [.family: name])
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) {
            descriptor = styled
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension UIColor {
    convenience init(hex: String, fallback: UIColor = .black) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            fallback.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.init(red: r, green: g, blue: b, alpha: a)
            return
        }
        self.init(red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
                  blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

enum Layout {
    /// 9 konumdan biri ("top-left" … "bottom-right"); kutunun sol üst köşesini döndürür.
    static func position(_ position: String, item: CGSize, in page: CGSize, margin: CGFloat) -> CGPoint {
        let parts = position.split(separator: "-").map(String.init)
        let vertical = parts.count == 2 ? parts[0] : "middle"
        let horizontal = parts.count == 2 ? parts[1] : (parts.first ?? "center")
        let x: CGFloat
        switch horizontal {
        case "left": x = margin
        case "right": x = page.width - margin - item.width
        default: x = (page.width - item.width) / 2
        }
        let y: CGFloat
        switch vertical {
        case "top": y = margin
        case "bottom": y = page.height - margin - item.height
        default: y = (page.height - item.height) / 2
        }
        return CGPoint(x: x, y: y)
    }

    static func margin(_ value: String, fallback: CGFloat = 28) -> CGFloat {
        let table: [String: CGFloat] = ["small": 14, "recommended": 28, "big": 48]
        return table[value] ?? fallback
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// {n}, {total}, {date}, {time}, {file} alanlarını doldurur.
    static func fill(_ template: String, page: Int, total: Int, file: String) -> String {
        let now = Date()
        let date = DateFormatter()
        date.locale = Locale(identifier: "tr_TR")
        date.dateFormat = "dd.MM.yyyy"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return template
            .replacingOccurrences(of: "{n}", with: String(page))
            .replacingOccurrences(of: "{total}", with: String(total))
            .replacingOccurrences(of: "{date}", with: date.string(from: now))
            .replacingOccurrences(of: "{time}", with: time.string(from: now))
            .replacingOccurrences(of: "{file}", with: stem(file))
    }
}

enum PDFDraw {
    /// PDF sayfasını (dönüşüyle birlikte) UIKit bağlamındaki dikdörtgene orantılı ve vektör olarak çizer.
    static func draw(_ page: PDFPage, in rect: CGRect, context: CGContext) {
        guard let ref = page.pageRef else { return }
        let box = ref.getBoxRect(.cropBox)
        let rotation = ((Int(ref.rotationAngle) % 360) + 360) % 360
        let visual = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        guard visual.width > 0, visual.height > 0 else { return }
        let scale = min(rect.width / visual.width, rect.height / visual.height)
        let drawn = CGSize(width: visual.width * scale, height: visual.height * scale)
        let origin = CGPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + drawn.height)
        context.scaleBy(x: scale, y: -scale)
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(ref)
        context.restoreGState()
    }

    /// Sayfanın görünür boyutu (dönüş dahil).
    static func visualSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    static func attributed(_ text: String, font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

enum PDFKitIO {
    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard document.write(to: url, withOptions: options) else {
            throw ToolError("PDF kaydedilemedi.")
        }
    }

    static func copyPages(from source: PDFDocument, _ indexes: [Int], into target: PDFDocument) {
        for index in indexes {
            if let page = source.page(at: index)?.copy() as? PDFPage {
                target.insert(page, at: target.pageCount)
            }
        }
    }

    static func document(from source: PDFDocument, pages indexes: [Int]) -> PDFDocument {
        let target = PDFDocument()
        copyPages(from: source, indexes, into: target)
        return target
    }
}
