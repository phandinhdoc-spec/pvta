import Foundation

/// Đọc cấu trúc và sửa tệp Word có sẵn trên bản sao. Chỉ đụng tới phần được yêu cầu; phần còn lại của gói giữ nguyên từng byte nội dung.
extension Docx {
    private static let pOrder = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs",
                                 "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd",
                                 "snapToGrid", "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment",
                                 "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]
    private static let rOrder = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow", "emboss", "imprint", "noProof",
                                 "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd",
                                 "fitText", "vertAlign", "rtl", "cs", "em", "lang", "eastAsianLayout", "specVanish", "oMath"]

    private static func open(_ data: Data) throws -> ZipArchive {
        guard data.count <= maxInput else { throw PVTAError("Tệp Word quá lớn (tối đa 50 MB).") }
        let zip = try ZipArchive(data: data)
        guard zip.entries["word/document.xml"] != nil else { throw PVTAError("Đây không phải tệp Word (.docx) hợp lệ hoặc tệp đã bị hỏng.") }
        return zip
    }

    private static func parse(_ data: Data) throws -> XMLDocument {
        do { return try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveCDATA]) }
        catch { throw PVTAError("Nội dung tệp Word bị hỏng nên PVTA không đọc được.") }
    }

    private static func body(_ doc: XMLDocument) throws -> XMLElement {
        guard let b = doc.rootElement()?.elements(forName: "w:body").first else { throw PVTAError("Tệp Word không có phần nội dung.") }
        return b
    }

    private static func blocks(_ body: XMLElement) -> [XMLElement] {
        (body.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == "w:p" || $0.name == "w:tbl" }
    }

    /// Các nút w:t của đoạn (không tính chữ bị xóa theo dõi thay đổi hay nằm trong công thức).
    private static func textNodes(_ e: XMLElement) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ n: XMLElement) {
            for case let c as XMLElement in n.children ?? [] {
                if c.name == "w:t" { out.append(c) } else if c.name != "w:del" && c.name != "m:oMath" && c.name != "m:oMathPara" { walk(c) }
            }
        }
        walk(e)
        return out
    }

    private static func plainText(_ e: XMLElement) -> String {
        var s = ""
        func walk(_ n: XMLElement) {
            for case let c as XMLElement in n.children ?? [] {
                switch c.name {
                case "w:t": s += c.stringValue ?? ""
                case "w:tab": s += "\t"
                case "w:br", "w:cr": s += "\n"
                case "m:oMath", "m:oMathPara": s += "[công thức]"
                case "w:del", "w:pPr", "w:rPr": break
                case "w:drawing", "w:pict": s += "[ảnh]"
                default: walk(c)
                }
            }
        }
        walk(e)
        return s
    }

    private static func style(_ p: XMLElement) -> String? {
        p.elements(forName: "w:pPr").first?.elements(forName: "w:pStyle").first?.attribute(forName: "w:val")?.stringValue
    }

    private static func tableRows(_ t: XMLElement) -> [[String]] {
        t.elements(forName: "w:tr").map { tr in tr.elements(forName: "w:tc").map { tc in tc.elements(forName: "w:p").map(plainText).joined(separator: " ") } }
    }

    // MARK: Đọc

    /// Mục lục nội dung có số thứ tự khối; số này dùng cho thao tác sửa.
    static func outline(_ data: Data, limit: Int = 40_000) throws -> String {
        let zip = try open(data)
        let doc = try parse(try zip.read("word/document.xml") ?? Data())
        let bs = blocks(try body(doc))
        var lines: [String] = []
        for (i, b) in bs.enumerated() {
            if b.name == "w:p" {
                let t = plainText(b)
                let st = style(b)
                if t.isEmpty && st == nil { lines.append("[\(i)] (đoạn trống)"); continue }
                lines.append("[\(i)]" + (st.map { " (\($0))" } ?? "") + " " + t)
            } else {
                let rows = tableRows(b)
                lines.append("[\(i)] Bảng \(rows.count) hàng × \(rows.first?.count ?? 0) cột")
                for r in rows.prefix(30) { lines.append("    | " + r.joined(separator: " | ") + " |") }
                if rows.count > 30 { lines.append("    … còn \(rows.count - 30) hàng") }
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > limit { text = String(text.prefix(limit)) + "\n… (đã cắt bớt, tài liệu dài)" }
        return text.isEmpty ? "(tài liệu trống)" : text
    }

    // MARK: Sửa

    private static func setChild(_ parent: XMLElement, _ name: String, attrs: [String: String], order: [String]) {
        let local = name.dropFirst(2)
        let el = parent.elements(forName: name).first ?? {
            let new = XMLElement(name: name)
            let rank = order.firstIndex(of: String(local)) ?? order.count
            var at = parent.childCount
            for (i, c) in (parent.children ?? []).enumerated() {
                if let ce = c as? XMLElement, let r = order.firstIndex(of: String(ce.name?.dropFirst(2) ?? "")), r > rank { at = i; break }
            }
            parent.insertChild(new, at: at)
            return new
        }()
        for (k, v) in attrs { el.addAttribute(XMLNode.attribute(withName: k, stringValue: v) as! XMLNode) }
    }

    private static func firstRPr(_ p: XMLElement) -> XMLElement? {
        var found: XMLElement?
        func walk(_ n: XMLElement) {
            for case let c as XMLElement in n.children ?? [] where found == nil {
                if c.name == "w:r", let pr = c.elements(forName: "w:rPr").first { found = pr; return }
                if c.name != "w:pPr" { walk(c) }
            }
        }
        walk(p)
        return found
    }

    private static func fragment(_ xml: String) throws -> XMLElement {
        // Gắn khai báo tên miền vào thẻ gốc của đoạn XML.
        guard let end = xml.firstIndex(where: { $0 == ">" || $0 == " " || $0 == "/" }) else { throw PVTAError("Nội dung chèn không hợp lệ.") }
        let wrapped = xml[..<end] + " " + nsDecl + xml[end...]
        do { return try XMLElement(xmlString: String(wrapped)) } catch { throw PVTAError("Nội dung chèn không hợp lệ (lỗi XML).") }
    }

    static func hasStyle(_ styles: XMLDocument?, _ id: String) -> Bool {
        guard let root = styles?.rootElement() else { return false }
        return root.elements(forName: "w:style").contains { $0.attribute(forName: "w:styleId")?.stringValue == id }
    }

    /// Áp dụng danh sách thao tác lên một tài liệu. Chỉ số khối là của tài liệu GỐC (xem `outline`), nên không lệch khi nhiều thao tác chèn/xóa.
    static func edit(_ data: Data, ops: [JSONValue], images: ImageLoader) async throws -> (data: Data, report: [String]) {
        guard !ops.isEmpty else { throw PVTAError("Chưa có thao tác sửa nào (ops).") }
        guard ops.count <= maxOps else { throw PVTAError("Tối đa \(maxOps) thao tác cho một lần sửa.") }
        let zip = try open(data)
        let doc = try parse(try zip.read("word/document.xml") ?? Data())
        let body = try body(doc)
        let originals = blocks(body)
        let styles = try zip.read("word/styles.xml").flatMap { try? parse($0) }
        var removed = Set<Int>(), lastInsert: [Int: XMLNode] = [:]
        var report: [String] = []
        var newMedia: [(name: String, data: Data)] = []
        var maxDocPr = 100

        func target(_ op: JSONValue, _ key: String = "index") throws -> (Int, XMLElement) {
            guard let n = op[key]?.number, n == n.rounded(), n >= 0, Int(n) < originals.count else {
                throw PVTAError("Thao tác “\(op["op"]?.string ?? "")”: số khối “\(key)” phải từ 0 đến \(originals.count - 1) (xem mục lục tài liệu).")
            }
            guard !removed.contains(Int(n)) else { throw PVTAError("Khối \(Int(n)) đã bị xóa ở thao tác trước.") }
            return (Int(n), originals[Int(n)])
        }

        /// Chèn sau khối `after` (số) hoặc "start"/"end". Nhiều lần chèn cùng một chỗ giữ đúng thứ tự thao tác.
        func place(_ op: JSONValue, _ node: XMLElement) throws {
            let key = op["after"]
            if key?.string == "start" || key == nil {
                if key == nil { throw PVTAError("Thao tác “\(op["op"]?.string ?? "")” cần chỉ rõ vị trí chèn (after: số khối, \"start\" hoặc \"end\").") }
                let k = -1
                let at = lastInsert[k].map { $0.index + 1 } ?? 0
                body.insertChild(node, at: at); lastInsert[k] = node; return
            }
            if key?.string == "end" {
                let k = -2
                let sect = (body.children ?? []).firstIndex { ($0 as? XMLElement)?.name == "w:sectPr" } ?? body.childCount
                let at = lastInsert[k].map { $0.index + 1 } ?? sect
                body.insertChild(node, at: at); lastInsert[k] = node; return
            }
            let (i, anchor) = try target(op, "after")
            let at = (lastInsert[i] ?? anchor).index + 1
            body.insertChild(node, at: at)
            lastInsert[i] = node
        }

        func inheritedFormat(_ op: JSONValue) -> (pPr: String, rPr: String) {
            guard let n = op["after"]?.number, Int(n) >= 0, Int(n) < originals.count, originals[Int(n)].name == "w:p" else { return ("", "") }
            let p = originals[Int(n)]
            let st = style(p) ?? ""
            if st.hasPrefix("Heading") || st == "Title" || p.elements(forName: "w:pPr").first?.elements(forName: "w:numPr").isEmpty == false { return ("", "") }
            let skip: Set<String> = ["w:rPr", "w:sectPr", "w:pPrChange"]
            let pPr = p.elements(forName: "w:pPr").first.map { pr in
                (pr.children ?? []).compactMap { $0 as? XMLElement }.filter { !skip.contains($0.name ?? "") }.map(\.xmlString).joined()
            } ?? ""
            let rPr = firstRPr(p).map { $0.xmlString } ?? ""
            return (pPr, rPr)
        }

        for (k, op) in ops.enumerated() {
            let kind = op["op"]?.string ?? ""
            let label = "Thao tác \(k + 1) (\(kind))"
            do {
                switch kind {
                case "replace":
                    guard let find = op["find"]?.string, !find.isEmpty, let new = op["replace"]?.string else { throw PVTAError("cần find (khác rỗng) và replace.") }
                    let all = op["all"]?.bool ?? false
                    var hits: [(XMLElement, [XMLElement], Range<Int>)] = []
                    var paragraphs: [XMLElement] = []
                    func collect(_ n: XMLElement) { for case let c as XMLElement in n.children ?? [] { if c.name == "w:p" { paragraphs.append(c) } else { collect(c) } } }
                    collect(body)
                    for p in paragraphs {
                        let nodes = textNodes(p)
                        let joined = nodes.map { $0.stringValue ?? "" }.joined()
                        var from = joined.startIndex
                        while let r = joined.range(of: find, range: from..<joined.endIndex) {
                            let a = joined.distance(from: joined.startIndex, to: r.lowerBound), b = joined.distance(from: joined.startIndex, to: r.upperBound)
                            hits.append((p, nodes, a..<b))
                            from = r.upperBound
                        }
                    }
                    if hits.isEmpty { throw PVTAError("không thấy “\(find.prefix(60))”. Chữ có thể bị chia thành nhiều đoạn định dạng; hãy dùng setText cho cả đoạn.") }
                    if hits.count > 1 && !all { throw PVTAError("“\(find.prefix(60))” xuất hiện \(hits.count) lần. Hãy dùng setText cho đúng đoạn, hoặc đặt all=true.") }
                    // Thay từ cuối về đầu trong từng đoạn để vị trí không lệch.
                    for (_, nodes, range) in hits.reversed() {
                        var offset = 0
                        var first = true
                        for node in nodes {
                            let text = Array(node.stringValue ?? "")
                            let lo = max(range.lowerBound - offset, 0), hi = min(range.upperBound - offset, text.count)
                            offset += text.count
                            guard lo < hi else { continue }
                            var t = text
                            t.replaceSubrange(lo..<hi, with: first ? Array(new) : [])
                            node.stringValue = String(t)
                            node.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
                            first = false
                        }
                    }
                    report.append("\(label): thay \(hits.count) chỗ")
                case "setText":
                    let (i, p) = try target(op)
                    guard p.name == "w:p" else { throw PVTAError("khối \(i) là bảng; hãy dùng replace cho chữ trong bảng.") }
                    guard let text = op["text"]?.string else { throw PVTAError("cần text.") }
                    let rPr = firstRPr(p).map(\.xmlString) ?? ""
                    for idx in stride(from: p.childCount - 1, through: 0, by: -1) where (p.children?[idx] as? XMLElement)?.name != "w:pPr" { p.removeChild(at: idx) }
                    for child in try fragment("<w:p>" + (try runs(text, rPr: rPr)) + "</w:p>").children ?? [] { p.addChild(child.copy() as! XMLNode) }
                    report.append("\(label): đoạn \(i)")
                case "insertParagraph":
                    guard let text = op["text"]?.string else { throw PVTAError("cần text.") }
                    var pPr = "", rPr = ""
                    if let level = op["heading"]?.number {
                        let l = min(max(Int(level), 1), 3)
                        if hasStyle(styles, "Heading\(l)") { pPr = "<w:pStyle w:val=\"Heading\(l)\"/>" }
                        else { pPr = "<w:keepNext/>"; rPr = "<w:rPr><w:b/><w:sz w:val=\"\(l == 1 ? 28 : 26)\"/><w:szCs w:val=\"\(l == 1 ? 28 : 26)\"/></w:rPr>" }
                    } else { (pPr, rPr) = inheritedFormat(op) }
                    if let al = op["align"]?.string { pPr += "<w:jc w:val=\"\(try justification(al))\"/>" }
                    try place(op, try fragment(try paragraph(text, pPr: pPr, rPr: rPr)))
                    report.append("\(label): thêm đoạn")
                case "insertTable":
                    try place(op, try fragment(try table(try rows(op["rows"], ""))))
                    report.append("\(label): thêm bảng")
                case "insertEquation":
                    guard let l = op["latex"]?.string else { throw PVTAError("cần latex.") }
                    try place(op, try fragment(try equation(l)))
                    report.append("\(label): thêm phương trình")
                case "insertImage":
                    guard let path = op["path"]?.string else { throw PVTAError("cần path.") }
                    let img = try await images(path)
                    guard let kind = ImageKind.detect(img), ["png", "jpg", "gif"].contains(kind.ext) else { throw PVTAError("Word chỉ nhận ảnh PNG, JPEG hoặc GIF.") }
                    let name = "pvta-\(UUID().uuidString.prefix(8).lowercased()).\(kind.ext == "jpg" ? "jpeg" : kind.ext)"
                    newMedia.append((name, img))
                    maxDocPr += 1
                    try place(op, try fragment(try drawing(rId: "rIdPvta\(newMedia.count)", id: maxDocPr, data: img, widthCm: op["widthCm"]?.number, name: (path as NSString).lastPathComponent)))
                    report.append("\(label): thêm ảnh")
                case "delete":
                    let (i, node) = try target(op)
                    guard originals.count > 1 else { throw PVTAError("không xóa được khối duy nhất của tài liệu.") }
                    node.detach()
                    removed.insert(i)
                    report.append("\(label): xóa khối \(i)")
                case "format":
                    var paragraphs: [XMLElement] = []
                    if op["index"]?.string == "all" {
                        func collect(_ n: XMLElement) { for case let c as XMLElement in n.children ?? [] { if c.name == "w:p" { paragraphs.append(c) } else { collect(c) } } }
                        collect(body)
                    } else {
                        let (i, node) = try target(op)
                        if node.name == "w:p" { paragraphs = [node] } else {
                            func collect(_ n: XMLElement) { for case let c as XMLElement in n.children ?? [] { if c.name == "w:p" { paragraphs.append(c) } else { collect(c) } } }
                            collect(node)
                            _ = i
                        }
                    }
                    guard ["bold", "italic", "size", "font", "align"].contains(where: { op[$0] != nil }) else { throw PVTAError("cần ít nhất một trong bold, italic, size, font, align.") }
                    for p in paragraphs {
                        if let al = op["align"]?.string {
                            let pPr = p.elements(forName: "w:pPr").first ?? { let n = XMLElement(name: "w:pPr"); p.insertChild(n, at: 0); return n }()
                            setChild(pPr, "w:jc", attrs: ["w:val": try justification(al)], order: pOrder)
                        }
                        var runsList: [XMLElement] = []
                        func collect(_ n: XMLElement) { for case let c as XMLElement in n.children ?? [] { if c.name == "w:r" { runsList.append(c) } else if c.name != "w:pPr" { collect(c) } } }
                        collect(p)
                        for r in runsList {
                            let rPr = r.elements(forName: "w:rPr").first ?? { let n = XMLElement(name: "w:rPr"); r.insertChild(n, at: 0); return n }()
                            if let b = op["bold"]?.bool { if b { setChild(rPr, "w:b", attrs: [:], order: rOrder) } else { rPr.elements(forName: "w:b").forEach { $0.detach() } } }
                            if let i = op["italic"]?.bool { if i { setChild(rPr, "w:i", attrs: [:], order: rOrder) } else { rPr.elements(forName: "w:i").forEach { $0.detach() } } }
                            if let size = op["size"]?.number {
                                guard size >= 4, size <= 200 else { throw PVTAError("cỡ chữ phải từ 4 đến 200 pt.") }
                                setChild(rPr, "w:sz", attrs: ["w:val": String(Int(size * 2))], order: rOrder)
                                setChild(rPr, "w:szCs", attrs: ["w:val": String(Int(size * 2))], order: rOrder)
                            }
                            if let font = op["font"]?.string, !font.isEmpty, font.count <= 60 {
                                setChild(rPr, "w:rFonts", attrs: ["w:ascii": font, "w:hAnsi": font, "w:eastAsia": font, "w:cs": font], order: rOrder)
                            }
                        }
                    }
                    report.append("\(label): \(paragraphs.count) đoạn")
                default:
                    throw PVTAError("loại thao tác không hợp lệ (replace, setText, insertParagraph, insertTable, insertEquation, insertImage, delete, format).")
                }
            } catch let e as PVTAError {
                throw PVTAError("\(label): \(e.message)")
            }
        }

        var out = ZipWriter()
        var relsDone = false
        let newDoc = doc.xmlData(options: [.nodePreserveWhitespace])
        for name in zip.names {
            guard var content = try zip.read(name) else { continue }
            if name == "word/document.xml" { content = newDoc }
            if !newMedia.isEmpty && name == "[Content_Types].xml" { content = try addContentTypes(content, media: newMedia.map(\.name)) }
            if !newMedia.isEmpty && name == "word/_rels/document.xml.rels" { content = try addRels(content, media: newMedia.map(\.name)); relsDone = true }
            out.add(name, content)
        }
        if !newMedia.isEmpty && !relsDone {
            out.add("word/_rels/document.xml.rels", try addRels(Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>".utf8), media: newMedia.map(\.name)))
        }
        for m in newMedia { out.add("word/media/" + m.name, m.data) }
        return (out.finish(), report)
    }

    private static func addContentTypes(_ data: Data, media: [String]) throws -> Data {
        guard var s = String(data: data, encoding: .utf8), s.contains("</Types>") else { throw PVTAError("Gói Word thiếu danh mục loại nội dung nên PVTA không thêm ảnh được.") }
        for ext in Set(media.map { ($0 as NSString).pathExtension }) where !s.contains("Extension=\"\(ext)\"") {
            let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : "image/jpeg"
            s = s.replacingOccurrences(of: "</Types>", with: "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/></Types>")
        }
        return Data(s.utf8)
    }

    private static func addRels(_ data: Data, media: [String]) throws -> Data {
        guard var s = String(data: data, encoding: .utf8), s.contains("</Relationships>") else { throw PVTAError("Gói Word thiếu danh mục liên kết nên PVTA không thêm ảnh được.") }
        let add = media.enumerated().map { "<Relationship Id=\"rIdPvta\($0.offset + 1)\" Type=\"\(r)/image\" Target=\"media/\($0.element)\"/>" }.joined()
        s = s.replacingOccurrences(of: "</Relationships>", with: add + "</Relationships>")
        return Data(s.utf8)
    }
}
