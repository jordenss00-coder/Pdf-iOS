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
        let sourceData = try XCTUnwrap(document.dataRepresentation())
        let annotations = PDFDocument(data: sourceData)?.page(at: 0)?.annotations.count ?? 0
        XCTAssertGreaterThan(annotations, 0)
        let source = try input(sourceData)
        let result = try await run("watermark", [source], ["text": .string("GİZLİ BELGE"), "position": .string("tile")])
        let output = try pdf(result.files[0])
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(output.page(at: 0)?.string?.contains("GİZLİ BELGE") == true, output.page(at: 0)?.string ?? "")
        XCTAssertTrue(output.page(at: 1)?.string?.contains("GİZLİ BELGE") == true)
        XCTAssertEqual(output.page(at: 0)?.annotations.count, annotations, "notlar korunmalı")
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

    // MARK: İyileştirme, karartma, bul-değiştir

    func testCompressShrinksScans() async throws {
        let size = CGSize(width: 2400, height: 3200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in stride(from: 0, to: 3200, by: 16) {
                for x in stride(from: 0, to: 2400, by: 16) {
                    UIColor(hue: CGFloat((x + y) % 360) / 360, saturation: 0.6, brightness: CGFloat.random(in: 0.5...1), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 16, height: 16))
                }
            }
        }
        let jpeg = try XCTUnwrap(photo.jpegData(compressionQuality: 0.95))
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            UIImage(data: jpeg)?.draw(in: CGRect(x: 0, y: 0, width: 595, height: 842))
        }
        let source = try input(data)
        let result = try await run("compress", [source], ["level": .string("recommended")])
        let after = result.files[0].fileSize
        XCTAssertLessThan(after, Int64(data.count) / 2, "önce \(data.count) sonra \(after) \(result.notes)")
        XCTAssertEqual(try pdf(result.files[0]).pageCount, 1)
    }

    func testGrayscaleRemovesColor() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 200, height: 100))
            NSAttributedString(string: "Renkli yazı", attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.blue])
                .draw(at: CGPoint(x: 20, y: 160))
        }
        let result = try await run("grayscale", [try input(data)])
        let image = try PDFiumDocument(data: Data(contentsOf: result.files[0])).render(page: 0, scale: 0.5)
        let pixels = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(pixels))
        var colorful = 0
        for i in stride(from: 0, to: CFDataGetLength(pixels) - 3, by: 4) {
            let b = Int(bytes[i]), g = Int(bytes[i + 1]), r = Int(bytes[i + 2])
            if max(r, g, b) - min(r, g, b) > 24 { colorful += 1 }
        }
        XCTAssertEqual(colorful, 0)
        XCTAssertTrue(try text(result.files[0]).contains("Renkli yazı"))
    }

    func testRedactRemovesText() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Müşteri: Ayşe Yılmaz", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 50, y: 60))
            NSAttributedString(string: "IBAN: TR33 0006 1005 1978 6457 8413 26", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 50, y: 90))
            NSAttributedString(string: "TC: 12345678901 ve telefon", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 50, y: 120))
        }
        let result = try await run("redact", [try input(data)], ["presets": .list(["iban", "tckn"]), "terms_text": .string("Yılmaz")])
        let remaining = try text(result.files[0])
        XCTAssertFalse(remaining.contains("0006"), remaining)
        XCTAssertFalse(remaining.contains("12345678901"), remaining)
        XCTAssertFalse(remaining.contains("Yılmaz"), remaining)
        XCTAssertTrue(remaining.contains("Müşteri"), remaining)
        XCTAssertTrue(remaining.contains("telefon"), remaining)
    }

    func testFindReplaceRewritesText() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Teslim tarihi 15 Ocak, sorumlu Ahmet Bey.", attributes: [.font: UIFont.systemFont(ofSize: 16)])
                .draw(at: CGPoint(x: 50, y: 80))
        }
        let result = try await run("find_replace", [try input(data)], ["pairs": .pairs([ReplacePair(find: "15 Ocak", replace: "28 Şubat"),
                                                                                       ReplacePair(find: "ahmet", replace: "Ayşe")])])
        let changed = try text(result.files[0])
        XCTAssertTrue(changed.contains("28 Şubat"), changed)
        XCTAssertTrue(changed.contains("Ayşe"), changed)
        XCTAssertFalse(changed.contains("15 Ocak"), changed)
        XCTAssertFalse(changed.contains("Ahmet"), changed)
        XCTAssertTrue(changed.contains("Teslim") && changed.contains("Bey"), changed)
        XCTAssertEqual(result.notes.first, "2 yerde değiştirildi.")
    }

    // MARK: PDF'ten Office

    func reportPDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Satış Raporu", attributes: [.font: UIFont.boldSystemFont(ofSize: 28)]).draw(at: CGPoint(x: 50, y: 50))
            NSAttributedString(string: "Bu çeyrekte satışlar beklenenden yüksek gerçekleşti ve stoklar",
                               attributes: [.font: UIFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 50, y: 100))
            NSAttributedString(string: "hızla tükendi. Yeni sipariş planı hazırlanıyor.",
                               attributes: [.font: UIFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 50, y: 115))
            for (row, cells) in [["Ürün", "Adet", "Tutar"], ["Kalem", "12", "1.250,50"], ["Defter", "3", "18,00"]].enumerated() {
                for (column, cell) in cells.enumerated() {
                    NSAttributedString(string: cell, attributes: [.font: UIFont.systemFont(ofSize: 12)])
                        .draw(at: CGPoint(x: 50 + column * 160, y: 170 + row * 22))
                }
            }
        }
    }

    /// Üretilen Office dosyasını Apple'ın Office motoruyla PDF'e çevirip metnini döndürür (dosya geçerli mi?).
    func officeText(_ url: URL) async throws -> String {
        let data = try await OfficeConverter.pdf(from: url)
        return PDFDocument(data: data)?.string ?? ""
    }

    func testPDFToWord() async throws {
        let result = try await run("pdf_to_word", [try input(reportPDF(), "rapor.pdf")])
        XCTAssertEqual(result.files[0].pathExtension, "docx")
        let text = try await officeText(result.files[0])
        XCTAssertTrue(text.contains("Satış Raporu"), text)
        XCTAssertTrue(text.contains("yüksek gerçekleşti ve stoklar hızla tükendi"), text)
        XCTAssertTrue(text.contains("Defter"), text)
        let image = try await run("pdf_to_word", [try input(reportPDF(), "rapor.pdf")], ["mode": .string("image")])
        let imageText = try await officeText(image.files[0])
        XCTAssertTrue(imageText.contains("Satış Raporu"), imageText)
    }

    func testPDFToExcel() async throws {
        let result = try await run("pdf_to_excel", [try input(reportPDF(), "rapor.pdf")])
        XCTAssertEqual(result.files[0].pathExtension, "xlsx")
        let text = try await officeText(result.files[0])
        XCTAssertTrue(text.contains("Kalem") && text.contains("Tutar"), text)
        XCTAssertTrue(text.contains("1250,5") || text.contains("1250.5") || text.contains("1.250,5"), text)
    }

    func testPDFToPowerPoint() async throws {
        let result = try await run("pdf_to_ppt", [try input(reportPDF(), "rapor.pdf")])
        XCTAssertEqual(result.files[0].pathExtension, "pptx")
        let text = try await officeText(result.files[0])
        XCTAssertTrue(text.contains("Satış") && text.contains("Raporu") && text.contains("Kalem"), text)
    }

    // MARK: Düzenleyici, kırpma, PDF/A, karşılaştırma, yapay zekâ

    func testEditorExportStampsImageAndRewritesText() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.samplePDF(pages: 1)))
        let page = try XCTUnwrap(document.page(at: 0))
        let red = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        page.addAnnotation(ImageAnnotation(image: red, bounds: CGRect(x: 300, y: 300, width: 80, height: 40)))
        let selection = try XCTUnwrap(document.findString("Sayfa 1", withOptions: []).first)
        page.addAnnotation(MarkerAnnotation(kind: .textEdit, bounds: selection.bounds(for: page), replacement: "Bölüm 9"))
        let url = try EditorExport.export(document)
        let output = try pdf(url)
        let text = output.string ?? ""
        XCTAssertTrue(text.contains("Bölüm 9"), text)
        XCTAssertFalse(text.contains("Sayfa 1"), text)
        XCTAssertEqual(output.page(at: 0)?.annotations.count, 0)
        let image = try PDFiumDocument(data: Data(contentsOf: url)).render(page: 0, scale: 1)
        let pixels = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(pixels))
        let x = 340, y = 842 - 320
        let offset = y * image.bytesPerRow + x * 4
        XCTAssertGreaterThan(Int(bytes[offset + 2]), 200, "kırmızı")
        XCTAssertLessThan(Int(bytes[offset + 1]), 80, "yeşil")
    }

    func testFormDetector() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Ad: ____________", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 50, y: 60))
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(1)
            cg.strokeLineSegments(between: [CGPoint(x: 50, y: 160), CGPoint(x: 300, y: 160)])
            cg.stroke(CGRect(x: 50, y: 200, width: 12, height: 12))
        }
        let fields = try FormDetector.detect(PDFiumDocument(data: data), page: 0)
        XCTAssertTrue(fields.contains { $0.checkbox }, "\(fields)")
        XCTAssertTrue(fields.contains { $0.name == "Ad" }, "\(fields)")
        XCTAssertGreaterThanOrEqual(fields.filter { !$0.checkbox }.count, 2, "\(fields)")
    }

    func testCrop() async throws {
        let source = try input(Self.samplePDF(pages: 2))
        let auto = try await run("crop", [source], ["mode": .string("auto"), "padding": .number(5)])
        let box = try XCTUnwrap(try pdf(auto.files[0]).page(at: 0)?.bounds(for: .cropBox))
        XCTAssertLessThan(box.width, 595)
        XCTAssertLessThan(box.height, 200)
        let manual = try await run("crop", [source], ["rect": .string("50,60,200,100"), "apply": .string("current"), "page": .number(1)])
        let document = try pdf(manual.files[0])
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .cropBox).width ?? 0, 200, accuracy: 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .cropBox).width ?? 0, 595, accuracy: 1)
    }

    func testPDFA() async throws {
        let result = try await run("pdf_to_pdfa", [try input(Self.samplePDF(pages: 2), "arşiv.pdf")], ["part": .string("2")])
        let data = try Data(contentsOf: result.files[0])
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(raw.contains("/OutputIntents"))
        XCTAssertTrue(raw.contains("<pdfaid:part>2</pdfaid:part>"))
        let document = try pdf(result.files[0])
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "arşiv")
    }

    func testCompareText() async throws {
        let a = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Teslim tarihi 15 Ocak olarak belirlendi", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 20, y: 40))
        }
        let b = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { context in
            context.beginPage()
            NSAttributedString(string: "Teslim tarihi 28 Şubat olarak belirlendi", attributes: [.font: UIFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 20, y: 40))
        }
        let result = try await run("compare", [try input(a, "a.pdf"), try input(b, "b.pdf")])
        XCTAssertTrue(result.text?.contains("2 kelime silinmiş") == true, result.text ?? "")
        let page = try XCTUnwrap(try pdf(result.files[0]).page(at: 0))
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).width, 800)
        let visual = try await run("compare", [try input(a, "a.pdf"), try input(b, "b.pdf")], ["mode": .string("visual")])
        XCTAssertTrue(visual.text?.contains("farklı bölge") == true, visual.text ?? "")
    }

    func testAISummarizeOrExplainsUnavailability() async throws {
        do {
            let result = try await run("ai_summarize", [try input(Self.samplePDF(pages: 1))], ["length": .string("short")])
            XCTAssertFalse((result.text ?? "").isEmpty)
        } catch let error as ToolError {
            if error.message.contains("Apple Intelligence") || error.message.contains("iOS 26") {
                throw XCTSkip(error.message)
            }
            throw error
        }
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
