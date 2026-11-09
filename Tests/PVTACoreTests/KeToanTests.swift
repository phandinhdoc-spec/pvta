import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("kt-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = FileManager.default.temporaryDirectory.appendingPathComponent("ktn-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let thuMuc = FileManager.default.temporaryDirectory.appendingPathComponent("ktt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let mang: FakeTransport
    let core: Core
    let chat: String
    let nguon: String, doiChieu: String
    let gate: Gate?

    init(_ replies: [FakeTransport.Reply] = [], gate: Gate? = nil) async throws {
        mang = FakeTransport(replies)
        self.gate = gate
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        for d in [nha, thuMuc] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let g = gate
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: nha, approvalTimeout: .seconds(5),
                    accountingPhase: { p in if p == "snapshot" { await g?.wait() } })
        chat = try await core.store.createChat().id
        for ten in ["ke-toan-nguon.xlsx", "ke-toan-doi-chieu.xlsx"] { try FileManager.default.copyItem(at: mau.appendingPathComponent(ten), to: thuMuc.appendingPathComponent(ten)) }
        let dir = thuMuc, cid = chat
        let r = try await core.attachments.add(chatId: cid, paths: ["ke-toan-nguon.xlsx", "ke-toan-doi-chieu.xlsx"].map { dir.appendingPathComponent($0).path })
        let ds = try await core.attachments.list(chatId: cid)
        let a = ds.first(where: { $0.name == "ke-toan-nguon.xlsx" })!.id
        let b = ds.first(where: { $0.name == "ke-toan-doi-chieu.xlsx" })!.id
        nguon = a; doiChieu = b
        _ = r
    }
    func don() { for u in [paths.home, nha, thuMuc] { try? FileManager.default.removeItem(at: u) } }
    var s: ReconcileSide { .init(sourceId: nguon, sheet: "So", range: "A2:C11", keyColumn: "A", valueColumn: "C") }
    var r: ReconcileSide { .init(sourceId: doiChieu, sheet: "DoiChieu", range: "A2:C9", keyColumn: "A", valueColumn: "C") }
    func chay(tol: String = "0", id: String = UUID().uuidString) async throws -> ReconcileReport {
        try await core.accounting.run(chatId: chat, runId: id, source: s, reference: r, tolerance: tol, unit: "VND")
    }
    var thuMucKetQua: URL { paths.home.appendingPathComponent("accounting-results") }
}

private func dong(_ r: ReconcileReport, _ khoa: String, _ loai: String? = nil) -> [ReconcileRow] { r.rows.filter { $0.key == khoa && (loai == nil || $0.kind == loai) } }

// MARK: Đối soát

@Test func doiSoatChinhXacTheoTungKhoa() async throws {
    let e = try await Moi(); defer { e.don() }
    let r = try await e.chay()
    #expect(r.sourceEdits == false && r.sources.count == 2 && r.sources[0].rowsRead == 10 && r.sources[1].rowsRead == 8 && r.sources.allSatisfy { $0.sha256.count == 64 })
    #expect(dong(r, "TK001").map(\.kind) == ["matched"] && dong(r, "TK001")[0].delta == "0")
    // Số thập phân chính xác, không dùng số thực: 2500000.5 − 2500000.49 = 0.01; 0.1 − 0.2 = −0.1.
    #expect(dong(r, "TK002").map(\.kind) == ["value_mismatch"] && dong(r, "TK002")[0].delta == "0.01")
    #expect(dong(r, "TK003")[0].delta == "-1" && dong(r, "TK003")[0].kind == "value_mismatch")
    #expect(dong(r, "TK006")[0].delta == "-0.1" && dong(r, "TK006")[0].kind == "value_mismatch")
    // Công thức luôn “chưa kiểm chứng”, kể cả khi giá trị lưu khớp; cả hai phía đều được báo, không kết luận khớp.
    let ct = dong(r, "TK004")
    #expect(ct.count == 2 && ct.allSatisfy { $0.kind == "unverified_formula" } && ct.contains { $0.evidence.contains("formula=C2+C3") && $0.evidence.contains("cachedValue=3500000.5") })
    // Số sai định dạng (có dấu chấm nghìn) không được hiểu là số.
    #expect(dong(r, "TK005").count == 2 && dong(r, "TK005").allSatisfy { $0.kind == "invalid_number" })
    // Khóa trùng: báo từng dòng, không cộng gộp hay ghép bừa.
    #expect(dong(r, "TK007").count == 3 && dong(r, "TK007").allSatisfy { $0.kind == "duplicate_key" })
    // Khóa trống, thiếu một phía.
    #expect(dong(r, "").map(\.kind) == ["invalid_key"])
    #expect(dong(r, "TK008").map(\.kind) == ["missing_reference"] && dong(r, "TK009").map(\.kind) == ["missing_source"])
    #expect(dong(r, "TK008")[0].sourceLocation == "ke-toan-nguon.xlsx / So / C11" && dong(r, "TK008")[0].referenceLocation == nil)
    #expect(r.summary.matched == 1 && r.summary.issues == r.rows.count - 1)
}

