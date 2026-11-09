import Foundation

public struct QueuedPrompt: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    /// "queue": chạy sau khi lượt hiện tại xong. "steer": chen vào ở lần gọi model kế tiếp của lượt đang chạy.
    public var mode: String
    public var createdAt: Date
}

/// Trạng thái riêng của từng hội thoại: bản nháp ô soạn, tóm tắt, hàng đợi lời lệnh, model.
extension DataStore {
    static let draftLimit = 1_000_000
    static let queueLimit = 100
    static let promptLimit = 100_000

    private func requireChat(_ id: String) throws {
        if try db.query("SELECT 1 FROM chats WHERE id = ?", [.text(id)], { _ in 1 }).isEmpty {
            throw PVTAError("Không tìm thấy hội thoại. Có thể nó đã bị xóa.")
        }
    }

    // MARK: Model và bản nháp

    /// `nil` hoặc "auto" = Tự động.
    public func setChatModel(id: String, _ model: String?) throws {
        let value = model == nil || model == "auto" ? nil : model
        try requireChanged(db.run("UPDATE chats SET model = ? WHERE id = ?", [value.map { .text($0) } ?? .null, .text(id)]))
    }

    public func draft(chatId: String) throws -> String {
        try requireChat(chatId)
        return try db.query("SELECT draft FROM chats WHERE id = ?", [.text(chatId)]) { $0.optText(0) ?? "" }.first ?? ""
    }

    /// Bản nháp chưa gửi của ô soạn; để trống thì xóa.
    public func saveDraft(chatId: String, _ text: String) throws {
        guard text.count <= Self.draftLimit else { throw PVTAError("Bản nháp vượt quá 1 triệu ký tự. Hãy chia nhỏ nội dung.") }
        try requireChanged(db.run("UPDATE chats SET draft = ? WHERE id = ?",
                                  [text.isEmpty ? .null : .text(text), .text(chatId)]))
    }

    // MARK: Tóm tắt

    /// Tóm tắt phần đầu hội thoại và số tin nhắn (tính từ đầu) mà nó đã thay thế.
    public func summary(chatId: String) throws -> (text: String, covered: Int) {
        try requireChat(chatId)
        return try db.query("SELECT summary, summaryCovered FROM chats WHERE id = ?", [.text(chatId)]) {
            ($0.optText(0) ?? "", Int($0.int(1)))
        }.first ?? ("", 0)
    }

    public func setSummary(chatId: String, _ text: String, covered: Int) throws {
        try requireChanged(db.run("UPDATE chats SET summary = ?, summaryCovered = ? WHERE id = ?",
                                  [text.isEmpty ? .null : .text(text), .int(Int64(covered)), .text(chatId)]))
    }

    // MARK: Hàng đợi

    public func queuePaused(chatId: String) throws -> Bool {
        try db.query("SELECT queuePaused FROM chats WHERE id = ?", [.text(chatId)]) { $0.int(0) != 0 }.first ?? false
    }

    public func setQueuePaused(chatId: String, _ paused: Bool) throws {
        try db.run("UPDATE chats SET queuePaused = ? WHERE id = ?", [.int(paused ? 1 : 0), .text(chatId)])
    }

    private static func queued(_ r: Row) -> QueuedPrompt {
        QueuedPrompt(id: r.text(0), text: r.text(1), mode: r.text(2), createdAt: Date(timeIntervalSince1970: r.double(3)))
    }

    public func queue(chatId: String) throws -> [QueuedPrompt] {
        try db.query("SELECT id, text, mode, createdAt FROM queued_prompts WHERE chatId = ? ORDER BY pos", [.text(chatId)], Self.queued)
    }

