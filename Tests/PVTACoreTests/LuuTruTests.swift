import Foundation
import Testing
@testable import PVTACore

/// Đồng hồ giả tăng 1 giây mỗi lần gọi để thứ tự ổn định.
private final class DongHo: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 1_800_000_000.0
    func tick() -> Date { lock.lock(); defer { lock.unlock() }; t += 1; return Date(timeIntervalSince1970: t) }
}

private func thuMuc() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pvta-luutru-\(UUID().uuidString)", isDirectory: true)
}

private func moKho(_ dir: URL, migrations: [Migration] = Schema.all, clock: DongHo = DongHo()) throws -> DataStore {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try DataStore(file: dir.appendingPathComponent("pvta.sqlite"), migrations: migrations, now: { clock.tick() })
}

@Test func taoDocDoiTenGhimXoaHoiThoai() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let kho = try moKho(dir)
    let a = try await kho.createChat(title: "  Soạn   bài  ")
    let b = try await kho.createChat(title: "Điểm số")
    #expect(a.title == "Soạn bài")
    #expect(try await kho.chats().map(\.id) == [b.id, a.id])   // mới nhất trước

    try await kho.setPinned(id: a.id, true)
    #expect(try await kho.chats().map(\.id) == [a.id, b.id])   // ghim lên đầu

    try await kho.renameChat(id: b.id, title: "Điểm học kỳ")
    #expect(try await kho.chat(id: b.id)?.title == "Điểm học kỳ")
    await #expect(throws: PVTAError.self) { try await kho.renameChat(id: b.id, title: "   ") }

    try await kho.appendMessage(chatId: a.id, role: .user, text: "Xin chào")
    try await kho.appendMessage(chatId: a.id, role: .assistant, text: "Chào thầy cô")
    #expect(try await kho.messages(chatId: a.id).map(\.text) == ["Xin chào", "Chào thầy cô"])

    try await kho.deleteChat(id: a.id)
    #expect(try await kho.chat(id: a.id) == nil)
    #expect(try await kho.messages(chatId: a.id).isEmpty)       // xóa dây chuyền tin nhắn
    await #expect(throws: PVTAError.self) { try await kho.deleteChat(id: a.id) }
}

@Test func diChuyenHoiThoaiVaXoaDuAn() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let kho = try moKho(dir)
    let duAn = try await kho.createProject(name: "Toán 8")
    let c = try await kho.createChat()
    try await kho.moveChat(id: c.id, toProject: duAn.id)
    #expect(try await kho.chat(id: c.id)?.projectId == duAn.id)
    await #expect(throws: PVTAError.self) { try await kho.moveChat(id: c.id, toProject: "khong-co") }

    try await kho.deleteProject(id: duAn.id)
    #expect(try await kho.chat(id: c.id)?.projectId == nil)     // hội thoại còn, thoát khỏi dự án
    try await kho.moveChat(id: c.id, toProject: nil)
}

@Test func dongMoLaiVanConDuLieu() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    var id = ""
    do {
        let kho = try moKho(dir)
        id = try await kho.createChat(title: "Giữ lại").id
        try await kho.appendMessage(chatId: id, role: .user, text: "Nội dung")
        try await kho.setSetting("giaoDien", "toi")
    }
    let lai = try moKho(dir)
    #expect(try await lai.chat(id: id)?.title == "Giữ lại")
    #expect(try await lai.messages(chatId: id).count == 1)
    #expect(try await lai.setting("giaoDien") == "toi")
}

@Test func xuatRoiNhapLaiGiongNhauVaNhapHaiLanKhongTrung() async throws {
    let d1 = thuMuc(), d2 = thuMuc()
    defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
    let nguon = try moKho(d1)
    let duAn = try await nguon.createProject(name: "Văn 9")
    let c = try await nguon.createChat(title: "Phân tích thơ", projectId: duAn.id)
    try await nguon.appendMessage(chatId: c.id, role: .user, text: "Dòng 1\nDòng 2 — có dấu")
    try await nguon.appendMessage(chatId: c.id, role: .assistant, text: "Trả lời")
    try await nguon.setPinned(id: c.id, true)
    try await nguon.setSetting("k", "v")

    let json = try await nguon.exportJSON()
    let dich = try moKho(d2)
    try await dich.importData(json)
    #expect(try await dich.exportData() == nguon.exportData())
    #expect(try await dich.exportJSON() == json)

    try await dich.importData(json)                             // nhập lần hai
    #expect(try await dich.chats().count == 1)
    #expect(try await dich.messages(chatId: c.id).count == 2)
}

