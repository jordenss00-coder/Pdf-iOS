import CoreText
import PDFKit
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cihaz üstü yapay zekâ (Apple Intelligence). Belge cihazdan çıkmaz.
enum AITools {
    static let lengths = [
        "short": "5-7 maddelik kısa bir özet",
        "medium": "başlıklarla düzenlenmiş, orta uzunlukta bir özet (yaklaşık 1 sayfa)",
        "long": "bölüm bölüm ayrıntılı bir özet; önemli sayılar, tarihler ve kararlar dahil",
    ]

    /// Modelle tek bir istem; her çağrı yeni oturumda (bağlam penceresi taşmasın).
    static func ask(_ prompt: String, instructions: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .unavailable(let reason) = SystemLanguageModel.default.availability {
                throw ToolError(unavailableMessage(String(describing: reason)))
            }
            let session = LanguageModelSession()
            do {
                return try await session.respond(to: instructions + "\n\n" + prompt).content
            } catch {
                throw ToolError("Yapay zekâ yanıt veremedi: \(error.localizedDescription)")
            }
        }
        #endif
        throw ToolError("Yapay zekâ araçları iOS 26 ve Apple Intelligence destekleyen bir cihaz gerektirir.")
    }

    static func unavailableMessage(_ reason: String) -> String {
        if reason.contains("appleIntelligenceNotEnabled") {
            return "Apple Intelligence kapalı. Ayarlar > Apple Intelligence ve Siri bölümünden açıp tekrar dene."
        }
        if reason.contains("modelNotReady") {
            return "Apple Intelligence modeli henüz indiriliyor. Biraz sonra tekrar dene."
        }
        return "Bu cihaz Apple Intelligence'ı desteklemiyor; yapay zekâ araçları kullanılamıyor."
    }

    /// Metni yaklaşık karakter sınırına göre paragraf sınırlarından böler.
    static func chunks(_ text: String, limit: Int = 6000) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += paragraph + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }

    static func summarize(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try PDFiumDocument(data: try await c.pdfData(input))
        var text = ""
        for index in 0..<document.pageCount {
            text += "[Sayfa \(index + 1)]\n" + (try document.text(page: index).plain) + "\n\n"
        }
        guard text.contains(where: { $0.isLetter }) else {
            throw ToolError("Belgede okunabilir metin yok. Önce OCR uygula.")
        }
        let language = c.options.string("language", "Türkçe")
        let length = lengths[c.options.string("length", "medium")] ?? lengths["medium"]!
        let focus = c.options.string("focus").trimmingCharacters(in: .whitespaces)
        let instructions = "Belgeleri doğru ve tarafsız özetleyen bir asistansın. Belgede olmayan bilgi ekleme."
        let parts = chunks(text)
        var notes: [String] = []
        if parts.count > 1 {
            for (index, part) in parts.enumerated() {
                c.progress(Double(index) / Double(parts.count + 1), "Bölüm \(index + 1) / \(parts.count)")
                notes.append(try await ask("Aşağıdaki belge bölümünün önemli noktalarını \(language) dilinde maddeler halinde çıkar:\n\n\(part)",
                                           instructions: instructions))
            }
        }
        var prompt = "Bu belgenin \(length) olarak \(language) dilinde özetini yaz. Önce belgenin ne olduğunu tek cümleyle söyle, "
            + "sonra özete geç. Markdown başlıkları ve madde işaretleri kullan."
        if !focus.isEmpty { prompt += " Özellikle şu konuya odaklan: \(focus)" }
        let material = parts.count > 1 ? notes.joined(separator: "\n\n") : text
        c.progress(Double(parts.count) / Double(parts.count + 1), "Özet yazılıyor")
        let summary = try await ask("\(prompt)\n\n<belge>\n\(material)\n</belge>", instructions: instructions)
        c.text = summary
        let url = c.out("\(stem(input.name))_ozet.pdf")
        try MarkdownPDF.render(title: "Özet: \(stem(input.name))", markdown: summary).write(to: url)
        return [url]
    }

    static func translate(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let language = c.options.string("language", "İngilizce")
        let document = try PDFiumDocument(data: try await c.pdfData(input))
        struct Block {
            var page: Int
            var rect: CGRect
            var text: String
            var size: Double
            var bold: Bool
            var color: String
        }
        var blocks: [Block] = []
        for index in 0..<document.pageCount {
            var current: Block?
            for line in try document.text(page: index).lines {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard text.contains(where: { $0.isLetter }) else { continue }
                if var block = current, abs(line.fontSize - block.size) <= max(1, block.size * 0.15),
                   line.rect.minY - block.rect.maxY < CGFloat(block.size) * 0.9, line.rect.minY >= block.rect.minY {
                    block.rect = block.rect.union(line.rect)
                    block.text += (block.text.hasSuffix("-") ? "" : " ") + text
                    current = block
                } else {
                    if let current { blocks.append(current) }
                    current = Block(page: index, rect: line.rect, text: text, size: line.fontSize, bold: line.bold, color: line.color)
                }
            }
            if let current { blocks.append(current) }
        }
        guard !blocks.isEmpty else { throw ToolError("Çevrilecek metin bulunamadı. Taranmış bir belgeyse önce OCR uygula.") }
        let instructions = "Profesyonel bir çevirmensin. Yalnızca çeviriyi yaz; açıklama ekleme. Sayıları, özel isimleri, e-posta ve adresleri olduğu gibi bırak."
        var translated: [String] = []
        for (index, block) in blocks.enumerated() {
            c.progress(Double(index) / Double(blocks.count), "Blok \(index + 1) / \(blocks.count)")
            let answer = try await ask("Şu metni \(language) diline çevir:\n\n\(block.text)", instructions: instructions)
            translated.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var leftovers: [Int: [TextSurgery.Placement]] = [:]
        for page in Set(blocks.map(\.page)) {
            let rects = blocks.filter { $0.page == page }.map(\.rect)
            try document.withPage(page) { handle in
                let geometry = PDFiumDocument.geometry(handle)
                let targets = rects.map { geometry.page($0.insetBy(dx: -1, dy: -1)) }
                let chars = TextSurgery.characters(handle)
                var plan = TextSurgery.Plan()
                for char in chars where !char.box.isNull && targets.contains(where: { $0.contains(CGPoint(x: char.box.midX, y: char.box.midY)) }) {
                    plan.remove.insert(char.index)
                }
                let surgery = TextSurgery.apply(plan, chars: chars, page: handle, document: document.handle)
                leftovers[page] = TextSurgery.placements(surgery.fallbacks, geometry: geometry)
            }
        }
        try document.stamp(pages: Set(blocks.map(\.page)).sorted()) { index, _, context in
            TextSurgery.draw(leftovers[index] ?? [], in: context)
            for (block, text) in zip(blocks, translated) where block.page == index {
                MarkdownPDF.fit(text, in: block.rect.insetBy(dx: 0, dy: -1), size: CGFloat(block.size), bold: block.bold,
                                color: UIColor(hex: block.color), context: context)
            }
        }
        let url = c.out("\(stem(input.name))_\(language.lowercased().replacingOccurrences(of: " ", with: "_")).pdf")
        try document.save().write(to: url)
        c.notes.append("\(blocks.count) metin bloğu cihaz üstü yapay zekâyla çevrildi.")
        return [url]
    }
}

