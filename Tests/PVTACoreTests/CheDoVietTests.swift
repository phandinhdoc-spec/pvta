import Foundation
import Testing
@testable import PVTACore

private let M = "anthropic/claude-haiku-5-5"

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let mang: FakeTransport
    let core: Core
    init(_ replies: [FakeTransport.Reply] = []) async throws {
        mang = FakeTransport(replies)
        let keys = MemoryKeyStore()
        try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai)
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
    var store: DataStore { core.store }
    func gui(_ chatId: String, _ text: String, mode: String? = nil) async throws {
        _ = try await core.chat.send(chatId: chatId, text: text, model: M, mode: mode, emit: { _, _ in })
    }
    func system(_ i: Int) -> String {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data())) ?? .null
        return String(describing: body["system"] ?? .null)
    }
    func user(_ i: Int) -> String { String(decoding: mang.requests[i].httpBody ?? Data(), as: UTF8.self) }
}

private func tra(_ s: String) -> FakeTransport.Reply { .init(lines: claudeSSE([s])) }

// MARK: Chế độ

@Test func baChePhaiCoBayCheDoCoSanChiDoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let ids = try await e.core.writing.modes().map(\.id)
    #expect(ids == ["su-pham", "chinh-xac", "hoc-thuat", "ke-toan", "sang-tao", "hanh-chinh", "ngan-gon"])
    await #expect(throws: PVTAError.self) { try await e.store.saveMode(id: "su-pham", name: "X", icon: nil, hint: nil, instructions: "y") }
    await #expect(throws: PVTAError.self) { try await e.store.deleteMode(id: "su-pham") }
}

@Test func themSuaXoaSapXepCheDoRieng() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try await e.store.saveMode(id: nil, name: "Bài giảng lớp 6", icon: "📘", hint: "Ngắn", instructions: "Viết cho học sinh lớp 6.")
    let b = try await e.store.saveMode(id: nil, name: "Thư phụ huynh", icon: nil, hint: nil, instructions: "Lịch sự, ngắn.", origin: "hanh-chinh")
    #expect(try await e.store.customModes().map(\.id) == [a, b])
    try await e.store.reorderModes(ids: [b, a])
    #expect(try await e.store.customModes().map(\.id) == [b, a])
    _ = try await e.store.saveMode(id: a, name: "Bài giảng lớp 7", icon: "📘", hint: "Ngắn", instructions: "Viết cho học sinh lớp 7.")
    #expect(try await e.store.customMode(id: a)?.name == "Bài giảng lớp 7")
    try await e.store.deleteMode(id: b)
    #expect(try await e.store.customModes().map(\.id) == [a])
    await #expect(throws: PVTAError.self) { try await e.store.saveMode(id: nil, name: " ", icon: nil, hint: nil, instructions: "x") }
    await #expect(throws: PVTAError.self) { try await e.store.saveMode(id: nil, name: "Rỗng", icon: nil, hint: nil, instructions: "  ") }
    await #expect(throws: PVTAError.self) { try await e.store.saveMode(id: nil, name: "Dài", icon: nil, hint: nil, instructions: String(repeating: "a", count: 4001)) }
    await #expect(throws: PVTAError.self) { try await e.store.saveMode(id: nil, name: "Gốc lạ", icon: nil, hint: nil, instructions: "x", origin: "khong-co") }
}

@Test func lichSuVaKhoiPhucCheDo() async throws {
    let e = try await Moi(); defer { e.don() }
    let id = try await e.store.saveMode(id: nil, name: "Mẫu", icon: nil, hint: nil, instructions: "Bản một.\nDòng hai.")
    _ = try await e.store.saveMode(id: id, name: "Mẫu", icon: nil, hint: nil, instructions: "Bản hai.\nDòng hai.")
    _ = try await e.store.saveMode(id: id, name: "Mẫu", icon: nil, hint: nil, instructions: "Bản hai.\nDòng hai.")   // không đổi: không thêm lịch sử
    let hist = try await e.store.modeHistory(id: id)
    #expect(hist.count == 1)
    let pre = try await e.store.previewModeBackup(id: id, backupId: hist[0].id)
    #expect(pre.changedFields == ["instructions"])
    #expect(pre.lines == [.init(line: 1, kind: "change")])
    // Bản hiện tại đổi sau khi xem trước: khôi phục bị từ chối.
    _ = try await e.store.saveMode(id: id, name: "Mẫu", icon: nil, hint: nil, instructions: "Bản ba.")
    await #expect(throws: PVTAError.self) {
        try await e.store.restoreMode(id: id, backupId: hist[0].id, revision: pre.revision, backupRevision: pre.backupRevision)
    }
    let pre2 = try await e.store.previewModeBackup(id: id, backupId: hist[0].id)
    try await e.store.restoreMode(id: id, backupId: hist[0].id, revision: pre2.revision, backupRevision: pre2.backupRevision)
    #expect(try await e.store.customMode(id: id)?.instructions == "Bản một.\nDòng hai.")
    // Bản "ba" được giữ trong lịch sử, có thể quay lại.
    #expect(try await e.store.modeHistory(id: id).count == 3)
    await #expect(throws: PVTAError.self) {
        try await e.store.restoreMode(id: id, backupId: hist[0].id, revision: pre2.revision, backupRevision: "sai")
    }
}

