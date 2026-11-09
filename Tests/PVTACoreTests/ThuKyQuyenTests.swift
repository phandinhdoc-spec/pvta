import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private func tam() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tq-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("tqh-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = tam(), lam = tam(), ngoai = tam()          // lam: thư mục PVTA được cấp; ngoai: không được cấp
    let mang: FakeTransport
    let core: Core
    var sec: SecretaryService { core.secretary }

    init(_ make: (String) -> [FakeTransport.Reply] = { _ in [] }) async throws {
        mang = FakeTransport(make(PathGuard.canonical(lam.path) ?? lam.path))
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: nha, approvalTimeout: .seconds(5))
        _ = try await core.permissions.addGrant(path: lam.path, write: true)
    }
    func don() { for u in [paths.home, nha, lam, ngoai] { try? FileManager.default.removeItem(at: u) } }
    func tep(_ rel: String, _ nd: String, in dir: URL? = nil) throws -> String {
        let u = (dir ?? lam).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(nd.utf8).write(to: u)
        return PathGuard.canonical(u.path) ?? u.path
    }
    var lamReal: String { PathGuard.canonical(lam.path) ?? lam.path }
    func capDoc(_ rel: String = "") async throws -> String {
        let p = rel.isEmpty ? lamReal : lamReal + "/" + rel
        try await sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(p)])
        return p
    }
    func call(_ m: String, _ p: JSONValue = [:]) async throws -> JSONValue { try await core.dispatch(m, p, scoped: { _, _ in }) }
    func choDeXuat() async throws -> ActionProposal {
        for _ in 0..<250 { if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }; try await Task.sleep(for: .milliseconds(20)) }
        throw PVTAError("không có đề xuất")
    }
}

private func arr(_ v: JSONValue?) -> [JSONValue]? { if case .array(let a)? = v { return a }; return nil }

private func tra(_ s: String) -> FakeTransport.Reply { .init(lines: claudeSSE([s])) }

// MARK: Quyền đọc tệp theo phạm vi

@Test func docTepChiTrongPhamViDuocCapVaThuHoiCoHieuLucNgay() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try e.tep("giao-an/tuan1.md", "# Kế hoạch tuần 1\nDạy chương 2")
    _ = try e.tep("khac/ghi-chu.txt", "ngoài phạm vi")
    // Chưa cấp gì thì không đọc được.
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(a) }
    let g = try await e.sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(e.lamReal + "/giao-an")])
    let r = try await e.sec.readFile(a)
    #expect(r["text"]?.string?.contains("Dạy chương 2") == true && r["revision"]?.string?.count == 64 && r["next"] == .null)
    // Ngoài phạm vi của Thư ký (dù PVTA có quyền ở đó) → từ chối.
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(e.lamReal + "/khac/ghi-chu.txt") }
    // Ngoài mọi thư mục PVTA được cấp → từ chối ngay khi cấp phạm vi.
    let ngoai = try e.tep("x.md", "bí mật", in: e.ngoai)
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(ngoai)]) }
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(ngoai) }
    // Đường dẫn chui qua “..” hoặc liên kết tượng trưng không vượt được phạm vi.
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(e.lamReal + "/giao-an/../khac/ghi-chu.txt") }
    try FileManager.default.createSymbolicLink(atPath: e.lamReal + "/giao-an/lk.txt", withDestinationPath: e.lamReal + "/khac/ghi-chu.txt")
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(e.lamReal + "/giao-an/lk.txt") }
    // Thu hồi có hiệu lực ngay, không cần khởi động lại.
    try await e.sec.editGrant(["op": "remove", "id": .string(g[0].id)])
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(a) }
    // Tắt/bật.
    let g2 = try await e.sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(e.lamReal)])
    _ = try await e.sec.readFile(a)
    try await e.sec.editGrant(["op": "toggle", "id": .string(g2[0].id)])
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(a) }
    // Gỡ quyền thư mục ở mức PVTA cũng chặn luôn phía Thư ký.
    try await e.sec.editGrant(["op": "toggle", "id": .string(g2[0].id)])
    _ = try await e.sec.readFile(a)
    try await e.core.permissions.removeGrant(path: e.lam.path)
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(a) }
}

