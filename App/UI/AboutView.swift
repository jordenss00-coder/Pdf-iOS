import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AboutView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirming = false
    @State private var cleared = false
    @State private var apiKey = ""
    @State private var keyHint = APIKeyStore.hint
    @State private var claudeModel = ClaudeClient.model

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
            Section("Görünüm") {
                Picker("Tema", selection: $appearance) {
                    Text("Sistem").tag("system")
                    Text("Açık").tag("light")
                    Text("Koyu").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section {
                Label(onDeviceAI ? "Apple Intelligence bu cihazda hazır." : "Apple Intelligence bu cihazda kullanılamıyor.",
                      systemImage: onDeviceAI ? "sparkles" : "exclamationmark.triangle")
                if let keyHint {
                    LabeledContent("Claude API anahtarı", value: keyHint)
                    TextField("Model", text: $claudeModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { ClaudeClient.model = claudeModel }
                    Button("Anahtarı sil", role: .destructive) {
                        APIKeyStore.delete()
                        self.keyHint = nil
                    }
                } else {
                    SecureField("Claude API anahtarı (sk-ant-…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Anahtarı kaydet") {
                        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty, APIKeyStore.save(key) else { return }
                        apiKey = ""
                        keyHint = APIKeyStore.hint
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Yapay zekâ")
            } footer: {
                Text("Özetleme ve çeviri önce cihazdaki Apple Intelligence ile yapılır. Kullanılamıyorsa ve kendi Anthropic API anahtarını eklediysen belge metni Claude'a gönderilir. Anahtar yalnızca bu cihazın anahtar zincirinde saklanır.")
            }
            Section("Gizlilik") {
                Label("Belgeler bu cihazda işlenir; yalnızca Claude anahtarı eklediysen yapay zekâ araçları metni Anthropic'e gönderir.", systemImage: "lock.shield")
                Label("Hesap, giriş ya da internet bağlantısı gerekmez.", systemImage: "wifi.slash")
                Label("Sonuçlar Dosyalar › iPhone'umda › PDF Atölye klasöründe durur; istediğin zaman silebilirsin.", systemImage: "folder")
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label(cleared ? "Dosyalar silindi" : "Dosyalarımı sil", systemImage: cleared ? "checkmark" : "trash")
                }
                .confirmationDialog("Tüm sonuçlar ve geçici dosyalar silinsin mi?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Tümünü sil", role: .destructive) {
                        model.deleteEverything()
                        cleared = true
                    }
                } message: {
                    Text("Bu işlem geri alınamaz. Kaydettiğin ya da paylaştığın kopyalar etkilenmez.")
                }
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
        .navigationTitle("Ayarlar")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { ClaudeClient.model = claudeModel }
    }

    private var onDeviceAI: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
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
