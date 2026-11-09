import Foundation
import Testing
@testable import PVTACore

private actor Runner {
    var calls: [String] = []
    var prompts: [String: String] = [:]
    var fail: Set<String> = []
    var running = 0, peak = 0
    var writeRunning = false, overlap = false
    var delay: Duration = .milliseconds(25)
    var answers: [String] = []
    func failure(_ ids: Set<String>) { fail = ids }
    func responses(_ values: [String]) { answers = values }
    func slow() { delay = .seconds(30) }
    func run(_ c: StepContext) async throws -> String {
        calls.append(c.step.id); prompts[c.step.id] = c.prompt
        if writeRunning || (c.step.write && running > 0) { overlap = true }
        running += 1; peak = max(peak, running); if c.step.write { writeRunning = true }
        defer { running -= 1; if c.step.write { writeRunning = false } }
        try await Task.sleep(for: delay)
        if fail.contains(c.step.id) { throw PVTAError("Lỗi giả " + c.step.id) }
        if !answers.isEmpty { return answers.removeFirst() }
        return "Kết quả " + c.step.id
    }
}
private actor InputVersion {
    var value = "đầu vào"
    func set(_ s: String) { value = s }
    func prepare(_ d: WorkDefinition) throws -> PreparedWork {
        var copy = d; copy.pinned = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PreparedWork(input: value, extras: [:], images: [:], fingerprint: FileHash.of(try encoder.encode(copy) + Data(value.utf8)))
    }
}
private struct Env {
    let root: URL
    let store: DataStore
    let runner = Runner()
    let input = InputVersion()
    let engine: WorkEngine
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("work-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try DataStore(file: root.appendingPathComponent("data.sqlite"))
        let runner = runner, input = input
        engine = WorkEngine(store: store, execute: { try await runner.run($0) }, prepare: { try await input.prepare($0) }, marks: { s, _ in Dictionary(uniqueKeysWithValues: s.outputs.map { ($0, "hash") }) })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func definition(_ kind: String = "workflow", parallel: Bool = false) -> WorkDefinition {
        WorkDefinition(name: "Thử", kind: kind, chatId: "chat", steps: [WorkStep(id: "a", name: "A", prompt: "{{input}}"), WorkStep(id: "b", name: "B", prompt: "{{prev}}", needs: ["a"])], parallel: parallel)
    }
}

@Test func automationPlanKhongTuChayDuyetTungBuocVaSua() async throws {
    let e = try Env(); defer { e.clean() }
    let saved = try await e.engine.save(e.definition("plan"), expectedRevision: nil)
    #expect(await e.runner.calls.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.engine.run(saved.definition.id, revision: 1, approved: false, stepId: "a") }
    await #expect(throws: PVTAError.self) { try await e.engine.run(saved.definition.id, revision: 1, approved: true, stepId: "b") }
    let first = try await e.engine.run(saved.definition.id, revision: 1, approved: true, stepId: "a")
    #expect(first.state == "waiting" && first.steps["b"] == nil)
    #expect(await e.runner.calls == ["a"])
    let second = try await e.engine.run(saved.definition.id, revision: 1, approved: true, stepId: "b")
    #expect(second.state == "done")
    #expect(await e.runner.prompts["b"]?.contains("Kết quả a") == true)
    var edit = second.definition; edit.steps[0].prompt = "Đã sửa"
    let new = try await e.engine.save(edit, expectedRevision: 1)
    #expect(new.definition.revision == 2 && new.steps.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.engine.run(new.definition.id, revision: 1, approved: true, stepId: "a") }
}
@Test func automationPlanBoQuaVanChanThieuKetQua() async throws {
    let e = try Env(); defer { e.clean() }
    let r = try await e.engine.save(e.definition("plan"), expectedRevision: nil)
    _ = try await e.engine.skip(r.definition.id, step: "a", replacement: nil)
    await #expect(throws: PVTAError.self) { try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: "b") }
    _ = try await e.engine.skip(r.definition.id, step: "a", replacement: "Dữ liệu giáo viên cung cấp")
    let done = try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: "b")
    #expect(done.state == "done")
}
@Test func automationTuanTuVaDaNhanhLoiChayLai() async throws {
    let e = try Env(); defer { e.clean() }
    var d = e.definition(parallel: true)
    d.steps[1].needs = []
    d.steps.append(WorkStep(id: "join", name: "Hợp nhất", prompt: "{{prev}}", needs: ["a", "b"]))
    await e.runner.failure(["a"])
    let r = try await e.engine.save(d, expectedRevision: nil)
    let failed = try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: nil)
    #expect(failed.steps["a"]?.state == "error" && failed.steps["b"]?.state == "done" && failed.steps["join"]?.state == "skipped")
    #expect(await e.runner.peak == 2)
    await e.runner.failure([])
    let retried = try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: nil, retry: true)
    #expect(retried.state == "done")
    #expect(await e.runner.calls.filter { $0 == "b" }.count == 1)
    #expect(await e.runner.prompts["join"]?.contains("Kết quả a") == true)
    await e.input.set("đã đổi")
    await #expect(throws: PVTAError.self) { try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: nil, retry: true) }
    let sequential = try await e.engine.save(e.definition(), expectedRevision: nil)
    let result = try await e.engine.run(sequential.definition.id, revision: 1, approved: true, stepId: nil)
    #expect(result.state == "done")
}
@Test func automationPhatHienVongLapVaThamChieuSai() throws {
    let e = try Env(); defer { e.clean() }
    var d = e.definition(parallel: true)
    d.steps[0].needs = ["b"]
    #expect(throws: PVTAError.self) { try d.validate() }
    d.steps[0].needs = ["a"]
    #expect(throws: PVTAError.self) { try d.validate() }
    d.steps[0].needs = ["missing"]
    #expect(throws: PVTAError.self) { try d.validate() }
    d.steps[0].needs = []; d.concurrency = 5
    #expect(throws: PVTAError.self) { try d.validate() }
}
@Test func automationGhiDocQuyenGiuaHaiQuyTrinh() async throws {
    let e = try Env(); defer { e.clean() }
    var d = e.definition(parallel: true); d.steps[1].needs = []; d.steps[0].write = true; d.steps[0].directory = e.root.path
    let a = try await e.engine.save(d, expectedRevision: nil)
    d.id = UUID().uuidString
    let b = try await e.engine.save(d, expectedRevision: nil)
    async let x = e.engine.run(a.definition.id, revision: 1, approved: true, stepId: nil)
    async let y = e.engine.run(b.definition.id, revision: 1, approved: true, stepId: nil)
    _ = try await (x, y)
    #expect(await e.runner.overlap == false)
}
@Test func automationHuyVaKhoiPhucSauGianDoan() async throws {
    let e = try Env(); defer { e.clean() }
    await e.runner.slow()
    let r = try await e.engine.save(e.definition("plan"), expectedRevision: nil)
    let task = Task { try await e.engine.run(r.definition.id, revision: 1, approved: true, stepId: "a") }
    for _ in 0..<100 { if await e.runner.running > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    await e.engine.cancel(r.definition.id)
    _ = try? await task.value
    #expect(try await e.engine.get(r.definition.id).state == "interrupted")
    var interrupted = try await e.engine.get(r.definition.id)
    interrupted.state = "running"; interrupted.steps["a"] = StepRecord(state: "running")
    try await e.store.setSetting("automation.v1", String(decoding: JSONEncoder().encode([r.definition.id: interrupted]), as: UTF8.self))
    let reopened = WorkEngine(store: e.store, execute: { _ in "Tiếp tục" }, prepare: { try await e.input.prepare($0) }, marks: { _, _ in [:] })
    #expect(try await reopened.get(r.definition.id).steps["a"]?.state == "interrupted")
    await #expect(throws: PVTAError.self) { try await reopened.run(r.definition.id, revision: 1, approved: true, stepId: "a") }
    _ = try await reopened.inspect(r.definition.id, step: "a")
    _ = try await reopened.recover(r.definition.id, step: "a", revision: 1, observed: [:], decision: "retry", output: nil, confirmed: true)
    let done = try await reopened.run(r.definition.id, revision: 1, approved: true, stepId: "a")
    #expect(done.steps["a"]?.state == "done")
}
@Test func automationPlanHoiThieuVaPhanBienPro() async throws {
    let e = try Env(); defer { e.clean() }
    let missing = #"{"name":"Kế hoạch","questions":["Lớp mấy?"],"steps":[{"id":"a","prompt":"Đợi thông tin"}]}"#
    await e.runner.responses([missing])
    let draft = try await e.engine.suggest(chatId: "chat", request: "Soạn bài", model: "auto", pro: false)
    #expect(draft.state == "draft" && draft.definition.questions == ["Lớp mấy?"])
    await #expect(throws: PVTAError.self) { try await e.engine.run(draft.definition.id, revision: 1, approved: true, stepId: "a") }
    let valid = #"{"name":"Kế hoạch","questions":[],"steps":[{"id":"a","prompt":"Soạn bài","criteria":"Đủ bài"}]}"#
    await e.runner.responses([valid, #"{"ok":false,"issues":"Cần rõ hơn"}"#, valid, #"{"ok":true,"issues":""}"#])
    let pro = try await e.engine.suggest(chatId: "chat", request: "Soạn bài lớp 8", model: "auto", pro: true)
    #expect(pro.state == "draft" && pro.definition.kind == "pro")
    #expect(pro.steps.isEmpty)
}

private struct RuntimeEnv {
    let root: URL
    let core: Core
    let runtime: AutomationRuntime
    let transport: FakeTransport
    let chat: String
    let folder: URL
    init(_ answers: [String] = []) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-work-" + UUID().uuidString)
        let paths = DataPaths(home: root.appendingPathComponent("data")); try paths.prepare()
        folder = root.appendingPathComponent("files"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys = MemoryKeyStore(); try keys.save("test", provider: "anthropic")
        transport = FakeTransport(answers.map { FakeTransport.Reply(lines: claudeSSE([$0])) })
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: transport, retry: .none, cli: Gia().moi())
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: root, approvalTimeout: .seconds(2))
        _ = try await core.permissions.addGrant(path: folder.path, write: true)
        chat = try await core.store.createChat().id
        runtime = AutomationRuntime(store: core.store, files: core.files, tools: core.tools, gateway: core.gateway, writing: core.writing, skills: core.skills, permissions: core.permissions, emit: { _, _ in })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func call(_ name: String, _ args: JSONValue) async throws -> JSONValue { try await core.dispatch(name, args, scoped: { _, _ in }) }
}
@Test func automationRPCBackendGiaVaLienKetChat() async throws {
    let e = try await RuntimeEnv([#"{"input":"Dữ liệu","task":"Soạn","output":"Bài","check":"Đủ"}"#, #"{"input":"Bài","task":"Kiểm tra","output":"Nhận xét","check":"Đủ"}"#, "Kết quả a", "Kết quả b"]); defer { e.clean() }
    let definition = try await e.call("workflow.save", ["name": "Quy trình", "chatId": .string(e.chat), "steps": [["id": "a", "prompt": "Một", "model": "anthropic/claude-haiku-5-5"], ["id": "b", "prompt": "{{prev}}", "model": "anthropic/claude-haiku-5-5"]]])
    let r = try definition.decode(WorkRecord.self)
    #expect(e.transport.requests.isEmpty)
    let preview = try await e.call("workflow.promptPreview", ["id": .string(r.definition.id), "revision": 1])
    let result = try await e.call("workflow.run", ["id": .string(r.definition.id), "revision": 1, "approved": true, "draftId": preview["id"]!])
    #expect(try result.decode(WorkRecord.self).state == "done")
    #expect(e.transport.requests.count == 4)
    let reopened = try await e.call("workflow.openChat", ["id": .string(r.definition.id)])
    #expect(reopened["id"]?.string == e.chat)
    _ = try await e.call("workflow.pin", ["id": .string(r.definition.id), "pinned": true])
    #expect(try await e.core.work.get(r.definition.id).definition.pinned)
}
@Test func automationThieuTepGhiDungBuocVaKhongGoiAI() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let missing = e.folder.appendingPathComponent("mat-de-bai.docx").path
    let d = WorkDefinition(name: "Thiếu", chatId: e.chat, steps: [WorkStep(id: "doc", name: "Đọc đề", prompt: "Đọc", resources: [missing])])
    _ = try await e.core.work.save(d, expectedRevision: nil)
    do {
        _ = try await e.core.work.run(d.id, revision: 1, approved: true, stepId: nil)
        Issue.record("Đã chạy khi thiếu tệp")
    } catch {
        #expect(UserMessage.text(for: error).contains("Đọc đề") && UserMessage.text(for: error).contains("mat-de-bai.docx"))
    }
    #expect(e.transport.requests.isEmpty)
}
@Test func automationDocNguonAnhVaGioiHanKhongCat() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    for n in ["quy-che.md", "anh-do.png"] { try FileManager.default.copyItem(at: fixtures.appendingPathComponent(n), to: e.folder.appendingPathComponent(n)) }
    var d = WorkDefinition(name: "Tài nguyên", chatId: e.chat, steps: [WorkStep(id: "a", name: "Đọc", prompt: "Đọc", resources: [e.folder.appendingPathComponent("quy-che.md").path, e.folder.appendingPathComponent("anh-do.png").path])], input: ["kind": "file", "value": .string(e.folder.appendingPathComponent("quy-che.md").path)])
    let prepared = try await e.runtime.prepare(d)
    #expect(prepared.images["a"]?.count == 1 && prepared.input.contains("Quy chế"))
    let huge = e.folder.appendingPathComponent("dai.txt")
    try String(repeating: "a", count: 20001).write(to: huge, atomically: true, encoding: .utf8)
    d.steps[0].resources = [huge.path]
    await #expect(throws: PVTAError.self) { try await e.runtime.prepare(d) }
    d.steps[0].resources = []; d.input = ["kind": "text", "value": .string(String(repeating: "a", count: 60001))]
    await #expect(throws: PVTAError.self) { try await e.runtime.prepare(d) }
}
@Test func automationChiDocChanCongCuGhiTrongCode() async throws {
    let tool = "```pvta-tool\n{\"tool\":\"fs_write\",\"args\":{\"path\":\"x.txt\",\"content\":\"ghi\"}}\n```"
    let e = try await RuntimeEnv([tool]); defer { e.clean() }
    let c = StepContext(step: WorkStep(id: "a", name: "Chỉ đọc", prompt: "Đọc", model: "anthropic/claude-haiku-5-5"), chatId: e.chat, prompt: "Đọc")
    await #expect(throws: PVTAError.self) { try await e.runtime.execute(c) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.folder.path).isEmpty)
    #expect(await e.core.permissions.queue.list().isEmpty)
}
@Test func automationKhoiPhucTacDongKhongRoVanChan() async throws {
    let e = try Env(); defer { e.clean() }
    var d = e.definition("plan"); d.steps[0].write = true; d.steps[0].directory = e.root.path
    _ = try await e.engine.save(d, expectedRevision: nil)
    await #expect(throws: PVTAError.self) { try await e.engine.recover(d.id, step: "a", revision: 1, observed: [:], decision: "retry", output: nil, confirmed: true) }
}

@Test func automationThieuDauRaChanBuocSauVaNhatKy() async throws {
    let e = try Env(); defer { e.clean() }
    let engine = WorkEngine(store: e.store, execute: { _ in "Tôi đã tạo tệp" }, prepare: { try await e.input.prepare($0) }, marks: { s, _ in Dictionary(uniqueKeysWithValues: s.outputs.map { ($0, "missing") }) })
    var d = e.definition("plan"); d.steps[0].outputs = [e.root.appendingPathComponent("chua-co.docx").path]
    _ = try await engine.save(d, expectedRevision: nil)
    let r = try await engine.run(d.id, revision: 1, approved: true, stepId: "a")
    #expect(r.steps["a"]?.state == "error")
    await #expect(throws: PVTAError.self) { try await engine.run(d.id, revision: 1, approved: true, stepId: "b") }
}
@Test func automationDungKhiLoiVaKhoaSuaLucChay() async throws {
    let e = try Env(); defer { e.clean() }
    var d = e.definition(); d.steps[0].stopOnError = true
    await e.runner.failure(["a"])
    _ = try await e.engine.save(d, expectedRevision: nil)
    let result = try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil)
    #expect(result.steps["b"]?.state == "skipped")
    #expect(await e.runner.calls == ["a"])
    await e.runner.failure([]); await e.runner.slow()
    let id = d.id
    let task = Task { try await e.engine.run(id, revision: 1, approved: true, stepId: nil) }
    for _ in 0..<100 { if await e.runner.running > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    await #expect(throws: PVTAError.self) { try await e.engine.pin(id, value: true) }
    await #expect(throws: PVTAError.self) { try await e.engine.save(d, expectedRevision: 1) }
    await e.engine.cancel(id); _ = try? await task.value
}

@Test func automation26DemDenBaKhongNhoAIDem() async throws {
    let e = try Env(); defer { e.clean() }
    let d = WorkDefinition(name: "Đếm đến 3", chatId: "chat", steps: [
        WorkStep(id: "start", name: "Bắt đầu", prompt: "!bien so-lan = 0"),
        WorkStep(id: "left", name: "Trái", prompt: "Việc trái", needs: ["start"]),
        WorkStep(id: "right", name: "Phải", prompt: "Việc phải", needs: ["start"]),
        WorkStep(id: "check", name: "Kiểm tra", prompt: "!gan so-lan = $so-lan + 1\n!in $so-lan\n!dau-ra = $so-lan\n!lap-lai \"start\" neu $so-lan < 3\n!dung neu $so-lan == 3", needs: ["left", "right"]),
        WorkStep(id: "exit", name: "Không chạy", prompt: "Không được chạy", needs: ["check"])
    ], parallel: true)
    let saved = try await e.engine.save(d, expectedRevision: nil)
    let r = try await e.engine.run(d.id, revision: saved.definition.revision, approved: true, stepId: nil)
    #expect(r.state == "done")
    #expect(r.steps["check"]?.value == .number(3))
    #expect(r.steps["check"]?.logs == ["1", "2", "3"])
    #expect(r.steps["exit"]?.state == "skipped")
    #expect(await e.runner.calls == ["left", "right", "left", "right", "left", "right"])
    #expect(await e.runner.peak == 1)
    await #expect(throws: PVTAError.self) { try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil, retry: true) }
}

@Test func automation26BieuThucThuanVaChanMaThucThi() throws {
    let expr = try WorkExpression.parse(#"{tong: ($a + 2) * 3, dung: $a >= 2 && !false, ds: [1, "hai"]}"#)
    #expect(try expr.evaluate(["a": 2])["tong"] == 12)
    #expect(try WorkExpression.parse(#"$a["node"].value"#).evaluate(["a": ["node": ["value": 3]]]) == 3)
    #expect(throws: PVTAError.self) { try WorkExpression.parse("system(\"rm\")") }
    #expect(throws: PVTAError.self) { try WorkExpression.parse("1 / 0").evaluate([:]) }
    #expect(throws: PVTAError.self) { try WorkExpression.parse("$unknown").evaluate([:]) }
    #expect(throws: PVTAError.self) { try WorkProgram("!bien input = 1") }
    #expect(throws: PVTAError.self) { try WorkProgram("!bien x = $other") }
    #expect(throws: PVTAError.self) { try WorkProgram("!dau-ra = 1\n!dau-ra = 2") }
    #expect(try WorkProgram("```text\n!bien x = 1\n```\nViết ví dụ").commands.isEmpty)
}

@Test func automation26KhungChongTangVaPhamVi() async throws {
    let e = try Env(); defer { e.clean() }
    var d = WorkDefinition(name: "Khung", chatId: "chat", steps: [
        WorkStep(id: "a", name: "A", prompt: "!bien cha = 1"),
        WorkStep(id: "b", name: "B", prompt: "!gan cha = $cha + 1"),
        WorkStep(id: "c", name: "C", prompt: "!dau-ra = $cha")
    ], advanced: WorkAdvanced(frames: [WorkFrame(id: "f", name: "Cha", steps: ["a", "b", "c"]), WorkFrame(id: "g", name: "Con", steps: ["b"])]))
    try d.validate()
    _ = try await e.engine.save(d, expectedRevision: nil)
    let r = try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil)
    #expect(r.steps["c"]?.value == 2)
    d.advanced!.frames = [WorkFrame(id: "f", name: "F", steps: ["a", "b"]), WorkFrame(id: "g", name: "G", steps: ["b", "c"])]
    #expect(throws: PVTAError.self) { try d.validate() }
    d.advanced!.frames = [WorkFrame(id: "f", name: "F", steps: ["a"]), WorkFrame(id: "g", name: "G", steps: ["a"])]
    #expect(throws: PVTAError.self) { try d.validate() }
    d.advanced!.frames = [WorkFrame(id: "f", name: "F", steps: ["a", "b", "c"]), WorkFrame(id: "g", name: "G", steps: ["b"])]
    d.steps[1].prompt = "!bien cha = 3"
    #expect(throws: PVTAError.self) { try d.validate() }
    d.steps += [WorkStep(id: "d", name: "D", prompt: "Việc")]
    d.advanced!.frames = (1...4).map { WorkFrame(id: String($0), name: "Khung", steps: Array(d.steps.prefix($0).map(\.id))) }
    #expect(throws: PVTAError.self) { try d.validate() }
}

@Test func automation26HamPhaiDuyetVaDoiKhaiBaoMatDuyet() async throws {
    let e = try Env(); defer { e.clean() }
    var d = WorkDefinition(name: "Hàm", chatId: "chat", steps: [WorkStep(id: "a", name: "A", prompt: """
    !ham cong(a, b)
    [Cộng hai số.]
    {tong: tổng hai số}
    !goi ket-qua = cong(2, 3)
    !dau-ra = $ket-qua.tong
    """)])
    _ = try await e.engine.save(d, expectedRevision: nil)
    #expect(try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil).state == "error")
    #expect(await e.runner.calls.isEmpty)
    await e.runner.responses([#"{"expression":"{tong: $a + $b}"}"#])
    let draft = try await e.engine.functionDraft(d.id, revision: 1, stepId: "a", name: "cong")
    await #expect(throws: PVTAError.self) { try await e.engine.approveFunction(draft.id, approved: false) }
    let approved = try await e.engine.approveFunction(draft.id, approved: true)
    let result = try await e.engine.run(d.id, revision: approved.definition.revision, approved: true, stepId: nil)
    #expect(result.steps["a"]?.value == 5)
    d = approved.definition; d.steps[0].prompt = d.steps[0].prompt.replacingOccurrences(of: "Cộng hai số.", with: "Cộng khác.")
    let changed = try await e.engine.save(d, expectedRevision: d.revision)
    #expect(try await e.engine.run(d.id, revision: changed.definition.revision, approved: true, stepId: nil).state == "error")
}

@Test func automation26LoiChiThiDungVaGioiHanVongLap() async throws {
    let e = try Env(); defer { e.clean() }
    var d = WorkDefinition(name: "Lỗi", chatId: "chat", steps: [WorkStep(id: "a", name: "A", prompt: "!gan chua-co = 1"), WorkStep(id: "b", name: "B", prompt: "Độc lập")], parallel: true)
    _ = try await e.engine.save(d, expectedRevision: nil)
    let failed = try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil)
    #expect(failed.state == "error"); #expect(failed.steps["b"]?.state == "skipped")
    #expect(failed.steps["a"]?.reason.contains("Dòng 1") == true)
    #expect(await e.runner.calls.isEmpty)
    d.id = UUID().uuidString
    d.steps = [WorkStep(id: "a", name: "A", prompt: "!bien x = 0"), WorkStep(id: "b", name: "B", prompt: "!gan x = $x + 1\n!lap-lai \"a\" neu true", needs: ["a"])]
    _ = try await e.engine.save(d, expectedRevision: nil)
    let capped = try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil)
    #expect(capped.state == "error"); #expect(capped.steps["b"]?.reason.contains("100") == true)
    d.id = UUID().uuidString; d.steps.append(WorkStep(id: "escape", name: "Thoát sớm", prompt: "Việc", needs: ["a"]))
    _ = try await e.engine.save(d, expectedRevision: nil)
    await #expect(throws: PVTAError.self) { try await e.engine.run(d.id, revision: 1, approved: true, stepId: nil) }
}

@Test func automation26QuyTrinhConTraiPhangVaChanVong() async throws {
    let e = try Env(); defer { e.clean() }
    let child = try await e.engine.save(e.definition(), expectedRevision: nil)
    var parent = WorkDefinition(name: "Cha", chatId: "chat", steps: [WorkStep(id: "sub", name: "Con", prompt: "Quy trình con", subWorkflowId: child.definition.id), WorkStep(id: "end", name: "Sau con", prompt: "{{prev}}")])
    _ = try await e.engine.save(parent, expectedRevision: nil)
    let r = try await e.engine.run(parent.id, revision: 1, approved: true, stepId: nil)
    #expect(r.state == "done"); #expect(await e.runner.calls == ["sub/a", "sub/b", "end"])
    let portable = try await e.engine.templateFrom(parent.id, name: "Mẫu cha")
    #expect(portable.steps.map(\.id) == ["sub/a", "sub/b", "end"])
    #expect(portable.steps.last?.needs == ["sub/b"])
    #expect(portable.steps.allSatisfy { $0.subWorkflowId == nil && !$0.write })
    var cycle = child.definition; cycle.steps[0].subWorkflowId = parent.id
    await #expect(throws: PVTAError.self) { try await e.engine.save(cycle, expectedRevision: 1) }
    parent.steps[0].subWorkflowId = "missing"
    await #expect(throws: PVTAError.self) { try await e.engine.save(parent, expectedRevision: 1) }
    var previous = child.definition.id
    for i in 0..<2 {
        let nest = WorkDefinition(name: "Tầng \(i)", chatId: "chat", steps: [WorkStep(id: "sub", name: "Con", prompt: "Việc", subWorkflowId: previous)])
        _ = try await e.engine.save(nest, expectedRevision: nil); previous = nest.id
    }
    let tooDeep = WorkDefinition(name: "Quá sâu", chatId: "chat", steps: [WorkStep(id: "sub", name: "Con", prompt: "Việc", subWorkflowId: previous)])
    await #expect(throws: PVTAError.self) { try await e.engine.save(tooDeep, expectedRevision: nil) }
}

@Test func automation26MauNhapChiDocBanSaoKhongMangDuLieuRieng() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let d = WorkDefinition(name: "Nguồn", chatId: e.chat, steps: [WorkStep(id: "a", name: "A", prompt: "Soạn", model: "model-riêng", write: true, directory: e.folder.path, resources: [e.folder.path], outputs: [e.folder.appendingPathComponent("out.md").path])], input: ["kind": "text", "value": "bí mật"])
    _ = try await e.core.work.save(d, expectedRevision: nil)
    let exported = try await e.call("template.export", ["id": .string(d.id)])
    let json = WorkExpression.text(exported)
    #expect(!json.contains(e.folder.path)); #expect(!json.contains("bí mật")); #expect(!json.contains("chatId"))
    let imported = try await e.call("template.import", ["json": .string(json), "chatId": .string(e.chat)]).decode(WorkRecord.self)
    #expect(imported.definition.steps[0].write == false)
    #expect(imported.definition.steps[0].model == "auto")
    #expect(imported.definition.steps[0].directory == nil)
    #expect(imported.steps.isEmpty)
    #expect(imported.definition.steps[0].id != "a")
    #expect(e.transport.requests.isEmpty)
    let template = try await e.core.work.templateFrom(d.id, name: "Mẫu")
    let inserted = try await e.core.work.insertTemplate(template, target: imported.definition.id, revision: imported.definition.revision)
    let link = try #require(inserted.definition.advanced?.suggestedLinks.first)
    #expect(inserted.definition.steps.last?.needs.isEmpty == true)
    let linked = try await e.core.work.resolveLink(inserted.definition.id, revision: inserted.definition.revision, from: link.from, to: link.to, accept: true)
    #expect(linked.definition.steps.last?.needs == [link.from])
    #expect(try await e.core.work.templates().first?.steps[0].id == "a")
}

@Test func automation26BanVietLaiHetHieuLucKhiDoiNguonHoacQuyTrinh() async throws {
    let e = try Env(); defer { e.clean() }
    let fields = #"{"input":"Đầu vào","task":"Soạn","output":"Bài","check":"Đủ"}"#
    await e.runner.responses([fields, fields, fields, fields])
    var d = e.definition(); _ = try await e.engine.save(d, expectedRevision: nil)
    let draft = try await e.engine.preview(d.id, revision: 1)
    #expect(draft.prompts["a"]?.contains("original:") == true)
    await e.input.set("nguồn đổi")
    await #expect(throws: PVTAError.self) { try await e.engine.runReviewed(d.id, revision: 1, approved: true, token: draft.id, retry: false) }
    await e.input.set("đầu vào")
    let newer = try await e.engine.preview(d.id, revision: 1)
    d.steps[0].prompt = "Yêu cầu mới"
    _ = try await e.engine.save(d, expectedRevision: 1)
    await #expect(throws: PVTAError.self) { try await e.engine.runReviewed(d.id, revision: 2, approved: true, token: newer.id, retry: false) }
    #expect(await e.runner.calls.count == 4) // Chỉ viết lại, chưa chạy bước nào.
}

@Test func automation26HuyBanVietLaiVaLuuBanSaoKhongChay() async throws {
    let e = try Env(); defer { e.clean() }
    var d = WorkDefinition(name: "Bản sao", chatId: "chat", steps: [WorkStep(id: "a", name: "A", prompt: "Yêu cầu {{input}}", copied: true)])
    _ = try await e.engine.save(d, expectedRevision: nil)
    let fields = #"{"input":"Nguồn","task":"Làm","output":"Kết quả","check":"Đúng"}"#
    await e.runner.responses([fields, fields])
    let old = try await e.engine.preview(d.id, revision: 1)
    await e.engine.cancelDraft(d.id)
    await #expect(throws: PVTAError.self) { try await e.engine.checkedDraft(old.id, id: d.id, revision: 1) }
    let draft = try await e.engine.preview(d.id, revision: 1)
    let saved = try await e.engine.savePrompts(draft.id, edits: ["a": ["input": "Nguồn", "task": "Sửa mô tả", "output": "Kết quả", "check": "Đúng"]])
    #expect(saved.definition.steps[0].prompt.contains("{{input}}"))
    #expect(saved.definition.steps[0].prompt.contains("Sửa mô tả"))
    #expect(saved.steps.isEmpty); #expect(await e.runner.calls.count == 2)
    let reused = try await e.engine.preview(saved.definition.id, revision: saved.definition.revision)
    #expect(reused.prompts["a"] == saved.definition.steps[0].prompt)
    #expect(await e.runner.calls.count == 2)
    d = saved.definition; d.steps[0].copied = false; d.steps[0].prompt = "Đổi prompt"; d.steps[0].rewrite = nil
    _ = try await e.engine.save(d, expectedRevision: d.revision)
    await e.runner.slow()
    let pendingID = d.id, pendingRevision = d.revision + 1
    let pending = Task { try await e.engine.preview(pendingID, revision: pendingRevision) }
    while await e.runner.calls.count < 3 { await Task.yield() }
    await e.engine.cancelDraft(d.id)
    await #expect(throws: (any Error).self) { try await pending.value }
}

@Test func automation26ThietKeHoiDapVaApDungMoiLuu() async throws {
    let e = try Env(); defer { e.clean() }
    await e.runner.responses([
        #"{"name":"Nháp","questions":["Môn nào?"],"steps":[{"id":"a","prompt":"Chờ","needs":[]}]}"#,
        #"{"name":"Khoa học","questions":[],"steps":[{"id":"a","prompt":"Soạn bài","needs":[]}]}"#
    ])
    let start = await e.engine.designStart(chatId: "chat", model: "auto")
    let question = try await e.engine.designSuggest(start.id, text: "Soạn bài học")
    #expect(question.draft?.questions == ["Môn nào?"])
    #expect(try await e.engine.list(kind: "workflow").isEmpty)
    let complete = try await e.engine.designSuggest(start.id, text: "Khoa học")
    #expect(complete.draft?.questions.isEmpty == true)
    await #expect(throws: PVTAError.self) { try await e.engine.designApply(start.id, approved: false) }
    let saved = try await e.engine.designApply(start.id, approved: true)
    #expect(saved.state == "draft"); #expect(saved.steps.isEmpty)
    #expect(await e.runner.calls.count == 2)
}

@Test func automation26DauVaoTepCoKieuVaTruyenTruoc() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let file = e.folder.appendingPathComponent("đề có dấu.md")
    try "Nội dung".write(to: file, atomically: true, encoding: .utf8)
    let path = String(decoding: try JSONEncoder().encode(file.path), as: UTF8.self)
    let d = WorkDefinition(name: "Tệp", chatId: e.chat, steps: [
        WorkStep(id: "a", name: "Đọc", prompt: "!dau-vao de-bai = \(path)\n!dau-ra = {text: $de-bai}"),
        WorkStep(id: "b", name: "Nhận", prompt: "!dau-vao ket-qua = @truoc\n!dau-ra = $ket-qua.text")
    ])
    _ = try await e.core.work.save(d, expectedRevision: nil)
    let result = try await e.call("workflow.run", ["id": .string(d.id), "revision": 1, "approved": true]).decode(WorkRecord.self)
    #expect(result.steps["b"]?.value?.string?.contains("Nội dung") == true)
    #expect(e.transport.requests.isEmpty)
}

