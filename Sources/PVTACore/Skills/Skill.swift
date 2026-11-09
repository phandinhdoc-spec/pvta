import Foundation
import CryptoKit

/// Cách nạp skill: always = luôn đưa nội dung vào ngữ cảnh; demand = chỉ liệt kê tên và mô tả, model đọc khi cần;
/// manual = chỉ nạp khi thầy cô gõ /tên; off = tắt.
public enum LoadMode: String, Codable, Sendable, CaseIterable { case always, demand, manual, off }

/// Nguồn gốc của skill (quyết định bởi bản ghi cài đặt, không tin phần đầu SKILL.md).
public enum SkillTier: String, Codable, Sendable {
    case system     // đi kèm PVTA
    case learned    // PVTA tự học, đã duyệt (tiền tố learned-)
    case github     // cài từ GitHub
    case imported   // cài từ thư mục
    case pack       // thuộc gói nhóm
    case own        // thầy cô tự viết
}

public struct Skill: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var load: LoadMode
    public var groups: [String]
    public var body: String
    public var tier: SkillTier
    public var source: String?
    public var enabled: Bool
    /// Mã bản hiện tại của tệp SKILL.md (dùng để chống ghi đè thay đổi mới hơn).
    public var revision: String
}

public struct SkillIssue: Codable, Sendable, Equatable {
    public var level: String      // "error" | "warn"
    public var message: String
}

enum SkillText {
    static let nameRegex = "^[a-z0-9][a-z0-9-]{0,63}$"
    static let reserved = ["pvta-", "learned-", "cd-"]
    static let maxName = 40, maxDescription = 220, maxBody = 20_000
    /// Bảy mục của khuôn skill, đúng thứ tự.
    static let template = ["Khi nào dùng", "Khi nào không dùng", "Quy định", "Quy trình", "Danh sách kiểm tra", "Tài liệu tham chiếu", "Kiểm tra bàn giao"]

