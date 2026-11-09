import Foundation

/// Kiểu của ô cần đặt: chỉ những trường có giá trị mới đổi, phần còn lại của kiểu cũ giữ nguyên.
struct XStyle: Equatable {
    var fill: String?       // RRGGBB
    var fontColor: String?
    var bold: Bool?
    var numFmt: String?     // "0.0", "#,##0", "0%", "dd/mm/yyyy"…
    var align: String?      // left, center, right
    var border: Bool?
    var wrap: Bool?

    init(_ op: JSONValue) throws {
        func color(_ k: String) throws -> String? {
            guard let c = op[k]?.string else { return nil }
            let h = c.hasPrefix("#") ? String(c.dropFirst()) : c
            guard h.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw PVTAError("Màu “\(c)” không hợp lệ (dùng dạng RRGGBB, ví dụ FFFF00).") }
            return h.uppercased()
        }
        fill = try color("color"); fontColor = try color("fontColor"); bold = op["bold"]?.bool
        numFmt = op["numFmt"]?.string; border = op["border"]?.bool; wrap = op["wrap"]?.bool
        if let a = op["align"]?.string {
            guard ["left", "center", "right"].contains(a) else { throw PVTAError("Căn lề “\(a)” không hợp lệ (left, center, right).") }
            align = a
        }
        if let f = numFmt, f.count > 60 { throw PVTAError("Định dạng số quá dài.") }
        guard fill != nil || fontColor != nil || bold != nil || numFmt != nil || align != nil || border != nil || wrap != nil else {
            throw PVTAError("Chưa nêu kiểu nào (color, fontColor, bold, numFmt, align, border, wrap).")
        }
    }
}

/// Một sổ tính .xlsx đang sửa: giữ nguyên mọi phần chưa đụng tới, chỉ đọc lại và ghi lại phần bảng tính, kiểu, biểu đồ cần đổi.
final class XlsxBook {
    static let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let maxInput = 50 * 1024 * 1024, maxCells = 100_000
    private static let sheetOrder = ["sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios",
                                     "autoFilter", "sortState", "dataConsolidate", "customSheetViews", "mergeCells", "phoneticPr", "conditionalFormatting", "dataValidations",
                                     "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks", "customProperties", "cellWatches",
                                     "ignoredErrors", "smartTags", "drawing", "legacyDrawing", "legacyDrawingHF", "picture", "oleObjects", "controls", "webPublishItems", "tableParts", "extLst"]
    private static let bookOrder = ["fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets", "functionGroups", "externalReferences",
                                    "definedNames", "calcPr", "oleSize", "customWorkbookViews", "pivotCaches", "extLst"]

    private var raw: [String: Data] = [:]
    private(set) var order: [String] = []
    private var docs: [String: XMLDocument] = [:]
    private var dirty: Set<String> = []
    private var shared: [String] = []
    private var styleCache: [String: Int] = [:]
    private(set) var sheets: [(name: String, path: String)] = []
    var report: [String] = []

    // MARK: Mở và ghi

    init(data: Data) throws {
        guard data.count <= Self.maxInput else { throw PVTAError("Tệp Excel quá lớn (tối đa 50 MB).") }
        let zip = try ZipArchive(data: data)
        guard zip.entries["xl/workbook.xml"] != nil else { throw PVTAError("Đây không phải tệp Excel (.xlsx) hợp lệ hoặc tệp đã bị hỏng.") }
        order = zip.names
        for n in order { raw[n] = try zip.read(n) }
        let wb = try doc("xl/workbook.xml")
        let rels = try relationships(of: "xl/workbook.xml")
        let list = wb.rootElement()?.elements(forName: "sheets").first?.elements(forName: "sheet") ?? []
        for (i, s) in list.enumerated() {
            let name = s.attribute(forName: "name")?.stringValue ?? "Sheet\(i + 1)"
            let rid = s.attribute(forName: "r:id")?.stringValue
            let target = rid.flatMap { rels[$0] }.map { Self.resolve($0, from: "xl/workbook.xml") } ?? "xl/worksheets/sheet\(i + 1).xml"
            guard raw[target] != nil else { throw PVTAError("Tệp Excel thiếu trang tính “\(name)” nên PVTA không đọc được.") }
            sheets.append((name, target))
        }
        guard !sheets.isEmpty else { throw PVTAError("Tệp Excel không có trang tính nào.") }
        if let ss = raw["xl/sharedStrings.xml"], let d = try? XMLDocument(data: ss, options: [.nodePreserveWhitespace]) {
            shared = (d.rootElement()?.elements(forName: "si") ?? []).map { si in Self.allText(si) }
        }
    }

