import Foundation
import Testing
@testable import PVTACore

/// Máy chủ REST giả có dữ liệu, ETag, phân trang và lỗi mạng; tuyệt đối không ra Google thật.
private actor GoogleServer: HTTPTransport {
    var records: [String: [String: JSONValue]] = ["calendar": [:], "tasks": [:], "notes": [:]]
    var content: [String: String] = [:]
    var sent: [URLRequest] = []
    var sequence = 0
    var invalidCursor = false
    var failNextWrite = false
    var loseTaskReply = false
    var raceWrite = false
    var unauthorized = false
    var malformed = false
    var tokenGate: Gate?
    var writeGate: Gate?
    var writesStarted = 0
    func set(_ flag: String) { if flag == "410" { invalidCursor = true }; if flag == "failure" { failNextWrite = true }; if flag == "lost" { loseTaskReply = true }; if flag == "race" { raceWrite = true }; if flag == "401" { unauthorized = true }; if flag == "malformed" { malformed = true } }
    func holdToken(_ gate: Gate) { tokenGate = gate }
    func holdWrite(_ gate: Gate) { writeGate = gate }
    func stream(_ request: URLRequest) async throws -> HTTPResponseStream { throw PVTAError("Không dùng AI thật.") }
    func data(for request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) { try await download(request, limit: 4 * 1024 * 1024) }
    func put(_ kind: CalendarKind, id: String, title: String, deleted: Bool = false) {
        sequence += 1
        var v = records[kind.rawValue]?[id] ?? [:]
        guard case .object(var o) = v else { return }
        o["id"] = .string(id); o["etag"] = .string("v\(sequence)")
        if kind == .event {
            o["summary"] = .string(title); o["status"] = .string(deleted ? "cancelled" : "confirmed")
            o["start"] = ["dateTime": "2026-11-09T00:30:00Z", "timeZone": "Asia/Ho_Chi_Minh"]
            o["end"] = ["dateTime": "2026-11-09T01:15:00Z", "timeZone": "Asia/Ho_Chi_Minh"]
        } else if kind == .task { o["title"] = .string(title); o["status"] = "needsAction"; o["deleted"] = .bool(deleted) }
        else { o["name"] = .string(title + ".md"); o["trashed"] = .bool(deleted); o["appProperties"] = ["pvtaKind": "note"]; o["modifiedTime"] = .string("m\(sequence)"); content[id] = "Nội dung " + title }
        v = .object(o); records[kind.rawValue]![id] = v
    }
    func remove(_ kind: CalendarKind, _ id: String) { records[kind.rawValue]?[id] = nil }
    func exception(_ id: String) {
        guard case .object(var o)? = records["calendar"]?[id] else { return }
        o["recurringEventId"] = "parent"; records["calendar"]![id] = .object(o)
    }
    func value(_ kind: CalendarKind, _ id: String) -> JSONValue? { records[kind.rawValue]?[id] }
    func count(_ kind: CalendarKind) -> Int { records[kind.rawValue]!.count }
    func download(_ request: URLRequest, limit: Int) async throws -> (status: Int, headers: [String: String], body: Data) {
        sent.append(request)
        let url = request.url!, path = url.path, method = request.httpMethod ?? "GET"
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        func reply(_ json: JSONValue, status: Int = 200, headers: [String: String] = [:]) throws -> (Int, [String: String], Data) { (status, headers, try JSONEncoder().encode(json)) }
        if path == "/token" {
            if let tokenGate { await tokenGate.wait() }
            return try reply(["access_token": "ACCESS-SECRET-32", "refresh_token": "REFRESH-SECRET-32", "expires_in": 3600, "scope": .string(GoogleAuth.scopes)])
        }
        if path == "/v1/userinfo" { return try reply(["sub": "owner-a", "email": "teacher@example.invalid"]) }
        if unauthorized { unauthorized = false; return try reply([:], status: 401) }
        if malformed { malformed = false; return (200, [:], Data("not-json".utf8)) }
        if path.hasSuffix("calendarList") { return try reply(["items": [["id": "cal-a", "summary": "Dạy học", "accessRole": "owner"], ["id": "readonly", "summary": "Chỉ xem", "accessRole": "reader"]]]) }
        if path.hasSuffix("/@me/lists") { return try reply(["items": [["id": "list-a", "title": "Công việc"]]]) }
        if path.hasSuffix("generateIds") { sequence += 1; return try reply(["ids": [.string("drive-\(sequence)")]]) }
        let kind: CalendarKind = path.contains("/calendar/") ? .event : path.contains("/tasks/") ? .task : .note
        let tail = kind == .event ? "events" : kind == .task ? "tasks" : "files"
        let isCollection = path.hasSuffix("/" + tail)
        var id = isCollection ? "" : path.components(separatedBy: "/").last!
        if method == "GET" && isCollection {
            if kind == .event && invalidCursor && q["syncToken"] != nil { invalidCursor = false; return try reply([:], status: 410) }
            let all = records[kind.rawValue]!.values.sorted { ($0["id"]?.string ?? "") < ($1["id"]?.string ?? "") }
            // Hai mục mỗi trang, kể cả khi đang lấy thay đổi; gửi lặp item hợp lệ như API incremental.
            let offset = Int(q["pageToken"] ?? "0") ?? 0
            var out: [String: JSONValue] = [kind == .note ? "files" : "items": .array(Array(all.dropFirst(offset).prefix(2)))]
            if offset + 2 < all.count { out["nextPageToken"] = .string("\(offset + 2)") }
            else if kind == .event { out["nextSyncToken"] = .string("cursor-\(sequence)") }
            return try reply(.object(out))
        }
        if method == "GET" {
            guard let v = records[kind.rawValue]?[id] else { return try reply([:], status: 404) }
            if q["alt"] == "media" { return (200, [:], Data((content[id] ?? "").utf8)) }
            return try reply(v, headers: ["etag": v["etag"]!.string!])
        }
        writesStarted += 1
        if let writeGate { await writeGate.wait() }
        if failNextWrite { failNextWrite = false; return try reply(["error": "ACCESS-SECRET-32 REFRESH-SECRET-32"], status: 503) }
        var payload: JSONValue
        if kind == .note && path.contains("/upload/") {
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            let boundary = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=")[1]
            let parts = body.components(separatedBy: "--" + boundary)
            payload = try JSONDecoder().decode(JSONValue.self, from: Data(parts[1].components(separatedBy: "\r\n\r\n")[1].trimmingCharacters(in: .newlines).utf8))
            if method == "POST" { id = payload["id"]!.string! }
            var text = parts[2].components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            if text.hasSuffix("\r\n") { text = String(text.dropLast()) }
            // Áp dụng nội dung sau khi kiểm If-Match bên dưới.
            if request.value(forHTTPHeaderField: "If-Match") == nil || request.value(forHTTPHeaderField: "If-Match") == records["notes"]?[id]?["etag"]?.string { content[id] = text }
        } else { payload = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? [:] }
        if method == "POST", kind != .note { id = payload["id"]?.string ?? "task-\(sequence + 1)" }
        if raceWrite, method != "POST" { raceWrite = false; put(kind, id: id, title: "Sửa ngay trước ghi") }
        if let match = request.value(forHTTPHeaderField: "If-Match"), match != records[kind.rawValue]?[id]?["etag"]?.string { return try reply([:], status: 412) }
        if method == "POST" && records[kind.rawValue]?[id] != nil { return try reply([:], status: 409) }
        if method == "DELETE" { put(kind, id: id, title: "Đã xóa", deleted: true); return (204, [:], Data()) }
        sequence += 1
        var o: [String: JSONValue] = [:]
        if case .object(let previous)? = records[kind.rawValue]?[id] { o = previous }
        if case .object(let fields) = payload { o.merge(fields) { _, new in new } }
        o["id"] = .string(id); o["etag"] = .string("v\(sequence)")
        if kind == .note { o["modifiedTime"] = .string("m\(sequence)") }
        records[kind.rawValue]![id] = .object(o)
        if loseTaskReply && kind == .task && method == "POST" { loseTaskReply = false; throw PVTAError("Mất phản hồi ACCESS-SECRET-32") }
        return try reply(.object(o))
    }
}

