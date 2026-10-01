import PencilKit
import PhotosUI
import SwiftUI

/// İmza oluşturma: çiz, yaz ya da fotoğraftan al. Son imza tekrar kullanılmak üzere saklanır.
struct SignaturePad: View {
    var initials = false
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var canvas = PKCanvasView()
    @State private var typed = ""
    @State private var fontName = "Snell Roundhand"
    @State private var photo: PhotosPickerItem?
    @State private var photoImage: UIImage?
    @State private var saved: UIImage?

    private let fonts = ["Snell Roundhand", "Bradley Hand", "Noteworthy", "Savoye LET", "Zapfino"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let saved {
                    Button {
                        onDone(saved)
                    } label: {
                        HStack {
                            Image(uiImage: saved).resizable().scaledToFit().frame(height: 44)
                            Spacer()
                            Text(initials ? "Kayıtlı parafı kullan" : "Kayıtlı imzayı kullan").font(.subheadline.weight(.semibold))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
                Picker("Yöntem", selection: $mode) {
                    Text("Çiz").tag(0)
                    Text("Yaz").tag(1)
                    Text("Fotoğraf").tag(2)
                }
                .pickerStyle(.segmented)
                Group {
                    switch mode {
                    case 0:
                        ZStack(alignment: .bottom) {
                            CanvasView(canvas: canvas)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                            Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 40)
                        }
                        .frame(height: 200)
                        .overlay(alignment: .topTrailing) {
                            Button("Temizle") { canvas.drawing = PKDrawing() }
                                .font(.caption.weight(.semibold))
                                .padding(10)
                        }
                    case 1:
                        VStack(spacing: 12) {
                            TextField(initials ? "Baş harfleriniz" : "Adınız Soyadınız", text: $typed)
                                .textFieldStyle(.roundedBorder)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(fonts, id: \.self) { font in
                                        Text(typed.isEmpty ? (initials ? "AY" : "İmza") : typed)
                                            .font(.custom(font, size: 26))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 14)
                                            .frame(height: 70)
                                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(fontName == font ? Color.accentColor : .clear, lineWidth: 2))
                                            .onTapGesture { fontName = font }
                                    }
                                }
                            }
                        }
                        .frame(height: 200)
                    default:
                        VStack(spacing: 12) {
                            if let photoImage {
                                Image(uiImage: photoImage).resizable().scaledToFit().frame(height: 140)
                            }
                            PhotosPicker(selection: $photo, matching: .images) {
                                Label(photoImage == nil ? (initials ? "Paraf fotoğrafı seç" : "İmza fotoğrafı seç") : "Başka fotoğraf seç", systemImage: "photo")
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(height: 200)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle(initials ? "Paraf" : "İmza")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { saved = SignatureStore.load(initials: initials) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle") { finish() }.bold()
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        photoImage = SignatureStore.removingBackground(image)
                    }
                }
            }
        }
    }

    private func finish() {
        var image: UIImage?
        switch mode {
        case 0:
            let drawing = canvas.drawing
            guard !drawing.strokes.isEmpty else { return }
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: drawing.bounds.insetBy(dx: -8, dy: -8), scale: 3)
            }
        case 1:
            let text = typed.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            let font = UIFont(name: fontName, size: 64) ?? .italicSystemFont(ofSize: 64)
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor(red: 0.05, green: 0.12, blue: 0.45, alpha: 1)])
            let size = attributed.size()
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            image = UIGraphicsImageRenderer(size: CGSize(width: size.width + 16, height: size.height + 8), format: format).image { _ in
                attributed.draw(at: CGPoint(x: 8, y: 4))
            }
        default:
            image = photoImage
        }
        guard let image else { return }
        SignatureStore.save(image, initials: initials)
        onDone(image)
    }
}

private struct CanvasView: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.05, green: 0.12, blue: 0.45, alpha: 1), width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}
}

enum SignatureStore {
    private static func url(initials: Bool) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(initials ? "paraf.png" : "imza.png")
    }

    static func load(initials: Bool = false) -> UIImage? {
        UIImage(contentsOfFile: url(initials: initials).path)
    }

    static func save(_ image: UIImage, initials: Bool = false) {
        try? image.pngData()?.write(to: url(initials: initials), options: .completeFileProtection)
    }

    /// Kağıt fotoğrafındaki beyaz arka planı saydam yapar.
    static func removingBackground(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width, height = cgImage.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let brightness = (Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / 3
            if brightness > 170 {
                buffer[index] = 0
                buffer[index + 1] = 0
                buffer[index + 2] = 0
                buffer[index + 3] = 0
            }
        }
        guard let output = context.makeImage() else { return image }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
}
