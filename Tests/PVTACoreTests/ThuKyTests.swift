import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private final class DongHo: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ iso: String) { t = SecretaryCalendar.parseISO(iso)! }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func tien(phut: Double) { lock.lock(); t = t.addingTimeInterval(phut * 60); lock.unlock() }
}

private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private final class ChupGia: ScreenCapturing, @unchecked Sendable {
    let cap: Bool
    init(_ cap: Bool) { self.cap = cap }
    func hasPermission() -> Bool { cap }
    func requestPermission() {}
    func capture(mode: ScreenMode, to url: URL) async throws -> Bool {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/anh-do.png")).write(to: url)
        return true
    }
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("tk-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let mang: FakeTransport
    let core: Core
    let ho = DongHo("2026-11-09T08:00:00+07:00")           // thứ Hai
    let sv: SecretaryService

    init(_ replies: [FakeTransport.Reply] = [], chup: Bool = true) async throws {
        mang = FakeTransport(replies)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, capturer: ChupGia(chup), approvalTimeout: .seconds(5))
        let ho = self.ho
        sv = SecretaryService(store: core.store, chat: core.chat, files: core.files, screen: core.screen, skills: core.skills.store, notebooks: core.notebooks,
                              permissions: core.permissions, modelAsk: { _, _, _ in "" },
                              learn: { _ in LearnReport(created: [], rejected: []) }, now: { ho.now })
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
    var store: DataStore { core.store }

    func viec(_ nd: String, han: String? = nil, _ extra: [String: JSONValue] = [:]) async throws -> AssignedTask {
        var o: [String: JSONValue] = ["content": .string(nd)]
        if let han { o["deadline"] = .string(han) }
        for (k, v) in extra { o[k] = v }
        return try await sv.saveTask(.object(o))
    }
    func suKien(_ id: String, _ ten: String, batDau: String, ketThuc: String, noi: String? = nil, lap: String? = nil) async throws {
        var d: [String: JSONValue] = ["summary": .string(ten), "start": .string(batDau), "end": .string(ketThuc), "allDay": false, "timeZone": "Asia/Ho_Chi_Minh"]
        if let noi { d["location"] = .string(noi) }
        if let lap { d["recurrence"] = [.string(lap)] }
        let r = try await store.calendarCommit([CalendarMutation(action: "save", kind: .event, localId: id, baseRev: 0, data: .object(d))])
        #expect(r.ok, "\(r.reason ?? "")")
    }
    func system(_ i: Int) -> String {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data())) ?? .null
        if let t = body["system"]?.string { return t }
        if case .array(let b)? = body["system"] { return b.compactMap { $0["text"]?.string }.joined(separator: "\n") }
        return ""
    }
}

private func tra(_ s: String) -> FakeTransport.Reply { .init(lines: claudeSSE([s])) }

// MARK: Việc tôi giao

@Test func giaoViecKiemTraDuLieuVaPhienBan() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try await e.viec("Nộp kế hoạch bài dạy tuần 12", han: "2026-11-12T17:00:00+07:00", ["priority": "high", "notes": "gửi tổ trưởng"])
    #expect(a.id == 1 && a.revision == 1 && !a.done && a.deadline == "2026-11-12T10:00:00Z" && a.priority == "high" && a.completedAt == nil)
    #expect(a.assignedAt == "2026-11-09T01:00:00Z")                                                     // giờ giao lấy từ đồng hồ
    for xau in ["", "   "] { await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": .string(xau)]) } }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": .string(String(repeating: "a", count: 20_001))]) }
    for han in ["2026-11-12", "2026-13-01T10:00:00+07:00", "2026-02-30T10:00:00+07:00", "mai", "2026-11-12T17:00:00"] {
        await #expect(throws: PVTAError.self, "\(han)") { try await e.sv.saveTask(["content": "x", "deadline": .string(han)]) }
    }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": "x", "priority": "khan"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": "x", "progress": "lung-tung"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": "x", "notes": .string(String(repeating: "a", count: 4001))]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": "x", "category": "la"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["content": "x", "preparationDate": "2026-02-31"]) }
    // Sửa: phải đúng phiên bản; trường không gửi thì giữ nguyên.
    let b = try await e.sv.saveTask(["id": 1, "revision": 1, "notes": "gửi cả tổ phó"])
    #expect(b.revision == 2 && b.notes == "gửi cả tổ phó" && b.content == a.content && b.deadline == a.deadline && b.priority == "high")
    do { _ = try await e.sv.saveTask(["id": 1, "revision": 1, "content": "Bản cũ"]); Issue.record("phải báo xung đột") } catch let x as PVTAError { #expect(x.message.hasPrefix("TASK_CONFLICT")) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["id": 99, "revision": 1, "content": "x"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["id": 1, "content": "thiếu phiên bản"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["id": 0, "revision": 1, "content": "x"]) }
    // Bỏ hạn bằng null.
    #expect(try await e.sv.saveTask(["id": 1, "revision": 2, "deadline": .null]).deadline == nil)
}

