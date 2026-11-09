import Foundation

/// Cách đưa dữ liệu vào stdin của tiến trình con.
enum StdinMode {
    case none
    case text(String)
    /// Giữ mở để gửi thêm sau (ví dụ mã đăng nhập); dùng `CLIProcess.Handle.write`.
    case interactive
}

struct CLIExit {
    var code: Int32?        // nil nếu bị tín hiệu giết
    var timedOut: Bool
    var stderrTail: String
}

/// Chạy một chương trình ngoài bằng `posix_spawn` trong nhóm tiến trình riêng, để hủy là dừng cả cây tiến trình.
enum CLIProcess {
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        init(fd: Int32) { self.fd = fd }

        func write(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            guard fd >= 0 else { return }
            let data = Array(text.utf8)
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }

        func closeStdin() {
            lock.lock(); defer { lock.unlock() }
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    private final class Killer: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        private var exited = false
        private(set) var timedOut = false
        init(pid: pid_t) { self.pid = pid }

        func markExited() { lock.lock(); exited = true; lock.unlock() }

        func terminate(timeout: Bool = false) {
            lock.lock()
            if timeout { timedOut = true }
            let alive = !exited
            lock.unlock()
            guard alive else { return }
            killpg(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); let stillAlive = !exited; lock.unlock()
                if stillAlive { killpg(pid, SIGKILL) }
            }
        }
    }

    /// Tách dòng từ các đoạn dữ liệu đến rời rạc.
    struct LineSplitter {
        private var buffer = Data()
        mutating func feed(_ chunk: Data) -> [String] {
            buffer.append(chunk)
            var out: [String] = []
            while let i = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                out.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...i)
            }
            return out
        }
        mutating func flush() -> String? {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }

    private static func chunks(fd: Int32) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Thread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    continuation.yield(Data(buf[0..<n]))
                }
                close(fd)
                continuation.finish()
            }.start()
        }
    }

    /// Chạy chương trình, gọi `onOutput` với từng đoạn chữ ra (stdout và stderr riêng), trả về khi tiến trình thoát.
    /// Hủy Task hoặc hết `timeout` thì dừng cả nhóm tiến trình.
    static func run(binary: String, args: [String], environment: [String: String], directory: URL,
                    stdin mode: StdinMode, timeout: Duration,
                    onStart: (@Sendable (Handle) -> Void)? = nil,
                    onOutput: @escaping @Sendable (_ isError: Bool, _ chunk: Data) -> Void) async throws -> CLIExit {
        signal(SIGPIPE, SIG_IGN)   // ghi vào ống đã đóng chỉ trả lỗi, không giết PVTA

        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw PVTAError("PVTA không khởi động được công cụ ngoài (hết tài nguyên hệ thống). Hãy thử lại.")
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }

        let argv: [UnsafeMutablePointer<CChar>?] = ([binary] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &actions, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw PVTAError("PVTA không chạy được công cụ \(URL(fileURLWithPath: binary).lastPathComponent). Hãy kiểm tra công cụ còn nguyên vẹn rồi thử lại.")
        }

        let childPid = pid, outFd = outPipe[0], errFd = errPipe[0]
        let killer = Killer(pid: childPid)
        let handle = Handle(fd: inPipe[1])
        switch mode {
        case .none: handle.closeStdin()
        case .text(let s):
            // Ghi ở luồng riêng: prompt dài hơn bộ đệm ống thì không làm kẹt việc đọc đầu ra.
            DispatchQueue.global().async { handle.write(s); handle.closeStdin() }
        case .interactive: onStart?(handle)
        }

        return await withTaskCancellationHandler {
            let timer = Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                killer.terminate(timeout: true)
            }
            async let errText: String = {
                var tail = ""
                for await c in chunks(fd: errFd) {
                    onOutput(true, c)
                    tail = String((tail + String(decoding: c, as: UTF8.self)).suffix(4000))
                }
                return tail
            }()
            for await c in chunks(fd: outFd) { onOutput(false, c) }
            let tail = await errText
            let status: Int32 = await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    var st: Int32 = 0
                    while waitpid(childPid, &st, 0) < 0 && errno == EINTR {}
                    cont.resume(returning: st)
                }
            }
            killer.markExited()
            timer.cancel()
            handle.closeStdin()
            let exited = (status & 0x7f) == 0
            return CLIExit(code: exited ? (status >> 8) & 0xff : nil, timedOut: killer.timedOut, stderrTail: tail)
        } onCancel: {
            killer.terminate()
        }
    }
}
