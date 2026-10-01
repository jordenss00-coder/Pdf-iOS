import PDFKit
import SwiftUI

struct ContentView: View {
    @State private var document: PDFDocument?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document)
                } else {
                    ContentUnavailableView("PDF seç", systemImage: "doc.richtext",
                                           description: Text("Açmak için sağ üstteki düğmeye dokun."))
                }
            }
            .navigationTitle("PDF Atölye")
            .toolbar {
                Button("Aç", systemImage: "folder") { importing = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    document = PDFDocument(data: data)
                }
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
