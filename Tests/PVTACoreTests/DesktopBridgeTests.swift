import Foundation
import Testing
@testable import PVTACore
@testable import PVTADesktop

@MainActor
private func wait45(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private struct DesktopEnv45 {
    let paths: DataPaths
    let node: PVTANode
    let app: AppState
    let transport: FakeTransport
    init(_ replies: [FakeTransport.Reply], client: Bool = false, extra: [String: Core.Handler] = [:]) async throws {
        paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("d45-" + UUID().uuidString.prefix(8)))
        try paths.prepare()
        let keys = MemoryKeyStore(); try keys.save("fake-key", provider: "anthropic")
        transport = FakeTransport(replies)
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: transport, retry: .none, cli: Gia().moi())
        node = try await PVTANode.open(paths: paths, extraMethods: extra, ai: ai)
        let connected = client ? try await PVTANode.open(paths: paths, ai: ai) : node
        app = AppState(paths: paths, open: { connected })
        await app.start()
    }
    func window() async throws -> ChatWindowState {
        let id = try await node.call("chat.create")["id"]!.string!
        let window = ChatWindowState(chat: id); await app.attach(window); return window
    }
    func close() async {
        await app.shutdown(); await node.shutdown()
        try? FileManager.default.removeItem(at: paths.home)
    }
}

@Test @MainActor func desktop45HaiCuaSoLoiThatAIGiaHuyRiengHostVaClient() async throws {
    for client in [false, true] {
        let gate = Gate()
        let e = try await DesktopEnv45([.hung(["Cửa sổ A"]), .held(["Cửa sổ B"], gate: gate)], client: client)
        let a = try await e.window(), b = try await e.window()
        a.draft = "Câu A"; b.draft = "Câu B"
        let first = Task { await e.app.send(a, model: "anthropic/claude-haiku-5-5") }
        #expect(await wait45 { a.streamedText == "Cửa sổ A" })
        #expect(b.streamedText.isEmpty && b.draft == "Câu B")
        let second = Task { await e.app.send(b, model: "anthropic/claude-haiku-5-5") }
        #expect(await wait45 { b.streamedText == "Cửa sổ B" })
        #expect(a.isSending && b.isSending)
        // Vẫn sửa ô soạn và gọi lõi được trong khi cả hai backend đang bị giữ.
        a.draft = "Nháp tiếp A"; b.draft = "Nháp tiếp B"
        #expect(try await e.node.call("core.ping") == "pong")
        await e.app.stop(a)
        #expect(await wait45 { !a.isSending })
        #expect(b.isSending && !b.isStopping && b.streamedText == "Cửa sổ B")
        await gate.open(); await first.value; await second.value
        #expect(a.streamedText == "Cửa sổ A" && b.streamedText == "Cửa sổ B")
        #expect(a.draft == "Nháp tiếp A" && b.draft == "Nháp tiếp B")
        #expect(b.messages.last?.text == "Cửa sổ B" && b.messages.last?.error == nil)
        #expect(a.messages.last?.error != nil)
        await e.close()
    }
}

@Test @MainActor func desktop45SuKienChungVaKhongPhatSuKienRiengMoCoi() async throws {
    let e = try await DesktopEnv45([], extra: ["test.private": { ctx in ctx.emit("chat.delta", ["text": "KHÔNG PHÁT CHUNG"]); return .null }])
    let a = try await e.window(), b = try await e.window()
    a.draft = "A"; b.draft = "B"
    _ = try await e.node.call("test.private") // Không thuộc lời gọi nào của cửa sổ.
    _ = try await e.node.call("permission.set", ["level": "chi-doc"])
    #expect(await wait45 { a.common["permission"] != nil && b.common["permission"] != nil })
    #expect(a.streamedText.isEmpty && b.streamedText.isEmpty)
    #expect(a.common["chat.delta"] == nil && b.common["chat.delta"] == nil)
    #expect(a.selectedChat != b.selectedChat && a.draft == "A" && b.draft == "B")
    await e.app.select(a, chat: b.selectedChat)
    #expect(a.draft == "A" && b.draft == "B")
    await e.close()
}

