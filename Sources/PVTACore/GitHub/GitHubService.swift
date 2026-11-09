import Foundation
import CryptoKit

actor GitHubService {
    let store: DataStore
    let files: FileService
    let keys: KeyStore
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    let notify: @Sendable (JSONValue) -> Void
    var epoch = 0
    var previews: [String: (GitHubPreview, Int)] = [:]
    var tasks: [String: Task<Void, Never>] = [:]
    var locked = Set<String>()
    var claims: [String: (preview: String, run: String)] = [:]
    var used = Set<String>()
    var outputs: [String: JSONValue] = [:]
    var recovered = false
    init(store: DataStore, files: FileService, keys: KeyStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }, notify: @escaping @Sendable (JSONValue) -> Void = { _ in }) {
        self.store = store; self.files = files; self.keys = keys; self.transport = transport; self.now = now; self.notify = notify
    }
    func credential() throws -> GitHubCredential {
        guard let raw = try keys.read(provider: "github-session"), let value = try? JSONDecoder().decode(GitHubCredential.self, from: Data(raw.utf8)) else { throw PVTAError("Chưa đăng nhập GitHub.") }; return value
    }
    func clean(_ value: String) -> String {
        let token = (try? credential())?.token
        return Redactor.clean(token.map { value.replacingOccurrences(of: $0, with: Redactor.mask) } ?? value)
    }
    func status() async throws -> JSONValue {
        let c = try? credential()
        return ["connected": .bool(c != nil), "account": c.map { .string($0.account) } ?? .null, "links": try JSONValue(encoding: await store.githubState().links), "running": .array(tasks.keys.sorted().map(JSONValue.string))]
    }
    func login(token: String, confirmed: Bool) async throws -> JSONValue {
        guard confirmed, files.permissions.level() != .readOnly, tasks.isEmpty, token.count >= 10, token.count <= 1000, !token.contains(where: \.isWhitespace) else { throw PVTAError("Cần xác nhận đăng nhập, token hợp lệ và chờ thao tác đang chạy kết thúc.") }
        epoch += 1; let generation = epoch
        let user = try await GitHubAPI(transport: transport, token: token).request("/user")
        guard generation == epoch, tasks.isEmpty, let login = user["login"]?.string, login.range(of: "^[A-Za-z0-9-]{1,39}$", options: .regularExpression) != nil else { throw PVTAError("Phiên đăng nhập đã đổi hoặc GitHub chưa xác minh tài khoản.") }
        let id = try CalendarValidation.integer(user["id"], name: "Tài khoản", minimum: 1)
        try keys.save(String(decoding: JSONEncoder().encode(GitHubCredential(token: token, account: login, userId: id)), as: UTF8.self), provider: "github-session")
        previews = [:]; notify(["kind": "authChanged"]); return try await status()
    }
    func logout() throws {
        epoch += 1; previews = [:]; tasks.values.forEach { $0.cancel() }
        try keys.delete(provider: "github-session"); notify(["kind": "authChanged"])
    }
    func link(project: String, folder: String, repository: String, branch: String, confirmed: Bool) async throws -> GitHubLink {
        guard confirmed, files.permissions.level() != .readOnly, tasks.isEmpty else { throw PVTAError("Cần xác nhận liên kết và chờ thao tác đang chạy kết thúc.") }
        let repo = try GitHubInput.repository(repository), ref = try GitHubInput.branch(branch)
        let path = try await files.permissions.authorize(path: folder, write: false)
        var st = stat(); guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PVTAError("Chọn thư mục dự án có sẵn.") }
        let result = GitHubLink(projectId: project, folder: path, repository: repo, branch: ref)
        guard tasks.isEmpty else { throw PVTAError("Một thao tác vừa bắt đầu; liên kết chưa đổi.") }
        try await store.githubLink(result); previews = previews.filter { $0.value.0.link.projectId != project }; return result
    }
    static let operations = ["repository", "branches", "history", "browseFiles", "downloadSelected", "uploadSelected", "createBranch"]
    func catalog() -> JSONValue {
        let names = ["Thông tin kho", "Danh sách nhánh", "Lịch sử phiên bản", "Duyệt tệp", "Tải tệp hoặc thư mục", "Cập nhật tệp hoặc thư mục", "Tạo nhánh"]
        return ["version": 1, "operations": .array(zip(Self.operations, names).map { op, name in ["id": .string(op), "title": .string(name), "confirmation": .string(op == "uploadSelected" ? "CẬP NHẬT" : op == "createBranch" ? "TẠO NHÁNH" : ""), "requiresApproval": true] })]
    }
    func checkSession(_ generation: Int) throws { try Task.checkCancellation(); guard epoch == generation, files.permissions.level() != .readOnly else { throw PVTAError("Phiên GitHub đã đổi; hãy xem trước lại.") } }
    func validateLink(_ link: GitHubLink, write: Bool = false) async throws {
        guard try await store.projects().contains(where: { $0.id == link.projectId }), try await store.githubState().links[link.projectId] == link,
              try await files.permissions.authorize(path: link.folder, write: write) == link.folder else { throw PVTAError("Liên kết hoặc quyền thư mục đã đổi; hãy xem trước lại.") }
    }
    func local(_ link: GitHubLink, selections: [String]) async throws -> [(GitHubFile, Data)] {
        try await validateLink(link)
        var result: [(GitHubFile, Data)] = [], seen = Set<String>(), total = 0, pending = selections
        while let relative = pending.popLast() {
            _ = try GitHubInput.path(relative)
            if !seen.insert(relative).inserted { continue }
            guard seen.count <= 10000 else { throw PVTAError("Lựa chọn có quá nhiều thư mục hoặc tệp.") }
            let path = link.folder + "/" + relative
            guard try await files.permissions.authorize(path: path, write: false) == path else { throw PVTAError("Nguồn có liên kết hoặc nằm ngoài quyền đọc.") }
            let fd = try GitHubFiles.open(root: link.folder, relative: relative)
            var st = stat()
            guard fstat(fd, &st) == 0 else { close(fd); throw PVTAError("Không đọc được thông tin nguồn.") }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard let directory = fdopendir(fd) else { close(fd); throw PVTAError("Không đọc được thư mục nguồn.") }
                var names: [String] = []
                while let entry = readdir(directory) {
                    var name = entry.pointee.d_name
                    let text = withUnsafePointer(to: &name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                    if text != ".", text != "..", text.lowercased() != ".git" { names.append(text) }
                }
                closedir(directory)
                pending += names.sorted().map { relative + "/" + $0 }
            } else {
                guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 20 * 1024 * 1024 else { close(fd); throw PVTAError("Chỉ chuyển tệp thường, tối đa 20 MB mỗi tệp.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data(); try handle.close()
                total += data.count
                guard data.count <= 20 * 1024 * 1024, total <= 100 * 1024 * 1024, result.count < 500 else { throw PVTAError("Mỗi lượt tối đa 500 tệp, tổng 100 MB.") }
                result.append((GitHubFile(path: relative, sha: FileHash.of(data), size: data.count, mode: st.st_mode & 0o111 != 0 ? "100755" : "100644"), data))
            }
        }
        guard !result.isEmpty else { throw PVTAError("Lựa chọn không có tệp.") }
        return result.sorted { $0.0.path < $1.0.path }
    }
    func preview(_ p: JSONValue) async throws -> JSONValue {
        guard p["confirmed"]?.bool == true, files.permissions.level() != .readOnly else { throw PVTAError("Cần xác nhận đọc thông tin GitHub để xem trước.") }
        let op = try p.requireString("operation"), project = try p.requireString("projectId")
        guard Self.operations.contains(op), let link = try await store.githubState().links[project] else { throw PVTAError("Thao tác không được hỗ trợ hoặc dự án chưa liên kết GitHub.") }
        let generation = epoch, api = GitHubAPI(transport: transport, token: try credential().token)
        try await validateLink(link)
        let repo = try await api.request("/repos/" + link.repository)
        if ["uploadSelected", "createBranch"].contains(op), repo["permissions"]?["push"]?.bool != true { throw PVTAError("Chưa xác minh được quyền ghi kho GitHub.") }
        let (head, tree) = try await api.head(link)
        var sources: [String] = []
        var selected: [GitHubFile] = [], destination: String?, newBranch: String?
        var message = ""
        if ["uploadSelected", "downloadSelected"].contains(op) {
            guard case .array(let rawPaths)? = p["paths"], !rawPaths.isEmpty, rawPaths.count <= 500, rawPaths.allSatisfy({ $0.string != nil }) else { throw PVTAError("Chọn đường dẫn tệp hoặc thư mục tương đối.") }
            let paths = try rawPaths.map { try GitHubInput.path($0.string!) }
            sources = paths
            if op == "uploadSelected" {
                selected = try await local(link, selections: paths).map(\.0)
                message = try p.requireString("message")
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.count <= 2000 else { throw PVTAError("Nội dung lần lưu cần 1–2.000 ký tự.") }
            } else {
                let remote = try await api.tree(link, sha: tree)
                for path in paths { guard remote.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) else { throw PVTAError("Không tìm thấy lựa chọn trong kho.") } }
                selected = remote.filter { f in paths.contains { f.path == $0 || f.path.hasPrefix($0 + "/") } }.sorted { $0.path < $1.path }
                guard selected.count <= 500, selected.allSatisfy({ ["100644", "100755"].contains($0.mode) && $0.size <= 20 * 1024 * 1024 }), selected.reduce(0, { $0 + $1.size }) <= 100 * 1024 * 1024 else { throw PVTAError("Lựa chọn vượt giới hạn hoặc có symlink/submodule.") }
                let dest = try await files.permissions.authorize(path: p.requireString("destination"), write: true)
                guard !FileManager.default.fileExists(atPath: dest) else { throw PVTAError("Chọn thư mục tải xuống mới; không ghi đè thư mục có sẵn.") }; destination = dest
            }
        }
        if op == "createBranch" { newBranch = try GitHubInput.branch(p.requireString("newBranch")); guard newBranch != link.branch else { throw PVTAError("Tên nhánh mới trùng nhánh nguồn.") } }
        try checkSession(generation)
        previews = previews.filter { $0.value.0.expiresAt > now().timeIntervalSince1970 && !used.contains($0.key) }
        guard previews.count < 100 else { throw PVTAError("Đã có 100 bản xem trước; hãy chờ hết hạn trước khi tạo thêm.") }
        let view = GitHubPreview(id: UUID().uuidString, operation: op, link: link, head: head, tree: tree, files: selected, sources: sources, destination: destination, message: message, newBranch: newBranch, expiresAt: now().addingTimeInterval(300).timeIntervalSince1970, confirmation: op == "uploadSelected" ? "CẬP NHẬT" : op == "createBranch" ? "TẠO NHÁNH" : "")
        previews[view.id] = (view, generation)
        // Xem trước chỉ GET/đọc tệp, không tạo blob/commit, không sửa kho hoặc ghi nhật ký.
        return try JSONValue(encoding: view)
    }
    func journal(project: String?, uploads: Bool = false) async throws -> JSONValue {
        if !recovered {
            recovered = true
            let rows = try await store.githubState().journal
            for var row in rows where row.state == "running" && tasks[row.id] == nil {
                row.state = "unknown"; row.effects = "unknown"; row.message = "Lõi đã dừng trước khi có kết quả; kiểm tra kho trước khi thử lại."; row.finishedAt = now().timeIntervalSince1970
                try await store.githubRecord(row)
            }
        }
        let rows = try await store.githubState().journal.filter { (project == nil || $0.projectId == project) && (!uploads || $0.operation == "uploadSelected") }
        return ["items": try JSONValue(encoding: Array(rows.suffix(100).reversed())), "truncated": .bool(rows.count > 100)]
    }
    func run(_ p: JSONValue) async throws -> JSONValue {
        _ = try await journal(project: nil)
        let previewId = try p.requireString("previewId"), requestId = try p.requireString("requestId"), chat = try p.requireString("chatId")
        guard UUID(uuidString: requestId) != nil else { throw PVTAError("requestId phải là UUID để chống chạy trùng.") }
        if let old = claims[requestId] {
            guard old.preview == previewId else { throw PVTAError("requestId đã dùng cho bản xem trước khác.") }; return ["runId": .string(old.run)]
        }
        if let row = try await store.githubState().journal.first(where: { $0.requestId == requestId }) {
            guard row.previewId == previewId else { throw PVTAError("requestId đã dùng cho bản xem trước khác.") }; return ["runId": .string(row.id)]
        }
        if let old = claims[requestId] {
            guard old.preview == previewId else { throw PVTAError("requestId đã dùng cho yêu cầu khác.") }; return ["runId": .string(old.run)]
        }
        guard let (view, generation) = previews[previewId], view.expiresAt > now().timeIntervalSince1970, !used.contains(previewId) else { throw PVTAError("Bản xem trước đã hết hạn hoặc đã dùng; hãy xem trước lại.") }
        try checkSession(generation)
        guard p["confirmation"]?.string ?? "" == view.confirmation else { throw PVTAError("Chưa nhập đúng chữ xác nhận của bản xem trước.") }
        guard !locked.contains(view.link.repository), !locked.contains(view.link.folder) else { throw PVTAError("Kho hoặc thư mục này đang có thao tác chạy.") }
        let api = GitHubAPI(transport: transport, token: try credential().token)
        let id = UUID().uuidString
        locked.insert(view.link.repository); locked.insert(view.link.folder); used.insert(previewId); claims[requestId] = (previewId, id)
        let row = GitHubJournal(id: id, requestId: requestId, previewId: previewId, projectId: view.link.projectId, operation: view.operation, repository: clean(view.link.repository), branch: clean(view.link.branch), files: view.files.map { clean($0.path) }, startedAt: now().timeIntervalSince1970)
        do { try await store.githubRecord(row) }
        catch { locked.remove(view.link.repository); locked.remove(view.link.folder); claims[requestId] = nil; throw error }
        tasks[id] = Task { await self.execute(view, generation: generation, row: row, chat: chat, api: api) }
        return ["runId": .string(id)]
    }
    func cancel(_ id: String) -> Bool { guard let task = tasks[id] else { return false }; task.cancel(); return true }
    func runStatus(_ id: String) async throws -> JSONValue {
        guard let row = try await store.githubState().journal.first(where: { $0.id == id }) else { throw PVTAError("Không tìm thấy lượt GitHub.") }; var object = try JSONValue(encoding: row)
        if case .object(var fields) = object { fields["output"] = outputs[id] ?? .null; object = .object(fields) }; return object
    }
    func progress(_ original: GitHubJournal, _ step: String) async throws -> GitHubJournal {
        var row = original; row.steps.append(step)
        try await store.githubRecord(row)
        notify(["runId": .string(row.id), "kind": "progress", "sequence": .number(Double(row.steps.count)), "step": .string(step)])
        return row
    }
    func execute(_ view: GitHubPreview, generation: Int, row initial: GitHubJournal, chat: String, api: GitHubAPI) async {
        var row = initial, output: JSONValue = .null, mutationStarted = false
        defer { tasks[row.id] = nil; locked.remove(view.link.repository); locked.remove(view.link.folder) }
        do {
            try checkSession(generation)
            let plan = ActionPlan(kind: .run, summary: "GitHub: " + view.operation + " — " + view.link.repository, preview: String(decoding: try JSONEncoder().encode(view), as: UTF8.self), paths: view.destination.map { [$0] } ?? [])
            let spec = ToolSpec(name: "github_run", summary: "Chạy thao tác GitHub đã xem trước", parameters: "{}", access: .network, plan: { _ in plan }) { _ in "" }
            switch await PermissionPolicy(files.permissions).decide(spec, args: [:], chatId: chat) {
            case .deny(let why): throw PVTAError(why)
            case .allow: break
            }
            try checkSession(generation)
            guard view.expiresAt > now().timeIntervalSince1970, files.permissions.level() != .readOnly else { throw PVTAError("Bản xem trước hết hạn hoặc quyền đã đổi.") }
            try await validateLink(view.link)
            let base = "/repos/" + view.link.repository
            let repo = try await api.request(base)
            if ["uploadSelected", "createBranch"].contains(view.operation), repo["permissions"]?["push"]?.bool != true { throw PVTAError("Quyền ghi kho đã bị thu hồi.") }
            let (head, _) = try await api.head(view.link)
            guard head == view.head else { throw PVTAError("Nhánh GitHub đã đổi sau xem trước; chưa chạy thao tác.") }
            try checkSession(generation)
            row = try await progress(row, "verified")
            switch view.operation {
            case "uploadSelected":
                let local = try await local(view.link, selections: view.sources)
                guard local.map(\.0) == view.files else { throw PVTAError("Nội dung nguồn đã đổi; hãy xem trước lại.") }
                var entries: [JSONValue] = []
                for (f, data) in local {
                    try await validateLink(view.link)
                    try checkSession(generation); mutationStarted = true
                    let blob = try await api.request(base + "/git/blobs", method: "POST", body: ["content": .string(data.base64EncodedString()), "encoding": "base64"])
                    entries.append(["path": .string(f.path), "mode": .string(f.mode), "type": "blob", "sha": .string(try GitHubInput.sha(blob["sha"]))])
                    row = try await progress(row, "blob:\(row.steps.count)")
                }
                try checkSession(generation)
                try await validateLink(view.link)
                let tree = try await api.request(base + "/git/trees", method: "POST", body: ["base_tree": .string(view.tree), "tree": .array(entries)])
                row = try await progress(row, "tree")
                try checkSession(generation)
                try await validateLink(view.link)
                let commit = try await api.request(base + "/git/commits", method: "POST", body: ["message": .string(view.message), "tree": .string(try GitHubInput.sha(tree["sha"])), "parents": [.string(view.head)]])
                let sha = try GitHubInput.sha(commit["sha"]); row.commit = sha; row = try await progress(row, "commit")
                try checkSession(generation)
                guard try await api.head(view.link).0 == view.head else { throw PVTAError("Nhánh vừa đổi; commit đã tạo nhưng chưa đưa vào nhánh. Kiểm tra kho trước khi thử lại.") }
                try await validateLink(view.link)
                try checkSession(generation)
                _ = try await api.request(base + "/git/refs/heads/" + GitHubInput.segment(view.link.branch), method: "PATCH", body: ["sha": .string(sha), "force": false])
                row.effects = "applied"; row = try await progress(row, "branch-updated")
                output = ["commit": .string(sha), "count": .number(Double(view.files.count))]
            case "downloadSelected":
                guard let destination = view.destination else { throw PVTAError("Thiếu đích tải xuống.") }
                guard try await files.permissions.authorize(path: destination, write: true) == destination, !FileManager.default.fileExists(atPath: destination) else { throw PVTAError("Đích tải xuống đã đổi hoặc đã tồn tại.") }
                guard mkdir(destination, 0o700) == 0 else { throw PVTAError("Không tạo được thư mục tải xuống mới; chọn thư mục cha có sẵn.") }
                mutationStarted = true; row.effects = "applied"; row = try await progress(row, "directory-created")
                for f in view.files {
                    try checkSession(generation)
                    guard files.permissions.level() != .readOnly else { throw PVTAError("Quyền ghi đã bị thu hồi.") }
                    let blob = try await api.request(base + "/git/blobs/" + f.sha)
                    guard blob["encoding"]?.string == "base64", let content = blob["content"]?.string,
                          let data = Data(base64Encoded: content.components(separatedBy: .whitespacesAndNewlines).joined()), data.count == f.size,
                          Self.blobHash(data) == f.sha else { throw PVTAError("Nội dung tải xuống không khớp mã blob; giữ các tệp đã tải để kiểm tra.") }
                    let path = destination + "/" + f.path
                    guard try await files.permissions.authorize(path: path, write: true) == path, PathGuard.resolve(path).path?.hasPrefix(destination + "/") == true else { throw PVTAError("Đường dẫn tải xuống đã đổi.") }
                    try checkSession(generation)
                    try FileService.atomicWrite(data, to: path, exclusive: true); row = try await progress(row, "file:\(row.steps.count)")
                }
                output = ["path": .string(destination), "count": .number(Double(view.files.count))]
            case "createBranch":
                try checkSession(generation); mutationStarted = true
                _ = try await api.request(base + "/git/refs", method: "POST", body: ["ref": .string("refs/heads/" + view.newBranch!), "sha": .string(view.head)])
                row.effects = "applied"; row = try await progress(row, "branch-created")
            case "browseFiles": output = try JSONValue(encoding: await api.tree(view.link, sha: view.tree))
            case "branches", "history":
                var query = ["per_page": "100"]
                if view.operation == "history" { query["sha"] = view.head }
                let value = try await api.request(base + (view.operation == "branches" ? "/branches" : "/commits"), query: query)
                guard case .array(let list) = value else { throw PVTAError("Danh sách GitHub không hợp lệ.") }
                output = ["items": .array(list), "truncated": .bool(list.count == 100)]
            default: output = ["repository": .string(view.link.repository), "private": repo["private"] ?? .null, "defaultBranch": repo["default_branch"] ?? .null, "head": .string(view.head)]
            }
            try checkSession(generation)
            row = try await progress(row, "completed"); row.state = "success"
        } catch {
            row.state = Task.isCancelled ? "cancelled" : "error"
            if mutationStarted {
                row.effects = view.operation == "downloadSelected" ? "applied" : "unknown"
                row.state = Task.isCancelled ? "cancelled" : "partial"
            }
            row.message = error is CancellationError || Task.isCancelled ? "Đã yêu cầu dừng; không hoàn tác các bước đã xong." : clean(UserMessage.text(for: error))
        }
        row.finishedAt = now().timeIntervalSince1970
        do { try await store.githubRecord(row) }
        catch { row.state = "unknown"; row.message = "Không lưu được kết quả; cần đối chiếu kho và nhật ký." }
        outputs[row.id] = output
        if outputs.count > 100, let old = outputs.keys.first(where: { $0 != row.id }) { outputs[old] = nil }
        notify(["runId": .string(row.id), "sequence": .number(Double(row.steps.count + 1)), "kind": "result", "result": (try? JSONValue(encoding: row)) ?? .null, "output": output])
    }
    static func blobHash(_ data: Data) -> String { Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined() }
}
