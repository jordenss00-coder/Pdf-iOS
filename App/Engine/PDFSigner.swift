import CryptoKit
import Foundation
import PDFKit
import Security

/// Asgari DER (ASN.1) kodlayıcı/okuyucu; CMS imzası için.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ parts: [[UInt8]]) -> [UInt8] {
        tlv(0x30, parts.flatMap { $0 })
    }

    /// DER'de SET OF öğeleri kodlanmış hallerine göre sıralanır.
    static func set(_ parts: [[UInt8]], sorted: Bool = false) -> [UInt8] {
        let ordered = sorted ? parts.sorted { $0.lexicographicallyPrecedes($1) } : parts
        return tlv(0x31, ordered.flatMap { $0 })
    }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ text: String) -> [UInt8] {
        let arcs = text.split(separator: ".").compactMap { UInt64($0) }
        var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }

    static let null: [UInt8] = [0x05, 0x00]

    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }

    /// Bağlama özel, yapılandırılmış etiket ([n]).
    static func context(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | number, content) }

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    /// Verilen konumdaki TLV'nin etiketi, başlık ve içerik uzunluğu.
    static func read(_ bytes: [UInt8], at index: Int) -> (tag: UInt8, header: Int, length: Int)? {
        guard index + 1 < bytes.count else { return nil }
        let tag = bytes[index], first = bytes[index + 1]
        if first < 0x80 { return (tag, 2, Int(first)) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, index + 1 + count < bytes.count else { return nil }
        var length = 0
        for k in 0..<count { length = (length << 8) | Int(bytes[index + 2 + k]) }
        return (tag, 2 + count, length)
    }

    static func children(_ bytes: [UInt8], start: Int, length: Int) -> [(start: Int, total: Int, tag: UInt8)] {
        var result: [(start: Int, total: Int, tag: UInt8)] = []
        var index = start
        while index < start + length, let item = read(bytes, at: index) {
            result.append((index, item.header + item.length, item.tag))
            index += item.header + item.length
        }
        return result
    }

    /// X.509 sertifikasından ham "veren" adı ve seri numarası (CMS IssuerAndSerialNumber için).
    static func issuerAndSerial(_ certificate: [UInt8]) -> (issuer: [UInt8], serial: [UInt8])? {
        guard let outer = read(certificate, at: 0), let tbs = read(certificate, at: outer.header) else { return nil }
        var fields = children(certificate, start: outer.header + tbs.header, length: tbs.length)
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 3, fields[0].tag == 0x02, fields[2].tag == 0x30 else { return nil }
        let serial = Array(certificate[fields[0].start..<(fields[0].start + fields[0].total)])
        let issuer = Array(certificate[fields[2].start..<(fields[2].start + fields[2].total)])
        return (issuer, serial)
    }
}

/// PKCS#12 sertifikasıyla PDF dijital imzası (adbe.pkcs7.detached, SHA-256).
enum PDFSigner {
    private static let capacity = 12_288

    static func sign(_ data: Data, certificate p12: Data, password: String, reason: String, location: String) throws -> Data {
        // 1) Kimlik ve sertifika zinciri
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw ToolError("Sertifika parolası yanlış.") }
        guard status == errSecSuccess, let list = items as? [[String: Any]], let entry = list.first,
              let identityValue = entry[kSecImportItemIdentity as String] else {
            throw ToolError("Sertifika açılamadı. Dosyanın .pfx/.p12 olduğundan emin ol.")
        }
        let identity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        var key: SecKey?
        _ = SecIdentityCopyCertificate(identity, &certificate)
        _ = SecIdentityCopyPrivateKey(identity, &key)
        guard let certificate, let key else { throw ToolError("Sertifikadaki gizli anahtar okunamadı.") }
        var chain: [[UInt8]] = [[UInt8](SecCertificateCopyData(certificate) as Data)]
        for extra in entry[kSecImportItemCertChain as String] as? [SecCertificate] ?? [] {
            let bytes = [UInt8](SecCertificateCopyData(extra) as Data)
            if !chain.contains(bytes) { chain.append(bytes) }
        }
        let signer = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "İmzacı"

