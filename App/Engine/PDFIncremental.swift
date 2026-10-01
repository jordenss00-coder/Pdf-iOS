import Foundation

/// Klasik çapraz başvuru tablolu bir PDF'in sonuna artımlı güncelleme ekler (orijinal baytlar değişmez).
/// Girdi önce PDFKit ile yeniden yazılmalı (nesne akışı/xref akışı olmayan düz dosya).
struct PDFIncremental {
    let original: Data
    private let text: String
    let root: Int
    let size: Int
    let previous: Int
    let idEntry: String?
    private(set) var objects: [(number: Int, body: Data)] = []
    private var next: Int

    init(_ data: Data) throws {
        original = data
        // Latin-1 her baytı tek karaktere eşler; ikili akışlar da güvenle okunur.
        text = String(data: data, encoding: .isoLatin1) ?? ""
        guard let trailerRange = text.range(of: "trailer", options: .backwards),
              let dictionary = PDFIncremental.dictionary(in: text, from: trailerRange.upperBound) else {
            throw ToolError("Bu PDF yapısı desteklenmiyor (çapraz başvuru tablosu bulunamadı).")
        }
        guard let rootValue = PDFIncremental.firstGroup(#"/Root\s+(\d+)\s+\d+\s+R"#, in: dictionary).flatMap(Int.init),
              let sizeValue = PDFIncremental.firstGroup(#"/Size\s+(\d+)"#, in: dictionary).flatMap(Int.init),
              let startRange = text.range(of: "startxref", options: .backwards),
              let previousValue = PDFIncremental.firstGroup(#"^\s*(\d+)"#, in: String(text[startRange.upperBound...])).flatMap(Int.init) else {
            throw ToolError("PDF'in son bölümü okunamadı.")
        }
        root = rootValue
        size = sizeValue
        previous = previousValue
        idEntry = dictionary.range(of: #"/ID\s*\[[^\]]*\]"#, options: .regularExpression).map { String(dictionary[$0]) }
        next = sizeValue
    }

    /// N numaralı nesnenin sözlüğü ("<< ... >>"); dosyadaki son tanım kullanılır.
    func dictionary(of number: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[\\r\\n\\s])\(number)\\s+0\\s+obj"),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        return PDFIncremental.dictionary(in: text, from: range.upperBound)
    }

    /// N numaralı nesnenin "obj" ile "endobj" arasındaki ham içeriği (ör. dolaylı diziler için).
    func objectBody(of number: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[\\r\\n\\s])\(number)\\s+0\\s+obj"),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text),
              let end = text.range(of: "endobj", range: range.upperBound..<text.endIndex) else { return nil }
        return String(text[range.upperBound..<end.lowerBound])
    }

    /// Yeni nesne ekler ve numarasını döndürür.
    mutating func add(_ body: Data) -> Int {
        let number = next
        next += 1
        objects.append((number, body))
        return number
    }

    mutating func add(_ body: String) -> Int {
        add(Data(body.utf8))
    }

    /// Var olan nesneyi yeni içerikle değiştirir.
    mutating func replace(_ number: Int, with body: String) {
        objects.append((number, Data(body.utf8)))
    }

    /// Ayırılmış ama henüz içeriği yazılmamış nesne numarası.
    mutating func reserve() -> Int {
        let number = next
        next += 1
        return number
    }

    mutating func set(_ number: Int, body: Data) {
        objects.append((number, body))
    }

    func build(info: Int? = nil) -> Data {
        var output = original
        if output.last != 0x0A { output.append(0x0A) }
        var offsets: [(Int, Int)] = []
        for (number, body) in objects {
            offsets.append((number, output.count))
            output.append(Data("\(number) 0 obj\n".utf8))
            output.append(body)
            output.append(Data("\nendobj\n".utf8))
        }
        let xref = output.count
        var table = "xref\n"
        for (number, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            table += "\(number) 1\n" + String(format: "%010d 00000 n \n", offset)
        }
        var trailer = "trailer\n<< /Size \(max(next, size)) /Root \(root) 0 R /Prev \(previous)"
        if let info { trailer += " /Info \(info) 0 R" }
        trailer += " \(idEntry ?? PDFIncremental.newID()) >>\nstartxref\n\(xref)\n%%EOF\n"
        output.append(Data((table + trailer).utf8))
        return output
    }

    static func newID() -> String {
        let hex = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "/ID [<\(hex)><\(hex)>]"
    }

    /// Verilen konumdan sonraki ilk "<< ... >>" sözlüğü (iç içe sözlükler dahil).
    static func dictionary(in text: String, from start: String.Index) -> String? {
        guard let open = text.range(of: "<<", range: start..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("<<") {
                depth += 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix(">>") {
                depth -= 1
                index = text.index(index, offsetBy: 2)
                if depth == 0 { return String(text[open.lowerBound..<index]) }
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Sözlükten bir anahtarı (ve değerini) çıkarır; basit değerler, başvurular ve diziler için.
    static func removing(_ key: String, from dictionary: String) -> String {
        let pattern = "/\(key)\\s*(\\d+\\s+\\d+\\s+R|\\[[^\\]]*\\]|<<[^<>]*>>|\\([^)]*\\)|/[^\\s/<>\\[\\]()]+|[\\d.]+)"
        return dictionary.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Sözlüğün sonuna (kapanış ">>" öncesine) metin ekler.
    static func appending(_ entries: String, to dictionary: String) -> String {
        guard let close = dictionary.range(of: ">>", options: .backwards) else { return dictionary }
        return String(dictionary[..<close.lowerBound]) + " " + entries + " >>"
    }
}