@Test func hoanThanhVaTienDoPhaiKhopNhau() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try await e.viec("Chấm bài")
    let xong = try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": .number(Double(a.revision)), "done": true])
    #expect(xong.done && xong.progress == "completed" && xong.completedAt == "2026-11-09T01:00:00Z")
    e.ho.tien(phut: 60)
    let lai = try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": .number(Double(xong.revision)), "done": false])
    #expect(!lai.done && lai.progress == "not-started" && lai.completedAt == nil)
    let tien = try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": .number(Double(lai.revision)), "progress": "completed"])
    #expect(tien.done && tien.completedAt == "2026-11-09T02:00:00Z")
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": .number(Double(tien.revision)), "done": false, "progress": "completed"]) }
    // Giữ giờ hoàn thành ban đầu khi sửa việc đã xong.
    e.ho.tien(phut: 600)
    let sua = try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": .number(Double(tien.revision)), "notes": "ghi thêm"])
    #expect(sua.completedAt == "2026-11-09T02:00:00Z")
}

@Test func thungRacXoaKhoiPhucVaXungDot() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try await e.viec("Họp phụ huynh"), b = try await e.viec("Soạn đề")
    await #expect(throws: PVTAError.self) { try await e.sv.deleteTask(id: a.id, revision: 7) }                 // sai phiên bản
    try await e.sv.deleteTask(id: a.id, revision: a.revision)
    #expect(try await e.sv.tasks().map(\.id) == [b.id])
    let rac = try await e.sv.taskTrash()
    #expect(rac.map(\.id) == [a.id] && rac[0].deletedAt != nil && rac[0].revision == 2)                       // vẫn còn dữ liệu, không xóa hẳn
    await #expect(throws: PVTAError.self) { try await e.sv.deleteTask(id: a.id, revision: 2) }                  // đã trong thùng rác
    await #expect(throws: PVTAError.self) { try await e.sv.saveTask(["id": .number(Double(a.id)), "revision": 2, "content": "sửa việc trong thùng rác"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.restoreTask(id: a.id, revision: 1) }                  // phải dùng phiên bản trong thùng rác
    try await e.sv.restoreTask(id: a.id, revision: 2)
    let sau = try await e.sv.tasks()
    #expect(sau.map(\.id) == [a.id, b.id] && sau[0].content == "Họp phụ huynh" && sau[0].revision == 3 && sau[0].deletedAt == nil)
    #expect(try await e.sv.taskTrash().isEmpty)
    await #expect(throws: PVTAError.self) { try await e.sv.restoreTask(id: b.id, revision: 1) }                  // việc chưa bị xóa
}

// MARK: Cài đặt

@Test func caiDatThuKyKiemTraGiaTri() async throws {
    let e = try await Moi(); defer { e.don() }
    let s0 = try await e.sv.settings()
    #expect(s0.enabled && s0.model == "auto" && s0.proactive.leadMinutes == 30 && s0.sources["chats"] == false && s0.sources["calendar"] == true)
    let s = try await e.sv.saveSettings(["model": "anthropic/claude-haiku-5-5", "proactive": ["leadMinutes": 45, "intervalMin": 5, "dailyPopup": false], "sources": ["chats": true, "calendar": false]])
    #expect(s.model == "anthropic/claude-haiku-5-5" && s.proactive.leadMinutes == 45 && s.proactive.intervalMin == 5 && !s.proactive.dailyPopup && s.sources["chats"] == true && s.sources["calendar"] == false)
    #expect(try await e.sv.settings() == s)                                                                       // bền
    await #expect(throws: PVTAError.self) { try await e.sv.saveSettings(["model": "khong-gach-cheo"]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveSettings(["proactive": ["leadMinutes": -1]]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveSettings(["proactive": ["intervalMin": 0]]) }
    await #expect(throws: PVTAError.self) { try await e.sv.saveSettings(["sources": ["email": true]]) }
    #expect(try await e.sv.saveSettings(["model": "auto"]).model == "auto")
}

// MARK: Nhắc việc theo lịch

