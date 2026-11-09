import Foundation

public enum LearnedKind: String, Codable, Sendable { case knowledge, skill }
public enum LearnedStatus: String, Codable, Sendable { case draft, approved }

public struct LearnedItem: Codable, Sendable, Equatable {
    public var id: String
    public var kind: LearnedKind
    public var title: String
    public var body: String
    /// Bản nháp (chưa duyệt) không bao giờ được nạp vào ngữ cảnh.
    public var status: LearnedStatus
    /// Chỉ có nghĩa khi đã duyệt: tắt thì không nạp nhưng vẫn giữ.
    public var enabled: Bool
    /// Nguồn để thầy cô xem: tên hội thoại hoặc tài liệu và đoạn trích nguyên văn làm bằng chứng.
    public var source: String
    /// "hoi-thoai" | "tai-lieu" | "van-ban-nhom" | "nhap" | "tay"
    public var origin: String
    /// Tên skill đã tạo khi duyệt một đề xuất skill.
    public var skillName: String?
    public var groups: [String] = []
    public var createdAt: Double
    public var updatedAt: Double
}

public struct AnswerRating: Codable, Sendable, Equatable {
    public var id: String
    public var chatId: String
    public var messageId: String
    public var rating: Int
    public var note: String
    public var createdAt: Double
    public var used: Bool
}

extension DataStore {
    private static func learned(_ r: Row) -> LearnedItem? { try? JSONDecoder().decode(LearnedItem.self, from: Data(r.text(0).utf8)) }

    /// Bản ghi lưu cả dạng JSON để thêm trường về sau không cần đổi bảng; các cột còn lại phục vụ lọc.
    public func learnedItems(status: LearnedStatus? = nil, kind: LearnedKind? = nil) throws -> [LearnedItem] {
        let rows = try db.query("""
            SELECT body FROM learned WHERE (? IS NULL OR status = ?) AND (? IS NULL OR kind = ?) ORDER BY updatedAt DESC, id
            """, [status.map { .text($0.rawValue) } ?? .null, status.map { .text($0.rawValue) } ?? .null, kind.map { .text($0.rawValue) } ?? .null, kind.map { .text($0.rawValue) } ?? .null], Self.learned)
        return rows.compactMap { $0 }
    }

    public func learnedItem(id: String) throws -> LearnedItem? {
        try db.query("SELECT body FROM learned WHERE id = ?", [.text(id)], Self.learned).first.flatMap { $0 }
    }

    func saveLearned(_ i: LearnedItem) throws {
        let json = String(decoding: try JSONEncoder().encode(i), as: UTF8.self)
        try db.run("""
            INSERT INTO learned(id, kind, title, body, status, enabled, source, origin, skillName, createdAt, updatedAt) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, title = excluded.title, body = excluded.body, status = excluded.status, enabled = excluded.enabled,
                source = excluded.source, origin = excluded.origin, skillName = excluded.skillName, updatedAt = excluded.updatedAt
            """, [.text(i.id), .text(i.kind.rawValue), .text(i.title), .text(json), .text(i.status.rawValue), .int(i.enabled ? 1 : 0), .text(i.source), .text(i.origin),
                  i.skillName.map { .text($0) } ?? .null, .double(i.createdAt), .double(i.updatedAt)])
    }

    func deleteLearned(id: String) throws { try db.run("DELETE FROM learned WHERE id = ?", [.text(id)]) }

    func addLearnedHistory(_ i: LearnedItem) throws {
        try db.run("INSERT INTO learned_history(id, learnedId, snapshot, createdAt) VALUES(?,?,?,?)",
                   [.text(UUID().uuidString), .text(i.id), .text(String(decoding: try JSONEncoder().encode(i), as: UTF8.self)), .double(Date().timeIntervalSince1970)])
        try db.run("""
            DELETE FROM learned_history WHERE learnedId = ? AND id NOT IN
              (SELECT id FROM learned_history WHERE learnedId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 20)
            """, [.text(i.id), .text(i.id)])
    }

    public func learnedHistory(id: String) throws -> [(id: String, item: LearnedItem, at: Double)] {
        try db.query("SELECT id, snapshot, createdAt FROM learned_history WHERE learnedId = ? ORDER BY createdAt DESC, rowid DESC", [.text(id)]) { r in
            (try? JSONDecoder().decode(LearnedItem.self, from: Data(r.text(1).utf8))).map { (r.text(0), $0, r.double(2)) }
        }.compactMap { $0 }
    }

    // MARK: Đánh giá câu trả lời

    func saveRating(_ r: AnswerRating) throws {
        try db.run("""
            INSERT INTO answer_ratings(id, chatId, messageId, rating, note, createdAt, used) VALUES(?,?,?,?,?,?,0)
            ON CONFLICT(messageId) DO UPDATE SET rating = excluded.rating, note = excluded.note, createdAt = excluded.createdAt, used = 0
            """, [.text(r.id), .text(r.chatId), .text(r.messageId), .int(Int64(r.rating)), .text(r.note), .double(r.createdAt)])
    }

    func deleteRating(messageId: String) throws { try db.run("DELETE FROM answer_ratings WHERE messageId = ?", [.text(messageId)]) }

    public func ratings(chatId: String? = nil, unusedOnly: Bool = false) throws -> [AnswerRating] {
        try db.query("""
            SELECT id, chatId, messageId, rating, note, createdAt, used FROM answer_ratings
            WHERE (? IS NULL OR chatId = ?) AND (? = 0 OR used = 0) ORDER BY createdAt
            """, [chatId.map { .text($0) } ?? .null, chatId.map { .text($0) } ?? .null, .int(unusedOnly ? 1 : 0)]) { r in
            AnswerRating(id: r.text(0), chatId: r.text(1), messageId: r.text(2), rating: Int(r.int(3)), note: r.text(4), createdAt: r.double(5), used: r.int(6) != 0)
        }
    }

    func markRatingsUsed(_ ids: [String]) throws { for id in ids { try db.run("UPDATE answer_ratings SET used = 1 WHERE id = ?", [.text(id)]) } }
}