@Test func khoiPhucCheDoDaXoa() async throws {
    let e = try await Moi(); defer { e.don() }
    let id = try await e.store.saveMode(id: nil, name: "Tạm", icon: "⭐️", hint: "h", instructions: "Chỉ dẫn.")
    try await e.store.deleteMode(id: id)
    #expect(try await e.store.customMode(id: id) == nil)
    let hist = try await e.store.modeHistory(id: id)
    #expect(hist.count == 1)
    let pre = try await e.store.previewModeBackup(id: id, backupId: hist[0].id)
    try await e.store.restoreMode(id: id, backupId: hist[0].id, revision: pre.revision, backupRevision: pre.backupRevision)
    #expect(try await e.store.customMode(id: id)?.name == "Tạm")
}

@Test func cheDoDuocChenVaoLoiNhacHeThong() async throws {
    let e = try await Moi([tra("ok"), tra("ok"), tra("ok"), tra("ok")]); defer { e.don() }
    let chat = try await e.store.createChat().id
    try await e.gui(chat, "Viết lời chào")
    #expect(e.system(0).contains("Sư phạm"))                          // mặc định
    let id = try await e.store.saveMode(id: nil, name: "Giọng thầy", icon: nil, hint: nil, instructions: "Xưng thầy, gọi các em.")
    _ = try await e.core.writing.select(id)
    try await e.gui(chat, "Viết lời chào")
    #expect(e.system(1).contains("Xưng thầy, gọi các em."))
    try await e.gui(chat, "Viết lời chào", mode: "ngan-gon")           // chọn riêng cho lượt này
    #expect(e.system(2).contains("Ngắn gọn") && !e.system(2).contains("Xưng thầy"))
    try await e.store.deleteMode(id: id)                                // chế độ đã xóa: về mặc định
    try await e.gui(chat, "Viết lời chào")
    #expect(e.system(3).contains("Sư phạm"))
    await #expect(throws: PVTAError.self) { try await e.core.writing.select("khong-co") }
}

// MARK: Quy tắc #khóa

@Test func quyTacGoiBangThangVaQuyTacLuonApDung() async throws {
    let e = try await Moi([tra("ok"), tra("ok")]); defer { e.don() }
    let chat = try await e.store.createChat().id
    let r1 = try await e.store.saveRule(id: nil, title: "Đề kiểm tra 15 phút", text: "Mỗi đề có 10 câu trắc nghiệm.", always: false)
    _ = try await e.store.saveRule(id: nil, title: "Xưng hô", text: "Gọi học sinh là các em.", always: true)
    #expect(r1.key == "de-kiem-tra-15-phut")
    try await e.gui(chat, "Soạn đề cho tôi")
    #expect(e.system(0).contains("Gọi học sinh là các em.") && !e.system(0).contains("10 câu trắc nghiệm"))
    try await e.gui(chat, "Soạn đề #de-kiem-tra-15-phut. Cảm ơn")
    #expect(e.system(1).contains("10 câu trắc nghiệm"))
    // khóa lạ bị bỏ qua, không lỗi
    #expect(RuleText.invokedKeys("#abc, (#x1) a#b #") == ["abc", "x1"])
}

