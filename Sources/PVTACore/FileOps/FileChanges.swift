import CryptoKit
import Foundation

enum FileHash {
    /// SHA-256 của tệp, đọc từng phần để không nạp cả tệp vào bộ nhớ.
    static func of(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Một thay đổi tệp do PVTA thực hiện, đủ thông tin để hoàn tác khi tệp chưa bị sửa bên ngoài.
public struct FileChange: Codable, Sendable, Equatable {
    public var id: String
    public var chatId: String?
    /// create, overwrite, edit, save, move, trash
    public var kind: String
    public var path: String
    /// Vị trí cũ (di chuyển, xóa).
    public var original: String?
    public var backup: String?
    public var trashPath: String?
    public var beforeHash: String?
    public var afterHash: String?
    public var detail: String?
    public var createdAt: Date
    public var undone: Bool
}

extension DataStore {
    private static let changeColumns = "id, chatId, kind, path, original, backup, trashPath, beforeHash, afterHash, detail, createdAt, undone"

    private static func change(_ r: Row) -> FileChange {
        FileChange(id: r.text(0), chatId: r.optText(1), kind: r.text(2), path: r.text(3), original: r.optText(4), backup: r.optText(5),
                   trashPath: r.optText(6), beforeHash: r.optText(7), afterHash: r.optText(8), detail: r.optText(9),
                   createdAt: Date(timeIntervalSince1970: r.double(10)), undone: r.int(11) != 0)
    }

    func recordChange(_ c: FileChange) throws {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        try db.run("INSERT INTO file_changes(\(Self.changeColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                   [.text(c.id), opt(c.chatId), .text(c.kind), .text(c.path), opt(c.original), opt(c.backup), opt(c.trashPath),
                    opt(c.beforeHash), opt(c.afterHash), opt(c.detail), .double(c.createdAt.timeIntervalSince1970), .int(c.undone ? 1 : 0)])
    }

    public func fileChanges(limit: Int = 50) throws -> [FileChange] {
        try db.query("SELECT \(Self.changeColumns) FROM file_changes ORDER BY createdAt DESC, rowid DESC LIMIT ?", [.int(Int64(limit))], Self.change)
    }

    public func fileChange(id: String) throws -> FileChange? {
        try db.query("SELECT \(Self.changeColumns) FROM file_changes WHERE id = ?", [.text(id)], Self.change).first
    }

    func markUndone(_ id: String) throws { try db.run("UPDATE file_changes SET undone = 1 WHERE id = ?", [.text(id)]) }

    /// Giữ 200 thay đổi mới nhất; trả về các tệp sao lưu của phần bị bỏ để dọn.
    func pruneFileChanges(keep: Int = 200) throws -> [String] {
        let old = try db.query("""
            SELECT id, backup FROM file_changes WHERE id NOT IN (SELECT id FROM file_changes ORDER BY createdAt DESC, rowid DESC LIMIT ?)
            """, [.int(Int64(keep))]) { ($0.text(0), $0.optText(1)) }
        for (id, _) in old { try db.run("DELETE FROM file_changes WHERE id = ?", [.text(id)]) }
        return old.compactMap(\.1)
    }

    public func outputDir(chatId: String) throws -> String? {
        try db.query("SELECT outputDir FROM chats WHERE id = ?", [.text(chatId)]) { $0.optText(0) }.first ?? nil
    }

    public func setOutputDir(chatId: String, _ dir: String?) throws {
        try requireChanged(db.run("UPDATE chats SET outputDir = ? WHERE id = ?", [dir.map { .text($0) } ?? .null, .text(chatId)]))
    }
}