@Test @MainActor func desktop45DuyetDungHangDoiVaXacNhanNguyHiem() async throws {
    let extra: [String: Core.Handler] = ["test.approval": { ctx in
        let plan = ActionPlan(kind: .run, summary: "Chạy giả", preview: "Không ghi tệp thật", warnings: [.init(level: "high", text: "Cần xác nhận thêm")])
        let tool = ToolSpec(name: "test", summary: "Test", parameters: "{}", access: .run, plan: { _ in plan }) { _ in "" }
        let answer = await PermissionPolicy(ctx.core.permissions).decide(tool, args: [:], chatId: try ctx.params.requireString("chatId"))
        switch answer { case .allow: return true; case .deny: return false }
    }]
    let e = try await DesktopEnv45([], extra: extra)
    let a = try await e.window(), b = try await e.window()
    for approve in [false, true] {
        let call = Task { try await e.node.call("test.approval", ["chatId": .string(a.selectedChat!)]) }
        #expect(await wait45 { !a.proposals.isEmpty })
        #expect(b.proposals.isEmpty)
        let p = try #require(a.proposals.first)
        if approve {
            await e.app.decide(a, proposal: p, approve: true)
            #expect(!a.proposals.isEmpty) // Cổng lõi không chấp nhận thiếu xác nhận nguy hiểm.
        }
        await e.app.decide(a, proposal: p, approve: approve, force: approve)
        #expect(try await call.value == .bool(approve))
        #expect(await wait45 { a.proposals.isEmpty })
    }
    await e.close()
}

@Test @MainActor func desktop45DongMotCuaSoKhongDongKetNoiCuaSoKhac() async throws {
    let gate = Gate()
    let e = try await DesktopEnv45([.hung(["A"]), .held(["B"], gate: gate)])
    let a = try await e.window(), b = try await e.window()
    a.draft = "A"; b.draft = "B"
    let first = Task { await e.app.send(a, model: "anthropic/claude-haiku-5-5") }
    #expect(await wait45 { a.streamedText == "A" })
    let second = Task { await e.app.send(b, model: "anthropic/claude-haiku-5-5") }
    #expect(await wait45 { b.streamedText == "B" })
    await e.app.detach(a)
    #expect(await wait45 { !a.isSending })
    #expect(e.app.windows[a.id] == nil && b.isSending && e.app.ready)
    await gate.open(); await first.value; await second.value
    #expect(b.messages.last?.text == "B")
    await e.close()
}

@Test @MainActor func desktop45DungNgaySauGuiVaChanHaiLuotCungHoiThoai() async throws {
    let e = try await DesktopEnv45([.hung(["Đang chạy"])], client: true)
    let a = try await e.window()
    let b = ChatWindowState(chat: a.selectedChat); await e.app.attach(b)
    a.draft = "Gửi"; b.draft = "Nháp giữ nguyên"
    let first = Task { await e.app.send(a, model: "anthropic/claude-haiku-5-5") }
    #expect(await wait45 { a.isSending })
    await e.app.send(b, model: "anthropic/claude-haiku-5-5")
    #expect(!b.isSending && b.error != nil && b.draft == "Nháp giữ nguyên")
    await e.app.stop(a)
    #expect(await wait45 { !a.isSending })
    await first.value
    #expect(e.transport.requests.count <= 1)
    await e.close()
}

private actor OpenCounter45 {
    var count = 0
    func opened() { count += 1 }
}

@Test @MainActor func desktop45NhieuCuaSoChiKhoiDongMotKetNoi() async throws {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("d45-" + UUID().uuidString.prefix(8)))
    let count = OpenCounter45()
    let ai = AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore(), transport: FakeTransport([]), retry: .none, cli: Gia().moi())
    let app = AppState(paths: paths, open: {
        await count.opened()
        try await Task.sleep(for: .milliseconds(30))
        return try await PVTANode.open(paths: paths, ai: ai)
    })
    let a = ChatWindowState(), b = ChatWindowState()
    async let first: Void = app.attach(a)
    async let second: Void = app.attach(b)
    _ = await (first, second)
    #expect(await count.count == 1)
    #expect(app.ready && app.windows.count == 2)
    await app.shutdown()
    #expect(!FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("core.sock").path))
    try? FileManager.default.removeItem(at: paths.home)
}

@Test @MainActor func desktop45LenhSignDungDungThuKyKhongHuyChatKhac() async throws {
    let gate = Gate()
    let e = try await DesktopEnv45([.hung(["Thư ký đang trả lời"]), .held(["Chat vẫn chạy"], gate: gate)])
    _ = try await e.node.call("secretary.saveSettings", ["model": "anthropic/claude-haiku-5-5"])
    let a = try await e.window(), b = try await e.window()
    a.draft = "/sign \"Hôm nay làm gì?\""; b.draft = "Câu hỏi riêng"
    let first = Task { await e.app.send(a) }
    #expect(await wait45 { a.streamedText == "Thư ký đang trả lời" })
    let second = Task { await e.app.send(b, model: "anthropic/claude-haiku-5-5") }
    #expect(await wait45 { b.streamedText == "Chat vẫn chạy" })
    await e.app.stop(a)
    #expect(await wait45 { !a.isSending })
    #expect(b.isSending)
    await gate.open(); await first.value; await second.value
    #expect(b.messages.last?.text == "Chat vẫn chạy")
    await e.close()
}
