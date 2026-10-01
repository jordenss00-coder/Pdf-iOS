import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var licenses: [(String, String)] {
        guard let folder = Bundle.main.url(forResource: "PDFium-licenses", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, text)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    GradientIcon(symbol: "doc.on.doc.fill", colors: Brand.colors, size: 56)
                    Text("PDF Atölye").font(.title2.weight(.bold))
                    Text("Sürüm \(version)").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Gizlilik") {
                Label("Belgeler yalnızca bu cihazda işlenir; hiçbir sunucuya gönderilmez.", systemImage: "lock.shield")
                Label("Hesap, giriş ya da internet bağlantısı gerekmez.", systemImage: "wifi.slash")
                Label("Sonuçlar Dosyalar › iPhone'umda › PDF Atölye klasöründe durur; istediğin zaman silebilirsin.", systemImage: "folder")
            }
            Section("Açık kaynak bileşenler") {
                NavigationLink("PDFium (Google, BSD/Apache)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(licenses, id: \.0) { name, text in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(name).font(.headline)
                                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        .padding()
                    }
                    .navigationTitle("Lisanslar")
                }
            }
        }
        .navigationTitle("Hakkında")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Başka bir uygulamadan "PDF Atölye ile aç" ile gelen dosya için araç seçimi.
struct IncomingSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ToolChooser(title: model.incoming.first?.name ?? "Dosya", kinds: model.incoming.map(\.kind)) { tool in
            let inputs = model.incoming
            model.showIncoming = false
            model.open(tool, with: inputs)
        }
        .presentationDetents([.medium, .large])
    }
}
