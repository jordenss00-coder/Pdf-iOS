import Foundation
import PDFKit

/// Kullanıcıya olduğu gibi gösterilecek hata.
struct ToolError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ToolResult {
    var files: [URL]
    var warnings: [String] = []
    var notes: [String] = []
    /// Dosya dışında gösterilecek metin (ör. özet, karşılaştırma raporu).
    var text: String? = nil
}

/// Bir araç çalışmasının girdileri, seçenekleri ve çıktı klasörü.
final class ToolContext {
    let tool: Tool
    let inputs: [InputFile]
    let options: OptionValues
    let workDir: URL
    var warnings: [String] = []
    var notes: [String] = []
    var text: String?
    private let report: (Double, String?) -> Void
    private var used = Set<String>()

    init(tool: Tool, inputs: [InputFile], options: OptionValues, workDir: URL,
         progress: @escaping (Double, String?) -> Void = { _, _ in }) {
        self.tool = tool
        self.inputs = inputs
        self.options = options
        self.workDir = workDir
        report = progress
    }

    var first: InputFile {
        get throws {
            guard let file = inputs.first else { throw ToolError("Önce bir dosya ekle.") }
            return file
        }
    }

    func progress(_ fraction: Double, _ message: String? = nil) {
        report(min(1, max(0, fraction)), message)
    }

    /// Çalışma klasöründe benzersiz bir çıktı yolu.
    func out(_ name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var candidate = clean
        var counter = 2
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return workDir.appendingPathComponent(candidate)
    }

    /// Girdiyi şifresi çözülmüş PDF verisi olarak döndürür; görsel, Office ve HTML dosyalarını önce PDF'e çevirir.
    func pdfData(_ input: InputFile) async throws -> Data {
        switch input.kind {
        case .pdf:
            let data = try Data(contentsOf: input.url)
            guard let probe = PDFDocument(data: data) else {
                // PDFKit açamıyorsa PDFium ile onarmayı dene.
                if let repaired = try? PDFiumDocument(data: data, password: input.password).save(),
                   PDFDocument(data: repaired) != nil {
                    return repaired
                }
                throw ToolError("'\(input.name)' açılamadı. Dosya bozuk olabilir; 'PDF Onar' aracını dene.")
            }
            guard probe.isEncrypted else { return data }
            if probe.isLocked {
                guard let password = input.password, probe.unlock(withPassword: password) else {
                    throw ToolError("'\(input.name)' parola korumalı. Önce parolayı gir.")
                }
            }
            return try PDFiumDocument(data: data, password: input.password).save(removeSecurity: true)
        case .image:
            return try ImageConverter.pdf(from: [input.url], options: OptionValues())
        case .word, .excel, .powerpoint:
            return try await OfficeConverter.pdf(from: input.url)
        case .html:
            return try await OfficeConverter.pdf(fromHTMLFile: input.url, headerFooter: false)
        case .certificate:
            throw ToolError("'\(input.name)' bir PDF değil.")
        }
    }

    func pdf(_ input: InputFile) async throws -> PDFDocument {
        guard let document = PDFDocument(data: try await pdfData(input)) else {
            throw ToolError("'\(input.name)' açılamadı.")
        }
        return document
    }
}

enum Engine {
    /// Bu sürümde çalışan araçlar; diğerleri arayüzde "yakında" olarak görünür.
    static let available: Set<String> = [
        "merge", "split", "remove_pages", "extract_pages", "organize", "rotate", "nup", "resize_pages",
        "watermark", "page_numbers", "header_footer", "metadata", "protect", "unlock", "flatten", "repair",
        "images_to_pdf", "word_to_pdf", "excel_to_pdf", "ppt_to_pdf", "html_to_pdf", "scan",
        "pdf_to_images", "pdf_to_text", "pdf_to_markdown", "ocr", "compress", "grayscale",
        "redact", "find_replace", "pdf_to_word", "pdf_to_excel", "pdf_to_ppt",
        "edit", "sign", "edit_text", "form", "form_create", "crop",
        "pdf_to_pdfa", "compare", "ai_summarize", "ai_translate",
    ]

