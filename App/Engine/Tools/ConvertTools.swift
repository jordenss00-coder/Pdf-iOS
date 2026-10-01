import ImageIO
import PDFKit
import PDFium
import UIKit
import UniformTypeIdentifiers
import WebKit

enum ImageCoding {
    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.9, dpi: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ToolError("Görsel kaydedilemedi.")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError("Görsel kaydedilemedi.") }
        return data as Data
    }
}

enum ImageConverter {
    struct Frame {
        let image: UIImage
        /// Nokta (pt) cinsinden boyut
        let size: CGSize
    }

    /// Görsel dosyasının tüm karelerini (GIF/TIFF) yönü düzeltilmiş olarak yükler.
    static func frames(_ url: URL) throws -> [Frame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("'\(url.lastPathComponent)' açılamadı.")
        }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let keepsData = type?.conforms(to: .jpeg) == true
        var frames: [Frame] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard var cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 96
            if dpi < 30 || dpi > 1200 { dpi = 96 }
            let exif = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
            // JPEG dışındaki fotoğrafları (HEIC vb.) saydamlık yoksa JPEG'e çevir; PDF küçük kalsın.
            if !keepsData, !hasAlpha(cgImage), let jpeg = try? ImageCoding.encode(cgImage, as: .jpeg, quality: 0.92),
               let reloaded = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                cgImage = reloaded
            }
            let image = UIImage(cgImage: cgImage, scale: 1, orientation: UIImage.Orientation(exif))
            let pixels = image.size
            frames.append(Frame(image: image, size: CGSize(width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi)))
        }
        guard !frames.isEmpty else { throw ToolError("'\(url.lastPathComponent)' içinde görüntü yok.") }
        return frames
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    /// Görselleri seçeneklere göre (sayfa boyutu, yön, kenar boşluğu) PDF'e yerleştirir.
    static func pdf(from urls: [URL], options: OptionValues, enhance: ((UIImage) -> UIImage)? = nil) throws -> Data {
        var frames: [Frame] = []
        for url in urls {
            frames += try self.frames(url)
        }
        return pdf(frames: frames, options: options, enhance: enhance)
    }

    static func pdf(frames: [Frame], options: OptionValues, enhance: ((UIImage) -> UIImage)? = nil) -> Data {
        let pageSize = options.string("page_size", "fit")
        let orientation = options.string("orientation", "auto")
        let margins: [String: CGFloat] = ["small": 20, "big": 40]
        let margin = margins[options.string("margin", "none")] ?? 0
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for frame in frames {
                let image = enhance?(frame.image) ?? frame.image
                // İyileştirme (kırpma) görüntü oranını değiştirebilir; genişlik korunur.
                let size = CGSize(width: frame.size.width, height: frame.size.width * image.size.height / max(1, image.size.width))
                let sheet: CGSize
                if pageSize == "fit" {
                    sheet = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
                } else {
                    let landscape = orientation == "auto" ? size.width > size.height : orientation == "landscape"
                    sheet = Paper.size(pageSize, landscape: landscape)
                }
                let bounds = CGRect(origin: .zero, size: sheet)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: Layout.aspectFit(image.size, in: bounds.insetBy(dx: margin, dy: margin)))
            }
        }
    }
}

extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        case .left: self = .left
        default: self = .up
        }
    }
}

/// Office, HTML ve web sayfalarını Apple'ın web motoruyla sayfalanmış A4 PDF'e çevirir.
@MainActor
final class OfficeConverter: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: CGRect(x: -10_000, y: 0, width: 800, height: 1100))
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        web.navigationDelegate = self
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first?.addSubview(web)
    }

    static func pdf(from url: URL) async throws -> Data {
        let converter = OfficeConverter()
        defer { converter.web.removeFromSuperview() }
        try await converter.load { $0.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        try await Task.sleep(nanoseconds: 700_000_000)
        return try converter.printed(name: url.lastPathComponent, header: nil)
    }

    static func pdf(fromHTMLFile url: URL, headerFooter: Bool) async throws -> Data {
        try await pdf(fromRequest: nil, file: url, headerFooter: headerFooter)
    }

    static func pdf(fromWeb address: URL, headerFooter: Bool) async throws -> Data {
        try await pdf(fromRequest: URLRequest(url: address, timeoutInterval: 40), file: nil, headerFooter: headerFooter)
    }

    private static func pdf(fromRequest request: URLRequest?, file: URL?, headerFooter: Bool) async throws -> Data {
        let converter = OfficeConverter()
        defer { converter.web.removeFromSuperview() }
        try await converter.load { web in
            if let file {
                web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            } else if let request {
                web.load(request)
            }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let address = request?.url?.absoluteString ?? file?.lastPathComponent ?? ""
        return try converter.printed(name: request?.url?.host ?? file?.lastPathComponent ?? "sayfa",
                                     header: headerFooter ? address : nil)
    }

    private func load(_ start: (WKWebView) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            start(web)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: ToolError("Sayfa yüklenemedi: \(error.localizedDescription)"))
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: ToolError("Sayfa yüklenemedi: \(error.localizedDescription)"))
        loaded = nil
    }

    private func printed(name: String, header: String?) throws -> Data {
        let renderer = A4PrintRenderer(header: header)
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, A4PrintRenderer.paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        let result = PDFCleanup.droppingTrailingBlankPages(data as Data)
        guard let document = PDFDocument(data: result), document.pageCount > 0 else {
            throw ToolError("'\(name)' PDF'e çevrilemedi.")
        }
        return result
    }
}

