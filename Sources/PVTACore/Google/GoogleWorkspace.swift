import Foundation

enum GoogleContent {
    static func normalized(_ data: JSONValue, kind: CalendarKind) -> JSONValue {
        guard case .object(var o) = data else { return data }
        o["calendarId"] = nil; o["tasklistId"] = nil
        if kind == .event {
            for key in ["location", "description", "colorId"] { o[key] = o[key] ?? "" }
            o["recurrence"] = o["recurrence"] ?? .array([])
            o["remindersMinutes"] = o["remindersMinutes"] ?? .array([])
            if o["allDay"]?.bool != true {
                for key in ["start", "end"] {
                    if let raw = o[key]?.string, let date = try? CalendarDates.parse(raw, zone: o["timeZone"]?.string ?? "Asia/Ho_Chi_Minh") { o[key] = .string(CalendarDates.iso(date)) }
                }
            }
        } else if kind == .task { o["notes"] = o["notes"] ?? ""; if o["due"] == .null { o["due"] = nil } }
        else { o["content"] = o["content"] ?? "" }
        return .object(o)
    }
    static func equal(_ a: JSONValue, _ b: JSONValue, kind: CalendarKind) -> Bool { normalized(a, kind: kind) == normalized(b, kind: kind) }
    static func dirty(_ record: CalendarRecord, _ link: GoogleLink) -> Bool { !equal(record.data, link.base, kind: record.kind) || record.deleted != link.baseDeleted }
}

