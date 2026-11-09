import Darwin
import Foundation

/// Đầu ra trực tiếp ra stdout của terminal (TTY / PTY).
public final class TerminalOutputSink: CLIOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var inDelta = false
    private var currentPrompt: String = "[pvta:chat]> "

    public init() {}

    public func setPrompt(_ prompt: String) {
        lock.lock()
        self.currentPrompt = prompt
        lock.unlock()
    }

    public func writeLine(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if inDelta {
            writeRaw("\n")
            inDelta = false
        }
        writeRaw(text + "\n")
    }

    public func writeDelta(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        inDelta = true
        writeRaw(text)
    }

    public func endDelta() {
        lock.lock()
        defer { lock.unlock() }
        if inDelta {
            writeRaw("\n")
            inDelta = false
        }
    }

    public func promptChanged(_ prompt: String) {
        lock.lock()
        defer { lock.unlock() }
        self.currentPrompt = prompt
        if inDelta {
            writeRaw("\n")
            inDelta = false
        }
        if !currentPrompt.isEmpty {
            writeRaw(currentPrompt)
        }
    }

    public func writeRaw(_ string: String) {
        let data = Data(string.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += n
            }
        }
        fflush(stdout)
    }
}

/// Sự kiện phím nhận từ terminal (TTY/PTY).
public enum TerminalKeyEvent: Sendable, Equatable {
    case char(Character)
    case enter
    case backspace
    case clearLine
    case tab
    case ctrlC
    case ctrlD
    case arrowUp
    case arrowDown
    case eof
}

/// Điều khiển chế độ raw của TTY/PTY và chạy vòng lặp giao diện dòng lệnh tương tác.
public enum InteractiveTerminal {

