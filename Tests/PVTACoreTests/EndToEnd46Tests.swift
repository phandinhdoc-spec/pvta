import Foundation
import Testing
import PDFKit
@testable import PVTACore

private let model46 = "anthropic/claude-haiku-5-5"
private let repo46 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Chạy binary thật, ghi đầu ra vào tệp để không kẹt pipe khi có nhiều sự kiện.
private final class Command46: @unchecked Sendable {
    let process: Process
    let stdout: URL, stderr: URL
    init(binary: URL, args: [String], root: URL, environment: [String: String]) throws {
        stdout = root.appendingPathComponent(UUID().uuidString + ".out")
        stderr = root.appendingPathComponent(UUID().uuidString + ".err")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        process = Process(); process.executableURL = binary; process.arguments = args
        process.environment = environment; process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
    }
    deinit { if process.isRunning { process.terminate() } }
    func result() async throws -> (Int32, Data, String) {
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw PVTAError("Tiến trình kiểm thử quá 30 giây: " + (process.arguments?.first ?? ""))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (process.terminationStatus, try Data(contentsOf: stdout), String(decoding: try Data(contentsOf: stderr), as: UTF8.self))
    }
}

private struct E46 {
    let root: URL, work: URL
    let node: PVTANode
    let ai: FakeTransport
    var environment: [String: String]
    var chat = ""
    static func run(_ replies: @Sendable (URL) -> [FakeTransport.Reply] = { _ in [] }, _ body: (E46) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("e46-" + UUID().uuidString.prefix(8))
        let work = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let paths = DataPaths(home: root.appendingPathComponent("data")); try paths.prepare()
        let keys = MemoryKeyStore(); try keys.save("fake-only", provider: "anthropic")
        let transport = FakeTransport(replies(work))
        let client = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: transport, retry: .none, cli: Gia().moi())
        let node = try await PVTANode.open(paths: paths, ai: client)
        var environment = ProcessInfo.processInfo.environment
        environment["PVTA_HOME"] = paths.home.path
        for name in ["CLAUDE", "CODEX", "AGY", "OPENCODE"] { environment["PVTA_" + name + "_BIN"] = "/usr/bin/false" }
        var e = E46(root: root, work: work, node: node, ai: transport, environment: environment)
        do {
            _ = try await e.call("grant.add", ["path": .string(work.path), "write": true])
            e.chat = try await e.call("chat.create", ["title": "Kiểm thử đầu-cuối"])["id"]!.string!
            try await body(e)
            await node.shutdown(); try FileManager.default.removeItem(at: root)
        } catch {
            await node.shutdown(); try? FileManager.default.removeItem(at: root); throw error
        }
    }
    func start(_ method: String, _ params: JSONValue = [:]) throws -> Command46 {
        let input = root.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(params).write(to: input)
        let binary = ProcessInfo.processInfo.environment["PVTA_TEST_BINARY"].map { URL(fileURLWithPath: $0) } ?? repo46.appendingPathComponent(".build/debug/pvta")
        return try Command46(binary: binary, args: ["call", method, "--file", input.path, "--events"], root: root, environment: environment)
    }
    func value(_ command: Command46) async throws -> JSONValue {
        let (code, data, error) = try await command.result()
        guard code == 0 else { throw PVTAError("pvta call thất bại: " + error) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue { try await value(start(method, params)) }
    func denied(_ method: String, _ params: JSONValue) async throws {
        let (code, _, error) = try await start(method, params).result()
        #expect(code != 0 && !error.isEmpty)
    }
    func fixture(_ name: String) throws -> URL {
        let path = work.appendingPathComponent(name)
        try FileManager.default.copyItem(at: repo46.appendingPathComponent("Tests/Fixtures/" + name), to: path)
        return path
    }
    func approve(_ command: Command46, output: URL) async throws -> JSONValue {
        for _ in 0..<100 {
            let list = try await call("action.list").decode([ActionProposal].self)
            if let p = list.first(where: { $0.state == .pending }) {
                #expect(!FileManager.default.fileExists(atPath: output.path))
                _ = try await call("action.approve", ["id": .string(p.id)])
                return try await value(command)
            }
            if !command.process.isRunning { return try await value(command) }
            try await Task.sleep(for: .milliseconds(20))
        }
        command.process.terminate(); throw PVTAError("Không thấy bước chờ duyệt.")
    }
}
private func tool46(_ name: String, _ args: JSONValue) -> FakeTransport.Reply {
    let json = try! JSONEncoder().encode(JSONValue.object(["tool": .string(name), "args": args]))
    return .init(lines: claudeSSE(["```pvta-tool\n" + String(decoding: json, as: UTF8.self) + "\n```\n"]))
}
private func answer46(_ text: String) -> FakeTransport.Reply { .init(lines: claudeSSE([text])) }

@Test func e2e46SuaDocxQuaCallVaDuyetGiuNguyenNguon() async throws {
    try await E46.run({ work in [
        tool46("word_edit", ["path": .string(work.appendingPathComponent("giao-an.docx").path), "output": .string(work.appendingPathComponent("da-sua.docx").path), "ops": [["op": "replace", "find": "Giáo án Toán 8", "replace": "Giáo án Toán 9"]]]), answer46("Đã xử lý")
    ] }) { e in
        let source = try e.fixture("giao-an.docx"), before = try Data(contentsOf: source)
        let output = e.work.appendingPathComponent("da-sua.docx")
        let command = try e.start("chat.send", ["chatId": .string(e.chat), "text": "Sửa tiêu đề trên bản sao", "model": .string(model46)])
        let result = try await e.approve(command, output: output)
        #expect(result["message"]?["error"] == nil || result["message"]?["error"] == .null)
        #expect(try Data(contentsOf: source) == before)
        // Kiểm tra trực tiếp gói kết quả, không tin câu trả lời do AI giả tự nói.
        let xmlCommand = try Command46(binary: URL(fileURLWithPath: "/usr/bin/unzip"), args: ["-p", output.path, "word/document.xml"], root: e.root, environment: e.environment)
        let (code, data, _) = try await xmlCommand.result()
        let xml = String(decoding: data, as: UTF8.self)
        #expect(code == 0 && xml.contains("Giáo án Toán 9") && !xml.contains("Giáo án Toán 8"))
        #expect(xml.contains("Khởi động"))
        #expect(try String(contentsOf: command.stderr, encoding: .utf8).contains("chat.tool"))
    }
}

@Test func e2e46DocXlsxQuaCallLayGiaTriTuCongCu() async throws {
    try await E46.run({ work in [tool46("excel_read", ["path": .string(work.appendingPathComponent("bang-diem.xlsx").path)]), answer46("Đã đọc")] }) { e in
        let source = try e.fixture("bang-diem.xlsx"), before = try Data(contentsOf: source)
        let result = try await e.call("chat.send", ["chatId": .string(e.chat), "text": "Đọc bảng điểm mẫu", "model": .string(model46)])
        guard case .array(let logs)? = result["message"]?["tools"] else { throw PVTAError("Không có kết quả công cụ Excel.") }
        let actual = try #require(logs.first { $0["tool"] == "excel_read" })
        #expect(actual["state"] == "done")
        let summary = actual["summary"]?.string ?? ""
        #expect(summary.contains("9.5") && summary.contains("Học sinh mẫu A") && summary.contains("Giỏi"))
        #expect(try Data(contentsOf: source) == before)
        #expect(try await e.call("action.list").decode([ActionProposal].self).isEmpty)
    }
}

@Test func e2e46TachPDFQuaCallDuyetVaDocLai() async throws {
    try await E46.run { e in
        let source = try e.fixture("pdf-tieng-viet.pdf"), before = try Data(contentsOf: source)
        let output = e.work.appendingPathComponent("trang-mot.pdf")
        let original = try await e.call("pdf.read", ["path": .string(source.path)])
        let command = try e.start("pdf.split", ["path": .string(source.path), "pages": [1], "output": .string(output.path), "chatId": .string(e.chat)])
        let result = try await e.approve(command, output: output)
        #expect(result["pages"] == 1)
        let reread = try await e.call("pdf.read", ["path": .string(output.path)])
        #expect(reread["pageCount"] == 1)
        guard case .array(let old)? = original["pages"], case .array(let new)? = reread["pages"] else { throw PVTAError("Thiếu nội dung PDF.") }
        #expect(new[0]["text"] == old[0]["text"] && !(new[0]["text"]?.string ?? "").isEmpty)
        #expect(PDFDocument(url: output)?.pageCount == 1)
        #expect(try Data(contentsOf: source) == before)
    }
}

@Test func e2e46TaoBoSlideQuaCallTuChoiRoiDuyet() async throws {
    try await E46.run { e in
        let output = e.work.appendingPathComponent("bai-day.pptx")
        let params: JSONValue = ["chatId": .string(e.chat), "path": .string(output.path), "subject": "Toán", "slides": [
            ["layout": "title", "title": "Bình phương một tổng", "text": "Toán 8"],
            ["layout": "content", "title": "Công thức", "text": "(a+b)² = a² + 2ab + b²"],
            ["layout": "twoColumns", "title": "Luyện tập", "left": "(x+1)²", "right": "x² + 2x + 1"]]]
        let rejected = try e.start("powerpoint.create", params)
        var found = false
        for _ in 0..<100 {
            if let p = try await e.call("action.list").decode([ActionProposal].self).first(where: { $0.state == .pending }) {
                found = true; _ = try await e.call("action.decline", ["id": .string(p.id)]); break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(found)
        let (code, _, _) = try await rejected.result()
        #expect(code != 0 && !FileManager.default.fileExists(atPath: output.path))
        _ = try await e.approve(e.start("powerpoint.create", params), output: output)
        let read = try await e.call("powerpoint.read", ["path": .string(output.path)])
        #expect(read.string?.contains("Bình phương một tổng") == true && read.string?.contains("Luyện tập") == true)
        let command = try Command46(binary: URL(fileURLWithPath: "/usr/bin/unzip"), args: ["-t", output.path], root: e.root, environment: e.environment)
        #expect(try await command.result().0 == 0)
        let list = try Command46(binary: URL(fileURLWithPath: "/usr/bin/unzip"), args: ["-Z1", output.path], root: e.root, environment: e.environment)
        let names = String(decoding: try await list.result().1, as: UTF8.self).split(separator: "\n")
        #expect(names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.count == 3)
    }
}

@Test func e2e46PlanLapSuaDuyetTungBuocQuaCall() async throws {
    let plan: JSONValue = ["name": "Soạn bài", "questions": [], "steps": [
        ["id": "a", "name": "Mục tiêu", "prompt": "Soạn mục tiêu", "model": .string(model46)],
        ["id": "b", "name": "Kiểm tra", "prompt": "Kiểm tra {{prev}}", "needs": ["a"], "model": .string(model46)]]]
    let planText = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    try await E46.run({ _ in [answer46(planText), answer46("MỤC TIÊU ĐÃ SỬA"), answer46("KIỂM TRA ĐẠT")] }) { e in
        let suggested = try await e.call("plan.suggest", ["chatId": .string(e.chat), "request": "Soạn bài nhân đa thức", "model": .string(model46), "input": ["kind": "text", "value": "Toán 8"]])
        let id = try suggested["definition"]!.requireString("id")
        #expect(e.ai.requests.count == 1)
        let saved = try await e.call("plan.save", ["id": .string(id), "revision": 1, "name": "Soạn bài đã sửa", "chatId": .string(e.chat), "steps": [
            ["id": "a", "prompt": "Mục tiêu đã điều chỉnh", "model": .string(model46)],
            ["id": "b", "prompt": "Kiểm tra {{prev}}", "needs": ["a"], "model": .string(model46)]]])
        #expect(saved["definition"]?["revision"] == 2 && e.ai.requests.count == 1)
        try await e.denied("plan.run", ["id": .string(id), "revision": 2, "stepId": "a", "approved": false])
        #expect(e.ai.requests.count == 1)
        let first = try await e.call("plan.run", ["id": .string(id), "revision": 2, "stepId": "a", "approved": true])
        #expect(first["state"] == "waiting" && first["steps"]?["b"] == nil && e.ai.requests.count == 2)
        let second = try await e.call("plan.run", ["id": .string(id), "revision": 2, "stepId": "b", "approved": true])
        #expect(second["state"] == "done" && second["steps"]?["b"]?["output"] == "KIỂM TRA ĐẠT")
        let persisted = try await e.call("plan.get", ["id": .string(id)])
        #expect(persisted["state"] == "done")
    }
}

@Test func e2e46QuyTrinhDaNhanhSongSongVaHopNhatQuaCall() async throws {
    let gate = Gate()
    let rewrite = #"{"input":"Đầu vào","task":"Thực hiện yêu cầu gốc","output":"Nội dung","check":"Đủ nội dung"}"#
    try await E46.run({ _ in [answer46(rewrite), answer46(rewrite), answer46(rewrite), .held(["KẾT QUẢ NHÁNH"], gate: gate), .held(["KẾT QUẢ NHÁNH"], gate: gate), answer46("HỢP NHẤT ĐẠT")] }) { e in
        defer { Task { await gate.open() } }
        let saved = try await e.call("workflow.save", ["name": "Hai nhánh", "chatId": .string(e.chat), "parallel": true, "concurrency": 2, "input": ["kind": "text", "value": "Bài giảng"], "steps": [
            ["id": "a", "prompt": "Soạn lý thuyết", "model": .string(model46)],
            ["id": "b", "prompt": "Soạn bài tập", "model": .string(model46)],
            ["id": "join", "prompt": "Hợp nhất {{prev}}", "needs": ["a", "b"], "model": .string(model46)]]])
        let id = try saved["definition"]!.requireString("id")
        try await e.denied("workflow.run", ["id": .string(id), "revision": 1, "approved": true])
        #expect(e.ai.requests.isEmpty)
        let draft = try await e.call("workflow.promptPreview", ["id": .string(id), "revision": 1])
        #expect(e.ai.requests.count == 3)
        let run = try e.start("workflow.run", ["id": .string(id), "revision": 1, "approved": true, "draftId": draft["id"]!])
        for _ in 0..<300 { if e.ai.requests.count == 5 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(e.ai.requests.count == 5) // Hai nhánh đều tới AI trước khi mở cổng, không thể chạy tuần tự.
        let mid = try await e.call("workflow.get", ["id": .string(id)])
        #expect(mid["steps"]?["a"]?["state"] == "running" && mid["steps"]?["b"]?["state"] == "running")
        #expect(mid["steps"]?["join"] == nil)
        await gate.open()
        let result = try await e.value(run)
        #expect(result["state"] == "done" && result["steps"]?["join"]?["output"] == "HỢP NHẤT ĐẠT")
        #expect(e.ai.requests.count == 6)
        let finalPrompt = String(decoding: e.ai.requests.last!.httpBody!, as: UTF8.self)
        #expect(finalPrompt.components(separatedBy: "KẾT QUẢ NHÁNH").count >= 3)
    }
}
