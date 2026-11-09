import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let M = "anthropic/claude-haiku-5-5"

private func tam() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class DaChay: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func them(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var ds: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func khoi(_ tool: String, _ args: JSONValue) -> String {
    let a = String(decoding: (try? JSONEncoder().encode(args)) ?? Data(), as: UTF8.self)
    return "```pvta-tool\n{\"tool\":\"\(tool)\",\"args\":\(a)}\n```\n"
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = tam()                 // thư mục cá nhân giả
    let lamViec = tam()             // thư mục sẽ được cấp
    let ngoai = tam()               // thư mục không được cấp
    let mang: FakeTransport
    let core: Core
    let chay = DaChay()

    init(_ replies: [FakeTransport.Reply] = [], timeout: Duration = .seconds(300)) async throws {
        mang = FakeTransport(replies)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: nha, approvalTimeout: timeout)
        let log = chay
        core.tools.register(ToolSpec(name: "ghi_tep", summary: "Ghi một tệp.", parameters: #"{"path","content"}"#, access: .write,
            plan: { a in ActionPlan(kind: .write, summary: "Ghi tệp \(a["path"]?.string ?? "?")", preview: a["content"]?.string ?? "", paths: [a["path"]?.string ?? ""]) },
            run: { a in
                try (a["content"]?.string ?? "").write(toFile: a["path"]?.string ?? "", atomically: true, encoding: .utf8)
                log.them("ghi " + (a["path"]?.string ?? ""))
                return "đã ghi"
            }))
        core.tools.register(ToolSpec(name: "xoa_tep", summary: "Xóa tệp.", access: .write,
            plan: { a in
                guard case .array(let ps)? = a["paths"] else { throw PVTAError("thiếu paths") }
                return ActionPlan(kind: .delete, summary: "Xóa \(ps.count) mục", paths: ps.compactMap(\.string))
            },
            run: { a in
                if case .array(let ps)? = a["paths"] { for p in ps.compactMap(\.string) { try FileManager.default.removeItem(atPath: p) } }
                log.them("xoa")
                return "đã xóa"
            }))
        core.tools.register(ToolSpec(name: "chay_lenh", summary: "Chạy lệnh.", access: .run,
            plan: { a in ActionPlan(kind: .run, summary: "Chạy lệnh: \(a["cmd"]?.string ?? "")", preview: a["cmd"]?.string ?? "") },
            run: { _ in log.them("lenh"); return "đã chạy" }))
        core.tools.register(ToolSpec(name: "goi_mang", summary: "Gửi dữ liệu ra ngoài.", access: .network, run: { _ in log.them("mang"); return "đã gửi" }))
        core.tools.register(ToolSpec(name: "ghi_mu", summary: "Ghi nhưng không nói rõ tác động.", access: .write, run: { _ in log.them("mu"); return "đã ghi mù" }))
        core.tools.register(ToolSpec(name: "doc_tep", summary: "Đọc.", access: .read, run: { _ in log.them("doc"); return "nội dung" }))
    }

    func don() { for u in [paths.home, nha, lamViec, ngoai] { try? FileManager.default.removeItem(at: u) } }
    func chat() async throws -> Chat { try await core.store.createChat() }
    func dat(_ l: PermissionLevel) async throws { _ = try await core.permissions.setLevel(l, acknowledge: true) }
    func gui(_ id: String, _ text: String = "làm đi") -> Task<ChatTurnResult, Error> {
        Task { try await core.chat.send(chatId: id, text: text, model: M, emit: { _, _ in }) }
    }
    func ketQuaCongCu() -> String {
        guard let b = try? JSONDecoder().decode(JSONValue.self, from: mang.requests.last?.httpBody ?? Data()), case .array(let ms)? = b["messages"] else { return "" }
        return ms.last?["content"]?.string ?? ""
    }
    func choDeXuat(_ n: Int = 1) async -> [ActionProposal] {
        for _ in 0..<250 {
            let p = await core.permissions.queue.list().filter { $0.state == .pending }
            if p.count >= n { return p }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return []
    }
}

private func goi(_ tool: String, _ args: JSONValue) -> [String] { claudeSSE([khoi(tool, args)]) }
private let xong = claudeSSE(["Xong"])

// MARK: Ba mức quyền

@Test func macDinhLaHoiDuyetVaChiNguoiDungDoiDuocMucQuyen() async throws {
    let e = try await Moi(); defer { e.don() }
    #expect(e.core.permissions.level() == .askApproval)
    let v = try await e.core.permissions.view()
    #expect(v.level == .askApproval && v.label == "Hỏi duyệt" && v.description.contains("chờ bạn duyệt"))
    // Tự sửa phải được xác nhận, và thông báo nói rõ không phải môi trường cô lập.
    do { _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: false); Issue.record("phải đòi xác nhận") } catch let err as PVTAError {
        #expect(err.message.contains("KHÔNG phải môi trường cô lập") && err.message.contains("xác nhận"))
    }
    #expect(e.core.permissions.level() == .askApproval)
    let ok = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    #expect(ok.level == .autoEdit && ok.description.contains("KHÔNG phải môi trường cô lập"))
    #expect(try String(contentsOf: e.paths.config, encoding: .utf8).contains("tu-sua"))     // lưu lại cho lần mở sau
    #expect(try await e.core.permissions.setLevel(.readOnly, acknowledge: false).level == .readOnly)   // hạ quyền không cần xác nhận
    #expect(PermissionLevel.readOnly.summary.contains("Chỉ đọc") && PermissionLevel.askApproval.summary.contains("mặc định"))

    // Cờ việc gấp đổi số bước song song nhưng không đụng tới mức quyền.
    _ = try await e.core.urgency.set(true)
    #expect(e.core.permissions.level() == .readOnly)
}