    static func revision(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    struct Parsed { var meta: [String: String]; var body: String; var hasHead: Bool }

    static func parse(_ md: String) -> Parsed {
        let text = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) ?? (text.hasSuffix("\n---") ? text.range(of: "\n---", options: .backwards) : nil) else {
            return Parsed(meta: [:], body: text.trimmingCharacters(in: .whitespacesAndNewlines), hasHead: false)
        }
        let head = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var meta: [String: String] = [:]
        for line in head.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key.range(of: "^[a-z_-]+$", options: .regularExpression) != nil else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            meta[key] = value
        }
        return Parsed(meta: meta, body: String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), hasHead: true)
    }

    static func groups(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { $0.range(of: nameRegex, options: .regularExpression) != nil }
    }

    /// Rút mô tả về tối đa 220 ký tự ở ranh giới câu hoặc từ.
    static func fitDescription(_ raw: String) -> String {
        let one = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard one.count > maxDescription else { return one }
        let cut = String(one.prefix(maxDescription))
        if let r = cut.range(of: ". ", options: .backwards), cut.distance(from: cut.startIndex, to: r.lowerBound) >= maxDescription * 6 / 10 { return String(cut[..<r.lowerBound]) + "." }
        if let r = cut.range(of: " ", options: .backwards) { return String(cut[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–-")) }
        return cut
    }

    static func compose(name: String, description: String, load: LoadMode, groups: [String], body: String) -> String {
        var head = "---\nname: \(name)\ndescription: \(description.replacingOccurrences(of: "\n", with: " "))\nload: \(load.rawValue)\n"
        if !groups.isEmpty { head += "groups: \(groups.joined(separator: ", "))\n" }
        return head + "---\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Kiểm tra an toàn

    /// Lý do không an toàn, hoặc nil. Chặn đường tiêm lệnh: khối công cụ, câu bảo bỏ qua chỉ dẫn, lệnh shell, khóa bí mật.
    static func unsafeReason(_ text: String, allowURLs: Bool) -> String? {
        let rules: [(String, String)] = [
            (#"```\s*pvta-tool"#, "chứa khối công cụ pvta-tool"),
            (#"(?i)ignore (all |any )?(the )?(previous|prior|above) (instructions|rules)"#, "có câu tìm cách bỏ qua chỉ dẫn"),
            (#"(?i)b[oỏ] qua (m[oọ]i |t[aấ]t c[aả] )?(ch[iỉ] d[aẫ]n|h[uư][oớ]ng d[aẫ]n|quy t[aắ]c)"#, "có câu tìm cách bỏ qua chỉ dẫn"),
            (#"(?i)\b(rm\s+-rf|curl\s|wget\s|sudo\s|Invoke-WebRequest|powershell\b|chmod\s)"#, "chứa lệnh shell"),
            (#"(sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|ghp_[A-Za-z0-9]{20,})"#, "giống khóa bí mật"),
            (#"(?i)\.ssh|id_rsa|/etc/passwd"#, "nhắc đến tệp nhạy cảm"),
        ]
        for (pattern, why) in rules where text.range(of: pattern, options: .regularExpression) != nil { return why }
        if !allowURLs {
            // Đường dẫn web chỉ được nằm trong phần “(Nguồn: …)”.
            let stripped = text.replacingOccurrences(of: #"\(Nguồn:[^)]*\)"#, with: "", options: .regularExpression)
            if stripped.range(of: #"(?i)https?://"#, options: .regularExpression) != nil { return "chứa đường dẫn web ngoài phần Nguồn" }
        }
        return nil
    }

    /// Kiểm tra chuẩn. `full` = skill thầy cô viết hoặc PVTA tự học (đủ khuôn, quy định có nguồn); ngược lại chỉ kiểm phần đầu, độ dài, an toàn.
    static func check(_ md: String, owner: String, full: Bool, directory: String? = nil) -> [SkillIssue] {
        var out: [SkillIssue] = []
        func err(_ m: String) { out.append(SkillIssue(level: "error", message: m)) }
        func warn(_ m: String) { out.append(SkillIssue(level: "warn", message: m)) }
        let p = parse(md)
        guard p.hasHead else { err("Thiếu phần đầu tệp (--- name, description, load ---)."); return out }
        let name = p.meta["name"] ?? ""
        if name.isEmpty { err("Thiếu tên (name) ở phần đầu.") }
        else if name.range(of: nameRegex, options: .regularExpression) == nil { err("Tên “\(name)” không hợp lệ: chỉ chữ thường không dấu, số và gạch nối, tối đa 64 ký tự.") }
        else {
            if name.count > maxName { err("Tên dài \(name.count) ký tự, tối đa \(maxName).") }
            if owner != "imported" && (name.contains("claude") || name.contains("anthropic")) { err("Tên không được chứa “claude” hoặc “anthropic”.") }
            if owner == "user", let r = reserved.first(where: { name.hasPrefix($0) }) { err("Tên không được bắt đầu bằng “\(r)” (dành cho skill hệ thống, tự học và nhóm).") }
            if let directory, directory != name { err("Tên “\(name)” khác tên thư mục “\(directory)”.") }
            if ["helper", "helpers", "tool", "tools", "utils", "misc", "data", "files", "skill"].contains(name) { warn("Tên quá chung chung, khó được chọn đúng lúc.") }
        }
        let desc = p.meta["description"] ?? ""
        if desc.isEmpty { err("Thiếu mô tả (description): mô tả giúp chọn đúng skill.") }
        else if desc.count > maxDescription {
            // Skill nhập từ nơi khác được rút gọn mô tả khi cài; skill thầy cô viết thì phải tự sửa.
            if owner == "imported" { warn("Mô tả dài \(desc.count) ký tự, sẽ được rút gọn còn \(maxDescription).") } else { err("Mô tả dài \(desc.count) ký tự, tối đa \(maxDescription).") }
        }
        if let l = p.meta["load"], LoadMode(rawValue: l) == nil { err("Chế độ nạp “\(l)” không hợp lệ (always, demand, manual, off).") }
        if p.body.isEmpty { err("Thân skill đang trống.") }
        if p.body.count > maxBody { err("Thân skill dài \(p.body.count) ký tự, tối đa \(maxBody).") }
        if let why = unsafeReason(md, allowURLs: !full) { err("Nội dung không an toàn: \(why).") }
        guard full else { return out }
        // Khuôn bảy mục và nguồn của quy định.
        let titles = p.body.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("## ") ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
        }
        let missing = template.filter { !titles.contains($0) }
        if !missing.isEmpty { warn("Thiếu mục: " + missing.joined(separator: ", ") + ".") }
        let present = titles.compactMap { template.firstIndex(of: $0) }
        if present != present.sorted() { warn("Các mục chưa đúng thứ tự khuôn: " + template.joined(separator: " → ") + ".") }
        if let rules = section("Quy định", in: p.body) {
            for line in rules.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("-") || line.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
                if line.range(of: #"\(Nguồn:\s*\S[^)]*\)\s*$"#, options: .regularExpression) == nil {
                    err("Dòng quy định chưa ghi nguồn “(Nguồn: …)”: " + String(line.trimmingCharacters(in: .whitespaces).prefix(70)))
                }
            }
        }
        return out
    }

    static func section(_ title: String, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## " + title }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n")
    }
}
