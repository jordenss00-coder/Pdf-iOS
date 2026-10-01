import CoreImage
import UIKit
import Vision

enum ScanTools {
    static func scan(_ c: ToolContext) async throws -> [URL] {
        let filter = c.options.string("filter", "auto")
        let crop = c.options.bool("auto_crop", true)
        var options = c.options
        if options["page_size"] == nil { options["page_size"] = .string("A4") }
        var frames: [ImageConverter.Frame] = []
        for input in c.inputs {
            frames += try ImageConverter.frames(input.url)
        }
        let context = CIContext()
        let data = ImageConverter.pdf(frames: frames, options: options) { image in
            enhance(image, filter: filter, crop: crop, context: context)
        }
        let url = c.out("tarama.pdf")
        if c.options.bool("ocr") {
            let document = try PDFiumDocument(data: data)
            let (codes, _) = OCRTools.languages(c.options.string("language", "tur+eng"))
            let words = try OCRTools.addTextLayer(to: document, pages: Array(0..<document.pageCount), languages: codes, skipText: false) { fraction, message in
                c.progress(fraction, message)
            }
            if words > 0 { c.notes.append("\(words) kelime tanındı; PDF aranabilir.") }
            try document.save().write(to: url)
        } else {
            try data.write(to: url)
        }
        return [url]
    }

    /// Belge kenarlarını bulup düzeltir ve seçilen görünüm filtresini uygular.
    static func enhance(_ image: UIImage, filter: String, crop: Bool, context: CIContext) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        var picture = CIImage(cgImage: cgImage).oriented(CGImagePropertyOrientation(image.imageOrientation))
        if crop, let corrected = straightened(picture) {
            picture = corrected
        }
        switch filter {
        case "gray":
            picture = picture.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        case "bw":
            picture = documentEnhanced(picture)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 2.2, kCIInputBrightnessKey: 0.05])
        case "auto":
            picture = documentEnhanced(picture)
        default:
            break
        }
        guard let output = context.createCGImage(picture, from: picture.extent) else { return image }
        return UIImage(cgImage: output)
    }

    private static func documentEnhanced(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIDocumentEnhancer") else {
            return image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.0, forKey: "inputAmount")
        return filter.outputImage ?? image
    }

    /// Fotoğraftaki belgeyi bulur; belge görüntünün büyük kısmını zaten kaplıyorsa (ör. kamera taraması) dokunmaz.
    private static func straightened(_ image: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let document = request.results?.first, document.confidence > 0.6 else { return nil }
        let extent = image.extent
        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
        }
        let area = abs((document.topRight.x - document.bottomLeft.x) * (document.topRight.y - document.bottomLeft.y))
        guard area < 0.85, area > 0.15 else { return nil }
        return image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(document.topLeft), "inputTopRight": point(document.topRight),
            "inputBottomLeft": point(document.bottomLeft), "inputBottomRight": point(document.bottomRight),
        ])
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        case .left: self = .left
        default: self = .up
        }
    }
}
