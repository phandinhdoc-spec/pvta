import Foundation
import Testing
@testable import PVTACore

/// Thư mục ngắn: đường dẫn socket Unix giới hạn khoảng 100 ký tự.
private func thuMuc() -> DataPaths {
    DataPaths(home: FileManager.default.temporaryDirectory
        .appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
}

/// Cổng đồng bộ cho backend giả: chờ đủ số bên rồi mới cho đi tiếp, hoặc chờ được thả.
private actor Cong {
    private var dem = 0
    private var daTha = false
    func vao() -> Int { dem += 1; return dem }
    func soDangCho() -> Int { dem }
    func tha() { daTha = true }
    func chuaTha() -> Bool { !daTha }
}

/// Backend AI giả: một lượt phát vài đoạn chữ rồi ghi tin nhắn vào kho, qua cổng chạy theo hội thoại.
private func backendGia(_ cong: Cong, chờ: Bool = false) -> [String: Core.Handler] {
    ["test.turn": { ctx in
        let chatId = try ctx.params.requireString("chatId")
        let hoi = try ctx.params.requireString("text")
        return try await ctx.core.runTurn(chatId: chatId) {
            _ = await cong.vao()
            try await ctx.core.store.appendMessage(chatId: chatId, role: .user, text: hoi)
            for part in ["Xin ", "chào ", "thầy cô"] { ctx.emit("chat.delta", ["chatId": .string(chatId), "text": .string(part)]) }
            // Chờ đến khi được thả (hoặc bị dừng).
            while await cong.chuaTha() { try await Task.sleep(for: .milliseconds(10)) }
            try await ctx.core.store.appendMessage(chatId: chatId, role: .assistant, text: "Xin chào thầy cô")
            return "xong"
        }
    },
    "test.release": { _ in await cong.tha(); return .null },
    "test.cancel": { ctx in .bool(await ctx.core.turns.cancel(chatId: try ctx.params.requireString("chatId"))) },
    "test.boom": { _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "sk-LO-BI-MAT"]) }]
}

private func cho(_ timeout: Double = 5, _ dieuKien: () async -> Bool) async -> Bool {
    let han = Date().addingTimeInterval(timeout)
    while Date() < han {
        if await dieuKien() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// Thu sự kiện của một nút.
private actor Thu {
    private(set) var ds: [Event] = []
    init(_ node: PVTANode) {
        let events = node.events
        Task { for await e in events { await self.them(e) } }
    }
    private func them(_ e: Event) { ds.append(e) }
    func ten(_ name: String) -> [Event] { ds.filter { $0.name == name } }
}

@Test func nutDauTienGiuDuLieuVaGoiDuocPhuongThuc() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let a = try await PVTANode.open(paths: paths)
    #expect(await a.role == .host)
    #expect(try await a.call("core.ping") == "pong")
    let chat = try await a.call("chat.create", ["title": "Soạn bài"])
    #expect(chat["title"]?.string == "Soạn bài")
    #expect(try await a.call("chat.list").decode([Chat].self).count == 1)

    await #expect(throws: PVTAError.self) { try await a.call("khong.co") }
    await #expect(throws: PVTAError.self) { try await a.call("chat.rename", ["id": "x"]) }   // thiếu tham số
    await a.shutdown()
}

@Test func nutThuHaiLaClientDungChungDuLieuVaSocketChiChuSoHuu() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let host = try await PVTANode.open(paths: paths)
    let client = try await PVTANode.open(paths: paths)
    #expect(await host.role == .host)
    #expect(await client.role == .client)

    let id = try await client.call("chat.create", ["title": "Từ CLI"])["id"]!.string!
    #expect(try await host.call("chat.list").decode([Chat].self).map(\.id) == [id])
    #expect(try await client.call("core.info")["pid"] == host.call("core.info")["pid"])   // cùng một bên giữ dữ liệu

    let attrs = try FileManager.default.attributesOfItem(atPath: paths.home.appendingPathComponent("core.sock").path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    await client.shutdown(); await host.shutdown()
}

@Test func suKienChungToiMoiBenSuKienRiengChiToiNguoiGoi() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let cong = Cong()
    let host = try await PVTANode.open(paths: paths, extraMethods: backendGia(cong))
    let a = try await PVTANode.open(paths: paths), b = try await PVTANode.open(paths: paths)
    let thuHost = Thu(host), thuA = Thu(a), thuB = Thu(b)

    let chat = try await host.call("chat.create")["id"]!.string!
    #expect(await cho {
        let na = await thuA.ten("data.changed").count, nb = await thuB.ten("data.changed").count
        return na == 1 && nb == 1
    })

    await cong.tha()
    _ = try await a.call("test.turn", ["chatId": .string(chat), "text": "Chào"])
    #expect(await cho { await thuA.ten("chat.delta").count == 3 })
    #expect(await thuA.ten("chat.delta").allSatisfy { $0.requestId != nil })
    try await Task.sleep(for: .milliseconds(100))
    #expect(await thuB.ten("chat.delta").isEmpty)        // chữ đang stream không lọt sang bên khác
    #expect(await thuHost.ten("chat.delta").isEmpty)
    await a.shutdown(); await b.shutdown(); await host.shutdown()
}

@Test func nhieuNutGhiDongThoiKhongXungDot() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let nodes = [try await PVTANode.open(paths: paths), try await PVTANode.open(paths: paths), try await PVTANode.open(paths: paths)]
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (i, node) in nodes.enumerated() {
            for j in 0..<20 {
                group.addTask { _ = try await node.call("chat.create", ["title": .string("n\(i)-\(j)")]) }
            }
        }
        try await group.waitForAll()
    }
    #expect(try await nodes[1].call("chat.list").decode([Chat].self).count == 60)
    for n in nodes { await n.shutdown() }
}

