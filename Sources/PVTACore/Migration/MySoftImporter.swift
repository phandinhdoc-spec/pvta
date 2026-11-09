import Foundation

// MARK: - Kết quả nhập

/// Tóm tắt kết quả sau khi nhập dữ liệu từ MySoft (phần mềm cũ).
public struct ImportResult: Codable, Sendable {
    public var chatsImported: Int = 0
    public var chatsSkipped: Int = 0
    public var messagesImported: Int = 0
    public var skillsImported: Int = 0
    public var skillsSkipped: Int = 0
    public var rulesImported: Int = 0
    public var rulesSkipped: Int = 0
    /// Mô tả những mục bị bỏ qua và lý do.
    public var skippedReasons: [String] = []
    /// `true` nếu dữ liệu đã được nhập từ trước (chạy lần 2 trở đi mà không có gì mới).
    public var alreadyDone: Bool = false
}

// MARK: - Cấu trúc JSON của MySoft

/// Index chính trong `chats.json` của MySoft.
private struct MySoftIndex: Decodable {
    struct ChatMeta: Decodable {
        var id: String
        var title: String?
        var host: String?
        var updatedAt: Double?   // milliseconds UNIX
    }
    var version: Int?
    var chats: [ChatMeta]
    var globalRules: [MySoftRule]?

    private enum CodingKeys: String, CodingKey { case version, chats, globalRules }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version    = try? c.decode(Int.self, forKey: .version)
        chats      = (try? c.decode([ChatMeta].self, forKey: .chats)) ?? []
        globalRules = try? c.decode([MySoftRule].self, forKey: .globalRules)
    }
}

/// Quy tắc trong MySoft (globalRules).
private struct MySoftRule: Decodable {
    var title: String?
    var text: String?
    var always: Bool?
}

/// Tin nhắn trong file `chats/{id}.json`.
private struct MySoftMessage: Decodable {
    var id: String?
    var role: String
    var text: String
    var createdAt: Double?   // milliseconds UNIX
}

// MARK: - Importer

