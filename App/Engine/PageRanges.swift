import Foundation

/// Masaüstüyle aynı sayfa aralığı sözdizimi: "1-3, 5, 8-", "son", "tek", "çift". Sonuçlar 0 tabanlıdır.
enum PageRanges {
    static func groups(_ spec: String, count n: Int) throws -> [[Int]] {
        let text = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if ["", "all", "tümü", "hepsi"].contains(text) { return [Array(0..<n)] }
        if ["odd", "tek"].contains(text) { return [Array(stride(from: 0, to: n, by: 2))] }
        if ["even", "çift", "cift"].contains(text) { return [Array(stride(from: 1, to: n, by: 2))] }
        var groups: [[Int]] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if let dash = piece.firstIndex(of: "-") {
                let left = piece[..<dash].trimmingCharacters(in: .whitespaces)
                let right = piece[piece.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                let a = try left.isEmpty ? 1 : number(left, n)
                let b = try right.isEmpty ? n : number(right, n)
                groups.append(a <= b ? Array((a - 1)...(b - 1)) : Array(((b - 1)...(a - 1)).reversed()))
            } else {
                groups.append([try number(piece, n) - 1])
            }
        }
        if groups.isEmpty { throw ToolError("Sayfa aralığı boş.") }
        return groups
    }

    /// Tekrarsız, yazıldığı sırada sayfa listesi.
    static func pages(_ spec: String, count n: Int) throws -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for page in try groups(spec, count: n).joined() where seen.insert(page).inserted {
            result.append(page)
        }
        return result
    }

    /// [0,1,2,4] -> "1-3,5"
    static func human(_ pages: [Int]) -> String {
        let sorted = pages.sorted()
        guard var start = sorted.first else { return "" }
        var previous = start
        var parts: [String] = []
        for page in sorted.dropFirst() {
            if page == previous + 1 { previous = page; continue }
            parts.append(start == previous ? "\(start + 1)" : "\(start + 1)-\(previous + 1)")
            start = page
            previous = page
        }
        parts.append(start == previous ? "\(start + 1)" : "\(start + 1)-\(previous + 1)")
        return parts.joined(separator: ",")
    }

    private static func number(_ token: String, _ n: Int) throws -> Int {
        if ["son", "last", "z"].contains(token) { return n }
        guard let value = Int(token) else { throw ToolError("Geçersiz sayfa numarası: '\(token)'") }
        guard value >= 1, value <= n else { throw ToolError("Sayfa \(value) yok. Belgede \(n) sayfa var.") }
        return value
    }
}