        // 2) Düz yapılı PDF ve artımlı güncelleme
        guard let kit = PDFDocument(data: data), let flat = kit.dataRepresentation() else { throw ToolError("PDF okunamadı.") }
        var update = try PDFIncremental(flat)
        guard let catalog = update.dictionary(of: update.root),
              let pages = PDFIncremental.firstGroup(#"/Pages\s+(\d+)\s+\d+\s+R"#, in: catalog).flatMap(Int.init),
              let pageNumber = firstPage(update, node: pages), let page = update.dictionary(of: pageNumber) else {
            throw ToolError("PDF'in sayfa yapısı okunamadı.")
        }
        let signatureNumber = update.reserve()
        let fieldNumber = update.reserve()
        let (pdfDate, _) = dates(Date())
        var signature = "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached "
            + "/ByteRange [0 0000000000 0000000000 0000000000] /Contents <\(String(repeating: "0", count: capacity * 2))> "
            + "/M (\(pdfDate)) /Name \(ArchiveTools.pdfText(signer))"
        if !reason.isEmpty { signature += " /Reason \(ArchiveTools.pdfText(reason))" }
        if !location.isEmpty { signature += " /Location \(ArchiveTools.pdfText(location))" }
        signature += " >>"
        update.set(signatureNumber, body: Data(signature.utf8))
        let fieldName = "Imza\(Int.random(in: 1000...9999))"
        update.set(fieldNumber, body: Data("<< /Type /Annot /Subtype /Widget /FT /Sig /Rect [0 0 0 0] /F 132 /T (\(fieldName)) /V \(signatureNumber) 0 R /P \(pageNumber) 0 R >>".utf8))
        let newPage = adding("\(fieldNumber) 0 R", to: "Annots", in: page, update: update)
        update.replace(pageNumber, with: newPage)
        let newCatalog = withAcroForm(catalog, field: fieldNumber, update: &update)
        update.replace(update.root, with: newCatalog)

        // 3) Bayt aralığı, özet ve CMS
        var output = [UInt8](update.build())
        let appendedFrom = flat.count
        guard let rangeStart = find(Array("/ByteRange [0 0000000000 0000000000 0000000000]".utf8), in: output, from: appendedFrom),
              let contentsMarker = find(Array("/Contents <".utf8), in: output, from: appendedFrom) else {
            throw ToolError("İmza yer tutucusu bulunamadı.")
        }
        let contentsStart = contentsMarker + "/Contents ".utf8.count
        let contentsEnd = contentsStart + 2 + capacity * 2
        let byteRange = Array(String(format: "/ByteRange [0 %010d %010d %010d]", contentsStart, contentsEnd, output.count - contentsEnd).utf8)
        output.replaceSubrange(rangeStart..<(rangeStart + byteRange.count), with: byteRange)
        var hasher = SHA256()
        hasher.update(data: output[0..<contentsStart])
        hasher.update(data: output[contentsEnd..<output.count])
        let cms = try signedData(digest: Array(hasher.finalize()), certificates: chain, key: key)
        guard cms.count <= capacity else { throw ToolError("İmza verisi beklenenden büyük.") }
        let hex = Array((cms.map { String(format: "%02X", $0) }.joined() + String(repeating: "0", count: (capacity - cms.count) * 2)).utf8)
        output.replaceSubrange((contentsStart + 1)..<(contentsStart + 1 + hex.count), with: hex)
        return Data(output)
    }

