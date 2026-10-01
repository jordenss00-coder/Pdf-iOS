import PDFKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case pan, select, text, draw, highlight, rectangle, ellipse, line, arrow, whiteout, image, note, link
    case signature, editText, redactArea, cropArea, field, checkbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pan: return "Gezin"
        case .select: return "Seç"
        case .text: return "Metin"
        case .draw: return "Çiz"
        case .highlight: return "Vurgula"
        case .rectangle: return "Kutu"
        case .ellipse: return "Elips"
        case .line: return "Çizgi"
        case .arrow: return "Ok"
        case .whiteout: return "Beyaz örtü"
        case .image: return "Görsel"
        case .note: return "Not"
        case .link: return "Bağlantı"
        case .signature: return "İmza"
        case .editText: return "Yazıyı düzelt"
        case .redactArea: return "Karart"
        case .cropArea: return "Kırp"
        case .field: return "Metin alanı"
        case .checkbox: return "Onay kutusu"
        }
    }

    var symbol: String {
        switch self {
        case .pan: return "hand.draw"
        case .select: return "cursorarrow.rays"
        case .text: return "textformat"
        case .draw: return "pencil.tip"
        case .highlight: return "highlighter"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .whiteout: return "eraser"
        case .image: return "photo"
        case .note: return "note.text"
        case .link: return "link"
        case .signature: return "signature"
        case .editText: return "character.cursor.ibeam"
        case .redactArea: return "rectangle.fill"
        case .cropArea: return "crop"
        case .field: return "character.textbox"
        case .checkbox: return "checkmark.square"
        }
    }

    /// Sürükleyerek alan çizen araçlar.
    var dragsRect: Bool {
        [.highlight, .rectangle, .ellipse, .whiteout, .redactArea, .cropArea, .field].contains(self)
    }

    static func tools(for mode: EditorMode) -> [EditorTool] {
        switch mode {
        case .edit: return [.pan, .select, .text, .draw, .highlight, .rectangle, .ellipse, .line, .arrow, .whiteout, .image, .signature, .note, .link, .editText]
        case .sign: return [.pan, .select, .signature, .text, .draw]
        case .crop: return [.pan, .cropArea]
        case .text: return [.pan, .editText, .select]
        case .find: return [.pan]
        case .form: return [.pan]
        case .formCreate: return [.pan, .select, .field, .checkbox]
        case .redact: return [.pan, .redactArea, .select]
        }
    }
}

/// Görsel/imza yer tutucusu; kaydederken sayfa içeriğine basılır.
final class ImageAnnotation: PDFAnnotation {
    let image: UIImage

    init(image: UIImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        image.draw(in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
        UIGraphicsPopContext()
    }
}

/// Düzenleyicide gösterilen, kaydederken işlenen işaretler (beyaz örtü, karartma, kırpma, yazı düzeltme).
final class MarkerAnnotation: PDFAnnotation {
    enum Kind { case whiteout, redact, crop, textEdit }
    let kind: Kind
    var replacement: String
    var original: String
    var style: TextSurgery.Style?

    init(kind: Kind, bounds: CGRect, replacement: String = "", original: String = "") {
        self.kind = kind
        self.replacement = replacement
        self.original = original
        super.init(bounds: bounds, forType: .square, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        switch kind {
        case .whiteout:
            context.setFillColor(UIColor.white.cgColor)
            context.fill(bounds)
        case .redact:
            context.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor)
            context.fill(bounds)
        case .crop:
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(bounds)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
            context.fill(bounds)
        case .textEdit:
            context.setFillColor(UIColor.white.cgColor)
            context.fill(bounds.insetBy(dx: -1, dy: -1))
            UIGraphicsPushContext(context)
            context.translateBy(x: bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            let size = style?.size ?? bounds.height * 0.8
            let font = Fonts.font(style?.family ?? "Helvetica", size: size, bold: style?.bold ?? false, italic: style?.italic ?? false)
            NSAttributedString(string: replacement, attributes: [.font: font, .foregroundColor: style?.color ?? UIColor.black])
                .draw(at: CGPoint(x: 0, y: (bounds.height - font.lineHeight) / 2))
            UIGraphicsPopContext()
        }
        context.restoreGState()
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let document: PDFDocument
    let mode: EditorMode
    @Published var tool: EditorTool = .pan
    @Published var color: UIColor = .systemRed
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 16
    @Published var selected: PDFAnnotation?
    @Published var canUndo = false
    @Published var pageIndex = 0
    weak var view: PDFView?
    private var history: [(PDFAnnotation, PDFPage, CGRect?)] = []

    init(document: PDFDocument, mode: EditorMode) {
        self.document = document
        self.mode = mode
        tool = EditorTool.tools(for: mode).dropFirst().first ?? .pan
        if mode == .redact { color = .black }
        if mode == .sign { color = UIColor(red: 0.05, green: 0.15, blue: 0.55, alpha: 1) }
    }

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        history.append((annotation, page, nil))
        canUndo = true
        selected = annotation
    }

    /// Taşıma/boyutlandırma sonrası geri alma için önceki konumu kaydeder.
    func recordMove(_ annotation: PDFAnnotation, from bounds: CGRect) {
        guard let page = annotation.page else { return }
        history.append((annotation, page, bounds))
        canUndo = true
    }

    func undo() {
        guard let (annotation, page, bounds) = history.popLast() else { return }
        if let bounds {
            move(annotation, to: bounds)
        } else {
            page.removeAnnotation(annotation)
            if selected === annotation { selected = nil }
        }
        canUndo = !history.isEmpty
    }

    func deleteSelected() {
        guard let annotation = selected, let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        history.removeAll { $0.0 === annotation }
        canUndo = !history.isEmpty
        selected = nil
    }

    func move(_ annotation: PDFAnnotation, to bounds: CGRect) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        annotation.bounds = bounds
        page.addAnnotation(annotation)
    }

    var currentPage: PDFPage? {
        view?.currentPage ?? document.page(at: 0)
    }

    /// Görünür sayfanın ortasına yerleştirilecek varsayılan dikdörtgen.
    func centeredRect(size: CGSize, on page: PDFPage) -> CGRect {
        let box = page.bounds(for: .cropBox)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    func addImage(_ image: UIImage, widthRatio: CGFloat = 0.35) {
        guard let page = currentPage else { return }
        let box = page.bounds(for: .cropBox)
        let width = box.width * widthRatio
        let height = width * image.size.height / max(1, image.size.width)
        add(ImageAnnotation(image: image, bounds: centeredRect(size: CGSize(width: width, height: height), on: page)), to: page)
        tool = .select
    }

    var markers: [MarkerAnnotation] {
        (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations.compactMap { $0 as? MarkerAnnotation } ?? [] }
    }
}
