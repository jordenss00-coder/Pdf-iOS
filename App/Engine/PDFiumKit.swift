import Foundation
import PDFium
import UIKit

/// PDFium iş parçacığı güvenli değildir; tüm çağrılar tek bir kilitten geçer.
enum PDFium {
    private static let lock = NSRecursiveLock()
    private static var ready = false

    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        if !ready {
            FPDF_InitLibrary()
            ready = true
        }
        return try body()
    }
}

private var writeBuffer = Data()

private func writeBlock(_ writer: UnsafeMutablePointer<FPDF_FILEWRITE_>?, _ data: UnsafeRawPointer?, _ size: UInt) -> Int32 {
    guard let data else { return 0 }
    writeBuffer.append(data.assumingMemoryBound(to: UInt8.self), count: Int(size))
    return 1
}

/// Sayfanın kırpma kutusu ve dönüşü; görünür (kullanıcının gördüğü) koordinatlara çeviri.
struct PageGeometry {
    let box: CGRect
    /// 0, 1, 2, 3 = 0°, 90°, 180°, 270° saat yönünde
    let rotation: Int

    var visualSize: CGSize {
        rotation % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Görünür, y yukarı koordinatlardan (katman sayfası) sayfa koordinatlarına.
    var overlayMatrix: FS_MATRIX {
        let x0 = Float(box.minX), y0 = Float(box.minY), w = Float(box.width), h = Float(box.height)
        switch rotation {
        case 1: return FS_MATRIX(a: 0, b: 1, c: -1, d: 0, e: x0 + w, f: y0)
        case 2: return FS_MATRIX(a: -1, b: 0, c: 0, d: -1, e: x0 + w, f: y0 + h)
        case 3: return FS_MATRIX(a: 0, b: -1, c: 1, d: 0, e: x0, f: y0 + h)
        default: return FS_MATRIX(a: 1, b: 0, c: 0, d: 1, e: x0, f: y0)
        }
    }

    /// Sayfa koordinatındaki noktayı görünür, sol üst başlangıçlı (y aşağı) koordinata çevirir.
    func visual(_ point: CGPoint) -> CGPoint {
        let a = point.x - box.minX, b = point.y - box.minY
        let up: CGPoint
        switch rotation {
        case 1: up = CGPoint(x: b, y: box.width - a)
        case 2: up = CGPoint(x: box.width - a, y: box.height - b)
        case 3: up = CGPoint(x: box.height - b, y: a)
        default: up = CGPoint(x: a, y: b)
        }
        return CGPoint(x: up.x, y: visualSize.height - up.y)
    }

    func visual(left: Double, bottom: Double, right: Double, top: Double) -> CGRect {
        let p1 = visual(CGPoint(x: left, y: bottom))
        let p2 = visual(CGPoint(x: right, y: top))
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}

struct TextLine {
    var text: String
    /// Görünür, sol üst başlangıçlı koordinatlarda
    var rect: CGRect
    var fontSize: Double
    var chars: [CGRect] = []
    var bold = false
    var italic = false
    /// "#rrggbb"
    var color = "#000000"
}

struct PageText {
    var size: CGSize
    var lines: [TextLine]

    var plain: String { lines.map(\.text).joined(separator: "\n") }
}

final class PDFiumDocument {
    let handle: FPDF_DOCUMENT
    private let source: NSData?

    init(data: Data, password: String? = nil) throws {
        let bytes = NSData(data: FontNames.unique(data))
        let document: FPDF_DOCUMENT? = PDFium.sync {
            if let password {
                return FPDF_LoadMemDocument(bytes.bytes, Int32(bytes.length), password)
            }
            return FPDF_LoadMemDocument(bytes.bytes, Int32(bytes.length), nil)
        }
        guard let document else {
            let code = PDFium.sync { FPDF_GetLastError() }
            if code == 4 {
                throw ToolError(password == nil ? "Bu PDF parola korumalı. Önce parolayı gir." : "PDF parolası yanlış.")
            }
            throw ToolError("PDF okunamadı (hata \(code)). Dosya ağır hasarlı olabilir.")
        }
        handle = document
        source = bytes
    }

    init() throws {
        let document: FPDF_DOCUMENT? = PDFium.sync { FPDF_CreateNewDocument() }
        guard let document else { throw ToolError("Yeni PDF oluşturulamadı.") }
        handle = document
        source = nil
    }

    deinit {
        let document = handle
        PDFium.sync { FPDF_CloseDocument(document) }
    }

    var pageCount: Int {
        PDFium.sync { Int(FPDF_GetPageCount(handle)) }
    }

    func withPage<T>(_ index: Int, _ body: (FPDF_PAGE) throws -> T) throws -> T {
        try PDFium.sync {
            guard let page = FPDF_LoadPage(handle, Int32(index)) else {
                throw ToolError("Sayfa \(index + 1) açılamadı.")
            }
            defer { FPDF_ClosePage(page) }
            return try body(page)
        }
    }

    /// removeSecurity: şifreyi ve izin kısıtlamalarını kaldırarak kaydeder.
    func save(removeSecurity: Bool = false, version: Int? = nil) throws -> Data {
        try PDFium.sync {
            writeBuffer = Data()
            var writer = FPDF_FILEWRITE(version: 1, WriteBlock: writeBlock)
            let flags: UInt = removeSecurity ? 3 : 2
            let saved: Int32
            if let version {
                saved = FPDF_SaveWithVersion(handle, &writer, flags, Int32(version))
            } else {
                saved = FPDF_SaveAsCopy(handle, &writer, flags)
            }
            let result = writeBuffer
            writeBuffer = Data()
            guard saved != 0, !result.isEmpty else { throw ToolError("PDF kaydedilemedi.") }
            return result
        }
    }

    static func geometry(_ page: FPDF_PAGE) -> PageGeometry {
        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
        if FPDFPage_GetCropBox(page, &left, &bottom, &right, &top) == 0 {
            if FPDFPage_GetMediaBox(page, &left, &bottom, &right, &top) == 0 {
                left = 0
                bottom = 0
                right = 612
                top = 792
            }
        }
        let box = CGRect(x: CGFloat(min(left, right)), y: CGFloat(min(bottom, top)),
                         width: CGFloat(abs(right - left)), height: CGFloat(abs(top - bottom)))
        let rotation = Int(FPDFPage_GetRotation(page))
        return PageGeometry(box: box, rotation: ((rotation % 4) + 4) % 4)
    }

    func geometry(page index: Int) throws -> PageGeometry {
        try withPage(index) { PDFiumDocument.geometry($0) }
    }

    /// Sayfaların görünür yüzüne çizer. Çizim UIKit koordinatlarındadır (sol üst köşe, y aşağı).
    /// Çizim gerçek PDF içeriği (vektör, gömülü yazı tipi) olarak eklenir; notlar ve formlar korunur.
    func stamp(pages: [Int], under: Bool = false, draw: (_ page: Int, _ size: CGSize, _ context: CGContext) -> Void) throws {
        guard !pages.isEmpty else { return }
        let geometries = try pages.map { try geometry(page: $0) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let overlayData = renderer.pdfData { context in
            for (k, index) in pages.enumerated() {
                let size = geometries[k].visualSize
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                draw(index, size, context.cgContext)
            }
        }
        let overlay = try PDFiumDocument(data: overlayData)
        try PDFium.sync {
            for (k, index) in pages.enumerated() {
                guard let xobject = FPDF_NewXObjectFromPage(handle, overlay.handle, Int32(k)) else {
                    throw ToolError("Sayfa \(index + 1) için katman oluşturulamadı.")
                }
                defer { FPDF_CloseXObject(xobject) }
                guard let page = FPDF_LoadPage(handle, Int32(index)) else {
                    throw ToolError("Sayfa \(index + 1) açılamadı.")
                }
                defer { FPDF_ClosePage(page) }
                guard let form = FPDF_NewFormObjectFromXObject(xobject) else {
                    throw ToolError("Sayfa \(index + 1) için katman eklenemedi.")
                }
                var matrix = geometries[k].overlayMatrix
                _ = FPDFPageObj_SetMatrix(form, &matrix)
                if under {
                    _ = FPDFPage_InsertObjectAtIndex(page, form, 0)
                } else {
                    FPDFPage_InsertObject(page, form)
                }
                guard FPDFPage_GenerateContent(page) != 0 else {
                    throw ToolError("Sayfa \(index + 1) güncellenemedi.")
                }
            }
        }
    }

    /// Sayfayı görünür haliyle (notlar dahil) çizer. scale: nokta başına piksel (dpi / 72).
    func render(page index: Int, scale: CGFloat, grayscale: Bool = false) throws -> CGImage {
        try withPage(index) { page in
            var factor = scale
            let pageWidth = CGFloat(FPDF_GetPageWidthF(page)), pageHeight = CGFloat(FPDF_GetPageHeightF(page))
            let maxPixels: CGFloat = 50_000_000
            if pageWidth * pageHeight * factor * factor > maxPixels {
                factor = sqrt(maxPixels / max(1, pageWidth * pageHeight))
            }
            let width = max(1, Int((pageWidth * factor).rounded()))
            let height = max(1, Int((pageHeight * factor).rounded()))
            guard let bitmap = FPDFBitmap_Create(Int32(width), Int32(height), 0) else {
                throw ToolError("Sayfa \(index + 1) çizilemedi (bellek yetersiz).")
            }
            defer { FPDFBitmap_Destroy(bitmap) }
            _ = FPDFBitmap_FillRect(bitmap, 0, 0, Int32(width), Int32(height), 0xFFFFFFFF)
            // 0x01: notları çiz, 0x08: gri tonlama
            FPDF_RenderPageBitmap(bitmap, page, 0, 0, Int32(width), Int32(height), 0, grayscale ? 0x09 : 0x01)
            let stride = Int(FPDFBitmap_GetStride(bitmap))
            guard let buffer = FPDFBitmap_GetBuffer(bitmap) else { throw ToolError("Sayfa çizilemedi.") }
            let data = Data(bytes: buffer, count: stride * height)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw ToolError("Sayfa görüntüsü oluşturulamadı.")
            }
            return image
        }
    }

    /// Sayfadaki metin, satırlar halinde ve görünür koordinatlarla.
    func text(page index: Int) throws -> PageText {
        try withPage(index) { page in
            let geometry = PDFiumDocument.geometry(page)
            guard let textPage = FPDFText_LoadPage(page) else {
                return PageText(size: geometry.visualSize, lines: [])
            }
            defer { FPDFText_ClosePage(textPage) }
            var lines: [TextLine] = []
            var current = ""
            var rect = CGRect.null
            var size = 0.0
            var boxes: [CGRect] = []
            var style: (bold: Bool, italic: Bool, color: String)?
            func flush() {
                // Baştaki ve sondaki boşlukları, karakter kutularıyla hizalı kalacak şekilde at.
                let scalars = Array(current.unicodeScalars)
                var start = 0, end = scalars.count
                while start < end, scalars[start].properties.isWhitespace { start += 1 }
                while end > start, scalars[end - 1].properties.isWhitespace { end -= 1 }
                if start < end {
                    let text = String(String.UnicodeScalarView(scalars[start..<end]))
                    var line = TextLine(text: text, rect: rect, fontSize: size, chars: Array(boxes[start..<end]))
                    if let style {
                        line.bold = style.bold
                        line.italic = style.italic
                        line.color = style.color
                    }
                    lines.append(line)
                }
                current = ""
                rect = .null
                size = 0
                boxes = []
                style = nil
            }
            let count = Int(FPDFText_CountChars(textPage))
            for i in 0..<count {
                let code = FPDFText_GetUnicode(textPage, Int32(i))
                if code == 0x0D || code == 0x0A {
                    flush()
                    continue
                }
                guard let scalar = Unicode.Scalar(code), code != 0xFFFE, code != 0xFFFF else { continue }
                current.unicodeScalars.append(scalar)
                var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
                var charRect = CGRect.null
                if FPDFText_GetCharBox(textPage, Int32(i), &left, &right, &bottom, &top) != 0 {
                    charRect = geometry.visual(left: left, bottom: bottom, right: right, top: top)
                    if scalar != " " { rect = rect.union(charRect) }
                }
                boxes.append(charRect)
                if style == nil, !scalar.properties.isWhitespace {
                    var flags: Int32 = 0
                    let nameLength = FPDFText_GetFontInfo(textPage, Int32(i), nil, 0, &flags)
                    var name = ""
                    if nameLength > 0 {
                        var buffer = [UInt8](repeating: 0, count: Int(nameLength))
                        _ = FPDFText_GetFontInfo(textPage, Int32(i), &buffer, nameLength, &flags)
                        name = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).lowercased()
                    }
                    var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
                    let hasColor = FPDFText_GetFillColor(textPage, Int32(i), &r, &g, &b, &a) != 0
                    style = (bold: FPDFText_GetFontWeight(textPage, Int32(i)) >= 600 || name.contains("bold") || name.contains("black"),
                             italic: flags & 0x40 != 0 || name.contains("italic") || name.contains("oblique"),
                             color: hasColor ? String(format: "#%02x%02x%02x", r, g, b) : "#000000")
                }
                // Yazı boyutu bazı üreticilerde metin matrisinde durur; yazı tipi metrikli kutudan da tahmin et.
                var loose = FS_RECTF(left: 0, top: 0, right: 0, bottom: 0)
                if scalar != " ", FPDFText_GetLooseCharBox(textPage, Int32(i), &loose) != 0 {
                    size = max(size, Double(abs(loose.top - loose.bottom)) / 1.2)
                }
                size = max(size, FPDFText_GetFontSize(textPage, Int32(i)))
            }
            flush()
            return PageText(size: geometry.visualSize, lines: lines)
        }
    }
}

/// PDFium sayfa içeriğini yeniden yazarken yazı tiplerini (alt küme etiketi atılmış BaseFont, tür) çiftiyle eşler.
/// Aynı yazı tipinin iki alt kümesi (ör. CoreGraphics'in "ş" gibi karakterler için açtığı ikinci TrueType alt kümesi)
/// böylece tek kaynağa düşer ve yeniden yazılan sayfada metin bozulur. Yüklemeden önce bu adlar aynı uzunlukta
/// benzersizleştirilir; nesne konumları değişmediği için xref geçerli kalır.
enum FontNames {
    private static let whitespace: Set<UInt8> = [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20]
    private static let delimiters: Set<UInt8> = whitespace.union(Array("()<>[]{}/%".utf8))
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)