@Test func automation26KhongVuotDuyetBangRPCPlanVaKhung() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let d = WorkDefinition(name: "Chờ duyệt", chatId: e.chat, steps: [WorkStep(id: "a", name: "A", prompt: "Soạn")])
    _ = try await e.core.work.save(d, expectedRevision: nil)
    await #expect(throws: PVTAError.self) { try await e.call("workflow.run", ["id": .string(d.id), "revision": 1, "approved": true]) }
    await #expect(throws: PVTAError.self) { try await e.call("plan.run", ["id": .string(d.id), "revision": 1, "approved": true, "stepId": "a"]) }
    var plan = d; plan.kind = "plan"; plan.advanced = WorkAdvanced(frames: [WorkFrame(id: "f", name: "Khung", steps: ["a"], decl: "!bien x = 1")])
    #expect(throws: PVTAError.self) { try plan.validate() }
    #expect(e.transport.requests.isEmpty)
}

@Test func automation26DoiQuyTrinhConHuyBanDuyet() async throws {
    let e = try Env(); defer { e.clean() }
    let fields = #"{"input":"Nguồn","task":"Làm","output":"Kết quả","check":"Đúng"}"#
    var child = WorkDefinition(name: "Con", chatId: "chat", steps: [WorkStep(id: "a", name: "A", prompt: "Việc")])
    _ = try await e.engine.save(child, expectedRevision: nil)
    let parent = WorkDefinition(name: "Cha", chatId: "chat", steps: [WorkStep(id: "sub", name: "Sub", prompt: "Con", subWorkflowId: child.id)])
    _ = try await e.engine.save(parent, expectedRevision: nil)
    await e.runner.responses([fields])
    let preview = try await e.engine.preview(parent.id, revision: 1)
    child.steps[0].prompt = "Việc mới"
    _ = try await e.engine.save(child, expectedRevision: 1)
    await #expect(throws: PVTAError.self) { try await e.engine.runReviewed(parent.id, revision: 1, approved: true, token: preview.id, retry: false) }
    await #expect(throws: PVTAError.self) { try await e.engine.delete(child.id) }
}

@Test func automation26NhapJSONKhongTinQuyenTuMau() async throws {
    let e = try await RuntimeEnv(); defer { e.clean() }
    let malicious = WorkTemplate(id: "ngoai", name: "Mẫu ngoài", steps: [WorkStep(id: "a", name: "A", prompt: "Việc", model: "model-khac", write: true, directory: "/tmp", resources: ["/tmp/private.md"], outputs: ["/tmp/out.md"], passthrough: true)], frames: [], parallel: false)
    let raw = String(decoding: try JSONEncoder().encode(malicious), as: UTF8.self)
    let imported = try await e.call("template.import", ["json": .string(raw), "chatId": .string(e.chat)]).decode(WorkRecord.self)
    let step = imported.definition.steps[0]
    #expect(!step.write && step.model == "auto" && step.directory == nil)
    #expect(step.resources.isEmpty && step.outputs.isEmpty && step.passthrough == nil)
    #expect(imported.definition.advanced?.functions.isEmpty == true)
}