private final class GoogleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private struct GoogleEnv {
    let root: URL
    let core: Core
    let keys: MemoryKeyStore
    let server: GoogleServer
    init(signedIn: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("google32-" + UUID().uuidString)
        let paths = DataPaths(home: root); try paths.prepare()
        keys = MemoryKeyStore(); server = GoogleServer()
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: server, retry: .none, cli: Gia().moi(), opener: { _ in })
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: root, hostActions: HostActions(trash: { $0 }, open: { _, _ in }))
        try await core.google.auth.configure(clientId: "fake.apps.googleusercontent.com", secret: "CLIENT-SECRET-32")
        if signedIn { try await signIn("owner-a"); _ = try await core.google.select(calendarId: "cal-a", tasklistId: "list-a", notes: true, enabled: true, confirmed: true) }
    }
    func signIn(_ owner: String, expires: Double = Date().timeIntervalSince1970 + 3600) async throws {
        try keys.save(String(decoding: JSONEncoder().encode(GoogleCredentials(access: "ACCESS-SECRET-32", refresh: "REFRESH-SECRET-32", expires: expires, subject: owner, email: "test@example.invalid")), as: UTF8.self), provider: "google-oauth")
        try await core.store.setSetting("google.activeOwner", owner)
    }
    func files() -> [URL] { FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects.compactMap { $0 as? URL } }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func call(_ name: String, _ p: JSONValue = [:]) async throws -> JSONValue { try await core.dispatch(name, p, scoped: { _, _ in }) }
    func sync() async throws -> JSONValue { try await call("google.syncNow", ["confirmed": true]) }
    func data(_ kind: CalendarKind, _ title: String) -> JSONValue {
        switch kind {
        case .event: ["summary": .string(title), "start": "2026-11-09T07:30:00+07:00", "end": "2026-11-09T08:15:00+07:00"]
        case .task: ["title": .string(title), "due": "2026-11-10", "notes": "Nội dung", "done": false]
        case .note: ["title": .string(title), "content": .string("Nội dung " + title)]
        }
    }
    func save(_ kind: CalendarKind, _ title: String, old: CalendarRecord? = nil) async throws -> CalendarRecord { try await core.calendar.save(kind: kind, id: old?.localId, baseRev: old?.rev ?? 0, data: data(kind, title)).records[0] }
    func link(_ id: String) async throws -> GoogleLink { try #require(await core.store.googleState().accounts["owner-a"]?.links[id]) }
}