@Test func chiDocKhongChayBatKyThaoTacGhiNao() async throws {
    let dich = tam(); defer { try? FileManager.default.removeItem(at: dich) }
    let e = try await Moi([
        .init(lines: claudeSSE([khoi("doc_tep", [:]) + khoi("ghi_tep", ["path": .string(dich.appendingPathComponent("a.txt").path), "content": "x"]) + khoi("chay_lenh", ["cmd": "ls"]) + khoi("goi_mang", [:])])),
        .init(lines: xong),
    ]); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: dich.path, write: true)
    try await e.dat(.readOnly)
    let c = try await e.chat()
    _ = try await e.gui(c.id).value
    #expect(e.chay.ds == ["doc"])                                                   // chỉ công cụ đọc chạy
    #expect(!FileManager.default.fileExists(atPath: dich.appendingPathComponent("a.txt").path))
    #expect(e.ketQuaCongCu().components(separatedBy: "Chế độ Chỉ đọc").count == 4)  // ba thao tác bị từ chối rõ ràng
    #expect(await e.core.permissions.queue.list().isEmpty)                          // không có gì để duyệt
}

@Test func hoiDuyetKhongCoThaoTacGhiNaoChayKhiChuaDuyetRoiDuyetThiChay() async throws {
    let dich = tam(); defer { try? FileManager.default.removeItem(at: dich) }
    let tep = dich.appendingPathComponent("giao-an.txt")
    let e = try await Moi([.init(lines: goi("ghi_tep", ["path": .string(tep.path), "content": "Nội dung giáo án"])), .init(lines: xong)]); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: dich.path, write: true)
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let ds = await e.choDeXuat()
    #expect(ds.count == 1)
    let p = try #require(ds.first)
    #expect(p.tool == "ghi_tep" && p.kind == .write && p.risk == "normal" && p.chatId == c.id)
    #expect(p.preview == "Nội dung giáo án" && p.summary.contains("giao-an.txt"))     // thấy nội dung và phạm vi tác động
    #expect(p.paths == [tep.path])
    try await Task.sleep(for: .milliseconds(300))
    #expect(e.chay.ds.isEmpty && !FileManager.default.fileExists(atPath: tep.path))   // chưa duyệt thì chưa ghi gì
    try await e.core.permissions.queue.approve(id: p.id)
    _ = try await luot.value
    let daGhi = try String(contentsOf: tep, encoding: .utf8)
    #expect(e.chay.ds.count == 1 && daGhi == "Nội dung giáo án")
    #expect(e.ketQuaCongCu().contains("đã ghi"))
    let sau = await e.core.permissions.queue.list()
    #expect(sau.first?.state == .approved && sau.first?.decidedAt != nil)
    let nhatKy = try await e.core.store.activities().first { $0.kind == "action.write" }
    #expect(nhatKy?.state == .done && nhatKy?.detail?.contains("Đã duyệt") == true)
}