@Test func docTepChanBiMatTrangVaAnTruongNhayCam() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try e.tep("token.txt", "abc"); _ = try e.tep(".env", "K=1"); _ = try e.tep("khoa.pem", "x"); _ = try e.tep("bai.md", "x")
    let json = try e.tep("cau-hinh.json", #"{"ten":"Lớp 8A","password":"123456","lồng":{"apiKey":"sk-x","ok":1}}"#)
    let jl = try e.tep("log.jsonl", "{\"a\":1,\"token\":\"t\"}\n{\"b\":2}")
    _ = try e.tep("hong.json", "{ không phải json bí mật-123")
    _ = try await e.capDoc()
    for ten in ["token.txt", ".env", "khoa.pem"] { await #expect(throws: PVTAError.self) { try await e.sec.readFile(e.lamReal + "/" + ten) } }
    let ds = try await e.sec.readFile(e.lamReal)
    guard case .array(let ten)? = ds["entries"] else { Issue.record("phải liệt kê"); return }
    let tens = ten.compactMap(\.string)
    #expect(tens.contains("bai.md") && !tens.contains("token.txt") && !tens.contains(".env") && !tens.contains("khoa.pem"))
    let j = try await e.sec.readFile(json), t = j["text"]?.string ?? ""
    #expect(t.contains("Lớp 8A") && !t.contains("123456") && !t.contains("sk-x") && t.contains("đã ẩn"))
    let l = try await e.sec.readFile(jl)
    #expect(l["text"]?.string?.contains("\"t\"") == false)
    do { _ = try await e.sec.readFile(e.lamReal + "/hong.json"); Issue.record("phải báo JSON lỗi") } catch let x as PVTAError { #expect(!x.message.contains("123")) }   // lỗi không lộ nội dung
    // Phân trang ký tự.
    _ = try e.tep("dai.txt", String(repeating: "a", count: 25_000))
    let p1 = try await e.sec.readFile(e.lamReal + "/dai.txt")
    #expect(p1["total"]?.number == 25_000 && p1["next"]?.number == 12_000)
    let p3 = try await e.sec.readFile(e.lamReal + "/dai.txt", start: 24_000)
    #expect(p3["text"]?.string?.count == 1_000 && p3["next"] == .null)
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(e.lamReal + "/dai.txt", start: -1) }
}

@Test func giaiDuongDanBoDauNhayFileUrlVaTenCoDau() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("Giáo án/bài 1.md", "x")
    #expect(try e.sec.resolvePath("\"\(p)\"").path == p)
    let enc = p.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").union(.alphanumerics)) ?? p
    #expect(try e.sec.resolvePath("file://" + enc).path == p)
    #expect(try e.sec.resolvePath(p.replacingOccurrences(of: " ", with: "\\ ")).path == p)
    #expect(try e.sec.resolvePath(p.decomposedStringWithCanonicalMapping).path == p)
    #expect(try e.sec.resolvePath(e.lamReal, expected: "directory").kind == "directory")
    for bad in ["", "tương-đối/x", e.lamReal + "/../x", e.lamReal + "/không-có", "\0"] { #expect(throws: PVTAError.self) { try e.sec.resolvePath(bad) } }
    #expect(throws: PVTAError.self) { try e.sec.resolvePath(p, expected: "directory") }
    #expect(throws: PVTAError.self) { try e.sec.resolvePath(e.lamReal, expected: "file") }
}

// MARK: Quyền mới: diễn giải rồi xác nhận

private func de(_ real: String, mode: String = "auto", extra: String = "") -> String {
    #"{"summary":"Đọc thư mục giáo án và tra cứu bộ phận","grants":[{"kind":"read.folder","description":"đọc giáo án","mode":"auto","scope":"\#(real)"},{"kind":"read.departments","mode":"auto"},{"kind":"write.departments","mode":"\#(mode)"\#(extra)}]}"#
}

@Test func quyenMoiChiCoHieuLucSauXacNhanVaQuyenGhiKhongTuThanhTuLam() async throws {
    let e = try await Moi { [tra(de($0, mode: "auto")), tra(de($0)), tra(de($0))] }; defer { e.don() }
    let tepA = try e.tep("a.md", "nội dung A")
    let mo = "Cho Thư ký đọc thư mục \(e.lamReal), tra cứu và giao việc cho các bộ phận"
    let d = try await e.sec.permissionDraft(mo)
    #expect(d.state == "pending" && d.grants.count == 3 && d.grants[2].mode == "ask")                 // quyền ghi: model đề xuất “auto” vẫn thành “ask”
    // Chưa xác nhận thì chưa có quyền nào.
    #expect(try await e.sec.grants().isEmpty)
    await #expect(throws: PVTAError.self) { try await e.sec.readFile(tepA) }
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list") }
    // Xác nhận → có hiệu lực; quyền ghi luôn hỏi trước.
    let xong = try await e.sec.permissionConfirm(id: d.id, approve: true)
    #expect(xong.state == "approved")
    let ds = try await e.sec.grants()
    #expect(ds.count == 3 && ds.first { $0.kind == "write.departments" }?.mode == "ask")
    _ = try await e.sec.readFile(tepA)
    _ = try await e.sec.departmentCall("projects.list")
    // Xác nhận lần hai không nhân đôi quyền.
    _ = try await e.sec.permissionConfirm(id: d.id, approve: true)
    #expect(try await e.sec.grants().count == 3)
    // Từ chối thì không đổi gì.
    let d2 = try await e.sec.permissionDraft(mo)
    _ = try await e.sec.permissionConfirm(id: d2.id, approve: false)
    let tt = try await e.sec.permissionDrafts().first { $0.id == d2.id }?.state, n3 = try await e.sec.grants().count
    #expect(tt == "declined" && n3 == 3)
    // Đã từ chối thì xác nhận sau không cấp.
    _ = try await e.sec.permissionConfirm(id: d2.id, approve: true)
    #expect(try await e.sec.grants().count == 3)
    // Người dùng cũng không đổi được quyền ghi sang tự làm bằng thao tác mode.
    let ghi = try #require(ds.first { $0.kind == "write.departments" })
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "mode", "id": .string(ghi.id), "value": "auto"]) }
    #expect(try await e.sec.grants().first { $0.id == ghi.id }?.mode == "ask")
}

