import Foundation

public enum DevPublish: String, Codable, Sendable { case main, branch, off }

public struct DevJob: Codable, Sendable, Equatable {
    public var id: String
    /// upgrade | revert
    public var kind: String
    public var title: String
    public var request: String
    public var startedAt: Double
    public var endedAt: Double?
    /// running | done | failed | cancelled
    public var state: String
    /// preflight | baseline | branch | agent | review | gates | version | commit | publish | revert | done
    public var step: String
    public var branch: String?
    public var commit: String?
    /// X.Y.Z.N sau khi nâng cấp.
    public var version: String?
    public var files: [String]?
    /// main | branch | none
    public var published: String?
    public var error: String?
    public var summary: String?
    public var reverted: Bool?
    public var log: [String]
}

public struct DevExecResult: Sendable { public var code: Int32; public var out: String }
public typealias DevExec = @Sendable (_ cmd: String, _ args: [String], _ cwd: String, _ timeout: Duration) async throws -> DevExecResult

public struct DevGate: Sendable {
    public var name: String
    public var cmd: String
    public var args: [String]
    public var timeout: Duration
    public init(name: String, cmd: String, args: [String], timeout: Duration = .seconds(1800)) { self.name = name; self.cmd = cmd; self.args = args; self.timeout = timeout }
}

/// Quyền nâng cấp mã nguồn do người dùng cấp: đúng kho, đúng địa chỉ origin ghi lúc cấp, chế độ đưa lên.
public struct DevAuthority: Sendable, Equatable {
    public var repo: String
    public var remote: String
    public var publish: DevPublish
}

