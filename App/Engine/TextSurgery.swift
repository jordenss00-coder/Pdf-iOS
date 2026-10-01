import CoreGraphics
import Foundation
import PDFium
import UIKit

/// PDFium metin nesneleri üzerinde karakter düzeyinde gerçek silme ve yeniden yazma.
/// Silinen karakterler dosyadan tamamen çıkar; kalanlar orijinal (gömülü) yazı tipiyle aynı yere yazılır.
enum TextSurgery {
    struct Char {
        let index: Int
        let scalar: Unicode.Scalar
        let object: FPDF_PAGEOBJECT?
        /// Sayfa koordinatları (y yukarı)
        let origin: CGPoint
        let box: CGRect
        let generated: Bool
    }

    struct Line {
        var chars: [Char]
        var text: String { String(String.UnicodeScalarView(chars.map(\.scalar))) }
    }

    struct Plan {
        var remove: Set<Int> = []
        /// Korunan karakterlerin taban çizgisi boyunca kayması (sayfa birimi)
        var shift: [Int: CGFloat] = [:]
    }

    struct Style {
        var size: CGFloat
        var color: UIColor
        var bold: Bool
        var italic: Bool
        var family: String
    }

    /// Sayfanın karakterleri, PDFium'un okuma sırasıyla. PDFium kilidi içinde çağrılmalı.
    static func characters(_ page: FPDF_PAGE) -> [Char] {
        guard let textPage = FPDFText_LoadPage(page) else { return [] }
        defer { FPDFText_ClosePage(textPage) }
        var result: [Char] = []
        let count = Int(FPDFText_CountChars(textPage))
        for i in 0..<count {
            guard let scalar = Unicode.Scalar(FPDFText_GetUnicode(textPage, Int32(i))) else { continue }
            var x = 0.0, y = 0.0
            _ = FPDFText_GetCharOrigin(textPage, Int32(i), &x, &y)
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            let hasBox = FPDFText_GetCharBox(textPage, Int32(i), &left, &right, &bottom, &top) != 0
            result.append(Char(index: i, scalar: scalar, object: FPDFText_GetTextObject(textPage, Int32(i)),
                               origin: CGPoint(x: x, y: y),
                               box: hasBox ? CGRect(x: left, y: bottom, width: right - left, height: top - bottom) : .null,
                               generated: FPDFText_IsGenerated(textPage, Int32(i)) == 1))
        }
        return result
    }

