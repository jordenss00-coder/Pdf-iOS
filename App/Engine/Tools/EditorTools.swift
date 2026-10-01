import PDFKit
import PDFium
import UIKit

/// Düzenleyicideki yer tutucuları (görsel, imza, beyaz örtü, yazı düzeltme) gerçek sayfa içeriğine işler.
enum EditorExport {
    static func visual(_ bounds: CGRect, on page: PDFPage) -> CGRect {
        let geometry = PageGeometry(box: page.bounds(for: .cropBox), rotation: ((page.rotation / 90) % 4 + 4) % 4)
        return geometry.visual(left: Double(bounds.minX), bottom: Double(bounds.minY), right: Double(bounds.maxX), top: Double(bounds.maxY))
    }

    private struct Stamp {
        var rect: CGRect
        var image: UIImage?
    }

    private struct Edit {
        var bounds: CGRect
        var replacement: String
        var style: TextSurgery.Style?
    }

    static func export(_ document: PDFDocument) throws -> URL {
        var stamps: [Int: [Stamp]] = [:]
        var edits: [Int: [Edit]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let image = annotation as? ImageAnnotation {
                    stamps[index, default: []].append(Stamp(rect: visual(image.bounds, on: page), image: image.image))
                    page.removeAnnotation(image)
                } else if let marker = annotation as? MarkerAnnotation {
                    switch marker.kind {
                    case .whiteout:
                        stamps[index, default: []].append(Stamp(rect: visual(marker.bounds, on: page), image: nil))
                    case .textEdit:
                        edits[index, default: []].append(Edit(bounds: marker.bounds, replacement: marker.replacement, style: marker.style))
                    case .redact, .crop:
                        break
                    }
                    page.removeAnnotation(marker)
                }
            }
        }
        guard let data = document.dataRepresentation() else { throw ToolError("PDF kaydedilemedi.") }
        let engine = try PDFiumDocument(data: data)
        var insertions: [Int: [TextSurgery.Placement]] = [:]
        for (index, list) in edits {
            try engine.withPage(index) { page in
                let geometry = PDFiumDocument.geometry(page)
                let chars = TextSurgery.characters(page)
                var plan = TextSurgery.Plan()
                for edit in list {
                    let area = edit.bounds.insetBy(dx: -1, dy: -1)
                    let hits = chars.filter { !$0.generated && !$0.box.isNull && area.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                    guard let first = hits.first(where: { !$0.scalar.properties.isWhitespace }) ?? hits.first else { continue }
                    for hit in hits { plan.remove.insert(hit.index) }
                    insertions[index, default: []].append(TextSurgery.Placement(text: edit.replacement, style: edit.style ?? TextSurgery.style(of: first),
                                                                                 baseline: geometry.visual(first.origin), rotation: geometry.rotation))
                }
                let surgery = TextSurgery.apply(plan, chars: chars, page: page, document: engine.handle)
                insertions[index, default: []] += TextSurgery.placements(surgery.fallbacks, geometry: geometry)
            }
        }
        let pages = Set(stamps.keys).union(insertions.keys).sorted()
        if !pages.isEmpty {
            try engine.stamp(pages: pages) { index, _, context in
                for stamp in stamps[index] ?? [] {
                    if let image = stamp.image {
                        image.draw(in: stamp.rect)
                    } else {
                        context.setFillColor(UIColor.white.cgColor)
                        context.fill(stamp.rect)
                    }
                }
                TextSurgery.draw(insertions[index] ?? [], in: context)
            }
        }
        let url = Storage.temporary.appendingPathComponent("duzenleyici-\(UUID().uuidString).pdf")
        try FileManager.default.createDirectory(at: Storage.temporary, withIntermediateDirectories: true)
        try engine.save().write(to: url)
        return url
    }
}

/// Düz PDF'te doldurulabilir alan adaylarını bulur: çizgiler, küçük kareler ve "Ad: ____" boşlukları.
enum FormDetector {
    struct Field {
        var rect: CGRect
        var checkbox: Bool
        var name: String
    }

