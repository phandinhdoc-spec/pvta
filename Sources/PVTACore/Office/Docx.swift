import Foundation
import ImageIO

/// Tạo, đọc và sửa tệp Word (.docx) bằng XML trực tiếp, không dùng thư viện ngoài: giữ nguyên mọi phần PVTA không đụng tới
/// (kiểu, đầu trang, ảnh, công thức, bảng có sẵn).
enum Docx {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let maxBlocks = 1000, maxOps = 200, maxText = 50_000, maxInput = 50 * 1024 * 1024
    static let nsDecl = "xmlns:w=\"\(w)\" xmlns:m=\"\(Omml.namespace)\" xmlns:r=\"\(r)\" "
        + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
        + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

    static func esc(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // Ký tự điều khiển không hợp lệ trong XML.
        out.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
        return out
    }

    // MARK: Dựng đoạn văn

    /// Chữ thành các run; `\n` là xuống dòng, `\t` là tab, `$công thức$` là phương trình cùng dòng.
    static func runs(_ text: String, rPr: String = "") throws -> String {
        guard text.count <= maxText else { throw PVTAError("Một đoạn quá dài (tối đa 50.000 ký tự).") }
        func plain(_ t: String) -> String {
            guard !t.isEmpty else { return "" }
            var out = ""
            let lines = t.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if i > 0 { out += "<w:r>\(rPr)<w:br/></w:r>" }
                for (j, part) in line.components(separatedBy: "\t").enumerated() {
                    if j > 0 { out += "<w:r>\(rPr)<w:tab/></w:r>" }
                    if !part.isEmpty { out += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(esc(part))</w:t></w:r>" }
                }
            }
            return out
        }
        let regex = try NSRegularExpression(pattern: #"\$(?=\S)([^$\n]+?)(?<=\S)\$"#)
        let ns = text as NSString
        var out = "", last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += try Omml.convert(ns.substring(with: m.range(at: 1)), display: false)
            last = m.range.location + m.range.length
        }
        return out + plain(ns.substring(from: last))
    }

