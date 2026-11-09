import Darwin
import Foundation
import Testing
@testable import PVTACore

// MARK: - Helper tạo môi trường giả lập & PTY

/// Kịch bản AI giả dùng trong bộ kiểm thử `InteractiveSession` trực tiếp (không tốn tiền, không gọi mạng).
private final class FakeCLIBackendScript {
    let dir: URL
    let binURL: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-fake-cli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dir = base
        self.binURL = base.appendingPathComponent("fake-claude.py")

        let script = """
        #!/usr/bin/env python3
        import json, sys, time

        args = sys.argv[1:]
        if "--version" in args:
            print("1.0.0-fake")
            sys.exit(0)
        if len(args) >= 2 and args[0] == "auth" and args[1] == "status":
            print(json.dumps({"loggedIn": True}))
            sys.exit(0)

        prompt = sys.stdin.read()

        def emit_delta(text):
            ev = {
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "delta": {"type": "text_delta", "text": text}
                }
            }
            sys.stdout.write(json.dumps(ev, ensure_ascii=False) + "\\n")
            sys.stdout.flush()

        def emit_result(text):
            res = {
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "result": text,
                "session_id": "fake-session-1"
            }
            sys.stdout.write(json.dumps(res, ensure_ascii=False) + "\\n")
            sys.stdout.flush()

        if "Khảo sát yêu cầu và bối cảnh trước" in prompt:
            plan_obj = {
                "name": "Kế hoạch bài dạy mẫu",
                "questions": [],
                "steps": [
                    {
                        "id": "b1",
                        "name": "Soạn mục tiêu bài học",
                        "prompt": "THUC_HIEN_BUOC_B1",
                        "needs": [],
                        "outputs": [],
                        "criteria": "Có đủ mục tiêu"
                    }
                ]
            }
            raw = json.dumps(plan_obj, ensure_ascii=False)
            emit_delta(raw)
            emit_result(raw)
            sys.exit(0)

        if "THUC_HIEN_BUOC_B1" in prompt:
            out = "Đã hoàn thành bước 1: Mục tiêu bài học rõ ràng."
            emit_delta(out)
            emit_result(out)
            sys.exit(0)

        if "YEU_CAU_CHAM_HUY" in prompt and prompt.rfind("YEU_CAU_CHAM_HUY") > prompt.rfind("Trợ lý:"):
            emit_delta("Đang xử lý yêu cầu rất lâu...")
            for _ in range(60):
                time.sleep(0.5)
            emit_result("Xong muộn")
            sys.exit(0)

        if "YEU_CAU_GHI_TU_CHOI" in prompt:
            tail = prompt[prompt.rfind("YEU_CAU_GHI_TU_CHOI"):]
            if "KẾT QUẢ CÔNG CỤ fs_write" in tail:
                msg = "Đã dừng tạo tệp tu-choi.txt vì giáo viên từ chối."
                emit_delta(msg)
                emit_result(msg)
            else:
                call_text = 'Tôi xin phép ghi tệp tu-choi.txt.\\n```pvta-tool\\n{"tool":"fs_write","args":{"path":"tu-choi.txt","content":"Không được ghi"}}\\n```\\n'
                emit_delta(call_text)
                emit_result(call_text)
            sys.exit(0)

        if "YEU_CAU_GHI_DUYET" in prompt:
            tail = prompt[prompt.rfind("YEU_CAU_GHI_DUYET"):]
            if "KẾT QUẢ CÔNG CỤ fs_write" in tail:
                msg = "Đã ghi tệp duyet.txt thành công sau khi giáo viên duyệt."
                emit_delta(msg)
                emit_result(msg)
            else:
                call_text = 'Tôi xin phép ghi tệp duyet.txt.\\n```pvta-tool\\n{"tool":"fs_write","args":{"path":"duyet.txt","content":"Nội dung đã duyệt"}}\\n```\\n'
                emit_delta(call_text)
                emit_result(call_text)
            sys.exit(0)

        # Trả lời streaming mặc định
        part1 = "Xin chào giáo viên, "
        part2 = "đây là câu trả lời streaming từ AI giả."
        emit_delta(part1)
        time.sleep(0.05)
        emit_delta(part2)
        emit_result(part1 + part2)
        """
        try Data(script.utf8).write(to: binURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Điều khiển tiến trình `pvta` thật qua một pseudo-terminal (`openpty`).
private final class PTYHarness: @unchecked Sendable {
    let masterFD: Int32
    let process: Process
    private let lock = NSLock()
    private var buffer = ""
    private var readerRunning = true

    init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PVTAError("Không mở được pseudo-terminal (openpty).")
        }
        self.masterFD = master

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.environment = environment
        proc.currentDirectoryURL = currentDirectory
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        try proc.run()
        close(slave) // Đóng bản sao phía cha để khi con thoát thì master nhận EOF
        self.process = proc

        let fd = master
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var rawBuf = [UInt8](repeating: 0, count: 4096)
            while let self {
                let n = Darwin.read(fd, &rawBuf, rawBuf.count)
                if n > 0 {
                    let chunk = String(decoding: rawBuf[0..<n], as: UTF8.self)
                    self.lock.lock()
                    self.buffer += chunk
                    self.lock.unlock()
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func send(_ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(masterFD, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += n
            }
        }
    }

    /// Chờ tới khi đầu ra của PTY từ vị trí `sinceIndex` chứa `substring`.
    func waitFor(_ substring: String, afterOffset: Int = 0, timeout: TimeInterval = 12) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = output
            let utf8Count = current.utf8.count
            if utf8Count >= afterOffset {
                let startIdx = current.utf8.index(current.utf8.startIndex, offsetBy: min(afterOffset, utf8Count))
                let slice = String(current[startIdx...])
                if slice.contains(substring) {
                    return slice
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw PVTAError("Hết thời gian chờ '\(substring)' trên PTY. Đầu ra hiện có:\n\(output)")
    }

    func currentOffset() -> Int {
        output.utf8.count
    }

    func closeAndWait(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
        }
        close(masterFD)
    }
}

// MARK: - 1. Kiểm thử đầu-cuối bằng Pseudo-Terminal (openpty) với AI giả

@Suite("CLI Tương tác qua Pseudo-Terminal (PTY)")
struct CLITuongTacPTYTests {

    private var pvtaBinary: URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent(".build/debug/pvta")
            }
        }
        return URL(fileURLWithPath: "/Users/phananh/pvta/.build/debug/pvta")
    }

    @Test("Điều khiển qua pseudo-terminal: gửi tin streaming, duyệt, từ chối, hủy Ctrl-C, chạy Plan, mở lại hội thoại cũ")
    func dieuKhienQuaPseudoTerminal() async throws {
        let fakeAI = try FakeCLIBackendScript()
        defer { fakeAI.cleanup() }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-pty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let dataHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("lop-10a1", isDirectory: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var env = ProcessInfo.processInfo.environment
        env["PVTA_HOME"] = dataHome.path
        env["PVTA_CLAUDE_BIN"] = fakeAI.binURL.path
        env["PVTA_CODEX_BIN"] = "/usr/bin/false"
        env["PVTA_AGY_BIN"] = "/usr/bin/false"
        env["PVTA_OPENCODE_BIN"] = "/usr/bin/false"

        let pty = try PTYHarness(
            executable: pvtaBinary,
            arguments: ["--cwd", workspace.path],
            environment: env,
            currentDirectory: workspace
        )
        defer { pty.closeAndWait() }

        // 1. Khởi động mở hội thoại mới trong dự án của thư mục hiện tại
        let startupOut = try await pty.waitFor("[pvta:chat]> ")
        #expect(startupOut.contains("Dự án: lop-10a1"))
        #expect(startupOut.contains("Hội thoại mới:"))
        let firstChatId = try #require(Self.extractBracketID(from: startupOut, prefix: "Hội thoại mới: Hội thoại mới ["))

        // 2. Gửi tin nhắn và nhận câu trả lời streaming
        var offset = pty.currentOffset()
        pty.send("Xin chào buổi sáng\n")
        let chatReply = try await pty.waitFor("đây là câu trả lời streaming từ AI giả.", afterOffset: offset)
        #expect(chatReply.contains("Xin chào giáo viên, "))
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: offset)

        // 3. Hỏi duyệt ngay trong terminal & Duyệt (/approve)
        offset = pty.currentOffset()
        pty.send("YEU_CAU_GHI_DUYET\n")
        let approvalPrompt = try await pty.waitFor("-> Gõ /approve ", afterOffset: offset)
        let approveId = try #require(Self.extractActionID(from: approvalPrompt))
        let offsetAfterPrompt = pty.currentOffset()
        pty.send("/approve \(approveId)\n")
        let approvedResult = try await pty.waitFor("Đã ghi tệp duyet.txt thành công sau khi giáo viên duyệt.", afterOffset: offsetAfterPrompt)
        #expect(approvedResult.contains("Đã duyệt thao tác #\(approveId)"))
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: offsetAfterPrompt)
        let approvedFile = workspace.appendingPathComponent("duyet.txt")
        #expect(FileManager.default.fileExists(atPath: approvedFile.path))
        #expect(try String(contentsOf: approvedFile, encoding: .utf8) == "Nội dung đã duyệt")

        // 4. Hỏi duyệt ngay trong terminal & Từ chối (/decline)
        offset = pty.currentOffset()
        pty.send("YEU_CAU_GHI_TU_CHOI\n")
        let declinePrompt = try await pty.waitFor("-> Gõ /approve ", afterOffset: offset)
        let declineId = try #require(Self.extractActionID(from: declinePrompt))
        let offsetBeforeDecline = pty.currentOffset()
        pty.send("/decline \(declineId)\n")
        let declinedResult = try await pty.waitFor("Đã dừng tạo tệp tu-choi.txt vì giáo viên từ chối.", afterOffset: offsetBeforeDecline)
        #expect(declinedResult.contains("Đã từ chối thao tác #\(declineId)"))
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: offsetBeforeDecline)
        let declinedFile = workspace.appendingPathComponent("tu-choi.txt")
        #expect(!FileManager.default.fileExists(atPath: declinedFile.path))

        // 5. Hủy yêu cầu đang chạy bằng Ctrl-C an toàn
        offset = pty.currentOffset()
        pty.send("YEU_CAU_CHAM_HUY\n")
        _ = try await pty.waitFor("Đang xử lý yêu cầu rất lâu...", afterOffset: offset)
        let cancelOffset = pty.currentOffset()
        pty.send("\u{03}") // Ctrl-C
        let cancelOut = try await pty.waitFor("Đã gửi yêu cầu dừng.", afterOffset: cancelOffset)
        #expect(cancelOut.contains("^C"))
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: cancelOffset)

        // 6. Tạo và chạy Plan (/plan, /plans, /run)
        offset = pty.currentOffset()
        pty.send("/plan Lập kế hoạch bài dạy\n")
        let planCreatedOut = try await pty.waitFor("Đã tạo Plan (bản nháp — chưa tự động chạy):", afterOffset: offset)
        _ = try await pty.waitFor("Bước [b1]", afterOffset: offset)
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: offset)
        let fullPlanSlice = String(pty.output[pty.output.utf8.index(pty.output.utf8.startIndex, offsetBy: offset)...])
        let planId = try #require(Self.extractBracketID(from: fullPlanSlice, prefix: "Plan ["))
        #expect(planCreatedOut.contains("chưa tự động chạy"))

        offset = pty.currentOffset()
        pty.send("/run \(planId)\n")
        let planRunOut = try await pty.waitFor("Đã hoàn thành bước 1: Mục tiêu bài học rõ ràng.", afterOffset: offset)
        #expect(planRunOut.contains("trạng thái: done"))
        _ = try await pty.waitFor("[pvta:chat]> ", afterOffset: offset)

        // 7. Tạo hội thoại mới rồi mở lại hội thoại cũ (/new, /chats, /chat <id>)
        offset = pty.currentOffset()
        pty.send("/new Hội thoại thứ hai\n")
        _ = try await pty.waitFor("Đã tạo hội thoại mới: Hội thoại thứ hai", afterOffset: offset)

        offset = pty.currentOffset()
        pty.send("/chats\n")
        let chatsOut = try await pty.waitFor("Danh sách hội thoại", afterOffset: offset)
        #expect(chatsOut.contains(firstChatId))

        offset = pty.currentOffset()
        pty.send("/chat \(firstChatId)\n")
        let reopenedOut = try await pty.waitFor("Đã mở lại hội thoại:", afterOffset: offset)
        #expect(reopenedOut.contains(firstChatId))
        #expect(reopenedOut.contains("Xin chào buổi sáng"))

        // 8. Thoát sạch
        pty.send("/quit\n")
        _ = try await pty.waitFor("Tạm biệt!")
    }

    private static func extractBracketID(from text: String, prefix: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        let rest = text[range.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        return String(rest[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractActionID(from text: String) -> String? {
        guard let range = text.range(of: "[Cần duyệt #") else { return nil }
        let rest = text[range.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        return String(rest[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 2. Kiểm thử bảo mật đường dẫn & Symlink, Sửa Markdown, Lệnh lập trình và các lệnh `/`

@Suite("CLI Tương tác — Bảo mật đường dẫn, Markdown, Script & Các lệnh")
struct CLITuongTacChiTietTests {

    @Test("Giới hạn đường dẫn trong thư mục làm việc và chặn liên kết tượng trưng (symlink) trỏ ra ngoài")
    func chanDuongDanNgoaiThuMucVaSymlink() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-guard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let outsideDir = tempRoot.appendingPathComponent("outside", isDirectory: true)
        let dataHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let outsideFile = outsideDir.appendingPathComponent("bi-mat.md")
        try Data("# Bí mật\n".utf8).write(to: outsideFile)
        let insideFile = workspace.appendingPathComponent("hop-le.md")
        try Data("# Hợp lệ\nDòng 2".utf8).write(to: insideFile)

        // Tạo symlink bên trong workspace trỏ ra tệp bên ngoài
        let symlinkFile = workspace.appendingPathComponent("lien-ket-ngoai.md")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: outsideFile)

        let paths = DataPaths(home: dataHome)
        let node = try await PVTANode.open(paths: paths)
        let sink = CollectingOutputSink()
        let session = try InteractiveSession(node: node, cwd: workspace.path, output: sink)
        try await session.start()

        // 1. /code, /edit, /open, /attach đều chặn ../outside và symlink trỏ ra ngoài
        for cmd in [
            "/code ../outside/bi-mat.md",
            "/code lien-ket-ngoai.md",
            "/edit ../outside/bi-mat.md",
            "/edit lien-ket-ngoai.md",
            "/open ../outside/bi-mat.md",
            "/open lien-ket-ngoai.md",
            "/attach ../outside/bi-mat.md",
            "/attach lien-ket-ngoai.md"
        ] {
            sink.clear()
            await session.submit(cmd, waitForCompletion: true)
            #expect(sink.joined.contains("Đường dẫn nằm ngoài thư mục làm việc"), "Lệnh '\(cmd)' phải bị chặn nhưng trả về: \(sink.joined)")
        }

        // 2. Tệp thật bên trong workspace hoạt động bình thường
        sink.clear()
        await session.submit("/code hop-le.md", waitForCompletion: true)
        #expect(sink.joined.contains("   1 | # Hợp lệ"))
        #expect(sink.joined.contains("   2 | Dòng 2"))

        await session.stopSession()
        await node.shutdown()
    }

    @Test("Chỉnh sửa Markdown (/edit, /toc, /replace, /diff, /save nguyên tử, /undo, /discard, /editor)")
    func chinhSuaMarkdownDayDu() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-md-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let dataHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mdFile = workspace.appendingPathComponent("giao-an.md")
        let initialContent = """
        # Bài 1: Hàm số
        Nội dung mở đầu
        ```
        # Không phải tiêu đề trong khối mã
        ```
        ## 1. Khái niệm
        Chi tiết khái niệm
        """
        try Data(initialContent.utf8).write(to: mdFile)

        let paths = DataPaths(home: dataHome)
        let node = try await PVTANode.open(paths: paths)
        let sink = CollectingOutputSink()
        let session = try InteractiveSession(node: node, cwd: workspace.path, output: sink)
        try await session.start()

        // Mở bản nháp
        sink.clear()
        await session.submit("/edit giao-an.md", waitForCompletion: true)
        #expect(sink.joined.contains("Đã mở bản nháp Markdown"))

        // Mục lục (/toc) bỏ qua tiêu đề trong khối mã ```
        sink.clear()
        await session.submit("/toc", waitForCompletion: true)
        #expect(sink.joined.contains("Bài 1: Hàm số"))
        #expect(sink.joined.contains("  1. Khái niệm"))
        #expect(!sink.joined.contains("Không phải tiêu đề"))

        // Thay dòng (/replace) và xem /diff
        sink.clear()
        await session.submit("/replace 2 Nội dung mở đầu đã chỉnh sửa", waitForCompletion: true)
        await session.submit("/diff", waitForCompletion: true)
        #expect(sink.joined.contains("- Nội dung mở đầu"))
        #expect(sink.joined.contains("+ Nội dung mở đầu đã chỉnh sửa"))

        // /discard khôi phục về bản gốc
        sink.clear()
        await session.submit("/discard", waitForCompletion: true)
        await session.submit("/diff", waitForCompletion: true)
        #expect(sink.joined.contains("Không có thay đổi so với bản gốc."))

        // Sửa lại và /save nguyên tử
        sink.clear()
        await session.submit("/replace 2 Nội dung lưu lần 1", waitForCompletion: true)
        await session.submit("/save", waitForCompletion: true)
        #expect(sink.joined.contains("Đã lưu nguyên tử bản nháp"))
        let savedDisk = try String(contentsOf: mdFile, encoding: .utf8)
        #expect(savedDisk.contains("Nội dung lưu lần 1"))

        // /undo hoàn tác lần lưu gần nhất
        sink.clear()
        await session.submit("/undo", waitForCompletion: true)
        #expect(sink.joined.contains("Đã hoàn tác lần lưu gần nhất"))
        let undoneDisk = try String(contentsOf: mdFile, encoding: .utf8)
        #expect(undoneDisk == initialContent)

        // Kiểm tra tách đối số VISUAL/EDITOR có dấu nháy và chạy trình soạn thảo giả
        let parsedArgs = try MarkdownDraftManager.editorArgs(env: ["VISUAL": #"my-editor --wait "cờ có dấu cách""#])
        #expect(parsedArgs == ["my-editor", "--wait", "cờ có dấu cách"])

        let fakeEditor = tempRoot.appendingPathComponent("fake-editor.sh")
        try Data("#!/bin/sh\nprintf '# Đã sửa bằng editor\\n' > \"$1\"\n".utf8).write(to: fakeEditor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeEditor.path)

        var draft = try #require(await session.markdownDraft)
        let editorOk = try MarkdownDraftManager.runExternalEditor(&draft, env: ["VISUAL": fakeEditor.path])
        #expect(editorOk)
        #expect(draft.text == "# Đã sửa bằng editor\n")

        // Phát hiện xung đột khi tệp trên đĩa bị sửa bên ngoài trước khi /save
        try Data("Bị sửa bên ngoài".utf8).write(to: mdFile)
        await session.submit("/replace 1 # Tiêu đề mới", waitForCompletion: true)
        sink.clear()
        await session.submit("/save", waitForCompletion: true)
        #expect(sink.joined.contains("Tệp đã thay đổi trên đĩa ngoài phiên sửa"))

        await session.stopSession()
        await node.shutdown()
    }

    @Test("Lệnh lập trình (/test, /typecheck, /lint, /build) chạy script thật trong package.json và báo kết quả thật")
    func lenhLapTrinhChayScriptThat() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-code-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let dataHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let packageJSON = """
        {
          "name": "kiem-thu-cli",
          "version": "1.0.0",
          "scripts": {
            "test": "echo 'Kiem thu don vi OK'",
            "typecheck": "echo 'Kiem tra kieu OK'",
            "lint": "echo 'Loi lint o dong 5' >&2 && exit 1",
            "build": "echo 'Dung du an thanh cong'"
          }
        }
        """
        try Data(packageJSON.utf8).write(to: workspace.appendingPathComponent("package.json"))

        let paths = DataPaths(home: dataHome)
        let node = try await PVTANode.open(paths: paths)
        let sink = CollectingOutputSink()
        let session = try InteractiveSession(node: node, cwd: workspace.path, output: sink)
        try await session.start()

        // /test đạt
        sink.clear()
        await session.submit("/test", waitForCompletion: true)
        #expect(sink.joined.contains("Kiem thu don vi OK"))
        #expect(sink.joined.contains("[/test ĐẠT (mã thoát 0)]"))

        // /typecheck đạt
        sink.clear()
        await session.submit("/typecheck", waitForCompletion: true)
        #expect(sink.joined.contains("Kiem tra kieu OK"))
        #expect(sink.joined.contains("[/typecheck ĐẠT (mã thoát 0)]"))

        // /build đạt
        sink.clear()
        await session.submit("/build", waitForCompletion: true)
        #expect(sink.joined.contains("Dung du an thanh cong"))
        #expect(sink.joined.contains("[/build ĐẠT (mã thoát 0)]"))

        // /lint báo lỗi thật (mã thoát khác 0)
        sink.clear()
        await session.submit("/lint", waitForCompletion: true)
        #expect(sink.joined.contains("Loi lint o dong 5"))
        #expect(sink.joined.contains("[/lint LỖI (mã thoát 1)]"))

        // Chế độ chỉ đọc (chi-doc) chặn chạy script
        await session.submit("/access chi-doc", waitForCompletion: true)
        sink.clear()
        await session.submit("/test", waitForCompletion: true)
        #expect(sink.joined.contains("Quyền hiện tại là chỉ đọc (chi-doc)"))

        await session.stopSession()
        await node.shutdown()
    }

    @Test("Các lệnh quản lý phiên, chọn nguồn bằng $ và $$, quy tắc #khóa, kỹ năng /tên")
    func cacLenhQuanLyVaChonNguon() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-cmds-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let subDir = workspace.appendingPathComponent("tai-lieu-toan", isDirectory: true)
        let dataHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let docFile = subDir.appendingPathComponent("de-cuong-hoc-ky.txt")
        try Data("Nội dung đề cương học kỳ 1 môn Toán".utf8).write(to: docFile)

        let paths = DataPaths(home: dataHome)
        let node = try await PVTANode.open(paths: paths)
        let sink = CollectingOutputSink()
        let session = try InteractiveSession(node: node, cwd: workspace.path, output: sink)
        try await session.start()

        // 1. /models và /model
        sink.clear()
        await session.submit("/models", waitForCompletion: true)
        #expect(sink.joined.contains("Công cụ dòng lệnh AI:"))
        #expect(sink.joined.contains("Nhà cung cấp API:"))

        sink.clear()
        await session.submit("/model claude/sonnet", waitForCompletion: true)
        #expect(sink.joined.contains("Đã đổi model của hội thoại sang: claude/sonnet"))
        await session.submit("/model auto", waitForCompletion: true)
        #expect(sink.joined.contains("Đã đặt model của hội thoại về: auto"))

        // 2. /writing, /rules, /skills
        sink.clear()
        await session.submit("/writing chinh-xac", waitForCompletion: true)
        #expect(sink.joined.contains("Đã chọn chế độ viết: chinh-xac"))

        _ = try await node.call("rule.save", [
            "scope": .string("profile"),
            "title": .string("Ngắn gọn"),
            "text": .string("Luôn trả lời dưới 5 gạch đầu dòng.")
        ])
        sink.clear()
        await session.submit("/rules", waitForCompletion: true)
        #expect(sink.joined.contains("#ngan-gon — Ngắn gọn"))

        sink.clear()
        await session.submit("/skills", waitForCompletion: true)
        #expect(sink.joined.contains("Danh sách kỹ năng") || sink.joined.contains("Chưa có kỹ năng"))

        // 3. /access, /output, /gap, /tools, /do, /activity, /handoff
        sink.clear()
        await session.submit("/access tu-sua", waitForCompletion: true)
        #expect(sink.joined.contains("Đã đổi quyền truy cập sang: tu-sua"))
        await session.submit("/access hoi-duyet", waitForCompletion: true)
        #expect(sink.joined.contains("Đã đổi quyền truy cập sang: hoi-duyet"))

        sink.clear()
        await session.submit("/output", waitForCompletion: true)
        #expect(sink.joined.contains("Thư mục đầu ra hiện tại của hội thoại:"))

        sink.clear()
        await session.submit("/gap on", waitForCompletion: true)
        #expect(sink.joined.contains("Đã BẬT chế độ việc gấp."))
        await session.submit("/gap off", waitForCompletion: true)
        #expect(sink.joined.contains("Đã TẮT chế độ việc gấp."))

        sink.clear()
        await session.submit("/tools core", waitForCompletion: true)
        #expect(sink.joined.contains("core.ping"))

        sink.clear()
        await session.submit("/do core.ping", waitForCompletion: true)
        #expect(sink.joined.contains("pong"))

        sink.clear()
        await session.submit("/handoff", waitForCompletion: true)
        #expect(sink.joined.contains("Không có yêu cầu chuyển model"))

        sink.clear()
        await session.submit("/activity", waitForCompletion: true)
        #expect(sink.joined.contains("Nhật ký hoạt động") || sink.joined.contains("Chưa có hoạt động"))

        // 4. Chọn nguồn bằng $$ (thư mục) và $ (tệp) + gợi ý Tab
        let dirSuggestions = await session.suggestions(for: "Hãy xem $$tai-lieu")
        #expect(!dirSuggestions.isEmpty)
        #expect(dirSuggestions.first?.title == "tai-lieu-toan")
        let afterDirInput = await session.applySuggestion(dirSuggestions[0], to: "Hãy xem $$tai-lieu")
        #expect(await session.selectedFolder == subDir.path)
        #expect(afterDirInput.contains("$$tai-lieu-toan"))

        let fileSuggestions = await session.suggestions(for: "Tóm tắt $de-cuong")
        #expect(!fileSuggestions.isEmpty)
        #expect(fileSuggestions.first?.title == "de-cuong-hoc-ky.txt")
        let afterFileInput = await session.applySuggestion(fileSuggestions[0], to: "Tóm tắt $de-cuong")
        #expect(afterFileInput == "Tóm tắt de-cuong-hoc-ky.txt ")

        // Kiểm tra tệp đã được đính kèm thật vào hội thoại
        let attachments = try await node.call("attachment.list", ["chatId": .string(await session.chatId)]).decode([PVTACore.Attachment].self)
        #expect(attachments.contains(where: { $0.name == "de-cuong-hoc-ky.txt" }))

        await session.stopSession()
        await node.shutdown()
    }
}