    static func allText(_ e: XMLElement) -> String {
        var s = ""
        func walk(_ n: XMLElement) {
            for case let c as XMLElement in n.children ?? [] {
                if c.name == "t" { s += c.stringValue ?? "" } else if c.name != "rPh" && c.name != "phoneticPr" { walk(c) }
            }
        }
        walk(e)
        return s
    }

    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var comps = part.split(separator: "/").dropLast().map(String.init)
        for p in target.split(separator: "/") { if p == ".." { _ = comps.popLast() } else if p != "." { comps.append(String(p)) } }
        return comps.joined(separator: "/")
    }

    private func relsPath(_ part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent, file = (part as NSString).lastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
    }

    private func relationships(of part: String) throws -> [String: String] {
        guard raw[relsPath(part)] != nil else { return [:] }
        var out: [String: String] = [:]
        for r in try doc(relsPath(part)).rootElement()?.elements(forName: "Relationship") ?? [] {
            if let id = r.attribute(forName: "Id")?.stringValue, let t = r.attribute(forName: "Target")?.stringValue { out[id] = t }
        }
        return out
    }

    func doc(_ part: String) throws -> XMLDocument {
        if let d = docs[part] { return d }
        guard let data = raw[part] else { throw PVTAError("Tệp Excel thiếu phần “\(part)”.") }
        do {
            let d = try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveCDATA])
            docs[part] = d
            return d
        } catch { throw PVTAError("Nội dung tệp Excel bị hỏng nên PVTA không đọc được.") }
    }

    func touch(_ part: String) { dirty.insert(part); if !order.contains(part) { order.append(part) } }

    func addPart(_ name: String, _ data: Data) {
        raw[name] = data
        docs[name] = nil
        if !order.contains(name) { order.append(name) }
    }

    func serialize() -> Data {
        var z = ZipWriter()
        for n in order {
            if dirty.contains(n), let d = docs[n] { z.add(n, d.xmlData(options: [.nodePreserveWhitespace])) } else if let r = raw[n] { z.add(n, r) }
        }
        return z.finish()
    }

    // MARK: Trang tính

    func sheet(_ name: String?) throws -> (name: String, path: String) {
        guard let name else { return sheets[0] }
        guard let s = sheets.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw PVTAError("Không có trang tính “\(name)”. Hiện có: " + sheets.map { "“\($0.name)”" }.joined(separator: ", ") + ".")
        }
        return s
    }

    private func sheetData(_ path: String) throws -> XMLElement {
        let root = try doc(path).rootElement()!
        if let sd = root.elements(forName: "sheetData").first { return sd }
        let sd = XMLElement(name: "sheetData")
        Self.insertOrdered(root, sd, Self.sheetOrder)
        return sd
    }

    static func insertOrdered(_ parent: XMLElement, _ child: XMLElement, _ order: [String]) {
        let rank = order.firstIndex(of: child.localName ?? "") ?? order.count
        var at = parent.childCount
        for (i, c) in (parent.children ?? []).enumerated() {
            if let ce = c as? XMLElement, let r = order.firstIndex(of: ce.localName ?? ""), r > rank { at = i; break }
        }
        parent.insertChild(child, at: at)
    }

    private func orderedChild(_ path: String, _ name: String) throws -> XMLElement {
        let root = try doc(path).rootElement()!
        if let e = root.elements(forName: name).first { return e }
        let e = XMLElement(name: name)
        Self.insertOrdered(root, e, Self.sheetOrder)
        return e
    }

    private func cellElement(_ sd: XMLElement, _ ref: String, create: Bool) -> XMLElement? {
        guard let (col, rowN) = FormulaEngine.split(ref) else { return nil }
        var row: XMLElement?
        var rowIndex = sd.childCount
        for (i, c) in (sd.children ?? []).enumerated() {
            guard let r = c as? XMLElement, r.name == "row", let n = Int(r.attribute(forName: "r")?.stringValue ?? "") else { continue }
            if n == rowN { row = r; break }
            if n > rowN { rowIndex = i; break }
        }
        if row == nil {
            guard create else { return nil }
            let r = XMLElement(name: "row")
            r.addAttribute(XMLNode.attribute(withName: "r", stringValue: String(rowN)) as! XMLNode)
            sd.insertChild(r, at: rowIndex)
            row = r
        }
        var at = row!.childCount
        for (i, c) in (row!.children ?? []).enumerated() {
            guard let ce = c as? XMLElement, let cr = ce.attribute(forName: "r")?.stringValue, let (cc, _) = FormulaEngine.split(cr) else { continue }
            if cc == col { return ce }
            if cc > col { at = i; break }
        }
        guard create else { return nil }
        let c = XMLElement(name: "c")
        c.addAttribute(XMLNode.attribute(withName: "r", stringValue: ref.replacingOccurrences(of: "$", with: "").uppercased()) as! XMLNode)
        row!.insertChild(c, at: at)
        return c
    }

    private static func setAttr(_ e: XMLElement, _ k: String, _ v: String?) {
        e.removeAttribute(forName: k)
        if let v { e.addAttribute(XMLNode.attribute(withName: k, stringValue: v) as! XMLNode) }
    }

    // MARK: Đọc ô

    /// Mọi ô có dữ liệu: ref → (giá trị đã lưu, công thức).
    func cells(of path: String) throws -> [String: (value: XValue, formula: String?)] {
        var out: [String: (XValue, String?)] = [:]
        for case let row as XMLElement in (try sheetData(path)).children ?? [] where row.name == "row" {
            for case let c as XMLElement in row.children ?? [] where c.name == "c" {
                guard let ref = c.attribute(forName: "r")?.stringValue else { continue }
                let t = c.attribute(forName: "t")?.stringValue ?? "n"
                let v = c.elements(forName: "v").first?.stringValue
                var value: XValue = .empty
                switch t {
                case "s": if let i = v.flatMap(Int.init), shared.indices.contains(i) { value = .text(shared[i]) }
                case "inlineStr": value = .text(c.elements(forName: "is").first.map(Self.allText) ?? "")
                case "str": value = .text(v ?? "")
                case "b": value = .bool(v == "1")
                case "e": value = .error(v ?? "#VALUE!")
                default: if let v, let d = Double(v) { value = .number(d) }
                }
                let f = c.elements(forName: "f").first
                let formula = f.flatMap { $0.stringValue?.isEmpty == false ? "=" + $0.stringValue! : nil }
                if value != .empty || formula != nil { out[ref] = (value, formula) }
            }
        }
        return out
    }

    /// Ô đọc nguyên văn từ XML (không đổi qua số thực): loại ô, chữ của `<v>`, chữ đã giải chuỗi chung, có công thức không.
    struct RawCell: Equatable {
        var type: String
        var raw: String?
        var text: String?
        var formula: String?
        var cached: String?
    }

    func rawCells(of path: String) throws -> [String: RawCell] {
        var out: [String: RawCell] = [:]
        for case let row as XMLElement in (try sheetData(path)).children ?? [] where row.name == "row" {
            for case let c as XMLElement in row.children ?? [] where c.name == "c" {
                guard let ref = c.attribute(forName: "r")?.stringValue else { continue }
                let t = c.attribute(forName: "t")?.stringValue ?? "n"
                let v = c.elements(forName: "v").first?.stringValue
                var text: String?
                switch t {
                case "s": if let i = v.flatMap(Int.init), shared.indices.contains(i) { text = shared[i] }
                case "inlineStr": text = c.elements(forName: "is").first.map(Self.allText)
                case "str": text = v
                default: break
                }
                let f = c.elements(forName: "f").first.map { $0.stringValue ?? "" }
                out[ref] = RawCell(type: t, raw: v, text: text, formula: f, cached: f != nil ? v : nil)
            }
        }
        return out
    }

    func engine() throws -> FormulaEngine {
        var all: [String: [String: (value: XValue, formula: String?)]] = [:]
        for s in sheets { all[s.name] = try cells(of: s.path) }
        return FormulaEngine(sheets: all)
    }

    // MARK: Ghi ô

    func set(sheet name: String?, ref: String, _ v: JSONValue?) throws {
        let (_, path) = try sheet(name)
        guard FormulaEngine.split(ref) != nil else { throw PVTAError("Địa chỉ ô “\(ref)” không hợp lệ (ví dụ B2).") }
        let c = cellElement(try sheetData(path), ref, create: true)!
        for ch in (c.children ?? []).indices.reversed() { c.removeChild(at: ch) }
        Self.setAttr(c, "t", nil)
        switch v {
        case .string(let s)?:
            if s.hasPrefix("="), s.count > 1 {
                let f = XMLElement(name: "f"); f.stringValue = String(s.dropFirst()); c.addChild(f)
            } else if !s.isEmpty {
                guard s.count <= 32_000 else { throw PVTAError("Ô \(ref) có quá nhiều chữ (tối đa 32.000 ký tự).") }
                Self.setAttr(c, "t", "inlineStr")
                let isE = XMLElement(name: "is"), t = XMLElement(name: "t")
                t.stringValue = s
                t.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
                isE.addChild(t); c.addChild(isE)
            }
        case .number(let d)?:
            guard d.isFinite else { throw PVTAError("Ô \(ref): số phải là số hữu hạn.") }
            let e = XMLElement(name: "v"); e.stringValue = XValue.format(d); c.addChild(e)
        case .bool(let b)?:
            Self.setAttr(c, "t", "b")
            let e = XMLElement(name: "v"); e.stringValue = b ? "1" : "0"; c.addChild(e)
        default: break
        }
        touch(path)
    }

    static func range(_ text: String) throws -> (c1: Int, r1: Int, c2: Int, r2: Int) {
        let parts = text.split(separator: ":").map(String.init)
        guard let a = FormulaEngine.split(parts[0]), let b = parts.count == 2 ? FormulaEngine.split(parts[1]) : a, parts.count <= 2 else {
            throw PVTAError("Vùng “\(text)” không hợp lệ (ví dụ A1:C10).")
        }
        return (min(a.col, b.col), min(a.row, b.row), max(a.col, b.col), max(a.row, b.row))
    }

    func setRows(sheet: String?, at start: String, rows: [JSONValue]) throws {
        guard let (c0, r0) = FormulaEngine.split(start) else { throw PVTAError("Địa chỉ ô “\(start)” không hợp lệ.") }
        guard rows.count * (rows.map { if case .array(let a) = $0 { return a.count } else { return 0 } }.max() ?? 0) <= Self.maxCells else { throw PVTAError("Quá nhiều ô cho một lần ghi (tối đa \(Self.maxCells)).") }
        for (i, row) in rows.enumerated() {
            guard case .array(let cells) = row else { throw PVTAError("Mỗi hàng phải là một danh sách ô.") }
            for (j, v) in cells.enumerated() where v != .null {
                guard c0 + j <= 16_384, r0 + i <= 1_048_576 else { throw PVTAError("Ghi vượt quá giới hạn của Excel (cột XFD, hàng 1.048.576).") }
                try set(sheet: sheet, ref: FormulaEngine.letters(c0 + j) + String(r0 + i), v)
            }
        }
    }

    // MARK: Kiểu ô

    private func styles() throws -> XMLDocument {
        if raw["xl/styles.xml"] == nil { try addStylesPart() }
        return try doc("xl/styles.xml")
    }

    private func addStylesPart() throws {
        addPart("xl/styles.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"\(Self.ns)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>".utf8))
        try addRelationship(part: "xl/workbook.xml", id: "rIdPvtaStyles", type: Self.rel + "/styles", target: "styles.xml")
        try addOverride("/xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml")
    }

    func addRelationship(part: String, id: String, type: String, target: String) throws {
        let rp = relsPath(part)
        if raw[rp] == nil { addPart(rp, Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>".utf8)) }
        let r = XMLElement(name: "Relationship")
        for (k, v) in [("Id", id), ("Type", type), ("Target", target)] { r.addAttribute(XMLNode.attribute(withName: k, stringValue: v) as! XMLNode) }
        try doc(rp).rootElement()!.addChild(r)
        touch(rp)
    }

    func addOverride(_ partName: String, _ type: String) throws {
        let root = try doc("[Content_Types].xml").rootElement()!
        if root.elements(forName: "Override").contains(where: { $0.attribute(forName: "PartName")?.stringValue == partName }) { return }
        let o = XMLElement(name: "Override")
        o.addAttribute(XMLNode.attribute(withName: "PartName", stringValue: partName) as! XMLNode)
        o.addAttribute(XMLNode.attribute(withName: "ContentType", stringValue: type) as! XMLNode)
        root.addChild(o)
        touch("[Content_Types].xml")
    }

    private func appendCounted(_ parent: XMLElement, _ child: XMLElement) -> Int {
        parent.addChild(child)
        parent.removeAttribute(forName: "count")
        parent.addAttribute(XMLNode.attribute(withName: "count", stringValue: String(parent.childCount)) as! XMLNode)
        return parent.childCount - 1
    }

    private static let builtinFormats = ["General": 0, "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "dd/mm/yyyy": 14]

    private func styleIndex(base: Int, _ s: XStyle) throws -> Int {
        let key = "\(base)|\(s.fill ?? "")|\(s.fontColor ?? "")|\(s.bold.map(String.init(describing:)) ?? "")|\(s.numFmt ?? "")|\(s.align ?? "")|\(s.border.map(String.init(describing:)) ?? "")|\(s.wrap.map(String.init(describing:)) ?? "")"
        if let i = styleCache[key] { return i }
        let st = try styles()
        let root = st.rootElement()!
        func section(_ name: String) -> XMLElement {
            if let e = root.elements(forName: name).first { return e }
            let e = XMLElement(name: name)
            let order = ["numFmts", "fonts", "fills", "borders", "cellStyleXfs", "cellXfs", "cellStyles", "dxfs", "tableStyles", "colors", "extLst"]
            Self.insertOrdered(root, e, order)
            return e
        }
        let xfs = section("cellXfs")
        let list = xfs.elements(forName: "xf")
        let xf = (base < list.count ? list[base].copy() : XMLElement(name: "xf")) as! XMLElement
        func attr(_ k: String) -> Int { Int(xf.attribute(forName: k)?.stringValue ?? "0") ?? 0 }
        if s.fill != nil {
            let fills = section("fills")
            let f = XMLElement(name: "fill"), p = XMLElement(name: "patternFill")
            Self.setAttr(p, "patternType", "solid")
            let fg = XMLElement(name: "fgColor"); Self.setAttr(fg, "rgb", "FF" + s.fill!)
            let bg = XMLElement(name: "bgColor"); Self.setAttr(bg, "indexed", "64")
            p.addChild(fg); p.addChild(bg); f.addChild(p)
            Self.setAttr(xf, "fillId", String(appendCounted(fills, f)))
            Self.setAttr(xf, "applyFill", "1")
        }
        if s.bold != nil || s.fontColor != nil {
            let fonts = section("fonts")
            let all = fonts.elements(forName: "font")
            let font = (attr("fontId") < all.count ? all[attr("fontId")].copy() : XMLElement(name: "font")) as! XMLElement
            if let b = s.bold {
                font.elements(forName: "b").forEach { $0.detach() }
                if b { Self.insertOrdered(font, XMLElement(name: "b"), ["b", "i", "strike", "condense", "extend", "outline", "shadow", "u", "vertAlign", "sz", "color", "name", "family", "charset", "scheme"]) }
            }
            if let c = s.fontColor {
                font.elements(forName: "color").forEach { $0.detach() }
                let ce = XMLElement(name: "color"); Self.setAttr(ce, "rgb", "FF" + c)
                Self.insertOrdered(font, ce, ["b", "i", "strike", "condense", "extend", "outline", "shadow", "u", "vertAlign", "sz", "color", "name", "family", "charset", "scheme"])
            }
            Self.setAttr(xf, "fontId", String(appendCounted(fonts, font)))
            Self.setAttr(xf, "applyFont", "1")
        }
        if let fmt = s.numFmt {
            var id = Self.builtinFormats[fmt]
            if id == nil {
                let nf = section("numFmts")
                if let e = nf.elements(forName: "numFmt").first(where: { $0.attribute(forName: "formatCode")?.stringValue == fmt }) { id = Int(e.attribute(forName: "numFmtId")?.stringValue ?? "") }
                else {
                    let used = nf.elements(forName: "numFmt").compactMap { Int($0.attribute(forName: "numFmtId")?.stringValue ?? "") }
                    let new = XMLElement(name: "numFmt"); id = max(164, (used.max() ?? 163) + 1)
                    Self.setAttr(new, "numFmtId", String(id!)); Self.setAttr(new, "formatCode", fmt)
                    _ = appendCounted(nf, new)
                }
            }
            Self.setAttr(xf, "numFmtId", String(id!)); Self.setAttr(xf, "applyNumberFormat", "1")
        }
        if let b = s.border {
            let borders = section("borders")
            if b {
                let e = XMLElement(name: "border")
                for side in ["left", "right", "top", "bottom"] {
                    let x = XMLElement(name: side); Self.setAttr(x, "style", "thin")
                    let c = XMLElement(name: "color"); Self.setAttr(c, "rgb", "FF808080"); x.addChild(c); e.addChild(x)
                }
                e.addChild(XMLElement(name: "diagonal"))
                let same = borders.elements(forName: "border").firstIndex { $0.xmlString == e.xmlString }
                Self.setAttr(xf, "borderId", String(same ?? appendCounted(borders, e)))
                Self.setAttr(xf, "applyBorder", "1")
            } else { Self.setAttr(xf, "borderId", "0") }
        }
        if s.align != nil || s.wrap != nil {
            let al = xf.elements(forName: "alignment").first ?? { let a = XMLElement(name: "alignment"); xf.addChild(a); return a }()
            if let a = s.align { Self.setAttr(al, "horizontal", a) }
            if let w = s.wrap { Self.setAttr(al, "wrapText", w ? "1" : "0") }
            Self.setAttr(xf, "applyAlignment", "1")
        }
        let idx = appendCounted(xfs, xf)
        touch("xl/styles.xml")
        styleCache[key] = idx
        return idx
    }

    func style(sheet name: String?, range: String, _ s: XStyle) throws {
        let (_, path) = try sheet(name)
        let r = try Self.range(range)
        guard (r.c2 - r.c1 + 1) * (r.r2 - r.r1 + 1) <= Self.maxCells else { throw PVTAError("Vùng quá lớn (tối đa \(Self.maxCells) ô).") }
        let sd = try sheetData(path)
        for row in r.r1...r.r2 {
            for col in r.c1...r.c2 {
                let c = cellElement(sd, FormulaEngine.letters(col) + String(row), create: true)!
                let base = Int(c.attribute(forName: "s")?.stringValue ?? "0") ?? 0
                Self.setAttr(c, "s", String(try styleIndex(base: base, s)))
            }
        }
        touch(path)
    }

    // MARK: Bố cục

    func setWidth(sheet name: String?, column: String, width: Double) throws {
        let (_, path) = try sheet(name)
        let col = FormulaEngine.column(column)
        guard col >= 1, col <= 16_384, width >= 1, width <= 255 else { throw PVTAError("Cột “\(column)” hoặc độ rộng \(width) không hợp lệ (1–255).") }
        let cols = try orderedChild(path, "cols")
        var map: [Int: (width: String, extra: [(String, String)])] = [:]
        for e in cols.elements(forName: "col") {
            guard let lo = Int(e.attribute(forName: "min")?.stringValue ?? ""), let hi = Int(e.attribute(forName: "max")?.stringValue ?? ""), hi - lo < 300 else { continue }
            let extra = (e.attributes ?? []).compactMap { a -> (String, String)? in
                guard let n = a.name, !["min", "max", "width", "customWidth"].contains(n) else { return nil }
                return (n, a.stringValue ?? "")
            }
            for i in lo...hi { map[i] = (e.attribute(forName: "width")?.stringValue ?? "9", extra) }
        }
        map[col] = (XValue.format(width), map[col]?.extra ?? [])
        for i in (cols.children ?? []).indices.reversed() { cols.removeChild(at: i) }
        for k in map.keys.sorted() {
            let e = XMLElement(name: "col")
            Self.setAttr(e, "min", String(k)); Self.setAttr(e, "max", String(k)); Self.setAttr(e, "width", map[k]!.width); Self.setAttr(e, "customWidth", "1")
            for (n, v) in map[k]!.extra { Self.setAttr(e, n, v) }
            cols.addChild(e)
        }
        touch(path)
    }

    func freeze(sheet name: String?, at ref: String) throws {
        let (_, path) = try sheet(name)
        guard let (col, row) = FormulaEngine.split(ref) else { throw PVTAError("Địa chỉ ô “\(ref)” không hợp lệ.") }
        let views = try orderedChild(path, "sheetViews")
        let view = views.elements(forName: "sheetView").first ?? { let v = XMLElement(name: "sheetView"); Self.setAttr(v, "workbookViewId", "0"); views.addChild(v); return v }()
        view.elements(forName: "pane").forEach { $0.detach() }
        view.elements(forName: "selection").forEach { $0.detach() }
        guard col > 1 || row > 1 else { touch(path); return }
        let pane = XMLElement(name: "pane")
        if col > 1 { Self.setAttr(pane, "xSplit", String(col - 1)) }
        if row > 1 { Self.setAttr(pane, "ySplit", String(row - 1)) }
        Self.setAttr(pane, "topLeftCell", ref.replacingOccurrences(of: "$", with: "").uppercased())
        Self.setAttr(pane, "activePane", col > 1 && row > 1 ? "bottomRight" : row > 1 ? "bottomLeft" : "topRight")
        Self.setAttr(pane, "state", "frozen")
        view.insertChild(pane, at: 0)
        touch(path)
    }

    func filter(sheet name: String?, range: String) throws {
        let (_, path) = try sheet(name)
        let r = try Self.range(range)
        let e = try orderedChild(path, "autoFilter")
        Self.setAttr(e, "ref", "\(FormulaEngine.letters(r.c1))\(r.r1):\(FormulaEngine.letters(r.c2))\(r.r2)")
        touch(path)
    }

    func merge(sheet name: String?, range: String) throws {
        let (_, path) = try sheet(name)
        let r = try Self.range(range)
        guard r.c1 != r.c2 || r.r1 != r.r2 else { throw PVTAError("Vùng gộp cần ít nhất hai ô.") }
        let ref = "\(FormulaEngine.letters(r.c1))\(r.r1):\(FormulaEngine.letters(r.c2))\(r.r2)"
        let mc = try orderedChild(path, "mergeCells")
        for e in mc.elements(forName: "mergeCell") {
            if let other = try? Self.range(e.attribute(forName: "ref")?.stringValue ?? ""), other.c1 <= r.c2, other.c2 >= r.c1, other.r1 <= r.r2, other.r2 >= r.r1 {
                throw PVTAError("Vùng \(ref) chồng lên vùng đã gộp \(e.attribute(forName: "ref")?.stringValue ?? "").")
            }
        }
        let e = XMLElement(name: "mergeCell"); Self.setAttr(e, "ref", ref)
        mc.addChild(e)
        Self.setAttr(mc, "count", String(mc.childCount))
        touch(path)
    }

    func addSheet(_ name: String) throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 31, n.range(of: #"[\[\]:*?/\\]"#, options: .regularExpression) == nil, !n.hasPrefix("'"), !n.hasSuffix("'") else {
            throw PVTAError("Tên trang tính “\(name)” không hợp lệ (1–31 ký tự, không có [ ] : * ? / \\).")
        }
        guard !sheets.contains(where: { $0.name.lowercased() == n.lowercased() }) else { throw PVTAError("Đã có trang tính tên “\(n)”.") }
        guard sheets.count < 100 else { throw PVTAError("Tối đa 100 trang tính.") }
        var i = sheets.count + 1
        while raw["xl/worksheets/sheet\(i).xml"] != nil { i += 1 }
        let path = "xl/worksheets/sheet\(i).xml"
        addPart(path, Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"\(Self.ns)\"><sheetData/></worksheet>".utf8))
        let rid = "rIdPvtaSheet\(i)"
        try addRelationship(part: "xl/workbook.xml", id: rid, type: Self.rel + "/worksheet", target: "worksheets/sheet\(i).xml")
        try addOverride("/" + path, "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
        let wb = try doc("xl/workbook.xml").rootElement()!
        let list = wb.elements(forName: "sheets").first!
        let ids = list.elements(forName: "sheet").compactMap { Int($0.attribute(forName: "sheetId")?.stringValue ?? "") }
        let s = XMLElement(name: "sheet")
        Self.setAttr(s, "name", n); Self.setAttr(s, "sheetId", String((ids.max() ?? 0) + 1))
        s.addAttribute(XMLNode.attribute(withName: "r:id", stringValue: rid) as! XMLNode)
        list.addChild(s)
        if wb.attribute(forName: "xmlns:r") == nil { wb.addNamespace(XMLNode.namespace(withName: "r", stringValue: Self.rel) as! XMLNode) }
        touch("xl/workbook.xml")
        sheets.append((n, path))
    }

    // MARK: Tính lại và lưu giá trị

    /// Tính mọi công thức, ghi giá trị vào tệp và bật “tính lại khi mở” để Excel tự tính lại. Ô chưa tính được bị ghi vào báo cáo.
    func recalculate() throws {
        var eng = try engine()
        var shown = 0
        for s in sheets {
            let sd = try sheetData(s.path)
            var changed = false
            for case let row as XMLElement in sd.children ?? [] where row.name == "row" {
                for case let c as XMLElement in row.children ?? [] where c.name == "c" {
                    guard c.elements(forName: "f").first != nil, let ref = c.attribute(forName: "r")?.stringValue else { continue }
                    let v = eng.value(sheet: s.name, ref: ref)
                    c.elements(forName: "v").forEach { $0.detach() }
                    Self.setAttr(c, "t", nil)
                    func put(_ text: String, _ t: String?) {
                        let e = XMLElement(name: "v"); e.stringValue = text; c.addChild(e)
                        Self.setAttr(c, "t", t)
                    }
                    switch v {
                    case .number(let d): put(XValue.format(d).contains("e") ? String(d) : XValue.format(d), nil)
                    case .text(let t): put(t, "str")
                    case .bool(let b): put(b ? "1" : "0", "b")
                    case .error(let e) where e.hasPrefix("#UNSUPPORTED:"):
                        report.append("Ô \(s.name)!\(ref): PVTA chưa tính được hàm “\(e.dropFirst(13))”; Excel sẽ tự tính khi mở tệp.")
                    case .error(let e):
                        put(e, "e"); report.append("Ô \(s.name)!\(ref): công thức báo lỗi \(e).")
                    case .empty: put("0", nil)
                    }
                    if shown < 15, case .error = v {} else if shown < 15 { report.append("Ô \(s.name)!\(ref) = \(v.display)"); shown += 1 }
                    changed = true
                }
            }
            if changed { touch(s.path) }
        }
        let wb = try doc("xl/workbook.xml").rootElement()!
        let calc = wb.elements(forName: "calcPr").first ?? { let e = XMLElement(name: "calcPr"); Self.insertOrdered(wb, e, Self.bookOrder); return e }()
        Self.setAttr(calc, "fullCalcOnLoad", "1")
        touch("xl/workbook.xml")
    }

    // MARK: Biểu đồ

    func chart(sheet name: String?, type: String, title: String?, categories: String?, series: [(name: String?, values: String)], anchor: String) throws {
        let (sheetName, path) = try sheet(name)
        guard ["bar", "line", "pie"].contains(type) else { throw PVTAError("Loại biểu đồ “\(type)” không hợp lệ (bar, line, pie).") }
        guard !series.isEmpty, series.count <= 10 else { throw PVTAError("Biểu đồ cần 1 đến 10 chuỗi số liệu (series).") }
        guard let (ac, ar) = FormulaEngine.split(anchor) else { throw PVTAError("Vị trí biểu đồ “\(anchor)” không hợp lệ.") }
        func ref(_ r: String) throws -> String {
            let x = try Self.range(r)
            let q = sheetName.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" }) ? "'\(sheetName.replacingOccurrences(of: "'", with: "''"))'" : sheetName
            return "\(q)!$\(FormulaEngine.letters(x.c1))$\(x.r1):$\(FormulaEngine.letters(x.c2))$\(x.r2)"
        }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var n = 1
        while raw["xl/charts/chart\(n).xml"] != nil { n += 1 }
        let cat = try categories.map { "<c:cat><c:strRef><c:f>\(esc(try ref($0)))</c:f></c:strRef></c:cat>" } ?? ""
        var ser = ""
        for (i, s) in series.enumerated() {
            let tx = s.name.map { "<c:tx><c:v>\(esc($0))</c:v></c:tx>" } ?? ""
            ser += "<c:ser><c:idx val=\"\(i)\"/><c:order val=\"\(i)\"/>\(tx)\(cat)<c:val><c:numRef><c:f>\(esc(try ref(s.values)))</c:f></c:numRef></c:val>\(type == "line" ? "<c:smooth val=\"0\"/>" : "")</c:ser>"
        }
        let axes = "<c:axId val=\"111\"/><c:axId val=\"222\"/>"
        let plot: String
        switch type {
        case "bar": plot = "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(ser)<c:gapWidth val=\"150\"/>\(axes)</c:barChart>"
        case "line": plot = "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(ser)<c:marker val=\"1\"/>\(axes)</c:lineChart>"
        default: plot = "<c:pieChart><c:varyColors val=\"1\"/>\(ser)</c:pieChart>"
        }
        let axisXML = type == "pie" ? "" : "<c:catAx><c:axId val=\"111\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:numFmt formatCode=\"General\" sourceLinked=\"0\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"222\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx><c:valAx><c:axId val=\"222\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"l\"/><c:majorGridlines/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"111\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"between\"/></c:valAx>"
        let titleXML = title.map { "<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>\(esc($0))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title><c:autoTitleDeleted val=\"0\"/>" } ?? "<c:autoTitleDeleted val=\"1\"/>"
        let chartXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(Self.rel)\"><c:chart>\(titleXML)<c:plotArea><c:layout/>\(plot)\(axisXML)</c:plotArea><c:legend><c:legendPos val=\"b\"/></c:legend><c:plotVisOnly val=\"1\"/></c:chart></c:chartSpace>"
        addPart("xl/charts/chart\(n).xml", Data(chartXML.utf8))
        try addOverride("/xl/charts/chart\(n).xml", "application/vnd.openxmlformats-officedocument.drawingml.chart+xml")

        // Phần vẽ của trang tính: dùng lại nếu đã có.
        let sheetRels = try relationships(of: path)
        let root = try doc(path).rootElement()!
        var drawingPath: String
        if let d = root.elements(forName: "drawing").first, let rid = d.attribute(forName: "r:id")?.stringValue, let t = sheetRels[rid] {
            drawingPath = Self.resolve(t, from: path)
        } else {
            var k = 1
            while raw["xl/drawings/drawing\(k).xml"] != nil { k += 1 }
            drawingPath = "xl/drawings/drawing\(k).xml"
            addPart(drawingPath, Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"></xdr:wsDr>".utf8))
            try addOverride("/" + drawingPath, "application/vnd.openxmlformats-officedocument.drawing+xml")
            let rid = "rIdPvtaDrawing\(k)"
            try addRelationship(part: path, id: rid, type: Self.rel + "/drawing", target: "../drawings/drawing\(k).xml")
            let d = XMLElement(name: "drawing")
            d.addAttribute(XMLNode.attribute(withName: "r:id", stringValue: rid) as! XMLNode)
            Self.insertOrdered(root, d, Self.sheetOrder)
            if root.attribute(forName: "xmlns:r") == nil { root.addNamespace(XMLNode.namespace(withName: "r", stringValue: Self.rel) as! XMLNode) }
            touch(path)
        }
        let crid = "rIdPvtaChart\(n)"
        try addRelationship(part: drawingPath, id: crid, type: Self.rel + "/chart", target: "../charts/chart\(n).xml")
        let dd = try doc(drawingPath)
        let count = dd.rootElement()!.childCount + 2
        let anchorXML = "<xdr:twoCellAnchor xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(Self.rel)\"><xdr:from><xdr:col>\(ac - 1)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(ar - 1)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>\(ac + 7)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(ar + 15)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(count)\" name=\"Biểu đồ \(n)\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" r:id=\"\(crid)\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>"
        dd.rootElement()!.addChild(try XMLElement(xmlString: anchorXML))
        touch(drawingPath)
    }

    // MARK: Mô tả nội dung

    func describe(limitRows: Int = 200, limitCols: Int = 40) throws -> String {
        var eng = try engine()
        var out: [String] = []
        for s in sheets {
            let cells = try cells(of: s.path)
            let refs = cells.keys.compactMap { FormulaEngine.split($0) }
            guard let maxR = refs.map(\.row).max(), let maxC = refs.map(\.col).max() else { out.append("[Trang tính “\(s.name)”] (trống)"); continue }
            let minR = refs.map(\.row).min()!, minC = refs.map(\.col).min()!
            out.append("[Trang tính “\(s.name)” — vùng \(FormulaEngine.letters(minC))\(minR):\(FormulaEngine.letters(maxC))\(maxR)]")
            let c2 = min(maxC, minC + limitCols - 1)
            out.append("hàng | " + (minC...c2).map(FormulaEngine.letters).joined(separator: " | "))
            for r in minR...min(maxR, minR + limitRows - 1) {
                let line = (minC...c2).map { c -> String in
                    let ref = FormulaEngine.letters(c) + String(r)
                    guard let cell = cells[ref] else { return "" }
                    if let f = cell.formula { return eng.value(sheet: s.name, ref: ref).display + " {" + f + "}" }
                    return cell.value.display.replacingOccurrences(of: "\n", with: " ")
                }
                if line.allSatisfy(\.isEmpty) { continue }
                out.append("\(r) | " + line.joined(separator: " | "))
            }
            if maxR - minR + 1 > limitRows { out.append("… còn \(maxR - minR + 1 - limitRows) hàng") }
        }
        return out.joined(separator: "\n")
    }
}
