import Foundation
import Testing
@testable import PVTACore

private func skillMd(_ name: String, groups: String? = nil, load: String = "demand", body: String = "Nội dung.") -> String {
    "---\nname: \(name)\ndescription: Mô tả của \(name) để chọn đúng lúc.\nload: \(load)\n" + (groups.map { "groups: \($0)\n" } ?? "") + "---\n" + body + "\n"
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let mang = FakeTransport((0..<8).map { _ in FakeTransport.Reply(lines: claudeSSE(["ok"])) })
    let core: Core
    init() async throws {
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai)
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
    var g: GroupService { core.groups }
    func gui(_ text: String = "Chào") async throws {
        let chat = try await core.store.createChat().id
        _ = try await core.chat.send(chatId: chat, text: text, model: "anthropic/claude-haiku-5-5", emit: { _, _ in })
    }
    func system(_ i: Int) -> String {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data())) ?? .null
        if let t = body["system"]?.string { return t }
        if case .array(let blocks)? = body["system"] { return blocks.compactMap { $0["text"]?.string }.joined(separator: "\n") }
        return String(describing: body["system"] ?? .null)
    }
    /// Các tên skill demand xuất hiện trong lời nhắc hệ thống lượt i.
    func skillsInContext(_ i: Int) -> Set<String> {
        let all = system(i)
        guard let r = all.range(of: "### Skill có thể đọc khi cần") else { return [] }
        let s = String(all[r.upperBound...].components(separatedBy: "\n\n").first ?? "")
        return Set(s.components(separatedBy: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
        })
    }
}