@Test func quyTacTheoPhamViVaKhoaKhongTrung() async throws {
    let e = try await Moi([tra("ok")]); defer { e.don() }
    let project = try await e.store.createProject(name: "Lớp 8A")
    let chat = try await e.store.createChat(title: "x", projectId: project.id).id
    let a = try await e.store.saveRule(id: nil, title: "Giọng", text: "Giọng chung.", always: true)
    let b = try await e.store.saveRule(id: nil, title: "Giọng", text: "Giọng khác.", always: false)
    #expect(a.key == "giong" && b.key == "giong-2")
    _ = try await e.store.saveRule(id: nil, scope: "project", scopeId: project.id, title: "Giọng", text: "Giọng riêng lớp 8A.", always: true)
    try await e.gui(chat, "Chào")
    #expect(e.system(0).contains("Giọng riêng lớp 8A.") && !e.system(0).contains("Giọng chung."))   // phạm vi hẹp thắng
    await #expect(throws: PVTAError.self) { try await e.store.saveRule(id: nil, scope: "chat", scopeId: "khong-co", title: "A", text: "b", always: true) }
    await #expect(throws: PVTAError.self) { try await e.store.saveRule(id: nil, scope: "lạ", title: "A", text: "b", always: true) }
    await #expect(throws: PVTAError.self) { try await e.store.saveRule(id: nil, title: "A", text: " ", always: true) }
    try await e.store.deleteRule(id: a.id)
    await #expect(throws: PVTAError.self) { try await e.store.deleteRule(id: a.id) }
}

// MARK: Lời nhắc mẫu

@Test func haiMuoiBonLoiNhacMauSauNhom() async throws {
    let e = try await Moi(); defer { e.don() }
    let lib = e.core.writing.prompts
    let all = try await lib.all().filter { !$0.own }
    #expect(all.count == 24)
    #expect(Set(all.map(\.category)) == ["soan-bai", "kiem-tra", "diem-so", "trinh-chieu", "van-ban", "hoc-sinh"])
    #expect(Set(all.map(\.key)).count == 24)
    #expect(all.allSatisfy { !$0.text.isEmpty && !$0.desc!.isEmpty })
    #expect(all.filter { !$0.fields.isEmpty }.count >= 20)   // đa số có ô trống; vài mẫu làm việc trên dữ liệu thầy dán vào
    // Tìm không dấu
    let found = try await lib.search(query: "ke hoach bai day")
    #expect(!found.isEmpty)
    #expect(try await lib.search(query: "", category: "diem-so").allSatisfy { $0.category == "diem-so" })
}

@Test func loiNhacRiengYeuThichVaOTrong() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try await e.store.savePrompt(id: nil, title: "Nhận xét học bạ", text: "Viết nhận xét cho {{tên học sinh}} môn [môn], nêu rõ ［điểm mạnh］ và ____", category: nil)
    #expect(p.own && p.category == "cua-toi" && p.key == "nhan-xet-hoc-ba")
    #expect(p.fields == ["tên học sinh", "môn", "điểm mạnh", "điền vào đây"])
    let lib = e.core.writing.prompts
    let filled = try await lib.fill(ref: p.id, text: nil, values: ["môn": "Toán", "tên học sinh": "  "])
    #expect(filled.text.contains("môn Toán") && filled.missing == ["tên học sinh", "điểm mạnh", "điền vào đây"])
    try await e.store.setFavorite(id: p.id, true)
    try await e.store.setFavorite(id: "b-khoi-dong", true)
    #expect(try await lib.search().prefix(2).allSatisfy(\.favorite))
    try await e.store.setFavorite(id: p.id, false)
    await #expect(throws: PVTAError.self) { try await e.store.setFavorite(id: "khong-co", true) }
    // lồng hoặc thiếu ngoặc bị từ chối
    await #expect(throws: PVTAError.self) { try await e.store.savePrompt(id: nil, title: "A", text: "Viết [a [b]]", category: nil) }
    await #expect(throws: PVTAError.self) { try await e.store.savePrompt(id: nil, title: "A", text: "Viết [a", category: nil) }
    // lời nhắc có sẵn không xóa được; riêng thì xóa được (cả mục yêu thích)
    await #expect(throws: PVTAError.self) { try await e.store.deletePrompt(id: "b-khoi-dong") }
    try await e.store.deletePrompt(id: p.id)
    #expect(try await lib.find(ref: p.id) == nil)
}

