import Foundation
import Security

/// İsteğe bağlı: kullanıcının kendi Anthropic API anahtarıyla Claude (masaüstündeki yapay zekâ yolu).
/// Yalnızca Apple Intelligence kullanılamadığında ve kullanıcı anahtar eklediyse devreye girer.
enum ClaudeClient {
    static let defaultModel = "claude-sonnet-5-5"
    private static let modelKey = "claude-model"

    static var isConfigured: Bool { APIKeyStore.load() != nil }

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static func ask(_ prompt: String, instructions: String) async throws -> String {
        guard let key = APIKeyStore.load() else {
            throw ToolError("Claude API anahtarı eklenmemiş.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolError("Claude'a bağlanılamadı. İnternet bağlantını kontrol et.")
        }
        return try text(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Messages API yanıtından metni çıkarır; hataları anlaşılır Türkçe iletiye çevirir.
    static func text(from data: Data, status: Int) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            switch status {
            case 401: throw ToolError("Claude API anahtarı geçersiz. Ayarlar'dan kontrol et.")
            case 403: throw ToolError("API anahtarının bu modele erişim izni yok.")
            case 404: throw ToolError("Claude modeli bulunamadı (\(model)). Ayarlar'daki model adını kontrol et.")
            case 429: throw ToolError("Claude kullanım sınırına ulaşıldı; biraz sonra tekrar dene.")
            case 500...599: throw ToolError("Claude şu an yanıt veremiyor; biraz sonra tekrar dene.")
            default: throw ToolError("Claude yanıt veremedi: \(detail)")
            }
        }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        if text.isEmpty {
            if json?["stop_reason"] as? String == "refusal" { throw ToolError("Claude bu içerik için yanıt vermeyi reddetti.") }
            throw ToolError("Claude boş yanıt döndürdü.")
        }
        return text
    }
}

/// API anahtarı yalnızca bu cihazın anahtar zincirinde saklanır (yedeklere ve diğer cihazlara geçmez).
enum APIKeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jordenss00.pdfatolye.anthropic",
        kSecAttrAccount as String: "api-key",
    ]

    static func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Ekranda göstermek için anahtarın son dört karakteri.
    static var hint: String? {
        load().map { "…" + String($0.suffix(4)) }
    }
}