    static func signedData(digest: [UInt8], certificates: [[UInt8]], key: SecKey) throws -> [UInt8] {
        guard let signer = certificates.first, let names = DER.issuerAndSerial(signer) else {
            throw ToolError("Sertifika ayrıştırılamadı.")
        }
        let issuer = names.issuer, serial = names.serial
        let sha256 = DER.sequence([DER.oid("2.16.840.1.101.3.4.2.1"), DER.null])
        let attributes = [
            DER.sequence([DER.oid("1.2.840.113549.1.9.3"), DER.set([DER.oid("1.2.840.113549.1.7.1")])]),
            DER.sequence([DER.oid("1.2.840.113549.1.9.5"), DER.set([DER.utcTime(Date())])]),
            DER.sequence([DER.oid("1.2.840.113549.1.9.4"), DER.set([DER.octets(digest)])]),
        ]
        let signedSet = DER.set(attributes, sorted: true)
        let type = (SecKeyCopyAttributes(key) as? [String: Any])?[kSecAttrKeyType as String] as? String
        let isRSA = type == (kSecAttrKeyTypeRSA as String)
        let algorithm: SecKeyAlgorithm = isRSA ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, Data(signedSet) as CFData, &error) as Data? else {
            throw ToolError("İmza oluşturulamadı: \(error?.takeRetainedValue().localizedDescription ?? "bilinmeyen hata")")
        }
        let signatureAlgorithm = isRSA ? DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null])
            : DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        var signedAttributes = signedSet
        signedAttributes[0] = 0xA0
        let signerInfo = DER.sequence([DER.integer(1), DER.sequence([issuer, serial]), sha256, signedAttributes,
                                       signatureAlgorithm, DER.octets([UInt8](signature))])
        let content = DER.sequence([
            DER.integer(1),
            DER.set([sha256]),
            DER.sequence([DER.oid("1.2.840.113549.1.7.1")]),
            DER.context(0, certificates.flatMap { $0 }),
            DER.set([signerInfo]),
        ])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.2"), DER.context(0, content)])
    }

    // MARK: PDF yardımcıları

    static func dates(_ date: Date) -> (pdf: String, iso: String) {
        let zone = TimeZone.current.secondsFromGMT(for: date)
        let sign = zone >= 0 ? "+" : "-"
        let hours = String(format: "%02d", abs(zone) / 3600), minutes = String(format: "%02d", abs(zone) % 3600 / 60)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMddHHmmss"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return ("D:\(stamp.string(from: date))\(sign)\(hours)'\(minutes)'", "\(iso.string(from: date))\(sign)\(hours):\(minutes)")
    }

    static func firstPage(_ update: PDFIncremental, node: Int, depth: Int = 0) -> Int? {
        guard depth < 32, let dictionary = update.dictionary(of: node) else { return nil }
        guard dictionary.range(of: #"/Type\s*/Pages\b"#, options: .regularExpression) != nil else { return node }
        guard let kids = dictionary.range(of: #"/Kids\s*\[[^\]]*\]"#, options: .regularExpression),
              let first = PDFIncremental.firstGroup(#"(\d+)\s+\d+\s+R"#, in: String(dictionary[kids])).flatMap(Int.init) else { return nil }
        return firstPage(update, node: first, depth: depth + 1)
    }

    /// Sözlükteki diziye (doğrudan ya da dolaylı) başvuru ekler; dizi yoksa oluşturur.
    static func adding(_ reference: String, to key: String, in dictionary: String, update: PDFIncremental) -> String {
        if let range = dictionary.range(of: "/\(key)\\s*\\[[^\\]]*\\]", options: .regularExpression) {
            var array = String(dictionary[range])
            array.insert(contentsOf: " \(reference) ", at: array.index(before: array.endIndex))
            return dictionary.replacingCharacters(in: range, with: array)
        }
        if let range = dictionary.range(of: "/\(key)\\s+\\d+\\s+\\d+\\s+R", options: .regularExpression),
           let number = PDFIncremental.firstGroup("/\(key)\\s+(\\d+)", in: String(dictionary[range])).flatMap(Int.init),
           let body = update.objectBody(of: number), let open = body.firstIndex(of: "["), let close = body.lastIndex(of: "]"), open < close {
            let inner = body[body.index(after: open)..<close]
            return dictionary.replacingCharacters(in: range, with: "/\(key) [\(inner) \(reference)]")
        }
        return PDFIncremental.appending("/\(key) [\(reference)]", to: dictionary)
    }

    static func withAcroForm(_ catalog: String, field: Int, update: inout PDFIncremental) -> String {
        let reference = "\(field) 0 R"
        func prepared(_ form: String) -> String {
            var result = adding(reference, to: "Fields", in: form, update: update)
            result = PDFIncremental.removing("SigFlags", from: result)
            return PDFIncremental.appending("/SigFlags 3", to: result)
        }
        if let number = PDFIncremental.firstGroup(#"/AcroForm\s+(\d+)\s+\d+\s+R"#, in: catalog).flatMap(Int.init),
           let form = update.dictionary(of: number) {
            update.replace(number, with: prepared(form))
            return catalog
        }
        if let start = catalog.range(of: "/AcroForm"), let form = PDFIncremental.dictionary(in: catalog, from: start.upperBound),
           let range = catalog.range(of: form) {
            return catalog.replacingCharacters(in: range, with: prepared(form))
        }
        return PDFIncremental.appending("/AcroForm << /Fields [\(reference)] /SigFlags 3 >>", to: catalog)
    }

    static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var index = max(0, start)
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0] && Array(bytes[index..<(index + pattern.count)]) == pattern { return index }
            index += 1
        }
        return nil
    }
}
