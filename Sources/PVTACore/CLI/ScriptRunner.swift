import Darwin
import Foundation

/// Kết quả chạy script thật trong thư mục làm việc (`/test`, `/typecheck`, `/lint`, `/build`).
public struct ScriptResult: Sendable, Equatable {
    public var code: Int32
    public var stdout: String
    public var stderr: String
    public var cancelled: Bool

    public init(code: Int32, stdout: String, stderr: String, cancelled: Bool = false) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
        self.cancelled = cancelled
    }
}

/// Chạy `git diff` và các script trong `package.json` (hoặc `Package.swift`) trong thư mục làm việc.
/// Mọi tiến trình con được đặt trong nhóm tiến trình (process group) riêng để `Ctrl-C` và `/stop` hủy sạch cả cây tiến trình.
public enum ScriptRunner {
    public static let maxOutputBytes = 256 * 1024

    /// Chạy `git diff` an toàn trong `cwd` (tắt external diff và textconv để không kích hoạt lệnh cấu hình ngoài).
    public static func gitDiff(cwd: String, target: String? = nil) throws -> String {
        let realCwd = try WorkspaceGuard.canonicalCwd(cwd)
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--"]
        if let t = target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let full = try WorkspaceGuard.resolveInWorkspace(cwd: realCwd, inputPath: t, mustExist: true)
            let rel: String
            if full == realCwd {
                rel = "."
            } else {
                rel = String(full.dropFirst(realCwd.count + 1))
            }
            args.append(rel)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: realCwd)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw PVTAError("Không chạy được git: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let stdout = String(decoding: outData.prefix(maxOutputBytes), as: UTF8.self)
        let stderr = String(decoding: errData.prefix(maxOutputBytes), as: UTF8.self)
        if proc.terminationStatus != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PVTAError(msg.isEmpty ? "Không chạy được git diff trong thư mục hiện tại." : msg)
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Không có thay đổi git." : stdout
    }

    /// Kiểm tra và lấy danh sách đối số lệnh thực thi cho `/test`, `/typecheck`, `/lint`, `/build`.
    public static func resolveScriptCommand(cwd: String, script: String) throws -> (realCwd: String, argv: [String]) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil else {
            throw PVTAError("Tên script không hợp lệ: \(script)")
        }
        let realCwd = try WorkspaceGuard.canonicalCwd(cwd)
        let pkgCandidate = (realCwd as NSString).appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: pkgCandidate) {
            let pkgPath = try WorkspaceGuard.resolveInWorkspace(cwd: realCwd, inputPath: "package.json", mustExist: true)
            var st = stat()
            guard stat(pkgPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= WorkspaceGuard.maxCodeFileBytes else {
                throw PVTAError("package.json không hợp lệ hoặc quá lớn.")
            }
            guard let data = FileManager.default.contents(atPath: pkgPath),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw PVTAError("Không đọc được package.json hợp lệ.")
            }
            guard case .object(let scripts)? = json["scripts"],
                  let cmd = scripts[trimmed]?.string,
                  !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PVTAError("Không có script \"\(trimmed)\" trong package.json.")
            }
            return (realCwd, ["/usr/bin/env", "npm", "run", trimmed])
        }

        // Hỗ trợ dự án Swift nếu có Package.swift mà không có package.json
        let swiftCandidate = (realCwd as NSString).appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: swiftCandidate) {
            _ = try WorkspaceGuard.resolveInWorkspace(cwd: realCwd, inputPath: "Package.swift", mustExist: true)
            switch trimmed {
            case "build", "typecheck":
                return (realCwd, ["/usr/bin/env", "swift", "build"])
            case "test":
                return (realCwd, ["/usr/bin/env", "swift", "test"])
            default:
                throw PVTAError("Không tìm thấy package.json và dự án Swift không có script \"\(trimmed)\".")
            }
        }

        throw PVTAError("Thư mục hiện tại không có package.json để chạy lệnh /\(trimmed).")
    }

    /// Chạy script trong nhóm tiến trình riêng, hỗ trợ hủy qua Task cancellation hoặc `killProcessGroup`.
    public static func runPackageScript(
        cwd: String,
        script: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onSpawn: (@Sendable (pid_t?) -> Void)? = nil
    ) async throws -> ScriptResult {
        let (realCwd, argv) = try resolveScriptCommand(cwd: cwd, script: script)
        return try await spawnProcessGroup(argv: argv, cwd: realCwd, environment: environment, onSpawn: onSpawn)
    }

    /// Gửi tín hiệu dừng cho toàn bộ nhóm tiến trình của script đang chạy.
    public static func killProcessGroup(_ pgid: pid_t) {
        guard pgid > 0 else { return }
        _ = Darwin.kill(-pgid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = Darwin.kill(-pgid, SIGKILL)
        }
    }

    private static func spawnProcessGroup(
        argv: [String],
        cwd: String,
        environment: [String: String],
        onSpawn: (@Sendable (pid_t?) -> Void)?
    ) async throws -> ScriptResult {
        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { throw PVTAError("Không tạo được đường ống đọc stdout.") }
        guard pipe(&errFds) == 0 else {
            close(outFds[0]); close(outFds[1])
            throw PVTAError("Không tạo được đường ống đọc stderr.")
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFds[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outFds[0])
        posix_spawn_file_actions_addclose(&actions, outFds[1])
        posix_spawn_file_actions_addclose(&actions, errFds[0])
        posix_spawn_file_actions_addclose(&actions, errFds[1])
        _ = cwd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var envStrings = environment.map { "\($0.key)=\($0.value)" }
        if environment["PATH"] == nil {
            envStrings.append("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        }
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgs where ptr != nil { free(ptr) }
            for ptr in cEnv where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let spawnErr = argv[0].withCString { binPtr in
            cArgs.withUnsafeBufferPointer { argsBuf in
                cEnv.withUnsafeBufferPointer { envBuf in
                    posix_spawn(&pid, binPtr, &actions, &attr,
                                UnsafeMutablePointer(mutating: argsBuf.baseAddress!),
                                UnsafeMutablePointer(mutating: envBuf.baseAddress!))
                }
            }
        }
        close(outFds[1])
        close(errFds[1])

        guard spawnErr == 0 else {
            close(outFds[0])
            close(errFds[0])
            throw PVTAError("Không thể khởi chạy lệnh (mã lỗi \(spawnErr)).")
        }

        onSpawn?(pid)
        defer { onSpawn?(nil) }

        let outBox = ScriptDataBox(limit: maxOutputBytes)
        let errBox = ScriptDataBox(limit: maxOutputBytes)
        let outRead = outFds[0]
        let errRead = errFds[0]

        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(outRead); readGroup.leave() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(outRead, &buf, buf.count)
                if n > 0 { outBox.append(buf, count: n) }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(errRead); readGroup.leave() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(errRead, &buf, buf.count)
                if n > 0 { errBox.append(buf, count: n) }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    readGroup.wait()
                    let cancelled = Task.isCancelled || ((status & 0x7f) != 0)
                    let code: Int32
                    if (status & 0x7f) == 0 {
                        code = (status >> 8) & 0xff
                    } else {
                        code = 130
                    }
                    continuation.resume(returning: ScriptResult(
                        code: code,
                        stdout: outBox.text,
                        stderr: errBox.text,
                        cancelled: cancelled
                    ))
                }
            }
        } onCancel: {
            killProcessGroup(pid)
        }
    }
}

private final class ScriptDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { return }
        data.append(bytes, count: min(count, remaining))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