@Test func deXuatQuyenSaiBiTuChoiVaKhongLuu() async throws {
    let e = try await Moi { r in [
        tra("không phải json"),
        tra(#"{"summary":"x","grants":[{"kind":"read.folder","mode":"auto","scope":"\#(r)"}]}"#),                     // đường dẫn không có trong mô tả
        tra(#"{"summary":"x","grants":[{"kind":"quyen.la","mode":"ask"}]}"#),
        tra(#"{"summary":"x","grants":[{"kind":"read.departments","mode":"auto","scope":"/tmp"}]}"#),                  // phạm vi cho loại không hỗ trợ
        tra(#"{"summary":"x","grants":[{"kind":"read.departments","mode":"auto","operations":["projects.create"]}]}"#), // thao tác ghi trong quyền đọc
        tra(#"{"summary":"x","grants":[{"kind":"read.folder","mode":"auto","scope":"/etc"}]}"#),
        tra(#"{"summary":"x","grants":[]}"#),
    ] }
    defer { e.don() }
    for mo in ["Cho đọc giáo án", "Cho đọc giáo án", "Cấp gì đó", "Tra cứu", "Tra cứu", "Cho đọc /etc", "Không cấp gì"] {
        await #expect(throws: PVTAError.self, "\(mo)") { try await e.sec.permissionDraft(mo) }
    }
    let dr = try await e.sec.permissionDrafts(), gr = try await e.sec.grants()
    #expect(dr.isEmpty && gr.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.sec.permissionDraft("   ") }
    await #expect(throws: PVTAError.self) { try await e.sec.permissionConfirm(id: "khong-co", approve: true) }
    try await e.sec.saveSettings(["enabled": false])
    await #expect(throws: PVTAError.self) { try await e.sec.permissionDraft("Cho đọc giáo án") }
}

@Test func suaQuyenKiemTraGiaTri() async throws {
    let e = try await Moi(); defer { e.don() }
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "la"]) }
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "read.folder"]) }                    // thiếu phạm vi
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "read.departments", "scope": "/tmp"]) }
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "xoa-het"]) }
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "remove", "id": "khong-co"]) }
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "write.departments", "operations": ["projects.list"]]) }  // thao tác đọc trong quyền ghi
    let g = try await e.sec.editGrant(["op": "add", "kind": "write.departments", "operations": ["notebooks.create", "projects.create"]])
    #expect(g[0].operations == ["notebooks.create", "projects.create"] && g[0].mode == "ask")
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "write.departments"]) }               // trùng loại
    let d = try await e.sec.editGrant(["op": "operations", "id": .string(g[0].id), "value": .null])
    #expect(d[0].operations == nil)
    let p = try await e.capDoc()
    let ds = try await e.sec.grants()
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(p)]) }  // trùng phạm vi
    let f = try #require(ds.first { $0.kind == "read.folder" })
    let sub = e.lamReal + "/con"; try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    let moi = try await e.sec.editGrant(["op": "scope", "id": .string(f.id), "value": .string(sub)])
    #expect(moi.first { $0.id == f.id }?.scope == PathGuard.canonical(sub))
    await #expect(throws: PVTAError.self) { try await e.sec.editGrant(["op": "scope", "id": .string(f.id), "value": .string(e.ngoai.path)]) }
}