/// Markdown benzeri metni A4 PDF'e dizer; metni kutuya sığdırır.
enum MarkdownPDF {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var font = UIFont.systemFont(ofSize: 11)
            var indent: CGFloat = 0
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                line = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                font = .boldSystemFont(ofSize: level <= 1 ? 16 : level == 2 ? 14 : 12)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                line = "•  " + line.dropFirst(2)
                indent = 12
            }
            line = line.replacingOccurrences(of: "**", with: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 5
            paragraph.lineSpacing = 2
            paragraph.headIndent = indent + 10
            paragraph.firstLineHeadIndent = indent
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.black]))
        }
        return result
    }

    static func render(title: String, markdown: String) -> Data {
        let body = NSMutableAttributedString(string: title + "\n", attributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.black])
        body.append(attributed(markdown))
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let frame = page.insetBy(dx: 56, dy: 56)
        let setter = CTFramesetterCreateWithAttributedString(body as CFAttributedString)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            var start = 0
            repeat {
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: frame.minX, y: page.height - frame.maxY, width: frame.width, height: frame.height), transform: nil)
                let ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
                CTFrameDraw(ctFrame, cg)
                cg.restoreGState()
                let visible = CTFrameGetVisibleStringRange(ctFrame)
                guard visible.length > 0 else { break }
                start += visible.length
            } while start < body.length
        }
    }

    /// Metni dikdörtgene sığacak en büyük boyutta (en fazla verilen boyut) çizer.
    static func fit(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool, color: UIColor, context: CGContext) {
        var fontSize = max(4, size)
        var attributed = NSAttributedString()
        var needed = CGSize.zero
        let width = max(rect.width, 20)
        repeat {
            let font = bold ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize)
            attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            needed = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], context: nil).size
            if needed.height <= rect.height * 1.05 || fontSize <= 4 { break }
            fontSize *= 0.92
        } while true
        UIGraphicsPushContext(context)
        attributed.draw(with: CGRect(x: rect.minX, y: rect.minY, width: width, height: max(rect.height, needed.height)),
                        options: [.usesLineFragmentOrigin], context: nil)
        UIGraphicsPopContext()
    }
}
