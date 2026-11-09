import CryptoKit
import Foundation

/// Vùng đối soát: khóa và giá trị nằm trong vùng, vùng không gồm hàng tiêu đề.
public struct ReconcileSide: Codable, Sendable, Equatable {
    public var sourceId: String
    public var sheet: String
    public var range: String
    public var keyColumn: String
    public var valueColumn: String
}

public struct ReconcileRow: Codable, Sendable, Equatable {
    public var key: String
    /// matched | value_mismatch | missing_source | missing_reference | duplicate_key | invalid_key | invalid_number | unverified_formula
    public var kind: String
    public var sourceLocation: String?
    public var referenceLocation: String?
    public var sourceValue: String?
    public var referenceValue: String?
    public var delta: String?
    public var tolerance: String
    public var evidence: String
}

public struct ReconcileSource: Codable, Sendable, Equatable {
    public var sourceId: String
    public var name: String
    public var sha256: String
    public var sheet: String
    public var range: String
    public var keyColumn: String
    public var valueColumn: String
    public var rowsRead: Int
}

public struct ReconcileExport: Codable, Sendable, Equatable {
    public var format: String
    public var path: String
    public var sha256: String
    public var bytes: Int
}

public struct ReconcileReport: Codable, Sendable, Equatable {
    public struct Summary: Codable, Sendable, Equatable { public var sourceRows: Int; public var referenceRows: Int; public var matched: Int; public var issues: Int }
    public var version: String
    public var createdAt: String
    public var unit: String
    public var tolerance: String
    public var sourceEdits: Bool
    public var formulas: String
    public var sources: [ReconcileSource]
    public var rows: [ReconcileRow]
    public var summary: Summary
    public var exports: [ReconcileExport]
}

/// Đối soát xác định (không AI): so hai cột số theo khóa, bằng số thập phân chính xác. Công thức luôn "chưa kiểm chứng".
enum Reconciler {
    static let maxRows = 10_000, maxCells = 200_000

    // MARK: Số thập phân

    private static let posix = Locale(identifier: "en_US_POSIX")
    /// Số thập phân chặt: không dấu phẩy, không tiền tệ; tối đa 34 chữ số có nghĩa và số mũ ±100 (giới hạn của Decimal).
    static func number(_ s: String?) -> Decimal? {
        guard let s, s.count <= 200, s.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
        let mant = s.split(whereSeparator: { $0 == "e" || $0 == "E" })[0]
        let digits = mant.filter(\.isNumber).drop { $0 == "0" }
        if digits.count > 34 { return nil }
        if let e = s.split(whereSeparator: { $0 == "e" || $0 == "E" }).dropFirst().first, let n = Int(e), abs(n) > 100 { return nil }
        guard let d = Decimal(string: s, locale: posix), d.isFinite else { return nil }
        return d
    }

