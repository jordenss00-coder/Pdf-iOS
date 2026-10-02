import SwiftUI
import UIKit

@main
struct PDFAtolyeApp: App {
    @StateObject private var model = AppModel()

    init() {
        Storage.cleanTemporary()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { model.handleOpen($0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .tool(let id, let inputs):
                        if let tool = Catalog.tool(id) {
                            ToolView(tool: tool, inputs: inputs)
                        }
                    case .workflows:
                        WorkflowsView()
                    }
                }
        }
        .tint(Brand.tint)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $model.showIncoming) {
            IncomingSheet()
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-demo"), index + 1 < arguments.count,
               let tool = Catalog.tool(arguments[index + 1]), model.path.isEmpty {
                model.open(tool, with: DemoSupport.sampleInputs(for: tool))
            }
        }
    }
}

/// CI ekran görüntüleri için örnek girdiler ("-demo <araç>").
enum DemoSupport {
    static func sampleInputs(for tool: Tool) -> [InputFile] {
        if tool.accepts.contains(.pdf), let file = try? InputFile.saving(samplePDF(), name: "Örnek Sözleşme.pdf", kind: .pdf) {
            return tool.minFiles > 1 ? [file, (try? InputFile.saving(samplePDF(), name: "Ek.pdf", kind: .pdf)) ?? file] : [file]
        }
        return []
    }

    static func samplePDF(pages: Int = 3) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                let title = NSAttributedString(string: "Hizmet Sözleşmesi – Sayfa \(page)",
                                               attributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
                title.draw(at: CGPoint(x: 56, y: 64))
                let body = "Taraflar arasında İstanbul'da imzalanan bu sözleşme; ödeme koşulları, gizlilik ve teslim tarihlerini düzenler. " +
                    "Çalışma saatleri, ücretler ve şartlar aşağıda açıklanmıştır."
                NSAttributedString(string: body, attributes: [.font: UIFont.systemFont(ofSize: 13)])
                    .draw(in: CGRect(x: 56, y: 110, width: 483, height: 200))
            }
        }
    }
}
