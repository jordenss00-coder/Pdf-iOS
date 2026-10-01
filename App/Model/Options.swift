import Foundation

/// Bir araç seçeneğinin değeri. Seçim listelerinin değerleri metin olarak tutulur.
enum OptionValue: Equatable, Codable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([String])
    case pairs([ReplacePair])
    case data(Data)
    case file(URL)
}

struct ReplacePair: Equatable, Identifiable, Codable {
    var id = UUID()
    var find = ""
    var replace = ""
}

struct Choice: Identifiable, Hashable {
    let value: String
    let label: String
    var detail: String? = nil
    var id: String { value }
}

enum OptionKind {
    case text(placeholder: String? = nil)
    case textarea(placeholder: String? = nil)
    case password
    case check
    case number(min: Double? = nil, max: Double? = nil, step: Double = 1)
    case range(min: Double, max: Double, step: Double, percent: Bool)
    case segmented([Choice])
    case select([Choice])
    case cards([Choice])
    case color
    case position(tile: Bool)
    case checks([Choice])
    case pairs
    case font
    case image
    case certificate
    case note(String)
}

struct ToolOption: Identifiable {
    let key: String
    let label: String
    let kind: OptionKind
    var defaultValue: OptionValue? = nil
    var hint: String? = nil
    var visible: (OptionValues) -> Bool = { _ in true }

    var id: String { key.isEmpty ? label : key }
}

/// Bir aracın seçenek değerleri ve türlerine göre okuma yardımcıları.
struct OptionValues: Equatable, Codable {
    var values: [String: OptionValue] = [:]

    init(_ values: [String: OptionValue] = [:]) {
        self.values = values
    }

    init(defaultsOf options: [ToolOption]) {
        for option in options {
            if let value = option.defaultValue {
                values[option.key] = value
            }
        }
    }

    subscript(key: String) -> OptionValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        switch values[key] {
        case .bool(let value): return value
        case .string(let value): return ["1", "true", "evet", "on"].contains(value.lowercased())
        case .number(let value): return value != 0
        default: return fallback
        }
    }

    func number(_ key: String, _ fallback: Double) -> Double {
        switch values[key] {
        case .number(let value): return value
        case .string(let value):
            return Double(value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? fallback
        case .bool(let value): return value ? 1 : 0
        default: return fallback
        }
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        Int(number(key, Double(fallback)).rounded())
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        switch values[key] {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return fallback
        }
    }

    func list(_ key: String) -> [String] {
        if case .list(let value) = values[key] { return value }
        return []
    }

    func pairs(_ key: String) -> [ReplacePair] {
        if case .pairs(let value) = values[key] { return value }
        return []
    }

    func data(_ key: String) -> Data? {
        if case .data(let value) = values[key] { return value }
        return nil
    }

    func url(_ key: String) -> URL? {
        if case .file(let value) = values[key] { return value }
        return nil
    }
}