final class A4PrintRenderer: UIPrintPageRenderer {
    static let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let header: String?

    init(header: String?) {
        self.header = header
        super.init()
        if header != nil {
            headerHeight = 24
            footerHeight = 24
        }
    }

    override var paperRect: CGRect { Self.paper }
    override var printableRect: CGRect { Self.paper.insetBy(dx: 36, dy: 36) }

    override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
        guard let header else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
        (formatter.string(from: Date()) as NSString).draw(at: CGPoint(x: headerRect.minX, y: headerRect.minY + 6), withAttributes: attributes)
        let text = header as NSString
        let width = text.size(withAttributes: attributes).width
        text.draw(at: CGPoint(x: headerRect.maxX - min(width, headerRect.width * 0.7), y: headerRect.minY + 6), withAttributes: attributes)
    }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        guard header != nil else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
        let text = "\(pageIndex + 1) / \(numberOfPages)" as NSString
        let width = text.size(withAttributes: attributes).width
        text.draw(at: CGPoint(x: footerRect.midX - width / 2, y: footerRect.minY + 6), withAttributes: attributes)
    }
}

enum PDFCleanup {
    /// Yazdırmanın sona eklediği boş sayfaları siler.
    static func droppingTrailingBlankPages(_ data: Data) -> Data {
        guard let document = try? PDFiumDocument(data: data), document.pageCount > 1 else { return data }
        var drop = 0
        for index in stride(from: document.pageCount - 1, to: 0, by: -1) {
            guard isBlank(document, page: index) else { break }
            drop += 1
        }
        guard drop > 0, let kit = PDFDocument(data: data) else { return data }
        for _ in 0..<drop { kit.removePage(at: kit.pageCount - 1) }
        return kit.dataRepresentation() ?? data
    }

    static func isBlank(_ document: PDFiumDocument, page: Int) -> Bool {
        if let text = try? document.text(page: page), !text.lines.isEmpty { return false }
        guard let image = try? document.render(page: page, scale: 0.25),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        var index = 0
        while index < length {
            if bytes[index] < 245 { return false }
            index += 1
        }
        return true
    }
}

enum ConvertTools {
    static func imagesToPDF(_ c: ToolContext) async throws -> [URL] {
        if c.options.bool("merge", true) {
            let data = try ImageConverter.pdf(from: c.inputs.map(\.url), options: c.options)
            let url = c.out(c.inputs.count == 1 ? "\(stem(c.inputs[0].name)).pdf" : "gorseller.pdf")
            try data.write(to: url)
            return [url]
        }
        return try c.inputs.map { input in
            let url = c.out("\(stem(input.name)).pdf")
            try ImageConverter.pdf(from: [input.url], options: c.options).write(to: url)
            return url
        }
    }

    static func officeToPDF(_ c: ToolContext) async throws -> [URL] {
        var parts: [(URL, Data)] = []
        for (k, input) in c.inputs.enumerated() {
            c.progress(Double(k) / Double(c.inputs.count), input.name)
            let data = try await OfficeConverter.pdf(from: input.url)
            parts.append((c.out("\(stem(input.name)).pdf"), data))
        }
        if parts.count > 1 && c.options.bool("merge") {
            let output = PDFDocument()
            for (_, data) in parts {
                if let document = PDFDocument(data: data) {
                    PDFKitIO.copyPages(from: document, Array(0..<document.pageCount), into: output)
                }
            }
            let url = c.out("donusturulmus.pdf")
            try PDFKitIO.write(output, to: url)
            return [url]
        }
        for (url, data) in parts { try data.write(to: url) }
        return parts.map(\.0)
    }