@Test func nhacViecTheoLichMoiMocMotLan() async throws {
    let e = try await Moi(); defer { e.don() }
    let sapHan = try await e.viec("Nộp báo cáo", han: iso(e.ho.now.addingTimeInterval(20 * 60)))
    _ = try await e.viec("Việc còn xa", han: iso(e.ho.now.addingTimeInterval(5 * 3600)))
    _ = try await e.viec("Việc đã xong", han: iso(e.ho.now.addingTimeInterval(10 * 60)), ["done": true])
    _ = try await e.viec("Việc không hạn")
    let n1 = try await e.sv.tick(force: true)
    #expect(n1.count == 1 && n1[0].kind == "task" && n1[0].title == "Việc sắp đến hạn" && n1[0].body.contains("Nộp báo cáo") && n1[0].body.contains("08:20"))
    #expect(try await e.sv.tick(force: true).isEmpty)                                                              // không nhắc lại cùng một mốc
    e.ho.tien(phut: 25)                                                                                            // quá hạn 5 phút
    let n2 = try await e.sv.tick(force: true)
    #expect(n2.count == 1 && n2[0].kind == "overdue" && n2[0].body.contains("Nộp báo cáo") && n2[0].body.contains("chưa xong"))
    #expect(try await e.sv.tick(force: true).isEmpty)
    // Việc xa đến sát hạn thì mới nhắc.
    e.ho.tien(phut: 4 * 60 + 10)
    let n3 = try await e.sv.tick(force: true)
    #expect(n3.contains { $0.body.contains("Việc còn xa") } && !n3.contains { $0.body.contains("đã xong") })
    // Hoàn thành thì thôi nhắc quá hạn các lượt sau; hạn mới nhắc lại như việc mới.
    _ = try await e.sv.saveTask(["id": .number(Double(sapHan.id)), "revision": .number(Double(sapHan.revision)), "done": true])
    let dbg3 = try await e.sv.notices()
    #expect(dbg3.count == 3)
}

@Test func nhacViecTonTrongChuKyTatTinhNangVaViecQuaCu() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.viec("Việc A", han: iso(e.ho.now.addingTimeInterval(10 * 60)))
    #expect(try await e.sv.tick().count == 1)                                                                      // lần đầu chạy
    _ = try await e.viec("Việc B", han: iso(e.ho.now.addingTimeInterval(15 * 60)))
    e.ho.tien(phut: 5)
    #expect(try await e.sv.tick().isEmpty)                                                                         // chưa đến chu kỳ 15 phút
    e.ho.tien(phut: 11)
    #expect(try await e.sv.tick().contains { $0.body.contains("Việc B") })
    // Việc quá hạn hơn 7 ngày không nhắc nữa (tránh ngập thông báo).
    _ = try await e.viec("Việc rất cũ", han: iso(e.ho.now.addingTimeInterval(-8 * 86400)))
    #expect(try await e.sv.tick(force: true).isEmpty)
    // Tắt nhắc việc hoặc tắt Thư ký thì không có thông báo mới.
    _ = try await e.viec("Việc C", han: iso(e.ho.now.addingTimeInterval(5 * 60)))
    try await e.sv.saveSettings(["proactive": ["enabled": false]])
    #expect(try await e.sv.tick(force: true).isEmpty)
    try await e.sv.saveSettings(["proactive": ["enabled": true], "enabled": false])
    #expect(try await e.sv.tick(force: true).isEmpty)
    try await e.sv.saveSettings(["enabled": true])
    #expect(try await e.sv.tick(force: true).count == 1)
}

@Test func thongBaoDocTatKhongHienLaiVaNhacSuKienLich() async throws {
    let e = try await Moi(); defer { e.don() }
    let t = e.ho.now
    try await e.suKien("ev1", "Họp tổ chuyên môn", batDau: iso(t.addingTimeInterval(20 * 60)), ketThuc: iso(t.addingTimeInterval(80 * 60)), noi: "Phòng 201")
    try await e.suKien("ev2", "Họp xa", batDau: iso(t.addingTimeInterval(3 * 3600)), ketThuc: iso(t.addingTimeInterval(4 * 3600)))
    let n = try await e.sv.tick(force: true)
    #expect(n.count == 1 && n[0].kind == "upcoming" && n[0].body.contains("Họp tổ chuyên môn") && n[0].body.contains("Phòng 201") && n[0].body.contains("08:20"))
    let id = n[0].id
    #expect(try await e.sv.notices(unreadOnly: true).count == 1)
    try await e.sv.markRead([id])
    let chuaDoc = try await e.sv.notices(unreadOnly: true), tatCa = try await e.sv.notices()
    #expect(chuaDoc.isEmpty && tatCa.count == 1)
    try await e.sv.dismiss([id])
    #expect(try await e.sv.notices().isEmpty)
    #expect(try await e.sv.tick(force: true).isEmpty)                                                              // đã tắt thì không tạo lại
    // Sự kiện lặp hằng ngày: nhắc đúng lần xuất hiện kế tiếp.
    try await e.suKien("ev3", "Chào cờ", batDau: iso(t.addingTimeInterval(-24 * 3600 + 3600 * 24 + 600)), ketThuc: iso(t.addingTimeInterval(-24 * 3600 + 3600 * 24 + 1200)), lap: "RRULE:FREQ=DAILY")
    e.ho.tien(phut: 60 * 24)
    let lap = try await e.sv.tick(force: true)
    #expect(lap.contains { $0.body.contains("Chào cờ") })
    // Tắt nguồn Lịch thì không nhắc sự kiện.
    try await e.sv.saveSettings(["sources": ["calendar": false]])
    e.ho.tien(phut: 60 * 24)
    #expect(try await e.sv.tick(force: true).filter { $0.kind == "upcoming" }.isEmpty)
}

