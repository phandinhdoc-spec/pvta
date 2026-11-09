import Foundation

actor CalendarService {
    typealias Ask = @Sendable (String, [ChatImage], String, String?) async throws -> String
    let store: DataStore
    let files: FileService
    let home: URL
    let ask: Ask
    let now: @Sendable () -> Date
    let changed: @Sendable (JSONValue) -> Void
    var proposals: [String: CalendarProposal] = [:]
    var applying = Set<String>()
    init(store: DataStore, files: FileService, home: URL, now: @escaping @Sendable () -> Date = { Date() },
         ask: @escaping Ask, changed: @escaping @Sendable (JSONValue) -> Void = { _ in }) {
        self.store = store; self.files = files; self.home = home.appendingPathComponent("calendar-attachments", isDirectory: true)
        self.now = now; self.ask = ask; self.changed = changed
    }
    func list(includeDeleted: Bool = false) async throws -> JSONValue {
        let state = try await store.calendarState()
        let records = state.records.values.filter { includeDeleted || !$0.deleted }.sorted { $0.localId < $1.localId }
        return ["revision": .number(Double(state.revision)), "events": try JSONValue(encoding: records.filter { $0.kind == .event }), "tasks": try JSONValue(encoding: records.filter { $0.kind == .task }), "notes": try JSONValue(encoding: records.filter { $0.kind == .note })]
    }
    func get(_ id: String, kind: CalendarKind) async throws -> CalendarRecord {
        guard let r = try await store.calendarState().records[id], r.kind == kind else { throw PVTAError("Không tìm thấy mục lịch.") }; return r
    }
    func publish(_ result: CalendarWriteResult) throws -> CalendarWriteResult {
        if result.ok { changed(try JSONValue(encoding: result)) }; return result
    }
    func save(kind: CalendarKind, id: String?, baseRev: Int, data: JSONValue) async throws -> CalendarWriteResult {
        if id == nil && baseRev != 0 { throw PVTAError("Mục mới phải có baseRev bằng 0.") }
        return try publish(await store.calendarCommit([CalendarMutation(action: "save", kind: kind, localId: id ?? UUID().uuidString, baseRev: baseRev, data: data)]))
    }
    func delete(kind: CalendarKind, id: String, baseRev: Int, confirmed: Bool) async throws -> CalendarWriteResult {
        guard confirmed else { throw PVTAError("Cần xác nhận xóa mục lịch.") }
        return try publish(await store.calendarCommit([CalendarMutation(action: "delete", kind: kind, localId: id, baseRev: baseRev)]))
    }
    func resolve(kind: CalendarKind, id: String, baseRev: Int, choice: String, data: JSONValue?) async throws -> CalendarWriteResult {
        if choice == "keep-current" {
            let state = try await store.calendarState()
            guard let current = state.records[id], current.kind == kind else { throw PVTAError("Không tìm thấy mục lịch.") }
            return CalendarWriteResult(ok: true, revision: state.revision, records: [current])
        }
        guard choice == "use-mine", let data else { throw PVTAError("Chọn keep-current hoặc use-mine với nội dung đã đối chiếu.") }
        return try await save(kind: kind, id: id, baseRev: baseRev, data: data)
    }
    func source(_ raw: String, chatId: String?) async throws -> (String, Int, String) {
        let path = try await files.resolve(raw, chatId: chatId, write: false)
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let hash = FileHash.of(URL(fileURLWithPath: path)) else { throw PVTAError("Không đọc được tệp “\((raw as NSString).lastPathComponent)”.") }
        return (path, Int(st.st_size), hash)
    }
    func stage(_ raw: String, chatId: String?, expectedHash: String? = nil) async throws -> CalendarAttachment {
        let (path, _, hash) = try await source(raw, chatId: chatId)
        guard expectedHash == nil || expectedHash == hash else { throw PVTAError("Tệp đính kèm đã đổi sau khi xem đề xuất.") }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString, name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        let stored = id + (ext.isEmpty ? "" : "." + ext)
        let dest = home.appendingPathComponent(stored)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            guard FileHash.of(dest) == hash else { throw PVTAError("Tệp thay đổi trong lúc sao chép; chưa đính kèm.") }
            let bytes = try dest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "pdf": "application/pdf", "md": "text/markdown", "txt": "text/plain"][ext] ?? "application/octet-stream"
            return CalendarAttachment(id: id, name: name, localPath: stored, bytes: bytes, sha256: hash, mime: mime)
        } catch { try? FileManager.default.removeItem(at: dest); throw error }
    }
    func addAttachment(kind: CalendarKind, id: String, baseRev: Int, path: String, chatId: String?) async throws -> CalendarWriteResult {
        let old = try await get(id, kind: kind)
        guard !old.deleted, old.rev == baseRev else { return CalendarWriteResult(ok: false, revision: try await store.calendarState().revision, reason: old.deleted ? "deleted" : "conflict", current: old) }
        let attachment = try await stage(path, chatId: chatId)
        do {
            let result = try await store.calendarCommit([CalendarMutation(action: "attach", kind: kind, localId: id, baseRev: baseRev, attachment: attachment)])
            if !result.ok { try? FileManager.default.removeItem(at: home.appendingPathComponent(attachment.localPath)) }
            return try publish(result)
        } catch { try? FileManager.default.removeItem(at: home.appendingPathComponent(attachment.localPath)); throw error }
    }
    func detach(kind: CalendarKind, id: String, baseRev: Int, attachmentId: String) async throws -> CalendarWriteResult {
        // Chỉ gỡ liên kết, giữ bản sao và tệp gốc để không mất dữ liệu.
        try publish(await store.calendarCommit([CalendarMutation(action: "detach", kind: kind, localId: id, baseRev: baseRev, attachmentId: attachmentId)]))
    }
    func attachmentPath(kind: CalendarKind, id: String, attachmentId: String) async throws -> JSONValue {
        let record = try await get(id, kind: kind)
        guard !record.deleted, let a = record.attachments.first(where: { $0.id == attachmentId }), !a.localPath.contains("/"), !a.localPath.contains("\\"), a.localPath != ".", a.localPath != "..",
              let root = PathGuard.canonical(home.path), let path = PathGuard.canonical(home.appendingPathComponent(a.localPath).path), path.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: path) else { throw PVTAError("Bản sao đính kèm không còn hoặc nằm ngoài kho lịch.") }
        return ["path": .string(path), "name": .string(a.name), "sha256": .string(a.sha256)]
    }
    func freeSlots(from: String, to: String, minutes: Int, zone: String) async throws -> [CalendarSlot] {
        let (a, b) = try CalendarDates.range(from, to, zone: zone)
        return try CalendarSchedule.freeSlots(Array(await store.calendarState().records.values), from: a, to: b, minutes: minutes)
    }
    func conflicts(from: String, to: String, zone: String) async throws -> [CalendarOverlap] {
        let (a, b) = try CalendarDates.range(from, to, zone: zone)
        return try CalendarSchedule.overlaps(Array(await store.calendarState().records.values), from: a, to: b)
    }
    func cancelProposal(_ id: String) { if !applying.contains(id) { proposals[id] = nil } }
    func proposal(_ id: String) throws -> CalendarProposal {
        guard let p = proposals[id], p.expiresAt > now().timeIntervalSince1970 else { throw PVTAError("Đề xuất không tồn tại hoặc đã hết hạn; hãy tạo lại.") }; return p
    }
    func apply(_ id: String, approved: Bool, allowConflicts: Bool, chatId: String?) async throws -> CalendarWriteResult {
        guard approved else { throw PVTAError("Đề xuất chưa được duyệt; lịch chưa thay đổi.") }
        let p = try proposal(id)
        guard !applying.contains(id) else { throw PVTAError("Đề xuất đang được áp dụng.") }
        guard p.conflicts.isEmpty || allowConflicts else { throw PVTAError("Có lịch trùng; hãy sửa đề xuất hoặc xác nhận giữ các lịch trùng đã xem.") }
        applying.insert(id); defer { applying.remove(id) }
        guard try await store.calendarState().revision == p.revision else { throw PVTAError("Lịch đã đổi sau khi xem đề xuất; hãy tạo lại và duyệt bản mới.") }
        var mutations = p.operations, staged: [CalendarAttachment] = []
        do {
            for i in mutations.indices where mutations[i].action == "attach" {
                guard let path = mutations[i].sourcePath else { throw PVTAError("Thiếu tệp đính kèm.") }
                let a = try await stage(path, chatId: chatId, expectedHash: mutations[i].sourceHash)
                mutations[i].attachment = a; staged.append(a)
            }
            try Task.checkCancellation()
            guard proposals[id] != nil else { throw PVTAError("Đề xuất đã hủy.") }
            let result = try await store.calendarCommit(mutations, revision: p.revision)
            if !result.ok { for a in staged { try? FileManager.default.removeItem(at: home.appendingPathComponent(a.localPath)) } }
            else { proposals[id] = nil }
            return try publish(result)
        } catch { for a in staged { try? FileManager.default.removeItem(at: home.appendingPathComponent(a.localPath)) }; throw error }
    }
}
