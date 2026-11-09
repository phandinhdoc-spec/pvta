import CryptoKit
import Darwin
import Foundation

struct SecretaryImportSnapshot {
    var preview: SecretaryImportPreview
    var authority: String
    var hashes: [String]
    var revision: String
    var at: Date
    var result: SecretaryImportResult?
}

public struct SecretaryImportItem: Codable, Sendable, Equatable {
    public var id: String
    /// skill | rule
    public var kind: String
    public var name: String
    public var title: String
    public var sourcePath: String
    public var destination: String
    public var content: String
}

public struct SecretaryImportPreview: Codable, Sendable, Equatable {
    public var token: String
    public var items: [SecretaryImportItem]
    public var warnings: [String]
}

public struct SecretaryImportResult: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable { public var id: String; public var kind: String; public var name: String; public var status: String; public var error: String? }
    public var token: String
    /// saved | partial | error
    public var status: String
    public var items: [Entry]
}

extension SecretaryService {
    static let sortedEncoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    static let importTTL: TimeInterval = 30 * 60

    private static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Đọc đúng một tệp thường nhỏ: không theo liên kết tượng trưng, không liên kết cứng, UTF-8.
    private static func readSmall(_ path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PVTAError("Không mở được “\((path as NSString).lastPathComponent)” (không nhập qua liên kết tượng trưng).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= 60_000 else { throw PVTAError("Chỉ nhập tệp thường tối đa 60 KB, không liên kết cứng.") }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw PVTAError("Tệp phải là Markdown UTF-8.") }
        return text
    }

    private func importAuthority(_ paths: [String]) async throws -> String {
        let grants = try await grants().filter { $0.kind == "read.folder" && $0.enabled }
        let perm = try await permissions.view()
        return Self.sha(String(decoding: try Self.sortedEncoder.encode(grants), as: UTF8.self) + "|" + paths.joined(separator: "\n") + "|" + String(describing: perm.level) + "|" + perm.grants.map(\.path).joined(separator: ","))
    }

    private func importRevision(_ items: [SecretaryImportItem]) async throws -> String {
        let names = await skills.list().map(\.name).sorted().joined(separator: ",")
        let rules = try await store.rules().map(\.key).sorted().joined(separator: ",")
        return Self.sha(names + "|" + rules + "|" + items.map { $0.kind + ":" + $0.name }.joined(separator: ","))
    }

    private func parseImport(file: String, path: String, content: String, warnings: inout [String]) throws -> SecretaryImportItem {
        if let why = SkillText.unsafeReason(content, allowURLs: true) ?? (content.range(of: #"(?:["']?\b(?:password|passwd|api[_-]?key|access[_-]?token|client[_-]?secret|authorization)["']?\s*[:=]\s*\S|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#, options: [.regularExpression, .caseInsensitive]) != nil ? "có trường thông tin bí mật" : nil) {
            throw PVTAError("\(file): nội dung không được nhập: \(why).")
        }
        let id = Self.sha(path)
        if file.range(of: #"^SKILL(-.+)?\.md$"#, options: .regularExpression) != nil {
            var md = content
            var meta = SkillText.parse(md).meta
            if meta["load"] == nil {
                md = md.replacingOccurrences(of: "^---\\r?\\n", with: "---\n" + "load: manual\n", options: .regularExpression)
                warnings.append("\(file): thêm load: manual; giữ nguyên nội dung còn lại.")
                meta = SkillText.parse(md).meta
            } else if meta["load"] != "manual" { throw PVTAError("\(file): đặt load: manual trước khi nhập; không tự kích hoạt skill.") }
            let errors = SkillText.check(md, owner: "user", full: true).filter { $0.level == "error" }
            if !errors.isEmpty { throw PVTAError("\(file): " + errors.map(\.message).joined(separator: " ")) }
            guard let name = meta["name"] else { throw PVTAError("\(file): thiếu name.") }
            return SecretaryImportItem(id: id, kind: "skill", name: name, title: meta["description"] ?? name, sourcePath: path, destination: "skill:\(name)", content: md)
        }
        if file.range(of: #"^RULE(-.+)?\.md$"#, options: .regularExpression) != nil {
            guard let m = content.range(of: #"^# ([^\r\n]+)\r?\n"#, options: .regularExpression) else { throw PVTAError("\(file): định dạng quy tắc là một tiêu đề đầu tệp “# Tên quy tắc” rồi nội dung Markdown.") }
            let title = content[m].dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(content[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count <= 80, !body.isEmpty, content.components(separatedBy: "\n").filter({ $0.hasPrefix("# ") }).count == 1 else {
                throw PVTAError("\(file): quy tắc cần đúng một tiêu đề tối đa 80 ký tự và có nội dung; không nhập nhiều quy tắc trong một tệp.")
            }
            guard body.count <= 20_000 else { throw PVTAError("\(file): quy tắc tối đa 20.000 ký tự.") }
            return SecretaryImportItem(id: id, kind: "rule", name: RuleText.key(title), title: title, sourcePath: path, destination: "quy tắc cá nhân", content: body)
        }
        throw PVTAError("\(file): dùng tên SKILL-*.md hoặc RULE-*.md.")
    }

    /// Bước chuẩn bị: đọc tệp trong phạm vi được cấp, kiểm tra, trả bản xem trước kèm mã xác nhận. Chưa ghi gì.
    public func importPrepare(paths: [String]) async throws -> SecretaryImportPreview {
        guard (1...20).contains(paths.count) else { throw PVTAError("Mỗi lần nhập cần 1–20 tệp.") }
        var resolved: [String] = [], contents: [String] = [], items: [SecretaryImportItem] = [], warnings: [String] = []
        for raw in paths {
            let p = try await folderPath(raw)
            let text = try Self.readSmall(p)
            resolved.append(p); contents.append(text)
            items.append(try parseImport(file: (p as NSString).lastPathComponent, path: p, content: text, warnings: &warnings))
        }
        guard Set(items.map { $0.kind + ":" + $0.name }).count == items.count else { throw PVTAError("Tên đích trùng trong danh sách; tách hoặc đổi tên trước khi nhập.") }
        for i in items where i.kind == "skill" { if await skills.skill(i.name) != nil { throw PVTAError("Đã có skill tên “\(i.name)”; đổi tên trong tệp trước khi nhập.") } }
        let authority = try await importAuthority(resolved), revision = try await importRevision(items)
        let preview = SecretaryImportPreview(token: UUID().uuidString, items: items, warnings: warnings)
        let t = now()
        imports = imports.filter { t.timeIntervalSince($0.value.at) <= Self.importTTL }
        guard imports.count < 100 else { throw PVTAError("Quá nhiều bản xem trước đang chờ; chờ bản cũ hết hạn.") }
        imports[preview.token] = SecretaryImportSnapshot(preview: preview, authority: authority, hashes: contents.map(Self.sha), revision: revision, at: t)
        return preview
    }

    /// Xác nhận: kiểm lại quyền, tệp nguồn và kho đích đúng như lúc xem trước rồi mới ghi. Mã dùng một lần; xác nhận lại chỉ trả biên nhận cũ.
    public func importConfirm(token: String) async throws -> SecretaryImportResult {
        guard var snap = imports[token], now().timeIntervalSince(snap.at) <= Self.importTTL else { throw PVTAError("Bản xem trước hết hạn; hãy xem trước lại.") }
        if let r = snap.result { return r }
        try await permissions.requireWritable()
        imports[token] = nil                                                   // dùng một lần, kể cả khi kiểm lại thất bại
        let stale = PVTAError("Nguồn, quyền hoặc kho đã thay đổi. Hãy xem trước lại trước khi nhập.")
        let paths = snap.preview.items.map(\.sourcePath)
        guard try await importAuthority(paths) == snap.authority, try await importRevision(snap.preview.items) == snap.revision else { throw stale }
        for p in paths { _ = try await folderPath(p) }
        guard try paths.map({ Self.sha(try Self.readSmall($0)) }) == snap.hashes else { throw stale }
        var entries: [SecretaryImportResult.Entry] = []
        for item in snap.preview.items {
            do {
                if item.kind == "skill" { try await skills.create(item.content, owner: "user") }
                else { _ = try await store.saveRule(id: nil, title: item.title, text: item.content, always: false) }
                entries.append(.init(id: item.id, kind: item.kind, name: item.name, status: "saved", error: nil))
            } catch { entries.append(.init(id: item.id, kind: item.kind, name: item.name, status: "error", error: UserMessage.text(for: error))) }
        }
        let ok = entries.filter { $0.status == "saved" }.count
        snap.result = SecretaryImportResult(token: token, status: ok == entries.count ? "saved" : ok > 0 ? "partial" : "error", items: entries)
        imports[token] = snap
        index = nil
        changed(["method": "secretary.import.confirm"])
        return snap.result!
    }
}