@Test func google32HaiChieuThemSuaXoaBaLoai() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    for kind in [CalendarKind.event, .task, .note] {
        let local = try await e.save(kind, "Tạo ở máy")
        _ = try await e.sync()
        let link = try await e.link(local.localId), remoteId = try #require(link.remoteId)
        #expect(link.state == "clean")
        let updated = try await e.save(kind, "Sửa ở máy", old: local)
        _ = try await e.sync()
        #expect(await e.server.value(kind, remoteId)?[kind == .event ? "summary" : kind == .task ? "title" : "name"] == .string(kind == .note ? "Sửa ở máy.md" : "Sửa ở máy"))
        _ = try await e.core.calendar.delete(kind: kind, id: local.localId, baseRev: updated.rev, confirmed: true)
        _ = try await e.sync()
        let remote = try await GoogleAPI(auth: e.core.google.auth, owner: "owner-a").get(kind: kind, collection: link.collection, id: remoteId)
        #expect(remote.deleted)
        await e.server.put(kind, id: "remote-" + kind.rawValue, title: "Tạo ở Google")
        _ = try await e.sync()
        let imported = try #require(await e.core.store.calendarState().records.values.first { $0.kind == kind && !$0.deleted })
        #expect(imported.owner == "owner-a")
        await e.server.put(kind, id: "remote-" + kind.rawValue, title: "Sửa ở Google")
        _ = try await e.sync()
        #expect(try await e.core.calendar.get(imported.localId, kind: kind).data[kind == .event ? "summary" : "title"] == "Sửa ở Google")
        await e.server.put(kind, id: "remote-" + kind.rawValue, title: "Xóa ở Google", deleted: true)
        _ = try await e.sync()
        #expect(try await e.core.calendar.get(imported.localId, kind: kind).deleted)
    }
    #expect(try await e.call("google.status")["pending"] == 0)
}

