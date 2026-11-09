import Foundation
import Testing
@testable import PVTACore

private actor GitHubServer: HTTPTransport {
    var requests: [URLRequest] = []
    var head = String(repeating: "a", count: 40)
    let tree = String(repeating: "b", count: 40)
    let newCommit = String(repeating: "c", count: 40)
    var writable = true
    var malformedTree = false
    var lostPatch = false
    var gate: Gate?
    var holdPath: String?
    var entries: [GitHubFile] = []
    var blobs: [String: Data] = [:]
    var proposedTree: JSONValue?
    var loginError = false
    func stream(_ request: URLRequest) async throws -> HTTPResponseStream { throw PVTAError("Không dùng AI thật.") }
    func data(for request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) { try await download(request, limit: 32 * 1024 * 1024) }
    func set(_ flag: String) {
        switch flag { case "head": head = String(repeating: "d", count: 40); case "permission": writable = false; case "truncated": malformedTree = true; case "lost": lostPatch = true; case "login": loginError = true; default: break }
    }
    func hold(_ path: String, _ gate: Gate) { holdPath = path; self.gate = gate }
    func add(_ path: String, text: String, mode: String = "100644") {
        let data = Data(text.utf8), sha = GitHubService.blobHash(data)
        entries.append(GitHubFile(path: path, sha: sha, size: data.count, mode: mode)); blobs[sha] = data
    }
    func corruptBlobs() { for key in blobs.keys { blobs[key] = Data("Sai".utf8) } }
    func mutations() -> Int { requests.filter { ($0.httpMethod ?? "GET") != "GET" }.count }
    func download(_ request: URLRequest, limit: Int) async throws -> (status: Int, headers: [String: String], body: Data) {
        requests.append(request)
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        func reply(_ value: JSONValue, status: Int = 200) throws -> (Int, [String: String], Data) { (status, [:], try JSONEncoder().encode(value)) }
        if path == "/user" {
            if loginError { return try reply(["message": "ghp_SUPER_SECRET_TEST_TOKEN_1234567890"], status: 401) }
            return try reply(["login": "teacher", "id": 123])
        }
        if path == "/repos/teacher/lessons" { return try reply(["permissions": ["push": .bool(writable)], "private": true, "default_branch": "main"]) }
        if method == "GET", path.contains("/git/ref/heads/") { return try reply(["object": ["sha": .string(head)]]) }
        if method == "GET", path.contains("/git/commits/") { return try reply(["sha": .string(head), "tree": ["sha": .string(tree)]]) }
        if method == "GET", path.contains("/git/trees/") {
            return try reply(["truncated": .bool(malformedTree), "tree": .array(entries.map { ["path": .string($0.path), "sha": .string($0.sha), "size": .number(Double($0.size)), "mode": .string($0.mode), "type": "blob"] })])
        }
        if method == "GET", path.contains("/git/blobs/") {
            guard let data = blobs[path.components(separatedBy: "/").last!] else { return try reply([:], status: 404) }
            return try reply(["encoding": "base64", "content": .string(data.base64EncodedString())])
        }
        if path.hasSuffix("/branches") { return try reply([["name": "main"]]) }
        if path.hasSuffix("/commits"), method == "GET" { return try reply([["sha": .string(head)]]) }
        if let holdPath, path.hasSuffix(holdPath), let gate { await gate.wait() }
        if path.hasSuffix("/git/blobs"), method == "POST" {
            let data = Data(base64Encoded: body["content"]!.string!)!, sha = GitHubService.blobHash(data); blobs[sha] = data
            return try reply(["sha": .string(sha)], status: 201)
        }
        if path.hasSuffix("/git/trees"), method == "POST" { proposedTree = body; return try reply(["sha": .string(tree)], status: 201) }
        if path.hasSuffix("/git/commits"), method == "POST" { return try reply(["sha": .string(newCommit)], status: 201) }
        if path.contains("/git/refs/heads/"), method == "PATCH" {
            guard body["force"] == false else { return try reply([:], status: 422) }
            head = body["sha"]!.string!
            if lostPatch { lostPatch = false; throw PVTAError("Mất phản hồi ghp_SUPER_SECRET_TEST_TOKEN_1234567890") }
            return try reply(["object": ["sha": .string(head)]])
        }
        if path.hasSuffix("/git/refs"), method == "POST" { return try reply(["ref": body["ref"]!], status: 201) }
        return try reply(["message": "Không có route giả"], status: 404)
    }
}

