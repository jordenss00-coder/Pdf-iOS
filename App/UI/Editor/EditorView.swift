import PDFKit
import PhotosUI
import SwiftUI

/// Tam ekran PDF düzenleyici. "Bitti" ile düzenlemeleri aracın seçeneklerine yazar.
struct EditorView: View {
    let tool: Tool
    @StateObject private var model: EditorModel
    let onFinish: (OptionValues) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Prompt: Identifiable {
        case text(PDFPage, CGPoint)
        case note(PDFPage, CGPoint)
        case link(PDFPage, PDFAnnotation)
        case editText(PDFPage, PDFSelection)
        case combo(PDFPage, CGRect)
        var id: String {
            switch self {
            case .text: return "text"
            case .note: return "note"
            case .link: return "link"
            case .editText: return "edit"
            case .combo: return "combo"
            }
        }
    }

    @State private var prompt: Prompt?
    @State private var input = ""
    @State private var signing = false
    @State private var signingInitials = false
    @State private var signatureTarget: (PDFPage, CGPoint)?
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var photoTarget: (PDFPage, CGPoint)?
    @State private var exporting = false
    @State private var detected: Int?
    @State private var errorText: String?

    init(tool: Tool, document: PDFDocument, mode: EditorMode, onFinish: @escaping (OptionValues) -> Void) {
        self.tool = tool
        _model = StateObject(wrappedValue: EditorModel(document: document, mode: mode))
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            EditorCanvas(model: model, onTap: handleTap, onArea: { page, annotation in
                input = ""
                prompt = model.tool == .combo ? .combo(page, annotation.bounds) : .link(page, annotation)
            })
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) { palette }
                .navigationTitle(tool.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Vazgeç") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Sayfa \(model.pageIndex + 1) / \(model.document.pageCount)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            finish()
                        } label: {
                            if exporting { ProgressView() } else { Text("Bitti").bold() }
                        }
                        .disabled(exporting)
                    }
                }
                .sheet(item: $prompt) { prompt in
                    promptSheet(prompt)
                        .presentationDetents([.height(280)])
                }
                .sheet(isPresented: $signing) {
                    SignaturePad { image in
                        signing = false
                        place(image, at: signatureTarget, widthRatio: 0.3)
                    }
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $signingInitials) {
                    SignaturePad(initials: true) { image in
                        signingInitials = false
                        place(image, at: signatureTarget, widthRatio: 0.12)
                    }
                    .presentationDetents([.medium, .large])
                }
                .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    Task { @MainActor in
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            place(image, at: photoTarget, widthRatio: 0.4)
                        }
                        photo = nil
                    }
                }
                .alert("Hata", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text(errorText ?? "")
                }
        }
    }

    // MARK: Araç çubuğu

    private var palette: some View {
        VStack(spacing: 10) {
            if showsStyleControls {
                HStack(spacing: 14) {
                    ForEach([UIColor.systemRed, .systemBlue, .black, .systemGreen, .systemOrange, .systemPurple], id: \.self) { color in
                        Circle()
                            .fill(Color(uiColor: color))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.9 : 0), lineWidth: 2.5).padding(-4))
                            .onTapGesture { model.color = color }
                    }
                    Spacer()
                    if model.tool == .text || model.tool == .date {
                        Stepper("\(Int(model.fontSize)) pt", value: $model.fontSize, in: 6...72, step: 2)
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                    } else {
                        Slider(value: $model.lineWidth, in: 1...12)
                            .frame(maxWidth: 110)
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(EditorTool.tools(for: model.mode)) { item in
                            toolButton(item)
                        }
                        if model.mode == .formCreate {
                            Button(action: detectFields) {
                                VStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars").font(.title3)
                                    Text(detected.map { "\($0) alan" } ?? "Algıla").font(.caption2.weight(.semibold))
                                }
                                .frame(width: 66, height: 52)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                Divider().frame(height: 36)
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.title3)
                }
                .disabled(!model.canUndo)
                .accessibilityLabel("Geri al")
                Button(role: .destructive) {
                    model.deleteSelected()
                } label: {
                    Image(systemName: "trash").font(.title3)
                }
                .disabled(model.selected == nil)
                .accessibilityLabel("Seçili öğeyi sil")
                .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var showsStyleControls: Bool {
        [.text, .date, .draw, .rectangle, .ellipse, .line, .arrow].contains(model.tool)
    }

    private func toolButton(_ item: EditorTool) -> some View {
        let active = model.tool == item
        return Button {
            withAnimation(.snappy) { model.tool = item }
            if item == .signature { signatureTarget = nil; signing = true }
            if item == .initials { signatureTarget = nil; signingInitials = true }
            if item == .image { photoTarget = nil; choosingPhoto = true }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol).font(.title3)
                Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .frame(width: 66, height: 52)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? AnyShapeStyle(tool.categoryInfo.gradient) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: active)
    }

    // MARK: Dokunarak yerleştirme

    private func handleTap(_ page: PDFPage, _ point: CGPoint) {
        switch model.tool {
        case .text:
            input = ""
            prompt = .text(page, point)
        case .note:
            input = ""
            prompt = .note(page, point)
        case .signature:
            signatureTarget = (page, point)
            signing = true
        case .initials:
            signatureTarget = (page, point)
            signingInitials = true
        case .date:
            addText(Self.today, on: page, at: point)
        case .image:
            photoTarget = (page, point)
            choosingPhoto = true
        case .editText:
            guard let selection = page.selectionForLine(at: point), let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            input = text
            prompt = .editText(page, selection)
        case .checkbox:
            let box = PDFAnnotation(bounds: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), forType: .widget, withProperties: nil)
            box.widgetFieldType = .button
            box.widgetControlType = .checkBoxControl
            box.fieldName = "Kutu \(Int.random(in: 1000...9999))"
            box.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            model.add(box, to: page)
        default:
            break
        }
    }

    static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: Date())
    }

    /// Dokunulan yere serbest metin ekler (yazı boyutu ve renk araç çubuğundan).
    private func addText(_ text: String, on page: PDFPage, at point: CGPoint) {
        let font = UIFont.systemFont(ofSize: model.fontSize)
        let size = (text as NSString).boundingRect(with: CGSize(width: 400, height: 2000), options: .usesLineFragmentOrigin,
                                                     attributes: [.font: font], context: nil).size
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height - 4, width: size.width + 10, height: size.height + 6),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = model.color
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        model.add(annotation, to: page)
    }

    private func place(_ image: UIImage, at target: (PDFPage, CGPoint)?, widthRatio: CGFloat) {
        guard let (page, point) = target else {
            model.addImage(image, widthRatio: widthRatio)
            return
        }
        let width = page.bounds(for: .cropBox).width * widthRatio
        let height = width * image.size.height / max(1, image.size.width)
        model.add(ImageAnnotation(image: image, bounds: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)), to: page)
    }

    @ViewBuilder
    private func promptSheet(_ prompt: Prompt) -> some View {
        NavigationStack {
            Form {
                switch prompt {
                case .text:
                    TextField("Metin", text: $input, axis: .vertical).lineLimit(1...5)
                case .note:
                    TextField("Not", text: $input, axis: .vertical).lineLimit(2...6)
                case .link:
                    TextField("https://ornek.com", text: $input)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .editText:
                    TextField("Yeni metin", text: $input, axis: .vertical).lineLimit(1...4)
                case .combo:
                    TextField("Seçenekler (virgülle ayır)", text: $input, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle(promptTitle(prompt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { self.prompt = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle") { commit(prompt) }.bold()
                }
            }
        }
    }

    private func promptTitle(_ prompt: Prompt) -> String {
        switch prompt {
        case .text: return "Metin ekle"
        case .note: return "Not ekle"
        case .link: return "Bağlantı adresi"
        case .editText: return "Yazıyı düzelt"
        case .combo: return "Açılır liste seçenekleri"
        }
    }

    private func commit(_ prompt: Prompt) {
        defer { self.prompt = nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .text(let page, let point):
            guard !text.isEmpty else { return }
            addText(text, on: page, at: point)
        case .combo(let page, let rect):
            let choices = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !choices.isEmpty else { return }
            let field = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            field.widgetFieldType = .choice
            field.isListChoice = false
            field.choices = choices
            field.widgetStringValue = choices[0]
            field.fieldName = "Liste \(Int.random(in: 1000...9999))"
            field.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            field.font = .systemFont(ofSize: max(8, min(14, rect.height * 0.6)))
            model.add(field, to: page)
        case .note(let page, let point):
            guard !text.isEmpty else { return }
            let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), forType: .text, withProperties: nil)
            annotation.contents = text
            annotation.color = .systemYellow
            annotation.iconType = .note
            model.add(annotation, to: page)
        case .link(let page, let area):
            guard !text.isEmpty else { return }
            var address = text
            if address.range(of: "^(https?|mailto|tel):", options: [.regularExpression, .caseInsensitive]) == nil {
                address = "https://" + address
            }
            let link = PDFAnnotation(bounds: area.bounds, forType: .link, withProperties: nil)
            link.url = URL(string: address)
            let border = PDFBorder()
            border.lineWidth = 0
            link.border = border
            model.add(link, to: page)
        case .editText(let page, let selection):
            let bounds = selection.bounds(for: page)
            let marker = MarkerAnnotation(kind: .textEdit, bounds: bounds, replacement: text, original: selection.string ?? "")
            if let attributed = selection.attributedString, attributed.length > 0 {
                let attributes = attributed.attributes(at: 0, effectiveRange: nil)
                let font = attributes[.font] as? UIFont
                let color = attributes[.foregroundColor] as? UIColor ?? .black
                let name = font?.fontName.lowercased() ?? ""
                marker.style = TextSurgery.Style(size: font?.pointSize ?? bounds.height * 0.8, color: color,
                                                 bold: name.contains("bold"), italic: name.contains("italic") || name.contains("oblique"),
                                                 family: font?.familyName ?? "Helvetica")
            }
            model.add(marker, to: page)
        }
    }

    // MARK: Form algılama

    private func detectFields() {
        guard let data = model.document.dataRepresentation(), let engine = try? PDFiumDocument(data: data) else { return }
        var count = 0
        for index in 0..<model.document.pageCount {
            guard let page = model.document.page(at: index), let fields = try? FormDetector.detect(engine, page: index) else { continue }
            for field in fields {
                let annotation = PDFAnnotation(bounds: field.rect, forType: .widget, withProperties: nil)
                count += 1
                if field.checkbox {
                    annotation.widgetFieldType = .button
                    annotation.widgetControlType = .checkBoxControl
                    annotation.fieldName = "Kutu \(count)"
                } else {
                    annotation.widgetFieldType = .text
                    annotation.fieldName = field.name.isEmpty ? "Alan \(count)" : field.name
                    annotation.font = .systemFont(ofSize: max(8, min(12, field.rect.height * 0.7)))
                }
                annotation.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
                model.add(annotation, to: page)
            }
        }
        detected = count
    }

    // MARK: Bitir

    private func finish() {
        exporting = true
        var values = OptionValues()
        switch model.mode {
        case .redact:
            var areas: [RedactTools.Area] = []
            for marker in model.markers where marker.kind == .redact {
                guard let page = marker.page else { continue }
                let rect = EditorExport.visual(marker.bounds, on: page)
                areas.append(RedactTools.Area(page: model.document.index(for: page), x: rect.minX, y: rect.minY, w: rect.width, h: rect.height))
            }
            values["areas"] = .string(String(data: (try? JSONEncoder().encode(areas)) ?? Data(), encoding: .utf8) ?? "")
        case .crop:
            if let marker = model.markers.first(where: { $0.kind == .crop }), let page = marker.page {
                let rect = EditorExport.visual(marker.bounds, on: page)
                values["rect"] = .string("\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)")
                values["page"] = .number(Double(model.document.index(for: page)))
            }
        default:
            do {
                let url = try EditorExport.export(model.document)
                values["edited_file"] = .file(url)
            } catch {
                errorText = error.localizedDescription
                exporting = false
                return
            }
        }
        exporting = false
        onFinish(values)
        dismiss()
    }
}