// MARK: Bộ phận PVTA

@Test func boPhanNgoaiQuyenBiTuChoiVaThuHoiCoHieuLucNgay() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.store.createProject(name: "Dự án STEM")
    _ = try await e.sec.saveTask(["content": "Việc A"])
    // Chưa cấp quyền nào.
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list") }
    let dd0 = try await e.sec.departments()
    #expect(dd0.isEmpty)
    let dep = try await e.sec.editGrant(["op": "add", "kind": "read.departments"])
    let ops = try await e.sec.departments().map(\.id)
    #expect(ops.contains("projects.list") && ops.contains("tasks.list") && !ops.contains("projects.create") && !ops.contains("chats.list"))   // chats: nguồn tắt
    let pl = try await e.sec.departmentCall("projects.list")
    #expect(arr(pl["items"])?.first?["name"]?.string == "Dự án STEM" && pl["next"] == .null && pl["total"]?.number == 1)
    // Nguồn tắt → ngoài quyền dù đã có quyền tra cứu.
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("chats.list") }
    try await e.sec.saveSettings(["sources": ["chats": true]])
    _ = try await e.sec.departmentCall("chats.list")
    // Thao tác ghi không đi qua đường đọc; thao tác lạ, tham số lạ bị từ chối.
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.create", ["name": "x"]) }
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("lenh.la") }
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list", ["start": 0, "ngoai": 1]) }
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list", ["limit": 99]) }
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list", "khong-phai-doi-tuong") }
    // Hội thoại của Thư ký không đọc được qua bộ phận Chat.
    let tk = try await e.sec.thread()
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("chats.read", ["chatId": .string(tk)]) }
    // Giới hạn thao tác trong quyền.
    _ = try await e.sec.editGrant(["op": "operations", "id": .string(dep[0].id), "value": ["tasks.list"]])
    _ = try await e.sec.departmentCall("tasks.list")
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("projects.list") }
    // Thu hồi: có hiệu lực ngay.
    try await e.sec.editGrant(["op": "remove", "id": .string(dep[0].id)])
    await #expect(throws: PVTAError.self) { try await e.sec.departmentCall("tasks.list") }
    #expect(try await e.sec.departments().isEmpty)
}