@Test func tuChoiHetGioVaDungLuotDeuKhongGhiGi() async throws {
    let dich = tam(); defer { try? FileManager.default.removeItem(at: dich) }
    let tep = dich.appendingPathComponent("a.txt")
    let args: JSONValue = ["path": .string(tep.path), "content": "x"]
    let e = try await Moi([.init(lines: goi("ghi_tep", args)), .init(lines: xong), .init(lines: goi("ghi_tep", args)), .init(lines: xong)], timeout: .milliseconds(600)); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: dich.path, write: true)
    let c = try await e.chat()

    // Từ chối.
    let l1 = e.gui(c.id)
    let p1 = try #require(await e.choDeXuat().first)
    try await e.core.permissions.queue.decline(id: p1.id)
    _ = try await l1.value
    #expect(e.ketQuaCongCu().contains("Người dùng đã từ chối"))
    // Hết giờ.
    let l2 = e.gui(c.id)
    _ = try await l2.value
    #expect(e.ketQuaCongCu().contains("Hết thời gian chờ"))
    let ds = await e.core.permissions.queue.list()
    #expect(ds.map(\.state) == [.declined, .expired])
    // Bấm Dừng khi đang chờ duyệt.
    let lai = try await Moi([.init(lines: goi("ghi_tep", args))]); defer { lai.don() }
    _ = try await lai.core.permissions.addGrant(path: dich.path, write: true)
    let c3 = try await lai.chat()
    let l3 = lai.gui(c3.id)
    #expect(await lai.choDeXuat().count == 1)
    _ = await lai.core.chat.cancel(chatId: c3.id)
    do { _ = try await l3.value } catch {}
    #expect(await lai.core.permissions.queue.list().first?.state == .expired)
    #expect(e.chay.ds.isEmpty && lai.chay.ds.isEmpty && !FileManager.default.fileExists(atPath: tep.path))
}

@Test func tuSuaGhiTrongThuMucDuocCapNhungKhongGhiNgoaiPhamVi() async throws {
    let doc = tam(); defer { try? FileManager.default.removeItem(at: doc) }
    let e = try await Moi([
        .init(lines: claudeSSE([khoi("ghi_tep", ["path": .string(e0(doc, "ghi-duoc.txt")), "content": "ok"])])), .init(lines: xong),
    ]); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: e.lamViec.path, write: true)
    _ = try await e.core.permissions.addGrant(path: doc.path, write: false)            // chỉ đọc
    try await e.dat(.autoEdit)
    let c = try await e.chat()
    // Thư mục chỉ cấp quyền đọc: bị chặn hẳn (không hiện ra để duyệt).
    _ = try await e.gui(c.id).value
    #expect(e.chay.ds.isEmpty && e.ketQuaCongCu().contains("mới được cấp quyền đọc"))
    #expect(await e.core.permissions.queue.list().isEmpty)
}

private func e0(_ dir: URL, _ name: String) -> String { dir.appendingPathComponent(name).path }

