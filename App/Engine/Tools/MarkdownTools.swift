import PDFKit

extension ConvertTools {
    static func pdfToMarkdown(_ c: ToolContext) async throws -> [URL] {
        var urls: [URL] = []
        var empty = 0
        for input in c.inputs {
            let data = try await c.pdfData(input)
            let document = try PDFiumDocument(data: data)
            let kit = PDFDocument(data: data)
            var sections: [String] = []
            for index in try PageRanges.pages(c.options.string("pages"), count: document.pageCount) {
                let text = try document.text(page: index)
                var content = MarkdownLayout.markdown(text.lines, headings: c.options.bool("headings", true),
                                                      tables: c.options.bool("tables", true))
                if content.isEmpty {
                    empty += 1
                    content = "_Bu sayfada çıkarılabilir metin yok. Önce OCR uygulayın._"
                }
                if c.options.bool("links", true), let page = kit?.page(at: index) {
                    let links = Set(page.annotations.compactMap { $0.url ?? ($0.action as? PDFActionURL)?.url }
                        .map(\.absoluteString).filter { $0.lowercased().hasPrefix("http") }).sorted()
                    if !links.isEmpty {
                        content += "\n\n" + links.map { "- <\($0.replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "<", with: "%3C"))>" }
                            .joined(separator: "\n")
                    }
                }
                sections.append((c.options.bool("page_markers", true) ? "<!-- Sayfa \(index + 1) -->\n\n" : "") + content)
            }
            let url = c.out("\(stem(input.name)).md")
            try (sections.joined(separator: "\n\n---\n\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        if empty > 0 {
            c.warnings.append("\(empty) sayfada metin bulunamadı. Taranmış belgeler için önce OCR kullan.")
        }
        return urls
    }
}

/// Satır düzeninden Markdown: başlıklar yazı boyutundan, listeler madde işaretinden,
/// tablolar ise birden fazla satırda hizalı sütun boşluklarından algılanır.
enum MarkdownLayout {
    static func markdown(_ lines: [TextLine], headings: Bool, tables: Bool) -> String {
        let sizes = lines.map(\.fontSize).filter { $0 > 0 }.sorted()
        let body = sizes.isEmpty ? 12 : sizes[sizes.count / 2]
        var blocks: [String] = []
        var index = 0
        while index < lines.count {
            if tables {
                var rows: [[String]] = []
                var k = index
                while k < lines.count {
                    let cells = self.cells(lines[k])
                    guard cells.count >= 2, rows.isEmpty || cells.count == rows[0].count else { break }
                    rows.append(cells)
                    k += 1
                }
                if rows.count >= 3 {
                    var table = rows.map { "| " + $0.map(escape).joined(separator: " | ") + " |" }
                    table.insert("| " + Array(repeating: "---", count: rows[0].count).joined(separator: " | ") + " |", at: 1)
                    blocks.append(table.joined(separator: "\n"))
                    index = k
                    continue
                }
            }
            let line = lines[index]
            let raw = line.text.trimmingCharacters(in: .whitespaces)
            let bullets: Set<Character> = ["•", "●", "▪", "◦", "–"]
            if let first = raw.first, bullets.contains(first) {
                blocks.append("- " + escape(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if headings && line.fontSize >= body * 1.2 {
                blocks.append((line.fontSize >= body * 1.6 ? "# " : "## ") + escape(raw))
            } else {
                blocks.append(escape(raw))
            }
            index += 1
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Satırı, yazı boyutunun belirgin şekilde üstündeki yatay boşluklardan hücrelere böler.
    static func cells(_ line: TextLine) -> [String] {
        let scalars = Array(line.text.unicodeScalars)
        guard scalars.count == line.chars.count else { return [line.text] }
        let threshold = max(line.fontSize * 1.5, 8)
        var cells: [String] = []
        var current = String.UnicodeScalarView()
        var lastRight: CGFloat?
        for (scalar, box) in zip(scalars, line.chars) {
            if scalar.properties.isWhitespace {
                current.append(scalar)
                continue
            }
            if let lastRight, !box.isNull, box.minX - lastRight > threshold {
                cells.append(String(current).trimmingCharacters(in: .whitespaces))
                current = String.UnicodeScalarView()
            }
            current.append(scalar)
            if !box.isNull { lastRight = box.maxX }
        }
        cells.append(String(current).trimmingCharacters(in: .whitespaces))
        return cells.filter { !$0.isEmpty }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]<>|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