/// Thư ký nâng cấp chính mã nguồn PVTA. AI chỉ sửa tệp trên nhánh `secretary/…`; mọi việc còn lại do mã này kiểm soát:
/// cây Git sạch, đúng origin → nhánh riêng → AI sửa → soát đường dẫn cấm, lộ bí mật, quy mô → build và test (không thêm lỗi mới)
/// → tăng N → commit → đẩy (không bao giờ ép đẩy). Không đạt bước nào thì việc dở được cất trên nhánh riêng, nhánh chính không bị đụng.
public actor SecretaryDev {
    public typealias Agent = @Sendable (_ prompt: String, _ repo: String, _ log: @escaping @Sendable (String) -> Void) async throws -> String
    public typealias Tests = @Sendable (_ repo: String) async throws -> [String]
    static let jobsKey = "secretary.devJobs", baselineKey = "secretary.devBaseline", maxJobs = 30

    let store: DataStore
    let exec: DevExec
    let agent: Agent
    let runTests: Tests
    let gates: [DevGate]
    let authority: @Sendable () async throws -> DevAuthority?
    let now: @Sendable () -> Date
    let changed: @Sendable (DevJob) -> Void
    private var task: Task<DevJob, Never>?
    private var jobsCache: [DevJob]?

    public init(store: DataStore, exec: @escaping DevExec = SecretaryDev.processExec, agent: @escaping Agent, runTests: @escaping Tests, gates: [DevGate] = SecretaryDev.defaultGates,
                authority: @escaping @Sendable () async throws -> DevAuthority?, now: @escaping @Sendable () -> Date = { Date() }, changed: @escaping @Sendable (DevJob) -> Void = { _ in }) {
        self.store = store; self.exec = exec; self.agent = agent; self.runTests = runTests; self.gates = gates; self.authority = authority; self.now = now; self.changed = changed
    }

    public static let defaultGates = [DevGate(name: "swift build", cmd: "swift", args: ["build"])]

    /// Chạy lệnh bằng posix_spawn trong nhóm tiến trình riêng (hủy là dừng cả cây). Không qua shell.
    public static let processExec: DevExec = { cmd, args, cwd, timeout in
        let bin: String
        if cmd.hasPrefix("/") { bin = cmd } else {
            guard let found = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/bin"].map({ $0 + "/" + cmd }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw PVTAError("Không tìm thấy lệnh “\(cmd)” trên máy.") }
            bin = found
        }
        let buf = OutBox()
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "GIT_TERMINAL_PROMPT": "0", "LANG": "en_US.UTF-8", "CI": "1"]
        if let h = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = h }
        let r = try await CLIProcess.run(binary: bin, args: args, environment: env, directory: URL(fileURLWithPath: cwd), stdin: .none, timeout: timeout) { _, d in buf.add(d) }
        if r.timedOut { return DevExecResult(code: 124, out: buf.text + "\n(quá thời gian)") }
        return DevExecResult(code: r.code ?? 137, out: buf.text)
    }

    final class OutBox: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func add(_ d: Data) { lock.lock(); if data.count < 64 * 1024 * 1024 { data.append(d) }; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Test mặc định: `swift test` trong kho, trả danh sách test lỗi.
    public static func swiftTests(_ exec: @escaping DevExec) -> Tests {
        { repo in
            let r = try await exec("swift", ["test"], repo, .seconds(3600))
            return DevPolicy.swiftTestFailures(r.out, exitCode: r.code)
        }
    }

    // MARK: Nhật ký công việc

    public func jobs() async throws -> [DevJob] {
        if let c = jobsCache { return c }
        guard let raw = try await store.setting(Self.jobsKey), var j = try? JSONDecoder().decode([DevJob].self, from: Data(raw.utf8)) else { jobsCache = []; return [] }
        // Việc đang chạy lúc ứng dụng tắt thì coi là gián đoạn.
        for i in j.indices where j[i].state == "running" && task == nil { j[i].state = "failed"; j[i].error = "Bị gián đoạn khi ứng dụng đóng."; j[i].endedAt = j[i].endedAt ?? now().timeIntervalSince1970 }
        jobsCache = j
        return j
    }

    private func put(_ job: DevJob) async {
        var all = (try? await jobs()) ?? []
        if let i = all.firstIndex(where: { $0.id == job.id }) { all[i] = job } else { all.insert(job, at: 0) }
        all = Array(all.prefix(Self.maxJobs))
        jobsCache = all
        if let d = try? JSONEncoder().encode(all) { try? await store.setSetting(Self.jobsKey, String(decoding: d, as: UTF8.self)) }
        changed(job)
    }

    public var busy: Bool { task != nil }

    /// Hủy lần chạy hiện tại. Trả false nếu không có gì đang chạy.
    @discardableResult
    public func cancel() -> Bool { guard let t = task else { return false }; t.cancel(); return true }

    /// Chờ lần chạy hiện tại xong (dùng cho kiểm thử và cổng gọi).
    public func wait() async -> DevJob? { await task?.value }

    // MARK: Git

    private func git(_ repo: String, _ args: [String], timeout: Duration = .seconds(120)) async throws -> DevExecResult { try await exec("git", args, repo, timeout) }
    @discardableResult
    private func must(_ repo: String, _ args: [String], timeout: Duration = .seconds(120)) async throws -> String {
        let r = try await git(repo, args, timeout: timeout)
        guard r.code == 0 else { throw PVTAError("git \(args.first ?? "") lỗi: " + String(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))) }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let ident = ["-c", "user.name=PVTA Thư ký", "-c", "user.email=secretary@pvta.local"]

    /// Cổng 1 — kho: đúng kho PVTA đã cấp, origin khớp địa chỉ ghi lúc cấp, ở nhánh thường, không dở merge/rebase, cây sạch.
    func preflight(_ auth: DevAuthority) async throws -> (repo: String, branch: String, head: String) {
        guard let repo = PathGuard.canonical(auth.repo), repo == PathGuard.canonical(auth.repo) else { throw PVTAError("Thư mục mã nguồn không tồn tại: \(auth.repo)") }
        guard DevPolicy.isPVTARepo(repo) else { throw PVTAError("Không phải kho mã nguồn PVTA (cần .git, Package.swift, Sources/PVTACore).") }
        let remote = try await must(repo, ["remote", "get-url", "origin"])
        guard remote == auth.remote else { throw PVTAError("Kho này đẩy lên “\(remote)”, khác địa chỉ đã cấp quyền (“\(auth.remote)”); Thư ký không tự đẩy lên nơi khác.") }
        let branch = try await must(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
        if branch == "HEAD" || branch.hasPrefix("secretary/") { throw PVTAError("Kho đang ở nhánh “\(branch)”; hãy chuyển về nhánh chính rồi thử lại.") }
        for f in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"] where FileManager.default.fileExists(atPath: repo + "/.git/" + f) {
            throw PVTAError("Kho đang dở dang một lần merge/rebase/revert; hãy hoàn tất trước.")
        }
        let dirty = try await must(repo, ["status", "--porcelain", "--untracked-files=all"]).split(separator: "\n").filter { !$0.isEmpty }
        if let first = dirty.first { throw PVTAError("Kho đang có \(dirty.count) thay đổi chưa commit (ví dụ \(first.trimmingCharacters(in: .whitespaces).prefix(80))). Thư ký không trộn việc của mình với việc dở của bạn: hãy commit hoặc cất chúng trước.") }
        return (repo, branch, try await must(repo, ["rev-parse", "HEAD"]))
    }

    // MARK: Nâng cấp

    public func start(title: String, request: String) async throws -> DevJob {
        guard task == nil else { throw PVTAError("Đang có một lần nâng cấp chạy. Đợi xong hoặc hủy trước.") }
        let r = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, r.count <= 6000 else { throw PVTAError("Hãy mô tả việc cần nâng cấp (tối đa 6000 ký tự).") }
        guard let auth = try await authority() else { throw PVTAError("Chưa cấp quyền “Nâng cấp mã nguồn PVTA” (dev.pvta) cho Thư ký, hoặc quyền đang tắt.") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DevJob(id: UUID().uuidString, kind: "upgrade", title: String((t.isEmpty ? "Nâng cấp" : t).prefix(120)), request: r, startedAt: now().timeIntervalSince1970,
                         state: "running", step: "preflight", log: [])
        await put(job)
        task = Task { await self.runUpgrade(job, auth) }
        return job
    }

    private func say(_ job: inout DevJob, _ line: String, step: String? = nil) async {
        if let step { job.step = step }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        job.log.append(String("\(f.string(from: now())) \(line)".prefix(500)))
        if job.log.count > 200 { job.log.removeFirst(job.log.count - 200) }
        await put(job)
    }

    private func check() throws { if Task.isCancelled { throw CancellationError() } }

    private func runUpgrade(_ start: DevJob, _ auth: DevAuthority) async -> DevJob {
        var job = start
        var repo = auth.repo, home = "", branch = ""
        do {
            await say(&job, "Kiểm tra kho mã nguồn…", step: "preflight")
            let pre = try await preflight(auth); repo = pre.repo; home = pre.branch
            try check()
            try await fastForward(repo, home, &job)
            let head = try await must(repo, ["rev-parse", "HEAD"])

            // Mốc so sánh: test đã lỗi sẵn trước khi sửa không bị tính là lỗi do Thư ký.
            await say(&job, "Lấy mốc test trước khi sửa…", step: "baseline")
            var baseline: [String]
            if let raw = try await store.setting(Self.baselineKey), let b = try? JSONDecoder().decode([String: [String]].self, from: Data(raw.utf8)), let f = b[head] { baseline = f; await say(&job, "Dùng mốc đã có: \(f.count) test lỗi sẵn.") }
            else { baseline = try await runTests(repo); try await saveBaseline(head, baseline); await say(&job, "Mốc: \(baseline.count) test đang lỗi sẵn.") }
            try check()

            let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmm"; f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh"); return f.string(from: now()) }()
            branch = "secretary/\(stamp)-\(DevPolicy.slugify(job.title))-\(UUID().uuidString.prefix(4).lowercased())"
            await say(&job, "Tạo nhánh riêng \(branch)", step: "branch")
            try await must(repo, ["checkout", "-b", branch]); job.branch = branch

            // AI có công cụ chạy lệnh nên về nguyên tắc có thể tự đẩy: ghi lại các nhánh trên origin để phát hiện sau.
            let headsBefore = try? await must(repo, ["ls-remote", "--heads", "origin"], timeout: .seconds(60))
            await say(&job, "AI đang sửa mã…", step: "agent")
            let logBox = LogBox()
            let summary = try await agent(DevPolicy.agentPrompt(title: job.title, request: job.request, branch: branch, repo: repo), repo, { logBox.add($0) })
            job.summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
            for l in logBox.take() { await say(&job, l) }
            try check()

            // Cổng 2 — soát thay đổi (không phụ thuộc AI đã làm gì: tự commit, đổi nhánh, đẩy đều bị phát hiện).
            await say(&job, "Soát thay đổi…", step: "review")
            if let before = headsBefore, let after = try? await must(repo, ["ls-remote", "--heads", "origin"], timeout: .seconds(60)), after != before {
                let old = Set(before.split(separator: "\n").map(String.init))
                for line in after.split(separator: "\n").map(String.init) where !old.contains(line) {
                    let sha = String(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")
                    if sha.count == 40, (try await git(repo, ["cat-file", "-e", sha + "^{commit}"])).code == 0 { throw PVTAError("AI đã tự đẩy lên origin trong lúc làm (không được phép). Hãy kiểm tra các nhánh trên GitHub.") }
                }
            }
            let currentBranch = try await must(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
            guard currentBranch == branch else { throw PVTAError("AI đã đổi nhánh sang “\(currentBranch)”; hủy để an toàn.") }
            try await must(repo, ["reset", "--soft", head])
            try await must(repo, ["add", "-A"])
            let files = try await must(repo, ["diff", "--cached", "--name-only", "--no-renames"]).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            job.files = files
            guard !files.isEmpty else { throw PVTAError("AI không thay đổi tệp nào; không có gì để nâng cấp.") }
            let blocked = DevPolicy.blockedPaths(files)
            if !blocked.isEmpty { throw PVTAError("Thay đổi chạm vào nơi không được phép: " + blocked.prefix(5).map { "\($0.file) (\($0.why))" }.joined(separator: "; ")) }
            guard files.count <= DevPolicy.maxFiles else { throw PVTAError("Thay đổi quá rộng (\(files.count) tệp, tối đa \(DevPolicy.maxFiles)). Hãy chia nhỏ yêu cầu.") }
            let added = try await must(repo, ["diff", "--cached", "--numstat"]).split(separator: "\n").reduce(0) { $0 + (Int($1.split(separator: "\t").first ?? "") ?? 0) }
            guard added <= DevPolicy.maxAddedLines else { throw PVTAError("Thay đổi quá lớn (\(added) dòng thêm, tối đa \(DevPolicy.maxAddedLines)). Hãy chia nhỏ yêu cầu.") }
            let secrets = DevPolicy.scanSecrets(try await must(repo, ["diff", "--cached", "-U0", "--no-color"]))
            if !secrets.isEmpty { throw PVTAError("Phát hiện nghi ngờ khóa/bí mật trong thay đổi: " + secrets.joined(separator: "; ")) }
            await say(&job, "\(files.count) tệp, +\(added) dòng.")
            try check()

            // Cổng 3 — build và test: không được thêm lỗi mới so với mốc.
            await say(&job, "Chạy kiểm tra…", step: "gates")
            for g in gates {
                await say(&job, "• \(g.name)…")
                let r = try await exec(g.cmd, g.args, repo, g.timeout)
                guard r.code == 0 else { throw PVTAError("Không đạt “\(g.name)”: " + String(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))) }
                try check()
            }
            await say(&job, "• test (không được thêm lỗi mới)…")
            let after = try await runTests(repo)
            let fresh = DevPolicy.newFailures(before: baseline, after: after)
            guard fresh.isEmpty else { throw PVTAError("Thêm \(fresh.count) test lỗi mới: " + fresh.prefix(5).joined(separator: "; ")) }
            let stray = try await must(repo, ["status", "--porcelain", "--untracked-files=all"]).split(separator: "\n").map { String($0.dropFirst(3)) }.filter { !$0.isEmpty && !files.contains($0.replacingOccurrences(of: "\"", with: "")) }
            guard stray.isEmpty else { throw PVTAError("Quá trình kiểm tra tạo thêm tệp ngoài dự kiến: " + stray.prefix(5).joined(separator: ", ")) }
            try check()

            // Tăng N (số lần nâng cấp) bằng mã, không nhờ AI.
            await say(&job, "Tăng số lần nâng cấp N…", step: "version")
            job.version = try bump(repo)
            await say(&job, "Commit \(job.version!)", step: "commit")
            try await must(repo, ["add", "-A"])
            let msg = "Thư ký PVTA \(job.version!): \(job.title)\n\n\(job.summary ?? "")\n\nYêu cầu: \(job.request.prefix(1500))\nKiểm tra: \(gates.map(\.name).joined(separator: ", ")), test (không thêm lỗi mới) đều đạt.\nThư-ký-PVTA-Version: \(job.version!)"
            try await must(repo, Self.ident + ["commit", "-m", msg])
            job.commit = try await must(repo, ["rev-parse", "HEAD"])
            try check()

            await say(&job, auth.publish == .off ? "Giữ trên nhánh riêng (không đẩy)." : "Đưa lên origin…", step: "publish")
            job.published = try await publish(repo, home, branch, auth.publish, head, &job)
            try? await saveBaseline(try await must(repo, ["rev-parse", "HEAD"]), after)
            job.state = "done"; job.endedAt = self.now().timeIntervalSince1970
            await say(&job, "Xong \(job.version!)" + (job.published == "main" ? " · đã đưa lên \(home)" : job.published == "branch" ? " · đã đẩy nhánh riêng" : "") + ".", step: "done")
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let msg = cancelled ? "Đã hủy." : UserMessage.text(for: error)
            job.state = cancelled ? "cancelled" : "failed"; job.error = msg; job.endedAt = now().timeIntervalSince1970
            await say(&job, (cancelled ? "✋ " : "✗ ") + msg)
            await rescue(repo, home, branch, &job)
        }
        task = nil
        await put(job)
        return job
    }

    final class LogBox: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { lock.unlock() }; let l = lines; lines = []; return l }
    }

    private func saveBaseline(_ sha: String, _ failures: [String]) async throws {
        try await store.setSetting(Self.baselineKey, String(decoding: try JSONEncoder().encode([sha: failures]), as: UTF8.self))
    }

    private func fastForward(_ repo: String, _ branch: String, _ job: inout DevJob) async throws {
        let f = try await git(repo, ["fetch", "origin", branch], timeout: .seconds(180))
        guard f.code == 0 else { await say(&job, "Không lấy được tin mới từ origin (có thể mất mạng); tiếp tục với bản trên máy."); return }
        let behind = Int(try await must(repo, ["rev-list", "--count", "HEAD..origin/\(branch)"])) ?? 0
        let ahead = Int(try await must(repo, ["rev-list", "--count", "origin/\(branch)..HEAD"])) ?? 0
        if behind > 0 && ahead > 0 { throw PVTAError("Nhánh \(branch) trên máy và trên origin đã rẽ nhánh (\(ahead) commit chưa đẩy, \(behind) commit mới). Hãy tự hợp nhất trước.") }
        if behind > 0 { try await must(repo, ["merge", "--ff-only", "origin/\(branch)"]); await say(&job, "Đã cập nhật \(behind) commit mới từ origin.") }
    }

    /// N (số lần nâng cấp) nằm ở tệp REVISION của kho; chỉ tăng, không bao giờ lùi. Phiên bản đầy đủ X.Y.Z.N.
    func bump(_ repo: String, from base: Int? = nil) throws -> String {
        let file = repo + "/REVISION"
        let current = base ?? (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let n = current + 1
        try "\(n)\n".write(toFile: file, atomically: true, encoding: .utf8)
        guard let back = try? String(contentsOfFile: file, encoding: .utf8), Int(back.trimmingCharacters(in: .whitespacesAndNewlines)) == n else { throw PVTAError("Phiên bản lệch sau khi tăng.") }
        return "\(Self.baseVersion(repo)).\(n)"
    }

    static func baseVersion(_ repo: String) -> String {
        let s = (try? String(contentsOfFile: repo + "/Sources/PVTACore/PVTAInfo.swift", encoding: .utf8)) ?? ""
        guard let r = s.range(of: #"version = "(\d+\.\d+\.\d+)""#, options: .regularExpression) else { return "0.0.0" }
        return String(s[r]).replacingOccurrences(of: "version = ", with: "").replacingOccurrences(of: "\"", with: "")
    }

    /// Cất việc dở lên nhánh riêng rồi trả kho về nhánh của người dùng; không để mất gì và không để kho bẩn.
    /// Chạy trong một Task mới để việc dọn dẹp không bị hủy theo lần chạy đã bị hủy.
    private func rescue(_ repo: String, _ home: String, _ branch: String, _ job: inout DevJob) async {
        guard !home.isEmpty, !branch.isEmpty else { return }
        let title = job.title
        let exec = self.exec
        let (kept, lines) = await Task.detached { await Self.rescueWork(exec, repo, home, branch, title) }.value
        if !kept { job.branch = nil }
        for l in lines { await say(&job, l) }
    }

    private static func rescueWork(_ exec: DevExec, _ repo: String, _ home: String, _ branch: String, _ title: String) async -> (kept: Bool, lines: [String]) {
        func git(_ r: String, _ a: [String]) async throws -> DevExecResult { try await exec("git", a, r, .seconds(120)) }
        func cur() async -> String { ((try? await git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]))?.out ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let c0 = await cur()
        if c0 != branch && c0 != home { _ = try? await git(repo, ["checkout", "-f", branch]) }
        let c1 = await cur()
        guard c1 == branch else { return (true, []) }
        _ = try? await git(repo, ["add", "-A"])
        if let st = try? await git(repo, ["status", "--porcelain"]), !st.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? await git(repo, Self.ident + ["commit", "--no-verify", "-q", "-m", "WIP (chưa đạt kiểm tra): \(title)"])
        }
        let r = try? await git(repo, ["checkout", home])
        if r?.code != 0 { return (true, ["Không quay về nhánh \(home): " + String((r?.out ?? "").suffix(200))]) }
        let ahead = Int((try? await git(repo, ["rev-list", "--count", "\(home)..\(branch)"]))?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        if ahead == 0 { _ = try? await git(repo, ["branch", "-D", branch]); return (false, ["Chưa có thay đổi nào; kho đã quay về \(home)."]) }
        return (true, ["Việc dở được giữ ở nhánh \(branch); kho đã quay về \(home)."])
    }

    private func publish(_ repo: String, _ home: String, _ branch: String, _ mode: DevPublish, _ startSha: String, _ job: inout DevJob) async throws -> String {
        switch mode {
        case .off:
            try await must(repo, ["checkout", home])
            await say(&job, "Nhánh \(branch) chỉ nằm trên máy; bạn tự hợp nhất khi muốn.")
            return "none"
        case .branch:
            try await must(repo, ["push", "-u", "origin", branch], timeout: .seconds(180))
            try await must(repo, ["checkout", home])
            return "branch"
        case .main:
            try await must(repo, ["checkout", home])
            try await must(repo, ["merge", "--ff-only", branch])
            let push = try await git(repo, ["push", "origin", home], timeout: .seconds(180))
            if push.code == 0 { _ = try? await git(repo, ["branch", "-d", branch]); return "main" }
            // Bị từ chối hoặc mất mạng: trả nhánh chính về như cũ rồi đẩy nhánh riêng để không mất việc. Không ép đẩy.
            try await must(repo, ["reset", "--hard", startSha])
            await say(&job, "Không đẩy được lên \(home): " + String(push.out.suffix(200)))
            if (try await git(repo, ["push", "-u", "origin", branch], timeout: .seconds(180))).code == 0 { await say(&job, "Đã đẩy nhánh riêng \(branch); hãy hợp nhất vào \(home) trên GitHub."); return "branch" }
            await say(&job, "Cũng không đẩy được nhánh riêng; việc nằm ở nhánh \(branch) trên máy.")
            return "none"
        }
    }

    // MARK: Hoàn tác

    /// Hoàn tác lần nâng cấp gần nhất đã xong bằng một commit revert (không viết lại lịch sử). N vẫn tăng tiếp.
    public func revertLast() async throws -> DevJob {
        guard task == nil else { throw PVTAError("Đang có một lần nâng cấp chạy.") }
        guard let auth = try await authority() else { throw PVTAError("Chưa cấp quyền “Nâng cấp mã nguồn PVTA” (dev.pvta) cho Thư ký, hoặc quyền đang tắt.") }
        guard var target = try await jobs().first(where: { $0.kind == "upgrade" && $0.state == "done" && $0.commit != nil && $0.reverted != true }) else { throw PVTAError("Chưa có lần nâng cấp nào để hoàn tác.") }
        let job = DevJob(id: UUID().uuidString, kind: "revert", title: "Hoàn tác \(target.version ?? target.title)", request: target.title, startedAt: now().timeIntervalSince1970, state: "running", step: "preflight", log: [])
        await put(job)
        task = Task {
            var job = job
            var repo = auth.repo
            do {
                let pre = try await self.preflight(auth); repo = pre.repo
                await self.say(&job, "Hoàn tác commit \(target.commit!.prefix(8))…", step: "revert")
                let revFile = repo + "/REVISION"
                let before = (try? String(contentsOfFile: revFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                let rv = try await self.git(repo, Self.ident + ["revert", "--no-edit", "--no-commit", target.commit!])
                if rv.code != 0 {
                    // Xung đột chỉ ở REVISION là bình thường (N luôn tăng): giữ N hiện tại rồi tăng. Xung đột khác thì dừng.
                    let conflicts = try await self.must(repo, ["diff", "--name-only", "--diff-filter=U"]).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    guard !conflicts.isEmpty, conflicts.allSatisfy({ $0 == "REVISION" }) else { throw PVTAError("Không hoàn tác tự động được (xung đột: \(conflicts.prefix(5).joined(separator: ", "))). Hãy tự xử lý.") }
                }
                job.version = try self.bump(repo, from: before)
                try await self.must(repo, ["add", "-A"])
                try await self.must(repo, Self.ident + ["commit", "-m", "Thư ký PVTA \(job.version!): hoàn tác “\(target.title)”\n\nThư-ký-PVTA-Version: \(job.version!)"])
                job.commit = try await self.must(repo, ["rev-parse", "HEAD"])
                if auth.publish != .off {
                    await self.say(&job, "Đưa lên origin…", step: "publish")
                    let p = try await self.git(repo, ["push", "origin", pre.branch], timeout: .seconds(180))
                    job.published = p.code == 0 ? "main" : "none"
                    if p.code != 0 { await self.say(&job, "Không đẩy được: " + String(p.out.suffix(200))) }
                } else { job.published = "none" }
                target.reverted = true
                await self.put(target)
                job.state = "done"; job.endedAt = self.now().timeIntervalSince1970
                await self.say(&job, "Đã hoàn tác; phiên bản \(job.version!).", step: "done")
            } catch {
                job.state = Task.isCancelled ? "cancelled" : "failed"; job.error = UserMessage.text(for: error); job.endedAt = self.now().timeIntervalSince1970
                await self.say(&job, "✗ " + job.error!)
                let r = repo
                let ex = self.exec
                await Task.detached { _ = try? await ex("git", ["revert", "--abort"], r, .seconds(60)); _ = try? await ex("git", ["reset", "--hard", "HEAD"], r, .seconds(60)) }.value
            }
            await self.clearTask()
            await self.put(job)
            return job
        }
        return job
    }

    private func clearTask() { task = nil }
}

extension SecretaryDev {
    /// Công cụ cho hội thoại Thư ký. Bắt đầu nâng cấp là thao tác ghi nên luôn hỏi duyệt; các cổng vẫn chạy bằng mã dù đã duyệt.
    nonisolated var toolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "sec_dev_upgrade", summary: "Bắt đầu nâng cấp mã nguồn PVTA theo yêu cầu của thầy cô (cần quyền dev.pvta và thầy cô duyệt). Mã tự kiểm tra cây Git sạch, đường dẫn cấm, lộ khóa, build và test trước khi commit/đẩy.",
                     parameters: #"{"title": "tên ngắn", "request": "mô tả việc cần sửa"}"#, access: .write,
                     plan: { a in
                         ActionPlan(kind: .run, summary: "Thư ký nâng cấp mã nguồn PVTA: \(a["title"]?.string ?? "")",
                                    preview: "Yêu cầu: \(String((a["request"]?.string ?? "").prefix(1500)))\nAI sửa trên nhánh secretary/…; chỉ commit và đẩy khi mọi cổng kiểm tra đạt.", paths: [])
                     }) { [self] a in
                guard let r = a["request"]?.string else { throw PVTAError("Thiếu “request”.") }
                let job = try await start(title: a["title"]?.string ?? "Nâng cấp", request: r)
                return "Đã bắt đầu nâng cấp (mã việc \(job.id)). Theo dõi bằng sec_dev_status."
            },
            ToolSpec(name: "sec_dev_status", summary: "Trạng thái các lần nâng cấp mã nguồn gần đây (bước, lỗi, phiên bản).", parameters: "{}") { [self] _ in
                let js = try await jobs().prefix(5)
                if js.isEmpty { return "Chưa có lần nâng cấp nào." }
                return js.map { "\($0.kind) “\($0.title)”: \($0.state) · bước \($0.step)" + ($0.version.map { " · \($0)" } ?? "") + ($0.error.map { " · lỗi: \($0)" } ?? "") }.joined(separator: "\n")
            },
        ]
    }
}
