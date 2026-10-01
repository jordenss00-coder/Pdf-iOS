import CoreText
import UIKit
import Vision

struct RecognizedWord {
    let text: String
    /// Görünür sayfa koordinatlarında (sol üst başlangıçlı)
    let rect: CGRect
}

enum OCRTools {
    /// "tur+eng" → Vision dil kodları; cihazın desteklemediği diller atlanır.
    static func languages(_ option: String) -> (codes: [String], missing: [String]) {
        let wanted: [String]
        switch option {
        case "tur": wanted = ["tr-TR"]
        case "eng": wanted = ["en-US"]
        default: wanted = ["tr-TR", "en-US"]
        }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let codes = wanted.filter { supported.contains($0) }
        let missing = wanted.filter { !supported.contains($0) }
        return (codes.isEmpty ? ["en-US"] : codes, missing)
    }

    /// Görüntüdeki kelimeleri ve görünür sayfa boyutuna ölçeklenmiş kutularını döndürür.
    static func recognize(_ image: CGImage, languages: [String], pageSize: CGSize) throws -> [RecognizedWord] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Sinir motoru olmayan ortamlarda (simülatör) işlemciyle dene.
            request.usesCPUOnly = true
            try handler.perform([request])
        }
        var words: [RecognizedWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            for match in string.matches(of: #/\S+/#) {
                guard let box = (try? candidate.boundingBox(for: match.range))?.boundingBox else { continue }
                let rect = CGRect(x: box.minX * pageSize.width, y: (1 - box.maxY) * pageSize.height,
                                  width: box.width * pageSize.width, height: box.height * pageSize.height)
                words.append(RecognizedWord(text: String(string[match.range]), rect: rect))
            }
        }
        return words
    }

    /// Kelimeleri görünmez (seçilebilir, aranabilir) metin olarak çizer.
    static func drawInvisible(_ words: [RecognizedWord], in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for word in words where word.rect.width > 0 && word.rect.height > 0 {
            let probe = UIFont(name: "Helvetica", size: 10) ?? .systemFont(ofSize: 10)
            let unit = NSAttributedString(string: word.text, attributes: [.font: probe]).size().width / 10
            guard unit > 0 else { continue }
            let size = min(word.rect.width / unit, word.rect.height * 1.15)
            let font = UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [.font: font]))
            let baseline = word.rect.maxY - (word.rect.height - (font.ascender - font.descender)) / 2 + font.descender
            context.textPosition = CGPoint(x: word.rect.minX, y: baseline)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// Belgedeki sayfalara OCR metin katmanı ekler; tanınan kelime sayısını döndürür.
    static func addTextLayer(to document: PDFiumDocument, pages: [Int], languages codes: [String], skipText: Bool,
                             progress: (Double, String) -> Void = { _, _ in }) throws -> Int {
        var found: [Int: [RecognizedWord]] = [:]
        for (k, index) in pages.enumerated() {
            progress(Double(k) / Double(max(1, pages.count)), "Sayfa \(index + 1)")
            if skipText, try document.text(page: index).plain.count > 20 { continue }
            let geometry = try document.geometry(page: index)
            let image = try document.render(page: index, scale: 300 / 72)
            let words = try recognize(image, languages: codes, pageSize: geometry.visualSize)
            if !words.isEmpty { found[index] = words }
        }
        guard !found.isEmpty else { return 0 }
        try document.stamp(pages: found.keys.sorted()) { index, _, context in
            drawInvisible(found[index] ?? [], in: context)
        }
        return found.values.reduce(0) { $0 + $1.count }
    }

    static func ocr(_ c: ToolContext) async throws -> [URL] {
        let (codes, missing) = languages(c.options.string("language", "tur+eng"))
        if !missing.isEmpty {
            c.warnings.append("Bu cihaz şu dilleri tanımıyor: \(missing.joined(separator: ", ")). iOS'u güncellemek dil desteğini artırabilir.")
        }
        var urls: [URL] = []
        var total = 0
        for input in c.inputs {
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
            total += try addTextLayer(to: document, pages: pages, languages: codes, skipText: c.options.bool("skip_text_pages", true)) { fraction, message in
                c.progress(fraction, "\(input.name) – \(message)")
            }
            let url = c.out("\(stem(input.name))_ocr.pdf")
            try document.save().write(to: url)
            urls.append(url)
        }
        if total == 0 {
            c.warnings.append("Tanınacak metin bulunamadı. Sayfalar zaten metin içeriyor olabilir.")
        } else {
            c.notes.append("\(total) kelime tanındı.")
        }
        return urls
    }
}
