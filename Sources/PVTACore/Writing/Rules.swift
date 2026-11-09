import Foundation

public struct Rule: Codable, Sendable, Equatable {
    public var id: String
    /// "profile" (mọi hội thoại), "project" (một dự án), "chat" (một hội thoại)
    public var scope: String
    public var scopeId: String
    /// Khóa gọi bằng `#khóa`: chữ thường không dấu, nối bằng gạch ngang.
    public var key: String
    public var title: String
    public var text: String
    /// Luôn áp dụng, không cần gọi.
    public var always: Bool
    public var updatedAt: Date
}

enum RuleLimits {
    static let count = 100, text = 20_000, title = 80
}

enum RuleText {
    /// Khóa gọi quy tắc từ tiêu đề: bỏ dấu, chữ thường, nối bằng gạch ngang, tối đa 36 ký tự.
    static func key(_ title: String) -> String {
        let folded = Fold.text(title)
        let slug = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let cut = String(slug.prefix(36)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "quy-tac" : cut
    }

    private static let token = try! NSRegularExpression(pattern: #"(?:^|[\s(])#([a-z0-9][a-z0-9-]{0,39})(?=$|[\s.,;:!?)])"#)

    /// Các khóa được gọi bằng `#khóa` trong chữ của người dùng.
    static func invokedKeys(_ text: String) -> Set<String> {
        let ns = text as NSString
        return Set(token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Phần đưa vào lời nhắc: quy tắc luôn áp dụng và quy tắc được gọi. Cùng khóa ở nhiều phạm vi thì phạm vi hẹp hơn thắng.
    static func section(_ rules: [Rule], userText: String) -> String {
        let order = ["chat": 0, "project": 1, "profile": 2]
        var byKey: [String: Rule] = [:]
        for r in rules.sorted(by: { order[$0.scope, default: 3] > order[$1.scope, default: 3] }) { byKey[r.key] = r }   // hẹp nhất ghi sau cùng
        let invoked = invokedKeys(userText)
        let all = byKey.values.sorted { $0.key < $1.key }
        func lines(_ rs: [Rule]) -> String { rs.map { "- [#\($0.key)] \($0.title): \($0.text)" }.joined(separator: "\n") }
        var parts: [String] = []
        let always = all.filter(\.always)
        if !always.isEmpty { parts.append("QUY TẮC LUÔN ÁP DỤNG (của giáo viên, không trái với quy tắc an toàn của PVTA):\n" + lines(always)) }
        let called = all.filter { !$0.always && invoked.contains($0.key) }
        if !called.isEmpty { parts.append("QUY TẮC GIÁO VIÊN GỌI TRONG YÊU CẦU:\n" + lines(called)) }
        return parts.joined(separator: "\n")
    }
}

extension DataStore {
    private static func rule(_ r: Row) -> Rule {
        Rule(id: r.text(0), scope: r.text(1), scopeId: r.text(2), key: r.text(3), title: r.text(4), text: r.text(5), always: r.int(6) != 0,
             updatedAt: Date(timeIntervalSince1970: r.double(7)))
    }

    private static let ruleColumns = "id, scope, scopeId, key, title, text, always, updatedAt"

    public func rules(scope: String? = nil, scopeId: String? = nil) throws -> [Rule] {
        try db.query("""
            SELECT \(Self.ruleColumns) FROM rules WHERE (? IS NULL OR scope = ?) AND (? IS NULL OR scopeId = ?) ORDER BY scope, key
            """, [scope.map { .text($0) } ?? .null, scope.map { .text($0) } ?? .null, scopeId.map { .text($0) } ?? .null, scopeId.map { .text($0) } ?? .null], Self.rule)
    }

    /// Mọi quy tắc áp dụng cho một hội thoại: cá nhân, của dự án chứa nó, của chính nó.
    func rulesApplying(chatId: String?) throws -> [Rule] {
        var out = try rules(scope: "profile")
        if let chatId {
            if let project = try chat(id: chatId)?.projectId { out += try rules(scope: "project", scopeId: project) }
            out += try rules(scope: "chat", scopeId: chatId)
        }
        return out
    }

    /// Tạo hoặc sửa quy tắc. Khóa giữ nguyên khi sửa để các tin cũ vẫn đúng.
    public func saveRule(id: String?, scope: String = "profile", scopeId: String = "", title: String, text: String, always: Bool) throws -> Rule {
        guard ["profile", "project", "chat"].contains(scope) else { throw PVTAError("Phạm vi quy tắc không hợp lệ (profile, project hoặc chat).") }
        if scope == "profile", !scopeId.isEmpty { throw PVTAError("Quy tắc cá nhân không có mã phạm vi.") }
        if scope == "chat", try chat(id: scopeId) == nil { throw PVTAError("Không tìm thấy hội thoại của quy tắc.") }
        if scope == "project", try projects().first(where: { $0.id == scopeId }) == nil { throw PVTAError("Không tìm thấy dự án của quy tắc.") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw PVTAError("Hãy đặt tên cho quy tắc.") }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PVTAError("Nội dung quy tắc đang trống.") }
        guard body.count <= RuleLimits.text else { throw PVTAError("Quy tắc quá dài (tối đa 20.000 ký tự).") }
        return try db.transaction {
            let at = now()
            if let id, let old = try db.query("SELECT \(Self.ruleColumns) FROM rules WHERE id = ?", [.text(id)], Self.rule).first {
                try db.run("UPDATE rules SET title = ?, text = ?, always = ?, updatedAt = ? WHERE id = ?",
                           [.text(String(t.prefix(RuleLimits.title))), .text(body), .int(always ? 1 : 0), .double(at.timeIntervalSince1970), .text(id)])
                return try db.query("SELECT \(Self.ruleColumns) FROM rules WHERE id = ?", [.text(old.id)], Self.rule)[0]
            }
            let count = try db.query("SELECT COUNT(*) FROM rules WHERE scope = ? AND scopeId = ?", [.text(scope), .text(scopeId)], { Int($0.int(0)) }).first ?? 0
            guard count < RuleLimits.count else { throw PVTAError("Đã đủ \(RuleLimits.count) quy tắc ở phạm vi này; hãy xóa bớt.") }
            let taken = Set(try db.query("SELECT key FROM rules WHERE scope = ? AND scopeId = ?", [.text(scope), .text(scopeId)], { $0.text(0) }))
            let base = RuleText.key(t)
            var key = base, n = 2
            while taken.contains(key) { key = "\(base.prefix(36))-\(n)"; n += 1 }
            let r = Rule(id: UUID().uuidString, scope: scope, scopeId: scopeId, key: key, title: String(t.prefix(RuleLimits.title)), text: body,
                         always: always, updatedAt: at)
            try db.run("INSERT INTO rules(\(Self.ruleColumns)) VALUES(?,?,?,?,?,?,?,?)",
                       [.text(r.id), .text(scope), .text(scopeId), .text(key), .text(r.title), .text(body), .int(always ? 1 : 0), .double(at.timeIntervalSince1970)])
            return r
        }
    }

    public func deleteRule(id: String) throws {
        guard try db.run("DELETE FROM rules WHERE id = ?", [.text(id)]) > 0 else { throw PVTAError("Không tìm thấy quy tắc.") }
    }
}