@Test func nhapLoiGiuNguyenDuLieuHienTai() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let kho = try moKho(dir)
    let c = try await kho.createChat(title: "Còn nguyên")
    await #expect(throws: PVTAError.self) { try await kho.importData(Data("không phải json".utf8), replace: true) }
    // Hội thoại trỏ tới dự án không tồn tại: giao dịch hoàn tác, kể cả bước xóa của replace.
    let hong = ExportBundle(format: 1, projects: [], chats: [
        .init(chat: Chat(id: "x", title: "x", projectId: "ma", pinned: false, createdAt: Date(), updatedAt: Date()), messages: [])
    ], settings: [:])
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
    await #expect(throws: PVTAError.self) { try await kho.importData(try enc.encode(hong), replace: true) }
    #expect(try await kho.chat(id: c.id)?.title == "Còn nguyên")
}

@Test func saoLuuRoiKhoiPhuc() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let kho = try moKho(dir)
    let c = try await kho.createChat(title: "Bản gốc")
    try await kho.appendMessage(chatId: c.id, role: .user, text: "Dữ liệu quan trọng")
    let file = dir.appendingPathComponent("sao-luu.sqlite")
    try await kho.exportRecovery(to: file)
    await #expect(throws: PVTAError.self) { try await kho.exportRecovery(to: file) }   // không ghi đè

    try await kho.deleteChat(id: c.id)
    _ = try await kho.createChat(title: "Rác")
    try await kho.restore(from: file)
    #expect(try await kho.chats().map(\.title) == ["Bản gốc"])
    #expect(try await kho.messages(chatId: c.id).first?.text == "Dữ liệu quan trọng")
}

@Test func migrationGiuDuLieuCuVaTuChoiBanMoiHon() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let hienTai = Schema.all.last!.version
    let v5 = Migration(version: hienTai + 1, sql: "ALTER TABLE chats ADD COLUMN ghiChu TEXT;")
    var id = ""
    do {
        let cu = try moKho(dir)                                   // cấu trúc hiện tại (v4)
        #expect(try await cu.schemaVersion() == hienTai)
        id = try await cu.createChat(title: "Từ bản cũ").id
    }
    let moi = try moKho(dir, migrations: Schema.all + [v5])       // mở bằng bản có bước mới
    #expect(try await moi.schemaVersion() == hienTai + 1)
    #expect(try await moi.chat(id: id)?.title == "Từ bản cũ")
    _ = try await moi.createChat(title: "Vẫn ghi được")

    // Bản PVTA cũ mở dữ liệu của bản mới hơn: từ chối, không sửa gì.
    #expect(throws: PVTAError.self) { try moKho(dir) }
}

@Test func migrationLoiThiHoanTac() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    _ = try moKho(dir)
    let hong = Migration(version: Schema.all.last!.version + 1, sql: "ALTER TABLE chats ADD COLUMN a TEXT; ALTER TABLE khong_co ADD COLUMN b TEXT;")
    #expect(throws: PVTAError.self) { try moKho(dir, migrations: Schema.all + [hong]) }
    let lai = try moKho(dir)
    #expect(try await lai.schemaVersion() == Schema.all.last!.version)
}

@Test func haiKhoCungTepGhiKhongXungDot() async throws {
    let dir = thuMuc(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = try moKho(dir), b = try moKho(dir)
    let c = try await a.createChat()
    try await b.appendMessage(chatId: c.id, role: .user, text: "từ tiến trình B")
    #expect(try await a.messages(chatId: c.id).count == 1)
}