@Test func saiSoBangDungThiKhopVaSaiSoSaiBiTuChoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let r = try await e.chay(tol: "0.01")
    #expect(dong(r, "TK002")[0].kind == "matched" && dong(r, "TK002")[0].delta == "0.01")      // bằng sai số là khớp
    #expect(dong(r, "TK003")[0].kind == "value_mismatch")
    for xau in ["-1", "1e2", "1,5", "abc", "", " 1", "1.", String(repeating: "9", count: 60)] {
        await #expect(throws: PVTAError.self, "\(xau)") { try await e.chay(tol: xau) }
    }
}

@Test func vungVaThamSoSaiBiTuChoiTruocKhiDoc() async throws {
    let e = try await Moi(); defer { e.don() }
    func vung(_ s: ReconcileSide) async throws { _ = try await e.core.accounting.run(chatId: e.chat, runId: UUID().uuidString, source: s, reference: e.r, tolerance: "0", unit: "VND") }
    var s = e.s
    for rg in ["A1", "a2:c11", "C2:A11", "A0:C5", "A2:C20000", "A2:ZZZZ5", "A2:C11;"] { s.range = rg; await #expect(throws: PVTAError.self, "\(rg)") { try await vung(s) } }
    s = e.s; s.keyColumn = "D"; await #expect(throws: PVTAError.self) { try await vung(s) }                      // cột ngoài vùng
    s = e.s; s.valueColumn = "A"; await #expect(throws: PVTAError.self) { try await vung(s) }                     // trùng cột khóa
    s = e.s; s.sheet = "Khong-co"; await #expect(throws: PVTAError.self) { try await vung(s) }
    s = e.s; s.sourceId = "khong-co"; await #expect(throws: PVTAError.self) { try await vung(s) }
    await #expect(throws: PVTAError.self) { _ = try await e.core.accounting.run(chatId: e.chat, runId: "x", source: e.s, reference: e.s, tolerance: "0", unit: "VND") }   // hai vùng giống nhau
    await #expect(throws: PVTAError.self) { _ = try await e.core.accounting.run(chatId: e.chat, runId: "x", source: e.s, reference: e.r, tolerance: "0", unit: "  ") }
    await #expect(throws: PVTAError.self) { _ = try await e.core.accounting.run(chatId: "khong-co", runId: "x", source: e.s, reference: e.r, tolerance: "0", unit: "VND") }
    // Tệp của hội thoại khác không đọc được.
    let khac = try await e.core.store.createChat().id
    await #expect(throws: PVTAError.self) { _ = try await e.core.accounting.run(chatId: khac, runId: "x", source: e.s, reference: e.r, tolerance: "0", unit: "VND") }
    // Chưa chạy được thì không tạo gì.
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path))
}