    /// Khởi chạy phiên CLI tương tác trên terminal hiện tại.
    public static func run(cwd: String = FileManager.default.currentDirectoryPath, paths: DataPaths = DataPaths.resolve()) async throws {
        let node = try await PVTANode.open(paths: paths)
        let sink = TerminalOutputSink()
        let session = try InteractiveSession(node: node, cwd: cwd, output: sink)
        var cachedPrompt = "[pvta:chat]> "
        sink.setPrompt(cachedPrompt)

        // Khởi động phiên (session.start tự động in dòng nhắc đầu tiên)
        try await session.start()
        cachedPrompt = await session.promptLabel()
        sink.setPrompt(cachedPrompt)

        // Thiết lập chế độ TTY nếu đầu vào là terminal hoặc pseudo-terminal
        var origTermios = termios()
        let isTTY = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &origTermios) == 0
        if isTTY {
            var raw = origTermios
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
            raw.c_iflag &= ~tcflag_t(IXON)
            raw.c_iflag |= tcflag_t(ICRNL)
            raw.c_oflag |= tcflag_t(OPOST | ONLCR)
            withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
                ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                    cc[Int(VMIN)] = 1
                    cc[Int(VTIME)] = 0
                }
            }
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer {
            if isTTY {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
            }
        }

        let (keyStream, keyContinuation) = AsyncStream.makeStream(of: TerminalKeyEvent.self)

        // Bắt tín hiệu SIGINT / SIGTERM để hủy an toàn hoặc thoát sạch
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        Foundation.signal(SIGINT, SIG_IGN)
        Foundation.signal(SIGTERM, SIG_IGN)
        sigintSource.setEventHandler { keyContinuation.yield(.ctrlC) }
        sigtermSource.setEventHandler { keyContinuation.yield(.ctrlD) }
        sigintSource.resume()
        sigtermSource.resume()
        defer {
            sigintSource.cancel()
            sigtermSource.cancel()
        }

        // Luồng đọc byte từ STDIN_FILENO
        startStdinReader(isTTY: isTTY, continuation: keyContinuation)

        var lineBuffer = ""
        var history: [String] = []
        var historyIndex: Int? = nil

        for await event in keyStream {
            switch event {
            case .char(let ch):
                lineBuffer.append(ch)
                if isTTY { sink.writeRaw(String(ch)) }

            case .backspace:
                if !lineBuffer.isEmpty {
                    lineBuffer.removeLast()
                    if isTTY { sink.writeRaw("\u{08} \u{08}") }
                }

            case .clearLine:
                lineBuffer = ""
                if isTTY {
                    cachedPrompt = await session.promptLabel()
                    sink.writeRaw("\r\u{1B}[2K" + cachedPrompt)
                }

            case .arrowUp:
                guard !history.isEmpty else { break }
                let nextIdx: Int
                if let cur = historyIndex {
                    nextIdx = max(0, cur - 1)
                } else {
                    nextIdx = history.count - 1
                }
                historyIndex = nextIdx
                lineBuffer = history[nextIdx]
                if isTTY {
                    cachedPrompt = await session.promptLabel()
                    sink.writeRaw("\r\u{1B}[2K" + cachedPrompt + lineBuffer)
                }

            case .arrowDown:
                guard let cur = historyIndex else { break }
                if cur + 1 < history.count {
                    historyIndex = cur + 1
                    lineBuffer = history[cur + 1]
                } else {
                    historyIndex = nil
                    lineBuffer = ""
                }
                if isTTY {
                    cachedPrompt = await session.promptLabel()
                    sink.writeRaw("\r\u{1B}[2K" + cachedPrompt + lineBuffer)
                }

            case .tab:
                let list = await session.suggestions(for: lineBuffer)
                if let first = list.first {
                    if isTTY { sink.writeRaw("\n") }
                    if list.count > 1 {
                        let preview = list.prefix(8).map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n")
                        sink.writeLine("Gợi ý (\(list.count)):\n\(preview)")
                    }
                    lineBuffer = await session.applySuggestion(first, to: lineBuffer)
                    cachedPrompt = await session.promptLabel()
                    if isTTY {
                        sink.writeRaw(cachedPrompt + lineBuffer)
                    }
                }

            case .ctrlC:
                sink.writeRaw("^C\n")
                let wasBusy = await session.busy
                if !lineBuffer.isEmpty && !wasBusy {
                    lineBuffer = ""
                    historyIndex = nil
                    cachedPrompt = await session.promptLabel()
                    sink.writeRaw(cachedPrompt)
                } else {
                    lineBuffer = ""
                    historyIndex = nil
                    await session.cancelCurrent(silent: false)
                    cachedPrompt = await session.promptLabel()
                }

            case .enter:
                if isTTY { sink.writeRaw("\n") }
                let submitted = lineBuffer
                lineBuffer = ""
                historyIndex = nil
                let trimmed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if history.last != trimmed { history.append(trimmed) }
                    // Nếu gọi /editor trên TTY, khôi phục termios tạm thời để trình soạn thảo ngoài điều khiển terminal
                    if trimmed.lowercased() == "/editor" && isTTY {
                        _ = tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
                    }
                    let keepGoing = await session.submit(trimmed, waitForCompletion: false)
                    if trimmed.lowercased() == "/editor" && isTTY {
                        var raw = origTermios
                        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
                        raw.c_iflag &= ~tcflag_t(IXON)
                        raw.c_iflag |= tcflag_t(ICRNL)
                        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
                        _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
                    }
                    if !keepGoing {
                        await node.shutdown()
                        return
                    }
                }
                cachedPrompt = await session.promptLabel()
                sink.setPrompt(cachedPrompt)
                if !(await session.busy) {
                    sink.writeRaw(cachedPrompt)
                }

            case .ctrlD, .eof:
                if isTTY { sink.writeRaw("\n") }
                await session.stopSession()
                await node.shutdown()
                return
            }
        }

        await session.stopSession()
        await node.shutdown()
    }

    private static func startStdinReader(isTTY: Bool, continuation: AsyncStream<TerminalKeyEvent>.Continuation) {
        DispatchQueue.global(qos: .userInteractive).async {
            var buf = [UInt8](repeating: 0, count: 256)
            var utf8Pending: [UInt8] = []

            func flushPendingUTF8() {
                guard !utf8Pending.isEmpty else { return }
                let str = String(decoding: utf8Pending, as: UTF8.self)
                utf8Pending.removeAll()
                for ch in str {
                    continuation.yield(.char(ch))
                }
            }

            while true {
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n < 0 {
                    if errno == EINTR { continue }
                    flushPendingUTF8()
                    continuation.yield(.eof)
                    continuation.finish()
                    break
                }
                if n == 0 {
                    flushPendingUTF8()
                    continuation.yield(.eof)
                    continuation.finish()
                    break
                }

                var i = 0
                while i < n {
                    let b = buf[i]
                    if b == 0x1B { // Escape sequence
                        flushPendingUTF8()
                        if i + 2 < n && buf[i + 1] == 0x5B {
                            let code = buf[i + 2]
                            if code == 0x41 { continuation.yield(.arrowUp) }
                            else if code == 0x42 { continuation.yield(.arrowDown) }
                            i += 3
                            continue
                        }
                        i += 1
                        continue
                    }

                    if b < 0x20 || b == 0x7F {
                        flushPendingUTF8()
                        switch b {
                        case 0x03:
                            continuation.yield(.ctrlC)
                        case 0x04:
                            continuation.yield(.ctrlD)
                        case 0x09:
                            continuation.yield(.tab)
                        case 0x0A, 0x0D:
                            // Gộp \r\n nếu đi liền nhau
                            if b == 0x0D && i + 1 < n && buf[i + 1] == 0x0A {
                                i += 1
                            }
                            continuation.yield(.enter)
                        case 0x15:
                            continuation.yield(.clearLine)
                        case 0x08, 0x7F:
                            continuation.yield(.backspace)
                        default:
                            break
                        }
                        i += 1
                        continue
                    }

                    utf8Pending.append(b)
                    if let valid = String(bytes: utf8Pending, encoding: .utf8) {
                        utf8Pending.removeAll()
                        for ch in valid {
                            continuation.yield(.char(ch))
                        }
                    } else if utf8Pending.count >= 4 {
                        flushPendingUTF8()
                    }
                    i += 1
                }
            }
        }
    }
}