    static func htmlToPDF(_ c: ToolContext) async throws -> [URL] {
        let headerFooter = c.options.bool("header_footer")
        var address = c.options.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            if address.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
                address = "https://" + address
            }
            guard let url = URL(string: address), let host = url.host else { throw ToolError("Web adresi geçersiz.") }
            let data = try await OfficeConverter.pdf(fromWeb: url, headerFooter: headerFooter)
            let output = c.out(host.replacingOccurrences(of: ".", with: "_") + ".pdf")
            try data.write(to: output)
            return [output]
        }
        guard !c.inputs.isEmpty else { throw ToolError("Bir web adresi yaz ya da HTML dosyası ekle.") }
        var urls: [URL] = []
        for input in c.inputs {
            let data = try await OfficeConverter.pdf(fromHTMLFile: input.url, headerFooter: headerFooter)
            let url = c.out("\(stem(input.name)).pdf")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func pdfToImages(_ c: ToolContext) async throws -> [URL] {
        let extract = c.options.string("mode", "pages") == "extract"
        let png = c.options.string("format", "jpg") == "png"
        let dpi = c.options.number("dpi", 150)
        var urls: [URL] = []
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            let base = stem(input.name)
            if extract {
                urls += try extractImages(document, base: base, context: c)
                continue
            }
            let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
            for (k, index) in pages.enumerated() {
                c.progress(Double(k) / Double(max(1, pages.count)), "Sayfa \(index + 1)")
                let image = try document.render(page: index, scale: dpi / 72)
                let url = c.out("\(base)_sayfa_\(index + 1).\(png ? "png" : "jpg")")
                try ImageCoding.encode(image, as: png ? .png : .jpeg, quality: 0.9, dpi: dpi).write(to: url)
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { throw ToolError("PDF'te çıkarılacak görsel bulunamadı.") }
        return urls
    }

    /// Gömülü görselleri çıkarır; JPEG olanları yeniden sıkıştırmadan, diğerlerini PNG olarak kaydeder.
    private static func extractImages(_ document: PDFiumDocument, base: String, context c: ToolContext) throws -> [URL] {
        var urls: [URL] = []
        var seen = Set<Int>()
        for index in 0..<document.pageCount {
            let found: [(Data, String)] = try document.withPage(index) { page in
                var items: [(Data, String)] = []
                for k in 0..<FPDFPage_CountObjects(page) {
                    guard let object = FPDFPage_GetObject(page, k), FPDFPageObj_GetType(object) == 3 else { continue }
                    var width: UInt32 = 0, height: UInt32 = 0
                    guard FPDFImageObj_GetImagePixelSize(object, &width, &height) != 0, width >= 32, height >= 32 else { continue }
                    let rawLength = FPDFImageObj_GetImageDataRaw(object, nil, 0)
                    guard rawLength > 0 else { continue }
                    var raw = [UInt8](repeating: 0, count: Int(rawLength))
                    _ = FPDFImageObj_GetImageDataRaw(object, &raw, rawLength)
                    var hasher = Hasher()
                    hasher.combine(raw.count)
                    hasher.combine(raw.prefix(4096))
                    guard seen.insert(hasher.finalize()).inserted else { continue }
                    if PDFiumImages.isPlainJPEG(object) {
                        items.append((Data(raw), "jpg"))
                    } else if let bitmap = FPDFImageObj_GetBitmap(object) {
                        defer { FPDFBitmap_Destroy(bitmap) }
                        if let image = PDFiumImages.cgImage(bitmap), let png = try? ImageCoding.encode(image, as: .png) {
                            items.append((png, "png"))
                        }
                    }
                }
                return items
            }
            for (data, ext) in found {
                let url = c.out("\(base)_s\(index + 1)_gorsel\(urls.count + 1).\(ext)")
                try data.write(to: url)
                urls.append(url)
            }
        }
        return urls
    }

    static func pdfToText(_ c: ToolContext) async throws -> [URL] {
        let html = c.options.string("format", "txt") == "html"
        var urls: [URL] = []
        for input in c.inputs {
            let document = try await c.pdf(input)
            let base = stem(input.name)
            var pages: [String] = []
            for index in 0..<document.pageCount {
                pages.append(document.page(at: index)?.string ?? "")
            }
            if html {
                let body = pages.enumerated().map { index, text in
                    let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
                    return "<section class=\"page\" data-page=\"\(index + 1)\">\n\(paragraphs)\n</section>"
                }.joined(separator: "\n")
                let page = """
                <!doctype html><html lang="tr"><head><meta charset="utf-8"><title>\(escapeHTML(base))</title>
                <style>body{max-width:900px;margin:2rem auto;font-family:system-ui;line-height:1.5}.page{border-bottom:1px solid #ccc;padding:1rem 0}</style>
                </head><body>
                \(body)
                </body></html>
                """
                let url = c.out("\(base).html")
                try page.write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            } else {
                let text = pages.enumerated().map { "--- Sayfa \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
                let url = c.out("\(base).txt")
                try ("\u{FEFF}" + text).write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
        }
        return urls
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
