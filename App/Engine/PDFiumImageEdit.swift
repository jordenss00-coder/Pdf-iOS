import CoreGraphics
import Foundation
import ImageIO
import PDFium
import UniformTypeIdentifiers

/// FPDF_FILEACCESS için bellekteki veri kaynağı.
private final class MemorySource {
    let data: Data
    init(_ data: Data) { self.data = data }
}

private func readBlock(_ param: UnsafeMutableRawPointer?, _ position: UInt, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: UInt) -> Int32 {
    guard let param, let buffer else { return 0 }
    let source = Unmanaged<MemorySource>.fromOpaque(param).takeUnretainedValue()
    let start = Int(position), count = Int(size)
    guard start >= 0, start + count <= source.data.count else { return 0 }
    source.data.copyBytes(to: buffer, from: start..<(start + count))
    return 1
}

enum PDFiumImageEdit {
    /// Görsel nesnesinin içeriğini verilen JPEG verisiyle değiştirir (PDFium kilidi içinde çağrılmalı).
    static func replace(_ object: FPDF_PAGEOBJECT, on page: FPDF_PAGE, jpeg: Data) -> Bool {
        let source = MemorySource(jpeg)
        var access = FPDF_FILEACCESS(m_FileLen: UInt(jpeg.count), m_GetBlock: readBlock,
                                     m_Param: Unmanaged.passUnretained(source).toOpaque())
        var pages: [FPDF_PAGE?] = [page]
        let done = withExtendedLifetime(source) {
            FPDFImageObj_LoadJpegFileInline(&pages, 1, object, &access) != 0
        }
        return done
    }

    /// CGImage'ı en fazla verilen piksel boyutuna küçültür; isteğe bağlı gri tonlama.
    static func resized(_ image: CGImage, width: Int, height: Int, gray: Bool) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(gray ? CGColor(gray: 1, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    struct Level {
        let threshold: Double
        let target: Double
        let quality: Double
    }

    static let levels: [String: Level] = [
        "extreme": Level(threshold: 90, target: 72, quality: 0.35),
        "recommended": Level(threshold: 150, target: 110, quality: 0.6),
        "low": Level(threshold: 220, target: 180, quality: 0.82),
    ]

    struct Report {
        var found = 0
        var nested = 0
        var changed = 0
        var failed = 0
    }

    /// Sayfadaki yüksek çözünürlüklü görselleri küçültüp JPEG olarak yeniden kodlar.
    static func recompress(_ document: PDFiumDocument, level: Level, gray: Bool) throws -> Report {
        var report = Report()
        for index in 0..<document.pageCount {
            try document.withPage(index) { page in
                var count = 0
                for k in 0..<FPDFPage_CountObjects(page) {
                    guard let object = FPDFPage_GetObject(page, k) else { continue }
                    if FPDFPageObj_GetType(object) == 5 {
                        report.nested += nestedImages(object)
                        continue
                    }
                    guard FPDFPageObj_GetType(object) == 3 else { continue }
                    report.found += 1
                    var pixelWidth: UInt32 = 0, pixelHeight: UInt32 = 0
                    guard FPDFImageObj_GetImagePixelSize(object, &pixelWidth, &pixelHeight) != 0, pixelWidth > 8, pixelHeight > 8 else { continue }
                    var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                    guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0, right > left, top > bottom else { continue }
                    let dpi = Double(pixelWidth) / (Double(right - left) / 72)
                    guard dpi > level.threshold || gray else { continue }
                    guard let bitmap = FPDFImageObj_GetBitmap(object) else { continue }
                    defer { FPDFBitmap_Destroy(bitmap) }
                    // Saydamlığı olan (BGRA) görseller JPEG'e çevrilmez.
                    guard FPDFBitmap_GetFormat(bitmap) != 4, let image = PDFiumImages.cgImage(bitmap) else { continue }
                    let scale = dpi > level.threshold ? min(1, level.target / dpi) : 1
                    let width = Int((Double(pixelWidth) * scale).rounded()), height = Int((Double(pixelHeight) * scale).rounded())
                    guard let smaller = resized(image, width: width, height: height, gray: gray),
                          let jpeg = try? ImageCoding.encode(smaller, as: .jpeg, quality: level.quality) else { continue }
                    let original = FPDFImageObj_GetImageDataRaw(object, nil, 0)
                    guard UInt(jpeg.count) < original || gray else { continue }
                    if replace(object, on: page, jpeg: jpeg) { count += 1 } else { report.failed += 1 }
                }
                if count > 0 { _ = FPDFPage_GenerateContent(page) }
                report.changed += count
            }
        }
        return report
    }

    /// Form nesnesi içindeki görsel sayısı (iç içe dahil).
    static func nestedImages(_ form: FPDF_PAGEOBJECT) -> Int {
        var total = 0
        for k in 0..<FPDFFormObj_CountObjects(form) {
            guard let child = FPDFFormObj_GetObject(form, UInt(k)) else { continue }
            switch FPDFPageObj_GetType(child) {
            case 3: total += 1
            case 5: total += nestedImages(child)
            default: break
            }
        }
        return total
    }

    /// Metin ve çizim renklerini griye çevirir. Gri yapılamayan içerik (form nesneleri, gölgelendirmeler)
    /// varsa false döner; bu sayfalar görüntü olarak griye çevrilir.
    static func grayscaleVector(_ page: FPDF_PAGE) -> Bool {
        var complete = true
        var dirty = false
        for k in 0..<FPDFPage_CountObjects(page) {
            guard let object = FPDFPage_GetObject(page, k) else { continue }
            switch FPDFPageObj_GetType(object) {
            case 1, 2:
                var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
                if FPDFPageObj_GetFillColor(object, &r, &g, &b, &a) != 0, !(r == g && g == b) {
                    let y = luminance(r, g, b)
                    _ = FPDFPageObj_SetFillColor(object, y, y, y, a)
                    dirty = true
                }
                if FPDFPageObj_GetStrokeColor(object, &r, &g, &b, &a) != 0, !(r == g && g == b) {
                    let y = luminance(r, g, b)
                    _ = FPDFPageObj_SetStrokeColor(object, y, y, y, a)
                    dirty = true
                }
            case 3:
                guard let bitmap = FPDFImageObj_GetBitmap(object) else { continue }
                defer { FPDFBitmap_Destroy(bitmap) }
                if FPDFBitmap_GetFormat(bitmap) == 1 { continue }
                guard FPDFBitmap_GetFormat(bitmap) != 4, let image = PDFiumImages.cgImage(bitmap),
                      let gray = resized(image, width: image.width, height: image.height, gray: true),
                      let jpeg = try? ImageCoding.encode(gray, as: .jpeg, quality: 0.85),
                      replace(object, on: page, jpeg: jpeg) else {
                    complete = false
                    continue
                }
                dirty = true
            default:
                complete = false
            }
        }
        if dirty { _ = FPDFPage_GenerateContent(page) }
        return complete
    }

    private static func luminance(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 {
        let red: Double = 0.299 * Double(r)
        let green: Double = 0.587 * Double(g)
        let blue: Double = 0.114 * Double(b)
        return UInt32((red + green + blue).rounded())
    }
}
