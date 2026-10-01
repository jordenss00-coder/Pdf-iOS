import PDFKit

enum DocumentTools {
    static let metadataKeys: [(String, PDFDocumentAttribute)] = [
        ("title", .titleAttribute), ("author", .authorAttribute), ("subject", .subjectAttribute),
        ("keywords", .keywordsAttribute), ("creator", .creatorAttribute), ("producer", .producerAttribute),
    ]

    /// Belge bilgilerini seçenek değerlerine çevirir (formu doldurmak için).
    static func currentMetadata(_ url: URL, password: String? = nil) -> OptionValues {
        var values = OptionValues()
        guard let document = PDFDocument(url: url) else { return values }
        if document.isLocked, let password { _ = document.unlock(withPassword: password) }
        let attributes = document.documentAttributes ?? [:]
        for (key, attribute) in metadataKeys {
            if let list = attributes[attribute] as? [String] {
                values[key] = .string(list.joined(separator: ", "))
            } else if let text = attributes[attribute] as? String {
                values[key] = .string(text)
            }
        }
        return values
    }

    static func metadata(_ c: ToolContext) async throws -> [URL] {
        let input = try c.first
        let document = try await c.pdf(input)
        var attributes = document.documentAttributes ?? [:]
        if c.options.bool("clear") {
            attributes = [:]
            for (_, attribute) in metadataKeys {
                attributes[attribute] = attribute == .keywordsAttribute ? [String]() as Any : "" as Any
            }
        } else {
            for (key, attribute) in metadataKeys {
                guard let value = c.options[key], case .string(let text) = value else { continue }
                if attribute == .keywordsAttribute {
                    attributes[attribute] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else {
                    attributes[attribute] = text
                }
            }
        }
        document.documentAttributes = attributes
        let url = c.out("\(stem(input.name)).pdf")
        try PDFKitIO.write(document, to: url)
        return [url]
    }

    static func protect(_ c: ToolContext) async throws -> [URL] {
        let password = c.options.string("password")
        guard !password.isEmpty else { throw ToolError("Bir parola belirle.") }
        if c.options["password2"] != nil, c.options.string("password2") != password {
            throw ToolError("Parolalar eşleşmiyor.")
        }
        let owner = UUID().uuidString + UUID().uuidString
        let allowed = Set(c.options["permissions"] == nil ? ["print", "copy", "annotate"] : c.options.list("permissions"))
        var bits: UInt = 0
        if allowed.contains("print") {
            bits |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        }
        if allowed.contains("copy") {
            bits |= PDFAccessPermissions.allowsContentCopying.rawValue | PDFAccessPermissions.allowsContentAccessibility.rawValue
        }
        if allowed.contains("modify") {
            bits |= PDFAccessPermissions.allowsDocumentChanges.rawValue | PDFAccessPermissions.allowsDocumentAssembly.rawValue
        }
        if allowed.contains("annotate") {
            bits |= PDFAccessPermissions.allowsCommenting.rawValue | PDFAccessPermissions.allowsFormFieldEntry.rawValue
        }
        var urls: [URL] = []
        for input in c.inputs {
            let document = try await c.pdf(input)
            let url = c.out("\(stem(input.name))_korumali.pdf")
            try PDFKitIO.write(document, to: url, options: [
                .userPasswordOption: password,
                .ownerPasswordOption: owner,
                .accessPermissionsOption: NSNumber(value: bits),
            ])
            urls.append(url)
        }
        return urls
    }

    static func unlock(_ c: ToolContext) async throws -> [URL] {
        let password = c.options.string("password")
        var urls: [URL] = []
        for input in c.inputs {
            let data = try Data(contentsOf: input.url)
            let probe = PDFDocument(data: data)
            if probe?.isEncrypted == false {
                c.warnings.append("'\(input.name)' zaten şifreli değildi.")
            }
            let candidate = password.isEmpty ? input.password : password
            let document: PDFiumDocument
            do {
                document = try PDFiumDocument(data: data, password: candidate)
            } catch {
                throw ToolError("'\(input.name)' için parola yanlış.")
            }
            let url = c.out("\(stem(input.name))_kilitsiz.pdf")
            try document.save(removeSecurity: true).write(to: url)
            urls.append(url)
        }
        return urls
    }

    static func flatten(_ c: ToolContext) async throws -> [URL] {
        var urls: [URL] = []
        for input in c.inputs {
            let document = try await c.pdf(input)
            let url = c.out("\(stem(input.name))_duzlestirilmis.pdf")
            try PDFKitIO.write(document, to: url, options: [.burnInAnnotationsOption: true])
            urls.append(url)
        }
        return urls
    }

    static func repair(_ c: ToolContext) async throws -> [URL] {
        var urls: [URL] = []
        for input in c.inputs {
            let data = try Data(contentsOf: input.url)
            let url = c.out("\(stem(input.name))_onarilmis.pdf")
            var repaired: Data?
            // PDFium bozuk çapraz başvuru tablolarını yeniden kurar.
            if let rebuilt = try? PDFiumDocument(data: data, password: input.password).save(removeSecurity: input.password != nil),
               let check = PDFDocument(data: rebuilt), check.pageCount > 0 {
                repaired = rebuilt
            } else if let document = PDFDocument(data: data), document.pageCount > 0 {
                if document.isLocked, let password = input.password { _ = document.unlock(withPassword: password) }
                repaired = document.dataRepresentation()
            }
            guard let repaired else {
                throw ToolError("'\(input.name)' onarılamadı. Dosya çok ağır hasarlı olabilir.")
            }
            try repaired.write(to: url)
            urls.append(url)
        }
        return urls
    }
}
