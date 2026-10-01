import PDFKit
import UIKit

/// Mevcut sayfalara yazı/görsel basan araçlar (PDFium katmanıyla; notlar, bağlantılar ve formlar korunur).
enum StampTools {
    static func watermark(_ c: ToolContext) async throws -> [URL] {
        let kind = c.options.string("kind", "text")
        let opacity = CGFloat(c.options.number("opacity", 0.3))
        let angle = CGFloat(c.options.number("rotation", 45)) * .pi / 180
        let position = c.options.string("position", "middle-center")
        let tile = position == "tile"
        let under = c.options.string("layer", "over") == "under"
        let text = c.options.string("text", "GİZLİ").trimmingCharacters(in: .whitespacesAndNewlines)
        let size = CGFloat(c.options.number("size", 60))
        let font = Fonts.font(c.options.string("family", "Helvetica"), size: size, bold: c.options.bool("bold", true))
        let color = UIColor(hex: c.options.string("color", "#cf006d"), fallback: .red)
        var image: UIImage?
        if kind == "image" {
            guard let data = c.options.data("image"), let loaded = UIImage(data: data) else {
                throw ToolError("Filigran için bir görsel seç.")
            }
            image = loaded
        } else if text.isEmpty {
            throw ToolError("Filigran yazısını gir.")
        }
        let scale = CGFloat(c.options.number("scale", 40)) / 100
        var urls: [URL] = []
        for (k, input) in c.inputs.enumerated() {
            c.progress(Double(k) / Double(c.inputs.count), input.name)
            let document = try PDFiumDocument(data: try await c.pdfData(input))
            let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
            try document.stamp(pages: pages, under: under) { _, page, context in
                context.saveGState()
                context.setAlpha(opacity)
                if let image {
                    let width = page.width * scale
                    let height = width * image.size.height / max(1, image.size.width)
                    let item = CGSize(width: width, height: height)
                    var centers: [CGPoint] = []
                    if tile {
                        for y in stride(from: 20 + height / 2, to: page.height + height / 2, by: max(height * 1.6, 1)) {
                            for x in stride(from: 20 + width / 2, to: page.width + width / 2, by: max(width * 1.5, 1)) {
                                centers.append(CGPoint(x: x, y: y))
                            }
                        }
                    } else {
                        let origin = Layout.position(position, item: item, in: page, margin: 36)
                        centers.append(CGPoint(x: origin.x + width / 2, y: origin.y + height / 2))
                    }
                    for center in centers {
                        context.saveGState()
                        context.translateBy(x: center.x, y: center.y)
                        context.rotate(by: -angle)
                        image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
                        context.restoreGState()
                    }
                } else {
                    let string = PDFDraw.attributed(text, font: font, color: color)
                    let bounds = string.size()
                    var centers: [CGPoint] = []
                    if tile {
                        for y in stride(from: size * 2, to: page.height, by: max(size * 4, 1)) {
                            for x in stride(from: bounds.width / 2, to: page.width + bounds.width / 2, by: max(bounds.width + size * 2, 1)) {
                                centers.append(CGPoint(x: x, y: y))
                            }
                        }
                    } else {
                        let origin = Layout.position(position, item: CGSize(width: bounds.width, height: size), in: page, margin: 36)
                        centers.append(CGPoint(x: origin.x + bounds.width / 2, y: origin.y + size / 2))
                    }
                    for center in centers {
                        context.saveGState()
                        context.translateBy(x: center.x, y: center.y)
                        context.rotate(by: -angle)
                        string.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
                        context.restoreGState()
                    }
                }
                context.restoreGState()
            }
            let url = c.out("\(stem(input.name))_filigranli.pdf")
            try document.save().write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func pageNumbers(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try PDFiumDocument(data: try await c.pdfData(input))
        let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
        let position = c.options.string("position", "bottom-center")
        let margin = Layout.margin(c.options.string("margin", "recommended"), fallback: CGFloat(c.options.number("margin", 28)))
        let start = c.options.int("start", 1)
        var format = c.options.string("format", "{n}")
        if format == "custom" { format = c.options.string("custom_format", "{n}") }
        if format.isEmpty { format = "{n}" }
        let size = CGFloat(c.options.number("size", 11))
        let font = Fonts.font(c.options.string("family", "Helvetica"), size: size, bold: c.options.bool("bold"))
        let color = UIColor(hex: c.options.string("color", "#000000"))
        let total = pages.count + start - 1
        let mirror = c.options.bool("mirror")
        var numbers: [Int: Int] = [:]
        for (k, page) in pages.enumerated() { numbers[page] = start + k }
        try document.stamp(pages: pages) { index, page, _ in
            let number = numbers[index] ?? start
            let string = PDFDraw.attributed(Layout.fill(format, page: number, total: total, file: input.name), font: font, color: color)
            var spot = position
            if mirror && number % 2 == 0 {
                spot = spot.replacingOccurrences(of: "left", with: "__").replacingOccurrences(of: "right", with: "left")
                    .replacingOccurrences(of: "__", with: "right")
            }
            let bounds = string.size()
            string.draw(at: Layout.position(spot, item: bounds, in: page, margin: margin))
        }
        let url = c.out("\(stem(input.name))_numarali.pdf")
        try document.save().write(to: url)
        return [url]
    }

    static func headerFooter(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try PDFiumDocument(data: try await c.pdfData(input))
        let pages = try PageRanges.pages(c.options.string("pages"), count: document.pageCount)
        let margin = Layout.margin(c.options.string("margin", "recommended"))
        let size = CGFloat(c.options.number("size", 10))
        let font = Fonts.font(c.options.string("family", "Helvetica"), size: size, bold: c.options.bool("bold"))
        let color = UIColor(hex: c.options.string("color", "#333333"))
        let slots: [(String, String)] = [
            ("top-left", "header_left"), ("top-center", "header_center"), ("top-right", "header_right"),
            ("bottom-left", "footer_left"), ("bottom-center", "footer_center"), ("bottom-right", "footer_right"),
        ].map { ($0.0, c.options.string($0.1)) }
        guard slots.contains(where: { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ToolError("Üst veya alt bilgi için en az bir metin yaz.")
        }
        let total = document.pageCount
        let line = c.options.bool("line")
        let hasHeader = slots.prefix(3).contains { !$0.1.isEmpty }
        let hasFooter = slots.suffix(3).contains { !$0.1.isEmpty }
        try document.stamp(pages: pages) { index, page, context in
            for (spot, template) in slots where !template.isEmpty {
                let string = PDFDraw.attributed(Layout.fill(template, page: index + 1, total: total, file: input.name), font: font, color: color)
                let bounds = string.size()
                string.draw(at: Layout.position(spot, item: CGSize(width: bounds.width, height: size * 1.2), in: page, margin: margin))
            }
            if line {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(0.5)
                if hasHeader {
                    let y = margin + size * 1.2 + 4
                    context.strokeLineSegments(between: [CGPoint(x: margin, y: y), CGPoint(x: page.width - margin, y: y)])
                }
                if hasFooter {
                    let y = page.height - margin - size * 1.2 - 4
                    context.strokeLineSegments(between: [CGPoint(x: margin, y: y), CGPoint(x: page.width - margin, y: y)])
                }
            }
        }
        let url = c.out("\(stem(input.name))_ustaltbilgi.pdf")
        try document.save().write(to: url)
        return [url]
    }
}