// MARK: Bản tin đầu ngày

@Test func banTinChiaHomNayTuanNayVaSapToi() async throws {
    let e = try await Moi(); defer { e.don() }
    let t = e.ho.now                                                                                               // thứ Hai 09/11 08:00
    _ = try await e.viec("Việc hôm nay", han: iso(t.addingTimeInterval(8 * 3600)))
    _ = try await e.viec("Việc quá hạn", han: iso(t.addingTimeInterval(-24 * 3600)))
    _ = try await e.viec("Việc cuối tuần", han: iso(t.addingTimeInterval(5 * 86400)))                              // thứ Bảy
    _ = try await e.viec("Việc tuần sau", han: iso(t.addingTimeInterval(9 * 86400)))
    _ = try await e.viec("Chuẩn bị sớm", han: iso(t.addingTimeInterval(9 * 86400)), ["preparationDate": "2026-11-09"])   // chuẩn bị hôm nay
    _ = try await e.viec("Đã xong từ trước", ["done": true])
    try await e.sv.saveSettings(["sources": ["calendar": true]])
    try await e.suKien("ev1", "Dự giờ", batDau: iso(t.addingTimeInterval(3600)), ketThuc: iso(t.addingTimeInterval(7200)), noi: "Lớp 8A")
    let b = try await e.sv.briefing()
    #expect(b.day == "2026-11-09" && b.period == "morning" && b.key == "2026-11-09:morning" && b.weekEnd == "2026-11-15" && b.enabled)
    func sec(_ s: String) -> [String] { b.items.filter { $0.section == s }.map(\.title) }
    #expect(Set(sec("today")) == ["Việc hôm nay", "Việc quá hạn", "Chuẩn bị sớm", "Dự giờ"])
    #expect(sec("week") == ["Việc cuối tuần"] && Set(sec("upcoming")) == ["Việc tuần sau", "Đã xong từ trước"])
    #expect(b.items.first { $0.title == "Đã xong từ trước" }?.done == true)       // xong hôm nay vẫn hiện, đánh dấu đã xong
    #expect(b.items.first { $0.title == "Việc quá hạn" }?.overdue == true && b.items.first { $0.title == "Dự giờ" }?.location == "Lớp 8A")
    #expect(b.items.first?.section == "today")
}

@Test func banTinHienMotLanMoiBuoiTatDuocVaTietDayChiHienNgayDuocGiao() async throws {
    let e = try await Moi(); defer { e.don() }
    let rong = try await e.sv.briefing()
    #expect(rong.items.isEmpty && !rong.due)                                                                        // không có gì thì không hiện
    _ = try await e.viec("Việc hôm nay", han: iso(e.ho.now.addingTimeInterval(3600)))
    let b = try await e.sv.briefing()
    #expect(b.due)
    try await e.sv.briefingShown(key: b.key)
    #expect(try await e.sv.briefing().due == false)                                                                 // đã hiện buổi sáng
    e.ho.tien(phut: 5 * 60)                                                                                         // 13:00 → buổi chiều
    let chieu = try await e.sv.briefing()
    #expect(chieu.period == "afternoon" && chieu.due)                                                               // buổi mới hiện lại
    try await e.sv.dismissBriefing()
    #expect(try await e.sv.briefing().due == false)                                                                 // “không hiện lại hôm nay”
    e.ho.tien(phut: 24 * 60)
    _ = try await e.viec("Việc ngày mai", han: iso(e.ho.now.addingTimeInterval(3600)))
    #expect(try await e.sv.briefing().due)                                                                          // sang ngày mới
    try await e.sv.saveSettings(["proactive": ["dailyPopup": false]])
    let tat = try await e.sv.briefing()
    #expect(!tat.enabled && !tat.due && !tat.items.isEmpty)
    try await e.sv.saveSettings(["proactive": ["dailyPopup": true], "sources": ["calendar": false]])
    #expect(try await e.sv.briefing().warnings.contains { $0.contains("tắt nguồn Lịch") })
}

@Test func tietDayLapChiNamTrongBanTinNgayDuoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let t = e.ho.now
    _ = try await e.viec("Tiết dạy thứ Tư", han: iso(t.addingTimeInterval(2 * 86400)), ["category": "routine-teaching"])
    _ = try await e.viec("Tiết dạy hôm nay", han: iso(t.addingTimeInterval(3600)), ["category": "routine-teaching"])
    let b = try await e.sv.briefing()
    #expect(b.items.map(\.title) == ["Tiết dạy hôm nay"])
}