private struct GitHubEnv {
    let root: URL, folder: URL
    let paths: DataPaths
    let core: Core
    let server: GitHubServer
    let keys: MemoryKeyStore
    let project: String
    static let token = "ghp_SUPER_SECRET_TEST_TOKEN_1234567890"
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("github39-" + UUID().uuidString)
        folder = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        paths = DataPaths(home: root.appendingPathComponent("data")); try paths.prepare()
        server = GitHubServer(); keys = MemoryKeyStore()
        core = Core(store: try DataStore(file: paths.database), ai: AIClient(config: ConfigStore(paths: paths), keys: keys, transport: server, retry: .none, cli: Gia().moi()), approvalTimeout: .seconds(5))
        project = try await core.store.createProject(name: "Bài giảng").id
        _ = try await core.permissions.addGrant(path: folder.path, write: true)
        _ = try await core.google.status() // Cùng lõi nhưng không dùng phiên Google.
        _ = try await core.github.login(token: Self.token, confirmed: true)
        _ = try await core.github.link(project: project, folder: folder.path, repository: "teacher/lessons", branch: "main", confirmed: true)
        try "Bản một".write(to: folder.appendingPathComponent("lesson.txt"), atomically: true, encoding: .utf8)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ p: JSONValue = [:]) async throws -> JSONValue { try await core.dispatch(method, p, scoped: { _, _ in }) }
    func preview(_ op: String = "uploadSelected", paths: [String] = ["lesson.txt"]) async throws -> JSONValue {
        try await call("github.preview", ["operation": .string(op), "projectId": .string(project), "paths": .array(paths.map(JSONValue.string)), "message": "Cập nhật bài giảng", "newBranch": "lesson/new", "destination": .string(folder.appendingPathComponent("download").path), "confirmed": true])
    }
    func args(_ preview: JSONValue, request: String = UUID().uuidString) -> JSONValue { ["previewId": preview["id"]!, "requestId": .string(request), "chatId": "github-test", "confirmation": preview["confirmation"]!] }
    func pending() async throws -> ActionProposal {
        for _ in 0..<200 {
            if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PVTAError("Không có yêu cầu duyệt GitHub.")
    }
    func wait(_ id: String) async throws -> JSONValue {
        for _ in 0..<400 {
            let v = try await call("github.runStatus", ["runId": .string(id)])
            if v["state"]?.string != "running" { return v }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PVTAError("Lượt GitHub giả chưa kết thúc.")
    }
    func run(_ preview: JSONValue, approve: Bool = true) async throws -> JSONValue {
        let id = try await call("github.run", args(preview)).requireString("runId")
        let p = try await pending()
        if approve { try await core.permissions.queue.approve(id: p.id) } else { try await core.permissions.queue.decline(id: p.id) }
        return try await wait(id)
    }
}

@Test func github39XemTruocKhongCoTacDungPhuVaChayCanDuyet() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let before = try await e.core.store.exportJSON()
    let preview = try await e.preview()
    #expect(await e.server.mutations() == 0)
    #expect(try await e.core.store.exportJSON() == before)
    var args = e.args(preview)
    if case .object(var o) = args { o["confirmation"] = "sai"; args = .object(o) }
    await #expect(throws: PVTAError.self) { try await e.call("github.run", args) }
    let id = try await e.call("github.run", e.args(preview)).requireString("runId")
    let proposal = try await e.pending()
    #expect(await e.server.mutations() == 0)
    #expect(proposal.tool == "github_run")
    try await e.core.permissions.queue.decline(id: proposal.id)
    #expect(try await e.wait(id)["state"] == "error")
    #expect(await e.server.mutations() == 0)
}