    public func enqueue(chatId: String, text: String, mode: String) throws -> QueuedPrompt {
        try requireChat(chatId)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw PVTAError("Nhập nội dung trước.") }
        guard t.count <= Self.promptLimit else { throw PVTAError("Lời lệnh quá dài; hãy chia nhỏ nội dung.") }
        guard mode == "queue" || mode == "steer" else { throw PVTAError("Chọn Xếp hàng hoặc Chen ngang.") }
        return try db.transaction {
            let count = try db.query("SELECT COUNT(*) FROM queued_prompts WHERE chatId = ?", [.text(chatId)]) { Int($0.int(0)) }.first ?? 0
            guard count < Self.queueLimit else { throw PVTAError("Hàng đợi đã đầy. Hãy chờ gửi bớt lời lệnh.") }
            let item = QueuedPrompt(id: UUID().uuidString, text: t, mode: mode, createdAt: now())
            let pos = try db.query("SELECT COALESCE(MAX(pos), 0) + 1 FROM queued_prompts WHERE chatId = ?", [.text(chatId)]) { $0.int(0) }.first ?? 1
            try db.run("INSERT INTO queued_prompts(id, chatId, pos, text, mode, createdAt) VALUES(?,?,?,?,?,?)",
                       [.text(item.id), .text(chatId), .int(pos), .text(item.text), .text(item.mode), .double(item.createdAt.timeIntervalSince1970)])
            return item
        }
    }

    /// Dời lên/xuống, xóa hoặc sửa nội dung một lời lệnh đang chờ (chỉ dùng mã nên cửa sổ cũ không làm lệch hàng đợi của cửa sổ khác).
    public func changeQueued(chatId: String, id: String, action: String, text: String? = nil) throws {
        try db.transaction {
            let items = try db.query("SELECT id, pos FROM queued_prompts WHERE chatId = ? ORDER BY pos", [.text(chatId)]) { ($0.text(0), $0.int(1)) }
            guard let i = items.firstIndex(where: { $0.0 == id }) else {
                throw PVTAError("Lời lệnh đã được gửi hoặc không còn trong hàng đợi.")
            }
            switch action {
            case "remove":
                try db.run("DELETE FROM queued_prompts WHERE id = ?", [.text(id)])
            case "up", "down":
                let j = i + (action == "up" ? -1 : 1)
                guard items.indices.contains(j) else { return }
                try db.run("UPDATE queued_prompts SET pos = ? WHERE id = ?", [.int(items[j].1), .text(items[i].0)])
                try db.run("UPDATE queued_prompts SET pos = ? WHERE id = ?", [.int(items[i].1), .text(items[j].0)])
            case "edit":
                let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { throw PVTAError("Nhập nội dung trước.") }
                guard t.count <= Self.promptLimit else { throw PVTAError("Lời lệnh quá dài; hãy chia nhỏ nội dung.") }
                try db.run("UPDATE queued_prompts SET text = ? WHERE id = ?", [.text(t), .text(id)])
            default:
                throw PVTAError("Thao tác hàng đợi không hợp lệ.")
            }
        }
    }

    /// Lấy và xóa lời lệnh đầu hàng (kể cả lời "chen ngang" chưa kịp dùng vì lượt đã xong).
    public func dequeueNext(chatId: String) throws -> QueuedPrompt? {
        try db.transaction {
            guard let item = try db.query("SELECT id, text, mode, createdAt FROM queued_prompts WHERE chatId = ? ORDER BY pos LIMIT 1",
                                          [.text(chatId)], Self.queued).first else { return nil }
            try db.run("DELETE FROM queued_prompts WHERE id = ?", [.text(item.id)])
            return item
        }
    }

    /// Lấy và xóa mọi lời lệnh "chen ngang" (chỉ dùng ở ranh giới giữa hai lần gọi model).
    public func takeSteering(chatId: String) throws -> [QueuedPrompt] {
        try db.transaction {
            let items = try db.query("SELECT id, text, mode, createdAt FROM queued_prompts WHERE chatId = ? AND mode = 'steer' ORDER BY pos",
                                     [.text(chatId)], Self.queued)
            try db.run("DELETE FROM queued_prompts WHERE chatId = ? AND mode = 'steer'", [.text(chatId)])
            return items
        }
    }
}