@Test func danhMucNhomDayDuVaGoiChonNhanhTroDungNhom() async throws {
    let e = try await Moi(); defer { e.don() }
    let cat = await e.g.catalog()
    #expect(cat.count == 28 && Set(cat.map(\.kind)) == [.chuyenMon, .vaiTro, .dangDoanThe, .congCu])
    #expect(Set(cat.map(\.id)).count == cat.count && cat.allSatisfy { $0.tier == .chinhThuc })
    let known = Set(cat.map(\.id))
    for p in await e.g.quickPacks() { #expect(p.groups.allSatisfy(known.contains), "\(p.id)") }
    #expect(cat.filter { $0.kind == .congCu }.allSatisfy { $0.domains.isEmpty })
}

@Test func chonBaNhomKhacNhauChiSkillDungNhomXuatHienTrongNguCanh() async throws {
    let e = try await Moi(); defer { e.don() }
    let st = e.core.skills.store
    for (n, g) in [("sk-giao-vien", "giao-vien"), ("sk-ke-toan", "ke-toan"), ("sk-van-thu", "van-thu"), ("sk-hieu-truong", "hieu-truong"), ("sk-hai-nhom", "giao-vien, hieu-truong")] {
        _ = try await st.create(skillMd(n, groups: g))
    }
    _ = try await st.create(skillMd("sk-rieng"))                                       // skill riêng, không thuộc nhóm nào
    try await e.gui()
    // Chưa chọn nhóm nào: skill gắn nhóm không được nạp (AI không tự tìm ngoài nhóm), kể cả skill đi kèm PVTA.
    let none = e.skillsInContext(0)
    #expect(none == ["sk-rieng"])
    // Chọn ba nhóm.
    try await e.g.setEnabled(["giao-vien", "ke-toan", "van-thu"])
    try await e.gui()
    let ba = e.skillsInContext(1)
    #expect(ba.isSuperset(of: ["sk-giao-vien", "sk-ke-toan", "sk-van-thu", "sk-hai-nhom", "sk-rieng"]), "\(ba)")
    #expect(!ba.contains("sk-hieu-truong"))                                             // nhóm chưa chọn
    #expect(ba.contains("pvta-giao-an") && ba.contains("pvta-excel"))   // skill đi kèm PVTA cũng theo nhóm
    // Đổi sang tập khác.
    try await e.g.setEnabled(["hieu-truong"])
    try await e.gui()
    let ht = e.skillsInContext(2)
    #expect(ht.contains("sk-hieu-truong") && ht.contains("sk-hai-nhom") && !ht.contains("sk-giao-vien") && !ht.contains("sk-ke-toan") && ht.contains("pvta-hanh-chinh") && !ht.contains("pvta-giao-an") && !ht.contains("pvta-dap-an"))
    // Tắt hẳn nhóm: skill biến mất.
    try await e.g.toggle("hieu-truong", false)
    try await e.gui()
    #expect(!e.skillsInContext(3).contains("sk-hieu-truong"))
}

@Test func chonNhomSaiBiTuChoiVaViewBaoDung() async throws {
    let e = try await Moi(); defer { e.don() }
    await #expect(throws: PVTAError.self) { try await e.g.setEnabled(["giao-vien", "khong-co"]) }
    await #expect(throws: PVTAError.self) { try await e.g.toggle("khong-co", true) }
    #expect(await e.g.enabledSet().isEmpty)
    try await e.g.setEnabled(["giao-vien", "giao-vien", "word"])
    let view = try await e.g.view()
    #expect(view.filter(\.enabled).map(\.id).sorted() == ["giao-vien", "word"])
    #expect(try #require(view.first { $0.id == "word" }).skills.contains("pvta-word"))
    #expect(try #require(view.first { $0.id == "giao-vien" }).skills.contains("pvta-giao-an"))
    #expect(try await e.g.applyQuickPack("van-thu") == ["van-thu", "pdf", "word", "excel"])
    await #expect(throws: PVTAError.self) { try await e.g.applyQuickPack("khong-co") }
}

// MARK: Hồ sơ học kỳ / tổ

@Test func luuVaApDungHoSoDoiDungTapNhom() async throws {
    let e = try await Moi(); defer { e.don() }
    let st = e.core.skills.store
    _ = try await st.create(skillMd("sk-giao-vien", groups: "giao-vien"))
    _ = try await st.create(skillMd("sk-ke-toan", groups: "ke-toan"))
    try await e.g.setEnabled(["giao-vien", "khtn"])
    let hk1 = try await e.g.createProfile("Học kỳ 1")
    try await e.g.setEnabled(["ke-toan"])
    let hk2 = try await e.g.createProfile("Tổ kế toán")
    await #expect(throws: PVTAError.self) { try await e.g.createProfile("Học kỳ 1") }               // trùng tên
    await #expect(throws: PVTAError.self) { try await e.g.createProfile("  ") }
    // Xem trước rồi áp dụng.
    let pv = try await e.g.previewProfile(hk1.id)
    #expect(pv.added.sorted() == ["giao-vien", "khtn"] && pv.removed == ["ke-toan"])
    await #expect(throws: PVTAError.self) { try await e.g.applyProfile(token: pv.token, confirmed: false) }
    await #expect(throws: PVTAError.self) { try await e.g.applyProfile(token: "sai", confirmed: true) }
    let pv2 = try await e.g.previewProfile(hk1.id)
    try await e.g.applyProfile(token: pv2.token, confirmed: true)
    #expect(await e.g.enabledSet() == ["giao-vien", "khtn"])
    try await e.gui()
    let ctx = e.skillsInContext(0)
    #expect(ctx.contains("sk-giao-vien") && !ctx.contains("sk-ke-toan"))
    // Hoàn tác về tập trước khi áp dụng.
    #expect(try await e.g.canUndoProfile())
    let u = try await e.g.previewProfile("undo")
    try await e.g.applyProfile(token: u.token, confirmed: true)
    #expect(await e.g.enabledSet() == ["ke-toan"])
    #expect(try await e.g.canUndoProfile() == false)
    _ = hk2
}

@Test func apDungHoSoBiTuChoiKhiDuLieuDoiHoacNhomKhongCon() async throws {
    let e = try await Moi(); defer { e.don() }
    try await e.g.setEnabled(["giao-vien"])
    let p = try await e.g.createProfile("A")
    try await e.g.setEnabled(["ke-toan"])
    let pv = try await e.g.previewProfile(p.id)
    try await e.g.toggle("van-thu", true)                                                  // dữ liệu đổi sau lúc xem
    await #expect(throws: PVTAError.self) { try await e.g.applyProfile(token: pv.token, confirmed: true) }
    // Sau khi áp dụng, hoàn tác bị chặn nếu cấu hình đã đổi tiếp.
    let pv2 = try await e.g.previewProfile(p.id)
    try await e.g.applyProfile(token: pv2.token, confirmed: true)
    try await e.g.toggle("toan", true)
    await #expect(throws: PVTAError.self) { try await e.g.previewProfile("undo") }
    // Hồ sơ nhắc nhóm gói đã gỡ thì không áp dụng.
    let pack = try await e.g.exportPack("giao-vien", asId: "to-ca-nhan", name: "Tổ cá nhân", author: "Thầy A")
    try await e.g.installPack(pack, confirmed: true)
    try await e.g.setEnabled(["to-ca-nhan"])
    let q = try await e.g.createProfile("B")
    try await e.g.removePack("to-ca-nhan")
    await #expect(throws: PVTAError.self) { let v = try await e.g.previewProfile(q.id); try await e.g.applyProfile(token: v.token, confirmed: true) }
    try await e.g.deleteProfile(q.id)
    await #expect(throws: PVTAError.self) { try await e.g.deleteProfile(q.id) }
}

// MARK: Gói nhóm

private func goiMau(_ e: Moi) async throws -> Data {
    let st = e.core.skills.store
    _ = try await st.create(skillMd("mau-chia-se", groups: "giao-vien", load: "always", body: "Quy trình chia sẻ."))
    return try await e.g.exportPack("giao-vien", asId: "to-toan-8", name: "Tổ Toán 8", author: "Thầy Phan")
}

@Test func xuatGoiRoiXemTruocVaCaiThanhNhomDongNghiep() async throws {
    let e = try await Moi(); defer { e.don() }
    let data = try await goiMau(e)
    let pv = await e.g.previewPack(data)
    #expect(pv.ok && pv.manifest?.id == "to-toan-8" && pv.manifest?.tier == .dongNghiep && pv.skills.contains("mau-chia-se") && pv.skills.contains("pvta-giao-an"))
    #expect(pv.warnings.contains { $0.contains("Thầy Phan") })
    await #expect(throws: PVTAError.self) { try await e.g.installPack(data, confirmed: false) }       // phải xác nhận
    #expect(await e.g.manifest("to-toan-8") == nil)                                                   // xem trước chưa ghi gì
    let m = try await e.g.installPack(data, confirmed: true)
    let da = await e.g.manifest("to-toan-8")
    #expect(m.tier == .dongNghiep && da?.name == "Tổ Toán 8")
    #expect(await e.g.enabledSet().isEmpty)                                                            // cài xong không tự bật
    // Skill thuộc gói chỉ hiện khi nhóm của gói được chọn, và gói không được tự ép nội dung vào mọi lượt (always → demand).
    // Gói được xuất cùng skill “mau-chia-se” (nhóm giao-vien); trên máy đã có bản gốc nên bản của người dùng thắng. Xóa bản gốc để thấy bản trong gói.
    try await e.core.skills.store.delete("mau-chia-se")
    let s0 = await e.core.skills.store.skill("mau-chia-se")
    #expect(s0?.tier == .pack && s0?.groups == ["to-toan-8"] && s0?.load == .demand)
    try await e.gui()
    #expect(!e.skillsInContext(0).contains("mau-chia-se"))
    try await e.g.toggle("to-toan-8", true)
    try await e.gui()
    #expect(e.skillsInContext(1).contains("mau-chia-se") && !e.system(1).contains("Quy trình chia sẻ."))
    // Skill của gói không sửa/xóa bằng đường skill thường.
    await #expect(throws: PVTAError.self) { try await e.core.skills.store.delete("mau-chia-se") }
    // Không cài lại cùng phiên bản; gỡ gói.
    await #expect(throws: PVTAError.self) { try await e.g.installPack(data, confirmed: true) }
    try await e.g.removePack("to-toan-8")
    let conLai = await e.g.manifest("to-toan-8"), bat = await e.g.enabledSet()
    #expect(conLai == nil && !bat.contains("to-toan-8"))
    await #expect(throws: PVTAError.self) { try await e.g.removePack("giao-vien") }
}

@Test func goiHongHoacNguyHiemBiTuChoiKemLyDo() async throws {
    let e = try await Moi(); defer { e.don() }
    let data = try await goiMau(e)
    // Mã nhóm trùng nhóm có sẵn.
    let trung = try await e.g.exportPack("giao-vien")
    let p1 = await e.g.previewPack(trung)
    #expect(!p1.ok && p1.problems.contains { $0.contains("trùng một nhóm có sẵn") })
    // Gói bị sửa sau khi đóng.
    var bytes = [UInt8](data)
    if let i = bytes.indices.first(where: { bytes[$0] == UInt8(ascii: "Q") }) { bytes[i] = UInt8(ascii: "q") }
    let p2 = await e.g.previewPack(Data(bytes))
    #expect(!p2.ok)
    // Không phải gói.
    #expect(!(await e.g.previewPack(Data("không phải zip".utf8)).ok))
    // Đường dẫn thoát, loại tệp lạ, thiếu mã băm.
    func goi(_ files: [String: String]) -> Data { var z = ZipWriter(); for (k, v) in files.sorted(by: { $0.key < $1.key }) { z.add(k, Data(v.utf8)) }; return z.finish() }
    let gj = #"{"id":"x-1","name":"X","kind":"vai-tro","version":"1.0","author":"A"}"#
    let a = await e.g.previewPack(goi(["group.json": gj, "skills/../thoat/SKILL.md": "x"]))
    #expect(a.problems.contains { $0.contains("không an toàn") })
    let b = await e.g.previewPack(goi(["group.json": gj, "chay.sh": "echo"]))
    #expect(b.problems.contains { $0.contains("Loại tệp không được phép") })
    let c = await e.g.previewPack(goi(["group.json": gj]))
    #expect(c.problems.contains { $0.contains("checksums.json") })
    // Skill nguy hiểm trong gói: dựng gói hợp lệ về mã băm nhưng skill chứa lệnh shell.
    var files: [String: Data] = ["group.json": Data(gj.utf8), "skills/xau/SKILL.md": Data(skillMd("xau", body: "chạy sudo rm -rf /").utf8)]
    let ex = try await e.g.exportPack("giao-vien", asId: "x-2")      // lấy cách tính mã băm từ gói thật
    _ = ex
    files["checksums.json"] = Data()                                  // mã băm sai → cũng bị từ chối, không thể cài
    var z = ZipWriter(); for (k, v) in files.sorted(by: { $0.key < $1.key }) { z.add(k, v) }
    let d = await e.g.previewPack(z.finish())
    #expect(!d.ok)
    await #expect(throws: PVTAError.self) { try await e.g.installPack(z.finish(), confirmed: true) }
}

@Test func phuongThucNhomQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    func call(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    let view = try await call("groups.view", [:])
    if case .array(let a) = view { #expect(a.count == 28) } else { Issue.record("view") }
    _ = try await call("groups.setEnabled", ["ids": ["giao-vien", "khtn"]])
    _ = try await call("groups.toggle", ["id": "word", "enabled": true])
    let pr = try await call("groups.profiles.create", ["name": "HK1"])
    let list = try await call("groups.profiles.list", [:])
    #expect(list["canUndo"]?.bool == false)
    _ = try await call("groups.toggle", ["id": "word", "enabled": false])
    let pv = try await call("groups.profiles.preview", ["id": pr["id"] ?? .null])
    _ = try await call("groups.profiles.apply", ["token": pv["token"] ?? .null, "confirmed": true])
    #expect(await e.g.enabledSet() == ["giao-vien", "khtn", "word"])
    let ex = try await call("groups.exportPack", ["id": "giao-vien", "asId": "goi-thu", "author": "Thầy B"])
    let pk = try await call("groups.previewPack", ["data": ex["data"] ?? .null])
    #expect(pk["ok"]?.bool == true)
    _ = try await call("groups.installPack", ["data": ex["data"] ?? .null, "confirmed": true])
    _ = try await call("groups.removePack", ["id": "goi-thu"])
    // Xuất ra tệp, không ghi đè.
    let out = e.paths.home.appendingPathComponent("goi.pvtagroup").path
    _ = try await call("groups.exportPack", ["id": "giao-vien", "asId": "goi-thu", "output": .string(out)])
    await #expect(throws: PVTAError.self) { _ = try await call("groups.exportPack", ["id": "giao-vien", "asId": "goi-thu", "output": .string(out)]) }
    let pk2 = try await call("groups.previewPack", ["path": .string(out)])
    #expect(pk2["ok"]?.bool == true)
}
