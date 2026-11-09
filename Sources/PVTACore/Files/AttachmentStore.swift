import Foundation

public struct Attachment: Codable, Sendable, Equatable {
    public var id: String
    public var chatId: String
    /// "file" (đã trích chữ), "image", "folder" (thư mục nguồn để chọn tệp, không tự đọc).
    public var kind: String
    public var name: String
    /// Đường dẫn gốc trên máy.
    public var path: String?
    public var mime: String?
    public var bytes: Int
    public var chars: Int
    public var truncated: Bool
    /// Ảnh đã được gửi cho model chưa.
    public var sent: Bool
    public var addedAt: Date
}

extension DataStore {
    static let attachmentColumns = "id, chatId, kind, name, path, mime, bytes, chars, truncated, sent, addedAt"

    private static func attachment(_ r: Row) -> Attachment {
        Attachment(id: r.text(0), chatId: r.text(1), kind: r.text(2), name: r.text(3), path: r.optText(4), mime: r.optText(5),
                   bytes: Int(r.int(6)), chars: Int(r.int(7)), truncated: r.int(8) != 0, sent: r.int(9) != 0,
                   addedAt: Date(timeIntervalSince1970: r.double(10)))
    }

    public func attachments(chatId: String) throws -> [Attachment] {
        try db.query("SELECT \(Self.attachmentColumns) FROM attachments WHERE chatId = ? ORDER BY addedAt, id", [.text(chatId)], Self.attachment)
    }

    public func attachment(id: String) throws -> Attachment? {
        try db.query("SELECT \(Self.attachmentColumns) FROM attachments WHERE id = ?", [.text(id)], Self.attachment).first
    }

    /// Thêm một mục. Tệp hoặc ảnh cùng tên thì thay; thư mục cùng đường dẫn thì giữ bản cũ.
    /// Trả về các tệp đã lưu của mục bị thay (để dọn).
    func putAttachment(_ a: Attachment, stored: String?, text: String?) throws -> [String] {
        try db.transaction {
            var old: [String] = []
            let same = a.kind == "folder"
                ? try db.query("SELECT id, stored FROM attachments WHERE chatId = ? AND kind = 'folder' AND path = ?", [.text(a.chatId), a.path.map { .text($0) } ?? .null]) { ($0.text(0), $0.optText(1)) }
                : try db.query("SELECT id, stored FROM attachments WHERE chatId = ? AND kind != 'folder' AND name = ?", [.text(a.chatId), .text(a.name)]) { ($0.text(0), $0.optText(1)) }
            for (id, s) in same {
                try db.run("DELETE FROM attachments WHERE id = ?", [.text(id)])
                if let s { old.append(s) }
            }
            try db.run("""
                INSERT INTO attachments(id, chatId, kind, name, path, stored, mime, bytes, chars, truncated, text, sent, addedAt)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(a.id), .text(a.chatId), .text(a.kind), .text(a.name), a.path.map { .text($0) } ?? .null,
                      stored.map { .text($0) } ?? .null, a.mime.map { .text($0) } ?? .null, .int(Int64(a.bytes)), .int(Int64(a.chars)),
                      .int(a.truncated ? 1 : 0), text.map { .text($0) } ?? .null, .int(a.sent ? 1 : 0), .double(a.addedAt.timeIntervalSince1970)])
            return old
        }
    }

    /// Xóa mục đính kèm; trả về mục và tệp đã lưu của nó.
    func deleteAttachment(id: String) throws -> (Attachment, String?)? {
        guard let a = try attachment(id: id) else { return nil }
        let stored = try db.query("SELECT stored FROM attachments WHERE id = ?", [.text(id)]) { $0.optText(0) }.first ?? nil
        try db.run("DELETE FROM attachments WHERE id = ?", [.text(id)])
        return (a, stored)
    }

    func attachmentText(id: String) throws -> String? {
        try db.query("SELECT text FROM attachments WHERE id = ?", [.text(id)]) { $0.optText(0) }.first ?? nil
    }

    func attachmentStored(id: String) throws -> String? {
        try db.query("SELECT stored FROM attachments WHERE id = ?", [.text(id)]) { $0.optText(0) }.first ?? nil
    }

    func storedPaths(chatId: String) throws -> [String] {
        try db.query("SELECT stored FROM attachments WHERE chatId = ? AND stored IS NOT NULL", [.text(chatId)]) { $0.text(0) }
    }

    func markAttachmentsSent(_ ids: [String]) throws {
        for id in ids { try db.run("UPDATE attachments SET sent = 1 WHERE id = ?", [.text(id)]) }
    }
}
