import Foundation

struct GoogleRemoteItem: Codable, Sendable, Equatable {
    var id: String
    var data: JSONValue
    var deleted: Bool = false
    var etag: String? = nil
    var localHint: String? = nil
    var stamp: String {
        let value: JSONValue = ["id": .string(id), "data": deleted ? .null : data, "deleted": .bool(deleted), "etag": etag.map(JSONValue.string) ?? .null]
        return FileHash.of((try? JSONEncoder.sorted.encode(value)) ?? Data())
    }
}
private extension JSONEncoder { static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e } }
struct GoogleLink: Codable, Sendable {
    var localId: String
    var kind: CalendarKind
    var collection: String
    var remoteId: String?
    var creationId: String = UUID().uuidString
    var base: JSONValue = .null
    var baseDeleted = false
    var etag: String? = nil
    var state = "pending"
    var error: String? = nil
    var conflict: GoogleRemoteItem? = nil
}
struct GoogleAccount: Codable, Sendable {
    var calendarId: String?
    var tasklistId: String?
    var notes = false
    var enabled = false
    var cursor: String?
    var links: [String: GoogleLink] = [:]
    var lastSynced: Double? = nil
    var lastError: String? = nil
}
struct GoogleSyncState: Codable, Sendable { var accounts: [String: GoogleAccount] = [:] }

