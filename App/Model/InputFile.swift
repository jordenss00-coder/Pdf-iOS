import Foundation
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case pdf, image, word, excel, powerpoint, html, certificate

    static func detect(_ url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }

    var extensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .image: return ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tif", "tiff", "gif", "jfif"]
        case .word: return ["doc", "docx", "docm", "odt", "rtf", "txt", "dot", "dotx", "pages"]
        case .excel: return ["xls", "xlsx", "xlsm", "ods", "csv", "numbers"]
        case .powerpoint: return ["ppt", "pptx", "pptm", "pps", "ppsx", "odp", "key"]
        case .html: return ["html", "htm", "mhtml", "webarchive"]
        case .certificate: return ["pfx", "p12"]
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .pdf: return [.pdf]
        case .image: return [.image]
        default: return extensions.compactMap { UTType(filenameExtension: $0) }
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "görsel"
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerpoint: return "PowerPoint"
        case .html: return "HTML"
        case .certificate: return "sertifika"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .word: return "doc.text"
        case .excel: return "tablecells"
        case .powerpoint: return "rectangle.on.rectangle"
        case .html: return "globe"
        case .certificate: return "checkmark.seal"
        }
    }
}

/// Uygulamanın kendi geçici klasörüne kopyalanmış girdi dosyası.
struct InputFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let kind: FileKind
    var name: String
    var password: String?

    init(url: URL, kind: FileKind, name: String? = nil, password: String? = nil) {
        id = UUID()
        self.url = url
        self.kind = kind
        self.name = name ?? url.lastPathComponent
        self.password = password
    }

    var size: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Dışarıdan gelen dosyayı (güvenlik kapsamlı olabilir) uygulama klasörüne kopyalar.
    static func importing(_ source: URL, as kind: FileKind? = nil) throws -> InputFile {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let kind = kind ?? FileKind.detect(source) else {
            throw ToolError("'\(source.lastPathComponent)' desteklenmeyen bir dosya türü.")
        }
        let folder = Storage.inputs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        return InputFile(url: target, kind: kind)
    }

    /// Bellekteki veriyi (ör. fotoğraf, tarama) girdi dosyasına çevirir.
    static func saving(_ data: Data, name: String, kind: FileKind) throws -> InputFile {
        let folder = Storage.inputs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try data.write(to: target)
        return InputFile(url: target, kind: kind)
    }
}

/// Uygulamanın dosya konumları.
enum Storage {
    static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PDFAtolye", isDirectory: true)
    }

    static var inputs: URL { temporary.appendingPathComponent("Girdiler", isDirectory: true) }

    static func newWorkFolder() throws -> URL {
        let url = temporary.appendingPathComponent("Is-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Sonuçların kalıcı olarak saklandığı, Dosyalar uygulamasında görünen klasör.
    static var results: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bir gün önceki geçici dosyaları temizler.
    static func cleanTemporary(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > age {
                try? fm.removeItem(at: item)
            }
        }
    }
}