@Test func giaoViecChoBoPhanPhaiDuocDuyetVaDungPhamVi() async throws {
    let e = try await Moi(); defer { e.don() }
    let tool = try #require(e.core.tools.spec("sec_department_task"))
    let policy = PermissionPolicy(e.core.permissions)
    let thread = try await e.sec.thread()
    let args: JSONValue = ["op": "projects.create", "args": ["name": "Lớp chủ nhiệm 8A"]]
    // Chưa có quyền giao việc → công cụ bị chặn trước khi hỏi duyệt.
    if case .deny = await policy.decide(tool, args: args, chatId: thread) {} else { Issue.record("chưa cấp quyền thì phải chặn") }
    #expect(await e.core.permissions.queue.list().isEmpty)
    _ = try await e.sec.editGrant(["op": "add", "kind": "write.departments", "operations": ["projects.create"]])
    // Từ chối → không tạo.
    let t1 = Task { await policy.decide(tool, args: args, chatId: thread) }
    let p = try await e.choDeXuat()
    #expect(p.tool == "sec_department_task" && p.summary.contains("Dự án") && p.preview.contains("projects.create") && p.preview.contains("Lớp chủ nhiệm 8A"))
    _ = try await e.call("action.decline", ["id": .string(p.id)])
    if case .deny = await t1.value {} else { Issue.record("từ chối thì phải chặn") }
    #expect(try await e.core.store.projects().isEmpty)
    // Duyệt → tạo thật.
    let t2 = Task { await policy.decide(tool, args: args, chatId: thread) }
    _ = try await e.call("secretary.approve", ["id": .string(try await e.choDeXuat().id), "approve": true])
    guard case .allow = await t2.value else { Issue.record("duyệt thì phải cho chạy"); return }
    let kq = try await tool.run(args)
    let dsP = try await e.core.store.projects().map(\.name)
    #expect(kq.contains("Lớp chủ nhiệm 8A") && dsP == ["Lớp chủ nhiệm 8A"])
    // Thao tác nằm ngoài phạm vi quyền đã cấp (chỉ projects.create) → bị chặn dù cùng loại ghi.
    if case .deny = await policy.decide(tool, args: ["op": "notebooks.create", "args": ["name": "Sổ"]], chatId: thread) {} else { Issue.record("ngoài phạm vi phải chặn") }
    await #expect(throws: PVTAError.self) { try await tool.run(["op": "notebooks.create", "args": ["name": "Sổ"]]) }
    // Thao tác đọc không dùng công cụ giao việc; mức Chỉ đọc chặn mọi ghi.
    if case .deny = await policy.decide(tool, args: ["op": "projects.list"], chatId: thread) {} else { Issue.record("thao tác đọc không đi đường ghi") }
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    if case .deny = await policy.decide(tool, args: args, chatId: thread) {} else { Issue.record("Chỉ đọc phải chặn") }
}

@Test func congCuBoPhanVaTepChiCoTrongHoiThoaiThuKy() async throws {
    let e = try await Moi { _ in [tra("ok"), tra("ok")] }; defer { e.don() }
    _ = try await e.sec.ask("Xin chào")
    let chat = try await e.core.store.createChat().id
    _ = try await e.core.chat.send(chatId: chat, text: "Chào", model: "anthropic/claude-haiku-5-5", emit: { _, _ in })
    func he(_ i: Int) -> String {
        let b = (try? JSONDecoder().decode(JSONValue.self, from: e.mang.requests[i].httpBody ?? Data())) ?? .null
        if let t = b["system"]?.string { return t }
        if case .array(let a)? = b["system"] { return a.compactMap { $0["text"]?.string }.joined(separator: "\n") }
        return ""
    }
    let s0 = he(0), s1 = he(1)
    for ten in ["sec_departments", "sec_department_task", "sec_read_file", "sec_permission_request"] { #expect(s0.contains(ten) && !s1.contains(ten), "\(ten)") }
    for ten in ["sec_departments", "sec_department", "sec_department_task", "sec_read_file", "sec_permission_request"] { #expect(e.core.tools.spec(ten) != nil) }
    #expect(e.core.tools.spec("sec_department_task")?.access == ToolAccess.write && e.core.tools.spec("sec_department")?.access == ToolAccess.read)
}

// MARK: Nhập dữ liệu: chuẩn bị rồi xác nhận

private let skillMau = "---\nname: soan-bai-tap\ndescription: Soạn bài tập về nhà theo mức độ\nload: manual\n---\n## Khi nào dùng\nKhi cần soạn bài tập.\n## Quy trình\n1. Xác định mục tiêu.\n"
private let quyTacMau = "# Giọng văn thân thiện\nLuôn xưng thầy/cô và gọi học sinh là các em."

@Test func nhapDuLieuBuocChuanBiKhongGhiXacNhanMoiGhi() async throws {
    let e = try await Moi(); defer { e.don() }
    let s = try e.tep("nhap/SKILL-bai-tap.md", skillMau), r = try e.tep("nhap/RULE-giong-van.md", quyTacMau)
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: [s]) }                                    // chưa cấp quyền đọc
    _ = try await e.capDoc("nhap")
    let pv = try await e.sec.importPrepare(paths: [s, r])
    #expect(pv.items.count == 2 && pv.items[0].kind == "skill" && pv.items[0].name == "soan-bai-tap" && pv.items[1].kind == "rule" && pv.items[1].title == "Giọng văn thân thiện")
    // Chưa xác nhận thì chưa ghi gì.
    let truocSkill = await e.core.skills.store.skill("soan-bai-tap")
    let truocRule = try await e.core.store.rules()
    #expect(truocSkill == nil && truocRule.isEmpty)
    let kq = try await e.sec.importConfirm(token: pv.token)
    #expect(kq.status == "saved" && kq.items.allSatisfy { $0.status == "saved" })
    let sau = await e.core.skills.store.skill("soan-bai-tap"), quy = try await e.core.store.rules()
    #expect(sau != nil && quy.map(\.title) == ["Giọng văn thân thiện"])
    // Mã dùng một lần: xác nhận lại chỉ trả biên nhận cũ, không ghi thêm.
    let lai = try await e.sec.importConfirm(token: pv.token)
    let quy2 = try await e.core.store.rules()
    #expect(lai == kq && quy2.count == 1)
    await #expect(throws: PVTAError.self) { try await e.sec.importConfirm(token: "khong-co") }
    // Tên skill đã có → từ chối ở bước chuẩn bị.
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: [s]) }
}

