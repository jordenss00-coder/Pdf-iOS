import SwiftUI
import PDFium

@main
struct PDFAtolyeApp: App {
    init() {
        FPDF_InitLibrary()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
