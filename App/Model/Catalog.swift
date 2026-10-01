import SwiftUI

struct ToolCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let symbol: String
    let colors: [Color]

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func == (lhs: ToolCategory, rhs: ToolCategory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum PageMode { case split, select, organize, rotate }
enum EditorMode { case edit, sign, crop, text, find, form, formCreate, redact }

enum Workspace {
    case files
    case pages(PageMode)
    case editor(EditorMode)
    case compare
    case scan
    case html
}

struct Tool: Identifiable, Hashable {
    let id: String
    let category: String
    let symbol: String
    let name: String
    let summary: String
    let accepts: [FileKind]
    var multi = false
    var sortable = false
    var workspace: Workspace = .files
    let action: String
    var options: [ToolOption] = []
    var minFiles = 1
    var maxFiles: Int? = nil
    var allowsLocked = false
    var validate: ((OptionValues, [InputFile]) -> String?)? = nil

    var categoryInfo: ToolCategory { Catalog.category(category) }

    static func == (lhs: Tool, rhs: Tool) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private func rgb(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

private func choices(_ items: [(String, String)]) -> [Choice] {
    items.map { Choice(value: $0.0, label: $0.1) }
}

private func cards(_ items: [(String, String, String)]) -> [Choice] {
    items.map { Choice(value: $0.0, label: $0.1, detail: $0.2) }
}

private let pagesHint = "Örnek: 1-3, 5, 8- (boş = tüm sayfalar)"
private let paper = choices([("A4", "A4"), ("A3", "A3"), ("A5", "A5"), ("Letter", "Letter"), ("Legal", "Legal")])
private let orientation = choices([("auto", "Otomatik"), ("portrait", "Dikey"), ("landscape", "Yatay")])
private let margin3 = choices([("small", "Dar"), ("recommended", "Normal"), ("big", "Geniş")])
let aiLanguages = ["İngilizce", "Türkçe", "Almanca", "Fransızca", "İspanyolca", "İtalyanca", "Rusça", "Arapça",
                   "Felemenkçe", "Portekizce", "Japonca", "Çince", "Korece", "Yunanca", "Azerbaycan Türkçesi"]

private func pagesOption(_ label: String = "Sayfalar", key: String = "pages", placeholder: String = "Tümü") -> ToolOption {
    ToolOption(key: key, label: label, kind: .text(placeholder: placeholder), hint: pagesHint)
}

private func fontOption(_ visible: @escaping (OptionValues) -> Bool = { _ in true }) -> ToolOption {
    ToolOption(key: "family", label: "Yazı tipi", kind: .font, defaultValue: .string("Helvetica"), visible: visible)
}

enum Catalog {
    static let categories: [ToolCategory] = [
        ToolCategory(id: "edit", name: "Düzenle ve ekle", note: "Metin, görsel, imza, filigran",
                     symbol: "pencil.and.outline", colors: [rgb(0xFF2D78), rgb(0xFF7A59)]),
        ToolCategory(id: "text", name: "Metin ve formlar", note: "Yazıyı düzelt, form doldur ve oluştur",
                     symbol: "character.cursor.ibeam", colors: [rgb(0xA24BFF), rgb(0xE24BD1)]),
        ToolCategory(id: "pages", name: "Sayfalar", note: "Birleştir, böl, sırala, döndür",
                     symbol: "square.stack.3d.up", colors: [rgb(0x0A84FF), rgb(0x00C6E0)]),
        ToolCategory(id: "from", name: "PDF'ten dönüştür", note: "Word, Excel, PowerPoint, görsel",
                     symbol: "arrow.up.doc", colors: [rgb(0xFF8A00), rgb(0xFFC300)]),
        ToolCategory(id: "to", name: "PDF'e dönüştür", note: "Office, görsel, web sayfası, tarama",
                     symbol: "arrow.down.doc", colors: [rgb(0x00B86B), rgb(0x43E0A0)]),
        ToolCategory(id: "optimize", name: "İyileştir", note: "Sıkıştır, onar, OCR",
                     symbol: "wand.and.stars", colors: [rgb(0x00A3C7), rgb(0x34D3B4)]),
        ToolCategory(id: "security", name: "Güvenlik", note: "Şifrele, karart, karşılaştır",
                     symbol: "lock.shield", colors: [rgb(0x3A3D98), rgb(0x6E6AF0)]),
        ToolCategory(id: "ai", name: "Yapay zekâ", note: "Cihazda özetle ve çevir",
                     symbol: "sparkles", colors: [rgb(0x7B2FF7), rgb(0xF107A3)]),
    ]

    static func category(_ id: String) -> ToolCategory {
        categories.first { $0.id == id } ?? categories[0]
    }

    static func tool(_ id: String) -> Tool? {
        tools.first { $0.id == id }
    }

    /// Bir dosya kümesiyle çalışabilecek araçlar ("başka araçla devam et").
    static func tools(for kinds: [FileKind]) -> [Tool] {
        let unique = Set(kinds)
        return tools.filter { tool in
            unique.allSatisfy { tool.accepts.contains($0) } && (unique.count == 1 || tool.multi)
        }
    }

    static let tools: [Tool] = editTools + textTools + pageTools + fromTools + toTools + optimizeTools + securityTools + aiTools

    // MARK: Düzenle ve ekle
    private static let editTools: [Tool] = [
        Tool(id: "edit", category: "edit", symbol: "pencil.tip.crop.circle", name: "PDF Düzenle",
             summary: "Metin, görsel, şekil, çizim, not ve bağlantı ekle; mevcut yazıyı düzelt.",
             accepts: [.pdf], workspace: .editor(.edit), action: "Değişiklikleri kaydet",
             options: [ToolOption(key: "flatten", label: "Notları ve vurguları sayfaya kalıcı işle", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "sign", category: "edit", symbol: "signature", name: "PDF İmzala",
             summary: "İmzanı çiz, yaz ya da yükle; istersen sertifikayla e-imza da ekle.",
             accepts: [.pdf], workspace: .editor(.sign), action: "İmzala",
             options: [
                ToolOption(key: "cert_on", label: "Sertifikayla dijital imza ekle (.pfx / .p12)", kind: .check, defaultValue: .bool(false)),
                ToolOption(key: "cert_file", label: "Sertifika dosyası", kind: .certificate, visible: { $0.bool("cert_on") }),
                ToolOption(key: "cert_password", label: "Sertifika parolası", kind: .password, visible: { $0.bool("cert_on") }),
                ToolOption(key: "cert_reason", label: "İmza nedeni", kind: .text(placeholder: "Onaylıyorum"), visible: { $0.bool("cert_on") }),
                ToolOption(key: "cert_location", label: "Konum", kind: .text(placeholder: "İstanbul"), visible: { $0.bool("cert_on") }),
             ],
             validate: { opts, _ in opts.bool("cert_on") && opts.url("cert_file") == nil ? "Sertifika dosyasını seç." : nil }),
        Tool(id: "watermark", category: "edit", symbol: "seal", name: "Filigran Ekle",
             summary: "Sayfalara yazı ya da logo filigranı bas; saydamlık, açı ve konumu ayarla.",
             accepts: [.pdf], multi: true, action: "Filigran ekle",
             options: [
                ToolOption(key: "kind", label: "Filigran türü", kind: .segmented(choices([("text", "Yazı"), ("image", "Görsel")])), defaultValue: .string("text")),
                ToolOption(key: "text", label: "Filigran yazısı", kind: .text(), defaultValue: .string("GİZLİ"), visible: { $0.string("kind") == "text" }),
                fontOption { $0.string("kind") == "text" },
                ToolOption(key: "size", label: "Yazı boyutu (pt)", kind: .number(min: 6, max: 300), defaultValue: .number(60), visible: { $0.string("kind") == "text" }),
                ToolOption(key: "color", label: "Renk", kind: .color, defaultValue: .string("#cf006d"), visible: { $0.string("kind") == "text" }),
                ToolOption(key: "bold", label: "Kalın", kind: .check, defaultValue: .bool(true), visible: { $0.string("kind") == "text" }),
                ToolOption(key: "image", label: "Görsel (PNG önerilir)", kind: .image, visible: { $0.string("kind") == "image" }),
                ToolOption(key: "scale", label: "Görsel genişliği (sayfanın %'si)", kind: .range(min: 5, max: 100, step: 1, percent: false), defaultValue: .number(40), visible: { $0.string("kind") == "image" }),
                ToolOption(key: "opacity", label: "Saydamlık", kind: .range(min: 0.05, max: 1, step: 0.05, percent: true), defaultValue: .number(0.3)),
                ToolOption(key: "rotation", label: "Açı", kind: .segmented(choices([("0", "0°"), ("30", "30°"), ("45", "45°"), ("90", "90°"), ("-45", "−45°")])), defaultValue: .string("45")),
                ToolOption(key: "position", label: "Konum", kind: .position(tile: true), defaultValue: .string("middle-center")),
                ToolOption(key: "layer", label: "Katman", kind: .segmented(choices([("over", "İçeriğin üstünde"), ("under", "Altında")])), defaultValue: .string("over")),
                pagesOption(),
             ],
             validate: { opts, _ in
                 if opts.string("kind") == "image" && opts.data("image") == nil { return "Filigran için bir görsel seç." }
                 if opts.string("kind") == "text" && opts.string("text").trimmingCharacters(in: .whitespaces).isEmpty { return "Filigran yazısını gir." }
                 return nil
             }),
        Tool(id: "page_numbers", category: "edit", symbol: "list.number", name: "Sayfa Numarası",
             summary: "Sayfalara istediğin konumda ve biçimde numara ekle.",
             accepts: [.pdf], action: "Numara ekle",
             options: [
                ToolOption(key: "position", label: "Konum", kind: .position(tile: false), defaultValue: .string("bottom-center")),
                ToolOption(key: "margin", label: "Kenar boşluğu", kind: .segmented(margin3), defaultValue: .string("recommended")),
                ToolOption(key: "format", label: "Biçim", kind: .select(choices([("{n}", "1"), ("{n} / {total}", "1 / 10"), ("Sayfa {n}", "Sayfa 1"),
                                                                              ("Sayfa {n} / {total}", "Sayfa 1 / 10"), ("- {n} -", "- 1 -"), ("custom", "Özel…")])),
                           defaultValue: .string("{n}")),
                ToolOption(key: "custom_format", label: "Özel biçim", kind: .text(placeholder: "Sayfa {n} / {total}"),
                           hint: "{n} sayfa no, {total} toplam, {date} tarih, {file} dosya adı", visible: { $0.string("format") == "custom" }),
                ToolOption(key: "start", label: "İlk numara", kind: .number(min: 0), defaultValue: .number(1)),
                pagesOption("Numaralanacak sayfalar"),
                fontOption(),
                ToolOption(key: "size", label: "Boyut (pt)", kind: .number(min: 5, max: 72), defaultValue: .number(11)),
                ToolOption(key: "color", label: "Renk", kind: .color, defaultValue: .string("#000000")),
                ToolOption(key: "bold", label: "Kalın", kind: .check, defaultValue: .bool(false)),
                ToolOption(key: "mirror", label: "Karşılıklı sayfalar (çift sayfalarda sağ/sol yer değiştirsin)", kind: .check, defaultValue: .bool(false)),
             ]),
        Tool(id: "header_footer", category: "edit", symbol: "rectangle.topthird.inset.filled", name: "Üst ve Alt Bilgi",
             summary: "Her sayfaya başlık, tarih, dosya adı ya da sayfa numarası yaz.",
             accepts: [.pdf], action: "Üst/alt bilgi ekle",
             options: [
                ToolOption(key: "", label: "Alanlar", kind: .note("Kullanılabilecek alanlar: {n} sayfa no, {total} toplam sayfa, {date} tarih, {time} saat, {file} dosya adı")),
                ToolOption(key: "header_left", label: "Üst bilgi – sol", kind: .text()),
                ToolOption(key: "header_center", label: "Üst bilgi – orta", kind: .text()),
                ToolOption(key: "header_right", label: "Üst bilgi – sağ", kind: .text(placeholder: "{date}")),
                ToolOption(key: "footer_left", label: "Alt bilgi – sol", kind: .text(placeholder: "{file}")),
                ToolOption(key: "footer_center", label: "Alt bilgi – orta", kind: .text()),
                ToolOption(key: "footer_right", label: "Alt bilgi – sağ", kind: .text(placeholder: "Sayfa {n} / {total}")),
                ToolOption(key: "line", label: "Ayırıcı çizgi ekle", kind: .check, defaultValue: .bool(false)),
                fontOption(),
                ToolOption(key: "size", label: "Boyut (pt)", kind: .number(min: 5, max: 40), defaultValue: .number(10)),
                ToolOption(key: "color", label: "Renk", kind: .color, defaultValue: .string("#333333")),
                ToolOption(key: "margin", label: "Kenar boşluğu", kind: .segmented(margin3), defaultValue: .string("recommended")),
                pagesOption(),
             ],
             validate: { opts, _ in
                 let keys = ["header_left", "header_center", "header_right", "footer_left", "footer_center", "footer_right"]
                 return keys.contains { !opts.string($0).trimmingCharacters(in: .whitespaces).isEmpty } ? nil : "Üst veya alt bilgi için en az bir metin yaz."
             }),
        Tool(id: "crop", category: "edit", symbol: "crop", name: "PDF Kırp",
             summary: "Sayfa üzerinde alan seçerek kırp ya da beyaz kenarları otomatik temizle.",
             accepts: [.pdf], workspace: .editor(.crop), action: "Kırp",
             options: [
                ToolOption(key: "mode", label: "Yöntem", kind: .segmented(choices([("manual", "Alanı seç"), ("auto", "Beyaz kenarları kırp")])), defaultValue: .string("manual")),
                ToolOption(key: "apply", label: "Uygula", kind: .segmented(choices([("all", "Tüm sayfalara"), ("current", "Yalnız bu sayfaya")])), defaultValue: .string("all"), visible: { $0.string("mode") == "manual" }),
                ToolOption(key: "padding", label: "İç boşluk (pt)", kind: .number(min: 0, max: 100), defaultValue: .number(10), visible: { $0.string("mode") == "auto" }),
             ]),

    ]

    // MARK: Metin ve formlar
    private static let textTools: [Tool] = [
        Tool(id: "edit_text", category: "text", symbol: "character.cursor.ibeam", name: "Metni Düzelt",
             summary: "PDF'teki yazıya dokun, yerinde düzelt. Yazı boyutu ve renk korunur.",
             accepts: [.pdf], workspace: .editor(.text), action: "Düzeltmeleri kaydet"),
        Tool(id: "find_replace", category: "text", symbol: "text.magnifyingglass", name: "Bul ve Değiştir",
             summary: "Bir kelimeyi ya da ifadeyi tüm belgede tek seferde değiştir.",
             accepts: [.pdf], action: "Tümünü değiştir",
             options: [
                ToolOption(key: "pairs", label: "Değişiklikler", kind: .pairs, defaultValue: .pairs([ReplacePair()])),
                ToolOption(key: "case", label: "Büyük/küçük harf duyarlı", kind: .check, defaultValue: .bool(false)),
                ToolOption(key: "whole_word", label: "Yalnızca tam kelime", kind: .check, defaultValue: .bool(false)),
             ],
             validate: { opts, _ in opts.pairs("pairs").contains { !$0.find.isEmpty } ? nil : "Aranacak metni yaz." }),
        Tool(id: "form", category: "text", symbol: "list.clipboard", name: "Form Doldur",
             summary: "Doldurulabilir alanları doldur ve kaydet.",
             accepts: [.pdf], workspace: .editor(.form), action: "Formu kaydet",
             options: [ToolOption(key: "flatten", label: "Kaydederken düzleştir (alanlar düzenlenemez hale gelir)", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "form_create", category: "text", symbol: "rectangle.and.pencil.and.ellipsis", name: "Form Oluştur",
             summary: "Çizgileri, kutucukları ve “Ad: ____” boşluklarını doldurulabilir forma çevir.",
             accepts: [.pdf], workspace: .editor(.formCreate), action: "Doldurulabilir PDF oluştur",
             options: [ToolOption(key: "flatten", label: "Kaydederken düzleştir", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "metadata", category: "text", symbol: "info.circle", name: "Belge Bilgileri",
             summary: "Başlık, yazar, konu ve anahtar kelimeleri düzenle ya da tamamen temizle.",
             accepts: [.pdf], action: "Bilgileri kaydet",
             options: [
                ToolOption(key: "title", label: "Başlık", kind: .text()),
                ToolOption(key: "author", label: "Yazar", kind: .text()),
                ToolOption(key: "subject", label: "Konu", kind: .text()),
                ToolOption(key: "keywords", label: "Anahtar kelimeler", kind: .text()),
                ToolOption(key: "creator", label: "Oluşturan uygulama", kind: .text()),
                ToolOption(key: "producer", label: "Üretici", kind: .text()),
                ToolOption(key: "clear", label: "Tüm bilgileri sil", kind: .check, defaultValue: .bool(false)),
             ]),

    ]

    // MARK: Sayfalar
    private static let pageTools: [Tool] = [
        Tool(id: "merge", category: "pages", symbol: "arrow.triangle.merge", name: "PDF Birleştir",
             summary: "PDF, görsel ve Office dosyalarını istediğin sırayla tek PDF'te topla.",
             accepts: [.pdf, .image, .word, .excel, .powerpoint], multi: true, sortable: true, action: "Birleştir",
             options: [ToolOption(key: "bookmarks", label: "Her dosya için yer imi ekle", kind: .check, defaultValue: .bool(true))],
             minFiles: 2,
             validate: { _, files in files.count < 2 ? "Birleştirmek için en az 2 dosya ekle." : nil }),
        Tool(id: "split", category: "pages", symbol: "scissors", name: "PDF Böl",
             summary: "Aralıklara, sabit sayfa sayısına, yer imlerine ya da boyuta göre ayır.",
             accepts: [.pdf], workspace: .pages(.split), action: "Böl",
             options: [
                ToolOption(key: "mode", label: "Bölme şekli", kind: .cards(cards([
                    ("ranges", "Aralıklara göre", "Her aralık ayrı bir PDF olur."),
                    ("every", "Her N sayfada bir", "Eşit parçalara ayır."),
                    ("all", "Tüm sayfaları ayır", "Her sayfa ayrı PDF."),
                    ("bookmarks", "Yer imlerine göre", "Her bölüm ayrı PDF."),
                    ("size", "Dosya boyutuna göre", "Her parça en fazla X MB.")])), defaultValue: .string("ranges")),
                ToolOption(key: "ranges", label: "Aralıklar", kind: .text(placeholder: "1-3, 4-8, 9-"), hint: "Her virgül yeni bir dosya başlatır.", visible: { $0.string("mode") == "ranges" }),
                ToolOption(key: "merge_output", label: "Aralıkları tek PDF'te birleştir", kind: .check, defaultValue: .bool(false), visible: { $0.string("mode") == "ranges" }),
                ToolOption(key: "every", label: "Kaç sayfada bir", kind: .number(min: 1), defaultValue: .number(2), visible: { $0.string("mode") == "every" }),
                ToolOption(key: "max_mb", label: "En büyük parça (MB)", kind: .number(min: 0.1, step: 0.1), defaultValue: .number(5), visible: { $0.string("mode") == "size" }),
             ],
             validate: { opts, _ in opts.string("mode") == "ranges" && opts.string("ranges").trimmingCharacters(in: .whitespaces).isEmpty ? "Aralıkları yaz ya da sayfalardan seç." : nil }),
        Tool(id: "remove_pages", category: "pages", symbol: "minus.square", name: "Sayfa Sil",
             summary: "İstemediğin sayfaları seç ve kaldır.",
             accepts: [.pdf], workspace: .pages(.select), action: "Seçili sayfaları sil",
             options: [ToolOption(key: "pages", label: "Silinecek sayfalar", kind: .text(placeholder: "Sayfalara dokun ya da yaz: 2, 5-7"))],
             validate: { opts, _ in opts.string("pages").trimmingCharacters(in: .whitespaces).isEmpty ? "Silinecek sayfaları seç." : nil }),
        Tool(id: "extract_pages", category: "pages", symbol: "doc.on.doc", name: "Sayfa Çıkar",
             summary: "Seçtiğin sayfalardan yeni bir PDF oluştur.",
             accepts: [.pdf], workspace: .pages(.select), action: "Sayfaları çıkar",
             options: [
                ToolOption(key: "pages", label: "Çıkarılacak sayfalar", kind: .text(placeholder: "Sayfalara dokun ya da yaz: 1, 3-4")),
                ToolOption(key: "separate", label: "Her sayfayı ayrı dosya yap", kind: .check, defaultValue: .bool(false)),
             ],
             validate: { opts, _ in opts.string("pages").trimmingCharacters(in: .whitespaces).isEmpty ? "Çıkarılacak sayfaları seç." : nil }),
        Tool(id: "organize", category: "pages", symbol: "square.grid.2x2", name: "Sayfaları Düzenle",
             summary: "Sürükleyerek sırala, döndür, sil, kopyala, boş sayfa ekle; birden fazla PDF'i karıştır.",
             accepts: [.pdf, .image], multi: true, workspace: .pages(.organize), action: "Kaydet"),
        Tool(id: "rotate", category: "pages", symbol: "rotate.right", name: "PDF Döndür",
             summary: "Tüm sayfaları ya da tek tek sayfaları döndür.",
             accepts: [.pdf], multi: true, workspace: .pages(.rotate), action: "Döndür",
             options: [
                ToolOption(key: "angle", label: "Açı", kind: .segmented(choices([("90", "90° sağa"), ("180", "180°"), ("270", "90° sola")])), defaultValue: .string("90")),
                pagesOption(),
             ]),
        Tool(id: "nup", category: "pages", symbol: "rectangle.split.2x2", name: "Kağıda Çoklu Sayfa",
             summary: "2, 4, 6, 9 veya 16 sayfayı tek kağıda yerleştir; baskıdan tasarruf et.",
             accepts: [.pdf], action: "Oluştur",
             options: [
                ToolOption(key: "per_sheet", label: "Kağıt başına sayfa", kind: .segmented(choices([("2", "2"), ("4", "4"), ("6", "6"), ("8", "8"), ("9", "9"), ("16", "16")])), defaultValue: .string("2")),
                ToolOption(key: "paper", label: "Kağıt", kind: .select(paper), defaultValue: .string("A4")),
                ToolOption(key: "orientation", label: "Yön", kind: .segmented(orientation), defaultValue: .string("auto")),
                ToolOption(key: "order", label: "Sıra", kind: .segmented(choices([("horizontal", "Soldan sağa"), ("vertical", "Yukarıdan aşağı")])), defaultValue: .string("horizontal")),
                ToolOption(key: "border", label: "Sayfa kenarlarını çiz", kind: .check, defaultValue: .bool(false)),
             ]),
        Tool(id: "resize_pages", category: "pages", symbol: "arrow.up.left.and.arrow.down.right", name: "Sayfa Boyutu",
             summary: "Tüm sayfaları A4, A3, Letter gibi tek bir kağıt boyutuna getir.",
             accepts: [.pdf], action: "Boyutlandır",
             options: [
                ToolOption(key: "paper", label: "Kağıt", kind: .select(paper), defaultValue: .string("A4")),
                ToolOption(key: "orientation", label: "Yön", kind: .segmented(orientation), defaultValue: .string("auto")),
                ToolOption(key: "margin", label: "Kenar boşluğu (pt)", kind: .number(min: 0, max: 100), defaultValue: .number(0)),
             ]),

    ]

    // MARK: PDF'ten dönüştür
    private static let fromTools: [Tool] = [
        Tool(id: "pdf_to_word", category: "from", symbol: "doc.richtext", name: "PDF'ten Word'e",
             summary: "PDF'i düzenlenebilir DOCX belgesine çevir.",
             accepts: [.pdf], multi: true, action: "Word'e dönüştür",
             options: [ToolOption(key: "mode", label: "Dönüştürme şekli", kind: .cards(cards([
                ("flow", "Düzenlenebilir metin", "Başlıklar, paragraflar, listeler ve tablolar; kolay düzenlenir."),
                ("image", "Birebir görünüm", "Her sayfa görüntü olarak eklenir, altına metni yazılır.")])), defaultValue: .string("flow"))]),
        Tool(id: "pdf_to_excel", category: "from", symbol: "tablecells", name: "PDF'ten Excel'e",
             summary: "PDF'teki tabloları çalışma sayfalarına aktar.",
             accepts: [.pdf], multi: true, action: "Excel'e dönüştür",
             options: [
                ToolOption(key: "layout", label: "Yerleşim", kind: .segmented(choices([("per_table", "Her tablo ayrı sayfa"), ("single", "Tek sayfada")])), defaultValue: .string("per_table")),
                ToolOption(key: "numbers", label: "Sayıları dönüştür", kind: .segmented(choices([("tr", "1.234,56"), ("en", "1,234.56"), ("none", "Metin kalsın")])), defaultValue: .string("tr")),
             ]),
        Tool(id: "pdf_to_ppt", category: "from", symbol: "play.rectangle", name: "PDF'ten PowerPoint'e",
             summary: "Her sayfayı bir slayta çevir.",
             accepts: [.pdf], multi: true, action: "PowerPoint'e dönüştür",
             options: [ToolOption(key: "mode", label: "Slayt türü", kind: .cards(cards([
                ("editable", "Düzenlenebilir", "Metinler ayrı kutularda, arka plan korunur."),
                ("image", "Birebir görünüm", "Her sayfa tam görüntü olarak eklenir.")])), defaultValue: .string("editable"))]),
        Tool(id: "pdf_to_images", category: "from", symbol: "photo.on.rectangle.angled", name: "PDF'ten JPG'ye",
             summary: "Sayfaları görsel olarak kaydet ya da PDF içindeki görselleri çıkar.",
             accepts: [.pdf], multi: true, action: "Görsellere dönüştür",
             options: [
                ToolOption(key: "mode", label: "Ne yapılsın?", kind: .cards(cards([
                    ("pages", "Sayfaları görsele çevir", "Her sayfa bir JPG/PNG olur."),
                    ("extract", "Görselleri çıkar", "PDF'e gömülü fotoğrafları ayıkla.")])), defaultValue: .string("pages")),
                ToolOption(key: "format", label: "Biçim", kind: .segmented(choices([("jpg", "JPG"), ("png", "PNG")])), defaultValue: .string("jpg"), visible: { $0.string("mode") == "pages" }),
                ToolOption(key: "dpi", label: "Çözünürlük", kind: .segmented(choices([("72", "Düşük"), ("150", "Normal"), ("300", "Yüksek")])), defaultValue: .string("150"), visible: { $0.string("mode") == "pages" }),
                ToolOption(key: "pages", label: "Sayfalar", kind: .text(placeholder: "Tümü"), hint: pagesHint, visible: { $0.string("mode") == "pages" }),
             ]),
        Tool(id: "pdf_to_pdfa", category: "from", symbol: "archivebox", name: "PDF/A'ya Dönüştür",
             summary: "Arşivleme için PDF/A dönüşümü yap; uygunluğu ayrıca doğrula.",
             accepts: [.pdf], multi: true, action: "PDF/A'ya dönüştür",
             options: [ToolOption(key: "part", label: "Sürüm", kind: .segmented(choices([("1", "PDF/A-1b"), ("2", "PDF/A-2b"), ("3", "PDF/A-3b")])), defaultValue: .string("2"))]),
        Tool(id: "pdf_to_text", category: "from", symbol: "doc.plaintext", name: "PDF'ten Metne",
             summary: "Tüm metni TXT ya da HTML olarak çıkar.",
             accepts: [.pdf], multi: true, action: "Metni çıkar",
             options: [ToolOption(key: "format", label: "Biçim", kind: .segmented(choices([("txt", "Düz metin (.txt)"), ("html", "HTML")])), defaultValue: .string("txt"))]),
        Tool(id: "pdf_to_markdown", category: "from", symbol: "number.square", name: "PDF → Markdown",
             summary: "Metni, başlıkları ve algılanan tabloları Markdown dosyasına aktar.",
             accepts: [.pdf], multi: true, action: "Markdown'a dönüştür",
             options: [
                pagesOption(placeholder: "Tüm sayfalar"),
                ToolOption(key: "headings", label: "Yazı boyutundan başlıkları algıla", kind: .check, defaultValue: .bool(true)),
                ToolOption(key: "tables", label: "Tabloları algıla", kind: .check, defaultValue: .bool(true)),
                ToolOption(key: "links", label: "Web bağlantılarını ekle", kind: .check, defaultValue: .bool(true)),
                ToolOption(key: "page_markers", label: "Sayfa işaretlerini ekle", kind: .check, defaultValue: .bool(true)),
             ]),

    ]

    // MARK: PDF'e dönüştür
    private static let toTools: [Tool] = [
        Tool(id: "images_to_pdf", category: "to", symbol: "photo", name: "JPG'den PDF'e",
             summary: "JPG, PNG, HEIC ve diğer görselleri sıralayıp PDF yap.",
             accepts: [.image], multi: true, sortable: true, action: "PDF'e dönüştür",
             options: [
                ToolOption(key: "page_size", label: "Sayfa boyutu", kind: .segmented(choices([("fit", "Görsel boyutu"), ("A4", "A4"), ("Letter", "Letter")])), defaultValue: .string("fit")),
                ToolOption(key: "orientation", label: "Yön", kind: .segmented(orientation), defaultValue: .string("auto"), visible: { $0.string("page_size") != "fit" }),
                ToolOption(key: "margin", label: "Kenar boşluğu", kind: .segmented(choices([("none", "Yok"), ("small", "Dar"), ("big", "Geniş")])), defaultValue: .string("none")),
                ToolOption(key: "merge", label: "Tüm görselleri tek PDF'te birleştir", kind: .check, defaultValue: .bool(true)),
             ]),
        Tool(id: "word_to_pdf", category: "to", symbol: "doc.text", name: "Word'den PDF'e",
             summary: "DOC, DOCX, ODT, RTF, Pages ve TXT dosyalarını PDF'e çevir.",
             accepts: [.word], multi: true, action: "PDF'e dönüştür",
             options: [ToolOption(key: "merge", label: "Birden fazla dosyayı tek PDF'te birleştir", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "excel_to_pdf", category: "to", symbol: "tablecells.badge.ellipsis", name: "Excel'den PDF'e",
             summary: "XLS, XLSX, ODS, Numbers ve CSV tablolarını PDF'e çevir.",
             accepts: [.excel], multi: true, action: "PDF'e dönüştür",
             options: [ToolOption(key: "merge", label: "Birden fazla dosyayı tek PDF'te birleştir", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "ppt_to_pdf", category: "to", symbol: "play.rectangle.on.rectangle", name: "PowerPoint'ten PDF'e",
             summary: "PPT, PPTX ve Keynote sunumlarını PDF'e çevir.",
             accepts: [.powerpoint], multi: true, action: "PDF'e dönüştür",
             options: [ToolOption(key: "merge", label: "Birden fazla dosyayı tek PDF'te birleştir", kind: .check, defaultValue: .bool(false))]),
        Tool(id: "html_to_pdf", category: "to", symbol: "globe", name: "HTML'den PDF'e",
             summary: "Bir web sayfasını ya da HTML dosyasını PDF olarak kaydet.",
             accepts: [.html], multi: true, workspace: .html, action: "PDF'e dönüştür",
             options: [
                ToolOption(key: "url", label: "Web adresi", kind: .text(placeholder: "https://ornek.com")),
                ToolOption(key: "header_footer", label: "Tarih ve adres üst bilgisini ekle", kind: .check, defaultValue: .bool(false)),
             ],
             minFiles: 0,
             validate: { opts, files in files.isEmpty && opts.string("url").trimmingCharacters(in: .whitespaces).isEmpty ? "Bir web adresi yaz ya da HTML dosyası ekle." : nil }),
        Tool(id: "scan", category: "to", symbol: "doc.viewfinder", name: "Belge Tara",
             summary: "Kamerayla ya da fotoğraftan tara; kenarlar bulunur, görüntü netleştirilir.",
             accepts: [.image], multi: true, sortable: true, workspace: .scan, action: "PDF oluştur",
             options: [
                ToolOption(key: "filter", label: "Görünüm", kind: .segmented(choices([("auto", "Renkli"), ("gray", "Gri"), ("bw", "Siyah-beyaz"), ("none", "Olduğu gibi")])), defaultValue: .string("auto")),
                ToolOption(key: "auto_crop", label: "Belge kenarlarını bul ve düzelt", kind: .check, defaultValue: .bool(true)),
                ToolOption(key: "page_size", label: "Sayfa", kind: .segmented(choices([("A4", "A4"), ("fit", "Fotoğraf boyutu")])), defaultValue: .string("A4")),
                ToolOption(key: "ocr", label: "Metni tanı (OCR) – aranabilir PDF", kind: .check, defaultValue: .bool(false)),
             ]),

    ]

    // MARK: İyileştir
    private static let optimizeTools: [Tool] = [
        Tool(id: "compress", category: "optimize", symbol: "arrow.down.right.and.arrow.up.left", name: "PDF Sıkıştır",
             summary: "Dosya boyutunu kalite ve sıkıştırma seçenekleriyle küçült.",
             accepts: [.pdf], multi: true, action: "Sıkıştır",
             options: [
                ToolOption(key: "level", label: "Sıkıştırma düzeyi", kind: .cards(cards([
                    ("extreme", "En yüksek", "En küçük dosya, görseller belirgin şekilde düşük kalite."),
                    ("recommended", "Önerilen", "İyi kalite, iyi sıkıştırma."),
                    ("low", "Hafif", "Yüksek kalite, daha az sıkıştırma.")])), defaultValue: .string("recommended")),
                ToolOption(key: "grayscale", label: "Görselleri griye çevir", kind: .check, defaultValue: .bool(false)),
             ]),
        Tool(id: "ocr", category: "optimize", symbol: "text.viewfinder", name: "OCR – Metin Tanıma",
             summary: "Taranmış PDF ve fotoğrafları aranabilir, seçilebilir metne çevir.",
             accepts: [.pdf, .image], multi: true, action: "Metni tanı",
             options: [
                ToolOption(key: "language", label: "Belgenin dili", kind: .select(choices([("tur+eng", "Türkçe + İngilizce"), ("tur", "Türkçe"), ("eng", "İngilizce")])), defaultValue: .string("tur+eng")),
                ToolOption(key: "skip_text_pages", label: "Zaten metin içeren sayfaları atla", kind: .check, defaultValue: .bool(true)),
                pagesOption(),
             ]),
        Tool(id: "repair", category: "optimize", symbol: "wrench.and.screwdriver", name: "PDF Onar",
             summary: "Bozuk ya da açılmayan PDF'leri kurtarmayı dene.",
             accepts: [.pdf], multi: true, action: "Onar"),
        Tool(id: "grayscale", category: "optimize", symbol: "circle.lefthalf.filled", name: "Siyah-Beyaz Yap",
             summary: "Tüm renkleri griye çevir; baskıda renkli mürekkep harcama.",
             accepts: [.pdf], multi: true, action: "Griye çevir"),
        Tool(id: "flatten", category: "optimize", symbol: "square.3.layers.3d.down.right", name: "Düzleştir",
             summary: "Form alanlarını ve notları sayfaya kalıcı olarak işle.",
             accepts: [.pdf], multi: true, action: "Düzleştir"),

    ]

    // MARK: Güvenlik
    private static let securityTools: [Tool] = [
        Tool(id: "protect", category: "security", symbol: "lock.fill", name: "PDF Şifrele",
             summary: "AES ile parola koy; yazdırma ve kopyalama izinlerini belirle.",
             accepts: [.pdf], multi: true, action: "Şifrele",
             options: [
                ToolOption(key: "password", label: "Parola", kind: .password),
                ToolOption(key: "password2", label: "Parola (tekrar)", kind: .password),
                ToolOption(key: "permissions", label: "İzin verilenler", kind: .checks(choices([("print", "Yazdırma"), ("copy", "Metin kopyalama"), ("annotate", "Not ve form doldurma"), ("modify", "Düzenleme")])),
                           defaultValue: .list(["print", "copy", "annotate"])),
             ],
             validate: { opts, _ in
                 if opts.string("password").isEmpty { return "Bir parola belirle." }
                 return opts.string("password") != opts.string("password2") ? "Parolalar eşleşmiyor." : nil
             }),
        Tool(id: "unlock", category: "security", symbol: "lock.open.fill", name: "Şifre Kaldır",
             summary: "Parolasını bildiğin PDF'ten şifreyi ve kısıtlamaları kaldır.",
             accepts: [.pdf], multi: true, action: "Şifreyi kaldır",
             options: [ToolOption(key: "password", label: "PDF parolası", kind: .password, hint: "Yalnızca kısıtlama varsa boş bırakabilirsin.")],
             allowsLocked: true),
        Tool(id: "redact", category: "security", symbol: "eye.slash", name: "Karart",
             summary: "Kişisel bilgileri kalıcı olarak sil: TC kimlik, IBAN, telefon, e-posta…",
             accepts: [.pdf], workspace: .editor(.redact), action: "Kalıcı olarak karart",
             options: [
                ToolOption(key: "presets", label: "Otomatik bul", kind: .checks(choices([("tckn", "TC kimlik no"), ("iban", "IBAN"), ("phone", "Telefon"), ("email", "E-posta"),
                                                                                       ("card", "Kart numarası"), ("url", "Web adresi"), ("date", "Tarih")])), defaultValue: .list([])),
                ToolOption(key: "terms_text", label: "Aranacak kelimeler", kind: .textarea(placeholder: "Her satıra bir ifade"), hint: "Bulunan her yer karartılır."),
                ToolOption(key: "case", label: "Büyük/küçük harf duyarlı", kind: .check, defaultValue: .bool(false)),
                ToolOption(key: "color", label: "Karartma rengi", kind: .color, defaultValue: .string("#000000")),
                ToolOption(key: "clean_metadata", label: "Belge bilgilerini (yazar vb.) de sil", kind: .check, defaultValue: .bool(true)),
             ]),
        Tool(id: "compare", category: "security", symbol: "rectangle.split.2x1", name: "PDF Karşılaştır",
             summary: "İki sürüm arasındaki farkları renkli olarak göster.",
             accepts: [.pdf], multi: true, workspace: .compare, action: "Karşılaştır",
             options: [ToolOption(key: "mode", label: "Karşılaştırma türü", kind: .cards(cards([
                ("text", "Metin farkları", "Eklenen ve silinen kelimeler işaretlenir."),
                ("visual", "Görsel farklar", "Taranmış belgeler ve çizimler için piksel karşılaştırma.")])), defaultValue: .string("text"))],
             minFiles: 2, maxFiles: 2,
             validate: { _, files in files.count != 2 ? "Karşılaştırmak için iki PDF ekle." : nil }),

    ]

    // MARK: Yapay zekâ
    private static let aiTools: [Tool] = [
        Tool(id: "ai_summarize", category: "ai", symbol: "sparkles", name: "Özetle",
             summary: "Uzun belgeleri cihazdaki yapay zekâ ile özetle; belge cihazdan çıkmaz.",
             accepts: [.pdf], action: "Özetle",
             options: [
                ToolOption(key: "length", label: "Uzunluk", kind: .cards(cards([("short", "Kısa", "5-7 madde"), ("medium", "Orta", "Başlıklarla yaklaşık 1 sayfa"),
                                                                                ("long", "Ayrıntılı", "Bölüm bölüm, sayılar ve tarihlerle")])), defaultValue: .string("medium")),
                ToolOption(key: "language", label: "Özet dili", kind: .select(aiLanguages.map { Choice(value: $0, label: $0) }), defaultValue: .string("Türkçe")),
                ToolOption(key: "focus", label: "Odaklanılacak konu (isteğe bağlı)", kind: .text(placeholder: "Örn. ödeme koşulları")),
             ]),
        Tool(id: "ai_translate", category: "ai", symbol: "character.bubble", name: "PDF Çevir",
             summary: "Sayfa düzenini koruyarak başka bir dile çevir.",
             accepts: [.pdf], action: "Çevir",
             options: [ToolOption(key: "language", label: "Hedef dil", kind: .select(aiLanguages.map { Choice(value: $0, label: $0) }), defaultValue: .string("İngilizce"))]),
    ]
}