    static func run(tool: Tool, inputs: [InputFile], options: OptionValues,
                    progress: @escaping (Double, String?) -> Void = { _, _ in }) async throws -> ToolResult {
        if inputs.count < tool.minFiles {
            throw ToolError(tool.minFiles <= 1 ? "Önce bir dosya ekle." : "Bu araç için en az \(tool.minFiles) dosya gerekli.")
        }
        if let max = tool.maxFiles, inputs.count > max {
            throw ToolError("Bu araç en fazla \(max) dosya alır.")
        }
        for input in inputs where !tool.accepts.contains(input.kind) {
            throw ToolError("'\(input.name)' bu araç için uygun bir dosya değil.")
        }
        if let message = tool.validate?(options, inputs) {
            throw ToolError(message)
        }
        let context = ToolContext(tool: tool, inputs: inputs, options: options,
                                  workDir: try Storage.newWorkFolder(), progress: progress)
        let files = try await dispatch(context)
        guard !files.isEmpty else { throw ToolError("Sonuç dosyası oluşmadı.") }
        return ToolResult(files: files, warnings: context.warnings, notes: context.notes, text: context.text)
    }

    private static func dispatch(_ c: ToolContext) async throws -> [URL] {
        switch c.tool.id {
        case "merge": return try await PageTools.merge(c)
        case "split": return try await PageTools.split(c)
        case "remove_pages": return try await PageTools.removePages(c)
        case "extract_pages": return try await PageTools.extractPages(c)
        case "organize": return try await PageTools.organize(c)
        case "rotate": return try await PageTools.rotate(c)
        case "nup": return try await PageTools.nUp(c)
        case "resize_pages": return try await PageTools.resize(c)
        case "watermark": return try await StampTools.watermark(c)
        case "page_numbers": return try await StampTools.pageNumbers(c)
        case "header_footer": return try await StampTools.headerFooter(c)
        case "metadata": return try await DocumentTools.metadata(c)
        case "protect": return try await DocumentTools.protect(c)
        case "unlock": return try await DocumentTools.unlock(c)
        case "flatten": return try await DocumentTools.flatten(c)
        case "repair": return try await DocumentTools.repair(c)
        case "images_to_pdf": return try await ConvertTools.imagesToPDF(c)
        case "word_to_pdf", "excel_to_pdf", "ppt_to_pdf": return try await ConvertTools.officeToPDF(c)
        case "html_to_pdf": return try await ConvertTools.htmlToPDF(c)
        case "pdf_to_images": return try await ConvertTools.pdfToImages(c)
        case "pdf_to_text": return try await ConvertTools.pdfToText(c)
        case "pdf_to_markdown": return try await ConvertTools.pdfToMarkdown(c)
        case "ocr": return try await OCRTools.ocr(c)
        case "scan": return try await ScanTools.scan(c)
        case "compress": return try await OptimizeTools.compress(c)
        case "grayscale": return try await OptimizeTools.grayscale(c)
        case "redact": return try await RedactTools.redact(c)
        case "find_replace": return try await TextTools.findReplace(c)
        case "pdf_to_word": return try await OfficeExportTools.pdfToWord(c)
        case "pdf_to_excel": return try await OfficeExportTools.pdfToExcel(c)
        case "pdf_to_ppt": return try await OfficeExportTools.pdfToPowerPoint(c)
        case "edit", "sign", "edit_text", "form", "form_create": return try await EditorTools.finish(c)
        case "crop": return try await EditorTools.crop(c)
        case "pdf_to_pdfa": return try await ArchiveTools.pdfToPDFA(c)
        case "compare": return try await CompareTools.compare(c)
        case "ai_summarize": return try await AITools.summarize(c)
        case "ai_translate": return try await AITools.translate(c)
        default:
            throw ToolError("Bu araç bir sonraki güncellemede gelecek.")
        }
    }
}

/// Dosya adının uzantısız kısmı.
func stem(_ name: String) -> String {
    let base = (name as NSString).deletingPathExtension
    return base.isEmpty ? "dosya" : base
}