@Test func google32XungDotGiuMayGiuGoogleVaBanDoiChieuCu() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    for kind in [CalendarKind.event, .task, .note] {
        let r = try await e.save(kind, "Gốc"); _ = try await e.sync()
        let remoteId = try #require(await e.link(r.localId).remoteId)
        let local = try await e.save(kind, "Bản máy", old: r)
        await e.server.put(kind, id: remoteId, title: "Bản Google"); _ = try await e.sync()
        let conflict = try #require(await e.link(r.localId).conflict)
        #expect(try await e.core.calendar.get(r.localId, kind: kind).data == local.data)
        await #expect(throws: PVTAError.self) { try await e.core.google.resolve(id: r.localId, baseRev: 1, stamp: conflict.stamp, choice: "keep-remote", confirmed: true) }
        await e.server.put(kind, id: remoteId, title: "Google đổi lần nữa")
        #expect(try await e.core.google.resolve(id: r.localId, baseRev: local.rev, stamp: conflict.stamp, choice: "keep-remote", confirmed: true)["resolved"] == false)
        let fresh = try #require(await e.link(r.localId).conflict)
        #expect(try await e.core.google.resolve(id: r.localId, baseRev: local.rev, stamp: fresh.stamp, choice: "keep-local", confirmed: true)["resolved"] == true)
        _ = try await e.sync(); #expect(try await e.link(r.localId).state == "clean")
        let current = try await e.core.calendar.get(r.localId, kind: kind)
        let edited = try await e.save(kind, "Lại sửa máy", old: current)
        await e.server.put(kind, id: remoteId, title: "Chọn bản Google"); _ = try await e.sync()
        let last = try #require(await e.link(r.localId).conflict)
        _ = try await e.core.google.resolve(id: r.localId, baseRev: edited.rev, stamp: last.stamp, choice: "keep-remote", confirmed: true)
        #expect(try await e.core.calendar.get(r.localId, kind: kind).data[kind == .event ? "summary" : "title"] == "Chọn bản Google")
    }
}

@Test func google32PhanTrang410VaMatPhanHoiKhongTaoTrung() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    for i in 0..<5 { await e.server.put(.event, id: "event-\(i)", title: "Tiết \(i)") }
    _ = try await e.sync(); #expect(try await e.core.store.calendarState().records.count == 5)
    await e.server.set("410"); _ = try await e.sync()
    #expect(try await e.core.store.calendarState().records.count == 5)
    #expect(await e.server.sent.contains { $0.url?.query?.contains("pageToken=") == true })
    let task = try await e.save(.task, "Chỉ một việc")
    await e.server.set("lost"); _ = try await e.sync()
    #expect(try await e.link(task.localId).state == "uncertain")
    _ = try await e.sync()
    #expect(await e.server.count(.task) == 1)
    #expect(try await e.link(task.localId).state == "clean")
}

@Test func google32ETagChanGhiDeTrongLucGui() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let r = try await e.save(.event, "Gốc"); _ = try await e.sync()
    _ = try await e.save(.event, "Bản máy", old: r)
    await e.server.set("race"); _ = try await e.sync()
    #expect(try await e.link(r.localId).state == "conflict")
    #expect(try await e.core.calendar.get(r.localId, kind: .event).data["summary"] == "Bản máy")
    #expect(try await e.link(r.localId).conflict?.data["summary"] == "Sửa ngay trước ghi")
}