    private struct Font {
        let object: Int
        let name: [UInt8]
        let tagged: Bool
        var ranges: [Range<Int>]
    }

    static func unique(_ data: Data) -> Data {
        let marker = Data("/BaseFont".utf8)
        var fonts: [String: [Font]] = [:]
        var names = Set<[UInt8]>()
        var cursor = data.startIndex
        while let found = data.range(of: marker, in: cursor..<data.endIndex) {
            cursor = found.upperBound
            guard let range = Self.name(after: found.upperBound, limit: data.endIndex, in: data),
                  let owner = Self.object(around: found.lowerBound, in: data),
                  let kind = Self.type(in: owner.body, of: data) else { continue }
            let full = [UInt8](data[range])
            let tagged = full.count > 7 && full[6] == 0x2B
            let base = Array(tagged ? full[7...] : full[...])
            names.insert(base)
            let key = String(decoding: base, as: UTF8.self) + "|" + kind
            if let index = fonts[key]?.firstIndex(where: { $0.object == owner.number }) {
                fonts[key]![index].ranges.append(range)
            } else {
                fonts[key, default: []].append(Font(object: owner.number, name: full, tagged: tagged, ranges: [range]))
            }
        }
        var output = data
        var changed = false
        for group in fonts.values where group.count > 1 {
            // Gömülü alt kümelerde ad yalnızca etikettir; değiştirmek görünümü etkilemez.
            for font in group.dropFirst() where font.tagged {
                var base = Array(font.name[7...])
                guard let last = base.indices.last else { continue }
                var unique = false
                for letter in alphabet {
                    base[last] = letter
                    if !names.contains(base) {
                        unique = true
                        break
                    }
                }
                guard unique else { continue }
                names.insert(base)
                let renamed = Array(font.name[..<7]) + base
                for range in font.ranges { output.replaceSubrange(range, with: renamed) }
                changed = true
            }
        }
        return changed ? output : data
    }

