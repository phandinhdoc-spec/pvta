import Foundation

/// Kho dữ liệu của PVTA: hội thoại, dự án, cài đặt. SQLite (chế độ WAL) trong thư mục dữ liệu chung.
/// Lý do chọn SQLite thay vì SwiftData: nhiều tiến trình (CLI, Desktop) cùng truy cập an toàn,
/// migration viết tay rõ ràng, không phụ thuộc giao diện nên lõi dùng được ở dòng lệnh.
public actor DataStore {
    let db: SQLiteDB
    let now: @Sendable () -> Date

    public init(file: URL, migrations: [Migration] = Schema.all, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let db = try SQLiteDB(path: file.path)
        try Migrator.run(db, migrations)
        self.db = db
        self.now = now
    }

    public static func open(paths: DataPaths) throws -> DataStore {
        try paths.prepare()
        return try DataStore(file: paths.database)
    }

    public func schemaVersion() throws -> Int {
        try db.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(n))
    }

    static func chat(_ r: Row) -> Chat {
        Chat(id: r.text(0), title: r.text(1), projectId: r.optText(2), pinned: r.int(3) != 0,
             createdAt: Date(timeIntervalSince1970: r.double(4)), updatedAt: Date(timeIntervalSince1970: r.double(5)),
             model: r.optText(6))
    }

    static let chatColumns = "id, title, projectId, pinned, createdAt, updatedAt, model"

    // MARK: Hội thoại

    public func createChat(title: String = "Hội thoại mới", projectId: String? = nil) throws -> Chat {
        let t = Self.clip(title, 80)
        let at = now()
        let chat = Chat(id: UUID().uuidString, title: t.isEmpty ? "Hội thoại mới" : t, projectId: projectId,
                        pinned: false, createdAt: at, updatedAt: at)
        try insert(chat)
        return chat
    }

    public func chat(id: String) throws -> Chat? {
        try db.query("SELECT \(Self.chatColumns) FROM chats WHERE id = ?", [.text(id)], Self.chat).first
    }

    /// Hội thoại đã ghim lên đầu, sau đó mới nhất trước.
    /// Danh sách hội thoại của người dùng. Hội thoại riêng của Thư ký Sign không nằm trong danh sách này.
    public func chats() throws -> [Chat] {
        let secretary = try setting("secretary.thread")
        return try db.query("SELECT \(Self.chatColumns) FROM chats ORDER BY pinned DESC, updatedAt DESC, id", [], Self.chat).filter { $0.id != secretary }
    }

    public func renameChat(id: String, title: String) throws {
        let t = Self.clip(title, 80)
        guard !t.isEmpty else { throw PVTAError("Tên hội thoại không được để trống.") }
        try requireChanged(db.run("UPDATE chats SET title = ? WHERE id = ?", [.text(t), .text(id)]))
    }

    public func deleteChat(id: String) throws {
        try requireChanged(db.run("DELETE FROM chats WHERE id = ?", [.text(id)]))
    }

    public func setPinned(id: String, _ pinned: Bool) throws {
        try requireChanged(db.run("UPDATE chats SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(id)]))
    }

    /// Chuyển hội thoại vào dự án; `nil` là bỏ khỏi dự án.
    public func moveChat(id: String, toProject projectId: String?) throws {
        if let projectId, try db.query("SELECT 1 FROM projects WHERE id = ?", [.text(projectId)], { _ in 1 }).isEmpty {
            throw PVTAError("Không tìm thấy dự án đã chọn.")
        }
        try requireChanged(db.run("UPDATE chats SET projectId = ? WHERE id = ?",
                                  [projectId.map { .text($0) } ?? .null, .text(id)]))
    }

    @discardableResult
    public func appendMessage(chatId: String, role: MessageRole, text: String, model: String? = nil,
                              error: String? = nil, tools: JSONValue? = nil) throws -> Message {
        let message = Message(role: role, text: text, createdAt: now(), model: model, error: error, tools: tools)
        try db.transaction {
            try insertMessage(chatId: chatId, message)
            try db.run("UPDATE chats SET updatedAt = ? WHERE id = ?",
                       [.double(message.createdAt.timeIntervalSince1970), .text(chatId)])
        }
        return message
    }

    func insertMessage(chatId: String, _ m: Message) throws {
        let tools = try m.tools.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.run("INSERT INTO messages(chatId, role, text, createdAt, model, error, tools) VALUES(?,?,?,?,?,?,?)",
                   [.text(chatId), .text(m.role.rawValue), .text(m.text), .double(m.createdAt.timeIntervalSince1970),
                    m.model.map { .text($0) } ?? .null, m.error.map { .text($0) } ?? .null, tools.map { .text($0) } ?? .null])
    }

    public func messages(chatId: String) throws -> [Message] {
        try db.query("SELECT role, text, createdAt, model, error, tools FROM messages WHERE chatId = ? ORDER BY seq", [.text(chatId)]) {
            Message(role: MessageRole(rawValue: $0.text(0)) ?? .assistant, text: $0.text(1),
                    createdAt: Date(timeIntervalSince1970: $0.double(2)), model: $0.optText(3), error: $0.optText(4),
                    tools: $0.optText(5).flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) })
        }
    }

    // MARK: Dự án

    public func createProject(name: String) throws -> Project {
        let n = Self.clip(name, 40)
        guard !n.isEmpty else { throw PVTAError("Tên dự án không được để trống.") }
        let project = Project(id: UUID().uuidString, name: n, createdAt: now())
        try insert(project)
        return project
    }

    public func projects() throws -> [Project] {
        try db.query("SELECT id, name, createdAt FROM projects ORDER BY createdAt, id") {
            Project(id: $0.text(0), name: $0.text(1), createdAt: Date(timeIntervalSince1970: $0.double(2)))
        }
    }

    public func renameProject(id: String, name: String) throws {
        let n = Self.clip(name, 40)
        guard !n.isEmpty else { throw PVTAError("Tên dự án không được để trống.") }
        try requireChanged(db.run("UPDATE projects SET name = ? WHERE id = ?", [.text(n), .text(id)]))
    }

    /// Xóa dự án: hội thoại trong dự án được giữ lại, về "không thuộc dự án".
    public func deleteProject(id: String) throws {
        try requireChanged(db.run("DELETE FROM projects WHERE id = ?", [.text(id)]))
    }

    // MARK: Cài đặt

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first
    }

    // MARK: Dùng chung

    func requireChanged(_ changes: Int) throws {
        if changes == 0 { throw PVTAError("Không tìm thấy mục cần thao tác. Có thể nó đã bị xóa.") }
    }

    func insert(_ chat: Chat) throws {
        try db.run("""
            INSERT INTO chats(id, title, projectId, pinned, createdAt, updatedAt, model) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, projectId = excluded.projectId,
                pinned = excluded.pinned, createdAt = excluded.createdAt, updatedAt = excluded.updatedAt,
                model = excluded.model
            """,
            [.text(chat.id), .text(chat.title), chat.projectId.map { .text($0) } ?? .null,
             .int(chat.pinned ? 1 : 0), .double(chat.createdAt.timeIntervalSince1970),
             .double(chat.updatedAt.timeIntervalSince1970), chat.model.map { .text($0) } ?? .null])
    }

    func insert(_ project: Project) throws {
        try db.run("""
            INSERT INTO projects(id, name, createdAt) VALUES(?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, createdAt = excluded.createdAt
            """,
            [.text(project.id), .text(project.name), .double(project.createdAt.timeIntervalSince1970)])
    }
}

extension DataStore {
    /// Đánh dấu hội thoại vừa có thay đổi (đẩy lên đầu danh sách).
    func setUpdated(_ chatId: String) throws {
        try db.run("UPDATE chats SET updatedAt = ? WHERE id = ?", [.double(now().timeIntervalSince1970), .text(chatId)])
    }
}