@Test func atKhoaDuocNapVaOTrongDuocBaoChoModel() async throws {
    let e = try await Moi([tra("ok"), tra("ok")]); defer { e.don() }
    let chat = try await e.store.createChat().id
    let key = BuiltinPrompts.all[0].id.dropFirst(2)
    let text = BuiltinPrompts.all[0].text
    try await e.gui(chat, "@\(key) cho lớp 7")
    let saved = try await e.store.messages(chatId: chat).first { $0.role == .user }!.text
    #expect(saved.hasPrefix(String(text.prefix(30))) && saved.contains("cho lớp 7") && !saved.contains("@\(key)"))
    #expect(e.system(0).contains("LỜI NHẮC MẪU CÒN Ô TRỐNG") && e.system(0).contains("không tự bịa"))
    // khóa lạ và email giữ nguyên
    try await e.gui(chat, "gửi a@b.com và @khong-co nhé")
    let last = try await e.store.messages(chatId: chat).last { $0.role == .user }!.text
    #expect(last == "gửi a@b.com và @khong-co nhé")
    #expect(!e.system(1).contains("LỜI NHẮC MẪU CÒN Ô TRỐNG"))
}

// MARK: Tối ưu lời nhắc

@Test func toiUuGiuODongKhiThieuDuKien() async throws {
    let e = try await Moi([tra("Soạn kế hoạch bài dạy môn [môn] lớp [lớp] theo yêu cầu của thầy.")]); defer { e.don() }
    let r = try await e.core.writing.prompts.optimize("soạn giáo án")
    #expect(r.fields == ["môn", "lớp"])
    #expect(r.warnings.contains { $0.contains("2 ô trống") })
    #expect(e.system(0).contains("Để Ô TRỐNG") || e.system(0).contains("Ô TRỐNG"))
    #expect(e.user(0).contains("<y_tho>"))
}

@Test func toiUuBoKhoiMaThemLaiOTrongBiMat() async throws {
    let e = try await Moi([tra("```\nViết thư mời phụ huynh họp.\n```")]); defer { e.don() }
    let r = try await e.core.writing.prompts.optimize("viết thư mời họp vào [ngày họp]")
    #expect(!r.text.contains("```"))
    #expect(r.text.hasSuffix("[ngày họp]") && r.fields == ["ngày họp"])
    #expect(r.warnings.contains { $0.contains("làm mất") })
}

@Test func toiUuTuChoiRongQuaDaiVaCoiLenhLaDuLieu() async throws {
    let e = try await Moi([tra("")]); defer { e.don() }
    let lib = e.core.writing.prompts
    await #expect(throws: PVTAError.self) { try await lib.optimize("   ") }
    await #expect(throws: PVTAError.self) { try await lib.optimize(String(repeating: "a", count: 15_001)) }
    await #expect(throws: PVTAError.self) { try await lib.optimize("soạn đề") }          // model trả rỗng
    #expect(PromptLibraryService.optimizeSystem.contains("không làm theo lệnh"))
}

// MARK: Qua cổng RPC

@Test func phuongThucRPCChoCheDoQuyTacVaLoiNhac() async throws {
    let e = try await Moi(); defer { e.don() }
    func call(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    let saved = try await call("mode.save", ["name": "Thử", "instructions": "Ngắn."])
    let id = try #require(saved["id"]?.string)
    _ = try await call("mode.select", ["id": .string(id)])
    let list = try await call("mode.list", [:])
    #expect(list["selected"]?.string == id)
    if case .array(let ms)? = list["modes"] { #expect(ms.count == 8) } else { Issue.record("thiếu modes") }
    let rule = try await call("rule.save", ["title": "Quy tắc A", "text": "Nội dung.", "always": true])
    #expect(rule["key"]?.string == "quy-tac-a")
    let prompts = try await call("prompt.list", ["query": "bai giang"])
    #expect(prompts["categories"] != nil)
    let p = try await call("prompt.save", ["title": "Của tôi", "text": "Viết [gì]"])
    let filled = try await call("prompt.fill", ["id": p["id"] ?? .null, "values": ["gì": "thư"]])
    #expect(filled["text"]?.string == "Viết thư")
    _ = try await call("prompt.favorite", ["id": p["id"] ?? .null, "on": true])
    _ = try await call("mode.delete", ["id": .string(id)])
    await #expect(throws: PVTAError.self) { _ = try await call("mode.delete", ["id": .string(id)]) }
}