@Test func github39UploadMotCommitGiuCayCuVaLichSuDayDu() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let preview = try await e.preview(), args = e.args(preview)
    let id = try await e.call("github.run", args).requireString("runId")
    #expect(try await e.call("github.run", args)["runId"] == .string(id))
    let p = try await e.pending(); try await e.core.permissions.queue.approve(id: p.id)
    let done = try await e.wait(id)
    #expect(done["state"] == "success" && done["effects"] == "applied")
    #expect(try done["steps"]?.decode([String].self).contains("branch-updated") == true)
    #expect(await e.server.mutations() == 4)
    #expect(await e.server.proposedTree?["base_tree"] == .string(e.server.tree))
    #expect(try await e.call("github.uploadHistory", ["projectId": .string(e.project)])["items"]?.decode([GitHubJournal].self).count == 1)
    #expect(try await e.call("github.run", args)["runId"] == .string(id))
    #expect(await e.server.mutations() == 4)
    await #expect(throws: PVTAError.self) { try await e.call("github.run", e.args(preview)) }
    let reopened = try DataStore(file: e.paths.database)
    #expect(try await reopened.githubState().journal[0].commit != nil)
    #expect(try await reopened.githubState().links[e.project]?.repository == "teacher/lessons")
}

@Test func github39BanCuQuyenCuVaNguonDoiBiChan() async throws {
    for reason in ["head", "permission", "source"] {
        let e = try await GitHubEnv(); defer { e.clean() }
        let p = try await e.preview()
        if reason == "source" { try "Đã sửa".write(to: e.folder.appendingPathComponent("lesson.txt"), atomically: true, encoding: .utf8) }
        else { await e.server.set(reason) }
        let done = try await e.run(p)
        #expect(done["state"] == "error" && done["effects"] == "none")
        #expect(await e.server.mutations() == 0)
    }
}

@Test func github39TaiXuongKiemBlobVaKhongGhiDe() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    await e.server.add("folder/a.txt", text: "Từ GitHub")
    let p = try await e.preview("downloadSelected", paths: ["folder"])
    #expect(!FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("download").path))
    let done = try await e.run(p)
    #expect(done["state"] == "success")
    let output = e.folder.appendingPathComponent("download/folder/a.txt")
    #expect(try String(contentsOf: output, encoding: .utf8) == "Từ GitHub")
    await #expect(throws: PVTAError.self) { try await e.preview("downloadSelected", paths: ["folder"]) }
    #expect(await e.server.mutations() == 0)
}

@Test func github39HuyVaMatPhanHoiKhongTuThuLai() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    var p = try await e.preview()
    let args = e.args(p), id = try await e.call("github.run", args).requireString("runId")
    _ = try await e.pending()
    #expect(try await e.call("github.cancel", ["runId": .string(id)])["accepted"] == true)
    #expect(try await e.wait(id)["state"] == "cancelled")
    #expect(await e.server.mutations() == 0)
    p = try await e.preview(); await e.server.set("lost")
    let done = try await e.run(p)
    #expect(done["state"] == "partial" && done["effects"] == "unknown")
    #expect(done["commit"] != .null)
    #expect(await e.server.mutations() == 4)
    #expect(!String(decoding: try JSONEncoder().encode(done), as: UTF8.self).contains(GitHubEnv.token))
}

@Test func github39HuyGiuaLucGuiGiuNhatKyChuaRo() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let gate = Gate(); await e.server.hold("/git/blobs", gate)
    let p = try await e.preview(), id = try await e.call("github.run", e.args(p)).requireString("runId")
    let proposal = try await e.pending(); try await e.core.permissions.queue.approve(id: proposal.id)
    for _ in 0..<200 { if await e.server.mutations() > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    _ = try await e.call("github.cancel", ["runId": .string(id)])
    await gate.open()
    let done = try await e.wait(id)
    #expect(done["state"] == "cancelled" && done["effects"] == "unknown")
    #expect(await e.server.mutations() == 1)
}