@Test func tuSuaChayThangTrongPhamViCapGhiVaVanHoiViecKhac() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: e.lamViec.path, write: true)
    try await e.dat(.autoEdit)
    let ghi = e.lamViec.appendingPathComponent("tu-ghi.txt")
    let tonTai = e.lamViec.appendingPathComponent("xoa-1.txt"); try Data("x".utf8).write(to: tonTai)
    // Ghi, xóa 1 tệp: tự chạy không hỏi.
    let mang1 = FakeTransport([.init(lines: goi("ghi_tep", ["path": .string(ghi.path), "content": "tự ghi"])), .init(lines: goi("xoa_tep", ["paths": [.string(tonTai.path)]])), .init(lines: xong)])
    let ai = AIClient(config: ConfigStore(paths: e.paths), keys: { let k = MemoryKeyStore(); try? k.save("k", provider: "anthropic"); return k }(), transport: mang1, retry: .none, cli: Gia().moi())
    let core2 = Core(store: e.core.store, ai: ai, screenHome: e.nha)
    for t in e.core.tools.all { core2.tools.register(t) }
    let c = try await e.chat()
    _ = try await core2.chat.send(chatId: c.id, text: "làm đi", model: M, emit: { _, _ in })
    #expect(e.chay.ds == ["ghi " + ghi.path, "xoa"] && !FileManager.default.fileExists(atPath: tonTai.path))
    #expect(await core2.permissions.queue.list().isEmpty)
}

@Test func tuSuaVanPhaiHoiKhiChayLenhMangVaThaoTacKhongRoTacDong() async throws {
    let e = try await Moi([.init(lines: claudeSSE([khoi("chay_lenh", ["cmd": "rm -rf ~"]) + khoi("goi_mang", [:]) + khoi("ghi_mu", [:])])), .init(lines: xong)], timeout: .milliseconds(500)); defer { e.don() }
    try await e.dat(.autoEdit)
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let ds = await e.choDeXuat(1)
    #expect(ds.first?.kind == .run && ds.first?.preview == "rm -rf ~")
    _ = try await luot.value                                                     // hết giờ cả ba
    let kinds = Set(await e.core.permissions.queue.list().map(\.kind))
    #expect(kinds == [.run, .network, .write])                                  // đều phải hỏi, không cái nào tự chạy
    #expect(e.chay.ds.isEmpty)
}

