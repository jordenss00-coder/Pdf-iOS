import PDFKit
import SwiftUI

/// PDF görüntüleyici ve araçlara göre dokunuşları işleyen şeffaf katman.
struct EditorCanvas: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    /// Dokunarak yerleştirilen araçlar (metin, not, imza, görsel, yazı düzeltme, onay kutusu).
    var onTap: (PDFPage, CGPoint) -> Void
    /// Alan çizildikten sonra bilgi isteyen araçlar (bağlantı).
    var onArea: (PDFPage, PDFAnnotation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let pdfView = PDFView()
        pdfView.document = model.document
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pdfView)
        let overlay = TouchOverlay()
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.coordinator = context.coordinator
        container.addSubview(overlay)
        context.coordinator.pdfView = pdfView
        context.coordinator.overlay = overlay
        model.view = pdfView
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.onTap = onTap
        context.coordinator.onArea = onArea
        context.coordinator.overlay?.isUserInteractionEnabled = model.tool != .pan
    }

    final class TouchOverlay: UIView {
        weak var coordinator: Coordinator?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            coordinator?.began(touch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            coordinator?.moved(touch.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            coordinator?.ended(touch.location(in: self))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.cancelled()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: EditorModel
        var onTap: (PDFPage, CGPoint) -> Void = { _, _ in }
        var onArea: (PDFPage, PDFAnnotation) -> Void = { _, _ in }
        weak var pdfView: PDFView?
        weak var overlay: TouchOverlay?
        private var page: PDFPage?
        private var start: CGPoint = .zero
        private var startLocation: CGPoint = .zero
        private var points: [CGPoint] = []
        private var preview: PDFAnnotation?
        private var moving: (annotation: PDFAnnotation, origin: CGPoint, original: CGRect)?

        init(model: EditorModel) {
            self.model = model
        }

        @objc func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage else { return }
            model.pageIndex = model.document.index(for: page)
        }

        func began(_ location: CGPoint) {
            guard let pdfView, let page = pdfView.page(for: location, nearest: true) else { return }
            let point = pdfView.convert(location, to: page)
            self.page = page
            start = point
            startLocation = location
            points = [point]
            if model.tool == .select {
                // Form oluştururken alanlar da seçilip taşınabilir.
                if let annotation = page.annotations.last(where: {
                    $0.bounds.insetBy(dx: -8, dy: -8).contains(point) && ($0.type != "Widget" || model.mode == .formCreate)
                }) {
                    model.selected = annotation
                    moving = (annotation, point, annotation.bounds)
                } else {
                    model.selected = nil
                }
            }
        }

        func moved(_ location: CGPoint) {
            guard let pdfView, let page else { return }
            let point = pdfView.convert(location, to: page)
            switch model.tool {
            case .select:
                guard let moving else { return }
                model.move(moving.annotation, to: moving.original.offsetBy(dx: point.x - moving.origin.x, dy: point.y - moving.origin.y))
            case .draw:
                points.append(point)
                replacePreview(ink(points), on: page)
            case .line, .arrow:
                replacePreview(line(from: start, to: point, arrow: model.tool == .arrow), on: page)
            case let tool where tool.dragsRect || tool == .link || tool == .combo:
                let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                replacePreview(area(tool, rect: rect), on: page)
            default:
                break
            }
        }

        func ended(_ location: CGPoint) {
            defer {
                preview = nil
                moving = nil
                page = nil
            }
            guard let pdfView, let page else { return }
            let point = pdfView.convert(location, to: page)
            let isTap = hypot(location.x - startLocation.x, location.y - startLocation.y) < 8
            switch model.tool {
            case .select:
                if let moving, !isTap { model.recordMove(moving.annotation, from: moving.original) }
            case .draw, .line, .arrow:
                guard let preview else { return }
                page.removeAnnotation(preview)
                if !isTap || model.tool == .draw { model.add(preview, to: page) }
            case .text, .note, .signature, .initials, .date, .image, .editText, .checkbox:
                if isTap { onTap(page, point) }
            case let tool where tool.dragsRect || tool == .link || tool == .combo:
                guard let preview else { return }
                page.removeAnnotation(preview)
                guard preview.bounds.width > 6, preview.bounds.height > 6 else { return }
                if tool == .cropArea {
                    for marker in model.markers where marker.kind == .crop { marker.page?.removeAnnotation(marker) }
                }
                if tool == .link || tool == .combo {
                    onArea(page, preview)
                } else {
                    model.add(preview, to: page)
                }
            default:
                break
            }
        }

        func cancelled() {
            if let preview, let page { page.removeAnnotation(preview) }
            preview = nil
            moving = nil
            page = nil
        }

        private func replacePreview(_ annotation: PDFAnnotation?, on page: PDFPage) {
            if let preview { page.removeAnnotation(preview) }
            preview = annotation
            if let annotation { page.addAnnotation(annotation) }
        }

        private func border(_ width: CGFloat) -> PDFBorder {
            let border = PDFBorder()
            border.lineWidth = width
            return border
        }

        private func ink(_ points: [CGPoint]) -> PDFAnnotation? {
            guard let first = points.first else { return nil }
            let width = model.lineWidth
            var box = CGRect(origin: first, size: .zero)
            for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
            box = box.insetBy(dx: -width - 2, dy: -width - 2)
            let path = UIBezierPath()
            func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - box.minX, y: p.y - box.minY) }
            path.move(to: local(first))
            if points.count == 1 {
                path.addLine(to: local(CGPoint(x: first.x + 0.1, y: first.y + 0.1)))
            }
            for index in 1..<max(1, points.count) {
                let previous = points[index - 1], current = points[index]
                let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: local(middle), controlPoint: local(previous))
            }
            if let last = points.last { path.addLine(to: local(last)) }
            let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            annotation.add(path)
            annotation.color = model.color
            annotation.border = border(width)
            return annotation
        }

        private func line(from start: CGPoint, to end: CGPoint, arrow: Bool) -> PDFAnnotation {
            let width = model.lineWidth
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                .insetBy(dx: -width * 4 - 6, dy: -width * 4 - 6)
            let annotation = PDFAnnotation(bounds: box, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - box.minX, y: start.y - box.minY)
            annotation.endPoint = CGPoint(x: end.x - box.minX, y: end.y - box.minY)
            annotation.color = model.color
            annotation.border = border(width)
            if arrow {
                annotation.endLineStyle = .closedArrow
                annotation.interiorColor = model.color
            }
            return annotation
        }

        private func area(_ tool: EditorTool, rect: CGRect) -> PDFAnnotation? {
            switch tool {
            case .rectangle, .ellipse:
                let annotation = PDFAnnotation(bounds: rect, forType: tool == .rectangle ? .square : .circle, withProperties: nil)
                annotation.color = model.color
                annotation.border = border(model.lineWidth)
                return annotation
            case .highlight:
                let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                annotation.quadrilateralPoints = [
                    NSValue(cgPoint: CGPoint(x: 0, y: rect.height)), NSValue(cgPoint: CGPoint(x: rect.width, y: rect.height)),
                    NSValue(cgPoint: .zero), NSValue(cgPoint: CGPoint(x: rect.width, y: 0)),
                ]
                return annotation
            case .whiteout: return MarkerAnnotation(kind: .whiteout, bounds: rect)
            case .redactArea: return MarkerAnnotation(kind: .redact, bounds: rect)
            case .cropArea: return MarkerAnnotation(kind: .crop, bounds: rect)
            case .field:
                let field = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
                field.widgetFieldType = .text
                field.fieldName = "Alan \(Int.random(in: 1000...9999))"
                field.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
                field.font = .systemFont(ofSize: max(8, min(14, rect.height * 0.6)))
                return field
            case .signatureField:
                let field = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
                field.widgetFieldType = .signature
                field.fieldName = "İmza \(Int.random(in: 1000...9999))"
                field.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.12)
                field.border = border(1)
                return field
            case .link, .combo:
                let link = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
                link.color = .systemBlue
                link.border = border(1)
                return link
            default:
                return nil
            }
        }
    }
}
