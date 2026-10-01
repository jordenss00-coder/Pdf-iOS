import CoreGraphics
import Foundation
import PDFium

/// PDFium görsel nesneleri ve bit eşlemleri için yardımcılar (PDFium kilidi içinde çağrılmalı).
enum PDFiumImages {
    /// Görsel yalnızca DCTDecode (JPEG) ile kodlanmışsa ham verisi doğrudan .jpg dosyasıdır.
    static func isPlainJPEG(_ object: FPDF_PAGEOBJECT) -> Bool {
        guard FPDFImageObj_GetImageFilterCount(object) == 1 else { return false }
        let length = FPDFImageObj_GetImageFilter(object, 0, nil, 0)
        guard length > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: Int(length))
        _ = FPDFImageObj_GetImageFilter(object, 0, &buffer, length)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) == "DCTDecode"
    }

    /// PDFium bit eşlemini (gri, BGR, BGRx, BGRA) CGImage'a kopyalar.
    static func cgImage(_ bitmap: FPDF_BITMAP) -> CGImage? {
        let width = Int(FPDFBitmap_GetWidth(bitmap)), height = Int(FPDFBitmap_GetHeight(bitmap))
        let stride = Int(FPDFBitmap_GetStride(bitmap))
        guard width > 0, height > 0, let buffer = FPDFBitmap_GetBuffer(bitmap) else { return nil }
        let source = buffer.assumingMemoryBound(to: UInt8.self)
        switch FPDFBitmap_GetFormat(bitmap) {
        case 1:
            let data = Data(bytes: buffer, count: stride * height)
            return make(data, width: width, height: height, bitsPerPixel: 8, stride: stride,
                        space: CGColorSpaceCreateDeviceGray(), info: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
        case 2:
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let s = y * stride + x * 3, d = (y * width + x) * 4
                    bytes[d] = source[s]
                    bytes[d + 1] = source[s + 1]
                    bytes[d + 2] = source[s + 2]
                }
            }
            return make(Data(bytes), width: width, height: height, bitsPerPixel: 32, stride: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        info: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        case 3:
            return make(Data(bytes: buffer, count: stride * height), width: width, height: height, bitsPerPixel: 32, stride: stride,
                        space: CGColorSpaceCreateDeviceRGB(),
                        info: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        case 4:
            return make(Data(bytes: buffer, count: stride * height), width: width, height: height, bitsPerPixel: 32, stride: stride,
                        space: CGColorSpaceCreateDeviceRGB(),
                        info: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        default:
            return nil
        }
    }

    private static func make(_ data: Data, width: Int, height: Int, bitsPerPixel: Int, stride: Int,
                             space: CGColorSpace, info: CGBitmapInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel, bytesPerRow: stride,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