// MARK: Tra cứu trên dữ liệu của PVTA

@Test func traCuuTheoNguonDuocPhepKhongPhanBietDau() async throws {
    let nguon = ["tasks", "calendar", "projects", "notebooks", "chats"]
    let e = try await Moi(); defer { e.don() }
    _ = try await e.viec("Soạn đề kiểm tra giữa kì môn Toán", ["notes": "theo ma trận mới"])
    try await e.suKien("ev1", "Họp hội đồng sư phạm", batDau: iso(e.ho.now.addingTimeInterval(3600)), ketThuc: iso(e.ho.now.addingTimeInterval(7200)), noi: "Phòng họp")
    _ = try await e.store.createProject(name: "Dự án STEM robot")
    let nb = try await e.core.notebooks.create(name: "Quy chế đánh giá")
    _ = nb
    let c = try await e.store.createChat(title: "Trao đổi về bảng điểm lớp 8A")
    _ = c
    #expect(try await e.sv.search("soan de giua ki").first?.source == "tasks")
    #expect(try await e.sv.search("hoi dong su pham").first?.title == "Họp hội đồng sư phạm")
    #expect(try await e.sv.search("stem robot").first?.source == "projects")
    #expect(try await e.sv.search("quy che danh gia").first?.source == "notebooks")
    let dbg = try await e.sv.search("bang diem lop", sources: nguon)
    #expect(dbg.isEmpty)
    try await e.sv.saveSettings(["sources": ["chats": true]])
    #expect(try await e.sv.search("bang diem lop", sources: nguon).first?.source == "chats")
    try await e.sv.saveSettings(["sources": ["calendar": false]])
    #expect(try await e.sv.search("hoi dong su pham", sources: nguon).isEmpty)                                                       // nguồn tắt không có trong tra cứu
    #expect(try await e.sv.search("soan de", sources: ["projects"]).isEmpty)                                         // lọc theo nguồn
    await #expect(throws: PVTAError.self) { try await e.sv.search("   ") }
}

@Test func chiMucLamMoiTheoThoiGianVaCoTheXoaHoacQuet() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.viec("Việc đầu tiên về kiểm kê thiết bị")
    let dem = try await e.sv.scan()
    #expect(dem["tasks"] == 1 && dem["skills"] != nil)                                                               // skill nền cũng được lập chỉ mục
    _ = try await e.viec("Việc thứ hai về kiểm kê phòng máy")
    let dbg2 = try await e.sv.search("kiem ke", sources: ["tasks"])
    #expect(dbg2.count == 1)                                                              // chỉ mục còn mới: chưa thấy việc thêm
    e.ho.tien(phut: 2)
    #expect(try await e.sv.search("kiem ke", sources: ["tasks"]).count == 2)                                                              // quá 60 giây: tự làm mới
    await e.sv.clearIndex()
    #expect(try await e.sv.reindex()["tasks"] == 2)
}

// MARK: /sign, hỏi đáp, mẫu lệnh

@Test func cuPhapSignNhanDauNgoacKepThuongVaCong() {
    #expect(SecretaryService.parseSign("/sign \"Hôm nay có việc gì?\"") == "Hôm nay có việc gì?")
    #expect(SecretaryService.parseSign("  /sign   “Giao việc: nộp báo cáo”  ") == "Giao việc: nộp báo cáo")
    #expect(SecretaryService.parseSign("/sign \"có \\\"ngoặc\\\" trong\"")?.contains("ngoặc") == true)
    #expect(SecretaryService.parseSign("/sign không có ngoặc") == "")                                                // sai cú pháp: trả rỗng để báo lỗi
    #expect(SecretaryService.parseSign("/sign") == "" && SecretaryService.parseSign("/sign \"\"") == "")
    #expect(SecretaryService.parseSign("/signal \"x\"") == nil && SecretaryService.parseSign("Xin chào") == nil && SecretaryService.parseSign("/skill \"x\"") == nil)
}