    /// `/Ad` biçimindeki adın bayt aralığı (baştaki boşluklar atlanır).
    private static func name(after index: Int, limit: Int, in data: Data) -> Range<Int>? {
        var start = index
        while start < limit, whitespace.contains(data[start]) { start += 1 }
        guard start < limit, data[start] == 0x2F else { return nil }
        start += 1
        var end = start
        while end < limit, !delimiters.contains(data[end]) { end += 1 }
        return end > start ? start..<end : nil
    }

    /// Konumu içeren dolaylı nesnenin numarası ve gövdesi ("N G obj" … "endobj").
    private static func object(around index: Int, in data: Data) -> (number: Int, body: Range<Int>)? {
        let lower = max(data.startIndex, index - 4096)
        guard let obj = data.range(of: Data("obj".utf8), options: .backwards, in: lower..<index) else { return nil }
        if obj.lowerBound - data.startIndex >= 3, data[(obj.lowerBound - 3)..<obj.lowerBound].elementsEqual("end".utf8) {
            return nil
        }
        var i = obj.lowerBound - 1
        func skip() {
            while i >= data.startIndex, whitespace.contains(data[i]) { i -= 1 }
        }
        func digits() -> Int? {
            var value = 0, scale = 1, count = 0
            while i >= data.startIndex, data[i] >= 0x30, data[i] <= 0x39, count < 10 {
                value += Int(data[i] - 0x30) * scale
                scale *= 10
                count += 1
                i -= 1
            }
            return count > 0 ? value : nil
        }
        skip()
        guard digits() != nil else { return nil }
        skip()
        guard let number = digits() else { return nil }
        let upper = min(data.endIndex, index + 4096)
        let end = data.range(of: Data("endobj".utf8), in: index..<upper)?.lowerBound ?? upper
        return (number, obj.upperBound..<end)
    }

    /// PDFium'un yazı tipi eşlemesinde kullandığı tür; yalnızca etiketi atılan basit yazı tipleri.
    private static func type(in body: Range<Int>, of data: Data) -> String? {
        guard let found = data.range(of: Data("/Subtype".utf8), in: body),
              let range = name(after: found.upperBound, limit: body.upperBound, in: data) else { return nil }
        switch String(decoding: data[range], as: UTF8.self) {
        case "Type1", "MMType1": return "Type1"
        case "TrueType": return "TrueType"
        default: return nil
        }
    }
}