    /// Sai số: số thập phân chuẩn không âm, không mũ, không dấu phẩy.
    static func tolerance(_ s: String) -> Decimal? {
        guard s.count <= 50, s.range(of: #"^(?:0|[1-9]\d*)(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return number(s)
    }

    /// Dạng viết thường (không mũ khoa học) của một số thập phân.
    static func plain(_ d: Decimal) -> String {
        let s = NSDecimalNumber(decimal: d).stringValue
        guard let e = s.firstIndex(where: { $0 == "E" || $0 == "e" }) else { return s }
        let mant = String(s[..<e]), exp = Int(s[s.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        let neg = mant.hasPrefix("-")
        let m = mant.replacingOccurrences(of: "-", with: "")
        let parts = m.split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
        var point = parts[0].count + exp
        if point <= 0 { digits = String(repeating: "0", count: -point + 1) + digits; point = 1 }
        if point > digits.count { digits += String(repeating: "0", count: point - digits.count) }
        let intPart = String(digits.prefix(point)), frac = String(digits.dropFirst(point))
        return (neg ? "-" : "") + intPart + (frac.isEmpty ? "" : "." + frac)
    }

    // MARK: Vùng

    static func column(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } }

    static func parse(_ side: ReconcileSide) throws -> (lo: Int, hi: Int, start: Int, end: Int) {
        guard let m = side.range.range(of: #"^([A-Z]{1,3})([1-9]\d*):([A-Z]{1,3})([1-9]\d*)$"#, options: .regularExpression) else { throw PVTAError("Vùng phải là A1:B10; không gồm tiêu đề.") }
        let r = String(side.range[m])
        let parts = r.split(separator: ":").map(String.init)
        func split(_ x: String) -> (String, Int) { let c = String(x.prefix { $0.isLetter }); return (c, Int(x.dropFirst(c.count))!) }
        let (c1, r1) = split(parts[0]), (c2, r2) = split(parts[1])
        let lo = column(c1), hi = column(c2)
        guard lo <= hi, r1 <= r2, hi <= 16384, r2 <= 1_048_576, r2 - r1 + 1 <= maxRows, (r2 - r1 + 1) * (hi - lo + 1) <= maxCells else { throw PVTAError("Vùng vượt giới hạn Excel/10.000 dòng/200.000 ô.") }
        for c in [side.keyColumn, side.valueColumn] {
            guard c.range(of: #"^[A-Z]{1,3}$"#, options: .regularExpression) != nil, (lo...hi).contains(column(c)) else { throw PVTAError("Cột phải nằm trong vùng đã chọn.") }
        }
        guard side.keyColumn != side.valueColumn else { throw PVTAError("Cột khóa và giá trị phải khác nhau.") }
        return (lo, hi, r1, r2)
    }

    struct Entry {
        var key: String
        var value: String?
        var location: String
        var error: String?
        var evidence: [String: String]
    }

    static func read(_ data: Data, name: String, side: ReconcileSide) throws -> (entries: [Entry], info: ReconcileSource) {
        let book = try XlsxBook(data: data)
        guard let sheet = book.sheets.first(where: { $0.name == side.sheet }) else { throw PVTAError("Trang tính “\(side.sheet)” không có trong “\(name)”.") }
        let box = try parse(side)
        let cells = try book.rawCells(of: sheet.path)
        var out: [Entry] = []
        for row in box.start...box.end {
            if row % 500 == 0 { try Task.checkCancellation() }
            let k = cells["\(side.keyColumn)\(row)"], v = cells["\(side.valueColumn)\(row)"]
            let address = "\(side.valueColumn)\(row)"
            let isText = { (c: XlsxBook.RawCell?) in c.map { ["s", "inlineStr", "str"].contains($0.type) } ?? false }
            let keyText = isText(k) ? k?.text : nil
            // Ô số lấy chữ nguyên của <v>; ô chữ dùng chữ của ô (phải là số thập phân chặt mới hợp lệ).
            let value: String? = v.map { ["s", "inlineStr", "str"].contains($0.type) ? $0.text : ($0.type == "n" ? $0.raw : $0.raw) } ?? nil
            let formula = k?.formula != nil || v?.formula != nil
            var error: String?
            if formula { error = "unverified_formula" }
            else if keyText?.trimmingCharacters(in: .whitespaces).isEmpty != false { error = "invalid_key" }
            else if v?.type == "b" || v?.type == "e" || number(value) == nil { error = "invalid_number" }
            var ev: [String: String] = ["key": keyText ?? "", "value": value ?? ""]
            if let f = v?.formula ?? k?.formula { ev["formula"] = f; ev["cachedValue"] = (v?.cached ?? "") }
            out.append(Entry(key: keyText ?? "", value: value, location: "\(name) / \(side.sheet) / \(address)", error: error, evidence: ev))
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (out, ReconcileSource(sourceId: side.sourceId, name: name, sha256: hash, sheet: side.sheet, range: side.range, keyColumn: side.keyColumn, valueColumn: side.valueColumn, rowsRead: out.count))
    }

    // MARK: Đối soát

    static func reconcile(source: (data: Data, name: String), reference: (data: Data, name: String), job: (source: ReconcileSide, reference: ReconcileSide, tolerance: String, unit: String), now: Date) throws -> ReconcileReport {
        guard let tol = tolerance(job.tolerance) else { throw PVTAError("Sai số phải là số thập phân không âm (không dấu phẩy, không mũ).") }
        let (left, a) = try read(source.data, name: source.name, side: job.source)
        try Task.checkCancellation()
        let (right, b) = try read(reference.data, name: reference.name, side: job.reference)
        try Task.checkCancellation()
        var rows: [ReconcileRow] = []
        func record(_ key: String, _ kind: String, source s: Entry? = nil, reference r: Entry? = nil, delta: String? = nil) {
            var ev: [String: String] = ["reason": kind]
            if let s { ev["source"] = flat(s.evidence) }
            if let r { ev["reference"] = flat(r.evidence) }
            if let delta, let s, let r { ev["expression"] = "\(s.value ?? "") - \(r.value ?? "") = \(delta)" }
            let json = (try? JSONSerialization.data(withJSONObject: ev, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            rows.append(ReconcileRow(key: key, kind: kind, sourceLocation: s?.location, referenceLocation: r?.location, sourceValue: s?.value, referenceValue: r?.value, delta: delta, tolerance: job.tolerance, evidence: json))
        }
        func flat(_ d: [String: String]) -> String { d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }
        var order: [String] = [], groups: [[String: [Entry]]] = [[:], [:]]
        for (i, list) in [left, right].enumerated() { for e in list { if groups[0][e.key] == nil && groups[1][e.key] == nil { order.append(e.key) }; groups[i][e.key, default: []].append(e) } }
        for key in order {
            try Task.checkCancellation()
            let ss = groups[0][key] ?? [], rs = groups[1][key] ?? []
            let invalid = (ss + rs).contains { $0.error != nil }, dup = ss.count > 1 || rs.count > 1
            if invalid || dup {
                let peer = (ss + rs).compactMap(\.error).first ?? "duplicate_key"
                for e in ss { record(key, e.error ?? (dup ? "duplicate_key" : peer), source: e) }
                for e in rs { record(key, e.error ?? (dup ? "duplicate_key" : peer), reference: e) }
                continue
            }
            switch (ss.first, rs.first) {
            case (nil, let r?): record(key, "missing_source", reference: r)
            case (let s?, nil): record(key, "missing_reference", source: s)
            case (let s?, let r?):
                let d = number(s.value)! - number(r.value)!
                record(key, abs(d) > tol ? "value_mismatch" : "matched", source: s, reference: r, delta: plain(d))
            default: break
            }
        }
        let matched = rows.filter { $0.kind == "matched" }.count
        let iso = ISO8601DateFormatter().string(from: now)
        return ReconcileReport(version: "1", createdAt: iso, unit: job.unit, tolerance: job.tolerance, sourceEdits: false,
                               formulas: "unverified; cached values are not recalculated or trusted", sources: [a, b], rows: rows,
                               summary: .init(sourceRows: left.count, referenceRows: right.count, matched: matched, issues: rows.count - matched), exports: [])
    }

    /// CSV: mọi ô đặt trong dấu nháy; ô giống công thức bảng tính thêm dấu ' phía trước.
    static func csv(_ report: ReconcileReport) -> String {
        func cell(_ v: String?) -> String {
            var s = v ?? ""
            if s.range(of: #"^[\s]*[=+\-@\t\r]"#, options: .regularExpression) != nil { s = "'" + s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let head = "key,kind,sourceLocation,referenceLocation,sourceValue,referenceValue,delta,tolerance,evidence"
        return ([head] + report.rows.map { [$0.key, $0.kind, $0.sourceLocation, $0.referenceLocation, $0.sourceValue, $0.referenceValue, $0.delta, $0.tolerance, $0.evidence].map(cell).joined(separator: ",") }).joined(separator: "\r\n") + "\r\n"
    }
}