@Test func google32OAuthPKCEStateTokenKeychainVaDangXuat() async throws {
    let e = try await GoogleEnv(signedIn: false); defer { e.clean() }
    await #expect(throws: PVTAError.self) { try await e.call("google.login") }
    let begin = try await e.call("google.login", ["confirmed": true])
    let url = try #require(URLComponents(string: begin["authorizationURL"]!.string!))
    let q = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
    #expect(q["code_challenge_method"] == "S256" && q["code_challenge"]!.count == 43)
    #expect(q["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
    #expect(await e.core.google.auth.callback(q["redirect_uri"]! + "?code=test&state=wrong") == false)
    #expect(await e.server.sent.isEmpty)
    // Đi qua cổng loopback thật, chỉ mạng nội bộ; token và userinfo vẫn do máy chủ giả trả.
    let callback = URL(string: q["redirect_uri"]! + "?code=test&state=" + q["state"]!)!
    let (_, response) = try await URLSession.shared.data(from: callback)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try e.keys.read(provider: "google-oauth")?.contains("REFRESH-SECRET-32") == true)
    #expect(await e.core.google.auth.callback(callback.absoluteString) == false)
    let status = try await e.call("google.status")
    #expect(status["auth"]?["connected"] == true)
    let tokenRequest = try #require(await e.server.sent.first { $0.url?.path == "/token" })
    #expect(String(decoding: tokenRequest.httpBody!, as: UTF8.self).contains("code_verifier="))
    _ = try await e.call("google.logout")
    #expect(try e.keys.read(provider: "google-oauth") == nil)
    #expect(try await e.core.store.setting("google.activeOwner") == "")
    #expect(try await e.call("google.status")["state"] == "disconnected")
}

@Test func google32LoiKhongLoTokenVaTaiKhoanKhongTron() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let r = try await e.save(.task, "Riêng tài khoản A")
    await e.server.set("failure"); let status = try await e.sync()
    #expect(status["state"] == "error")
    let serialized = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
    #expect(!serialized.contains("SECRET-32"))
    await e.server.set("failure")
    await #expect(throws: Error.self) {
        try await e.core.track(kind: "google.test") {
            try await GoogleAPI(auth: e.core.google.auth, owner: "owner-a").request("https://tasks.googleapis.com/tasks/v1/lists/list-a/tasks", method: "POST", json: ["title": "Thử lỗi"])
        }
    }
    let log = try await e.core.store.activities()
    #expect(log.count == 1 && log[0].state == .error)
    #expect(!String(decoding: try JSONEncoder().encode(log), as: UTF8.self).contains("SECRET-32"))
    // Quét cả SQLite/WAL và mọi tệp dưới data home; không chỉ kiểm JSON trả RPC.
    for file in e.files() {
        if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let bytes = try Data(contentsOf: file)
            for secret in ["ACCESS-SECRET-32", "REFRESH-SECRET-32", "CLIENT-SECRET-32"] { #expect(bytes.range(of: Data(secret.utf8)) == nil) }
        }
    }
    _ = try await e.call("google.logout"); try await e.signIn("owner-b")
    _ = try await e.core.google.select(calendarId: "cal-a", tasklistId: "list-a", notes: false, enabled: true, confirmed: true)
    _ = try await e.sync()
    #expect(try await e.core.calendar.get(r.localId, kind: .task).owner == "owner-a")
    #expect(await e.server.count(.task) == 0)
}