    static func detect(_ document: PDFiumDocument, page index: Int) throws -> [Field] {
        try document.withPage(index) { page in
            var fields: [Field] = []
            for k in 0..<FPDFPage_CountObjects(page) {
                guard let object = FPDFPage_GetObject(page, k), FPDFPageObj_GetType(object) == 2 else { continue }
                var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
                let width = CGFloat(right - left), height = CGFloat(top - bottom)
                if height <= 2.5 && width >= 40 {
                    fields.append(Field(rect: CGRect(x: CGFloat(left), y: CGFloat(top), width: width, height: 16), checkbox: false, name: ""))
                } else if abs(width - height) < 3 && width >= 7 && width <= 22 {
                    fields.append(Field(rect: CGRect(x: CGFloat(left), y: CGFloat(bottom), width: width, height: height), checkbox: true, name: ""))
                }
            }
            for line in TextSurgery.lines(TextSurgery.characters(page)) {
                var run: [TextSurgery.Char] = []
                func close(at position: Int) {
                    defer { run = [] }
                    guard run.count >= 4 else { return }
                    let box = run.map(\.box).filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
                    guard !box.isNull else { return }
                    let label = String(String.UnicodeScalarView(line.chars[..<(position - run.count)].map(\.scalar)))
                        .components(separatedBy: CharacterSet(charactersIn: ":.")).last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let previousLabel = label.isEmpty ? String(String.UnicodeScalarView(line.chars[..<(position - run.count)].map(\.scalar)))
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": .").union(.whitespaces)) : label
                    fields.append(Field(rect: CGRect(x: box.minX, y: box.minY, width: box.width, height: max(14, box.height + 4)),
                                        checkbox: false, name: String(previousLabel.suffix(40))))
                }
                for (position, char) in line.chars.enumerated() {
                    if char.scalar == "_" { run.append(char) } else { close(at: position) }
                }
                close(at: line.chars.count)
            }
            // Üst üste binen adayları ele.
            var unique: [Field] = []
            for field in fields where !unique.contains(where: { $0.rect.intersection(field.rect).width * $0.rect.intersection(field.rect).height > field.rect.width * field.rect.height * 0.5 }) {
                unique.append(field)
            }
            return unique
        }
    }
}

enum EditorTools {
    static func finish(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        var data: Data
        if let edited = c.options.url("edited_file") {
            data = try Data(contentsOf: edited)
        } else if c.tool.id == "sign" && c.options.bool("cert_on") {
            data = try await c.pdfData(input)
        } else {
            throw ToolError("Önce düzenleyiciyi aç ve değişikliklerini yap.")
        }
        if c.options.bool("flatten"), let document = PDFDocument(data: data) {
            let url = c.out("duzlestir.pdf")
            try PDFKitIO.write(document, to: url, options: [.burnInAnnotationsOption: true])
            data = try Data(contentsOf: url)
        }
        if c.tool.id == "sign" && c.options.bool("cert_on") {
            data = try DigitalSignature.sign(data, options: c.options)
            c.notes.append("Belge sertifikayla dijital olarak imzalandı.")
        }
        let suffixes = ["edit": "duzenlenmis", "sign": "imzali", "edit_text": "duzeltilmis", "form": "doldurulmus", "form_create": "form"]
        let url = c.out("\(stem(input.name))_\(suffixes[c.tool.id] ?? "duzenlenmis").pdf")
        try data.write(to: url)
        return [url]
    }

    static func crop(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let data = try await c.pdfData(input)
        guard let document = PDFDocument(data: data) else { throw ToolError("'\(input.name)' açılamadı.") }
        let engine = try PDFiumDocument(data: data)
        var changed = 0
        if c.options.string("mode", "manual") == "auto" {
            let padding = CGFloat(c.options.number("padding", 10))
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let content = try engine.withPage(index) { page -> CGRect in
                    let geometry = PDFiumDocument.geometry(page)
                    var box = CGRect.null
                    for k in 0..<FPDFPage_CountObjects(page) {
                        guard let object = FPDFPage_GetObject(page, k) else { continue }
                        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                        guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else { continue }
                        let rect = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom))
                        if FPDFPageObj_GetType(object) == 2 && rect.width >= geometry.box.width * 0.98 && rect.height >= geometry.box.height * 0.98 { continue }
                        box = box.union(rect)
                    }
                    return box.isNull ? box : box.insetBy(dx: -padding, dy: -padding).intersection(geometry.box)
                }
                guard !content.isNull, content.width > 10, content.height > 10 else { continue }
                page.setBounds(content, for: .cropBox)
                changed += 1
            }
        } else {
            let parts = c.options.string("rect").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { throw ToolError("Kırpılacak alanı sayfa üzerinde seç.") }
            let visual = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            let pages = c.options.string("apply", "all") == "current" ? [c.options.int("page", 0)] : Array(0..<document.pageCount)
            for index in pages {
                guard let page = document.page(at: index) else { continue }
                let geometry = try engine.geometry(page: index)
                let target = geometry.page(visual).intersection(geometry.box)
                guard !target.isNull, target.width >= 10, target.height >= 10 else { continue }
                page.setBounds(target, for: .cropBox)
                changed += 1
            }
        }
        guard changed > 0 else { throw ToolError("Kırpılacak bir alan bulunamadı.") }
        let url = c.out("\(stem(input.name))_kirpilmis.pdf")
        try PDFKitIO.write(document, to: url)
        return [url]
    }
}

/// Sertifikalı dijital imza (PKCS#12). Ayrı dosyada uygulanır.
enum DigitalSignature {
    static func sign(_ data: Data, options: OptionValues) throws -> Data {
        guard let certificate = options.url("cert_file") else { throw ToolError("Sertifika dosyasını seç.") }
        return try PDFSigner.sign(data, certificate: try Data(contentsOf: certificate), password: options.string("cert_password"),
                                  reason: options.string("cert_reason"), location: options.string("cert_location"))
    }
}
