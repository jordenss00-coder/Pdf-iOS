import Foundation

/// PKCS#12 sertifikasıyla PDF dijital imzası (adbe.pkcs7.detached).
enum PDFSigner {
    static func sign(_ data: Data, certificate: Data, password: String, reason: String, location: String) throws -> Data {
        throw ToolError("Sertifikalı dijital imza bir sonraki güncellemede gelecek. Görsel imzan eklendi.")
    }
}