@Test func google32DangXuatTrongLucRefreshKhongHoiSinhToken() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    try await e.signIn("owner-a", expires: 0)
    let gate = Gate(); await e.server.holdToken(gate)
    let refreshing = Task { try await e.core.google.auth.token(owner: "owner-a") }
    for _ in 0..<100 { if await e.server.sent.contains(where: { $0.url?.path == "/token" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
    try await e.core.google.auth.logout(); await gate.open()
    await #expect(throws: Error.self) { try await refreshing.value }
    #expect(try e.keys.read(provider: "google-oauth") == nil)
}

@Test func google32SuaTrongLucDangGuiVanConPending() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let r = try await e.save(.task, "Bản đầu")
    let gate = Gate(); await e.server.holdWrite(gate)
    let syncing = Task { try await e.sync() }
    for _ in 0..<100 { if await e.server.writesStarted > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    _ = try await e.save(.task, "Sửa khi đang gửi", old: r)
    await gate.open(); _ = try await syncing.value
    #expect(try await e.link(r.localId).state == "pending")
    _ = try await e.sync()
    #expect(try await e.link(r.localId).state == "clean")
    #expect(await e.server.count(.task) == 1)
}

@Test func google32RPCKhongVuotCongDuyetAI() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    #expect(e.core.methods.contains("google.aiCommand") && e.core.methods.contains("google.aiScanTimetable"))
    let p = try await e.core.calendar.makeProposal([["op": "create_task", "summary": "Đề xuất"]], reply: "Xem trước", snapshot: e.core.store.calendarState(), zone: "Asia/Ho_Chi_Minh", chatId: nil)
    await #expect(throws: PVTAError.self) { try await e.call("google.aiApplyOps", ["proposalId": .string(p.id)]) }
    #expect(try await e.core.store.calendarState().records.isEmpty)
    _ = try await e.call("google.aiApplyOps", ["proposalId": .string(p.id), "approved": true])
    #expect(try await e.core.store.calendarState().records.count == 1)
    await #expect(throws: PVTAError.self) { try await e.call("google.syncNow") }
    await #expect(throws: PVTAError.self) { try await e.core.google.select(calendarId: "readonly", tasklistId: nil, notes: false, enabled: true, confirmed: true) }
}

@Test func google32DongBoNenGomThayDoiVaThuLai() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    _ = try await e.sync()
    let clock = GoogleClock()
    let worker = GoogleWorkspace(auth: e.core.google.googleAuth, store: e.core.store, calendar: e.core.calendar, now: { clock.now() })
    var r = try await e.save(.task, "Gom thay đổi")
    await worker.tick(); clock.advance(29); await worker.tick()
    #expect(await e.server.count(.task) == 0)
    r = try await e.save(.task, "Đang sửa tiếp", old: r)
    await worker.tick(); clock.advance(29); await worker.tick()
    #expect(await e.server.count(.task) == 0)
    clock.advance(1); await worker.tick()
    #expect(await e.server.count(.task) == 1)
    r = try await e.save(.task, "Thử lại khi mạng lỗi", old: r)
    await worker.tick(); clock.advance(30); await e.server.set("failure"); await worker.tick()
    let failedCount = await e.server.sent.count
    clock.advance(29); await worker.tick()
    #expect(await e.server.sent.count == failedCount)
    clock.advance(1); await worker.tick()
    #expect(try await e.link(r.localId).state == "clean")
}

@Test func google32Refresh401VaDuLieuLoiKhongXoaKho() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let r = try await e.save(.task, "Giữ dữ liệu"); _ = try await e.sync()
    await e.server.set("401")
    _ = try await e.core.google.catalogs()
    #expect(await e.server.sent.filter { $0.url?.path == "/token" }.count == 1)
    #expect(try e.keys.read(provider: "google-oauth")?.contains("REFRESH-SECRET-32") == true)
    // Chỉ chọn Tasks để kiểm phản hồi không phải JSON ở lượt lấy danh sách đầy đủ.
    _ = try await e.core.google.select(calendarId: nil, tasklistId: "list-a", notes: false, enabled: true, confirmed: true)
    await e.server.set("malformed"); let status = try await e.sync()
    #expect(status["state"] == "error")
    #expect(try await e.core.calendar.get(r.localId, kind: .task).deleted == false)
    let reopened = try DataStore(file: DataPaths(home: e.root).database)
    #expect(try await reopened.googleState().accounts["owner-a"]?.links[r.localId]?.remoteId != nil)
    #expect(try await reopened.calendarState().records[r.localId]?.data["title"] == "Giữ dữ liệu")
}

