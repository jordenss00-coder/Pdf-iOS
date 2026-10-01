import PDFKit
import PDFium
import UIKit

extension PDFiumDocument {
    /// Gömülmemiş yazı tiplerinin adları.
    func unembeddedFonts() throws -> [String] {
        var names = Set<String>()
        for index in 0..<pageCount {
            try withPage(index) { page in
                for k in 0..<FPDFPage_CountObjects(page) {
                    guard let object = FPDFPage_GetObject(page, k), FPDFPageObj_GetType(object) == 1,
                          let font = FPDFTextObj_GetFont(object), FPDFFont_GetIsEmbedded(font) == 0 else { continue }
                    let length = FPDFFont_GetBaseFontName(font, nil, 0)
                    var buffer = [CChar](repeating: 0, count: max(1, Int(length)))
                    _ = FPDFFont_GetBaseFontName(font, &buffer, length)
                    names.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
            }
        }
        return names.filter { !$0.isEmpty }.sorted()
    }
}

enum ArchiveTools {
    /// PDF metin dizesi (UTF-16BE, BOM ile).
    static func pdfText(_ text: String) -> String {
        "<FEFF" + text.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    static func pdfToPDFA(_ c: ToolContext) async throws -> [URL] {
        let part = min(3, max(1, c.options.int("part", 2)))
        var urls: [URL] = []
        for input in c.inputs {
            let source = try await c.pdfData(input)
            let missing = try PDFiumDocument(data: source).unembeddedFonts()
            if !missing.isEmpty {
                c.warnings.append("\(input.name): gömülü olmayan yazı tipleri: \(missing.prefix(5).joined(separator: ", "))")
            }
            guard let kit = PDFDocument(data: source), let flat = kit.dataRepresentation() else {
                throw ToolError("'\(input.name)' açılamadı.")
            }
            let attributes = kit.documentAttributes ?? [:]
            let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem(input.name)
            let author = attributes[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            var update = try PDFIncremental(flat)
            guard let catalog = update.dictionary(of: update.root) else { throw ToolError("Belge kataloğu okunamadı.") }

            guard let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else { throw ToolError("Renk profili oluşturulamadı.") }
            var profile = Data("<< /N 3 /Length \(icc.count) >>\nstream\n".utf8)
            profile.append(icc)
            profile.append(Data("\nendstream".utf8))
            let profileNumber = update.add(profile)
            let intent = update.add("<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB IEC61966-2.1) /DestOutputProfile \(profileNumber) 0 R >>")

            let now = Date()
            let zone = TimeZone.current.secondsFromGMT(for: now)
            let sign = zone >= 0 ? "+" : "-"
            let hours = String(format: "%02d", abs(zone) / 3600), minutes = String(format: "%02d", abs(zone) % 3600 / 60)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMddHHmmss"
            let iso = DateFormatter()
            iso.locale = Locale(identifier: "en_US_POSIX")
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let pdfDate = "D:\(stamp.string(from: now))\(sign)\(hours)'\(minutes)'"
            let xmpDate = "\(iso.string(from: now))\(sign)\(hours):\(minutes)"
            let creator = author.isEmpty ? "" : "<dc:creator><rdf:Seq><rdf:li>\(xmlEscape(author))</rdf:li></rdf:Seq></dc:creator>"
            let xmp = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
            <pdfaid:part>\(part)</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>
            <dc:format>application/pdf</dc:format>
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(xmlEscape(title))</rdf:li></rdf:Alt></dc:title>\(creator)
            <xmp:CreateDate>\(xmpDate)</xmp:CreateDate><xmp:ModifyDate>\(xmpDate)</xmp:ModifyDate><xmp:MetadataDate>\(xmpDate)</xmp:MetadataDate>
            <xmp:CreatorTool>PDF Atölye</xmp:CreatorTool><pdf:Producer>PDF Atölye</pdf:Producer>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            <?xpacket end="w"?>
            """
            let xmpData = Data(xmp.utf8)
            var metadata = Data("<< /Type /Metadata /Subtype /XML /Length \(xmpData.count) >>\nstream\n".utf8)
            metadata.append(xmpData)
            metadata.append(Data("\nendstream".utf8))
            let metadataNumber = update.add(metadata)
            var info = "<< /Title \(pdfText(title)) /Producer \(pdfText("PDF Atölye")) /Creator \(pdfText("PDF Atölye"))"
            if !author.isEmpty { info += " /Author \(pdfText(author))" }
            info += " /CreationDate (\(pdfDate)) /ModDate (\(pdfDate)) >>"
            let infoNumber = update.add(info)
            var newCatalog = PDFIncremental.removing("Metadata", from: catalog)
            newCatalog = PDFIncremental.removing("OutputIntents", from: newCatalog)
            newCatalog = PDFIncremental.appending("/Metadata \(metadataNumber) 0 R /OutputIntents [\(intent) 0 R]", to: newCatalog)
            update.replace(update.root, with: newCatalog)
            let url = c.out("\(stem(input.name))_pdfa.pdf")
            try update.build(info: infoNumber).write(to: url)
            urls.append(url)
        }
        c.notes.append("PDF/A-\(min(3, max(1, c.options.int("part", 2))))b işaretleri, sRGB renk profili ve XMP bilgileri eklendi. "
                       + "Arşiv uygunluğu bağımsız bir doğrulayıcıyla (ör. veraPDF) denetlenmelidir.")
        return urls
    }
}

enum CompareTools {
    static let removed = UIColor(red: 0.9, green: 0.15, blue: 0.2, alpha: 1)
    static let added = UIColor(red: 0.1, green: 0.65, blue: 0.3, alpha: 1)

    private struct Word {
        let page: Int
        let rect: CGRect
        let text: String
    }

    static func compare(_ c: ToolContext) async throws -> [URL] {
        guard c.inputs.count == 2 else { throw ToolError("Karşılaştırmak için iki PDF ekle.") }
        let dataA = try await c.pdfData(c.inputs[0]), dataB = try await c.pdfData(c.inputs[1])
        let a = try PDFiumDocument(data: dataA), b = try PDFiumDocument(data: dataB)
        guard let kitA = PDFDocument(data: dataA), let kitB = PDFDocument(data: dataB) else { throw ToolError("PDF açılamadı.") }
        var marksA: [Int: [CGRect]] = [:], marksB: [Int: [CGRect]] = [:]
        var changedPages = Set<Int>()
        var summary: String
        if c.options.string("mode", "text") == "visual" {
            var regions = 0
            for index in 0..<min(a.pageCount, b.pageCount) {
                c.progress(Double(index) / Double(max(1, min(a.pageCount, b.pageCount))), "Sayfa \(index + 1)")
                let boxes = try differences(a.render(page: index, scale: 100 / 72, grayscale: true),
                                            b.render(page: index, scale: 100 / 72, grayscale: true), scale: 72 / 100)
                if !boxes.isEmpty {
                    marksA[index] = boxes
                    marksB[index] = boxes
                    changedPages.insert(index + 1)
                    regions += boxes.count
                }
            }
            summary = "\(regions) farklı bölge bulundu."
        } else {
            func words(_ document: PDFiumDocument) throws -> [Word] {
                var result: [Word] = []
                for index in 0..<document.pageCount {
                    for line in try document.text(page: index).lines {
                        result += PageRasterizer.split(line).map { Word(page: index, rect: $0.rect, text: $0.text) }
                    }
                }
                return result
            }
            let wordsA = try words(a), wordsB = try words(b)
            guard !(wordsA.isEmpty && wordsB.isEmpty) else {
                throw ToolError("Belgelerde metin yok. 'Görsel farklar' modunu dene.")
            }
            var deleted = 0, inserted = 0
            for change in wordsB.map(\.text).difference(from: wordsA.map(\.text)) {
                switch change {
                case .remove(let offset, _, _):
                    let word = wordsA[offset]
                    marksA[word.page, default: []].append(word.rect)
                    changedPages.insert(word.page + 1)
                    deleted += 1
                case .insert(let offset, _, _):
                    let word = wordsB[offset]
                    marksB[word.page, default: []].append(word.rect)
                    changedPages.insert(word.page + 1)
                    inserted += 1
                }
            }
            summary = deleted + inserted == 0 ? "Metin farkı yok; belgeler aynı metni içeriyor."
                : "\(deleted) kelime silinmiş (kırmızı), \(inserted) kelime eklenmiş (yeşil)."
        }
        if !changedPages.isEmpty {
            summary += " Farklı sayfalar: " + changedPages.sorted().map(String.init).joined(separator: ", ") + "."
        }
        c.text = summary
        c.notes.append(summary)

        let gap: CGFloat = 24, header: CGFloat = 30
        let labelFont = UIFont.boldSystemFont(ofSize: 11)
        let output = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for index in 0..<max(kitA.pageCount, kitB.pageCount) {
                let pageA = kitA.page(at: index), pageB = kitB.page(at: index)
                let sizeA = pageA.map(PDFDraw.visualSize) ?? .zero, sizeB = pageB.map(PDFDraw.visualSize) ?? .zero
                let width = sizeA.width + gap + sizeB.width, height = max(sizeA.height, sizeB.height) + header
                context.beginPage(withBounds: CGRect(x: 0, y: 0, width: width, height: height), pageInfo: [:])
                let cg = context.cgContext
                let rectA = CGRect(x: 0, y: header, width: sizeA.width, height: sizeA.height)
                let rectB = CGRect(x: sizeA.width + gap, y: header, width: sizeB.width, height: sizeB.height)
                if let pageA { PDFDraw.draw(pageA, in: rectA, context: cg) }
                if let pageB { PDFDraw.draw(pageB, in: rectB, context: cg) }
                for (marks, origin, color) in [(marksA[index] ?? [], rectA.origin, removed), (marksB[index] ?? [], rectB.origin, added)] {
                    cg.setFillColor(color.withAlphaComponent(0.28).cgColor)
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(0.8)
                    for mark in marks {
                        let box = mark.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1)
                        cg.fill(box)
                        cg.stroke(box)
                    }
                }
                NSAttributedString(string: "A: \(c.inputs[0].name)", attributes: [.font: labelFont, .foregroundColor: removed])
                    .draw(at: CGPoint(x: 6, y: 9))
                NSAttributedString(string: "B: \(c.inputs[1].name)", attributes: [.font: labelFont, .foregroundColor: added])
                    .draw(at: CGPoint(x: rectB.minX + 6, y: 9))
            }
        }
        let url = c.out("karsilastirma_\(stem(c.inputs[0].name))_\(stem(c.inputs[1].name)).pdf")
        try output.write(to: url)
        return [url]
    }

    /// İki gri görüntü arasındaki farklı bölgeler (nokta cinsinden kutular).
    static func differences(_ first: CGImage, _ second: CGImage, scale: CGFloat) -> [CGRect] {
        guard let dataA = first.dataProvider?.data, let dataB = second.dataProvider?.data,
              let bytesA = CFDataGetBytePtr(dataA), let bytesB = CFDataGetBytePtr(dataB) else { return [] }
        let width = min(first.width, second.width), height = min(first.height, second.height)
        let cell = 6
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var marked = [Bool](repeating: false, count: columns * rows)
        for y in 0..<height {
            for x in 0..<width {
                let a = Int(bytesA[y * first.bytesPerRow + x * 4]), b = Int(bytesB[y * second.bytesPerRow + x * 4])
                if abs(a - b) > 40 { marked[(y / cell) * columns + x / cell] = true }
            }
        }
        var visited = [Bool](repeating: false, count: marked.count)
        var boxes: [CGRect] = []
        for start in 0..<marked.count where marked[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            while let current = stack.popLast() {
                let cx = current % columns, cy = current / columns
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                        let neighbour = ny * columns + nx
                        if marked[neighbour] && !visited[neighbour] {
                            visited[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }
            let rect = CGRect(x: CGFloat(minX * cell) * scale, y: CGFloat(minY * cell) * scale,
                              width: CGFloat((maxX - minX + 1) * cell) * scale, height: CGFloat((maxY - minY + 1) * cell) * scale)
            if rect.width * rect.height >= 20 { boxes.append(rect) }
        }
        return boxes
    }
}