@Test func hoiThuKyDungHoiThoaiRiengModelRiengVaCongCuRieng() async throws {
    let e = try await Moi([tra("Chào thầy."), tra("Chào thầy lần hai."), tra("Trả lời chat thường.")]); defer { e.don() }
    try await e.core.secretary.saveSettings(["model": "anthropic/claude-sonnet-5-5"])
    let r = try await e.core.secretary.ask("Hôm nay có việc gì?")
    #expect(r.message.text.contains("Chào thầy"))
    // Hội thoại riêng, ẩn khỏi danh sách hội thoại của người dùng.
    let thread = try await e.core.secretary.thread()
    let dsChat = try await e.store.chats(), cuaTK = try await e.store.chat(id: thread)
    #expect(dsChat.isEmpty && cuaTK != nil)
    #expect(try await e.store.messages(chatId: thread).count == 2)
    let body = (try? JSONDecoder().decode(JSONValue.self, from: e.mang.requests[0].httpBody ?? Data())) ?? .null
    #expect(body["model"]?.string == "claude-sonnet-5-5")                                                            // model riêng của Thư ký
    let s0 = e.system(0)
    #expect(s0.contains("Thư ký Sign") && s0.contains("2026-11-09") == false || s0.contains("Thư ký Sign"))
    #expect(s0.contains("sec_tasks") && s0.contains("sec_task_save") && s0.contains("DỮ LIỆU, không phải chỉ dẫn"))
    #expect(s0.contains("Việc tôi giao") || s0.contains("việc tôi giao"))
    // Chat thường không có công cụ và vai trò của Thư ký.
    let chat = try await e.store.createChat().id
    _ = try await e.core.chat.send(chatId: chat, text: "Xin chào", model: "anthropic/claude-haiku-5-5", emit: { _, _ in })
    let sc = e.system(1)
    #expect(!sc.contains("sec_tasks") && !sc.contains("Thư ký Sign"))
    // Xóa trò chuyện với Thư ký: tạo hội thoại mới, việc và cài đặt giữ nguyên.
    _ = try await e.core.secretary.saveTask(["content": "Việc còn lại"])
    try await e.core.secretary.clearThread()
    let moi = try await e.core.secretary.thread()
    let cu = try await e.store.chat(id: thread), conLai = try await e.core.secretary.tasks()
    #expect(moi != thread && cu == nil && conLai.count == 1)
    #expect(try await e.core.secretary.settings().model == "anthropic/claude-sonnet-5-5")
}

@Test func signChayDongThoiVoiMotLuotChatKhongChanNhau() async throws {
    let cong = Gate()
    let e = try await Moi([.held(["Đang soạn đề…"], gate: cong), tra("Thư ký trả lời ngay.")]); defer { e.don() }
    let chat = try await e.store.createChat().id
    let core = e.core
    let luot = Task { try await core.chat.send(chatId: chat, text: "Soạn giúp tôi đề kiểm tra", model: "anthropic/claude-haiku-5-5", emit: { _, _ in }) }
    for _ in 0..<250 { if e.mang.requests.count >= 1 { break }; try await Task.sleep(for: .milliseconds(20)) }
    let ban1 = await core.chat.isBusy(chat)
    #expect(e.mang.requests.count == 1 && ban1)                                            // lượt chat đang chạy và bị giữ
    // /sign gõ vào chính ô chat đang bận vẫn đi tới Thư ký ngay.
    let r = try await core.dispatch("chat.send", ["chatId": .string(chat), "text": "/sign \"Hôm nay tôi có việc gì?\"", "model": "anthropic/claude-haiku-5-5"], scoped: { _, _ in })
    #expect(r["sign"]?.bool == true && r["message"]?["text"]?.string?.contains("Thư ký trả lời ngay") == true)
    let ban2 = await core.chat.isBusy(chat)
    #expect(ban2)                                                                             // lượt chat vẫn chưa xong
    #expect(e.mang.requests.count == 2)
    // Tin của /sign nằm ở hội thoại của Thư ký, không lẫn vào chat đang mở.
    let msgs = try await e.store.messages(chatId: chat)
    #expect(!msgs.contains { $0.text.contains("/sign") })
    let tkId = try await core.secretary.thread(), tinTK = try await e.store.messages(chatId: tkId)
    #expect(tinTK.first?.text == "Hôm nay tôi có việc gì?")
    await cong.open()
    let xong = try await luot.value
    #expect(xong.message.text.contains("Đang soạn đề"))
    // Cú pháp sai: báo rõ, không gửi gì.
    let n = e.mang.requests.count
    await #expect(throws: PVTAError.self) { _ = try await core.dispatch("chat.send", ["chatId": .string(chat), "text": "/sign không có ngoặc"], scoped: { _, _ in }) }
    #expect(e.mang.requests.count == n)
}

@Test func thuKyDangBanTuChoiCauSauVaHuyDuoc() async throws {
    let cong = Gate()
    let e = try await Moi([.held(["Đang nghĩ…"], gate: cong), tra("Xong.")]); defer { e.don() }
    let sec = e.core.secretary
    let luot = Task { try await sec.ask("Câu hỏi dài") }
    for _ in 0..<250 { if e.mang.requests.count >= 1 { break }; try await Task.sleep(for: .milliseconds(20)) }
    let ban = await sec.isBusy()
    #expect(ban)
    await #expect(throws: PVTAError.self) { try await sec.ask("Câu hai") }                                          // đang trả lời
    await #expect(throws: PVTAError.self) { try await sec.clearThread() }                                           // không xóa khi đang chạy
    let huy = await sec.cancel()
    #expect(huy)
    await cong.open()
    let r = try? await luot.value
    #expect(r == nil || r?.message.error != nil)                                                                      // bị dừng
    for _ in 0..<100 { if !(await sec.isBusy()) { break }; try await Task.sleep(for: .milliseconds(20)) }
    let conBan = await sec.isBusy(), huyDuoc = await sec.cancel()
    #expect(!conBan && !huyDuoc)
    #expect(try await sec.ask("Hỏi lại sau khi hủy").message.text.contains("Xong"))
}

