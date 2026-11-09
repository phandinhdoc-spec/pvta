import Foundation

public struct SetupEvent: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case running, code, done, failed }
    public var backend: CLIBackendID
    public var kind: String   // "install" | "login"
    public var phase: Phase
    public var lines: [String]
    public var url: String?
    public var message: String?
}

enum SetupText {
    static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}")

    static func stripAnsi(_ s: String) -> String { ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "") }

    /// Chỉ mở đường dẫn đăng nhập thuộc đúng nhà cung cấp của công cụ.
    static func loginHosts(_ id: CLIBackendID) -> [String] {
        switch id {
        case .claude: ["claude.com", "claude.ai", "anthropic.com"]
        case .codex: ["openai.com", "chatgpt.com"]
        case .agy: ["google.com", "antigravity.google"]
        case .opencode: []
        }
    }

    static func extractLoginURL(_ id: CLIBackendID, _ text: String) -> URL? {
        let clean = stripAnsi(text)
        guard let re = try? NSRegularExpression(pattern: #"https://[^\s"'<>\x00-\x1f]+"#) else { return nil }
        for m in re.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
            let raw = String(clean[Range(m.range, in: clean)!]).replacingOccurrences(of: #"[.,;:)\]]+$"#, with: "", options: .regularExpression)
            guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { continue }
            if loginHosts(id).contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return nil
    }

    static func asksForCode(_ text: String) -> Bool {
        stripAnsi(text).range(of: #"(paste|enter) (the )?(authorization )?code"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Mã dán vào chỉ gồm chữ, số và vài ký hiệu; không xuống dòng, không dấu cách.
    static func validCode(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._~#:/+=-]{6,4000}$"#, options: .regularExpression) != nil
    }

    /// Dòng hiển thị cho người dùng: bỏ mã màu, rút địa chỉ web còn tên miền.
    static func displayLine(_ s: String) -> String {
        let t = stripAnsi(s).replacingOccurrences(of: #"https?://\S+"#, with: "[liên kết]", options: .regularExpression)
        return String(t.trimmingCharacters(in: .whitespaces).prefix(160))
    }
}

/// Cài và đăng nhập công cụ AI ngay trong PVTA, không mở Terminal (trừ bước đăng nhập agy/opencode).
/// Thông tin đăng nhập do chính công cụ lưu; PVTA không giữ mật khẩu hay token.
public actor ToolSetup {
    private final class Run: @unchecked Sendable {
        let backend: CLIBackendID
        let kind: String
        private let lock = NSLock()
        private var lines: [String] = []
        private var raw = ""
        private var partial = ["", ""]
        private(set) var url: URL?
        private(set) var phase = SetupEvent.Phase.running
        private var handle: CLIProcess.Handle?
        var work: Task<ToolStatus, Error>?

        init(backend: CLIBackendID, kind: String) { self.backend = backend; self.kind = kind }

        func setHandle(_ h: CLIProcess.Handle) { lock.lock(); handle = h; lock.unlock() }

        /// Nhận chữ công cụ in ra; trả về sự kiện mới và đường dẫn đăng nhập lần đầu thấy (nếu có).
        func feed(isError: Bool, _ chunk: Data, watchLogin: Bool) -> (SetupEvent, URL?) {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: chunk, as: UTF8.self)
            raw = String((raw + text).suffix(6000))
            let idx = isError ? 1 : 0
            var parts = (partial[idx] + text).components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            partial[idx] = parts.removeLast()
            for p in parts { let l = SetupText.displayLine(p); if !l.isEmpty { lines.append(l) } }
            if lines.count > 8 { lines.removeFirst(lines.count - 8) }
            var opened: URL?
            if watchLogin {
                if url == nil, let u = SetupText.extractLoginURL(backend, raw) { url = u; opened = u }
                if phase == .running, SetupText.asksForCode(String(raw.suffix(400))) { phase = .code }
            }
            return (event(), opened)
        }

        func event(_ phase: SetupEvent.Phase? = nil, message: String? = nil) -> SetupEvent {
            SetupEvent(backend: backend, kind: kind, phase: phase ?? self.phase, lines: lines, url: url?.absoluteString, message: message)
        }

        /// Gửi mã người dùng dán vào công cụ; chỉ nhận khi công cụ đã hỏi mã.
        func sendCode(_ code: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard phase == .code, let handle else { throw PVTAError("Công cụ chưa yêu cầu nhập mã.") }
            guard SetupText.validCode(code) else { throw PVTAError("Mã không hợp lệ. Hãy dán đúng mã hiện trên trang đăng nhập.") }
            handle.write(code + "\n")
            phase = .running
        }
    }

    private let env: CLIEnvironment
    private let home: URL
    private let transport: HTTPTransport
    private let opener: @Sendable (URL) -> Void
    private let emit: @Sendable (SetupEvent) -> Void
    private let installTimeout: Duration
    private let pollInterval: Duration
    private var runs: [CLIBackendID: Run] = [:]

    public init(env: CLIEnvironment, home: URL, transport: HTTPTransport, opener: @escaping @Sendable (URL) -> Void,
                emit: @escaping @Sendable (SetupEvent) -> Void, installTimeout: Duration = .seconds(10 * 60),
                pollInterval: Duration = .seconds(3)) {
        self.pollInterval = pollInterval
        self.env = env
        self.home = home
        self.transport = transport
        self.opener = opener
        self.emit = emit
        self.installTimeout = installTimeout
    }

    /// Mở đường dẫn hoặc tệp bằng chương trình mặc định của macOS (`open`).
    public static let systemOpener: @Sendable (URL) -> Void = { url in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.isFileURL ? url.path : url.absoluteString]
        try? p.run()
    }

    private func begin(_ id: CLIBackendID, kind: String) throws -> Run {
        guard runs[id] == nil else { throw PVTAError("\(id.name) đang được cài hoặc đăng nhập. Hãy chờ xong hoặc bấm Dừng.") }
        let run = Run(backend: id, kind: kind)
        runs[id] = run
        return run
    }

    private func end(_ id: CLIBackendID) { runs[id] = nil }

    private func execute(_ run: Run, _ body: @escaping @Sendable () async throws -> ToolStatus) async throws -> ToolStatus {
        let work = Task { try await body() }
        run.work = work
        emit(run.event(.running))
        do {
            let status = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            emit(run.event(.done, message: status.detail))
            end(run.backend)
            return status
        } catch {
            let message = error is CancellationError ? "Đã dừng theo yêu cầu." : UserMessage.text(for: error)
            emit(run.event(.failed, message: message))
            end(run.backend)
            throw error is CancellationError ? PVTAError(message) : error
        }
    }

    public func install(_ id: CLIBackendID) async throws -> ToolStatus {
        _ = try ToolInstaller.info(id)
        let run = try begin(id, kind: "install")
        let (env, home, transport, emit, timeout) = (self.env, self.home, self.transport, self.emit, installTimeout)
        return try await execute(run) {
            let installer = try await ToolInstaller.download(id, into: home, transport: transport)
            let (bin, args) = ToolInstaller.command(id, file: installer.file)
            let exit = try await CLIProcess.run(binary: bin, args: args, environment: env.childEnvironment(), directory: installer.directory,
                                                stdin: .none, timeout: timeout) { isError, chunk in
                emit(run.feed(isError: isError, chunk, watchLogin: false).0)
            }
            try Task.checkCancellation()
            // Mở trình cài hay chạy xong chưa phải là cài thành công: chỉ tính khi công cụ thật sự chạy được.
            let status = await ToolHealth.check(id, in: env)
            if exit.timedOut { throw PVTAError("Cài \(id.name) quá thời gian cho phép nên PVTA đã dừng. Hãy thử lại hoặc cài theo \(id.docs).") }
            guard exit.code == 0, status.installed else {
                throw PVTAError("Cài \(id.name) chưa thành công. Hãy thử lại; nếu vẫn lỗi, cài theo hướng dẫn tại \(id.docs).")
            }
            return status
        }
    }

    public func login(_ id: CLIBackendID, deviceCode: Bool = false) async throws -> ToolStatus {
        guard env.find(id) != nil else {
            throw PVTAError("Máy chưa có \(id.name). " + ToolHealth.steps(id, state: .notInstalled).joined(separator: " "))
        }
        let run = try begin(id, kind: "login")
        let (env, home, emit, opener, poll) = (self.env, self.home, self.emit, self.opener, self.pollInterval)
        return try await execute(run) {
            switch id {
            case .claude, .codex:
                let args = id == .claude ? ["auth", "login"] : (deviceCode ? ["login", "--device-auth"] : ["login"])
                try env.prepareWorkDirectory()
                let exit = try await CLIProcess.run(binary: env.find(id)!, args: args, environment: env.childEnvironment(for: id),
                                                    directory: env.workDirectory, stdin: .interactive, timeout: .seconds(10 * 60),
                                                    onStart: { run.setHandle($0) }) { isError, chunk in
                    let (event, url) = run.feed(isError: isError, chunk, watchLogin: true)
                    if let url { opener(url) }
                    emit(event)
                }
                try Task.checkCancellation()
                let status = await ToolHealth.check(id, in: env)
                guard status.state == .ready else {
                    throw PVTAError(exit.timedOut ? "Đăng nhập \(id.name) quá thời gian cho phép. Hãy thử lại." : "Đăng nhập \(id.name) chưa thành công. Hãy thử lại; nếu trình duyệt không mở được, dùng đăng nhập bằng mã thiết bị.")
                }
                return status
            case .agy, .opencode:
                // Hai công cụ này chỉ đăng nhập qua giao diện dòng lệnh: mở Terminal cho riêng bước này.
                let dir = home.appendingPathComponent("installers/login-\(id.rawValue)-\(UUID().uuidString.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = dir.appendingPathComponent("dang-nhap.command")
                let quoted = "'" + env.find(id)!.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let command = id == .agy ? quoted : quoted + " auth login"
                try Data("#!/bin/bash\nclear\necho 'Đăng nhập \(id.name) cho PVTA. Làm theo hướng dẫn, xong thì quay lại PVTA.'\n\(command)\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                opener(file)
                if id == .opencode { return await ToolHealth.check(id, in: env) }
                // Đợi tối đa 10 phút cho tới khi agy nhận ra đã đăng nhập.
                let deadline = Date().addingTimeInterval(10 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: poll)
                    let status = await ToolHealth.check(id, in: env)
                    if status.state == .ready { return status }
                }
                throw PVTAError("Chưa thấy \(id.name) đăng nhập xong sau 10 phút. Hãy hoàn tất đăng nhập trong cửa sổ Terminal rồi bấm Kiểm tra lại.")
            }
        }
    }

    public func sendCode(_ id: CLIBackendID, _ code: String) throws {
        guard let run = runs[id] else { throw PVTAError("Không có phiên đăng nhập \(id.name) nào đang chờ mã.") }
        try run.sendCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
        emit(run.event())
    }

    public func cancel(_ id: CLIBackendID) {
        runs[id]?.work?.cancel()
    }
}
