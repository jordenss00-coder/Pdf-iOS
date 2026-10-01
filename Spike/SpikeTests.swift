// Teknik deneme: iOS'ta PDFKit, PDFium, Vision ve WebKit ile neyin yapılabildiğini ölçer.
// Her ölçüm "SPIKE|ad|OK/NO/INFO|ayrıntı" satırı yazar; CI bu satırları rapora dönüştürür.
// Olumsuz sonuç testi düşürmez; yalnızca entegrasyon hataları (ör. PDFium açılmaması) düşürür.
import PDFKit
import PDFium
import UIKit
import Vision
import WebKit
import XCTest

private let pdfiumReady: Void = FPDF_InitLibrary()
private var pdfiumOutput = Data()

func report(_ name: String, _ status: String, _ detail: String) {
    let clean = detail.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ⏎ ")
    print("SPIKE|\(name)|\(status)|\(clean.prefix(500))")
}

func normalized(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// 1 = aynı, 0 = tamamen farklı (Levenshtein, karakter bazında).
func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(normalized(a)), y = Array(normalized(b))
    guard !x.isEmpty, !y.isEmpty else { return x.count == y.count ? 1 : 0 }
    var row = Array(0...y.count)
    for i in 1...x.count {
        var diag = row[0]
        row[0] = i
        for j in 1...y.count {
            let up = row[j]
            row[j] = x[i - 1] == y[j - 1] ? diag : min(diag, row[j - 1], up) + 1
            diag = up
        }
    }
    return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
}

func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
func kb(_ bytes: Int) -> String { bytes < 0 ? "hata" : "\(bytes / 1024)KB" }
func temp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }

enum Sample {
    static let turkish = "Ağaç, şeker ve ılık süt; İstanbul'da güzel bir gün. ÇĞİÖŞÜ çğıöşü"

    static func textPDF(_ text: String = turkish) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            context.beginPage()
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 18)])
                .draw(in: CGRect(x: 50, y: 80, width: 495, height: 200))
        }
    }

    static func textImage(_ text: String = turkish) -> UIImage {
        let size = CGSize(width: 1800, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 44),
                                                          .foregroundColor: UIColor.black])
                .draw(in: CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80))
        }
    }

    /// Fotoğraf benzeri, iyi sıkışmayan büyük görsel.
    static func noisyImage() -> UIImage {
        let size = CGSize(width: 2400, height: 3200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in stride(from: 0, to: Int(size.height), by: 8) {
                for x in stride(from: 0, to: Int(size.width), by: 8) {
                    UIColor(hue: CGFloat((x + y) % 360) / 360, saturation: 0.6,
                            brightness: CGFloat.random(in: 0.5...1), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
    }
}

func pdfiumText(_ page: FPDF_PAGE) -> String {
    guard let textPage = FPDFText_LoadPage(page) else { return "" }
    defer { FPDFText_ClosePage(textPage) }
    let count = FPDFText_CountChars(textPage)
    guard count > 0 else { return "" }
    var buffer = [UInt16](repeating: 0, count: Int(count) + 1)
    let written = FPDFText_GetText(textPage, 0, count, &buffer)
    return String(decoding: buffer.prefix(max(Int(written) - 1, 0)), as: UTF16.self)
}

func firstMatch(_ pattern: String, in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return "-" }
    return String(text[range])
}

/// WKWebView'e belge yükleyip yazdırma ya da anlık görüntü yoluyla PDF üretir.
@MainActor
final class WebPDF: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100))
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        web.navigationDelegate = self
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first?.addSubview(web)
    }

    func load(file url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    /// Sayfalara bölünmüş A4 PDF (yazdırma altyapısı).
    func printedPDF() -> Data {
        let renderer = A4Renderer()
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, A4Renderer.paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// Görünen içeriğin tek parça PDF'i.
    func snapshotPDF() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            web.createPDF(configuration: WKPDFConfiguration()) { continuation.resume(with: $0) }
        }
    }

    func close() {
        web.removeFromSuperview()
    }
}

final class A4Renderer: UIPrintPageRenderer {
    static let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    override var paperRect: CGRect { Self.paper }
    override var printableRect: CGRect { Self.paper.insetBy(dx: 36, dy: 36) }
}

final class SpikeTests: XCTestCase {
    override func setUp() {
        executionTimeAllowance = 120
    }

    func test01_TurkishTextRoundTrip() {
        let text = PDFDocument(data: Sample.textPDF())?.string ?? ""
        let nbsp = text.contains("\u{00A0}")
        let score = similarity(text, Sample.turkish)
        report("turkce-metin-pdfkit", score > 0.98 && !nbsp ? "OK" : "NO",
               "benzerlik=\(fmt(score)) bolunmez-bosluk=\(nbsp) metin=\(text)")
    }