@Test func google32GhiChuRPCVaTroGiup() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let note = try await e.call("google.saveNote", ["data": ["title": "Ghi chú", "content": "# Bài học\n\nNội dung\n"]]).decode(CalendarWriteResult.self).records[0]
    _ = try await e.sync()
    let link = try await e.link(note.localId)
    #expect(await e.server.content[link.remoteId!] == "# Bài học\n\nNội dung\n")
    #expect(try await e.call("google.listNotes").decode([CalendarRecord].self).count == 1)
    await #expect(throws: PVTAError.self) { try await e.call("google.deleteNote", ["localId": .string(note.localId), "baseRev": 1]) }
    _ = try await e.call("google.deleteNote", ["localId": .string(note.localId), "baseRev": 1, "confirmed": true])
    #expect(try await e.call("google.listNotes") == .array([]))
    #expect(e.core.help.chapter("google-dong-bo")?.body.contains("Keychain") == true)
}

@Test func google32XungDotXoaVaSuaKhongLamMatBanMay() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    for kind in [CalendarKind.event, .task, .note] {
        let r = try await e.save(kind, "Gốc"); _ = try await e.sync()
        let remoteId = try #require(await e.link(r.localId).remoteId)
        let changed = try await e.save(kind, "Giữ bản máy", old: r)
        await e.server.put(kind, id: remoteId, title: "Đã xóa", deleted: true)
        _ = try await e.sync()
        let conflict = try #require(await e.link(r.localId).conflict)
        #expect(conflict.deleted)
        #expect(try await e.core.calendar.get(r.localId, kind: kind).deleted == false)
        _ = try await e.core.google.resolve(id: r.localId, baseRev: changed.rev, stamp: conflict.stamp, choice: "keep-local", confirmed: true)
        _ = try await e.sync()
        #expect(try await e.link(r.localId).state == "clean")
        #expect(try await e.link(r.localId).remoteId != remoteId)
    }
}

@Test func google32KhongBoQuaLanLapSuaRiengVaFullSyncNhanXoa() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    await e.server.put(.event, id: "original", title: "Giữ lịch")
    _ = try await e.sync()
    let record = try #require(await e.core.store.calendarState().records.values.first)
    let cursor = try await e.core.store.googleState().accounts["owner-a"]?.cursor
    await e.server.put(.event, id: "exception", title: "Lần lặp sửa riêng"); await e.server.exception("exception")
    let status = try await e.sync()
    #expect(status["state"] == "error")
    #expect(try await e.core.store.googleState().accounts["owner-a"]?.cursor == cursor)
    #expect(try await e.core.store.calendarState().records.count == 1)
    await e.server.remove(.event, "exception"); await e.server.remove(.event, "original"); await e.server.set("410")
    _ = try await e.sync()
    #expect(try await e.core.calendar.get(record.localId, kind: .event).deleted)
}

@Test func google32TaoViecChuaRoCanXacNhanTruocThuLai() async throws {
    let e = try await GoogleEnv(); defer { e.clean() }
    let task = try await e.save(.task, "Chưa gửi được")
    await e.server.set("failure"); _ = try await e.sync()
    #expect(try await e.link(task.localId).state == "uncertain")
    _ = try await e.sync(); #expect(await e.server.count(.task) == 0)
    await #expect(throws: PVTAError.self) { try await e.core.google.retryCreate(id: task.localId, confirmed: false) }
    _ = try await e.call("google.retryPendingCreate", ["localId": .string(task.localId), "confirmed": true])
    _ = try await e.sync(); #expect(await e.server.count(.task) == 1)
}
