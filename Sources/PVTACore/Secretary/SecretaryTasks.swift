import Foundation

extension DataStore {
    static let taskColumns = "id, assignedAt, content, deadline, done, completedAt, notes, progress, priority, metadata, revision, deletedAt"

    private static func task(_ r: Row) -> AssignedTask {
        let meta = (try? JSONSerialization.jsonObject(with: Data(r.text(9).utf8))) as? [String: Any] ?? [:]
        func m(_ k: String) -> String? { meta[k] as? String }
        return AssignedTask(id: Int(r.int(0)), assignedAt: r.text(1), content: r.text(2), deadline: r.optText(3), done: r.int(4) != 0, completedAt: r.optText(5), notes: r.optText(6),
                            progress: r.optText(7), priority: r.optText(8), preparationDate: m("preparationDate"), category: m("category"), sourceStatus: m("sourceStatus"),
                            sourceRef: m("sourceRef"), nextAction: m("nextAction"), schoolYear: m("schoolYear"), revision: Int(r.int(10)), deletedAt: r.optText(11))
    }

    func assignedTasks(trash: Bool = false) throws -> [AssignedTask] {
        try db.query("SELECT \(Self.taskColumns) FROM secretary_tasks WHERE deletedAt IS \(trash ? "NOT " : "")NULL ORDER BY id", [], Self.task)
    }

    func assignedTask(id: Int) throws -> AssignedTask? { try db.query("SELECT \(Self.taskColumns) FROM secretary_tasks WHERE id = ?", [.int(Int64(id))], Self.task).first }

    func insertAssigned(_ t: AssignedTask) throws -> Int {
        _ = try db.run("""
            INSERT INTO secretary_tasks(assignedAt, content, deadline, done, completedAt, notes, progress, priority, metadata) VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(t.assignedAt), .text(t.content), t.deadline.map { .text($0) } ?? .null, .int(t.done ? 1 : 0), t.completedAt.map { .text($0) } ?? .null,
                  t.notes.map { .text($0) } ?? .null, t.progress.map { .text($0) } ?? .null, t.priority.map { .text($0) } ?? .null, .text(Self.metadataJSON(t))])
        return try db.query("SELECT last_insert_rowid()", [], { Int($0.int(0)) }).first ?? 0
    }

    /// Cập nhật chỉ khi phiên bản khớp; trả false nếu đã đổi hoặc đã vào thùng rác.
    func updateAssigned(_ t: AssignedTask, expectedRevision: Int) throws -> Bool {
        try db.run("""
            UPDATE secretary_tasks SET assignedAt = ?, content = ?, deadline = ?, done = ?, completedAt = ?, notes = ?, progress = ?, priority = ?, metadata = ?, revision = revision + 1
            WHERE id = ? AND revision = ? AND deletedAt IS NULL
            """, [.text(t.assignedAt), .text(t.content), t.deadline.map { .text($0) } ?? .null, .int(t.done ? 1 : 0), t.completedAt.map { .text($0) } ?? .null,
                  t.notes.map { .text($0) } ?? .null, t.progress.map { .text($0) } ?? .null, t.priority.map { .text($0) } ?? .null, .text(Self.metadataJSON(t)),
                  .int(Int64(t.id)), .int(Int64(expectedRevision))]) == 1
    }

    func trashAssigned(id: Int, revision: Int, at: String) throws -> Bool {
        try db.run("UPDATE secretary_tasks SET deletedAt = ?, revision = revision + 1 WHERE id = ? AND revision = ? AND deletedAt IS NULL", [.text(at), .int(Int64(id)), .int(Int64(revision))]) == 1
    }

    func restoreAssigned(id: Int, revision: Int) throws -> Bool {
        try db.run("UPDATE secretary_tasks SET deletedAt = NULL, revision = revision + 1 WHERE id = ? AND revision = ? AND deletedAt IS NOT NULL", [.int(Int64(id)), .int(Int64(revision))]) == 1
    }

    private static func metadataJSON(_ t: AssignedTask) -> String {
        var m: [String: String] = [:]
        if let v = t.preparationDate { m["preparationDate"] = v }
        if let v = t.category { m["category"] = v }
        if let v = t.sourceStatus { m["sourceStatus"] = v }
        if let v = t.sourceRef { m["sourceRef"] = v }
        if let v = t.nextAction { m["nextAction"] = v }
        if let v = t.schoolYear { m["schoolYear"] = v }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: m)) ?? Data("{}".utf8), as: UTF8.self)
    }

    // MARK: Thông báo

    func notices(unreadOnly: Bool = false) throws -> [SecretaryNotice] {
        try db.query("SELECT id, key, kind, title, body, at, read, dismissed FROM secretary_notices WHERE dismissed = 0 AND (? = 0 OR read = 0) ORDER BY at DESC, id", [.int(unreadOnly ? 1 : 0)]) {
            SecretaryNotice(id: $0.text(0), key: $0.text(1), kind: $0.text(2), title: $0.text(3), body: $0.text(4), at: $0.double(5), read: $0.int(6) != 0, dismissed: $0.int(7) != 0)
        }
    }

    /// Thêm thông báo nếu khóa chưa từng có (kể cả đã tắt), để một việc chỉ nhắc một lần cho mỗi mốc.
    func addNotice(_ n: SecretaryNotice) throws -> Bool {
        try db.run("INSERT OR IGNORE INTO secretary_notices(id, key, kind, title, body, at, read, dismissed) VALUES(?,?,?,?,?,?,0,0)",
                   [.text(n.id), .text(n.key), .text(n.kind), .text(n.title), .text(n.body), .double(n.at)]) == 1
    }

    func markNotices(ids: [String], read: Bool? = nil, dismissed: Bool? = nil) throws {
        for id in ids {
            if let read { try db.run("UPDATE secretary_notices SET read = ? WHERE id = ?", [.int(read ? 1 : 0), .text(id)]) }
            if let dismissed { try db.run("UPDATE secretary_notices SET dismissed = ? WHERE id = ?", [.int(dismissed ? 1 : 0), .text(id)]) }
        }
    }

    func pruneNotices(keep: Int = 500) throws {
        try db.run("DELETE FROM secretary_notices WHERE id NOT IN (SELECT id FROM secretary_notices ORDER BY at DESC LIMIT ?)", [.int(Int64(keep))])
    }
}
