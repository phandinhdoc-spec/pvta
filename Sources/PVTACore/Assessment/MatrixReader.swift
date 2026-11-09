import Foundation

public struct SourceCell: Codable, Sendable, Equatable {
    public var column: Int
    public var endColumn: Int
    public var address: String
    /// Ô gốc khi ô này là phần gộp dọc.
    public var origin: String?
    public var text: String
}

public struct SourceRow: Codable, Sendable, Equatable {
    public var table: String
    public var row: Int
    public var cells: [SourceCell]
}

/// Ô số liệu của ma trận, giữ nguyên văn và tọa độ. Ô trống là chưa xác định, không phải 0.
public struct MatrixCell: Codable, Sendable, Equatable {
    public var table: String
    public var address: String
    public var column: Int
    public var topic: String
    /// I | II | III
    public var form: String
    public var headers: [String]
    /// NB | TH | VD | VDC
    public var level: String?
    public var code: String
    public var raw: String
    public var value: Double?
    /// câu | ý | câu/ý
    public var unit: String
}

public struct MatrixReading: Codable, Sendable, Equatable {
    public var cells: [MatrixCell]
    public var summaries: [MatrixCell]
    public var issues: [String]
}

public struct SpecItem: Codable, Sendable, Equatable {
    public var id: String
    public var topic: String
    public var unit: String
    public var level: String
    public var content: String
    public var ref: String
}

public struct SpecReading: Codable, Sendable, Equatable {
    public var items: [SpecItem]
    public var issues: [String]
}

/// Đọc bảng trong .docx giữ ô gộp ngang (gridSpan) và gộp dọc (vMerge) với tọa độ R#C#.
enum DocxTables {
    static func read(_ data: Data) throws -> [SourceRow] {
        let zip = try ZipArchive(data: data)
        guard let xml = try zip.read("word/document.xml"), let doc = try? XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever]) else {
            throw PVTAError("Không đọc được tệp Word (không phải .docx hợp lệ).")
        }
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        func kids(_ n: XMLNode, _ name: String) -> [XMLElement] { (n.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name } }
        func attr(_ e: XMLElement, _ n: String) -> String? { e.attribute(forLocalName: n, uri: w)?.stringValue }
        func text(_ cell: XMLElement) -> String {
            kids(cell, "p").map { p in
                var s = ""
                func walk(_ n: XMLNode) {
                    for c in (n.children ?? []) {
                        guard let e = c as? XMLElement else { continue }
                        if e.localName == "t" { s += e.stringValue ?? "" } else if e.localName == "tab" { s += " " } else { walk(e) }
                    }
                }
                walk(p)
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.joined(separator: " / ")
        }
        guard let body = try doc.rootElement().flatMap({ kids($0, "body").first }) else { return [] }
        var rows: [SourceRow] = []
        for (ti, tbl) in kids(body, "tbl").enumerated() {
            var above: [Int: String] = [:]            // cột → địa chỉ ô gốc của vùng gộp dọc đang chạy
            for (ri, tr) in kids(tbl, "tr").enumerated() {
                var col = 1
                var cells: [SourceCell] = []
                var next: [Int: String] = [:]
                for tc in kids(tr, "tc") {
                    let pr = kids(tc, "tcPr").first
                    let span = pr.flatMap { kids($0, "gridSpan").first }.flatMap { attr($0, "val") }.flatMap(Int.init) ?? 1
                    let vm = pr.flatMap { kids($0, "vMerge").first }
                    let address = "R\(ri + 1)C\(col)"
                    var origin: String?
                    if let vm, (attr(vm, "val") ?? "continue") != "restart" { origin = above[col] }
                    let root = origin ?? address
                    if vm != nil { for c in col..<(col + span) { next[c] = root } }
                    cells.append(SourceCell(column: col, endColumn: col + span - 1, address: address, origin: origin, text: origin == nil ? text(tc) : ""))
                    col += span
                }
                above = next
                rows.append(SourceRow(table: String(ti + 1), row: ri + 1, cells: cells))
            }
        }
        return rows
    }
}