actor GoogleWorkspace {
    let auth: GoogleAuth
    let store: DataStore
    let calendar: CalendarService
    let now: @Sendable () -> Date
    let notify: @Sendable (JSONValue) -> Void
    var busy = false
    /// Truy cập `auth` từ ngoài actor (let, nên an toàn).
    nonisolated var googleAuth: GoogleAuth { auth }
    var firstDirty: Date?, lastDirty: Date?, nextAttempt: Date?
    var lastSignature = ""
    var retryCount = 0
    init(auth: GoogleAuth, store: DataStore, calendar: CalendarService, now: @escaping @Sendable () -> Date = { Date() }, notify: @escaping @Sendable (JSONValue) -> Void = { _ in }) {
        self.auth = auth; self.store = store; self.calendar = calendar; self.now = now; self.notify = notify
    }
    func owner() async throws -> String { guard let c = try await auth.credentials() else { throw PVTAError("Chưa đăng nhập Google.") }; return c.subject }
    func collection(_ kind: CalendarKind, account: GoogleAccount) -> String? {
        switch kind { case .event: account.calendarId; case .task: account.tasklistId; case .note: account.notes ? "pvta-notes" : nil }
    }
    func status() async throws -> JSONValue {
        let authState = try await auth.status()
        guard let owner = authState["accountId"]?.string else { return ["auth": authState, "state": "disconnected"] }
        let account = try await store.googleState().accounts[owner] ?? GoogleAccount()
        let local = try await store.calendarState()
        let pending = local.records.values.filter { r in
            guard r.owner == owner, let selected = collection(r.kind, account: account) else { return false }
            if let link = account.links[r.localId] { return link.collection == selected && GoogleContent.dirty(r, link) }; return !r.deleted
        }.count
        let conflicts: [JSONValue] = try account.links.values.filter { $0.state == "conflict" }.sorted { $0.localId < $1.localId }.map { link in
            ["localId": .string(link.localId), "local": try JSONValue(encoding: local.records[link.localId]), "remote": try JSONValue(encoding: link.conflict), "remoteStamp": link.conflict.map { .string($0.stamp) } ?? .null]
        }
        let errors = account.links.values.filter { $0.error != nil }.sorted { $0.localId < $1.localId }.map { ["localId": JSONValue.string($0.localId), "state": .string($0.state), "message": .string($0.error!)] }
        return ["auth": authState, "state": .string(busy ? "syncing" : !conflicts.isEmpty ? "conflict" : account.lastError != nil ? "error" : pending > 0 ? "waiting" : "idle"), "enabled": .bool(account.enabled), "calendarId": account.calendarId.map(JSONValue.string) ?? .null, "tasklistId": account.tasklistId.map(JSONValue.string) ?? .null, "notes": .bool(account.notes), "pending": .number(Double(pending)), "conflicts": .array(conflicts), "errors": try JSONValue(encoding: errors), "lastSynced": account.lastSynced.map(JSONValue.number) ?? .null, "error": account.lastError.map(JSONValue.string) ?? .null, "nextAttempt": nextAttempt.map { .number($0.timeIntervalSince1970) } ?? .null]
    }
    func catalogs() async throws -> JSONValue {
        let id = try await owner(), api = GoogleAPI(auth: auth, owner: id)
        return ["calendars": .array(try await api.collections(kind: .event)), "tasklists": .array(try await api.collections(kind: .task))]
    }
    func select(calendarId: String?, tasklistId: String?, notes: Bool, enabled: Bool, confirmed: Bool) async throws -> JSONValue {
        guard confirmed, !busy else { throw PVTAError("Cần xác nhận đích đồng bộ khi không có lượt đang chạy.") }
        let id = try await owner(), api = GoogleAPI(auth: auth, owner: id)
        if let calendarId { guard try await api.collections(kind: .event).contains(where: { $0["id"]?.string == calendarId }) else { throw PVTAError("Không có quyền ghi lịch đã chọn.") } }
        if let tasklistId { guard try await api.collections(kind: .task).contains(where: { $0["id"]?.string == tasklistId }) else { throw PVTAError("Không tìm thấy danh sách việc đã chọn.") } }
        guard try await owner() == id, !busy else { throw PVTAError("Phiên Google đã đổi.") }
        try await store.googleSelect(owner: id, calendarId: calendarId, tasklistId: tasklistId, notes: notes, enabled: enabled)
        firstDirty = nil; lastDirty = nil; nextAttempt = nil; lastSignature = ""; retryCount = 0
        return try await status()
    }
    static func safeError(_ error: Error) -> String {
        if let http = error as? GoogleHTTPError { return "Google trả mã \(http.status). Thay đổi cục bộ được giữ để kiểm tra/thử lại." }
        if let app = error as? PVTAError { return Redactor.clean(app.message) }
        // Không đưa body HTTP, URL token, hoặc lỗi mạng của thư viện vào nhật ký.
        return "Chưa đồng bộ được với Google; dữ liệu cục bộ vẫn được giữ. Kiểm tra kết nối và phiên đăng nhập."
    }
    func sync(confirmed: Bool = false, scheduled: Bool = false) async throws -> JSONValue {
        let id = try await owner()
        guard !busy else { throw PVTAError("Đang có một lượt đồng bộ Google.") }
        guard let initial = try await store.googleState().accounts[id], initial.enabled, confirmed || scheduled else { throw PVTAError("Chưa bật và xác nhận đồng bộ Google.") }
        busy = true; defer { busy = false }
        let api = GoogleAPI(auth: auth, owner: id)
        var failed = false
        do {
            for kind in [CalendarKind.event, .task, .note] {
                guard let target = collection(kind, account: initial) else { continue }
                let page = try await api.list(kind: kind, collection: target, cursor: kind == .event ? initial.cursor : nil)
                try await store.googleMerge(owner: id, kind: kind, collection: target, items: page.items, full: page.full, cursor: page.cursor)
            }
            let local = try await store.calendarState()
            for record in local.records.values.sorted(by: { $0.localId < $1.localId }) where record.owner == id {
                guard let target = collection(record.kind, account: initial) else { continue }
                let currentAccount = try await store.googleState().accounts[id]!
                var existing = currentAccount.links[record.localId]
                if let link = existing, link.collection != target { continue }
                if existing == nil && record.deleted { continue }
                if let link = existing, link.state == "conflict" || !GoogleContent.dirty(record, link) { continue }
                if existing == nil { existing = try await store.googleBind(owner: id, id: record.localId, kind: record.kind, collection: target, remoteId: nil) }
                var link = existing!
                do {
                    let create = link.base == .null && !link.baseDeleted
                    if create && record.deleted && link.state != "creating" && link.state != "uncertain" {
                        link.base = record.data; link.baseDeleted = true; link.state = "clean"; try await store.googleSetLink(owner: id, link: link); continue
                    }
                    if create, let remoteId = link.remoteId {
                        let found = try await api.get(kind: record.kind, collection: target, id: remoteId)
                        if !found.deleted {
                            if GoogleContent.equal(found.data, record.data, kind: record.kind), !record.deleted { try await store.googleAcknowledge(owner: id, sent: record, remote: found, link: link); continue }
                            link.state = "conflict"; link.conflict = found; link.error = "Mã Google đã có nội dung khác; cần đối chiếu."
                            try await store.googleSetLink(owner: id, link: link); continue
                        }
                    }
                    if create && record.kind == .task && ["creating", "uncertain"].contains(link.state) {
                        link.state = "uncertain"; link.error = "Lượt tạo việc trước chưa rõ kết quả. Chưa tìm thấy dấu PVTA trên Google; cần kiểm tra trước khi thử tạo lại."
                        try await store.googleSetLink(owner: id, link: link); failed = true; continue
                    }
                    if !create, let remoteId = link.remoteId {
                        let fresh = try await api.get(kind: record.kind, collection: target, id: remoteId)
                        if fresh.deleted != link.baseDeleted || (!fresh.deleted && !GoogleContent.equal(fresh.data, link.base, kind: record.kind)) {
                            try await store.googleMerge(owner: id, kind: record.kind, collection: target, items: [fresh], full: false); continue
                        }
                        link.etag = fresh.etag
                        if record.deleted && fresh.deleted { try await store.googleAcknowledge(owner: id, sent: record, remote: fresh, link: link); continue }
                        guard link.etag != nil else { throw PVTAError("Google chưa trả etag; không ghi đè khi chưa kiểm được phiên bản.") }
                    }
                    if create && link.remoteId == nil { link.remoteId = try await api.allocate(link) }
                    link.state = create ? "creating" : "pending"; link.error = nil
                    try await store.googleSetLink(owner: id, link: link) // Giữ mã trước khi gửi để khôi phục khi mất phản hồi.
                    let response = try await api.write(record, link: link, create: create)
                    try await store.googleAcknowledge(owner: id, sent: record, remote: response, link: link)
                } catch let error as GoogleHTTPError where error.status == 412 || error.status == 409 {
                    if let remoteId = link.remoteId {
                        let remote = try await api.get(kind: record.kind, collection: target, id: remoteId)
                        link.state = "conflict"; link.conflict = remote; link.error = "Google đổi trong lúc ghi; cần đối chiếu."
                        try await store.googleSetLink(owner: id, link: link)
                    } else { link.state = "uncertain"; link.error = "Kết quả tạo việc chưa rõ; cần kiểm tra Google."; try await store.googleSetLink(owner: id, link: link) }
                    failed = true
                } catch {
                    link.state = link.state == "creating" && record.kind == .task ? "uncertain" : "error"; link.error = Self.safeError(error)
                    try await store.googleSetLink(owner: id, link: link); failed = true
                }
            }
            try await store.googleSyncResult(owner: id, error: failed ? "Một số mục chưa đồng bộ; xem lỗi và xung đột." : nil)
        } catch {
            failed = true
            try await store.googleSyncResult(owner: id, error: Self.safeError(error))
        }
        if failed { retryCount += 1; nextAttempt = now().addingTimeInterval([30.0, 60, 120, 300, 900][min(retryCount - 1, 4)]) }
        else { retryCount = 0; nextAttempt = nil }
        firstDirty = nil; lastDirty = nil; lastSignature = ""
        busy = false
        let result = try await status(); notify(result); return result
    }
    func resolve(id: String, baseRev: Int, stamp: String, choice: String, confirmed: Bool) async throws -> JSONValue {
        guard confirmed, !busy else { throw PVTAError("Cần xác nhận giải quyết xung đột khi không đang đồng bộ.") }
        let owner = try await owner()
        guard let link = try await store.googleState().accounts[owner]?.links[id], let remoteId = link.remoteId else { throw PVTAError("Không tìm thấy xung đột Google.") }
        let remote = try await GoogleAPI(auth: auth, owner: owner).get(kind: link.kind, collection: link.collection, id: remoteId)
        guard !busy else { throw PVTAError("Đồng bộ đã bắt đầu; hãy đối chiếu lại.") }
        let applied = try await store.googleResolve(owner: owner, id: id, baseRev: baseRev, stamp: stamp, choice: choice, remote: remote)
        return ["resolved": .bool(applied), "status": try await status()]
    }
    func retryCreate(id: String, confirmed: Bool) async throws {
        guard confirmed, !busy else { throw PVTAError("Cần kiểm tra Google và xác nhận thử tạo lại.") }
        let owner = try await owner()
        guard var link = try await store.googleState().accounts[owner]?.links[id], link.state == "uncertain", link.remoteId == nil else { throw PVTAError("Mục không ở trạng thái tạo chưa rõ kết quả.") }
        link.state = "pending"; link.error = nil; try await store.googleSetLink(owner: owner, link: link)
    }
    func tick() async {
        guard !busy, let owner = try? await owner(), let account = try? await store.googleState().accounts[owner], account.enabled,
              let local = try? await store.calendarState() else { return }
        let dirty = local.records.values.filter { r in
            guard r.owner == owner, let target = collection(r.kind, account: account) else { return false }
            if let link = account.links[r.localId] { return link.collection == target && link.state != "conflict" && link.state != "uncertain" && GoogleContent.dirty(r, link) }; return !r.deleted
        }.sorted { $0.localId < $1.localId }
        let signature = dirty.map { "\($0.localId):\($0.rev)" }.joined(separator: ",")
        if !signature.isEmpty && signature != lastSignature { if firstDirty == nil { firstDirty = now() }; lastDirty = now(); lastSignature = signature }
        if let nextAttempt, now() < nextAttempt { return }
        let due = firstDirty.map { first in min(first.addingTimeInterval(120), (lastDirty ?? first).addingTimeInterval(30)) <= now() } ?? false
        let pullDue = now().timeIntervalSince1970 - (account.lastSynced ?? 0) >= 300
        if due || pullDue || nextAttempt != nil { _ = try? await sync(scheduled: true) }
    }
}