@Test func xoaHangLoatLaNguyHiemPhaiXacNhanThem() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: e.lamViec.path, write: true)
    var ps: [JSONValue] = []
    for i in 0..<6 { let u = e.lamViec.appendingPathComponent("t\(i).txt"); try Data("x".utf8).write(to: u); ps.append(.string(u.path)) }
    let thuMucCon = e.lamViec.appendingPathComponent("con"); try FileManager.default.createDirectory(at: thuMucCon, withIntermediateDirectories: true)
    let mang = FakeTransport([.init(lines: goi("xoa_tep", ["paths": .array(ps)])), .init(lines: xong), .init(lines: goi("xoa_tep", ["paths": [.string(thuMucCon.path)]])), .init(lines: xong)])
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let core = Core(store: e.core.store, ai: AIClient(config: ConfigStore(paths: e.paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi()), screenHome: e.nha)
    for t in e.core.tools.all { core.tools.register(t) }
    _ = try await core.permissions.addGrant(path: e.lamViec.path, write: true)
    try ConfigStore(paths: e.paths).update { $0.permission = .autoEdit }              // ngay cả Tự sửa
    let c = try await e.chat()
    let t1 = Task { try await core.chat.send(chatId: c.id, text: "xóa hết", model: M, emit: { _, _ in }) }
    var p: ActionProposal?
    for _ in 0..<250 where p == nil { p = await core.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    let nguyHiem = try #require(p)
    #expect(nguyHiem.risk == "high" && nguyHiem.riskReasons.joined().contains("6 mục"))
    await #expect(throws: PVTAError.self) { try await core.permissions.queue.approve(id: nguyHiem.id) }       // chưa đủ: cần “Vẫn làm”
    #expect(e.chay.ds.isEmpty)
    try await core.permissions.queue.approve(id: nguyHiem.id, force: true)
    _ = try await t1.value
    #expect(e.chay.ds == ["xoa"] && ps.allSatisfy { !FileManager.default.fileExists(atPath: $0.string ?? "") })

    // Xóa cả thư mục cũng là nguy hiểm.
    let t2 = Task { try await core.chat.send(chatId: c.id, text: "xóa thư mục", model: M, emit: { _, _ in }) }
    var q: ActionProposal?
    for _ in 0..<250 where q == nil { q = await core.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(q?.riskReasons.contains("xóa cả thư mục") == true)
    try await core.permissions.queue.decline(id: try #require(q).id)
    _ = try await t2.value
    #expect(FileManager.default.fileExists(atPath: thuMucCon.path))
}

// MARK: Phạm vi thư mục và liên kết tượng trưng

@Test func ghiNgoaiThuMucDuocCapBiChanKeCaQuaLienKetTuongTrung() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: e.lamViec.path, write: true)
    let fm = FileManager.default
    let mat = e.ngoai.appendingPathComponent("bi-mat.txt"); try Data("bí mật".utf8).write(to: mat)
    try fm.createSymbolicLink(at: e.lamViec.appendingPathComponent("lk-tep.txt"), withDestinationURL: mat)          // liên kết tới tệp ngoài
    try fm.createSymbolicLink(at: e.lamViec.appendingPathComponent("lk-thu-muc"), withDestinationURL: e.ngoai)      // liên kết tới thư mục ngoài
    try fm.createDirectory(at: e.lamViec.appendingPathComponent("that"), withIntermediateDirectories: true)
    try Data("ok".utf8).write(to: e.lamViec.appendingPathComponent("that/a.txt"))
    let lam = e.lamViec.path

    func kiem(_ p: String, ghi: Bool) async -> String? { await e.core.permissions.check(p, ghi ? .write : .read).denied }
    for ghi in [false, true] {
        #expect(await kiem(lam + "/that/a.txt", ghi: ghi) == nil)                       // trong phạm vi
        #expect(await kiem(lam + "/moi/tep-moi.txt", ghi: ghi) == nil)                  // tệp mới, thư mục chưa có
        #expect(await kiem(lam + "/lk-tep.txt", ghi: ghi)?.contains("ngoài các thư mục") == true)       // liên kết tới tệp ngoài
        #expect(await kiem(lam + "/lk-thu-muc/bi-mat.txt", ghi: ghi) != nil)            // đi qua liên kết thư mục
        #expect(await kiem(lam + "/lk-thu-muc/moi.txt", ghi: ghi) != nil)               // tệp mới dưới liên kết thư mục
        #expect(await kiem(lam + "/that/../../" + e.ngoai.lastPathComponent + "/x.txt", ghi: ghi)?.contains("“..”") == true)
        #expect(await kiem(mat.path, ghi: ghi) != nil)                                  // đường dẫn ngoài trực tiếp
        #expect(await kiem("that/a.txt", ghi: ghi)?.contains("tuyệt đối") == true)      // tương đối
        #expect(await kiem("/etc/hosts", ghi: ghi) != nil)
    }
    // authorize dùng cho công cụ tệp: trả đường dẫn chuẩn hoặc báo lỗi tiếng Việt.
    #expect(try await e.core.permissions.authorize(path: lam + "/that/a.txt", write: true).hasSuffix("/that/a.txt"))
    await #expect(throws: PVTAError.self) { _ = try await e.core.permissions.authorize(path: lam + "/lk-tep.txt", write: true) }

    // Quyền đọc không kéo theo quyền ghi.
    let doc = tam(); defer { try? fm.removeItem(at: doc) }
    _ = try await e.core.permissions.addGrant(path: doc.path, write: false)
    #expect(await kiem(doc.path + "/a.txt", ghi: false) == nil)
    #expect(await kiem(doc.path + "/a.txt", ghi: true)?.contains("chưa cấp quyền ghi") == true)
    // Gỡ cấp quyền thì có hiệu lực ngay.
    try await e.core.permissions.removeGrant(path: doc.path)
    #expect(await kiem(doc.path + "/a.txt", ghi: false) != nil)
    await #expect(throws: PVTAError.self) { try await e.core.permissions.removeGrant(path: doc.path) }
}

@Test func vungBaoVeVaThuMucKhongTheCap() async throws {
    let e = try await Moi(); defer { e.don() }
    let fm = FileManager.default
    let ssh = e.nha.appendingPathComponent(".ssh"); try fm.createDirectory(at: ssh, withIntermediateDirectories: true)
    try Data("khóa".utf8).write(to: ssh.appendingPathComponent("id_rsa"))
    let pvta = e.nha.appendingPathComponent("Library/Application Support/PVTA"); try fm.createDirectory(at: pvta, withIntermediateDirectories: true)
    let tapTin = tam(); defer { try? fm.removeItem(at: tapTin) }
    try Data("x".utf8).write(to: tapTin.appendingPathComponent("tep.txt"))
    let lk = tam().appendingPathComponent("lk"); try fm.createSymbolicLink(at: lk, withDestinationURL: e.lamViec)

    for sai in ["/", "/Users", e.nha.path, "/System", "/etc", ssh.path, pvta.path, e.paths.home.path, e.nha.path + "/Library",
                tapTin.appendingPathComponent("tep.txt").path, lk.path, "tuong-doi", e.ngoai.appendingPathComponent("khong-co").path] {
        await #expect(throws: PVTAError.self, "\(sai)") { _ = try await e.core.permissions.addGrant(path: sai, write: true) }
    }
    // Thư mục chứa vùng bảo vệ bên trong thì cấp được, nhưng vùng bảo vệ vẫn bị chặn.
    let trongNha = e.nha.appendingPathComponent("GiaoAn"); try fm.createDirectory(at: trongNha, withIntermediateDirectories: true)
    _ = try await e.core.permissions.addGrant(path: trongNha.path, write: true)
    #expect(await e.core.permissions.check(ssh.appendingPathComponent("id_rsa").path, .read).denied != nil)
    // Dữ liệu PVTA không bao giờ đọc/ghi được, kể cả khi cố cấp thư mục nằm trong nó hoặc chứa nó.
    await #expect(throws: PVTAError.self) { _ = try await e.core.permissions.addGrant(path: e.paths.home.deletingLastPathComponent().path, write: false) }

    // Thư mục đã cấp bị thay bằng liên kết tượng trưng thì mất hiệu lực.
    let tmp = tam(); defer { try? fm.removeItem(at: tmp) }
    let goc = tmp.appendingPathComponent("duoc-cap"); try fm.createDirectory(at: goc, withIntermediateDirectories: true)
    _ = try await e.core.permissions.addGrant(path: goc.path, write: true)
    #expect(await e.core.permissions.check(goc.path + "/a.txt", .write).denied == nil)
    try fm.removeItem(at: goc)
    try fm.createSymbolicLink(at: goc, withDestinationURL: e.ngoai)
    #expect(await e.core.permissions.check(goc.path + "/a.txt", .write).denied != nil)
}

@Test func duyetXongNhungThuMucDoiThanhLienKetTrongLucChoThiBiChanLai() async throws {
    let e = try await Moi(); defer { e.don() }
    let fm = FileManager.default
    let con = e.lamViec.appendingPathComponent("con"); try fm.createDirectory(at: con, withIntermediateDirectories: true)
    let tep = con.appendingPathComponent("a.txt")
    let mang = FakeTransport([.init(lines: goi("ghi_tep", ["path": .string(tep.path), "content": "x"])), .init(lines: xong)])
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let core = Core(store: e.core.store, ai: AIClient(config: ConfigStore(paths: e.paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi()), screenHome: e.nha)
    for t in e.core.tools.all { core.tools.register(t) }
    _ = try await core.permissions.addGrant(path: e.lamViec.path, write: true)
    let c = try await e.chat()
    let luot = Task { try await core.chat.send(chatId: c.id, text: "ghi", model: M, emit: { _, _ in }) }
    var p: ActionProposal?
    for _ in 0..<250 where p == nil { p = await core.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    // Trong lúc chờ duyệt, thư mục con bị thay bằng liên kết trỏ ra ngoài.
    try fm.removeItem(at: con)
    try fm.createSymbolicLink(at: con, withDestinationURL: e.ngoai)
    try await core.permissions.queue.approve(id: try #require(p).id)
    _ = try await luot.value
    #expect(e.chay.ds.isEmpty)
    #expect(!fm.fileExists(atPath: e.ngoai.appendingPathComponent("a.txt").path))
    let guiLai = try String(decoding: JSONEncoder().encode(JSONValue.string(e.ketQuaCongCuOf(mang))), as: UTF8.self)
    #expect(guiLai.contains("kiểm lại"))
}

private extension Moi {
    func ketQuaCongCuOf(_ m: FakeTransport) -> String {
        guard let b = try? JSONDecoder().decode(JSONValue.self, from: m.requests.last?.httpBody ?? Data()), case .array(let ms)? = b["messages"] else { return "" }
        return ms.last?["content"]?.string ?? ""
    }
}

// MARK: Hàng đợi và giao diện gọi chung

@Test func hangDoiCheNoiDungNhayCamVaGiuLichSuCoGioiHan() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: e.lamViec.path, write: true)
    let q = e.core.permissions.queue
    let policy = PermissionPolicy(e.core.permissions)
    let ghi = try #require(e.core.tools.spec("ghi_tep"))
    let tep = e.lamViec.appendingPathComponent("n.txt").path
    let t = Task { await policy.decide(ghi, args: ["path": .string(tep), "content": "token=sk-ant-BI-MAT-12345678 và nội dung"], chatId: "c1") }
    let p = try #require(await e.choDeXuat().first)
    #expect(!p.preview.contains("BI-MAT") && p.preview.contains("[đã ẩn]") && p.preview.contains("nội dung"))
    await #expect(throws: PVTAError.self) { try await q.approve(id: "khong-co") }
    try await q.approve(id: p.id)
    #expect(await t.value == .allow)
    await #expect(throws: PVTAError.self) { try await q.approve(id: p.id) }          // duyệt hai lần
    await #expect(throws: PVTAError.self) { try await q.decline(id: p.id) }
    // Lịch sử giữ tối đa 50 mục đã xử lý.
    for i in 0..<60 {
        let tk = Task { await policy.decide(ghi, args: ["path": .string(e.lamViec.appendingPathComponent("l\(i).txt").path), "content": "x"], chatId: "c1") }
        let pend = try #require(await e.choDeXuat().first)
        try await q.decline(id: pend.id)
        _ = await tk.value
    }
    let lichSu = await q.list()
    #expect(lichSu.count == 50 && lichSu.allSatisfy { $0.state != .pending })
}

@Test func goiQuaLoiMucQuyenThuMucVaDuyetGiuaHaiNut() async throws {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: paths.home) }
    let lam = tam(); defer { try? FileManager.default.removeItem(at: lam) }
    let ai = AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore(), transport: FakeTransport([]), retry: .none, cli: Gia().moi())
    let host = try await PVTANode.open(paths: paths, ai: ai)
    let a = try await PVTANode.open(paths: paths), b = try await PVTANode.open(paths: paths)
    let v = try await a.call("permission.get").decode(PermissionView.self)
    #expect(v.level == .askApproval && v.grants.isEmpty)
    await #expect(throws: PVTAError.self) { try await a.call("permission.set", ["level": "tu-sua"]) }
    await #expect(throws: PVTAError.self) { try await a.call("permission.set", ["level": "toan-quyen"]) }
    let g = try await b.call("grant.add", ["path": .string(lam.path), "write": true]).decode(Grant.self)
    let dsCap = try await a.call("grant.list").decode(Array<Grant>.self)
    #expect(g.write && dsCap.map(\.path) == [g.path])
    await #expect(throws: PVTAError.self) { try await a.call("grant.add", ["path": "/"]) }
    #expect(try await b.call("permission.set", ["level": "chi-doc"]).decode(PermissionView.self).level == .readOnly)
    #expect(try await a.call("permission.get").decode(PermissionView.self).level == .readOnly)           // nút khác thấy ngay
    #expect(try await a.call("action.list").decode(Array<ActionProposal>.self).isEmpty)
    await #expect(throws: PVTAError.self) { try await a.call("action.approve", ["id": "khong-co"]) }
    _ = try await a.call("grant.remove", ["path": .string(g.path)])
    #expect(try await b.call("grant.list").decode(Array<Grant>.self).isEmpty)
    await a.shutdown(); await b.shutdown(); await host.shutdown()
}