    func test02_PDFiumTextRenderEdit() throws {
        _ = pdfiumReady
        let source = Sample.textPDF() as NSData
        guard let doc = FPDF_LoadMemDocument(source.bytes, Int32(source.length), nil) else {
            report("pdfium-acma", "NO", "FPDF_GetLastError=\(FPDF_GetLastError())")
            XCTFail("PDFium belgeyi açamadı")
            return
        }
        defer { FPDF_CloseDocument(doc) }
        guard let page = FPDF_LoadPage(doc, 0) else {
            XCTFail("PDFium sayfayı açamadı")
            return
        }
        let text = pdfiumText(page)
        let score = similarity(text, Sample.turkish)
        report("pdfium-metin", score > 0.98 ? "OK" : "NO",
               "sayfa=\(FPDF_GetPageCount(doc)) benzerlik=\(fmt(score)) metin=\(text)")

        let width: Int32 = 595, height: Int32 = 842
        if let bitmap = FPDFBitmap_Create(width, height, 0) {
            _ = FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF)
            FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0)
            let rowBytes = Int(FPDFBitmap_GetStride(bitmap))
            let pixels = FPDFBitmap_GetBuffer(bitmap)!.assumingMemoryBound(to: UInt8.self)
            var dark = 0
            for y in 0..<Int(height) {
                for x in 0..<Int(width) where pixels[y * rowBytes + x * 4] < 128 {
                    dark += 1
                }
            }
            FPDFBitmap_Destroy(bitmap)
            report("pdfium-cizim", dark > 500 ? "OK" : "NO", "koyu piksel=\(dark)")
        } else {
            report("pdfium-cizim", "NO", "bitmap oluşturulamadı")
        }

        // Gerçek karartmanın temeli: metin nesnelerini içerikten silip kaydetmek.
        var removed = 0
        var index = FPDFPage_CountObjects(page) - 1
        while index >= 0 {
            if let object = FPDFPage_GetObject(page, index), FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
               FPDFPage_RemoveObject(page, object) != 0 {
                FPDFPageObj_Destroy(object)
                removed += 1
            }
            index -= 1
        }
        let generated = FPDFPage_GenerateContent(page) != 0
        FPDF_ClosePage(page)
        pdfiumOutput = Data()
        var writer = FPDF_FILEWRITE(version: 1, WriteBlock: { _, data, size in
            guard let data else { return 0 }
            pdfiumOutput.append(data.assumingMemoryBound(to: UInt8.self), count: Int(size))
            return 1
        })
        let saved = FPDF_SaveAsCopy(doc, &writer, 2 /* FPDF_NO_INCREMENTAL */) != 0
        let after = PDFDocument(data: pdfiumOutput)?.string ?? ""
        report("pdfium-duzenle-kaydet", saved && removed > 0 && normalized(after).isEmpty ? "OK" : "NO",
               "silinen metin nesnesi=\(removed) icerik=\(generated) kaydedildi=\(saved) boyut=\(kb(pdfiumOutput.count)) kalan metin='\(after)'")
        XCTAssertTrue(saved, "PDFium kaydedemedi")
    }

    func test03_PDFKitEncryption() throws {
        let doc = PDFDocument(data: Sample.textPDF())!
        let url = temp("sifreli.pdf")
        let written = doc.write(to: url, withOptions: [.userPasswordOption: "kullanici", .ownerPasswordOption: "sahip"])
        let raw = try Data(contentsOf: url)
        let text = String(data: raw, encoding: .isoLatin1) ?? ""
        var snippet = "şifreleme sözlüğü düz metinde bulunamadı"
        if let range = text.range(of: "/Standard") {
            let start = text.index(range.lowerBound, offsetBy: -250, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            snippet = String(text[start..<end].map { (char: Character) -> Character in
                let visible = char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol || char == " "
                return char.isASCII && visible ? char : "."
            })
        }
        let reopened = PDFDocument(url: url)
        let locked = reopened?.isLocked ?? false
        let unlocked = reopened?.unlock(withPassword: "kullanici") ?? false
        report("pdfkit-sifreleme", written && locked && unlocked ? "OK" : "NO",
               "V=\(firstMatch("/V\\s*(\\d+)", in: snippet)) R=\(firstMatch("/R\\s*(\\d+)", in: snippet)) " +
               "Length=\(firstMatch("/Length\\s*(\\d+)", in: snippet)) AES=\(firstMatch("(AESV\\d)", in: snippet)) " +
               "kilitli=\(locked) acildi=\(unlocked) sozluk=\(snippet)")
    }

    func test04_PDFKitCompression() throws {
        // Taranmış belge gibi: A4 sayfada yaklaşık 290 dpi görsel.
        let image = Sample.noisyImage()
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        let source = UIGraphicsPDFRenderer(bounds: a4).pdfData { context in
            context.beginPage()
            image.draw(in: a4)
        }
        let doc = PDFDocument(data: source)!
        func size(_ options: [PDFDocumentWriteOption: Any]) -> Int {
            let url = temp(UUID().uuidString + ".pdf")
            guard doc.write(to: url, withOptions: options) else { return -1 }
            return (try? Data(contentsOf: url).count) ?? -1
        }
        let plain = size([:])
        let jpeg = size([.saveImagesAsJPEGOption: true])
        let screen = size([.optimizeImagesForScreenOption: true])
        let both = size([.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        report("pdfkit-sikistirma", both > 0 && both < plain ? "OK" : "NO",
               "kaynak=\(kb(source.count)) normal=\(kb(plain)) jpeg=\(kb(jpeg)) ekran=\(kb(screen)) ikisi=\(kb(both))")
    }

    func test05_PDFKitFlatten() throws {
        let doc = PDFDocument(data: Sample.textPDF("Düzleştirme deneme"))!
        let page = doc.page(at: 0)!
        let note = PDFAnnotation(bounds: CGRect(x: 60, y: 600, width: 320, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Serbest not ğüş"
        note.font = UIFont.systemFont(ofSize: 16)
        note.fontColor = .black
        note.color = .clear
        page.addAnnotation(note)
        let field = PDFAnnotation(bounds: CGRect(x: 60, y: 540, width: 320, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "ad"
        field.widgetStringValue = "Form değeri İĞÜ"
        page.addAnnotation(field)
        let url = temp("duzlestirilmis.pdf")
        let written = doc.write(to: url, withOptions: [.burnInAnnotationsOption: true])
        let reopened = PDFDocument(url: url)
        let remaining = reopened?.page(at: 0)?.annotations.count ?? -1
        report("pdfkit-duzlestirme", written && remaining == 0 ? "OK" : "NO",
               "kalan not=\(remaining) metin=\(reopened?.string ?? "")")
    }

    func test06_VisionTurkishOCR() throws {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        let languages = try request.supportedRecognitionLanguages()
        let turkish = languages.first { $0.lowercased().hasPrefix("tr") }
        report("vision-diller", turkish != nil ? "OK" : "NO", languages.joined(separator: ","))
        request.recognitionLanguages = turkish.map { [$0] } ?? ["en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: Sample.textImage().cgImage!, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Bazı simülatörlerde sinir motoru yok; işlemciyle tekrar dene.
            report("vision-ilk-deneme", "INFO", "hata: \(error)")
            request.usesCPUOnly = true
            try handler.perform([request])
        }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let score = similarity(text, Sample.turkish)
        report("vision-turkce-ocr", score > 0.95 ? "OK" : "NO",
               "dil=\(request.recognitionLanguages) benzerlik=\(fmt(score)) metin=\(text)")
    }

    func test07_PDFKitOCRTextLayer() throws {
        let doc = PDFDocument()
        doc.insert(PDFPage(image: Sample.textImage())!, at: 0)
        let url = temp("ocr.pdf")
        let written = doc.write(to: url, withOptions: [.saveTextFromOCROption: true])
        let text = PDFDocument(url: url)?.string ?? ""
        let score = similarity(text, Sample.turkish)
        report("pdfkit-ocr-katmani", written && score > 0.9 ? "OK" : "NO", "benzerlik=\(fmt(score)) metin=\(text)")
    }

    @MainActor
    func test08_HTMLToPDF() async throws {
        let page = WebPDF()
        defer { page.close() }
        try await page.load(html: "<html><head><meta charset='utf-8'></head><body><h1>PDF Atölye HTML deneme</h1><p>\(Sample.turkish)</p></body></html>")
        let doc = PDFDocument(data: page.printedPDF())
        let text = doc?.string ?? ""
        report("html-pdf", normalized(text).contains("HTML deneme") ? "OK" : "NO",
               "sayfa=\(doc?.pageCount ?? 0) metin=\(text)")
    }

    @MainActor
    func test09_OfficeToPDF() async throws {
        for (ext, marker) in [("docx", "Word deneme"), ("xlsx", "Excel deneme"), ("pptx", "PowerPoint deneme")] {
            guard let url = Bundle(for: SpikeTests.self).url(forResource: "ornek", withExtension: ext) else {
                report("office-\(ext)", "NO", "örnek dosya test paketinde yok")
                continue
            }
            let page = WebPDF()
            do {
                try await page.load(file: url)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let printed = PDFDocument(data: page.printedPDF())
                let snapshot = PDFDocument(data: try await page.snapshotPDF())
                let printedText = printed?.string ?? "", snapshotText = snapshot?.string ?? ""
                let found = normalized(printedText).contains(marker) || normalized(snapshotText).contains(marker)
                report("office-\(ext)", found ? "OK" : "NO",
                       "yazdirma: sayfa=\(printed?.pageCount ?? 0) metin=\(printedText.prefix(120)) | " +
                       "goruntu: sayfa=\(snapshot?.pageCount ?? 0) metin=\(snapshotText.prefix(120))")
            } catch {
                report("office-\(ext)", "NO", "hata: \(error)")
            }
            page.close()
        }
    }
}