@Test func tepMacroLienKetVaQuaLonBiTuChoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let m = e.thuMuc.appendingPathComponent("co-macro.xlsm"); try FileManager.default.copyItem(at: mau.appendingPathComponent("ke-toan-nguon.xlsx"), to: m)
    let a = try await e.core.attachments.add(chatId: e.chat, paths: [m.path])
    _ = a
    let id = try await e.core.attachments.list(chatId: e.chat).first { $0.name == "co-macro.xlsm" }?.id
    if let id { var s = e.s; s.sourceId = id; await #expect(throws: PVTAError.self) { _ = try await e.core.accounting.run(chatId: e.chat, runId: "m", source: s, reference: e.r, tolerance: "0", unit: "VND") } }
    // Tệp nguồn bị thay bằng liên kết tượng trưng sau khi đính kèm → từ chối, không theo liên kết.
    let goc = e.thuMuc.appendingPathComponent("ke-toan-nguon.xlsx")
    try FileManager.default.removeItem(at: goc)
    try FileManager.default.createSymbolicLink(at: goc, withDestinationURL: mau.appendingPathComponent("ke-toan-nguon.xlsx"))
    await #expect(throws: PVTAError.self) { try await e.chay() }
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path))
}

// MARK: Báo cáo

@Test func baoCaoGhiRaJsonVaCsvDocLaiDungBamVaKhongDoiNguon() async throws {
    let e = try await Moi(); defer { e.don() }
    let truoc = [e.thuMuc.appendingPathComponent("ke-toan-nguon.xlsx"), e.thuMuc.appendingPathComponent("ke-toan-doi-chieu.xlsx")].map { try? Data(contentsOf: $0) }
    let r = try await e.chay()
    #expect(r.exports.map(\.format) == ["json", "csv"] && r.exports.allSatisfy { $0.path.hasPrefix(e.thuMucKetQua.path + "/run-") && $0.bytes > 0 })
    for x in r.exports {
        let d = try Data(contentsOf: URL(fileURLWithPath: x.path))
        #expect(d.count == x.bytes)
    }
    let json = try JSONDecoder().decode(ReconcileReport.self, from: Data(contentsOf: URL(fileURLWithPath: r.exports[0].path)))
    #expect(json.rows == r.rows && json.exports.isEmpty)
    let csv = try String(contentsOfFile: r.exports[1].path, encoding: .utf8)
    #expect(csv.hasPrefix("key,kind,sourceLocation") && csv.contains("\"TK002\",\"value_mismatch\""))
    // Nguồn không đổi một byte.
    let sau = [e.thuMuc.appendingPathComponent("ke-toan-nguon.xlsx"), e.thuMuc.appendingPathComponent("ke-toan-doi-chieu.xlsx")].map { try? Data(contentsOf: $0) }
    #expect(truoc == sau)
    // Mỗi lần chạy có thư mục riêng, không ghi đè.
    let r2 = try await e.chay()
    #expect(Set(r.exports.map { ($0.path as NSString).deletingLastPathComponent }).isDisjoint(with: Set(r2.exports.map { ($0.path as NSString).deletingLastPathComponent })))
}

@Test func csvChanCongThucBangTinh() {
    var r = ReconcileReport(version: "1", createdAt: "", unit: "VND", tolerance: "0", sourceEdits: false, formulas: "", sources: [], rows: [], summary: .init(sourceRows: 0, referenceRows: 0, matched: 0, issues: 0), exports: [])
    r.rows = [ReconcileRow(key: "=HYPERLINK(\"x\")", kind: "matched", sourceLocation: nil, referenceLocation: nil, sourceValue: "+1", referenceValue: "-2", delta: "@x", tolerance: "0", evidence: "a\"b")]
    let c = Reconciler.csv(r)
    #expect(c.contains("\"'=HYPERLINK(\"\"x\"\")\"") && c.contains("\"'+1\"") && c.contains("\"'-2\"") && c.contains("\"'@x\"") && c.contains("\"a\"\"b\""))
}