    static func paragraph(_ text: String, pPr: String = "", rPr: String = "") throws -> String {
        "<w:p>\(pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>")\(try runs(text, rPr: rPr))</w:p>"
    }

    static func equation(_ latex: String) throws -> String {
        "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>\(try Omml.convert(latex, display: true))</w:p>"
    }

    static func table(_ rows: [[String]]) throws -> String {
        guard let width = rows.first?.count, width > 0, width <= 30, rows.count <= 500, rows.allSatisfy({ $0.count == width }) else {
            throw PVTAError("Bảng phải có từ 1 đến 30 cột, tối đa 500 hàng và mọi hàng cùng số ô.")
        }
        let border = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>" }.joined()
        var out = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>\(border)</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        out += String(repeating: "<w:gridCol w:w=\"\(9000 / width)\"/>", count: width) + "</w:tblGrid>"
        for (i, row) in rows.enumerated() {
            out += "<w:tr>" + (i == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for cell in row {
                let head = i == 0
                out += "<w:tc><w:tcPr><w:tcW w:w=\"\(9000 / width)\" w:type=\"dxa\"/>\(head ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"D9E2F3\"/>" : "")</w:tcPr>"
                out += try paragraph(cell, rPr: head ? "<w:rPr><w:b/></w:rPr>" : "") + "</w:tc>"
            }
            out += "</w:tr>"
        }
        return out + "</w:tbl>"
    }

    static func imageSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let wd = p[kCGImagePropertyPixelWidth] as? Int, let ht = p[kCGImagePropertyPixelHeight] as? Int, wd > 0, ht > 0 else { return nil }
        return (wd, ht)
    }

    static func drawing(rId: String, id: Int, data: Data, widthCm: Double?, name: String) throws -> String {
        guard let size = imageSize(data) else { throw PVTAError("Không đọc được kích thước ảnh “\(name)”.") }
        let cm = min(max(widthCm ?? 12, 1), 16)
        let cx = Int(cm * 360_000), cy = Int(Double(cx) * Double(size.h) / Double(size.w))
        return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(id)\" name=\"\(esc(name))\" descr=\"\(esc(name))\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(esc(name))\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rId)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    // MARK: Tạo tài liệu mới

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """

    static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """

    static func styles() -> String {
        func heading(_ id: String, _ name: String, _ size: Int, italic: Bool = false) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"\(id.last!.wholeNumberValue! - 1)\"/></w:pPr><w:rPr><w:b/>\(italic ? "<w:i/>" : "")<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"\(w)\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"Times New Roman\" w:cs=\"Times New Roman\"/><w:sz w:val=\"26\"/><w:szCs w:val=\"26\"/><w:lang w:val=\"vi-VN\" w:eastAsia=\"vi-VN\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"288\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:before=\"0\" w:after=\"240\"/><w:jc w:val=\"center\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"32\"/><w:szCs w:val=\"32\"/></w:rPr></w:style>"
            + heading("Heading1", "heading 1", 28) + heading("Heading2", "heading 2", 26) + heading("Heading3", "heading 3", 26, italic: true)
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:ind w:left=\"720\"/><w:contextualSpacing/></w:pPr></w:style></w:styles>"
    }

    /// numId 1 = gạch đầu dòng; các numId từ 2 là danh sách số bắt đầu lại từ 1.
    static func numbering(orderedLists: Int) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"\(w)\">"
        out += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        out += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        out += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for i in 0..<orderedLists { out += "<w:num w:numId=\"\(i + 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>" }
        return out + "</w:numbering>"
    }

    typealias ImageLoader = @Sendable (String) async throws -> Data

    /// Tạo tài liệu mới từ danh sách khối: heading, paragraph, list, table, equation, image, page_break.
    static func create(title: String?, blocks: [JSONValue], images: ImageLoader) async throws -> Data {
        guard !blocks.isEmpty || title != nil else { throw PVTAError("Tài liệu chưa có nội dung.") }
        guard blocks.count <= maxBlocks else { throw PVTAError("Tối đa \(maxBlocks) khối cho một tài liệu.") }
        var body = "", media: [(name: String, data: Data)] = [], ordered = 0
        if let title, !title.isEmpty { body += try paragraph(title, pPr: "<w:pStyle w:val=\"Title\"/>") }
        for (i, b) in blocks.enumerated() {
            let n = "Khối \(i + 1): "
            switch b["type"]?.string {
            case "heading":
                let level = min(max(Int(b["level"]?.number ?? 1), 1), 3)
                body += try paragraph(b["text"]?.string ?? "", pPr: "<w:pStyle w:val=\"Heading\(level)\"/>")
            case "paragraph":
                var pPr = ""
                if let al = b["align"]?.string { pPr = "<w:jc w:val=\"\(try justification(al))\"/>" }
                body += try paragraph(b["text"]?.string ?? "", pPr: pPr)
            case "list":
                guard case .array(let items)? = b["items"], !items.isEmpty, items.count <= 200 else { throw PVTAError(n + "danh sách cần 1 đến 200 mục (items).") }
                var numId = 1
                if b["ordered"]?.bool == true { ordered += 1; numId = ordered + 1 }
                for it in items { body += try paragraph(it.string ?? "", pPr: "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numId)\"/></w:numPr>") }
            case "table":
                body += try table(try rows(b["rows"], n))
            case "equation":
                guard let l = b["latex"]?.string else { throw PVTAError(n + "công thức cần trường latex.") }
                body += try equation(l)
            case "image":
                guard let path = b["path"]?.string else { throw PVTAError(n + "ảnh cần trường path.") }
                let data = try await images(path)
                guard let kind = ImageKind.detect(data), ["png", "jpg", "gif"].contains(kind.ext) else { throw PVTAError(n + "Word chỉ nhận ảnh PNG, JPEG hoặc GIF.") }
                media.append(("image\(media.count + 1).\(kind.ext == "jpg" ? "jpeg" : kind.ext)", data))
                body += try drawing(rId: "rIdImg\(media.count)", id: media.count, data: data, widthCm: b["widthCm"]?.number, name: (path as NSString).lastPathComponent)
            case "page_break":
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            default:
                throw PVTAError(n + "loại khối “\(b["type"]?.string ?? "")” không hợp lệ (heading, paragraph, list, table, equation, image, page_break).")
            }
        }
        if body.isEmpty { body = "<w:p/>" }
        let section = "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"851\" w:bottom=\"1134\" w:left=\"1701\" w:header=\"709\" w:footer=\"709\" w:gutter=\"0\"/></w:sectPr>"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(nsDecl)><w:body>\(body)\(section)</w:body></w:document>"
        var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        rels += "<Relationship Id=\"rIdStyles\" Type=\"\(r)/styles\" Target=\"styles.xml\"/><Relationship Id=\"rIdNum\" Type=\"\(r)/numbering\" Target=\"numbering.xml\"/>"
        for (i, m) in media.enumerated() { rels += "<Relationship Id=\"rIdImg\(i + 1)\" Type=\"\(r)/image\" Target=\"media/\(m.name)\"/>" }
        rels += "</Relationships>"
        let core = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(esc(title ?? ""))</dc:title><dc:creator>PVTA</dc:creator></cp:coreProperties>"
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rootRels.utf8))
        zip.add("word/document.xml", Data(document.utf8))
        zip.add("word/_rels/document.xml.rels", Data(rels.utf8))
        zip.add("word/styles.xml", Data(styles().utf8))
        zip.add("word/numbering.xml", Data(numbering(orderedLists: ordered).utf8))
        zip.add("docProps/core.xml", Data(core.utf8))
        for m in media { zip.add("word/media/" + m.name, m.data) }
        return zip.finish()
    }

    static func rows(_ v: JSONValue?, _ n: String) throws -> [[String]] {
        guard case .array(let rs)? = v, !rs.isEmpty else { throw PVTAError(n + "bảng cần danh sách hàng (rows).") }
        return try rs.map { row in
            guard case .array(let cells) = row else { throw PVTAError(n + "mỗi hàng của bảng phải là một danh sách ô.") }
            return cells.map { c in c.string ?? c.number.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String($0) } ?? (c.bool.map { $0 ? "true" : "false" } ?? "") }
        }
    }

    static func justification(_ a: String) throws -> String {
        guard let v = ["left": "left", "center": "center", "right": "right", "justify": "both"][a] else { throw PVTAError("Căn lề “\(a)” không hợp lệ (left, center, right, justify).") }
        return v
    }
}