/// Ma trận/đặc tả dạng bảng Markdown (| a | b |) để dán nhanh hoặc dùng làm tệp .md. Không có ô gộp.
enum MarkdownTables {
    static func read(_ text: String) -> [SourceRow] {
        var rows: [SourceRow] = [], table = 0, row = 0, inTable = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard line.hasPrefix("|") else { inTable = false; continue }
            if !inTable { table += 1; row = 0; inTable = true }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { continue }
            row += 1
            rows.append(SourceRow(table: String(table), row: row, cells: parts.enumerated().map { SourceCell(column: $0.offset + 1, endColumn: $0.offset + 1, address: "R\(row)C\($0.offset + 1)", origin: nil, text: $0.element) }))
        }
        return rows
    }
}

public enum MatrixReader {
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*/\s*"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Số liệu nguyên văn: chỉ nhận số thuần. “1/2” không phải 12 hay hai số riêng.
    static func number(_ text: String) -> Double? {
        let t = text.replacingOccurrences(of: #"^(?:\s*/)+|(?:/\s*)+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"^\d+(?:[.,]\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    static func levelCode(_ header: String) -> String? {
        let h = Fold.text(header)
        guard ["biet", "nhan biet", "hieu", "thong hieu", "van dung", "van dung cao"].contains(h) else { return nil }
        return h.contains("cao") ? "VDC" : h.contains("van dung") ? "VD" : h.contains("hieu") ? "TH" : "NB"
    }

    public static func rows(docx data: Data) throws -> [SourceRow] { try DocxTables.read(data) }
    public static func rows(markdown text: String) -> [SourceRow] { MarkdownTables.read(text) }

    /// Đọc số câu/ý theo ô: dạng I, II, III ở cột hình thức, các cột mức độ nằm trước cột “Tổng số”.
    public static func readMatrix(_ rows: [SourceRow]) -> MatrixReading {
        var cells: [MatrixCell] = [], summaries: [MatrixCell] = [], issues: [String] = []
        let byAddress = Dictionary(rows.flatMap { r in r.cells.map { ("\(r.table):\($0.address)", $0) } }, uniquingKeysWith: { a, _ in a })
        func resolve(_ table: String, _ cell: SourceCell) -> String {
            var seen = Set<String>(), current: SourceCell? = cell
            while let c = current, let o = c.origin {
                if !seen.insert(o).inserted { return "" }
                current = byAddress["\(table):\(o)"]
            }
            return current?.text ?? ""
        }
        func isForm(_ s: String) -> Bool { ["I", "II", "III"].contains(s.trimmingCharacters(in: .whitespaces)) }
        for table in Array(Set(rows.map(\.table))).sorted() {
            let tr = rows.filter { $0.table == table }
            guard let first = tr.firstIndex(where: { $0.cells.contains { isForm(resolve(table, $0)) } }) else { continue }
            let headerRows = Array(tr[..<first])
            guard let boundary = headerRows.flatMap(\.cells).first(where: { Fold.text(clean($0.text)).replacingOccurrences(of: " ", with: "").contains("tongso") })?.column else {
                issues.append("Bảng \(table): chưa xác định cột tổng số; giữ văn bản nguồn để đối chiếu."); continue
            }
            for row in tr[first...] {
                guard let formCell = row.cells.first(where: { isForm(resolve(table, $0)) }) else { continue }
                let form = resolve(table, formCell).trimmingCharacters(in: .whitespaces)
                let summary = row.cells.contains { c in let t = Fold.text(resolve(table, c)); return t.range(of: #"so cau tn\s*/?\s*so y"#, options: .regularExpression) != nil || t.hasPrefix("tong") }
                let topic = clean(row.cells.first.map { resolve(table, $0) } ?? "")
                for cell in row.cells where cell.column > formCell.column && cell.column < boundary && cell.origin == nil {
                    let headers = headerRows.flatMap { r in r.cells.filter { $0.column <= cell.column && $0.endColumn >= cell.endColumn }.map { clean(resolve(table, $0)) } }.filter { !$0.isEmpty }
                    let level = headers.compactMap(Self.levelCode).first
                    let code = headers.first { $0.range(of: #"^TN\d"#, options: [.regularExpression, .caseInsensitive]) != nil }?.replacingOccurrences(of: " ", with: "") ?? ""
                    let value = number(cell.text)
                    let entry = MatrixCell(table: table, address: cell.address, column: cell.column, topic: topic, form: form, headers: headers, level: level, code: code,
                                           raw: cell.text, value: value, unit: form == "I" ? "câu" : form == "II" ? "ý" : "câu/ý")
                    if summary { summaries.append(entry) } else { cells.append(entry) }
                    if !cell.text.trimmingCharacters(in: .whitespaces).isEmpty, value == nil { issues.append("Bảng \(table) \(cell.address): giữ nguyên “\(cell.text)”, chưa xác định số lượng.") }
                    if let v = value, v > 0, level == nil { issues.append("Bảng \(table) \(cell.address): tiêu đề chưa xác định mức độ.") }
                }
            }
        }
        if cells.isEmpty { issues.append("Chưa nhận diện được bảng ma trận theo hàng dạng I, II, III và cột tổng số. Xem văn bản nguồn; không dùng ma trận mẫu thay thế.") }
        return MatrixReading(cells: cells, summaries: summaries, issues: issues + auditTotals(cells, summaries))
    }

    /// So tổng các ô chi tiết với dòng tổng của chính nguồn (không so với mẫu cố định). Lệch thì báo, không tự sửa.
    static func auditTotals(_ cells: [MatrixCell], _ summaries: [MatrixCell]) -> [String] {
        var sums: [String: Double] = [:]
        for c in cells { if let v = c.value { sums["\(c.table):\(c.form):\(c.column)", default: 0] += v } }
        return summaries.compactMap { s in
            guard let v = s.value, let actual = sums["\(s.table):\(s.form):\(s.column)"], abs(actual - v) > 1e-6 else { return nil }
            return "Bảng \(s.table) \(s.address): tổng nguồn \(s.raw), tổng các ô chi tiết đã ghi \(actual.formatted(.number.precision(.fractionLength(0...2)))); cần đối chiếu nguồn, không tự sửa."
        }
    }

    // MARK: Đặc tả (yêu cầu cần đạt)

    /// Đặc tả dạng cột “Chủ đề | Nội dung/đơn vị | Mức độ | Yêu cầu cần đạt”, hoặc yêu cầu nằm dưới các cột Nhận biết/Thông hiểu/Vận dụng.
    public static func readSpec(_ rows: [SourceRow]) -> SpecReading {
        var items: [SpecItem] = [], issues: [String] = []
        for table in Array(Set(rows.map(\.table))).sorted() {
            let tr = rows.filter { $0.table == table }
            guard let h = tr.firstIndex(where: { r in r.cells.contains { Fold.text($0.text).contains("yeu cau can dat") || levelCode($0.text) != nil } }) else { continue }
            let header = tr[h]
            func col(_ keys: [String]) -> Int? { header.cells.first { c in keys.contains { Fold.text(clean(c.text)).contains($0) } }?.column }
            let topicCol = col(["chu de"]) ?? 1, unitCol = col(["noi dung", "don vi"])
            let levelCols = header.cells.compactMap { c in levelCode(clean(c.text)).map { (c, $0) } }
            var topic = "", unit = ""
            for row in tr[(h + 1)...] {
                let get = { (c: Int?) -> String in c.flatMap { cc in row.cells.first { $0.column == cc }?.text } ?? "" }
                if !get(topicCol).isEmpty { topic = clean(get(topicCol)) }
                if let uc = unitCol, !get(uc).isEmpty { unit = clean(get(uc)) }
                if let lvlCol = col(["muc do"]), let yc = col(["yeu cau can dat"]) {
                    let level = levelCode(clean(get(lvlCol))), content = get(yc).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { continue }
                    guard let level else { issues.append("Bảng \(table) hàng \(row.row): chưa xác định mức độ của yêu cầu, giữ nguyên văn."); continue }
                    items.append(SpecItem(id: "\(table).\(row.row)", topic: topic, unit: unit, level: level, content: content, ref: "Bảng \(table) · R\(row.row)"))
                } else {
                    for (hc, lv) in levelCols {
                        let content = row.cells.first { $0.column == hc.column }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !content.isEmpty { items.append(SpecItem(id: "\(table).\(row.row).\(lv)", topic: topic, unit: unit, level: lv, content: content, ref: "Bảng \(table) · R\(row.row)C\(hc.column)")) }
                    }
                }
            }
        }
        if items.isEmpty { issues.append("Chưa nhận diện được bảng đặc tả (cột Yêu cầu cần đạt hoặc các cột mức độ). Không dùng yêu cầu mẫu thay thế.") }
        return SpecReading(items: items, issues: issues)
    }
}
