import Foundation

/// Khóa nhà cung cấp dùng cho hạn mức: `claude`, `codex`, `agy`, `opencode` hoặc `api:<nhà-cung-cấp>`.
func providerKey(model full: String) -> String {
    if let slash = full.firstIndex(of: "/") {
        let head = String(full[..<slash])
        if CLIBackendID(rawValue: head) != nil { return head }
        return "api:" + head
    }
    return full
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

extension AIClient {
    /// Đọc hạn mức qua chính công cụ đã đăng nhập (không gửi lượt hỏi model nào) hoặc qua API của nhà cung cấp.
    public func readUsage(key: String, model: String? = nil, timeout: Duration = .seconds(15)) async throws -> ProviderUsage {
        if let tool = CLIBackendID(rawValue: key) {
            guard let bin = cli.find(tool) else { throw PVTAError("Máy chưa có \(tool.name) nên chưa đọc được hạn mức.") }
            switch tool {
            case .agy: return try await readAgy(bin, model: model, timeout: timeout)
            case .claude: return try await readClaude(bin, timeout: timeout)
            case .codex: return try await readCodex(bin, timeout: timeout)
            case .opencode: throw PVTAError("OpenCode không cung cấp truy vấn hạn mức.")
            }
        }
        if key == "api:commandcode" { return try await readCommandCode() }
        throw PVTAError("Nguồn này chưa cung cấp truy vấn hạn mức.")
    }

    private func readAgy(_ bin: String, model: String?, timeout: Duration) async throws -> ProviderUsage {
        let r = await cli.capture(bin, ["--print", "/usage", "--output-format", "json"], id: .agy, timeout: timeout)
        let json = r.output.split(whereSeparator: \.isNewline).lazy.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }.first
        guard r.exit?.code == 0, let json, let usage = UsageParser.agy(json, model: model, now: Date()) else {
            throw PVTAError("Antigravity chưa cung cấp số phần trăm hạn mức cho phiên đăng nhập hiện tại.")
        }
        return usage
    }

    /// Nói chuyện qua stdin/stdout theo từng dòng JSON với công cụ cho tới khi `onLine` trả về kết quả.
    private func converse(_ bin: String, _ args: [String], id: CLIBackendID, first: String, timeout: Duration,
                          failure: String, onLine: @escaping @Sendable (JSONValue, @Sendable (String) -> Void) throws -> ProviderUsage?) async throws -> ProviderUsage {
        try cli.prepareWorkDirectory()
        let env = cli
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProviderUsage, Error>) in
            let once = Once()
            let handleBox = HandleBox()
            let splitter = SplitterBox()
            let runTask = Task {
                _ = try? await CLIProcess.run(binary: bin, args: args, environment: env.childEnvironment(for: id), directory: env.workDirectory,
                                              stdin: .interactive, timeout: timeout, onStart: { h in handleBox.set(h); h.write(first + "\n") }) { isError, chunk in
                    if isError { return }
                    for line in splitter.feed(chunk) {
                        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                        do {
                            if let usage = try onLine(v, { handleBox.write($0 + "\n") }), once.take() { cont.resume(returning: usage) }
                        } catch { if once.take() { cont.resume(throwing: error) } }
                    }
                }
                if once.take() { cont.resume(throwing: PVTAError(failure)) }   // tiến trình thoát hoặc hết giờ mà chưa có số liệu
            }
            Task {
                try? await Task.sleep(for: timeout + .seconds(2))
                runTask.cancel()
            }
            Task {
                // Có kết quả thì dừng công cụ (không để tiến trình chạy tiếp).
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    if once.isDone { runTask.cancel(); return }
                }
            }
        }
    }

    private func readClaude(_ bin: String, timeout: Duration) async throws -> ProviderUsage {
        let args = ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--no-session-persistence",
                    "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands",
                    "--settings", #"{"disableAllHooks":true}"#]
        let msg: @Sendable (String, String) -> String = { id, sub in
            #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"\#(sub)"\#(sub == "initialize" ? #","hooks":{}"# : #","skip_behaviors":true"#)}}"#
        }
        return try await converse(bin, args, id: .claude, first: msg("usage-init", "initialize"), timeout: timeout,
                                  failure: "Nguồn AI chưa trả số phần trăm 5h/tuần; hãy thử làm mới sau.") { v, send in
            guard v["type"]?.string == "control_response", let r = v["response"] else { return nil }
            if r["subtype"]?.string == "error" { throw PVTAError("Phiên bản Claude Code này chưa hỗ trợ đọc hạn mức.") }
            switch r["request_id"]?.string {
            case "usage-init": send(msg("usage-read", "get_usage")); return nil
            case "usage-read":
                if let u = r["response"].flatMap({ UsageParser.claude($0, now: Date()) }) { return u }
                throw PVTAError(r["response"]?["rate_limits_available"]?.bool == false
                    ? "Phiên đăng nhập hiện tại không cung cấp hạn mức gói 5h/tuần." : "Nguồn AI chưa trả số phần trăm 5h/tuần; hãy thử làm mới sau.")
            default: return nil
            }
        }
    }

    private func readCodex(_ bin: String, timeout: Duration) async throws -> ProviderUsage {
        let first = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"pvta_usage","version":"1"},"capabilities":{"experimentalApi":true}}}"#
        return try await converse(bin, ["app-server", "--listen", "stdio://"], id: .codex, first: first, timeout: timeout,
                                  failure: "Codex chưa cung cấp số phần trăm hạn mức cho phiên đăng nhập hiện tại.") { v, send in
            switch v["id"]?.number {
            case 1:
                if v["error"] != nil { throw PVTAError("Không khởi tạo được truy vấn hạn mức Codex.") }
                send(#"{"method":"initialized","params":{}}"#)
                send(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
                return nil
            case 2:
                if let u = v["result"].flatMap({ UsageParser.codex($0, now: Date()) }) { return u }
                throw PVTAError("Codex chưa cung cấp số phần trăm hạn mức cho phiên đăng nhập hiện tại.")
            default: return nil
            }
        }
    }

    /// Cùng các đường đọc chỉ-đọc mà lệnh /usage của Command Code dùng; khóa chỉ gửi tới máy chủ chính thức, không đi theo chuyển hướng.
    private func readCommandCode() async throws -> ProviderUsage {
        guard let key = try keysForUsage.read(provider: "commandcode") else { throw PVTAError("Chưa cấu hình khóa Command Code.") }
        guard let info = ProviderInfo.find("commandcode"), let base = URL(string: info.baseURL), base.host == "api.commandcode.ai" else {
            throw PVTAError("Chỉ đọc hạn mức từ máy chủ Command Code chính thức.")
        }
        func get(_ path: String) async throws -> JSONValue {
            var req = URLRequest(url: URL(string: "https://api.commandcode.ai" + path)!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            req.setValue("application/json", forHTTPHeaderField: "accept")
            req.timeoutInterval = 15
            let reply: (status: Int, headers: [String: String], body: Data)
            do { reply = try await transportForTools.download(req, limit: 2_000_000) } catch {
                throw PVTAError("Chưa kết nối được Command Code để đọc hạn mức. Hãy thử lại.")
            }
            guard (200..<300).contains(reply.status) else {
                throw PVTAError(reply.status == 401 || reply.status == 403 ? "Khóa Command Code chưa có quyền đọc hạn mức." : "Command Code chưa trả dữ liệu hạn mức. Hãy thử lại.")
            }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: reply.body) else {
                throw PVTAError("Command Code trả dữ liệu hạn mức không hợp lệ.")
            }
            return json
        }
        let who = try await get("/alpha/whoami?limits=1")
        var path = "/alpha/billing/credits"
        if let org = who["org"]?["id"] {
            let id = org.string ?? org.number.map { String(Int($0)) }
            if let id { path += "?orgId=" + (id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id) }
        }
        return try UsageParser.commandCode(try await get(path), now: Date())
    }
}

final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: CLIProcess.Handle?
    func set(_ h: CLIProcess.Handle) { lock.lock(); handle = h; lock.unlock() }
    func write(_ s: String) { lock.lock(); let h = handle; lock.unlock(); h?.write(s) }
}

final class SplitterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = CLIProcess.LineSplitter()
    func feed(_ d: Data) -> [String] { lock.lock(); defer { lock.unlock() }; return splitter.feed(d).filter { !$0.isEmpty } }
}
