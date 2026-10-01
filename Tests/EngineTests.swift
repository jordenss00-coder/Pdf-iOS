import PDFKit
import UIKit
import XCTest
@testable import PDFAtolye

/// Her aracı gerçek PDF'lerle çalıştırıp sonucu ölçer.
final class EngineTests: XCTestCase {
    override func setUp() {
        executionTimeAllowance = 180
    }

    // MARK: Yardımcılar

    static func samplePDF(pages: Int = 3, size: CGSize = CGSize(width: 595, height: 842), prefix: String = "Sayfa") -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                NSAttributedString(string: "\(prefix) \(page) – Türkçe ğüşıöç İĞÜŞÖÇ",
                                   attributes: [.font: UIFont.systemFont(ofSize: 18)])
                    .draw(at: CGPoint(x: 50, y: 80))
            }
        }
    }

    func input(_ data: Data, _ name: String = "ornek.pdf", kind: FileKind = .pdf) throws -> InputFile {
        try InputFile.saving(data, name: name, kind: kind)
    }

    func run(_ id: String, _ inputs: [InputFile], _ options: [String: OptionValue] = [:]) async throws -> ToolResult {
        let tool = try XCTUnwrap(Catalog.tool(id), id)
        var values = OptionValues(defaultsOf: tool.options)
        for (key, value) in options { values[key] = value }
        return try await Engine.run(tool: tool, inputs: inputs, options: values)
    }

    func pdf(_ url: URL) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(url: url), url.lastPathComponent)
    }

    func text(_ url: URL) throws -> String {
        try pdf(url).string ?? ""
    }

    // MARK: Katalog ve aralıklar

    func testCatalogHasAllDesktopTools() {
        XCTAssertEqual(Catalog.tools.count, 43)
        XCTAssertEqual(Set(Catalog.tools.map(\.id)).count, 43)
        XCTAssertEqual(Catalog.categories.count, 8)
    }

    func testPageRanges() throws {
        XCTAssertEqual(try PageRanges.groups("1-3, 5, 8-", count: 9), [[0, 1, 2], [4], [7, 8]])
        XCTAssertEqual(try PageRanges.pages("tek", count: 5), [0, 2, 4])
        XCTAssertEqual(try PageRanges.pages("çift", count: 5), [1, 3])
        XCTAssertEqual(try PageRanges.pages("son", count: 4), [3])
        XCTAssertEqual(try PageRanges.pages("3-1", count: 4), [2, 1, 0])
        XCTAssertEqual(try PageRanges.pages("", count: 2), [0, 1])
        XCTAssertThrowsError(try PageRanges.pages("7", count: 3))
        XCTAssertEqual(PageRanges.human([0, 1, 2, 4]), "1-3,5")
    }

    // MARK: Sayfalar

    func testMergeWithBookmarks() async throws {
        let result = try await run("merge", [try input(Self.samplePDF(pages: 2), "a.pdf"), try input(Self.samplePDF(pages: 3), "b.pdf")])
        let document = try pdf(result.files[0])
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 2)
        XCTAssertEqual(document.outlineRoot?.child(at: 1)?.label, "b")
    }

    func testSplitModes() async throws {
        let source = try input(Self.samplePDF(pages: 5))
        let ranges = try await run("split", [source], ["mode": .string("ranges"), "ranges": .string("1, 2-3, 5")])
        XCTAssertEqual(try ranges.files.map { try pdf($0).pageCount }, [1, 2, 1])
        let every = try await run("split", [source], ["mode": .string("every"), "every": .number(2)])
        XCTAssertEqual(try every.files.map { try pdf($0).pageCount }, [2, 2, 1])
        let all = try await run("split", [source], ["mode": .string("all")])
        XCTAssertEqual(all.files.count, 5)
        let merged = try await run("split", [source], ["mode": .string("ranges"), "ranges": .string("1, 4-5"), "merge_output": .bool(true)])
        XCTAssertEqual(try pdf(merged.files[0]).pageCount, 3)
        let size = try await run("split", [source], ["mode": .string("size"), "max_mb": .number(0.001)])
        XCTAssertEqual(size.files.count, 5)
    }

    func testSplitByBookmarks() async throws {
        let merged = try await run("merge", [try input(Self.samplePDF(pages: 2), "a.pdf"), try input(Self.samplePDF(pages: 3), "b.pdf")])
        let parts = try await run("split", [try InputFile.importing(merged.files[0])], ["mode": .string("bookmarks")])
        XCTAssertEqual(try parts.files.map { try pdf($0).pageCount }, [2, 3])
    }

    func testRemoveAndExtractPages() async throws {
        let source = try input(Self.samplePDF(pages: 4))
        let removed = try await run("remove_pages", [source], ["pages": .string("2, 4")])
        let remaining = try text(removed.files[0])
        XCTAssertTrue(remaining.contains("Sayfa 1") && remaining.contains("Sayfa 3") && !remaining.contains("Sayfa 2"))
        do {
            _ = try await run("remove_pages", [source], ["pages": .string("1-4")])
            XCTFail("Tüm sayfalar silinmemeli")
        } catch {}
        let extracted = try await run("extract_pages", [source], ["pages": .string("3, 1")])
        XCTAssertEqual(try pdf(extracted.files[0]).pageCount, 2)
        XCTAssertTrue(try pdf(extracted.files[0]).page(at: 0)?.string?.contains("Sayfa 3") == true)
        let separate = try await run("extract_pages", [source], ["pages": .string("1-2"), "separate": .bool(true)])
        XCTAssertEqual(separate.files.count, 2)
    }

    func testOrganizeSequenceAndRotate() async throws {
        let a = try input(Self.samplePDF(pages: 2), "a.pdf"), b = try input(Self.samplePDF(pages: 1, prefix: "Ek"), "b.pdf")
        let sequence = #"[{"file":1,"page":0},{"blank":true},{"file":0,"page":1,"rotate":90}]"#
        let result = try await run("organize", [a, b], ["sequence": .string(sequence)])
        let document = try pdf(result.files[0])
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Ek 1") == true)
        XCTAssertEqual(document.page(at: 2)?.rotation, 90)

        let rotated = try await run("rotate", [a], ["angle": .string("270"), "pages": .string("2")])
        let rotatedDocument = try pdf(rotated.files[0])
        XCTAssertEqual(rotatedDocument.page(at: 0)?.rotation, 0)
        XCTAssertEqual(rotatedDocument.page(at: 1)?.rotation, 270)
        let perPage = try await run("rotate", [a], ["per_page": .string(#"{"0":180}"#)])
        XCTAssertEqual(try pdf(perPage.files[0]).page(at: 0)?.rotation, 180)
    }

    func testNUpAndResize() async throws {
        let source = try input(Self.samplePDF(pages: 5, size: CGSize(width: 612, height: 792)))
        let nup = try await run("nup", [source], ["per_sheet": .string("4")])
        let sheets = try pdf(nup.files[0])
        XCTAssertEqual(sheets.pageCount, 2)
        XCTAssertTrue(sheets.string?.contains("Sayfa 5") == true)
        let resized = try await run("resize_pages", [source], ["paper": .string("A4")])
        let page = try XCTUnwrap(try pdf(resized.files[0]).page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 842, accuracy: 1)
    }

    // MARK: Damgalama

    func testWatermarkKeepsAnnotationsAndRotation() async throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.samplePDF(pages: 2)))
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Not"
        document.page(at: 0)?.addAnnotation(note)
        document.page(at: 1)?.rotation = 90
        let source = try input(try XCTUnwrap(document.dataRepresentation()))
        let result = try await run("watermark", [source], ["text": .string("GİZLİ BELGE"), "position": .string("tile")])
        let output = try pdf(result.files[0])
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(output.page(at: 0)?.string?.contains("GİZLİ BELGE") == true, output.page(at: 0)?.string ?? "")
        XCTAssertTrue(output.page(at: 1)?.string?.contains("GİZLİ BELGE") == true)
        XCTAssertEqual(output.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(output.page(at: 1)?.rotation, 90)

        let png = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 30)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        }
        let image = try await run("watermark", [source], ["kind": .string("image"), "image": .data(png), "layer": .string("under")])
        XCTAssertEqual(try pdf(image.files[0]).pageCount, 2)
    }

    func testPageNumbersAndHeaderFooter() async throws {
        let source = try input(Self.samplePDF(pages: 3), "rapor.pdf")
        let numbered = try await run("page_numbers", [source], ["format": .string("Sayfa {n} / {total}"), "pages": .string("2-3")])
        let output = try pdf(numbered.files[0])
        XCTAssertTrue(output.page(at: 1)?.string?.contains("Sayfa 1 / 2") == true, output.page(at: 1)?.string ?? "")
        XCTAssertTrue(output.page(at: 2)?.string?.contains("Sayfa 2 / 2") == true)
        let header = try await run("header_footer", [source], ["header_left": .string("{file} – Başlık {n}"), "line": .bool(true)])
        XCTAssertTrue(try pdf(header.files[0]).page(at: 2)?.string?.contains("rapor – Başlık 3") == true)
    }

    // MARK: Belge

    func testMetadata() async throws {
        let source = try input(Self.samplePDF(pages: 1))
        let result = try await run("metadata", [source], ["title": .string("Yıllık Rapor"), "author": .string("Ayşe Çınar"),
                                                           "keywords": .string("pdf, atölye")])
        let attributes = try pdf(result.files[0]).documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Yıllık Rapor")
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Ayşe Çınar")
    }

    func testProtectAndUnlock() async throws {
        let source = try input(Self.samplePDF(pages: 2))
        let protected = try await run("protect", [source], ["password": .string("gizli123"), "password2": .string("gizli123"),
                                                             "permissions": .list(["print"])])
        let locked = try pdf(protected.files[0])
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(locked.unlock(withPassword: "gizli123"))

        var lockedInput = try InputFile.importing(protected.files[0])
        let unlocked = try await run("unlock", [lockedInput], ["password": .string("gizli123")])
        let open = try pdf(unlocked.files[0])
        XCTAssertFalse(open.isEncrypted)
        XCTAssertEqual(open.pageCount, 2)

        do {
            _ = try await run("unlock", [lockedInput], ["password": .string("yanlis")])
            XCTFail("Yanlış parola kabul edilmemeli")
        } catch {}

        // Parolası girilmiş kilitli PDF diğer araçlarda da kullanılabilmeli.
        lockedInput.password = "gizli123"
        let rotated = try await run("rotate", [lockedInput])
        XCTAssertFalse(try pdf(rotated.files[0]).isEncrypted)
    }

    func testFlattenAndRepair() async throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.samplePDF(pages: 1)))
        let note = PDFAnnotation(bounds: CGRect(x: 60, y: 600, width: 300, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Kalıcı not"
        note.font = UIFont.systemFont(ofSize: 14)
        document.page(at: 0)?.addAnnotation(note)
        let source = try input(try XCTUnwrap(document.dataRepresentation()))
        let flat = try await run("flatten", [source])
        XCTAssertEqual(try pdf(flat.files[0]).page(at: 0)?.annotations.count, 0)

        var broken = Self.samplePDF(pages: 2)
        if let range = broken.range(of: Data("xref".utf8), options: .backwards) {
            broken.replaceSubrange(range, with: Data("xrex".utf8))
        }
        let repaired = try await run("repair", [try input(broken)])
        XCTAssertEqual(try pdf(repaired.files[0]).pageCount, 2)
    }

    // MARK: Dönüşüm

    func imageData(_ color: UIColor, size: CGSize, jpeg: Bool) -> Data {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            NSAttributedString(string: "Görsel", attributes: [.font: UIFont.boldSystemFont(ofSize: 40)]).draw(at: CGPoint(x: 20, y: 20))
        }
        return jpeg ? image.jpegData(compressionQuality: 0.9)! : image.pngData()!
    }

    func testImagesToPDF() async throws {
        let a = try input(imageData(.orange, size: CGSize(width: 400, height: 300), jpeg: true), "a.jpg", kind: .image)
        let b = try input(imageData(.blue, size: CGSize(width: 300, height: 500), jpeg: false), "b.png", kind: .image)
        let merged = try await run("images_to_pdf", [a, b], ["page_size": .string("A4"), "margin": .string("small")])
        let document = try pdf(merged.files[0])
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 842, accuracy: 1, "yatay görsel yatay A4")
        let separate = try await run("images_to_pdf", [a, b], ["merge": .bool(false)])
        XCTAssertEqual(separate.files.count, 2)
    }

    func testOfficeAndHTMLToPDF() async throws {
        let bundle = Bundle(for: EngineTests.self)
        for (ext, tool, marker) in [("docx", "word_to_pdf", "Word deneme"), ("xlsx", "excel_to_pdf", "Excel deneme"), ("pptx", "ppt_to_pdf", "PowerPoint deneme")] {
            let url = try XCTUnwrap(bundle.url(forResource: "ornek", withExtension: ext))
            let result = try await run(tool, [try InputFile.importing(url)])
            XCTAssertTrue(try text(result.files[0]).contains(marker), ext)
        }
        let html = try input(Data("<html><head><meta charset='utf-8'></head><body><h1>Merhaba Dünya</h1><p>ğüşıöç</p></body></html>".utf8),
                             "sayfa.html", kind: .html)
        let result = try await run("html_to_pdf", [html], ["header_footer": .bool(true)])
        XCTAssertTrue(try text(result.files[0]).contains("Merhaba Dünya"))
    }

    func testPDFToImages() async throws {
        let source = try input(Self.samplePDF(pages: 3))
        let pages = try await run("pdf_to_images", [source], ["dpi": .string("72"), "pages": .string("1-2")])
        XCTAssertEqual(pages.files.count, 2)
        let image = try XCTUnwrap(UIImage(contentsOfFile: pages.files[0].path))
        XCTAssertEqual(image.size.width, 595, accuracy: 2)

        let photo = try input(imageData(.green, size: CGSize(width: 320, height: 240), jpeg: true), "foto.jpg", kind: .image)
        let withImage = try await run("images_to_pdf", [photo])
        let extracted = try await run("pdf_to_images", [try InputFile.importing(withImage.files[0])], ["mode": .string("extract")])
        XCTAssertEqual(extracted.files.count, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: extracted.files[0].path))
    }

    func testPDFToTextAndMarkdown() async throws {
        let source = try input(Self.samplePDF(pages: 2))
        let txt = try await run("pdf_to_text", [source])
        let content = try String(contentsOf: txt.files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("--- Sayfa 2 ---") && content.contains("ğüşıöç"))
        let html = try await run("pdf_to_text", [source], ["format": .string("html")])
        XCTAssertTrue(try String(contentsOf: html.files[0], encoding: .utf8).contains("<section class=\"page\""))

        let layout = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Büyük Başlık", attributes: [.font: UIFont.boldSystemFont(ofSize: 30)]).draw(at: CGPoint(x: 50, y: 50))
            NSAttributedString(string: "Normal bir paragraf satırı.", attributes: [.font: UIFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 50, y: 110))
            for (row, cells) in [["Ürün", "Adet", "Fiyat"], ["Kalem", "12", "4,50"], ["Defter", "3", "18,00"]].enumerated() {
                for (column, cell) in cells.enumerated() {
                    NSAttributedString(string: cell, attributes: [.font: UIFont.systemFont(ofSize: 12)])
                        .draw(at: CGPoint(x: 50 + column * 160, y: 160 + row * 22))
                }
            }
        }
        let markdown = try await run("pdf_to_markdown", [try input(layout)])
        let md = try String(contentsOf: markdown.files[0], encoding: .utf8)
        XCTAssertTrue(md.contains("# Büyük Başlık"), md)
        XCTAssertTrue(md.contains("| Ürün | Adet | Fiyat |"), md)
        XCTAssertTrue(md.contains("<!-- Sayfa 1 -->"))
    }

    // MARK: OCR ve tarama

    func scannedPDF(_ text: String) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1240, height: 1754), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 44)])
                .draw(in: CGRect(x: 100, y: 200, width: 1040, height: 400))
        }
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            image.draw(in: CGRect(x: 0, y: 0, width: 595, height: 842))
        }
    }

    func testOCRMakesScannedPDFSearchable() async throws {
        let source = try input(scannedPDF("Ağaç ve ılık süt İstanbul"))
        XCTAssertEqual(try pdf(source.url).string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        let result = try await run("ocr", [source])
        let recognized = try text(result.files[0])
        XCTAssertTrue(recognized.contains("İstanbul") || recognized.contains("Istanbul"), recognized)
        XCTAssertTrue(recognized.contains("süt"), recognized)
    }

    func testScanToA4() async throws {
        let photo = try input(imageData(.white, size: CGSize(width: 900, height: 1200), jpeg: true), "foto.jpg", kind: .image)
        let result = try await run("scan", [photo], ["filter": .string("bw")])
        let document = try pdf(result.files[0])
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595, accuracy: 1)
    }

    // MARK: ZIP

    func testZipArchive() throws {
        let folder = try Storage.newWorkFolder()
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("ö.txt")
        try String(repeating: "PDF Atölye ", count: 200).write(to: a, atomically: true, encoding: .utf8)
        try "ikinci".write(to: b, atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("arsiv.zip")
        try Zip.archive([a, b], to: zip)
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(data.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertLessThan(data.count, 2400)
    }
}
