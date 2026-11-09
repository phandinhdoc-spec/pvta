import Foundation

public struct FileEntry: Codable, Sendable, Equatable {
    public var path: String
    public var name: String
    /// "file", "dir" hoặc "link" (liên kết tượng trưng, không đi theo).
    public var kind: String
    public var bytes: Int
    public var modified: Date?
}

public struct FileHit: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var text: String?
}

public struct TextEdit: Codable, Sendable, Equatable {
    public var find: String
    public var replace: String
    public var all: Bool
    public init(find: String, replace: String, all: Bool = false) {
        self.find = find
        self.replace = replace
        self.all = all
    }

    static func parse(_ v: JSONValue?) throws -> [TextEdit] {
        guard case .array(let items)? = v, !items.isEmpty else { throw PVTAError("Thiếu danh sách chỗ cần sửa (edits).") }
        return try items.map {
            guard let f = $0["find"]?.string, !f.isEmpty, let r = $0["replace"]?.string else {
                throw PVTAError("Mỗi chỗ sửa cần có find (đoạn cũ, không để trống) và replace (đoạn mới).")
            }
            return TextEdit(find: f, replace: r, all: $0["all"]?.bool ?? false)
        }
    }

    static func apply(_ edits: [TextEdit], to text: String) throws -> String {
        var out = text
        for (i, e) in edits.enumerated() {
            let n = out.components(separatedBy: e.find).count - 1
            let label = edits.count > 1 ? "Chỗ sửa \(i + 1): " : ""
            if n == 0 { throw PVTAError("\(label)không thấy đoạn cần sửa “\(e.find.prefix(60))”. Hãy đọc lại tệp rồi chép đúng đoạn cũ.") }
            if n > 1 && !e.all { throw PVTAError("\(label)đoạn “\(e.find.prefix(60))” xuất hiện \(n) lần. Hãy nêu thêm ngữ cảnh để chỉ một chỗ, hoặc đặt all=true để sửa tất cả.") }
            out = out.replacingOccurrences(of: e.find, with: e.replace)
        }
        return out
    }
}

/// Đọc, tìm, ghi, sửa, di chuyển, xóa (vào Thùng rác) và hoàn tác, luôn trong thư mục đã cấp. Mọi thay đổi được ghi lại để hoàn tác.
public final class FileService: Sendable {
    static let maxTextBytes = 5 * 1024 * 1024
    static let maxReadBytes = 50 * 1024 * 1024
    static let listLimit = 500
    static let findLimit = 50

    let permissions: PermissionService
    let store: DataStore
    let backups: URL
    let sessions: EditSessions
    let actions: HostActions
    let attachments: AttachmentService

    public init(permissions: PermissionService, store: DataStore, directory: URL, attachments: AttachmentService, actions: HostActions = .system) {
        self.permissions = permissions
        self.store = store
        self.backups = directory.appendingPathComponent("backups", isDirectory: true)
        self.sessions = EditSessions(root: directory.appendingPathComponent("edit-sessions", isDirectory: true))
        self.actions = actions
        self.attachments = attachments
    }

    // MARK: Đường dẫn

    /// Thư mục kết quả của hội thoại: nơi người dùng đã chọn nếu vẫn được cấp quyền ghi, không thì thư mục đầu tiên được cấp quyền ghi.
    public func outputDirectory(chatId: String) async throws -> String? {
        let writable = try await store.grants().filter(\.write).map(\.path)
        if let d = try await store.outputDir(chatId: chatId), writable.contains(where: { d == $0 || d.hasPrefix($0 + "/") }) { return d }
        return writable.first
    }