@Test func soThapPhanChatCheVaVietDayDu() {
    #expect(Reconciler.number("0.1") != nil && Reconciler.number("-12.50") != nil && Reconciler.number("1e3") != nil && Reconciler.number("0") != nil)
    for xau in ["01", "1,000", "1 000", "$5", "NaN", "Infinity", "1e999", "", "1.", ".5", "--1", String(repeating: "1", count: 40)] { #expect(Reconciler.number(xau) == nil, "\(xau)") }
    #expect(Reconciler.plain(Reconciler.number("0.1")! - Reconciler.number("0.2")!) == "-0.1")
    #expect(Reconciler.plain(Reconciler.number("1e3")!) == "1000" && Reconciler.plain(Reconciler.number("1.5e-5")!) == "0.000015")
    #expect(Reconciler.plain(Reconciler.number("12345678901234567890.123456789")! + Reconciler.number("0.000000001")!) == "12345678901234567890.12345679")   // Decimal 38 chữ số
}

// MARK: Hủy

@Test func huyTacVuDangChayKhongGhiGiVaChayLaiDuoc() async throws {
    let cong = Gate()
    let e = try await Moi(gate: cong); defer { e.don() }
    let core = e.core, chat = e.chat, s = e.s, r = e.r
    let t = Task { try await core.accounting.run(chatId: chat, runId: "chay-1", source: s, reference: r, tolerance: "0", unit: "VND") }
    for _ in 0..<250 { if await core.accounting.running() == 1 { break }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(await core.accounting.running() == 1)
    // Chạy trùng mã đang chạy bị từ chối; hủy đúng cặp hội thoại/lần chạy.
    await #expect(throws: PVTAError.self) { _ = try await core.accounting.run(chatId: chat, runId: "chay-1", source: s, reference: r, tolerance: "0", unit: "VND") }
    let sai = await core.accounting.cancel(chatId: chat, runId: "khac")
    let saiChat = await core.accounting.cancel(chatId: "chat-khac", runId: "chay-1")
    #expect(!sai && !saiChat)
    let huy = await core.accounting.cancel(chatId: chat, runId: "chay-1")
    #expect(huy)
    await cong.open()
    do { _ = try await t.value; Issue.record("phải báo đã hủy") } catch let x as PVTAError { #expect(x.message.contains("hủy")) }
    #expect(await core.accounting.running() == 0)
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path) || ((try? FileManager.default.contentsOfDirectory(atPath: e.thuMucKetQua.path)) ?? []).isEmpty)   // không để lại báo cáo dở
    // Sau khi hủy vẫn chạy lại bình thường (cổng đã mở).
    let ok = try await e.chay()
    #expect(ok.exports.count == 2)
    let nua = await core.accounting.cancel(chatId: chat, runId: "chay-1")
    #expect(!nua)
}

@Test func nguonDoiTrongLucDoiSoatThiHuyKhongXuat() async throws {
    let cong = Gate()
    let e = try await Moi(gate: cong); defer { e.don() }
    let core = e.core, chat = e.chat, s = e.s, r = e.r
    let t = Task { try await core.accounting.run(chatId: chat, runId: "doi", source: s, reference: r, tolerance: "0", unit: "VND") }
    for _ in 0..<250 { if await core.accounting.running() == 1 { break }; try await Task.sleep(for: .milliseconds(20)) }
    // Đổi nội dung tệp nguồn khi đang chạy.
    var d = try Data(contentsOf: e.thuMuc.appendingPathComponent("ke-toan-nguon.xlsx")); d.append(0)
    try d.write(to: e.thuMuc.appendingPathComponent("ke-toan-nguon.xlsx"))
    await cong.open()
    await #expect(throws: PVTAError.self) { _ = try await t.value }
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path) || ((try? FileManager.default.contentsOfDirectory(atPath: e.thuMucKetQua.path)) ?? []).isEmpty)
}

// MARK: Duyệt trước khi ghi

private func choDeXuat(_ core: Core) async throws -> ActionProposal {
    for _ in 0..<250 { if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }; try await Task.sleep(for: .milliseconds(20)) }
    throw PVTAError("không có đề xuất")
}