@Test func nhapDuLieuKiemLaiTruocKhiGhi() async throws {
    let e = try await Moi(); defer { e.don() }
    let r = try e.tep("nhap/RULE-a.md", quyTacMau)
    let g = try await e.sec.editGrant(["op": "add", "kind": "read.folder", "scope": .string(e.lamReal + "/nhap")])
    // Tệp nguồn đổi sau khi xem trước → từ chối.
    var pv = try await e.sec.importPrepare(paths: [r])
    try Data("# Giọng văn thân thiện\nNội dung đã bị đổi.".utf8).write(to: URL(fileURLWithPath: r))
    await #expect(throws: PVTAError.self) { try await e.sec.importConfirm(token: pv.token) }
    await #expect(throws: PVTAError.self) { try await e.sec.importConfirm(token: pv.token) }                               // mã đã bị tiêu
    // Thu hồi quyền đọc giữa hai bước → từ chối.
    pv = try await e.sec.importPrepare(paths: [r])
    try await e.sec.editGrant(["op": "remove", "id": .string(g[0].id)])
    await #expect(throws: PVTAError.self) { try await e.sec.importConfirm(token: pv.token) }
    _ = try await e.capDoc("nhap")
    // Chỉ đọc: không nhập.
    pv = try await e.sec.importPrepare(paths: [r])
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.sec.importConfirm(token: pv.token) }
    _ = try await e.core.permissions.setLevel(.askApproval, acknowledge: false)
    let quy = try await e.core.store.rules()
    #expect(quy.isEmpty)                                                                                                    // suốt các lần trên không ghi gì
}