    /// Karakterleri PDFium'un ürettiği satır sonlarından satırlara böler.
    static func lines(_ chars: [Char]) -> [Line] {
        var lines: [Line] = []
        var current: [Char] = []
        for char in chars {
            if char.scalar == "\r" || char.scalar == "\n" {
                if !current.isEmpty { lines.append(Line(chars: current)) }
                current = []
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { lines.append(Line(chars: current)) }
        return lines
    }

    /// Planı uygular. Form XObject içindeki (iç içe) nesnelere dokunulamazsa `nested` true döner.
    static func apply(_ plan: Plan, chars: [Char], page: FPDF_PAGE, document: FPDF_DOCUMENT) -> (removed: Int, nested: Bool) {
        var topLevel: [FPDF_PAGEOBJECT: Int] = [:]
        for k in 0..<FPDFPage_CountObjects(page) {
            if let object = FPDFPage_GetObject(page, k) { topLevel[object] = Int(k) }
        }
        var groups: [FPDF_PAGEOBJECT: [Char]] = [:]
        var order: [FPDF_PAGEOBJECT] = []
        for char in chars where !char.generated {
            guard let object = char.object else { continue }
            if groups[object] == nil { order.append(object) }
            groups[object, default: []].append(char)
        }
        let affected = order.filter { object in
            groups[object]!.contains { plan.remove.contains($0.index) || (plan.shift[$0.index] ?? 0) != 0 }
        }
        var removed = 0
        var nested = false
        for object in affected.sorted(by: { (topLevel[$0] ?? -1) > (topLevel[$1] ?? -1) }) {
            guard let position = topLevel[object] else {
                nested = true
                continue
            }
            let list = groups[object]!
            let font = FPDFTextObj_GetFont(object)
            var size: Float = 0
            _ = FPDFTextObj_GetFontSize(object, &size)
            var matrix = FS_MATRIX(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
            _ = FPDFPageObj_GetMatrix(object, &matrix)
            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 255
            _ = FPDFPageObj_GetFillColor(object, &r, &g, &b, &a)
            let mode = FPDFTextObj_GetTextRenderMode(object)

            // Her kelime ayrı parça olarak orijinal konumundan yazılır (aralık/kerning kayması birikmesin);
            // satır değişince de parça kapanır (bir nesne birden fazla satıra yayılabilir).
            var runs: [(origin: CGPoint, text: [UInt16])] = []
            var current: [UInt16] = []
            var start: CGPoint?
            var currentShift: CGFloat = 0
            var last: CGPoint?
            func close() {
                if let start, !current.isEmpty { runs.append((start, current)) }
                current = []
                start = nil
            }
            for char in list {
                if plan.remove.contains(char.index) {
                    if !char.scalar.properties.isWhitespace { removed += 1 }
                    close()
                    continue
                }
                let shift = plan.shift[char.index] ?? 0
                if let previous = last, abs(char.origin.y - previous.y) > 0.5 || char.origin.x < previous.x - 0.5 { close() }
                if start != nil && shift != currentShift { close() }
                if start == nil {
                    start = CGPoint(x: char.origin.x + shift, y: char.origin.y)
                    currentShift = shift
                }
                current += Array(String(char.scalar).utf16)
                last = char.origin
                if char.scalar.properties.isWhitespace { close() }
            }
            close()

            guard FPDFPage_RemoveObject(page, object) != 0 else {
                nested = true
                continue
            }
            FPDFPageObj_Destroy(object)
            guard let font else { continue }
            for run in runs.reversed() {
                guard let text = FPDFPageObj_CreateTextObj(document, font, size) else { continue }
                var wide = run.text + [0]
                _ = FPDFText_SetText(text, &wide)
                var placed = matrix
                placed.e = Float(run.origin.x)
                placed.f = Float(run.origin.y)
                _ = FPDFPageObj_SetMatrix(text, &placed)
                _ = FPDFPageObj_SetFillColor(text, r, g, b, a)
                _ = FPDFTextObj_SetTextRenderMode(text, mode)
                _ = FPDFPage_InsertObjectAtIndex(page, text, position)
            }
        }
        if !affected.isEmpty { _ = FPDFPage_GenerateContent(page) }
        return (removed, nested)
    }

    /// Karakterin metin nesnesinden yazı stili (yeni metin için sistem yazı tipi seçimi).
    static func style(of char: Char) -> Style {
        guard let object = char.object else {
            return Style(size: max(4, char.box.height), color: .black, bold: false, italic: false, family: "Helvetica")
        }
        var size: Float = 0
        _ = FPDFTextObj_GetFontSize(object, &size)
        var matrix = FS_MATRIX(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
        _ = FPDFPageObj_GetMatrix(object, &matrix)
        let effective = CGFloat(size) * CGFloat(hypot(Double(matrix.c), Double(matrix.d)))
        var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 255
        _ = FPDFPageObj_GetFillColor(object, &r, &g, &b, &a)
        var name = ""
        if let font = FPDFTextObj_GetFont(object) {
            let length = FPDFFont_GetBaseFontName(font, nil, 0)
            if length > 0 {
                var buffer = [CChar](repeating: 0, count: Int(length))
                _ = FPDFFont_GetBaseFontName(font, &buffer, length)
                name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        let lower = name.lowercased()
        let family: String
        if lower.contains("times") || lower.contains("serif") && !lower.contains("sans") {
            family = "Times New Roman"
        } else if lower.contains("courier") || lower.contains("mono") {
            family = "Courier New"
        } else if lower.contains("georgia") {
            family = "Georgia"
        } else if lower.contains("verdana") {
            family = "Verdana"
        } else if lower.contains("arial") {
            family = "Arial"
        } else {
            family = "Helvetica"
        }
        return Style(size: effective > 0.5 ? effective : max(4, char.box.height),
                     color: UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255),
                     bold: lower.contains("bold") || lower.contains("black") || lower.contains("heavy"),
                     italic: lower.contains("italic") || lower.contains("oblique"),
                     family: family)
    }

    /// Satır metninde düzenli ifade eşleşmelerini karakter dizinlerine (satır içi) çevirir.
    static func matches(_ regex: NSRegularExpression, in line: Line) -> [Range<Int>] {
        let text = line.text
        let scalars = text.unicodeScalars
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), !range.isEmpty else { return nil }
            let lower = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
            let upper = scalars.distance(from: scalars.startIndex, to: range.upperBound)
            return lower..<upper
        }
    }

    static func regex(_ find: String, caseSensitive: Bool, wholeWord: Bool) throws -> NSRegularExpression {
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord { pattern = "(?<!\\w)" + pattern + "(?!\\w)" }
        do {
            return try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw ToolError("Geçersiz arama ifadesi.")
        }
    }
}

extension PageGeometry {
    /// Görünür (sol üst, y aşağı) noktayı sayfa koordinatına çevirir.
    func page(_ point: CGPoint) -> CGPoint {
        let up = CGPoint(x: point.x, y: visualSize.height - point.y)
        let a: CGFloat, b: CGFloat
        switch rotation {
        case 1:
            b = up.x
            a = box.width - up.y
        case 2:
            a = box.width - up.x
            b = box.height - up.y
        case 3:
            a = up.y
            b = box.height - up.x
        default:
            a = up.x
            b = up.y
        }
        return CGPoint(x: a + box.minX, y: b + box.minY)
    }

    func page(_ rect: CGRect) -> CGRect {
        let p1 = page(CGPoint(x: rect.minX, y: rect.minY)), p2 = page(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}