/// Nhập dữ liệu từ MySoft (phần mềm cũ) vào kho dữ liệu PVTA.
/// Chỉ đọc từ `sourcePath` — không ghi đè, không xóa dữ liệu cũ.
public actor MySoftImporter {

    // Các tiền tố skill hệ thống của MySoft → bỏ qua
    private static let systemPrefixes = ["pvta-", "office-", "choice-model"]

    // MARK: Hàm chính

    /// Nhập dữ liệu từ thư mục MySoft vào `store` và `skillsDir`.
    /// - Parameters:
    ///   - sourcePath: Đường dẫn thư mục MySoft; mặc định `~/.phananh-office`.
    ///   - store: Kho dữ liệu PVTA đang mở.
    ///   - skillsDir: Thư mục skills của PVTA (DataPaths.home/skills).
    public func run(
        sourcePath: String = "~/.phananh-office",
        store: DataStore,
        skillsDir: URL
    ) async throws -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        let expanded = (sourcePath as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded, isDirectory: true)

        // Kiểm tra thư mục nguồn tồn tại
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw PVTAError("Không tìm thấy thư mục dữ liệu cũ tại \"\(expanded)\". Hãy kiểm tra lại đường dẫn.")
        }

        // Nhập từng phần
        try await importChats(root: root, store: store, result: &result)
        try await importSkills(root: root, skillsDir: skillsDir, result: &result)
        try await importRules(root: root, store: store, result: &result)

        // Ghi mốc thời gian hoàn tất
        let iso = ISO8601DateFormatter().string(from: Date())
        try await store.setSetting("legacy.import.at", iso)

        return result
    }

    // MARK: Nhập hội thoại

    private func importChats(root: URL, store: DataStore, result: inout ImportResult) async throws {
        let indexFile = root.appendingPathComponent("chats.json")
        guard let data = try? Data(contentsOf: indexFile) else {
            result.skippedReasons.append("Không đọc được chats.json — bỏ qua toàn bộ hội thoại.")
            return
        }
        let index: MySoftIndex
        do { index = try JSONDecoder().decode(MySoftIndex.self, from: data) }
        catch {
            result.skippedReasons.append("chats.json không đúng định dạng — bỏ qua toàn bộ hội thoại.")
            return
        }

        let chatsDir = root.appendingPathComponent("chats", isDirectory: true)

        for meta in index.chats {
            let settingKey = "legacy.mysoftId:\(meta.id)"

            // Chống nhập trùng
            if let _ = try? await store.setting(settingKey) {
                result.chatsSkipped += 1
                continue
            }

            // Đọc file tin nhắn
            let msgFile = chatsDir.appendingPathComponent("\(meta.id).json")
            guard let msgData = try? Data(contentsOf: msgFile) else {
                result.skippedReasons.append("Bỏ qua hội thoại \"\(meta.title ?? meta.id)\": không tìm thấy file tin nhắn chats/\(meta.id).json.")
                result.chatsSkipped += 1
                continue
            }

            let rawMessages: [MySoftMessage]
            do { rawMessages = try JSONDecoder().decode([MySoftMessage].self, from: msgData) }
            catch {
                result.skippedReasons.append("Bỏ qua hội thoại \"\(meta.title ?? meta.id)\": file tin nhắn không đúng định dạng.")
                result.chatsSkipped += 1
                continue
            }

            // Tạo hội thoại mới trong PVTA
            let title: String
            let rawTitle = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            title = rawTitle.isEmpty ? "Hội thoại cũ" : rawTitle

            let updatedAt = meta.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let newId = UUID().uuidString
            let chat = Chat(id: newId, title: title, projectId: nil, pinned: false,
                            createdAt: updatedAt, updatedAt: updatedAt)
            try await store.insert(chat)

            // Nhập tin nhắn
            var msgCount = 0
            var lastTime = updatedAt
            for (i, m) in rawMessages.enumerated() {
                let role: MessageRole = m.role == "user" ? .user : .assistant
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Mỗi tin cách nhau 1 giây để giữ thứ tự; dùng createdAt nếu có
                let at: Date
                if let ms = m.createdAt, ms > 0 {
                    at = Date(timeIntervalSince1970: ms / 1000)
                } else {
                    at = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970 - Double(rawMessages.count - i))
                }
                lastTime = at
                let msg = Message(role: role, text: text, createdAt: at)
                try await store.insertMessage(chatId: newId, msg)
                msgCount += 1
            }
            _ = lastTime

            // Ghi mapping để chống nhập trùng lần 2
            try await store.setSetting(settingKey, newId)
            result.chatsImported += 1
            result.messagesImported += msgCount
        }
    }

    // MARK: Nhập skill

    private func importSkills(root: URL, skillsDir: URL, result: inout ImportResult) async throws {
        let fm = FileManager.default
        let srcSkillsDir = root.appendingPathComponent("skills", isDirectory: true)
        guard fm.fileExists(atPath: srcSkillsDir.path) else {
            result.skippedReasons.append("Không tìm thấy thư mục skills/ trong dữ liệu cũ — bỏ qua toàn bộ skill.")
            return
        }

        // Danh sách skill đi kèm MySoft (bundled) — bỏ qua
        let bundledFile = srcSkillsDir.appendingPathComponent(".bundled.json")
        let bundled: Set<String>
        if let data = try? Data(contentsOf: bundledFile),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            bundled = Set(dict.keys)
        } else {
            bundled = []
        }

        // Danh sách skill đã được cài từ repo GitHub/import bên ngoài — bỏ qua
        let importedFile = srcSkillsDir.appendingPathComponent(".imported.json")
        let imported: Set<String>
        if let data = try? Data(contentsOf: importedFile),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            imported = Set(dict.keys)
        } else {
            imported = []
        }

        // Duyệt các thư mục skill
        let items = (try? fm.contentsOfDirectory(
            at: srcSkillsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for item in items {
            let name = item.lastPathComponent
            // Bỏ qua thư mục ẩn
            guard !name.hasPrefix(".") else { continue }
            // Chỉ thư mục
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            // Quyết định có nhập không
            let skipReason = shouldSkip(name: name, bundled: bundled, imported: imported)
            if let reason = skipReason {
                result.skippedReasons.append("Bỏ qua skill \"\(name)\": \(reason).")
                result.skillsSkipped += 1
                continue
            }

            // Kiểm tra SKILL.md tồn tại
            let srcMd = item.appendingPathComponent("SKILL.md")
            guard let mdText = try? String(contentsOf: srcMd, encoding: .utf8) else {
                result.skippedReasons.append("Bỏ qua skill \"\(name)\": không đọc được SKILL.md.")
                result.skillsSkipped += 1
                continue
            }

            // Kiểm tra chưa có trong PVTA
            let destDir = skillsDir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: destDir.path) {
                result.skippedReasons.append("Bỏ qua skill \"\(name)\": đã có skill cùng tên trong PVTA.")
                result.skillsSkipped += 1
                continue
            }

            // Tạo thư mục và chép SKILL.md
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let destMd = destDir.appendingPathComponent("SKILL.md")
            try Data(mdText.utf8).write(to: destMd, options: .withoutOverwriting)

            // Chép thêm các file văn bản nhỏ đi kèm (ngoài SKILL.md)
            let extras = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
            for f in extras {
                let ext = f.pathExtension.lowercased()
                guard f.lastPathComponent != "SKILL.md",
                      ["md", "txt", "json", "csv"].contains(ext),
                      let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true,
                      (v.fileSize ?? 0) <= 200_000 else { continue }
                try? fm.copyItem(at: f, to: destDir.appendingPathComponent(f.lastPathComponent))
            }

            result.skillsImported += 1
        }
    }

    /// Trả lý do bỏ qua, hoặc `nil` nếu nên nhập.
    private func shouldSkip(name: String, bundled: Set<String>, imported: Set<String>) -> String? {
        // Skill đi kèm MySoft (bundled)
        if bundled.contains(name) { return "skill đi kèm MySoft (không nhập, PVTA có phiên bản riêng)" }
        // Skill từ GitHub/import bên ngoài
        if imported.contains(name) { return "skill từ nguồn bên ngoài, hãy tự cài lại" }
        // Tiền tố hệ thống
        for prefix in Self.systemPrefixes {
            if name.hasPrefix(prefix) { return "skill hệ thống MySoft (tiền tố \"\(prefix)\")" }
        }
        return nil
    }

    // MARK: Nhập quy tắc

    private func importRules(root: URL, store: DataStore, result: inout ImportResult) async throws {
        let indexFile = root.appendingPathComponent("chats.json")
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? JSONDecoder().decode(MySoftIndex.self, from: data),
              let globalRules = index.globalRules, !globalRules.isEmpty else {
            // Không có quy tắc → không phải lỗi
            return
        }

        for raw in globalRules {
            guard let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let text  = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),  !text.isEmpty else {
                result.skippedReasons.append("Bỏ qua quy tắc không hợp lệ từ dữ liệu cũ (thiếu tiêu đề hoặc nội dung).")
                result.rulesSkipped += 1
                continue
            }

            // Chống trùng: check theo setting key
            let ruleKey = "legacy.rule:\(title)"
            if let _ = try? await store.setting(ruleKey) {
                result.rulesSkipped += 1
                continue
            }

            do {
                _ = try await store.saveRule(id: nil, scope: "profile", scopeId: "",
                                             title: title, text: text,
                                             always: raw.always ?? false)
                try await store.setSetting(ruleKey, "1")
                result.rulesImported += 1
            } catch {
                result.skippedReasons.append("Bỏ qua quy tắc \"\(title)\": \(error.localizedDescription).")
                result.rulesSkipped += 1
            }
        }
    }
}