@Test func github39TokenChiTrongKhoKhoaVaDangXuatHuyPreview() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let p = try await e.preview()
    #expect(try e.keys.read(provider: "github-session")?.contains(GitHubEnv.token) == true)
    #expect(!String(decoding: try await e.core.store.exportJSON(), as: UTF8.self).contains(GitHubEnv.token))
    #expect(!String(decoding: try JSONEncoder().encode(await e.call("github.status")), as: UTF8.self).contains(GitHubEnv.token))
    _ = try await e.call("github.logout")
    #expect(try e.keys.read(provider: "github-session") == nil)
    await #expect(throws: PVTAError.self) { try await e.call("github.run", e.args(p)) }
    await e.server.set("login")
    await #expect(throws: PVTAError.self) { try await e.call("github.login", ["token": .string(GitHubEnv.token), "confirmed": true]) }
    #expect(try e.keys.read(provider: "github-session") == nil)
}

@Test func github39DuongDanSymlinkVaCayBiCatBiChan() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    for path in ["../secret", "/etc/passwd", ".git/config", "a/../../b"] {
        await #expect(throws: PVTAError.self) { try await e.preview(paths: [path]) }
    }
    try FileManager.default.createSymbolicLink(atPath: e.folder.appendingPathComponent("link.txt").path, withDestinationPath: e.folder.appendingPathComponent("lesson.txt").path)
    await #expect(throws: PVTAError.self) { try await e.preview(paths: ["link.txt"]) }
    await e.server.set("truncated")
    await #expect(throws: PVTAError.self) { try await e.preview("downloadSelected", paths: ["a"]) }
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.preview() }
}

@Test func github39DanhMucCacThaoTacDocVaTaoNhanh() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    for op in ["repository", "branches", "history", "browseFiles", "createBranch"] {
        let p = try await e.preview(op), done = try await e.run(p)
        #expect(done["state"] == "success")
    }
    #expect(await e.server.mutations() == 1)
    #expect(try await e.call("github.journal")["items"]?.decode([GitHubJournal].self).count == 5)
}

@Test func github39ThuMucThemTepSauXemTruocBiChan() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let dir = e.folder.appendingPathComponent("lessons")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    try Data("Một".utf8).write(to: dir.appendingPathComponent("one.txt"))
    let p = try await e.preview(paths: ["lessons"])
    try Data("Hai".utf8).write(to: dir.appendingPathComponent("two.txt"))
    let done = try await e.run(p)
    #expect(done["state"] == "error" && done["effects"] == "none")
    #expect(await e.server.mutations() == 0)
}

@Test func github39BlobSaiGiuNhatKyTaiDoVaKhongGhiTep() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    await e.server.add("folder/a.txt", text: "Đúng")
    let p = try await e.preview("downloadSelected", paths: ["folder"])
    await e.server.corruptBlobs()
    let done = try await e.run(p)
    #expect(done["state"] == "partial" && done["effects"] == "applied")
    #expect(done["finishedAt"] != nil)
    #expect(!FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("download/folder/a.txt").path))
    #expect(try await e.call("github.journal")["items"]?.decode([GitHubJournal].self).first?.state == "partial")
}

@Test func github39KhoiPhucNhatKyDangChayKhongTuGuiLai() async throws {
    let e = try await GitHubEnv(); defer { e.clean() }
    let request = UUID().uuidString, preview = UUID().uuidString, id = UUID().uuidString
    let row = GitHubJournal(id: id, requestId: request, previewId: preview, projectId: e.project, operation: "uploadSelected", repository: "teacher/lessons", branch: "main", startedAt: 0)
    try await e.core.store.githubRecord(row)
    let rows = try await e.call("github.journal")["items"]!.decode([GitHubJournal].self)
    #expect(rows.first?.state == "unknown" && rows.first?.effects == "unknown")
    #expect(rows.first?.finishedAt != nil)
    let retry = try await e.call("github.run", ["requestId": .string(request), "previewId": .string(preview), "chatId": "retry"])
    #expect(retry["runId"]?.string == id)
    #expect(await e.server.mutations() == 0)
}
