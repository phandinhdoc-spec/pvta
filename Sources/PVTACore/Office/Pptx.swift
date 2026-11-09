import Foundation

/// Xử lý gói PowerPoint trong bộ nhớ; giữ nguyên các phần không được sửa.
enum Pptx {
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let r = Docx.r
    static let ns = "xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\""
    static func esc(_ s: String) -> String { Docx.esc(s).replacingOccurrences(of: "\"", with: "&quot;") }
    static func xml(_ d: Data) throws -> XMLDocument {
        guard !String(decoding: d, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw PVTAError("Không nhận XML có khai báo thực thể.") }
        do { return try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever]) }
        catch { throw PVTAError("Nội dung PowerPoint bị hỏng.") }
    }
    static func nodes(_ n: XMLNode, _ name: String) throws -> [XMLElement] {
        try n.nodes(forXPath: ".//*[local-name()='\(name)']").compactMap { $0 as? XMLElement }
    }
    static func rels(_ items: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(r)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
    }
    static func open(_ data: Data) throws -> (ZipArchive, [String]) {
        guard data.count <= Docx.maxInput else { throw PVTAError("Tệp PowerPoint quá lớn (tối đa 50 MB).") }
        let z = try ZipArchive(data: data)
        guard let main = try z.read("ppt/presentation.xml"), let links = try z.read("ppt/_rels/presentation.xml.rels") else { throw PVTAError("Tệp PowerPoint thiếu danh sách slide.") }
        let relations = try nodes(xml(links), "Relationship")
        let paths = try nodes(xml(main), "sldId").map { slide -> String in
            let id = slide.attribute(forName: "r:id")?.stringValue
            guard let link = relations.first(where: { $0.attribute(forName: "Id")?.stringValue == id }),
                  link.attribute(forName: "TargetMode")?.stringValue != "External",
                  let target = link.attribute(forName: "Target")?.stringValue else { throw PVTAError("Liên kết slide không hợp lệ.") }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : ("ppt/" + target as NSString).standardizingPath
            guard path.hasPrefix("ppt/"), z.entries[path] != nil else { throw PVTAError("Không tìm thấy nội dung slide.") }
            return path
        }
        guard !paths.isEmpty, paths.count <= 200 else { throw PVTAError("Bộ trình chiếu cần từ 1 đến 200 slide.") }
        guard z.entries.values.reduce(0, { $0 + $1.size }) <= 128 * 1024 * 1024 else { throw PVTAError("Nội dung giải nén quá lớn.") }
        return (z, paths)
    }
    static func read(_ data: Data) throws -> String {
        let (z, paths) = try open(data)
        return try paths.enumerated().map { i, path in
            let doc = try xml(z.read(path)!)
            let shapes = try nodes(doc, "sp") + nodes(doc, "pic")
            return "Slide \(i + 1)\n" + (try shapes.map { shape in
                let id = try nodes(shape, "cNvPr").first?.attribute(forName: "id")?.stringValue ?? "?"
                return "[hình \(id)] " + (try nodes(shape, "t").map { $0.stringValue ?? "" }.joined(separator: "\n"))
            }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    static func theme(_ subject: String?) -> (String, String) {
        switch Fold.text(subject ?? "") {
        case "ngu van", "lich su": return ("9C4221", "Georgia")
        case "sinh hoc", "khoa hoc tu nhien": return ("16714B", "Arial")
        case "dia li": return ("087E8B", "Arial")
        default: return ("234E9B", "Arial")
        }
    }
    static let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    static func shape(_ text: String, id: Int, x: Int, y: Int, width: Int, height: Int, size: Int, color: String, font: String) throws -> String {
        guard text.count <= 10_000 else { throw PVTAError("Chữ trên một hình quá dài.") }
        let paragraphs = text.components(separatedBy: "\n").map { "<a:p><a:r><a:rPr lang=\"vi-VN\" sz=\"\(size)\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:latin typeface=\"\(esc(font))\"/></a:rPr><a:t>\(esc($0))</a:t></a:r></a:p>" }.joined()
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Nội dung \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
    }
    static func create(slides: [JSONValue], subject: String?) throws -> Data {
        guard !slides.isEmpty, slides.count <= 200 else { throw PVTAError("Cần từ 1 đến 200 slide.") }
        let (color, font) = theme(subject)
        var zip = ZipWriter()
        func add(_ path: String, _ text: String) { zip.add(path, Data(text.utf8)) }
        var types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        func type(_ path: String, _ kind: String) { types += "<Override PartName=\"/\(path)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\(kind)+xml\"/>" }
        type("ppt/presentation.xml", "presentation.main")
        type("ppt/slideMasters/slideMaster1.xml", "slideMaster")
        type("ppt/slideLayouts/slideLayout1.xml", "slideLayout")
        add("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")]))
        var links: [(String, String, String)] = [("master", "slideMaster", "slideMasters/slideMaster1.xml")]
        var ids = ""
        for (i, slide) in slides.enumerated() {
            let layout = slide["layout"]?.string ?? "content"
            guard ["title", "content", "twoColumns"].contains(layout), let title = slide["title"]?.string else { throw PVTAError("Slide cần title và bố cục title, content hoặc twoColumns.") }
            let n = i + 1
            var shapes = try shape(title, id: 2, x: 600000, y: layout == "title" ? 1800000 : 400000, width: 10800000, height: 1200000, size: 3600, color: color, font: font)
            let bodies = layout == "twoColumns" ? [slide["left"]?.string ?? "", slide["right"]?.string ?? ""] : [slide["text"]?.string ?? ""]
            for (j, body) in bodies.enumerated() {
                shapes += try shape(body, id: j + 3, x: 600000 + j * 5500000, y: layout == "title" ? 3300000 : 1800000, width: bodies.count == 2 ? 5100000 : 10800000, height: 3800000, size: 2400, color: "222222", font: font)
            }
            let path = "ppt/slides/slide\(n).xml"
            type(path, "slide")
            add(path, "<p:sld \(ns)><p:cSld><p:spTree>\(group)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            add("ppt/slides/_rels/slide\(n).xml.rels", rels([("layout", "slideLayout", "../slideLayouts/slideLayout1.xml")]))
            links.append(("s\(n)", "slide", "slides/slide\(n).xml"))
            ids += "<p:sldId id=\"\(255 + n)\" r:id=\"s\(n)\"/>"
        }
        add("ppt/presentation.xml", "<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\" type=\"screen16x9\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        add("ppt/_rels/presentation.xml.rels", rels(links))
        add("ppt/slideMasters/slideMaster1.xml", "<p:sldMaster \(ns)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"layout\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        add("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels([("layout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "theme", "../theme/theme1.xml")]))
        add("ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"Trống\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("master", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        types += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "222222"), ("lt2", "EEEEEE"), ("accent1", color), ("accent2", "16714B"), ("accent3", "E6A23C"), ("accent4", "8256A0"), ("accent5", "087E8B"), ("accent6", "9C4221"), ("hlink", "0000FF"), ("folHlink", "800080")]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fonts = ["majorFont", "minorFont"].map { "<a:\($0)><a:latin typeface=\"\(font)\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:\($0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">" + fill + "<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        add("ppt/theme/theme1.xml", "<a:theme xmlns:a=\"\(a)\" name=\"PVTA\"><a:themeElements><a:clrScheme name=\"PVTA\">\(scheme)</a:clrScheme><a:fontScheme name=\"PVTA\">\(fonts)</a:fontScheme><a:fmtScheme name=\"PVTA\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: line, count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        add("[Content_Types].xml", types + "</Types>")
        return zip.finish()
    }
    static func edit(_ data: Data, ops: [JSONValue]) throws -> Data {
        let (z, paths) = try open(data)
        guard !ops.isEmpty, ops.count <= 200 else { throw PVTAError("Cần từ 1 đến 200 thao tác.") }
        var changed: [String: XMLDocument] = [:]
        for op in ops {
            guard let sn = op["slide"]?.number, sn.rounded() == sn, sn >= 1, sn <= Double(paths.count), let id = op["shape"]?.number, id.isFinite, id >= 1, id < 1e9 else { throw PVTAError("Cần số slide và mã hình hợp lệ.") }
            let path = paths[Int(sn) - 1], doc = try changed[path] ?? xml(z.read(path)!)
            let shapes = try nodes(doc, "sp") + nodes(doc, "pic")
            guard let shape = try shapes.first(where: { try nodes($0, "cNvPr").first?.attribute(forName: "id")?.stringValue == String(Int(id)) }) else { throw PVTAError("Không tìm thấy hình trên slide.") }
            switch op["op"]?.string {
            case "text":
                let texts = try nodes(shape, "t")
                guard let first = texts.first, let text = op["text"]?.string, text.count <= 10000 else { throw PVTAError("Hình không có chữ hoặc nội dung mới không hợp lệ.") }
                first.stringValue = text
                for t in texts.dropFirst() { t.stringValue = "" }
            case "style":
                let color = try op["color"].map { try XStyle(.object(["color": $0])).fill! }
                for run in try nodes(shape, "r") {
                    let pr = run.elements(forName: "a:rPr").first ?? XMLElement(name: "a:rPr")
                    if pr.parent == nil { run.insertChild(pr, at: 0) }
                    if let font = op["font"]?.string {
                        for c in pr.elements(forName: "a:latin") { c.detach() }
                        let latin = XMLElement(name: "a:latin"); latin.addAttribute(XMLNode.attribute(withName: "typeface", stringValue: font) as! XMLNode); pr.addChild(latin)
                    }
                    if let color {
                        for c in pr.children ?? [] where ["solidFill", "noFill", "gradFill", "pattFill"].contains(c.localName ?? "") { c.detach() }
                        let fill = try XMLElement(xmlString: "<a:solidFill xmlns:a=\"\(a)\"><a:srgbClr val=\"\(color)\"/></a:solidFill>")
                        pr.insertChild(fill, at: 0)
                    }
                }
            case "move":
                guard let offset = try nodes(shape, "off").first else { throw PVTAError("Hình chưa có vị trí riêng.") }
                for key in ["x", "y"] {
                    guard let value = op[key]?.number, value.isFinite, abs(value) <= 100 else { throw PVTAError("Vị trí x, y tính bằng cm, trong khoảng -100 đến 100.") }
                    offset.attribute(forName: key)?.stringValue = String(Int(value * 360000))
                }
            default: throw PVTAError("Thao tác PowerPoint phải là text, style hoặc move.")
            }
            changed[path] = doc
        }
        var out = ZipWriter()
        for name in z.names { out.add(name, try changed[name]?.xmlData ?? z.read(name)!) }
        return out.finish()
    }
}
