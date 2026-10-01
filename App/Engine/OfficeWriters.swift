import Foundation

func xmlEscape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        default:
            // XML 1.0'da geçersiz denetim karakterlerini at.
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

private let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

// MARK: - DOCX

/// Basit, bağımlılıksız Word (DOCX) yazıcı: başlıklar, paragraflar, tablolar, görseller, sayfa sonları.
final class DocxWriter {
    struct Run {
        var text: String
        var size: Double? = nil
        var bold = false
        var italic = false
        var color: String? = nil
    }

    private var body = ""
    private var media: [(name: String, data: Data)] = []
    private var drawingID = 1
    var pageSize = CGSize(width: 595, height: 842)

    func paragraph(_ runs: [Run], style: String? = nil, alignment: String? = nil) {
        var xml = "<w:p>"
        var properties = ""
        if let style { properties += #"<w:pStyle w:val="\#(style)"/>"# }
        if let alignment { properties += #"<w:jc w:val="\#(alignment)"/>"# }
        if !properties.isEmpty { xml += "<w:pPr>\(properties)</w:pPr>" }
        for run in runs {
            xml += "<w:r>"
            var rpr = ""
            if run.bold { rpr += "<w:b/>" }
            if run.italic { rpr += "<w:i/>" }
            if let color = run.color, color.lowercased() != "#000000" {
                rpr += #"<w:color w:val="\#(color.replacingOccurrences(of: "#", with: "").uppercased())"/>"#
            }
            if let size = run.size {
                let half = max(2, Int((size * 2).rounded()))
                rpr += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"#
            }
            if !rpr.isEmpty { xml += "<w:rPr>\(rpr)</w:rPr>" }
            xml += #"<w:t xml:space="preserve">\#(xmlEscape(run.text))</w:t></w:r>"#
        }
        body += xml + "</w:p>"
    }

    func pageBreak() {
        body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
    }

    func table(_ rows: [[String]]) {
        guard let columns = rows.map(\.count).max(), columns > 0 else { return }
        let usable = Int((pageSize.width - 2 * 56.7) * 20)
        let width = usable / columns
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(usable)\" w:type=\"dxa\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            xml += #"<w:\#(edge) w:val="single" w:sz="4" w:space="0" w:color="A0A0A0"/>"#
        }
        xml += "</w:tblBorders></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns)
        xml += "</w:tblGrid>"
        for (index, row) in rows.enumerated() {
            xml += "<w:tr>"
            for column in 0..<columns {
                let text = column < row.count ? row[column] : ""
                let bold = index == 0 ? "<w:rPr><w:b/></w:rPr>" : ""
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(width)" w:type="dxa"/></w:tcPr><w:p><w:r>\#(bold)<w:t xml:space="preserve">\#(xmlEscape(text))</w:t></w:r></w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        body += xml + "</w:tbl><w:p/>"
    }

    /// Görsel ekler; genişlik nokta (pt) cinsinden.
    func image(_ data: Data, jpeg: Bool, width: Double, height: Double) {
        let id = drawingID
        drawingID += 1
        let name = "image\(id).\(jpeg ? "jpeg" : "png")"
        media.append((name, data))
        let cx = Int(width * 12700), cy = Int(height * 12700)
        body += """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(id)" name="Resim \(id)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdImg\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    func data() -> Data {
        let w = Int(pageSize.width * 20), h = Int(pageSize.height * 20)
        let document = xmlHeader + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="\(w)" w:h="\(h)"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" \
        w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        var relationships = xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        relationships += #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        for (index, item) in media.enumerated() {
            relationships += #"<Relationship Id="rIdImg\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\#(item.name)"/>"#
        }
        relationships += "</Relationships>"
        let styles = xmlHeader + """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr>\
        <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/>\
        <w:lang w:val="tr-TR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/>\
        </w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
        <w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>\
        <w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
        <w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr>\
        <w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:style></w:styles>
        """
        let contentTypes = xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rootRelationships = xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/_rels/document.xml.rels", Data(relationships.utf8)),
        ]
        for item in media { entries.append(("word/media/\(item.name)", item.data)) }
        return Zip.make(entries)
    }
}

// MARK: - XLSX

/// Basit Excel (XLSX) yazıcı: metin ve sayı hücreleri, kalın başlık satırı, sütun genişlikleri.
final class XlsxWriter {
    enum Cell {
        case text(String)
        case number(Double)
        case empty
    }

    private var sheets: [(name: String, rows: [[Cell]], bold: Set<Int>)] = []

    func addSheet(_ name: String, rows: [[Cell]], boldRows: Set<Int> = [0]) {
        var clean = name.components(separatedBy: CharacterSet(charactersIn: "[]:*?/\\")).joined(separator: " ")
        if clean.isEmpty { clean = "Sayfa" }
        clean = String(clean.prefix(31))
        var unique = clean
        var counter = 2
        while sheets.contains(where: { $0.name.lowercased() == unique.lowercased() }) {
            unique = String(clean.prefix(27)) + " (\(counter))"
            counter += 1
        }
        sheets.append((unique, rows, boldRows))
    }

    var isEmpty: Bool { sheets.isEmpty }

    static func column(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    func data() -> Data {
        var entries: [(String, Data)] = []
        var workbookSheets = ""
        var workbookRelationships = ""
        var overrides = ""
        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            workbookSheets += #"<sheet name="\#(xmlEscape(sheet.name))" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            workbookRelationships += #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            var widths: [Int: Int] = [:]
            var rowsXML = ""
            for (r, row) in sheet.rows.enumerated() {
                rowsXML += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() {
                    let reference = "\(Self.column(c))\(r + 1)"
                    let style = sheet.bold.contains(r) ? " s=\"1\"" : ""
                    switch cell {
                    case .text(let text):
                        widths[c] = max(widths[c] ?? 0, text.count)
                        rowsXML += #"<c r="\#(reference)" t="inlineStr"\#(style)><is><t xml:space="preserve">\#(xmlEscape(text))</t></is></c>"#
                    case .number(let value):
                        let text = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
                        widths[c] = max(widths[c] ?? 0, text.count)
                        rowsXML += #"<c r="\#(reference)"\#(style)><v>\#(text)</v></c>"#
                    case .empty:
                        continue
                    }
                }
                rowsXML += "</row>"
            }
            var columns = ""
            if !widths.isEmpty {
                columns = "<cols>" + widths.keys.sorted().map { key in
                    #"<col min="\#(key + 1)" max="\#(key + 1)" width="\#(min(60, max(8, widths[key]! + 2)))" customWidth="1"/>"#
                }.joined() + "</cols>"
            }
            let worksheet = xmlHeader + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\#(columns)<sheetData>\#(rowsXML)</sheetData></worksheet>"#
            entries.append(("xl/worksheets/sheet\(number).xml", Data(worksheet.utf8)))
        }
        let styleRelationship = sheets.count + 1
        workbookRelationships += #"<Relationship Id="rId\#(styleRelationship)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        let workbook = xmlHeader + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(workbookSheets)</sheets></workbook>"#
        let styles = xmlHeader + """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        let contentTypes = xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """
        let root = xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        entries.insert(contentsOf: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(root.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data((xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(workbookRelationships)</Relationships>"#).utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
        ], at: 0)
        return Zip.make(entries)
    }
}

// MARK: - PPTX

/// Basit PowerPoint (PPTX) yazıcı: her slaytta arka plan görseli ve metin kutuları.
final class PptxWriter {
    struct TextBox {
        var frame: CGRect
        var text: String
        var size: Double
        var bold = false
        var italic = false
        var color = "#000000"
    }

    private var slides: [(background: Data?, jpeg: Bool, boxes: [TextBox])] = []
    let slideSize: CGSize

    init(slideSize: CGSize) {
        self.slideSize = slideSize
    }

    func addSlide(background: Data?, jpeg: Bool, boxes: [TextBox]) {
        slides.append((background, jpeg, boxes))
    }

    private func emu(_ value: CGFloat) -> Int { Int((value * 12700).rounded()) }

    func data() -> Data {
        var entries: [(String, Data)] = []
        let cx = emu(slideSize.width), cy = emu(slideSize.height)
        var slideIDs = ""
        var presentationRelationships = #"<Relationship Id="rIdMaster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>"#
        presentationRelationships += #"<Relationship Id="rIdTheme" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>"#
        var overrides = ""
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            slideIDs += #"<p:sldId id="\#(255 + number)" r:id="rIdSlide\#(number)"/>"#
            presentationRelationships += #"<Relationship Id="rIdSlide\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(number).xml"/>"#
            overrides += #"<Override PartName="/ppt/slides/slide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            var shapes = ""
            var shapeID = 2
            var slideRelationships = #"<Relationship Id="rIdLayout" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            if let background = slide.background {
                let name = "slide\(number)_bg.\(slide.jpeg ? "jpeg" : "png")"
                entries.append(("ppt/media/\(name)", background))
                slideRelationships += #"<Relationship Id="rIdBg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/\#(name)"/>"#
                shapes += """
                <p:pic><p:nvPicPr><p:cNvPr id="\(shapeID)" name="Arka plan"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rIdBg"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                """
                shapeID += 1
            }
            for box in slide.boxes {
                let size = max(100, Int((box.size * 100).rounded()))
                let color = box.color.replacingOccurrences(of: "#", with: "").uppercased()
                shapes += """
                <p:sp><p:nvSpPr><p:cNvPr id="\(shapeID)" name="Metin \(shapeID)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
                <p:spPr><a:xfrm><a:off x="\(emu(box.frame.minX))" y="\(emu(box.frame.minY))"/><a:ext cx="\(emu(box.frame.width))" cy="\(emu(box.frame.height))"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
                <p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"><a:noAutofit/></a:bodyPr><a:lstStyle/>\
                <a:p><a:r><a:rPr lang="tr-TR" sz="\(size)" b="\(box.bold ? 1 : 0)" i="\(box.italic ? 1 : 0)" dirty="0">\
                <a:solidFill><a:srgbClr val="\(color)"/></a:solidFill></a:rPr><a:t>\(xmlEscape(box.text))</a:t></a:r></a:p></p:txBody></p:sp>
                """
                shapeID += 1
            }
            let slideXML = xmlHeader + """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            entries.append(("ppt/slides/slide\(number).xml", Data(slideXML.utf8)))
            entries.append(("ppt/slides/_rels/slide\(number).xml.rels",
                            Data((xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(slideRelationships)</Relationships>"#).utf8)))
        }
        let presentation = xmlHeader + """
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" saveSubsetFonts="1">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        let emptyTree = """
        <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        </p:spTree></p:cSld>
        """
        let namespaces = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let master = xmlHeader + """
        <p:sldMaster \(namespaces)>\(emptyTree)\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" \
        accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rIdLayout"/></p:sldLayoutIdLst>\
        <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """
        let layout = xmlHeader + #"<p:sldLayout \#(namespaces) type="blank" preserve="1">\#(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#
        let relationshipsHead = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        let masterRelationships = xmlHeader + relationshipsHead
            + #"<Relationship Id="rIdLayout" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            + #"<Relationship Id="rIdTheme" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>"#
        let layoutRelationships = xmlHeader + relationshipsHead
            + #"<Relationship Id="rIdMaster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>"#
        let contentTypes = xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(overrides)</Types>
        """
        let root = xmlHeader + relationshipsHead
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#
        entries.insert(contentsOf: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(root.utf8)),
            ("ppt/presentation.xml", Data(presentation.utf8)),
            ("ppt/_rels/presentation.xml.rels", Data((xmlHeader + relationshipsHead + presentationRelationships + "</Relationships>").utf8)),
            ("ppt/slideMasters/slideMaster1.xml", Data(master.utf8)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(masterRelationships.utf8)),
            ("ppt/slideLayouts/slideLayout1.xml", Data(layout.utf8)),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(layoutRelationships.utf8)),
            ("ppt/theme/theme1.xml", Data(Self.theme.utf8)),
        ], at: 0)
        return Zip.make(entries)
    }

    private static let theme = xmlHeader + """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="PDF Atölye"><a:themeElements>\
    <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
    <a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
    <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
    <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    </a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
    </a:themeElements></a:theme>
    """
}