@Test func congCuDoiSoatPhaiDuocDuyetKhongGhiKhiChuaDuyet() async throws {
    let e = try await Moi(); defer { e.don() }
    let tool = try #require(e.core.tools.spec("accounting_reconcile"))
    #expect(tool.access == .write)
    let policy = PermissionPolicy(e.core.permissions)
    func tham(_ s: ReconcileSide, _ r: ReconcileSide) -> JSONValue {
        func j(_ x: ReconcileSide) -> JSONValue { ["sourceId": .string(x.sourceId), "sheet": .string(x.sheet), "range": .string(x.range), "keyColumn": .string(x.keyColumn), "valueColumn": .string(x.valueColumn)] }
        return ["source": j(s), "reference": j(r), "tolerance": "0.01", "unit": "VND", "chatId": .string(e.chat)]
    }
    let args = tham(e.s, e.r)
    // Từ chối → không tạo gì.
    let t1 = Task { await policy.decide(tool, args: args, chatId: e.chat) }
    let p = try await choDeXuat(e.core)
    #expect(p.tool == "accounting_reconcile" && p.summary.contains("đối soát") && p.preview.contains("Chỉ đọc hai tệp nguồn") && p.preview.contains("0.01"))
    _ = try await e.core.dispatch("action.decline", ["id": .string(p.id)], scoped: { _, _ in })
    if case .deny = await t1.value {} else { Issue.record("từ chối thì phải chặn") }
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path))
    // Mức Chỉ đọc chặn ngay, không hỏi.
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    if case .deny = await policy.decide(tool, args: args, chatId: e.chat) {} else { Issue.record("Chỉ đọc phải chặn") }
    _ = try await e.core.permissions.setLevel(.askApproval, acknowledge: false)
    #expect(!FileManager.default.fileExists(atPath: e.thuMucKetQua.path))
    // Duyệt → chạy và có báo cáo.
    let t2 = Task { await policy.decide(tool, args: args, chatId: e.chat) }
    _ = try await e.core.dispatch("action.approve", ["id": .string(try await choDeXuat(e.core).id)], scoped: { _, _ in })
    guard case .allow = await t2.value else { Issue.record("duyệt thì phải cho chạy"); return }
    let kq = try await tool.run(args)
    #expect(kq.contains("khớp 2") && kq.contains("TK003: value_mismatch") && kq.contains("reconciliation.json"))
    // Tham số lạ bị từ chối ở bước lập kế hoạch.
    var xau = args; if case .object(var o) = xau { o["extra"] = 1; xau = .object(o) }
    _ = xau
    if case .object(var o) = args, case .object(var so)? = o["source"] { so["path"] = "/etc/hosts"; o["source"] = .object(so)
        if case .deny = await policy.decide(tool, args: .object(o), chatId: e.chat) {} else { Issue.record("tham số lạ phải bị chặn") } }
}

@Test func cacLenhQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    func goi(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    func j(_ x: ReconcileSide) -> JSONValue { ["sourceId": .string(x.sourceId), "sheet": .string(x.sheet), "range": .string(x.range), "keyColumn": .string(x.keyColumn), "valueColumn": .string(x.valueColumn)] }
    let kq = try await goi("accounting.run", ["chatId": .string(e.chat), "runId": "rpc-1", "source": j(e.s), "reference": j(e.r), "tolerance": "0", "unit": "VND"])
    #expect(kq["summary"]?["matched"]?.number == 1 && kq["sourceEdits"]?.bool == false)
    #expect(try await goi("accounting.cancel", ["chatId": .string(e.chat), "runId": "rpc-1"]).bool == false)         // đã xong
    await #expect(throws: PVTAError.self) { _ = try await goi("accounting.run", ["chatId": .string(e.chat), "runId": "x", "source": j(e.s), "reference": j(e.r), "tolerance": "0", "unit": "VND", "outputPath": "/tmp/x"]) .self ?? .null }
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { _ = try await goi("accounting.run", ["chatId": .string(e.chat), "runId": "ro", "source": j(e.s), "reference": j(e.r), "tolerance": "0", "unit": "VND"]) }
}
