import PDFKit
import UIKit

enum OptimizeTools {
    static func compress(_ c: ToolContext) async throws -> [URL] {
        let level = PDFiumImageEdit.levels[c.options.string("level", "recommended")] ?? PDFiumImageEdit.levels["recommended"]!
        let gray = c.options.bool("grayscale")
        var urls: [URL] = []
        for (k, input) in c.inputs.enumerated() {
            c.progress(Double(k) / Double(c.inputs.count), input.name)
            let original = try await c.pdfData(input)
            let before = (try? Data(contentsOf: input.url).count) ?? original.count
            let document = try PDFiumDocument(data: original)
            let report = try PDFiumImageEdit.recompress(document, level: level, gray: gray)
            var output = try document.save()
            if report.found + report.nested > 0 && report.changed == 0 {
                c.notes.append("\(input.name): \(report.summary).")
            }
            // PDFium eski görsel akışlarını dosyada bırakır; PDFKit yalnızca kullanılan nesneleri yazar.
            if report.changed > 0, let cleaned = PDFDocument(data: output)?.dataRepresentation(), cleaned.count < output.count {
                output = cleaned
            }
            if output.count >= before {
                output = original
                c.notes.append("\(input.name): dosya zaten iyi sıkıştırılmış; boyutu korundu.")
            } else {
                let saved = Int((1 - Double(output.count) / Double(max(1, before))) * 100)
                c.notes.append("\(input.name): \(Int64(before).fileSize) → \(Int64(output.count).fileSize) (%\(saved) küçüldü)")
            }
            let url = c.out("\(stem(input.name))_sikistirilmis.pdf")
            try output.write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func grayscale(_ c: ToolContext) async throws -> [URL] {
        var urls: [URL] = []
        for input in c.inputs {
            let source = try await c.pdfData(input)
            let document = try PDFiumDocument(data: source)
            var rasterPages: [Int] = []
            for index in 0..<document.pageCount {
                let complete = try document.withPage(index) { PDFiumImageEdit.grayscaleVector($0) }
                if !complete { rasterPages.append(index) }
            }
            var output = try document.save()
            if !rasterPages.isEmpty {
                output = try PageRasterizer.rasterize(output, pages: rasterPages, grayscale: true)
                c.notes.append("\(rasterPages.count) sayfa gri görüntüye çevrildi; metni seçilebilir kaldı.")
            }
            let url = c.out("\(stem(input.name))_gri.pdf")
            try output.write(to: url)
            urls.append(url)
        }
        return urls
    }
}