@Test func moiHoiThoaiMotLuotNhungNhieuHoiThoaiChaySongSong() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let cong = Cong()
    let host = try await PVTANode.open(paths: paths, extraMethods: backendGia(cong))
    let client = try await PVTANode.open(paths: paths)
    let x = try await host.call("chat.create")["id"]!.string!
    let y = try await host.call("chat.create")["id"]!.string!

    // Hai lượt ở hai hội thoại cùng đang chạy (một từ host, một từ client).
    async let lx = host.call("test.turn", ["chatId": .string(x), "text": "x1"])
    async let ly = client.call("test.turn", ["chatId": .string(y), "text": "y1"])
    #expect(await cho { await cong.soDangCho() == 2 })

    // Lượt thứ hai vào hội thoại x đang bận bị từ chối.
    await #expect(throws: PVTAError.self) { try await client.call("test.turn", ["chatId": .string(x), "text": "x2"]) }

    await cong.tha()
    #expect(try await lx == "xong")
    #expect(try await ly == "xong")
    // Xong rồi thì hội thoại nhận lượt mới.
    #expect(try await client.call("test.turn", ["chatId": .string(x), "text": "x3"]) == "xong")
    #expect(try await host.call("chat.messages", ["id": .string(x)]).decode([Message].self).count == 4)
    await client.shutdown(); await host.shutdown()
}

@Test func dungLuotDangChay() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let cong = Cong()
    let host = try await PVTANode.open(paths: paths, extraMethods: backendGia(cong))
    let x = try await host.call("chat.create")["id"]!.string!
    let luot = Task { try await host.call("test.turn", ["chatId": .string(x), "text": "x1"]) }
    #expect(await cho { await cong.soDangCho() == 1 })
    #expect(try await host.call("test.cancel", ["chatId": .string(x)]) == true)
    await #expect(throws: PVTAError.self) { try await luot.value }
    #expect(try await host.call("test.cancel", ["chatId": .string(x)]) == false)   // không còn lượt nào
    await host.shutdown()
}

@Test func loiKyThuatKhongLoRaNgoai() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let host = try await PVTANode.open(paths: paths, extraMethods: backendGia(Cong()))
    let client = try await PVTANode.open(paths: paths)
    for node in [host, client] {
        do { _ = try await node.call("test.boom"); Issue.record("phải lỗi") } catch {
            #expect(!"\(error)".contains("LO-BI-MAT"))
            #expect((error as? PVTAError)?.message == UserMessage.generic)
        }
    }
    await client.shutdown(); await host.shutdown()
}

@Test func hostChetDotNgotThiClientNhanQuyenVaGhiTiep() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let host = try await PVTANode.open(paths: paths)
    let b = try await PVTANode.open(paths: paths), c = try await PVTANode.open(paths: paths)
    let truoc = try await b.call("chat.create", ["title": "Trước khi host chết"])["id"]!.string!

    await host.abandon()                                  // không dọn socket, không dọn khóa

    // Một client nhận quyền; sau đó ghi tiếp được, dữ liệu cũ còn nguyên.
    #expect(await cho {
        let rb = await b.role, rc = await c.role
        return rb == .host || rc == .host
    })
    let moi = try await b.call("chat.create", ["title": "Sau khi host chết"])["id"]!.string!
    let ds = try await c.call("chat.list").decode([Chat].self)
    #expect(Set(ds.map(\.id)) == [truoc, moi])
    let vaiTro = [await b.role, await c.role]
    #expect(vaiTro.filter { $0 == .host }.count == 1)     // đúng một bên lên làm host
    #expect(vaiTro.filter { $0 == .client }.count == 1)

    await b.shutdown(); await c.shutdown()
}

@Test func hostThoatGonThiClientNhanQuyen() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let host = try await PVTANode.open(paths: paths)
    let b = try await PVTANode.open(paths: paths)
    _ = try await host.call("chat.create", ["title": "Giữ lại"])
    await host.shutdown()
    #expect(await cho { await b.role == .host })     // đợi nhận quyền (lời gọi bay đúng lúc host thoát sẽ báo lỗi, đúng thiết kế)
    #expect(try await b.call("chat.list").decode([Chat].self).map(\.title) == ["Giữ lại"])
    #expect(await b.role == .host)
    await b.shutdown()
}

@Test func nutMoiGiaiQuyetSocketVaKhoaCuCuaTienTrinhDaChet() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let cu = try await PVTANode.open(paths: paths)
    _ = try await cu.call("chat.create", ["title": "Còn"])
    await cu.abandon()
    #expect(FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("core.sock").path))
    let moi = try await PVTANode.open(paths: paths)
    #expect(await moi.role == .host)
    #expect(try await moi.call("chat.list").decode([Chat].self).count == 1)
    await moi.shutdown()
}

@Test func thoatHetThiDonSocketVaKhoa() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let a = try await PVTANode.open(paths: paths), b = try await PVTANode.open(paths: paths)
    await b.shutdown()
    await a.shutdown()
    #expect(!FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("core.sock").path))
    #expect(!FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("core.lock").path))
}

@Test func xuatNhapQuaGoiPhuongThuc() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let host = try await PVTANode.open(paths: paths)
    let client = try await PVTANode.open(paths: paths)
    let c = try await client.call("chat.create", ["title": "Xuất"])["id"]!.string!
    try await client.call("chat.pin", ["id": .string(c)])
    let goi = try await client.call("data.export")
    try await client.call("chat.delete", ["id": .string(c)])
    try await host.call("data.import", ["data": goi])
    #expect(try await host.call("chat.list").decode([Chat].self).map(\.pinned) == [true])
    await client.shutdown(); await host.shutdown()
}
