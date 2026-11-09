import Foundation

public struct EditSession: Codable, Sendable, Equatable {
    public var id: String
    /// Đường dẫn chuẩn của tệp gốc.
    public var source: String
    /// Mã băm của tệp gốc lúc mở (hoặc lúc lưu gần nhất) để phát hiện sửa ngoài PVTA.
    public var sourceHash: String
    var versions: [String]
    var cursor: Int
    public var revision: Int

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor + 1 < versions.count }
    public var dirty: Bool { versions.count > 1 || cursor > 0 }
}

/// Bản nháp của tệp: các phiên bản bất biến nằm trong thư mục riêng của PVTA, tệp gốc chỉ đổi khi người dùng bấm Lưu.
actor EditSessions {
    private let root: URL

    init(root: URL) { self.root = root }

    private func dir(_ id: String) throws -> URL {
        guard id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw PVTAError("Phiên chỉnh sửa không hợp lệ.") }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    private func persist(_ s: EditSession) throws {
        let d = try dir(s.id)
        let tmp = d.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(s).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(d.appendingPathComponent("session.json"), withItemAt: tmp)
    }

    func get(_ id: String) throws -> EditSession {
        guard let data = try? Data(contentsOf: try dir(id).appendingPathComponent("session.json")),
              let s = try? JSONDecoder().decode(EditSession.self, from: data) else {
            throw PVTAError("Phiên chỉnh sửa không còn. Hãy mở lại tệp.")
        }
        return s
    }

    func current(_ s: EditSession) throws -> URL { try dir(s.id).appendingPathComponent(s.versions[s.cursor]) }
    func baseline(_ s: EditSession) throws -> URL { try dir(s.id).appendingPathComponent(s.versions[0]) }

    static func sessionId(_ canonicalSource: String) -> String { FileHash.of(Data(canonicalSource.utf8)) }

    func find(_ canonicalSource: String) -> EditSession? { try? get(Self.sessionId(canonicalSource)) }

    /// Mở phiên cho tệp. Đã có phiên với thay đổi chưa lưu thì giữ nguyên; phiên chưa sửa gì mà tệp gốc đã đổi thì bắt đầu lại từ tệp mới.
    func open(source canonical: String) throws -> EditSession {
        let id = Self.sessionId(canonical)
        let d = try dir(id)
        let hash = FileHash.of(URL(fileURLWithPath: canonical))
        if let existing = try? get(id) {
            if existing.dirty || existing.sourceHash == hash { return existing }
            try? FileManager.default.removeItem(at: d)
        }
        guard let hash else { throw PVTAError("Không đọc được tệp để mở bản nháp.") }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ext = (canonical as NSString).pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        try FileManager.default.copyItem(atPath: canonical, toPath: d.appendingPathComponent(name).path)
        guard FileHash.of(d.appendingPathComponent(name)) == hash else {
            try? FileManager.default.removeItem(at: d)
            throw PVTAError("Tệp đang được ứng dụng khác lưu. Hãy mở lại sau giây lát.")
        }
        let s = EditSession(id: id, source: canonical, sourceHash: hash, versions: [name], cursor: 0, revision: 0)
        try persist(s)
        return s
    }

    private func check(_ s: EditSession, _ revision: Int) throws {
        guard s.revision == revision else { throw PVTAError("Bản nháp đã đổi. Hãy tải lại trước khi chỉnh sửa.") }
    }

    /// Tạo phiên bản mới từ phiên bản hiện tại; bỏ các phiên bản "làm lại" phía sau.
    func change(_ id: String, revision: Int, writer: (URL) throws -> Data) throws -> EditSession {
        var s = try get(id)
        try check(s, revision)
        let d = try dir(id)
        let ext = (s.source as NSString).pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let out = d.appendingPathComponent(name)
        try writer(try current(s)).write(to: out, options: .withoutOverwriting)
        let abandoned = Array(s.versions[(s.cursor + 1)...])
        s.versions = Array(s.versions[...s.cursor]) + [name]
        s.cursor += 1
        s.revision += 1
        do { try persist(s) } catch { try? FileManager.default.removeItem(at: out); throw error }
        for v in abandoned { try? FileManager.default.removeItem(at: d.appendingPathComponent(v)) }
        return s
    }

    func move(_ id: String, revision: Int, by step: Int) throws -> EditSession {
        var s = try get(id)
        try check(s, revision)
        let next = s.cursor + step
        guard s.versions.indices.contains(next) else { throw PVTAError("Không còn bước hoàn tác hoặc làm lại.") }
        s.cursor = next
        s.revision += 1
        try persist(s)
        return s
    }

    /// Sau khi lưu: phiên bản hiện tại trở thành nền mới, bỏ lịch sử cũ.
    func rebase(_ id: String, revision: Int, newHash: String) throws -> EditSession {
        var s = try get(id)
        try check(s, revision)
        let d = try dir(id)
        let keep = s.versions[s.cursor]
        let old = s.versions.filter { $0 != keep }
        s.versions = [keep]
        s.cursor = 0
        s.revision += 1
        s.sourceHash = newHash
        try persist(s)
        for v in old { try? FileManager.default.removeItem(at: d.appendingPathComponent(v)) }
        return s
    }

    func discard(_ id: String, revision: Int) throws {
        let s = try get(id)
        try check(s, revision)
        try? FileManager.default.removeItem(at: try dir(id))
    }

    func remove(_ id: String) { if let d = try? dir(id) { try? FileManager.default.removeItem(at: d) } }
}
