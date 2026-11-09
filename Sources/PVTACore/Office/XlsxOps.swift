import Foundation

/// Tạo mới và sửa tệp Excel bằng danh sách thao tác.
enum Xlsx {
    static let maxOps = 300, maxSheets = 30

    private static func blank(sheetNames: [String], title: String?) -> Data {
        var z = ZipWriter()
        let n = sheetNames.count
        var ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        var wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"\(XlsxBook.ns)\" xmlns:r=\"\(XlsxBook.rel)\"><bookViews><workbookView/></bookViews><sheets>"
        var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (i, name) in sheetNames.enumerated() {
            ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            wb += "<sheet name=\"\(Docx.esc(name).replacingOccurrences(of: "\"", with: "&quot;"))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(XlsxBook.rel)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        ct += "</Types>"
        wb += "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        rels += "<Relationship Id=\"rId\(n + 1)\" Type=\"\(XlsxBook.rel)/styles\" Target=\"styles.xml\"/></Relationships>"
        z.add("[Content_Types].xml", Data(ct.utf8))
        z.add("_rels/.rels", Data(Docx.rootRels.replacingOccurrences(of: "word/document.xml", with: "xl/workbook.xml").utf8))
        z.add("xl/workbook.xml", Data(wb.utf8))
        z.add("xl/_rels/workbook.xml.rels", Data(rels.utf8))
        z.add("xl/styles.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"\(XlsxBook.ns)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>".utf8))
        for i in 1...n { z.add("xl/worksheets/sheet\(i).xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"\(XlsxBook.ns)\"><sheetData/></worksheet>".utf8)) }
        z.add("docProps/core.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(Docx.esc(title ?? ""))</dc:title><dc:creator>PVTA</dc:creator></cp:coreProperties>".utf8))
        return z.finish()
    }

    private static func validName(_ n: String) throws -> String {
        let t = n.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 31, t.range(of: #"[\[\]:*?/\\]"#, options: .regularExpression) == nil else {
            throw PVTAError("Tên trang tính “\(n)” không hợp lệ (1–31 ký tự, không có [ ] : * ? / \\).")
        }
        return t
    }

    /// Tạo sổ tính: mỗi trang có `rows` (hàng đầu là tiêu đề), `formulas`, `merges`, `charts`. Hàng tiêu đề tự tô, đóng băng, bật lọc; có kẻ khung và độ rộng cột tự vừa.
    static func create(title: String?, sheets spec: [JSONValue]) throws -> (data: Data, report: [String]) {
        guard !spec.isEmpty, spec.count <= maxSheets else { throw PVTAError("Sổ tính cần 1 đến \(maxSheets) trang tính (sheets).") }
        let names = try spec.enumerated().map { try validName($0.element["name"]?.string ?? "Trang \($0.offset + 1)") }
        guard Set(names.map { $0.lowercased() }).count == names.count else { throw PVTAError("Tên các trang tính không được trùng nhau.") }
        let book = try XlsxBook(data: blank(sheetNames: names, title: title))
        for (i, s) in spec.enumerated() {
            let name = names[i]
            guard case .array(let rows)? = s["rows"] else { throw PVTAError("Trang “\(name)” cần danh sách hàng (rows).") }
            try book.setRows(sheet: name, at: "A1", rows: rows)
            if case .array(let fs)? = s["formulas"] {
                for f in fs {
                    guard let cell = f["cell"]?.string, let formula = f["formula"]?.string else { throw PVTAError("Mỗi công thức cần cell và formula.") }
                    try book.set(sheet: name, ref: cell, .string(formula.hasPrefix("=") ? formula : "=" + formula))
                }
            }
            let width = rows.map { if case .array(let a) = $0 { return a.count } else { return 0 } }.max() ?? 0
            if width > 0, !rows.isEmpty {
                let last = "\(FormulaEngine.letters(width))\(rows.count)"
                if s["header"]?.bool != false {
                    try book.style(sheet: name, range: "A1:\(FormulaEngine.letters(width))1", XStyle(["color": "1F3864", "fontColor": "FFFFFF", "bold": true, "align": "center"]))
                    try book.freeze(sheet: name, at: "A2")
                    try book.filter(sheet: name, range: "A1:\(last)")
                }
                try book.style(sheet: name, range: "A1:\(last)", XStyle(["border": true]))
                for c in 1...width {
                    let longest = rows.compactMap { r -> Int? in
                        guard case .array(let a) = r, c <= a.count else { return nil }
                        switch a[c - 1] { case .string(let t): return t.hasPrefix("=") ? 10 : t.split(separator: "\n").map(\.count).max() ?? 0; case .number(let d): return XValue.format(d).count; default: return 0 }
                    }.max() ?? 0
                    try book.setWidth(sheet: name, column: FormulaEngine.letters(c), width: Double(min(max(longest + 3, 8), 60)))
                }
            }
            if case .array(let ms)? = s["merges"] { for m in ms { if let r = m.string { try book.merge(sheet: name, range: r) } } }
            if case .array(let cs)? = s["charts"] { for c in cs { try chart(book, name, c) } }
        }
        try book.recalculate()
        return (book.serialize(), book.report)
    }

    private static func chart(_ book: XlsxBook, _ sheet: String?, _ c: JSONValue) throws {
        guard let type = c["type"]?.string, let anchor = c["anchor"]?.string else { throw PVTAError("Biểu đồ cần type (bar, line, pie) và anchor (ô đặt biểu đồ, ví dụ F2).") }
        guard case .array(let ser)? = c["series"] else { throw PVTAError("Biểu đồ cần series: [{\"name\":..,\"values\":\"C2:C10\"}].") }
        let series = try ser.map { s -> (String?, String) in
            guard let v = s["values"]?.string else { throw PVTAError("Mỗi series cần values (ví dụ C2:C10).") }
            return (s["name"]?.string, v)
        }
        try book.chart(sheet: sheet, type: type, title: c["title"]?.string, categories: c["categories"]?.string, series: series, anchor: anchor)
    }

    /// Sửa sổ tính có sẵn. Trả về tệp mới và báo cáo (giá trị công thức, cảnh báo).
    static func edit(_ data: Data, ops: [JSONValue]) throws -> (data: Data, report: [String]) {
        guard !ops.isEmpty else { throw PVTAError("Chưa có thao tác sửa nào (ops).") }
        guard ops.count <= maxOps else { throw PVTAError("Tối đa \(maxOps) thao tác cho một lần sửa.") }
        let book = try XlsxBook(data: data)
        var done: [String] = []
        for (k, op) in ops.enumerated() {
            let kind = op["op"]?.string ?? ""
            let label = "Thao tác \(k + 1) (\(kind))"
            let sheet = op["sheet"]?.string
            do {
                switch kind {
                case "set":
                    guard let cell = op["cell"]?.string else { throw PVTAError("cần cell.") }
                    if let f = op["formula"]?.string { try book.set(sheet: sheet, ref: cell, .string(f.hasPrefix("=") ? f : "=" + f)) }
                    else { try book.set(sheet: sheet, ref: cell, op["value"]) }
                    done.append("\(label): \(cell)")
                case "setRows":
                    guard case .array(let rows)? = op["rows"] else { throw PVTAError("cần rows.") }
                    try book.setRows(sheet: sheet, at: op["at"]?.string ?? "A1", rows: rows)
                    done.append("\(label): \(rows.count) hàng từ \(op["at"]?.string ?? "A1")")
                case "style":
                    guard let r = op["range"]?.string else { throw PVTAError("cần range.") }
                    try book.style(sheet: sheet, range: r, XStyle(op))
                    done.append("\(label): \(r)")
                case "filter": try book.filter(sheet: sheet, range: try need(op, "range")); done.append("\(label): \(op["range"]?.string ?? "")")
                case "freeze": try book.freeze(sheet: sheet, at: try need(op, "cell")); done.append("\(label): \(op["cell"]?.string ?? "")")
                case "merge": try book.merge(sheet: sheet, range: try need(op, "range")); done.append("\(label): \(op["range"]?.string ?? "")")
                case "width":
                    guard let w = op["width"]?.number else { throw PVTAError("cần width.") }
                    try book.setWidth(sheet: sheet, column: try need(op, "column"), width: w)
                    done.append("\(label): cột \(op["column"]?.string ?? "")")
                case "addSheet": try book.addSheet(try need(op, "name")); done.append("\(label): \(op["name"]?.string ?? "")")
                case "chart": try chart(book, sheet, op); done.append("\(label): biểu đồ \(op["type"]?.string ?? "")")
                default:
                    throw PVTAError("loại thao tác không hợp lệ (set, setRows, style, filter, freeze, merge, width, addSheet, chart).")
                }
            } catch let e as PVTAError { throw PVTAError("\(label): \(e.message)") }
        }
        try book.recalculate()
        return (book.serialize(), done + book.report)
    }

    private static func need(_ op: JSONValue, _ k: String) throws -> String {
        guard let s = op[k]?.string, !s.isEmpty else { throw PVTAError("cần \(k).") }
        return s
    }
}
