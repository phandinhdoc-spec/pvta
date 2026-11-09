import Foundation

/// Nơi tìm công cụ dòng lệnh và môi trường chạy chúng.
/// Ứng dụng mở từ Finder không có PATH của shell nên phải tìm thêm ở các thư mục cài thường gặp.
public struct CLIEnvironment: Sendable {
    public var environment: [String: String]
    /// Thư mục làm việc riêng, trống: công cụ không đọc nhầm thư mục của người dùng.
    public var workDirectory: URL
    var extraDirs: [String]

    public static func defaultExtraDirs(home: String = NSHomeDirectory()) -> [String] {
        [".local/bin", ".claude/local", ".npm-global/bin", ".antigravity/bin", ".bun/bin", ".volta/bin", ".opencode/bin"]
            .map { home + "/" + $0 } + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, workDirectory: URL,
                extraDirs: [String] = CLIEnvironment.defaultExtraDirs()) {
        self.environment = environment
        self.workDirectory = workDirectory
        self.extraDirs = extraDirs
    }

    private var searchDirs: [String] {
        var seen = Set<String>()
        return ((environment["PATH"] ?? "").split(separator: ":").map(String.init) + extraDirs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Đường dẫn công cụ: biến `PVTA_<TÊN>_BIN` nếu hợp lệ, không thì tìm trong PATH và thư mục cài thường gặp.
    public func find(_ id: CLIBackendID) -> String? {
        if let custom = environment[id.envVar], Self.isExecutable(custom) { return custom }
        return searchDirs.map { $0 + "/" + id.binary }.first(where: Self.isExecutable)
    }

    /// Bỏ khóa API và token trong môi trường để công cụ dùng tài khoản đã đăng nhập, không tính phí theo khóa.
    public func childEnvironment(for id: CLIBackendID? = nil) -> [String: String] {
        var env = environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "GEMINI_API_KEY",
                    "GOOGLE_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"] { env[key] = nil }
        env["PATH"] = searchDirs.joined(separator: ":")
        for (k, v) in id?.childEnvironment ?? [:] { env[k] = v }
        return env
    }

    func prepareWorkDirectory() throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Chạy một lệnh ngắn và lấy chữ ra (dùng để kiểm tra phiên bản, đăng nhập).
    func capture(_ binary: String, _ args: [String], id: CLIBackendID?, timeout: Duration = .seconds(15)) async -> (exit: CLIExit?, output: String) {
        guard (try? prepareWorkDirectory()) != nil else { return (nil, "") }
        let box = OutputBox()
        let exit = try? await CLIProcess.run(binary: binary, args: args, environment: childEnvironment(for: id),
                                             directory: workDirectory, stdin: .none, timeout: timeout) { _, chunk in box.add(chunk) }
        return (exit, box.text)
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data.prefix(100_000), as: UTF8.self) }
}
