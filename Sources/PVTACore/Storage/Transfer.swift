import Foundation

extension DataStore {
    /// Xuất toàn bộ dữ liệu (thứ tự cố định để hai lần xuất giống nhau thì giống từng byte).
    public func exportData() throws -> ExportBundle {
        let chats = try db.query("SELECT \(Self.chatColumns) FROM chats ORDER BY createdAt, id", [], Self.chat)
        var settings: [String: String] = [:]
        for (k, v) in try db.query("SELECT key, value FROM settings", [], { ($0.text(0), $0.text(1)) }) { settings[k] = v }
        return ExportBundle(
            format: ExportBundle.currentFormat,
            projects: try projects(),
            chats: try chats.map { .init(chat: $0, messages: try messages(chatId: $0.id)) },
            settings: settings)
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(exportData())
    }

    /// Nhập dữ liệu. Mặc định gộp theo mã (nhập lại nhiều lần không tạo bản trùng);
    /// `replace` xóa dữ liệu hiện có trước. Lỗi thì dữ liệu hiện có giữ nguyên.
    public func importData(_ json: Data, replace: Bool = false) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let bundle: ExportBundle
        do { bundle = try decoder.decode(ExportBundle.self, from: json) } catch {
            throw PVTAError("Tệp dữ liệu không đúng định dạng của PVTA nên không nhập được.")
        }
        try apply(bundle, replace: replace)
    }

    private func apply(_ bundle: ExportBundle, replace: Bool) throws {
        guard bundle.format == ExportBundle.currentFormat else {
            throw PVTAError("Tệp dữ liệu này có định dạng không được hỗ trợ (có thể do bản PVTA khác tạo ra).")
        }
        do {
            try db.transaction {
                if replace {
                    try db.run("DELETE FROM chats")
                    try db.run("DELETE FROM projects")
                    try db.run("DELETE FROM settings")
                }
                for p in bundle.projects { try insert(p) }
                for entry in bundle.chats {
                    try insert(entry.chat)
                    try db.run("DELETE FROM messages WHERE chatId = ?", [.text(entry.chat.id)])
                    for m in entry.messages { try insertMessage(chatId: entry.chat.id, m) }
                }
                for (k, v) in bundle.settings {
                    try db.run("INSERT INTO settings(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               [.text(k), .text(v)])
                }
            }
        } catch is PVTAError {
            throw PVTAError("Dữ liệu nhập không hợp lệ (ví dụ hội thoại trỏ tới dự án không có trong tệp). Dữ liệu hiện tại được giữ nguyên.")
        }
    }

    /// Tạo bản sao lưu: một tệp SQLite độc lập, nhất quán.
    public func exportRecovery(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw PVTAError("Đã có tệp \(url.lastPathComponent) ở nơi này. Hãy chọn tên khác để không ghi đè bản sao lưu cũ.")
        }
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try db.exec("VACUUM INTO '\(escaped)'")
    }

    /// Khôi phục từ bản sao lưu: thay toàn bộ dữ liệu hiện tại. Bản sao lưu cũ được nâng cấp cấu trúc trước khi nhập.
    public func restore(from url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PVTAError("Không tìm thấy tệp sao lưu \(url.lastPathComponent).")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-restore-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temp.path + suffix) }
        }
        do { try FileManager.default.copyItem(at: url, to: temp) } catch {
            throw PVTAError("Không đọc được tệp sao lưu \(url.lastPathComponent).")
        }
        let backup = try DataStore(file: temp)
        let bundle = try await backup.exportData()
        try apply(bundle, replace: true)
    }
}