extension DataStore {
    func googleState() throws -> GoogleSyncState {
        guard let raw = try setting("google.sync.v1") else { return GoogleSyncState() }
        guard let state = try? JSONDecoder().decode(GoogleSyncState.self, from: Data(raw.utf8)) else { throw PVTAError("Kho đồng bộ Google không đọc được; không tự ghi đè.") }; return state
    }
    func googleWrite(_ state: GoogleSyncState) throws { try setSetting("google.sync.v1", String(decoding: JSONEncoder.sorted.encode(state), as: UTF8.self)) }
    func calendarWrite(_ state: CalendarState) throws { try setSetting("calendar.v1", String(decoding: JSONEncoder.sorted.encode(state), as: UTF8.self)) }
    func googleRequireOwner(_ owner: String) throws { guard try setting("google.activeOwner") == owner else { throw PVTAError("Tài khoản Google đã đổi hoặc đã đăng xuất.") } }
    func googleSelect(owner: String, calendarId: String?, tasklistId: String?, notes: Bool, enabled: Bool) throws {
        try db.transaction {
            try googleRequireOwner(owner)
            var state = try googleState(), local = try calendarState()
            var account = state.accounts[owner] ?? GoogleAccount()
            if account.calendarId != calendarId { account.cursor = nil }
            account.calendarId = calendarId; account.tasklistId = tasklistId; account.notes = notes; account.enabled = enabled
            // Chỉ nhận các mục chưa gắn tài khoản khi người dùng chọn bật đồng bộ rõ ràng.
            if enabled {
                for id in local.records.keys where local.records[id]!.owner == nil && !local.records[id]!.deleted { local.records[id]!.owner = owner }
                try calendarWrite(local)
            }
            state.accounts[owner] = account; try googleWrite(state)
        }
    }
    func googleBind(owner: String, id: String, kind: CalendarKind, collection: String, remoteId: String?) throws -> GoogleLink {
        try db.transaction {
            try googleRequireOwner(owner)
            var state = try googleState(); guard var account = state.accounts[owner], let local = try calendarState().records[id], local.owner == owner else { throw PVTAError("Mục không thuộc tài khoản Google đang dùng.") }
            var link = account.links[id] ?? GoogleLink(localId: id, kind: kind, collection: collection, remoteId: nil)
            guard link.collection == collection, link.kind == kind else { throw PVTAError("Mục đã gắn với lịch/danh sách khác; không tự chuyển đích.") }
            if let remoteId { link.remoteId = remoteId }
            account.links[id] = link; state.accounts[owner] = account; try googleWrite(state); return link
        }
    }
    func googleSetLink(owner: String, link: GoogleLink) throws {
        try googleRequireOwner(owner)
        var state = try googleState(); guard state.accounts[owner] != nil else { throw PVTAError("Chưa chọn lịch Google.") }
        state.accounts[owner]!.links[link.localId] = link; try googleWrite(state)
    }
    /// Hợp nhất một trang đầy đủ trước khi tiến cursor; không ghi đè nội dung đang sửa ở máy.
    func googleMerge(owner: String, kind: CalendarKind, collection: String, items: [GoogleRemoteItem], full: Bool, cursor: String? = nil) throws {
        try db.transaction {
            try googleRequireOwner(owner)
            var state = try googleState(), local = try calendarState()
            guard var account = state.accounts[owner] else { throw PVTAError("Chưa chọn lịch Google.") }
            var incoming = items
            let seen = Set(items.map(\.id))
            if full {
                for link in account.links.values where link.kind == kind && link.collection == collection && link.base != .null {
                    if let remoteId = link.remoteId, !seen.contains(remoteId) { incoming.append(GoogleRemoteItem(id: remoteId, data: link.base, deleted: true)) }
                }
            }
            var changed = false
            for remote in incoming {
                let found = account.links.values.first { $0.kind == kind && $0.collection == collection && ($0.remoteId == remote.id || ($0.remoteId == nil && remote.localHint == $0.localId)) }
                if var link = found, var record = local.records[link.localId] {
                    guard record.owner == owner else { throw PVTAError("Ánh xạ Google không đúng tài khoản.") }
                    link.remoteId = remote.id
                    let dirty = GoogleContent.dirty(record, link)
                    let remoteChanged = remote.deleted != link.baseDeleted || (!remote.deleted && !GoogleContent.equal(remote.data, link.base, kind: kind))
                    if dirty && remoteChanged && !(record.deleted == remote.deleted && (record.deleted || GoogleContent.equal(record.data, remote.data, kind: kind))) {
                        link.state = "conflict"; link.conflict = remote; link.error = "Cả PVTA và Google đã thay đổi; cần đối chiếu."
                    } else if !dirty || (record.deleted == remote.deleted && (record.deleted || GoogleContent.equal(record.data, remote.data, kind: kind))) {
                        if !GoogleContent.equal(record.data, remote.data, kind: kind) && !remote.deleted || record.deleted != remote.deleted {
                            if !remote.deleted { record.data = remote.data }
                            record.deleted = remote.deleted; record.rev += 1; record.updatedAt = now().timeIntervalSince1970; changed = true
                        }
                        link.base = record.data; link.baseDeleted = record.deleted; link.etag = remote.etag; link.state = "clean"; link.error = nil; link.conflict = nil
                    } else { link.etag = remote.etag; link.state = "pending"; link.error = nil; link.conflict = nil }
                    local.records[record.localId] = record; account.links[record.localId] = link
                } else if !remote.deleted {
                    let id = UUID().uuidString
                    let record = CalendarRecord(localId: id, kind: kind, rev: 1, updatedAt: now().timeIntervalSince1970, data: remote.data, owner: owner)
                    local.records[id] = record
                    account.links[id] = GoogleLink(localId: id, kind: kind, collection: collection, remoteId: remote.id, base: remote.data, etag: remote.etag, state: "clean")
                    changed = true
                }
            }
            if kind == .event, let cursor { account.cursor = cursor }
            guard local.records.count <= 10000 else { throw PVTAError("Kho lịch vượt 10.000 mục; chưa cập nhật mốc đồng bộ.") }
            if changed { local.revision += 1 }
            state.accounts[owner] = account; try calendarWrite(local); try googleWrite(state)
        }
    }
    func googleAcknowledge(owner: String, sent: CalendarRecord, remote: GoogleRemoteItem, link: GoogleLink) throws {
        try googleRequireOwner(owner)
        var state = try googleState(); guard let current = try calendarState().records[sent.localId], current.owner == owner else { throw PVTAError("Mục không còn thuộc tài khoản.") }
        var updated = link; updated.remoteId = remote.id; updated.base = sent.data; updated.baseDeleted = sent.deleted; updated.etag = remote.etag
        updated.state = GoogleContent.equal(current.data, sent.data, kind: sent.kind) && current.deleted == sent.deleted ? "clean" : "pending"
        updated.conflict = nil; updated.error = nil
        state.accounts[owner]!.links[sent.localId] = updated; try googleWrite(state)
    }
    func googleResolve(owner: String, id: String, baseRev: Int, stamp: String, choice: String, remote: GoogleRemoteItem) throws -> Bool {
        try db.transaction {
            try googleRequireOwner(owner)
            var state = try googleState(), local = try calendarState()
            guard var account = state.accounts[owner], var link = account.links[id], let conflict = link.conflict, var record = local.records[id], record.rev == baseRev, record.owner == owner else { throw PVTAError("Bản đối chiếu đã cũ; hãy đọc lại xung đột.") }
            guard conflict.stamp == stamp else { throw PVTAError("Cần đối chiếu đúng phiên bản Google.") }
            if remote.stamp != stamp {
                link.conflict = remote; account.links[id] = link; state.accounts[owner] = account; try googleWrite(state); return false
            }
            if choice == "keep-remote" {
                if !remote.deleted { record.data = remote.data }
                record.deleted = remote.deleted; record.rev += 1; record.updatedAt = now().timeIntervalSince1970
                local.records[id] = record; local.revision += 1
                link.base = record.data; link.baseDeleted = record.deleted; link.etag = remote.etag; link.state = "clean"
            } else if choice == "keep-local" {
                link.base = remote.data; link.baseDeleted = remote.deleted; link.etag = remote.etag; link.state = "pending"
                if remote.deleted && !record.deleted { link.remoteId = nil; link.base = .null; link.baseDeleted = false; link.creationId = UUID().uuidString }
            } else { throw PVTAError("Chọn keep-local hoặc keep-remote.") }
            link.conflict = nil; link.error = nil; account.links[id] = link; state.accounts[owner] = account
            try calendarWrite(local); try googleWrite(state); return true
        }
    }
    func googleSyncResult(owner: String, error: String?) throws {
        try googleRequireOwner(owner)
        var state = try googleState(); guard state.accounts[owner] != nil else { return }
        state.accounts[owner]!.lastError = error
        if error == nil { state.accounts[owner]!.lastSynced = now().timeIntervalSince1970 }
        try googleWrite(state)
    }
}