@Test func nhapDuLieuTuChoiTepNguyHiem() async throws {
    let e = try await Moi(); defer { e.don() }
    try FileManager.default.createDirectory(atPath: e.lamReal + "/nhap", withIntermediateDirectories: true)
    _ = try await e.capDoc("nhap")
    let hong: [(String, String)] = [
        ("nhap/SKILL-khong-khung.md", "không có frontmatter"),
        ("nhap/SKILL-he-thong.md", "---\nname: pvta-gia\ndescription: mạo danh skill hệ thống\nload: manual\n---\n## Quy trình\nx"),
        ("nhap/SKILL-tu-bat.md", "---\nname: tu-bat\ndescription: tự kích hoạt\nload: always\n---\n## Quy trình\nx"),
        ("nhap/SKILL-bi-mat.md", "---\nname: bi-mat\ndescription: có khóa\nload: manual\n---\n## Quy trình\napi_key: sk-abc123"),
        ("nhap/RULE-nhieu.md", "# Một\nnội dung\n# Hai\nnội dung"),
        ("nhap/RULE-rong.md", "# Chỉ tiêu đề\n"),
        ("nhap/ghi-chu.md", "tên tệp sai"),
    ]
    for (rel, nd) in hong {
        let p = try e.tep(rel, nd)
        await #expect(throws: PVTAError.self, "\(rel)") { try await e.sec.importPrepare(paths: [p]) }
    }
    // Liên kết tượng trưng, tệp lớn, không có tệp, quá 20 tệp.
    let that = try e.tep("khac/RULE-that.md", quyTacMau)
    try FileManager.default.createSymbolicLink(atPath: e.lamReal + "/nhap/RULE-lk.md", withDestinationPath: that)
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: [e.lamReal + "/nhap/RULE-lk.md"]) }
    let lon = try e.tep("nhap/RULE-lon.md", "# Lớn\n" + String(repeating: "a", count: 61_000))
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: [lon]) }
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: []) }
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: Array(repeating: that, count: 21)) }
    // Tên đích trùng trong cùng lần nhập.
    let a = try e.tep("nhap/RULE-1.md", "# Trùng tên\nnội dung 1"), b = try e.tep("nhap/RULE-2.md", "# Trùng tên\nnội dung 2")
    await #expect(throws: PVTAError.self) { try await e.sec.importPrepare(paths: [a, b]) }
    // Thiếu load: manual thì thêm và cảnh báo (không tự kích hoạt).
    let tt = try e.tep("nhap/SKILL-thieu-load.md", "---\nname: thieu-load\ndescription: Soạn đề cương ôn tập\n---\n## Khi nào dùng\nKhi ôn tập.\n## Quy trình\n1. Soạn.\n")
    let pv = try await e.sec.importPrepare(paths: [tt])
    #expect(pv.warnings.contains { $0.contains("load: manual") } && pv.items[0].content.contains("load: manual"))
}

// MARK: Cổng gọi

@Test func phuongThucQuyenQuaCongGoi() async throws {
    let e = try await Moi { [tra(de($0))] }; defer { e.don() }
    let tepA = try e.tep("a.md", "xin chào")
    let r = try await e.call("secretary.resolvePath", ["path": .string(tepA), "expected": "file"])
    #expect(r["kind"]?.string == "file")
    await #expect(throws: PVTAError.self) { _ = try await e.call("secretary.readFile", ["path": .string(tepA)]) }
    let d = try await e.call("secretary.permissionDraft", ["description": .string("Cho đọc \(e.lamReal), tra cứu và giao việc")])
    #expect(d["state"]?.string == "pending")
    await #expect(throws: PVTAError.self) { _ = try await e.call("secretary.permissionConfirm", ["id": d["id"] ?? .null]) }    // thiếu approve
    _ = try await e.call("secretary.permissionConfirm", ["id": d["id"] ?? .null, "approve": true])
    #expect(arr(try await e.call("secretary.grants"))?.count == 3)
    #expect(try await e.call("secretary.readFile", ["path": .string(tepA)])["text"]?.string == "xin chào")
    #expect(arr(try await e.call("secretary.departments"))?.isEmpty == false)
    #expect(try await e.call("secretary.department", ["op": "tasks.list"]) != .null)
    #expect(arr(try await e.call("secretary.permissionDrafts"))?.count == 1)
    let gs = try await e.call("secretary.grant", ["op": "toggle", "id": .string(try await e.sec.grants()[1].id)])
    #expect(arr(gs)?.count == 3)
    let pv = try await e.call("secretary.import.prepare", ["paths": [.string(try e.tep("n/RULE-x.md", quyTacMau))]])
    #expect(try await e.call("secretary.import.confirm", ["token": pv["token"] ?? .null])["status"]?.string == "saved")
}

@Test func deXuatNhieuQuyenCungLoaiDuocGopKhongMatPhamVi() async throws {
    let e = try await Moi { _ in [tra(#"{"summary":"x","grants":[{"kind":"read.departments","mode":"auto","operations":["projects.list"]},{"kind":"read.departments","mode":"auto","operations":["notebooks.list"]}]}"#)] }
    defer { e.don() }
    let d = try await e.sec.permissionDraft("Tra cứu dự án và sổ nguồn")
    _ = try await e.sec.permissionConfirm(id: d.id, approve: true)
    let ds = try await e.sec.grants().filter { $0.kind == "read.departments" }
    #expect(ds.count == 1 && ds[0].operations == ["notebooks.list", "projects.list"])
}