    public func selectOutput(chatId: String, dir: String) async throws -> String {
        let real = try await permissions.authorize(path: dir, write: true)
        var st = stat()
        guard lstat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PVTAError("Thư mục kết quả phải là một thư mục có sẵn.") }
        try await store.setOutputDir(chatId: chatId, real)
        return real
    }

    func resolve(_ raw: String, chatId: String?, write: Bool) async throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { throw PVTAError("Thiếu đường dẫn.") }
        if p.hasPrefix("/") || p.hasPrefix("~") { return try await permissions.authorize(path: p, write: write) }
        guard let chatId, let dir = try await outputDirectory(chatId: chatId) else {
            throw PVTAError("Đường dẫn tương đối cần thư mục kết quả của hội thoại. Hãy chọn thư mục kết quả (output.select), cấp quyền ghi cho một thư mục, hoặc dùng đường dẫn tuyệt đối.")
        }
        return try await permissions.authorize(path: dir + "/" + p, write: write)
    }

    private static func isText(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty || (TextExtractor.plainExtensions.contains(ext) && ext != "rtf")
    }

    private static func requireText(_ path: String) throws {
        guard isText(path) else {
            throw PVTAError("“\((path as NSString).lastPathComponent)” không phải tệp văn bản thường nên công cụ này chưa ghi được. Với Word, Excel, PowerPoint hãy dùng công cụ tài liệu Office.")
        }
    }

    private static func kind(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return "dir"
        case S_IFLNK: return "link"
        case S_IFREG: return "file"
        default: return "other"
        }
    }

    // MARK: Đọc, liệt kê, tìm

    public func read(path: String, chatId: String?, start: Int = 0, length: Int? = nil) async throws -> String {
        let p = try await resolve(path, chatId: chatId, write: false)
        guard Self.kind(p) == "file" else { throw PVTAError("“\((p as NSString).lastPathComponent)” không phải tệp đọc được (có thể là thư mục).") }
        let text = Array(try TextExtractor.extract(URL(fileURLWithPath: p)).text)
        let s = max(0, min(text.count, start))
        let len = max(1, min(AttachmentService.limits.readMax, length ?? AttachmentService.limits.readDefault))
        let e = min(text.count, s + len)
        return "Tệp: \(p) — ký tự \(s)–\(e) / \(text.count)" + (e < text.count ? " (đọc tiếp từ start=\(e))" : "") + "\n---\n" + String(text[s..<e])
    }

    public func list(path: String, chatId: String?, depth: Int = 1) async throws -> [FileEntry] {
        let root = try await resolve(path, chatId: chatId, write: false)
        guard Self.kind(root) == "dir" else { throw PVTAError("“\(root)” không phải thư mục.") }
        var out: [FileEntry] = []
        func visit(_ dir: String, _ level: Int) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            for n in names where out.count < Self.listLimit {
                let full = dir + "/" + n
                guard let k = Self.kind(full) else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: full)
                out.append(FileEntry(path: full, name: n, kind: k, bytes: (attrs?[.size] as? Int) ?? 0, modified: attrs?[.modificationDate] as? Date))
                if k == "dir", level < depth { visit(full, level + 1) }
            }
        }
        visit(root, 1)
        return out
    }

    /// Tìm theo tên và/hoặc nội dung, không phân biệt dấu và hoa thường ("quy tac" thấy "Quy tắc").
    public func find(root: String, chatId: String?, name: String?, content: String?) async throws -> (hits: [FileHit], note: String?) {
        let base = try await resolve(root, chatId: chatId, write: false)
        guard Self.kind(base) == "dir" else { throw PVTAError("“\(base)” không phải thư mục.") }
        func words(_ s: String?) -> [String] { Fold.text(s ?? "").split(whereSeparator: \.isWhitespace).map(String.init) }
        let nameWords = words(name), contentWords = words(content)
        guard !nameWords.isEmpty || !contentWords.isEmpty else { throw PVTAError("Cần từ khóa tên (name) hoặc nội dung (content).") }
        let walked = AttachmentService.walk(base)
        var note = walked.truncated ? "Thư mục quá lớn, chỉ duyệt \(AttachmentService.limits.treeEntries) mục đầu." : nil
        var hits: [FileHit] = []
        let deadline = Date().addingTimeInterval(20)
        var scanned = 0
        for rel in walked.files {
            guard hits.count < Self.findLimit else { note = (note.map { $0 + " " } ?? "") + "Còn nhiều kết quả khác, hãy tìm cụ thể hơn."; break }
            let foldedPath = Fold.text(rel)
            guard nameWords.allSatisfy({ foldedPath.contains($0) }) else { continue }
            let full = base + "/" + rel
            if contentWords.isEmpty { hits.append(FileHit(path: full, line: nil, text: nil)); continue }
            let ext = (rel as NSString).pathExtension.lowercased()
            let readable = TextExtractor.plainExtensions.contains(ext) || ["docx", "xlsx", "pptx", "pdf"].contains(ext)
            guard readable, scanned < 1500, Date() < deadline else { if readable { note = "Dừng tìm trong nội dung ở giữa chừng vì quá nhiều tệp hoặc quá lâu." }; continue }
            scanned += 1
            guard let ex = try? TextExtractor.extract(URL(fileURLWithPath: full)) else { continue }
            for (i, line) in ex.text.components(separatedBy: "\n").enumerated() {
                let f = Fold.text(line)
                if contentWords.allSatisfy({ f.contains($0) }) {
                    hits.append(FileHit(path: full, line: i + 1, text: String(line.trimmingCharacters(in: .whitespaces).prefix(300))))
                    if hits.count >= Self.findLimit { break }
                }
            }
        }
        return (hits, note)
    }

    // MARK: Ghi an toàn

    private func backupFile(for changeId: String, source path: String) throws -> String {
        let dir = backups.appendingPathComponent(changeId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try FileManager.default.copyItem(atPath: path, toPath: dest.path)
        return dest.path
    }

    /// Ghi nguyên tử: viết ra tệp tạm cùng thư mục (không theo liên kết tượng trưng) rồi đổi tên đè lên đích.
    /// Đổi tên thay chính mục đích chứ không ghi xuyên qua liên kết tượng trưng nếu đích là liên kết.
    static func atomicWrite(_ data: Data, to path: String, exclusive: Bool = false) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = dir + "/.pvta-" + UUID().uuidString + ".tmp"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PVTAError("Không tạo được tệp tạm để ghi. Hãy kiểm tra quyền ghi và dung lượng ổ đĩa.") }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        var st = stat()
        let mode: mode_t = lstat(path, &st) == 0 ? (st.st_mode & 0o7777) : 0o644
        guard ok, chmod(tmp, mode) == 0 else { unlink(tmp); throw PVTAError("Không ghi được tệp. Hãy kiểm tra dung lượng ổ đĩa và quyền ghi.") }
        if exclusive {
            let r = link(tmp, path)
            unlink(tmp)
            guard r == 0 else { throw PVTAError(errno == EEXIST ? "Đã có tệp cùng tên; PVTA không ghi đè." : "Không ghi được tệp. Hãy kiểm tra quyền ghi.") }
        } else if rename(tmp, path) != 0 {
            unlink(tmp)
            throw PVTAError("Không ghi được tệp. Hãy kiểm tra quyền ghi.")
        }
    }

    private func record(_ kind: String, path: String, chatId: String?, original: String? = nil, backup: String? = nil, trash: String? = nil,
                        before: String? = nil, after: String? = nil, detail: String? = nil, id: String = UUID().uuidString) async throws -> FileChange {
        let c = FileChange(id: id, chatId: chatId, kind: kind, path: path, original: original, backup: backup, trashPath: trash,
                           beforeHash: before, afterHash: after, detail: detail, createdAt: Date(), undone: false)
        try await store.recordChange(c)
        return c
    }

    /// Tạo tệp mới hoặc ghi đè (chỉ khi `overwrite`), có sao lưu bản cũ để hoàn tác.
    public func write(path: String, content: String, overwrite: Bool, chatId: String?) async throws -> FileChange {
        let p = try await resolve(path, chatId: chatId, write: true)
        try Self.requireText(p)
        let data = Data(content.utf8)
        guard data.count <= Self.maxTextBytes else { throw PVTAError("Nội dung quá lớn (tối đa 5 MB). Hãy chia nhỏ.") }
        let id = UUID().uuidString
        switch Self.kind(p) {
        case nil:
            try Self.atomicWrite(data, to: p, exclusive: true)
            return try await record("create", path: p, chatId: chatId, after: FileHash.of(data), detail: "Tạo tệp mới", id: id)
        case "file":
            guard overwrite else { throw PVTAError("Đã có tệp “\((p as NSString).lastPathComponent)”. Hãy đặt overwrite=true để ghi đè (bản cũ được sao lưu) hoặc chọn tên khác.") }
            let before = FileHash.of(URL(fileURLWithPath: p))
            let backup = try backupFile(for: id, source: p)
            try Self.atomicWrite(data, to: p)
            return try await record("overwrite", path: p, chatId: chatId, backup: backup, before: before, after: FileHash.of(data), detail: "Ghi đè", id: id)
        default:
            throw PVTAError("“\(p)” không phải tệp thường nên không ghi được.")
        }
    }

    private func textOf(_ p: String) throws -> String {
        guard Self.kind(p) == "file" else { throw PVTAError("Không tìm thấy tệp “\((p as NSString).lastPathComponent)”.") }
        guard let d = FileManager.default.contents(atPath: p), d.count <= Self.maxTextBytes, let t = String(data: d, encoding: .utf8) else {
            throw PVTAError("“\((p as NSString).lastPathComponent)” không phải tệp văn bản UTF-8 nhỏ hơn 5 MB.")
        }
        return t
    }

    /// Kết quả sửa thử (không ghi) để xem trước khi duyệt.
    func previewEdit(path: String, edits: [TextEdit], chatId: String?) async throws -> (path: String, diff: String) {
        let p = try await resolve(path, chatId: chatId, write: false)
        try Self.requireText(p)
        let old = try textOf(p)
        return (p, DiffText.unified(old: old, new: try TextEdit.apply(edits, to: old)))
    }

    /// Sửa một phần: thay đúng các đoạn nêu trong `edits` (mỗi đoạn phải khớp một chỗ, trừ khi `all`).
    public func edit(path: String, edits: [TextEdit], chatId: String?) async throws -> FileChange {
        let p = try await resolve(path, chatId: chatId, write: true)
        try Self.requireText(p)
        let old = try textOf(p)
        let data = Data(try TextEdit.apply(edits, to: old).utf8)
        guard data.count <= Self.maxTextBytes else { throw PVTAError("Kết quả sau khi sửa quá lớn (tối đa 5 MB).") }
        let id = UUID().uuidString
        let before = FileHash.of(URL(fileURLWithPath: p))
        let backup = try backupFile(for: id, source: p)
        guard FileHash.of(URL(fileURLWithPath: p)) == before else { throw PVTAError("Tệp vừa bị đổi trong lúc sửa nên PVTA dừng lại. Hãy thử lại.") }
        try Self.atomicWrite(data, to: p)
        return try await record("edit", path: p, chatId: chatId, backup: backup, before: before, after: FileHash.of(data), detail: "Sửa \(edits.count) chỗ", id: id)
    }

    public func move(from: String, to: String, chatId: String?) async throws -> FileChange {
        let src = try await resolve(from, chatId: chatId, write: true)
        let dst = try await resolve(to, chatId: chatId, write: true)
        guard let k = Self.kind(src), k != "link" else { throw PVTAError("Không tìm thấy tệp hoặc thư mục cần di chuyển (liên kết tượng trưng không được nhận).") }
        guard Self.kind(dst) == nil else { throw PVTAError("Đã có tệp hoặc thư mục ở nơi đến; PVTA không ghi đè.") }
        guard !(dst + "/").hasPrefix(src + "/") else { throw PVTAError("Không thể di chuyển một thư mục vào chính nó.") }
        try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let hash = k == "file" ? FileHash.of(URL(fileURLWithPath: src)) : nil
        do { try FileManager.default.moveItem(atPath: src, toPath: dst) } catch { throw PVTAError("Không di chuyển được. Hãy kiểm tra quyền ghi ở cả hai nơi.") }
        return try await record("move", path: dst, chatId: chatId, original: src, before: hash, after: hash, detail: "Di chuyển")
    }

    /// Xóa = chuyển vào Thùng rác (khôi phục được), không xóa hẳn.
    public func trash(paths: [String], chatId: String?) async throws -> [FileChange] {
        var resolved: [String] = []
        for raw in paths {
            let p = try await resolve(raw, chatId: chatId, write: true)
            guard let k = Self.kind(p) else { throw PVTAError("Không tìm thấy “\(p)”.") }
            guard k != "link" else { throw PVTAError("“\(p)” là liên kết tượng trưng nên PVTA không xóa.") }
            resolved.append(p)
        }
        var out: [FileChange] = []
        for p in resolved {
            let hash = Self.kind(p) == "file" ? FileHash.of(URL(fileURLWithPath: p)) : nil
            let where_: URL
            do { where_ = try actions.trash(URL(fileURLWithPath: p)) } catch { throw PVTAError("Không chuyển được “\((p as NSString).lastPathComponent)” vào Thùng rác.") }
            out.append(try await record("trash", path: p, chatId: chatId, original: p, trash: where_.path, before: hash, detail: "Chuyển vào Thùng rác"))
        }
        return out
    }

    // MARK: Hoàn tác

    public func changes(limit: Int = 50) async throws -> [FileChange] { try await store.fileChanges(limit: limit) }

    /// Hoàn tác một thay đổi, chỉ khi tệp vẫn đúng như PVTA đã để lại (chưa bị sửa bên ngoài).
    public func undo(id: String) async throws -> FileChange {
        try await permissions.requireWritable()
        guard let c = try await store.fileChange(id: id) else { throw PVTAError("Không tìm thấy thay đổi cần hoàn tác.") }
        guard !c.undone else { throw PVTAError("Thay đổi này đã được hoàn tác.") }
        let conflict = PVTAError("Tệp đã được chỉnh sửa bên ngoài PVTA sau lần ghi này nên PVTA giữ nguyên để tránh mất thay đổi của bạn.")
        let p = try await permissions.authorize(path: c.path, write: true)
        switch c.kind {
        case "create":
            guard FileHash.of(URL(fileURLWithPath: p)) == c.afterHash else { throw conflict }
            _ = try actions.trash(URL(fileURLWithPath: p))
        case "overwrite", "edit", "save":
            guard FileHash.of(URL(fileURLWithPath: p)) == c.afterHash else { throw conflict }
            guard let b = c.backup, let data = FileManager.default.contents(atPath: b) else { throw PVTAError("Không còn bản sao lưu để khôi phục.") }
            try Self.atomicWrite(data, to: p)
        case "move":
            guard let origin = c.original else { throw PVTAError("Thiếu vị trí cũ của tệp.") }
            let back = try await permissions.authorize(path: origin, write: true)
            guard Self.kind(back) == nil else { throw PVTAError("Vị trí cũ đã có tệp khác nên không thể đưa về.") }
            if c.afterHash != nil, FileHash.of(URL(fileURLWithPath: p)) != c.afterHash { throw conflict }
            guard Self.kind(p) != nil else { throw PVTAError("Tệp không còn ở nơi đã di chuyển tới.") }
            try FileManager.default.moveItem(atPath: p, toPath: back)
        case "trash":
            guard let t = c.trashPath, Self.kind(t) != nil else { throw PVTAError("Không còn thấy tệp trong Thùng rác (có thể đã dọn Thùng rác).") }
            guard Self.kind(p) == nil else { throw PVTAError("Vị trí cũ đã có tệp khác nên không thể khôi phục.") }
            try FileManager.default.moveItem(atPath: t, toPath: p)
        default:
            throw PVTAError("Loại thay đổi này chưa hỗ trợ hoàn tác.")
        }
        try await store.markUndone(id)
        var done = c
        done.undone = true
        return done
    }

    func prune() async {
        for b in (try? await store.pruneFileChanges()) ?? [] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: b).deletingLastPathComponent()) }
    }

    /// Cho model biết công cụ tệp được làm việc ở đâu (để không phải đoán đường dẫn).
    func promptSection(chatId: String) async -> String {
        guard let grants = try? await store.grants(), !grants.isEmpty else { return "" }
        var lines = ["THƯ MỤC PVTA ĐƯỢC PHÉP LÀM VIỆC (các công cụ fs_* chỉ hoạt động trong những thư mục này):"]
        lines += grants.map { "- \($0.path) (\($0.write ? "đọc và ghi" : "chỉ đọc"))" }
        if let out = try? await outputDirectory(chatId: chatId) {
            lines.append("THƯ MỤC KẾT QUẢ của hội thoại này: \(out). Đường dẫn tương đối tính từ đây; tạo tệp mới ở đây trừ khi người dùng nói khác.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Mở tệp

    /// Mở bằng ứng dụng mặc định hoặc hiện trong Finder. Chỉ tệp nằm trong phạm vi người dùng đã cấp hoặc đã đính kèm.
    public func open(ref: String, chatId: String?, reveal: Bool) async throws -> String {
        var target: URL?
        if let chatId, let r = try? await attachments.resolve(chatId: chatId, ref: ref) { target = r.url }
        if target == nil, ref.hasPrefix("/") || ref.hasPrefix("~") { target = URL(fileURLWithPath: try await permissions.authorize(path: ref, write: false)) }
        if target == nil, let chatId { target = URL(fileURLWithPath: try await resolve(ref, chatId: chatId, write: false)) }
        guard let url = target, Self.kind(url.path) != nil else { throw PVTAError("Không tìm thấy “\(ref)” trong những gì bạn đã cấp hoặc đính kèm.") }
        actions.open(url, reveal)
        return url.path
    }

    // MARK: Phiên sửa

    public struct SessionView: Codable, Sendable, Equatable {
        public var id: String
        public var source: String
        public var revision: Int
        public var canUndo: Bool
        public var canRedo: Bool
        public var dirty: Bool
        /// Tệp gốc đã bị sửa bên ngoài PVTA kể từ lúc mở.
        public var sourceChanged: Bool
    }

    private func view(_ s: EditSession) -> SessionView {
        SessionView(id: s.id, source: s.source, revision: s.revision, canUndo: s.canUndo, canRedo: s.canRedo, dirty: s.dirty,
                    sourceChanged: FileHash.of(URL(fileURLWithPath: s.source)) != s.sourceHash)
    }

    public func editOpen(path: String, chatId: String?) async throws -> SessionView {
        let p = try await resolve(path, chatId: chatId, write: false)
        try Self.requireText(p)
        guard Self.kind(p) == "file" else { throw PVTAError("Chỉ mở bản nháp cho tệp văn bản có sẵn.") }
        return view(try await sessions.open(source: p))
    }

    public func editRead(sessionId: String, start: Int = 0, length: Int? = nil) async throws -> (session: SessionView, text: String, total: Int) {
        let s = try await sessions.get(sessionId)
        let t = Array(try textOf(try await sessions.current(s).path))
        let a = max(0, min(t.count, start)), b = min(t.count, a + max(1, min(AttachmentService.limits.readMax, length ?? AttachmentService.limits.readDefault)))
        return (view(s), String(t[a..<b]), t.count)
    }

    /// Sửa bản nháp (không đụng tới tệp gốc): thay đúng các đoạn trong `edits` hoặc thay toàn bộ bằng `content`.
    public func editApply(sessionId: String, revision: Int, edits: [TextEdit]?, content: String?) async throws -> SessionView {
        let s = try await sessions.change(sessionId, revision: revision) { current in
            if let content { return Data(content.utf8) }
            guard let edits else { throw PVTAError("Cần danh sách chỗ sửa (edits) hoặc nội dung mới (content).") }
            let new = Data(try TextEdit.apply(edits, to: try self.textOf(current.path)).utf8)
            guard new.count <= Self.maxTextBytes else { throw PVTAError("Kết quả sau khi sửa quá lớn (tối đa 5 MB).") }
            return new
        }
        return view(s)
    }

    public func editMove(sessionId: String, revision: Int, by step: Int) async throws -> SessionView { view(try await sessions.move(sessionId, revision: revision, by: step)) }

    /// Khác biệt giữa bản gốc lúc mở và bản nháp hiện tại.
    public func editDiff(sessionId: String) async throws -> String {
        let s = try await sessions.get(sessionId)
        let diff = DiffText.unified(old: try textOf(try await sessions.baseline(s).path), new: try textOf(try await sessions.current(s).path))
        return diff.isEmpty ? "(bản nháp chưa khác bản gốc)" : diff
    }

    public func editDiscard(sessionId: String, revision: Int) async throws { try await sessions.discard(sessionId, revision: revision) }

    /// Lưu bản nháp. Không có `destination`: ghi đè tệp gốc nếu nó chưa bị sửa bên ngoài PVTA. Có `destination`: lưu thành tệp mới (không bao giờ ghi đè).
    public func editSave(sessionId: String, revision: Int, destination: String?, chatId: String?) async throws -> SessionView {
        try await permissions.requireWritable()
        let s = try await sessions.get(sessionId)
        guard s.revision == revision else { throw PVTAError("Bản nháp đã đổi. Hãy tải lại trước khi lưu.") }
        let data = try Data(contentsOf: try await sessions.current(s))
        let ext = (s.source as NSString).pathExtension.lowercased()
        let target: String
        if let destination {
            target = try await resolve(destination, chatId: chatId, write: true)
            guard (target as NSString).pathExtension.lowercased() == ext else { throw PVTAError("Hãy chọn tên tệp cùng định dạng (.\(ext)).") }
        } else {
            target = try await permissions.authorize(path: s.source, write: true)
        }
        if target == s.source {
            guard FileHash.of(URL(fileURLWithPath: s.source)) == s.sourceHash else {
                throw PVTAError("Tệp gốc đã bị sửa bên ngoài PVTA. Hãy chọn Lưu thành… để giữ cả hai bản.")
            }
            let id = UUID().uuidString
            let backup = try backupFile(for: id, source: s.source)
            try Self.atomicWrite(data, to: s.source)
            let after = FileHash.of(data)
            _ = try await record("save", path: s.source, chatId: chatId, backup: backup, before: s.sourceHash, after: after, detail: "Lưu bản nháp", id: id)
            return view(try await sessions.rebase(s.id, revision: revision, newHash: after))
        }
        guard await sessions.find(target) == nil else { throw PVTAError("Tệp đích đang có bản nháp riêng. Hãy chọn tên khác.") }
        try Self.atomicWrite(data, to: target, exclusive: true)
        _ = try await record("create", path: target, chatId: chatId, after: FileHash.of(data), detail: "Lưu thành từ bản nháp")
        let next = try await sessions.open(source: target)
        await sessions.remove(s.id)
        return view(next)
    }
}
