import Foundation

public struct Citation: Codable, Sendable, Equatable {
    public var no: String
    public var key: String
    public var type: String?
    public var index: Int
}

public struct LegalChunk: Codable, Sendable, Equatable {
    public var dieu: String
    public var khoan: String
    public var heading: String
    public var text: String
}

public struct DocFacts: Codable, Sendable, Equatable {
    public var no: String?
    public var issuedAt: String?
    public var effectiveAt: String?
    public var replaces: [String] = []
    public var repeals: [String] = []
    public var amends: [String] = []
}

/// Xử lý chữ của văn bản pháp quy bằng quy tắc (không cần AI): nhận số hiệu, cắt theo Điều/Khoản, đọc quan hệ thay thế/sửa đổi.
enum Legal {
    /// Khóa so sánh số hiệu: bỏ dấu, hoa, bỏ khoảng trắng. “115/2020/NĐ-CP” ≡ “115/2020/ND-CP”.
    static func noKey(_ no: String) -> String {
        Fold.text(no).uppercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
    }

    private static let type = "(?:Nghị định|Nghị quyết|Thông tư liên tịch|Thông tư|Quyết định|Chỉ thị|Công văn|Luật|Pháp lệnh|Kết luận|Hướng dẫn|Thông báo|Kế hoạch|Văn bản hợp nhất|Điều lệ|Quy định|Quy chế)"
    private static let withYear = #"\d{1,4}\s*/\s*(?:19|20)\d{2}\s*/\s*[A-ZĐ][A-ZĐ0-9]{1,}(?:-[A-ZĐ0-9]{1,12}){0,3}"#
    private static let noYear = #"\d{1,5}\s*/\s*[A-ZĐ]{2,}(?:-[A-Za-zĐđ0-9]{1,12}){1,3}"#
    private static let noRegex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}/])(\(withYear)|\(noYear))(?![\\p{L}\\p{N}/])")
    private static let typedRegex = try! NSRegularExpression(pattern: "(\(type))\\s+(?:số\\s+)?(\(withYear)|\(noYear))", options: .caseInsensitive)

    /// Trích mọi số hiệu văn bản trong một đoạn chữ; mỗi số hiệu một lần, theo thứ tự xuất hiện.
    static func citations(_ text: String) -> [Citation] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [String: Citation] = [:]
        for m in typedRegex.matches(in: text, range: all) {
            let no = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            let k = noKey(no)
            let t = ns.substring(with: m.range(at: 1))
            if out[k] == nil { out[k] = Citation(no: no, key: k, type: t.prefix(1).uppercased() + t.dropFirst().lowercased(), index: m.range.location) }
        }
        for m in noRegex.matches(in: text, range: all) {
            let no = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            let k = noKey(no)
            if out[k] == nil { out[k] = Citation(no: no, key: k, type: nil, index: m.range.location) }
        }
        return out.values.sorted { $0.index < $1.index }
    }

    static let chunkMax = 1800, paragraphTarget = 900

    /// Cắt theo Điều (rồi theo Khoản nếu Điều dài); văn bản không có “Điều” thì cắt theo đoạn khoảng 900 ký tự.
    static func chunks(_ text: String) -> [LegalChunk] {
        let dieu = try! NSRegularExpression(pattern: #"^\s*Điều\s+(\d+[a-zđ]?)\s*[.:]\s*(.*)$"#, options: [.caseInsensitive])
        let khoan = try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\s*[.)]\s+\S"#)
        struct Sec { var dieu: String; var heading: String; var lines: [String] }
        var sections: [Sec] = [], cur = Sec(dieu: "Phần mở đầu", heading: "", lines: [])
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = dieu.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                if cur.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { sections.append(cur) }
                cur = Sec(dieu: "Điều " + ns.substring(with: m.range(at: 1)).lowercased(), heading: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces), lines: [line])
            } else { cur.lines.append(line) }
        }
        if cur.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { sections.append(cur) }
        guard sections.contains(where: { $0.dieu.hasPrefix("Điều") }) else { return paragraphs(text) }
        var out: [LegalChunk] = []
        for s in sections {
            let body = s.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count <= chunkMax { out.append(LegalChunk(dieu: s.dieu, khoan: "", heading: s.heading, text: body)); continue }
            var k = "", buf: [String] = []
            func flush() {
                let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out += splitLong(LegalChunk(dieu: s.dieu, khoan: k, heading: s.heading, text: t)) }
                buf = []
            }
            for line in s.lines {
                let ns = line as NSString
                if let m = khoan.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    if !buf.isEmpty { flush() }
                    k = "khoản " + ns.substring(with: m.range(at: 1))
                }
                buf.append(line)
            }
            flush()
        }
        return out
    }

    private static func splitLong(_ c: LegalChunk) -> [LegalChunk] {
        guard c.text.count > chunkMax else { return [c] }
        var out: [LegalChunk] = [], buf = ""
        for line in c.text.components(separatedBy: "\n") {
            if !buf.isEmpty && buf.count + line.count > chunkMax { var x = c; x.text = buf.trimmingCharacters(in: .whitespacesAndNewlines); out.append(x); buf = "" }
            // Dòng dài hơn một khúc thì cắt thành nhiều khúc, không bỏ chữ.
            for piece in slices(line, chunkMax) {
                if !buf.isEmpty && buf.count + piece.count > chunkMax { var x = c; x.text = buf.trimmingCharacters(in: .whitespacesAndNewlines); out.append(x); buf = "" }
                buf += (buf.isEmpty ? "" : "\n") + piece
            }
        }
        if !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { var x = c; x.text = buf.trimmingCharacters(in: .whitespacesAndNewlines); out.append(x) }
        return out
    }

    private static func slices(_ s: String, _ size: Int) -> [String] {
        guard s.count > size else { return [s] }
        var out: [String] = [], rest = Substring(s)
        while !rest.isEmpty { out.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
        return out
    }

    private static func paragraphs(_ text: String) -> [LegalChunk] {
        var out: [LegalChunk] = [], buf = ""
        func push() { let t = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(LegalChunk(dieu: "Đoạn \(out.count + 1)", khoan: "", heading: "", text: t)) }; buf = "" }
        for para in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            for piece in slices(String(para), chunkMax) {
                if !buf.isEmpty && buf.count + piece.count > paragraphTarget { push() }
                buf += (buf.isEmpty ? "" : "\n") + piece
            }
        }
        push()
        return out
    }

    /// “15 tháng 6 năm 2020” hoặc “15/06/2020” → “2020-06-15”.
    static func vnDate(_ s: String) -> String? {
        let ns = s as NSString
        let a = try! NSRegularExpression(pattern: #"(\d{1,2})\s+tháng\s+(\d{1,2})\s+năm\s+((?:19|20)\d{2})"#, options: .caseInsensitive)
        let b = try! NSRegularExpression(pattern: #"(\d{1,2})[/.-](\d{1,2})[/.-]((?:19|20)\d{2})"#)
        guard let m = a.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) ?? b.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let d = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))), (1...31).contains(d), (1...12).contains(mo) else { return nil }
        return String(format: "%@-%02d-%02d", ns.substring(with: m.range(at: 3)), mo, d)
    }

    /// Dữ kiện rõ ràng ngay trong chữ: số hiệu, ngày ban hành, ngày hiệu lực, văn bản bị thay thế / bãi bỏ / sửa đổi. Không suy đoán.
    static func facts(_ text: String) -> DocFacts {
        let head = String(text.prefix(4000))
        var f = DocFacts()
        f.no = citations(String(head.prefix(1200))).first?.no
        let issued = try! NSRegularExpression(pattern: #"(?:ngày|Hà Nội,|Hồ Chí Minh,|TP\.?\s*[^,\n]{2,20},)\s*(?:ngày\s*)?(\d{1,2}\s+tháng\s+\d{1,2}\s+năm\s+(?:19|20)\d{2})"#, options: .caseInsensitive)
        let hns = head as NSString
        if let m = issued.firstMatch(in: head, range: NSRange(location: 0, length: hns.length)) { f.issuedAt = vnDate(hns.substring(with: m.range(at: 1))) }
        let eff = try! NSRegularExpression(pattern: #"(?:có\s+hiệu\s+lực(?:\s+thi\s+hành)?\s+(?:kể\s+)?từ\s+ngày|có\s+hiệu\s+lực\s+từ\s+ngày)\s+([^.;\n]{4,40})"#, options: .caseInsensitive)
        let ns = text as NSString
        if let m = eff.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) { f.effectiveAt = vnDate(ns.substring(with: m.range(at: 1))) }
        // Chỉ coi là thay thế/bãi bỏ TOÀN BỘ khi động từ đứng ngay trước loại văn bản + số hiệu.
        // “thay thế khoản 2 Điều 5 của Nghị định X” chỉ là sửa đổi một phần: X vẫn còn hiệu lực.
        let partial = try! NSRegularExpression(pattern: "(điều|khoản|điểm|mục|chương|phụ lục|một số|quy định)", options: .caseInsensitive)
        func scan(_ verb: String, whole: WritableKeyPath<DocFacts, [String]>, part: WritableKeyPath<DocFacts, [String]>) {
            let re = try! NSRegularExpression(pattern: "(?:\(verb))([^.;\\n]{0,160})", options: .caseInsensitive)
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let rest = ns.substring(with: m.range(at: 1))
                guard let c = citations(rest).first else { continue }
                let between = (rest as NSString).substring(to: min(c.index, (rest as NSString).length))
                let isPartial = partial.firstMatch(in: between, range: NSRange(location: 0, length: (between as NSString).length)) != nil
                let target = isPartial ? part : whole
                if !f[keyPath: target].contains(c.no) { f[keyPath: target].append(c.no) }
            }
        }
        scan(#"thay\s+thế"#, whole: \.replaces, part: \.amends)
        scan(#"bãi\s+bỏ"#, whole: \.repeals, part: \.amends)
        scan(#"sửa\s+đổi(?:,\s*bổ\s+sung)?|bổ\s+sung"#, whole: \.amends, part: \.amends)
        if let no = f.no {   // một văn bản không tự thay thế chính nó
            let k = noKey(no)
            f.replaces.removeAll { noKey($0) == k }; f.repeals.removeAll { noKey($0) == k }; f.amends.removeAll { noKey($0) == k }
        }
        return f
    }
}