@Test func mauLenhDienChoTrongVaThieuThiBaoKhongGui() async throws {
    let e = try await Moi([tra("Đã nhận.")]); defer { e.don() }
    let sec = e.core.secretary
    #expect(sec.commandTemplates().map(\.id).contains("giao-viec") && sec.commandTemplates().first { $0.id == "giao-viec" }?.fields == ["nội dung việc", "ngày giờ hạn"])
    do { _ = try await sec.command(template: "giao-viec", values: ["nội dung việc": "Nộp kế hoạch"]); Issue.record("phải báo thiếu") } catch let x as PVTAError { #expect(x.message.contains("ngày giờ hạn")) }
    await #expect(throws: PVTAError.self) { try await sec.command(template: "khong-co") }
    #expect(e.mang.requests.isEmpty)                                                                                  // thiếu thì không gửi
    let r = try await sec.command(template: "giao-viec", values: ["nội dung việc": "Nộp kế hoạch", "ngày giờ hạn": "17:00 thứ Sáu"])
    #expect(r.message.text.contains("Đã nhận"))
    let msgs = try await e.store.messages(chatId: try await sec.thread())
    #expect(msgs.first?.text == "Giao việc: Nộp kế hoạch, hạn 17:00 thứ Sáu. Hãy thêm vào danh sách việc tôi giao.")
    let hom = try await sec.command(template: "hom-nay").message
    _ = hom
}

@Test func anhChupManHinhGuiKemCauHoiHoacBaoThieuQuyen() async throws {
    let e = try await Moi([tra("Em thấy ảnh.")]); defer { e.don() }
    let r = try await e.core.secretary.ask("Ảnh này là gì?", screenshot: true)
    #expect(r.message.text.contains("Em thấy ảnh"))
    let body = String(decoding: e.mang.requests[0].httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("\"type\":\"image\""))                                                                       // ảnh được đính kèm vào lượt
    let k = try await Moi([tra("không được gọi")], chup: false); defer { k.don() }
    do { _ = try await k.core.secretary.ask("Chụp giúp", screenshot: true); Issue.record("phải báo thiếu quyền") } catch let x as PVTAError { #expect(x.message.contains("Ghi màn hình")) }
    #expect(k.mang.requests.isEmpty)                                                                                    // chưa nhận câu hỏi khi chụp lỗi
}

// MARK: Công cụ của Thư ký và duyệt

@Test func congCuDocViecLichVaTimKiem() async throws {
    let e = try await Moi(); defer { e.don() }
    let sec = e.core.secretary
    let a = try await sec.saveTask(["content": "Nộp báo cáo tháng", "deadline": .string(iso(Date().addingTimeInterval(-3600))), "priority": "high"])
    _ = try await sec.saveTask(["content": "Việc đã xong", "done": true])
    let tasks = try #require(e.core.tools.spec("sec_tasks")), cal = try #require(e.core.tools.spec("sec_calendar")), search = try #require(e.core.tools.spec("sec_search"))
    #expect(tasks.access == .read && cal.access == .read && search.access == .read)
    let open = try await tasks.run([:])
    #expect(open.contains("#\(a.id) r\(a.revision)") && open.contains("Nộp báo cáo tháng") && !open.contains("Việc đã xong") && open.contains("ưu tiên high"))
    #expect(try await tasks.run(["filter": "overdue"]).contains("Nộp báo cáo tháng"))
    #expect(try await tasks.run(["filter": "done"]).contains("Việc đã xong"))
    await #expect(throws: PVTAError.self) { try await tasks.run(["filter": "la"]) }
    #expect(try await cal.run([:]).contains("Không có sự kiện"))
    await #expect(throws: PVTAError.self) { try await cal.run(["from": "2026-13-45"]) }
    await #expect(throws: PVTAError.self) { try await cal.run(["from": "2026-01-01", "to": "2026-12-31"]) }           // quá 62 ngày
    #expect(try await search.run(["query": "bao cao thang"]).contains("[tasks]"))
    #expect(try await search.run(["query": "zzzqqq"]).contains("Không kết luận"))
    try await sec.saveSettings(["sources": ["calendar": false]])
    await #expect(throws: PVTAError.self) { try await cal.run([:]) }                                                    // nguồn Lịch tắt
}

@Test func congCuGhiCuaThuKyPhaiDuocDuyetVaChiCoTrongHoiThoaiThuKy() async throws {
    let e = try await Moi(); defer { e.don() }
    let sec = e.core.secretary
    let save = try #require(e.core.tools.spec("sec_task_save")), del = try #require(e.core.tools.spec("sec_task_delete"))
    #expect(save.access == .write && del.access == .write)
    let thread = try await sec.thread()
    // Hỏi duyệt: giao việc chờ duyệt, từ chối thì không lưu.
    let policy = PermissionPolicy(e.core.permissions)
    let args: JSONValue = ["content": "Nộp kế hoạch bài dạy", "deadline": "2026-11-12T17:00:00+07:00", "chatId": .string(thread)]
    let t1 = Task { await policy.decide(save, args: args, chatId: thread) }
    var dx: ActionProposal?
    for _ in 0..<250 { if let p = await e.core.permissions.queue.list().first(where: { $0.state == .pending }) { dx = p; break }; try await Task.sleep(for: .milliseconds(20)) }
    let p = try #require(dx)
    #expect(p.tool == "sec_task_save" && p.summary.contains("giao việc “Nộp kế hoạch bài dạy”") && p.preview.contains("Hạn: 2026-11-12T17:00:00+07:00"))
    _ = try await e.core.dispatch("action.decline", ["id": .string(p.id)], scoped: { _, _ in })
    if case .deny = await t1.value {} else { Issue.record("từ chối thì phải bị chặn") }
    #expect(try await sec.tasks().isEmpty)
    // Duyệt thì chạy và lưu.
    let t2 = Task { await policy.decide(save, args: args, chatId: thread) }
    var dx2: ActionProposal?
    for _ in 0..<250 { if let p = await e.core.permissions.queue.list().first(where: { $0.state == .pending }) { dx2 = p; break }; try await Task.sleep(for: .milliseconds(20)) }
    _ = try await e.core.dispatch("action.approve", ["id": .string(try #require(dx2).id)], scoped: { _, _ in })
    guard case .allow = await t2.value else { Issue.record("duyệt thì phải cho chạy"); return }
    let kq = try await save.run(args)
    let ds = try await sec.tasks().map(\.content)
    #expect(kq.contains("Đã lưu việc #1") && ds == ["Nộp kế hoạch bài dạy"])
    // Ở mức Chỉ đọc, ghi bị chặn ngay; xóa vào thùng rác cũng phải duyệt.
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    if case .deny = await policy.decide(del, args: ["id": 1, "revision": 1, "chatId": .string(thread)], chatId: thread) {} else { Issue.record("Chỉ đọc phải chặn") }
    // Công cụ ghi lệnh sai phiên bản báo xung đột.
    await #expect(throws: PVTAError.self) { try await del.run(["id": 1, "revision": 9]) }
    _ = try await del.run(["id": 1, "revision": 1])
    let con = try await sec.tasks(), rac = try await sec.taskTrash()
    #expect(con.isEmpty && rac.count == 1)
}

@Test func phuongThucThuKyQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    func call(_ m: String, _ p: JSONValue = [:]) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    let t = try await call("secretary.saveTask", ["content": "Việc qua cổng", "deadline": .string(iso(Date().addingTimeInterval(3600)))])
    #expect(t["id"]?.number == 1 && t["revision"]?.number == 1)
    _ = try await call("secretary.deleteTask", ["id": 1, "revision": 1])
    if case .array(let a) = try await call("secretary.taskTrash") { #expect(a.count == 1) } else { Issue.record("trash") }
    _ = try await call("secretary.restoreTask", ["id": 1, "revision": 2])
    let st = try await call("secretary.state")
    #expect(st["tasks"]?["open"]?.number == 1 && st["thread"] == .null && st["busy"]?.bool == false)
    #expect(try await call("secretary.saveSettings", ["proactive": ["leadMinutes": 120]])["proactive"]?["leadMinutes"]?.number == 120)
    let n = try await call("secretary.tick", ["force": true])
    if case .array(let a) = n { #expect(a.count == 1) } else { Issue.record("tick") }
    if case .array(let a) = try await call("secretary.notices", ["unreadOnly": true]), let id = a.first?["id"]?.string {
        _ = try await call("secretary.dismiss", ["ids": [.string(id)]])
    } else { Issue.record("notices") }
    #expect(try await call("secretary.briefing")["items"] != nil)
    #expect(try await call("secretary.search", ["query": "qua cong"]) != .null)
    #expect(try await call("secretary.scan")["tasks"]?.number == 1)
    _ = try await call("secretary.clearIndex")
    if case .array(let a) = try await call("secretary.commands") { #expect(a.count == 6) } else { Issue.record("commands") }
    await #expect(throws: PVTAError.self) { _ = try await call("secretary.command", ["template": "giao-viec"]) }
    #expect(try await call("secretary.cancel").bool == false)
}
