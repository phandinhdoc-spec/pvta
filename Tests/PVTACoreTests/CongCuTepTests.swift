import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let M = "anthropic/claude-haiku-5-5"
private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

private func tam() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class NhatKyHeThong: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mo: [(String, Bool)] = []
    private(set) var rac: [String] = []
    let thungRac = tam()
    func ghiMo(_ u: URL, _ r: Bool) { lock.lock(); mo.append((u.path, r)); lock.unlock() }
    func chuyenRac(_ u: URL) throws -> URL {
        let dich = thungRac.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + u.lastPathComponent)
        try FileManager.default.moveItem(at: u, to: dich)
        lock.lock(); rac.append(u.path); lock.unlock()
        return dich
    }
    var hanhDong: HostActions { HostActions(trash: { [self] in try chuyenRac($0) }, open: { [self] in ghiMo($0, $1) }) }
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = tam(), lam = tam(), ngoai = tam()
    let he = NhatKyHeThong()
    let mang: FakeTransport
    let core: Core
    var f: FileService { core.files }

    init(_ replies: [FakeTransport.Reply] = [], write: Bool = true) async throws {
        mang = FakeTransport(replies)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: nha, approvalTimeout: .seconds(5), hostActions: he.hanhDong)
        _ = try await core.permissions.addGrant(path: lam.path, write: write)
    }

    func don() { for u in [paths.home, nha, lam, ngoai, he.thungRac] { try? FileManager.default.removeItem(at: u) } }
    func tep(_ rel: String, _ nd: String = "x") throws -> String {
        let u = lam.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(nd.utf8).write(to: u)
        return u.path
    }
    func doc(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func dat(_ l: PermissionLevel) async throws { _ = try await core.permissions.setLevel(l, acknowledge: true) }
    func chat() async throws -> Chat { try await core.store.createChat() }
    func body(_ i: Int) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data())) ?? .null }
    func ketQua(_ i: Int) -> String {
        guard case .array(let ms)? = body(i)["messages"] else { return "" }
        return ms.last?["content"]?.string ?? ""
    }
    func gui(_ id: String) -> Task<ChatTurnResult, Error> {
        Task { try await core.chat.send(chatId: id, text: "làm đi", model: M, emit: { _, _ in }) }
    }
    func choDeXuat() async -> ActionProposal? {
        for _ in 0..<250 {
            if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

private func khoi(_ tool: String, _ args: JSONValue) -> String {
    let a = String(decoding: (try? JSONEncoder().encode(args)) ?? Data(), as: UTF8.self)
    return "```pvta-tool\n{\"tool\":\"\(tool)\",\"args\":\(a)}\n```\n"
}

private let xong = claudeSSE(["Xong"])

// MARK: Đọc, liệt kê, tìm

@Test func docLietKeVaTimTheoTenVaNoiDungKhongPhanBietDau() async throws {
    let e = try await Moi(); defer { e.don() }
    try FileManager.default.copyItem(at: mau.appendingPathComponent("giao-an.docx"), to: e.lam.appendingPathComponent("Giáo án.docx"))
    try FileManager.default.copyItem(at: mau.appendingPathComponent("de-cuong.pdf"), to: e.lam.appendingPathComponent("de-cuong.pdf"))
    _ = try e.tep("Quy tắc/Quy tắc chấm điểm.md", "# Quy tắc\nĐiều 1. Quy tắc làm tròn điểm.\nĐiều 2. Khác.\n")
    _ = try e.tep("Tuần 1/phiếu.txt", "không liên quan")
    _ = try e.tep(".an/quy tac an.md", "quy tắc ẩn")
    try FileManager.default.createSymbolicLink(at: e.lam.appendingPathComponent("lk"), withDestinationURL: e.ngoai)
    _ = try e.tep("../" + e.ngoai.lastPathComponent + "/quy-tac-ngoai.md", "quy tắc ngoài phạm vi")

    let ten = try await e.f.find(root: e.lam.path, chatId: nil, name: "quy tac", content: nil)
    #expect(ten.hits.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["Quy tắc chấm điểm.md"])   // "quy tac" thấy "quy tắc"; mục ẩn và liên kết bị bỏ
    let nd = try await e.f.find(root: e.lam.path, chatId: nil, name: nil, content: "quy tac lam tron")
    #expect(nd.hits.count == 1 && nd.hits[0].line == 2 && nd.hits[0].text?.contains("làm tròn") == true)
    let docx = try await e.f.find(root: e.lam.path, chatId: nil, name: nil, content: "nhan don thuc")        // trong Word
    #expect(docx.hits.first?.path.hasSuffix("Giáo án.docx") == true)
    let pdf = try await e.f.find(root: e.lam.path, chatId: nil, name: nil, content: "hằng đẳng thức")           // trong PDF không dấu
    #expect(pdf.hits.first?.path.hasSuffix("de-cuong.pdf") == true)
    let ket = try await e.f.find(root: e.lam.path, chatId: nil, name: "giao an", content: "khoi dong")
    #expect(ket.hits.count == 1)
    await #expect(throws: PVTAError.self) { _ = try await e.f.find(root: e.lam.path, chatId: nil, name: nil, content: nil) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.find(root: e.ngoai.path, chatId: nil, name: "quy", content: nil) }   // ngoài phạm vi

    let ds = try await e.f.list(path: e.lam.path, chatId: nil)
    #expect(ds.map(\.name) == ["Giáo án.docx", "Quy tắc", "Tuần 1", "de-cuong.pdf"] || Set(ds.map(\.name)) == ["Giáo án.docx", "Quy tắc", "Tuần 1", "de-cuong.pdf", "lk"])
    #expect(ds.first { $0.name == "lk" }?.kind == "link" && ds.first { $0.name == "Quy tắc" }?.kind == "dir")
    #expect(try await e.f.list(path: e.lam.path, chatId: nil, depth: 2).contains { $0.name == "Quy tắc chấm điểm.md" })

    let doc = try await e.f.read(path: e.lam.appendingPathComponent("Quy tắc/Quy tắc chấm điểm.md").path, chatId: nil, start: 0, length: 20)
    #expect(doc.contains("ký tự 0–20") && doc.contains("đọc tiếp từ start=20"))
    #expect(try await e.f.read(path: e.lam.appendingPathComponent("Giáo án.docx").path, chatId: nil).contains("Giáo án Toán 8"))
    await #expect(throws: PVTAError.self) { _ = try await e.f.read(path: e.lam.path, chatId: nil) }                // thư mục
    await #expect(throws: PVTAError.self) { _ = try await e.f.read(path: e.ngoai.path + "/quy-tac-ngoai.md", chatId: nil) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.read(path: e.lam.path + "/lk/quy-tac-ngoai.md", chatId: nil) }       // qua liên kết
    await #expect(throws: PVTAError.self) { _ = try await e.f.read(path: "tuong-doi.txt", chatId: nil) }
}

// MARK: Ghi, sửa, di chuyển, xóa

@Test func ghiTaoMoiGhiDeCoSaoLuuVaGhiNguyenTu() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = e.lam.appendingPathComponent("moi/bai.md").path                         // thư mục "moi" chưa có
    let c1 = try await e.f.write(path: p, content: "Bản một", overwrite: false, chatId: nil)
    #expect(c1.kind == "create" && e.doc(p) == "Bản một")
    await #expect(throws: PVTAError.self) { _ = try await e.f.write(path: p, content: "Bản hai", overwrite: false, chatId: nil) }
    #expect(e.doc(p) == "Bản một")                                                  // không ghi đè khi chưa cho phép
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: p)
    let c2 = try await e.f.write(path: p, content: "Bản hai", overwrite: true, chatId: nil)
    #expect(c2.kind == "overwrite" && e.doc(p) == "Bản hai" && c2.backup.flatMap { e.doc($0) } == "Bản một")
    #expect(((try FileManager.default.attributesOfItem(atPath: p))[.posixPermissions] as? Int) == 0o640)   // giữ quyền tệp
    #expect(try FileManager.default.contentsOfDirectory(atPath: (p as NSString).deletingLastPathComponent).allSatisfy { !$0.hasPrefix(".pvta-") })
    // Chỉ tệp văn bản; ghi qua liên kết tượng trưng ra ngoài bị chặn, liên kết nội bộ ghi đúng tệp thật.
    await #expect(throws: PVTAError.self) { _ = try await e.f.write(path: e.lam.path + "/a.docx", content: "x", overwrite: false, chatId: nil) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.write(path: e.ngoai.path + "/a.txt", content: "x", overwrite: false, chatId: nil) }
    let that = try e.tep("that.txt", "cũ")
    try FileManager.default.createSymbolicLink(atPath: e.lam.path + "/lien.txt", withDestinationPath: that)
    _ = try await e.f.write(path: e.lam.path + "/lien.txt", content: "mới", overwrite: true, chatId: nil)
    #expect(e.doc(that) == "mới" && (try? FileManager.default.destinationOfSymbolicLink(atPath: e.lam.path + "/lien.txt")) == that)
    let lkNgoai = e.lam.path + "/ra-ngoai.txt"
    let mat = e.ngoai.path + "/mat.txt"; try Data("bí mật".utf8).write(to: URL(fileURLWithPath: mat))
    try FileManager.default.createSymbolicLink(atPath: lkNgoai, withDestinationPath: mat)
    await #expect(throws: PVTAError.self) { _ = try await e.f.write(path: lkNgoai, content: "ghi đè", overwrite: true, chatId: nil) }
    #expect(e.doc(mat) == "bí mật")
}

@Test func suaMotPhanTheoDoanKhopDungMotCho() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("sua.md", "Dòng A\nDòng B\nDòng B\nDòng C\n")
    await #expect(throws: PVTAError.self) { _ = try await e.f.edit(path: p, edits: [TextEdit(find: "Dòng Z", replace: "x")], chatId: nil) }
    do { _ = try await e.f.edit(path: p, edits: [TextEdit(find: "Dòng B", replace: "x")], chatId: nil); Issue.record("phải báo trùng") } catch let err as PVTAError {
        #expect(err.message.contains("xuất hiện 2 lần") && err.message.contains("all=true"))
    }
    #expect(e.doc(p) == "Dòng A\nDòng B\nDòng B\nDòng C\n")                          // lỗi thì tệp giữ nguyên
    let c = try await e.f.edit(path: p, edits: [TextEdit(find: "Dòng A", replace: "Đầu"), TextEdit(find: "Dòng B", replace: "Giữa", all: true)], chatId: nil)
    #expect(e.doc(p) == "Đầu\nGiữa\nGiữa\nDòng C\n" && c.kind == "edit" && c.detail == "Sửa 2 chỗ")
    let xem = try await e.f.previewEdit(path: p, edits: [TextEdit(find: "Dòng C", replace: "Cuối")], chatId: nil)
    #expect(xem.diff.contains("- Dòng C") && xem.diff.contains("+ Cuối"))
    #expect(e.doc(p).contains("Dòng C"))                                            // xem trước không ghi
    #expect(DiffText.unified(old: "a\nb\nc\nd\ne\nf\ng\nh", new: "a\nb\nc\nd\ne\nf\ng\nh") == "")
    await #expect(throws: PVTAError.self) { _ = try TextEdit.parse(.array([["find": "", "replace": "x"]])) }
}

@Test func diChuyenKhongGhiDeVaXoaVaoThungRac() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try e.tep("a.txt", "nội dung a"), b = try e.tep("b.txt", "b")
    let dich = e.lam.path + "/moi/a2.txt"
    let m = try await e.f.move(from: a, to: dich, chatId: nil)
    #expect(m.kind == "move" && e.doc(dich) == "nội dung a" && !FileManager.default.fileExists(atPath: a))
    await #expect(throws: PVTAError.self) { _ = try await e.f.move(from: b, to: dich, chatId: nil) }             // đã có đích
    await #expect(throws: PVTAError.self) { _ = try await e.f.move(from: b, to: e.ngoai.path + "/b.txt", chatId: nil) }   // đích ngoài phạm vi
    await #expect(throws: PVTAError.self) { _ = try await e.f.move(from: e.ngoai.path + "/x", to: e.lam.path + "/x", chatId: nil) }
    _ = try e.tep("thu/muc/c.txt")
    await #expect(throws: PVTAError.self) { _ = try await e.f.move(from: e.lam.path + "/thu", to: e.lam.path + "/thu/muc/thu2", chatId: nil) }   // vào chính nó

    let cs = try await e.f.trash(paths: [b, e.lam.path + "/thu"], chatId: nil)
    let goc = PathGuard.canonical(e.lam.path) ?? e.lam.path
    #expect(cs.count == 2 && e.he.rac == [goc + "/b.txt", goc + "/thu"])               // chuyển vào Thùng rác, không xóa hẳn
    #expect(!FileManager.default.fileExists(atPath: b) && FileManager.default.fileExists(atPath: cs[0].trashPath ?? ""))
    try FileManager.default.createSymbolicLink(atPath: e.lam.path + "/lk", withDestinationPath: e.ngoai.path)
    await #expect(throws: PVTAError.self) { _ = try await e.f.trash(paths: [e.lam.path + "/lk"], chatId: nil) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.trash(paths: [e.lam.path + "/khong-co"], chatId: nil) }
}

// MARK: Hoàn tác

@Test func hoanTacChiKhiTepChuaBiSuaBenNgoai() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("ht.txt", "gốc")
    let c = try await e.f.write(path: p, content: "PVTA ghi", overwrite: true, chatId: nil)
    // Đã sửa bên ngoài: không hoàn tác, tệp giữ nguyên.
    try Data("người dùng sửa tay".utf8).write(to: URL(fileURLWithPath: p))
    do { _ = try await e.f.undo(id: c.id); Issue.record("phải từ chối") } catch let err as PVTAError {
        #expect(err.message.contains("chỉnh sửa bên ngoài PVTA") && err.message.contains("giữ nguyên"))
    }
    #expect(e.doc(p) == "người dùng sửa tay")
    // Chưa sửa ngoài: hoàn tác được, một lần duy nhất.
    let c2 = try await e.f.write(path: p, content: "PVTA ghi lần 2", overwrite: true, chatId: nil)
    let xong = try await e.f.undo(id: c2.id)
    #expect(xong.undone && e.doc(p) == "người dùng sửa tay")
    await #expect(throws: PVTAError.self) { _ = try await e.f.undo(id: c2.id) }

    // Sửa một phần, tạo mới, di chuyển, xóa: mỗi loại hoàn tác đúng.
    let q = try e.tep("q.txt", "một hai ba")
    let sua = try await e.f.edit(path: q, edits: [TextEdit(find: "hai", replace: "2")], chatId: nil)
    _ = try await e.f.undo(id: sua.id)
    #expect(e.doc(q) == "một hai ba")
    let moi = try await e.f.write(path: e.lam.path + "/moi.txt", content: "mới tạo", overwrite: false, chatId: nil)
    _ = try await e.f.undo(id: moi.id)
    #expect(!FileManager.default.fileExists(atPath: moi.path) && e.he.rac.contains(moi.path))        // tạo mới → hoàn tác vào Thùng rác
    let dc = try await e.f.move(from: q, to: e.lam.path + "/q2.txt", chatId: nil)
    try Data("sửa sau khi chuyển".utf8).write(to: URL(fileURLWithPath: dc.path))
    await #expect(throws: PVTAError.self) { _ = try await e.f.undo(id: dc.id) }                      // đã bị sửa nên không kéo về
    let dc2 = try await e.f.move(from: e.lam.path + "/q2.txt", to: e.lam.path + "/q3.txt", chatId: nil)
    _ = try await e.f.undo(id: dc2.id)
    #expect(FileManager.default.fileExists(atPath: e.lam.path + "/q2.txt"))
    let r = try await e.f.trash(paths: [e.lam.path + "/q2.txt"], chatId: nil)
    _ = try await e.f.undo(id: r[0].id)
    #expect(e.doc(e.lam.path + "/q2.txt") == "sửa sau khi chuyển")                                  // khôi phục từ Thùng rác
    #expect(try await e.f.changes().count >= 7)
    // Chỉ đọc thì không hoàn tác.
    let k = try await e.f.write(path: e.lam.path + "/k.txt", content: "k", overwrite: false, chatId: nil)
    try await e.dat(.readOnly)
    await #expect(throws: PVTAError.self) { _ = try await e.f.undo(id: k.id) }
}

// MARK: Phiên sửa tệp

@Test func phienSuaMoXemApDungHoanTacLamLaiVaChiGhiKhiLuu() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("bai.md", "Dòng 1\nDòng 2\nDòng 3\n")
    let s0 = try await e.f.editOpen(path: p, chatId: nil)
    #expect(!s0.dirty && !s0.canUndo && !s0.sourceChanged)
    let s1 = try await e.f.editApply(sessionId: s0.id, revision: s0.revision, edits: [TextEdit(find: "Dòng 2", replace: "Dòng hai")], content: nil)
    let s2 = try await e.f.editApply(sessionId: s0.id, revision: s1.revision, edits: nil, content: "Làm lại toàn bộ\n")
    #expect(s2.dirty && s2.canUndo && !s2.canRedo)
    #expect(e.doc(p) == "Dòng 1\nDòng 2\nDòng 3\n")                                   // tệp gốc chưa đổi
    #expect(try await e.f.editRead(sessionId: s0.id).text == "Làm lại toàn bộ\n")
    let diff = try await e.f.editDiff(sessionId: s0.id)
    #expect(diff.contains("- Dòng 1") && diff.contains("+ Làm lại toàn bộ"))
    await #expect(throws: PVTAError.self) { _ = try await e.f.editApply(sessionId: s0.id, revision: s1.revision, edits: nil, content: "x") }   // revision cũ
    let u = try await e.f.editMove(sessionId: s0.id, revision: s2.revision, by: -1)
    #expect(try await e.f.editRead(sessionId: s0.id).text == "Dòng 1\nDòng hai\nDòng 3\n" && u.canRedo)
    let r = try await e.f.editMove(sessionId: s0.id, revision: u.revision, by: 1)
    #expect(try await e.f.editRead(sessionId: s0.id).text == "Làm lại toàn bộ\n" && !r.canRedo)
    await #expect(throws: PVTAError.self) { _ = try await e.f.editMove(sessionId: s0.id, revision: r.revision, by: 1) }
    // Quay lại rồi sửa tiếp thì nhánh "làm lại" cũ bị bỏ.
    let back = try await e.f.editMove(sessionId: s0.id, revision: r.revision, by: -1)
    let nhanh = try await e.f.editApply(sessionId: s0.id, revision: back.revision, edits: [TextEdit(find: "Dòng 3", replace: "Dòng ba")], content: nil)
    #expect(!nhanh.canRedo)

    // Lưu: ghi đè tệp gốc, ghi nhận để hoàn tác.
    let saved = try await e.f.editSave(sessionId: s0.id, revision: nhanh.revision, destination: nil, chatId: nil)
    #expect(e.doc(p) == "Dòng 1\nDòng hai\nDòng ba\n" && !saved.dirty && !saved.sourceChanged)
    let luu = try #require(try await e.f.changes().first { $0.kind == "save" })
    #expect(luu.path == (try #require(PathGuard.canonical(p))))
    _ = try await e.f.undo(id: luu.id)
    #expect(e.doc(p) == "Dòng 1\nDòng 2\nDòng 3\n")                                   // hoàn tác lần lưu cuối
}

@Test func luuBaoXungDotKhiTepGocBiSuaNgoaiVaHoanTacLuuChiKhiChuaSuaNgoai() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("xd.txt", "bản gốc")
    let s = try await e.f.editOpen(path: p, chatId: nil)
    let d = try await e.f.editApply(sessionId: s.id, revision: s.revision, edits: nil, content: "bản nháp của PVTA")
    try Data("người khác sửa trong lúc mở".utf8).write(to: URL(fileURLWithPath: p))
    let v = try await e.f.editRead(sessionId: s.id).session
    #expect(v.sourceChanged)                                                          // báo xung đột trước khi lưu
    do { _ = try await e.f.editSave(sessionId: s.id, revision: d.revision, destination: nil, chatId: nil); Issue.record("phải báo xung đột") } catch let err as PVTAError {
        #expect(err.message.contains("sửa bên ngoài PVTA") && err.message.contains("Lưu thành"))
    }
    #expect(e.doc(p) == "người khác sửa trong lúc mở")                                // không ghi đè
    // Lưu thành tệp mới thì được, và không bao giờ ghi đè tệp có sẵn.
    let ban2 = e.lam.path + "/xd-ban-2.txt"
    let moi = try await e.f.editSave(sessionId: s.id, revision: d.revision, destination: ban2, chatId: nil)
    #expect(e.doc(ban2) == "bản nháp của PVTA" && moi.source == PathGuard.canonical(ban2))
    await #expect(throws: PVTAError.self) { _ = try await e.f.editSave(sessionId: moi.id, revision: moi.revision, destination: p, chatId: nil) }   // đích đã có
    await #expect(throws: PVTAError.self) { _ = try await e.f.editSave(sessionId: moi.id, revision: moi.revision, destination: e.lam.path + "/sai-dinh-dang.md", chatId: nil) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.editSave(sessionId: moi.id, revision: moi.revision, destination: e.ngoai.path + "/ngoai.txt", chatId: nil) }

    // Hoàn tác lần lưu cuối chỉ chạy khi tệp chưa bị sửa ngoài.
    let n = try await e.f.editApply(sessionId: moi.id, revision: moi.revision, edits: nil, content: "lần lưu hai")
    _ = try await e.f.editSave(sessionId: moi.id, revision: n.revision, destination: nil, chatId: nil)
    let luu = try #require(try await e.f.changes().first { $0.kind == "save" })
    try Data("sửa tay sau khi lưu".utf8).write(to: URL(fileURLWithPath: ban2))
    do { _ = try await e.f.undo(id: luu.id); Issue.record("phải từ chối") } catch let err as PVTAError { #expect(err.message.contains("giữ nguyên")) }
    #expect(e.doc(ban2) == "sửa tay sau khi lưu")
    let hong = try await e.f.changes().first { $0.id == luu.id }
    #expect(hong?.undone == false)
}

@Test func phienSuaMoLaiGiuBanNhapVaDonPhienSach() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.tep("m.txt", "v1")
    let a = try await e.f.editOpen(path: p, chatId: nil)
    // Phiên chưa sửa gì mà tệp gốc đổi: mở lại thì lấy bản mới.
    try Data("v2".utf8).write(to: URL(fileURLWithPath: p))
    let b = try await e.f.editOpen(path: p, chatId: nil)
    let doc2 = try await e.f.editRead(sessionId: b.id).text
    #expect(a.id == b.id && doc2 == "v2")
    // Phiên đã có bản nháp: mở lại không mất bản nháp.
    let c = try await e.f.editApply(sessionId: b.id, revision: b.revision, edits: nil, content: "nháp")
    let d = try await e.f.editOpen(path: p, chatId: nil)
    #expect(d.dirty && d.revision == c.revision)
    await #expect(throws: PVTAError.self) { try await e.f.editDiscard(sessionId: d.id, revision: 0) }          // sai revision
    try await e.f.editDiscard(sessionId: d.id, revision: d.revision)
    await #expect(throws: PVTAError.self) { _ = try await e.f.editRead(sessionId: d.id) }
    #expect(e.doc(p) == "v2")                                                          // bỏ bản nháp không đụng tệp gốc
    // Không mở được: tệp ngoài phạm vi, tệp Office, thư mục, tệp không tồn tại, mã phiên bậy.
    _ = try e.tep("a.docx")
    for bad in [e.ngoai.path + "/x.txt", e.lam.path + "/a.docx", e.lam.path, e.lam.path + "/khong-co.txt"] {
        await #expect(throws: PVTAError.self, "\(bad)") { _ = try await e.f.editOpen(path: bad, chatId: nil) }
    }
    await #expect(throws: PVTAError.self) { _ = try await e.f.editRead(sessionId: "../../etc") }
    // Chỉ đọc thì không lưu được.
    let s = try await e.f.editOpen(path: p, chatId: nil)
    let n = try await e.f.editApply(sessionId: s.id, revision: s.revision, edits: nil, content: "x")
    try await e.dat(.readOnly)
    await #expect(throws: PVTAError.self) { _ = try await e.f.editSave(sessionId: s.id, revision: n.revision, destination: nil, chatId: nil) }
}

// MARK: Dùng qua model: duyệt, thư mục kết quả, quyền

@Test func modelGhiTepPhaiChoDuyetThayDiffVaThuMucKetQua() async throws {
    let e = try await Moi([
        .init(lines: claudeSSE([khoi("fs_write", ["path": "giao-an-moi.md", "content": "# Giáo án\nNội dung"])])), .init(lines: xong),
        .init(lines: claudeSSE([khoi("fs_edit", ["path": "giao-an-moi.md", "edits": [["find": "Nội dung", "replace": "Đã sửa"]]])])), .init(lines: xong),
    ]); defer { e.don() }
    let c = try await e.chat()
    let dichDuKien = try #require(PathGuard.canonical(e.lam.path)) + "/giao-an-moi.md"
    // Chưa chọn thư mục kết quả: dùng thư mục đầu tiên được cấp quyền ghi.
    #expect(try await e.f.outputDirectory(chatId: c.id) == PathGuard.canonical(e.lam.path))
    let l1 = e.gui(c.id)
    let p1 = try #require(await e.choDeXuat())
    #expect(p1.kind == .write && p1.paths == [dichDuKien] && p1.preview.contains("Nội dung") && p1.summary.hasPrefix("Tạo tệp mới"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: dichDuKien))                          // chưa duyệt thì chưa có tệp
    try await e.core.permissions.queue.approve(id: p1.id)
    _ = try await l1.value
    #expect(e.doc(dichDuKien) == "# Giáo án\nNội dung" && e.ketQua(1).contains("Đã ghi") && e.ketQua(1).contains("mã hoàn tác"))
    let he = String(describing: e.body(0)["system"] ?? .null)       // model được báo rõ nơi làm việc, khỏi đoán đường dẫn
    #expect(he.contains("THƯ MỤC PVTA ĐƯỢC PHÉP LÀM VIỆC") && he.contains((PathGuard.canonical(e.lam.path) ?? "") + " (đọc và ghi)") && he.contains("THƯ MỤC KẾT QUẢ"))

    let l2 = e.gui(c.id)
    var p2: ActionProposal?
    for _ in 0..<250 where p2 == nil { p2 = await e.core.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(p2?.preview.contains("- Nội dung") == true && p2?.preview.contains("+ Đã sửa") == true)   // thấy diff trước khi duyệt
    try await e.core.permissions.queue.decline(id: try #require(p2).id)
    _ = try await l2.value
    #expect(e.doc(dichDuKien).contains("Nội dung") && !e.doc(dichDuKien).contains("Đã sửa"))
}

@Test func modelBiChanNgoaiPhamViVaThuMucChiDocVaXoaNhieuLaNguyHiem() async throws {
    let doc = tam(); defer { try? FileManager.default.removeItem(at: doc) }
    let e = try await Moi([
        .init(lines: claudeSSE([khoi("fs_write", ["path": .string(e0(doc, "a.txt")), "content": "x"]) + khoi("fs_write", ["path": .string(e0(tam(), "b.txt")), "content": "x"]) + khoi("fs_read", ["path": .string(e0(doc, "a.txt"))])])),
        .init(lines: xong),
    ]); defer { e.don() }
    _ = try await e.core.permissions.addGrant(path: doc.path, write: false)
    try Data("chỉ đọc được".utf8).write(to: doc.appendingPathComponent("a.txt"))
    try await e.dat(.autoEdit)
    let c = try await e.chat()
    _ = try await e.gui(c.id).value
    let kq = e.ketQua(1)
    #expect(kq.contains("mới được cấp quyền đọc") && kq.contains("nằm ngoài các thư mục"))   // ghi vào thư mục chỉ đọc và thư mục lạ đều bị chặn hẳn
    #expect(kq.contains("chỉ đọc được"))                                                     // nhưng đọc được
    #expect(e.doc(doc.path + "/a.txt") == "chỉ đọc được")
    #expect(await e.core.permissions.queue.list().isEmpty)

    // Xóa 6 mục qua model: nguy hiểm ngay cả ở Tự sửa.
    let e2 = try await Moi(); defer { e2.don() }
    var ps: [JSONValue] = []
    for i in 0..<6 { ps.append(.string(try e2.tep("x\(i).txt"))) }
    let mang2 = FakeTransport([.init(lines: claudeSSE([khoi("fs_trash", ["paths": .array(ps)])])), .init(lines: xong)])
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let core2 = Core(store: e2.core.store, ai: AIClient(config: ConfigStore(paths: e2.paths), keys: keys, transport: mang2, retry: .none, cli: Gia().moi()),
                     screenHome: e2.nha, approvalTimeout: .seconds(5), hostActions: e2.he.hanhDong)
    try ConfigStore(paths: e2.paths).update { $0.permission = .autoEdit }
    let c2 = try await e2.chat()
    let luot = Task { try await core2.chat.send(chatId: c2.id, text: "dọn", model: M, emit: { _, _ in }) }
    var nguyHiem: ActionProposal?
    for _ in 0..<250 where nguyHiem == nil { nguyHiem = await core2.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    let p = try #require(nguyHiem)
    #expect(p.risk == "high" && p.kind == .delete && p.paths.count == 6 && e2.he.rac.isEmpty)
    await #expect(throws: PVTAError.self) { try await core2.permissions.queue.approve(id: p.id) }
    try await core2.permissions.queue.approve(id: p.id, force: true)
    _ = try await luot.value
    #expect(e2.he.rac.count == 6)                                                       // vào Thùng rác, hoàn tác được
    #expect(try await e2.f.changes().filter { $0.kind == "trash" }.count == 6)
}

private func e0(_ d: URL, _ n: String) -> String { d.appendingPathComponent(n).path }

@Test func tuSuaGhiThangTrongThuMucCapQuyenGhi() async throws {
    let e = try await Moi([.init(lines: claudeSSE([khoi("fs_write", ["path": "tu-ghi.txt", "content": "ok"])])), .init(lines: xong)]); defer { e.don() }
    try await e.dat(.autoEdit)
    let c = try await e.chat()
    _ = try await e.gui(c.id).value
    #expect(e.doc(e.lam.path + "/tu-ghi.txt") == "ok" || e.doc((PathGuard.canonical(e.lam.path) ?? "") + "/tu-ghi.txt") == "ok")
    #expect(await e.core.permissions.queue.list().isEmpty)
    // Không có thư mục ghi nào được cấp: đường dẫn tương đối báo lỗi rõ ràng.
    let rieng = try await Moi([.init(lines: claudeSSE([khoi("fs_write", ["path": "x.txt", "content": "ok"])])), .init(lines: xong)], write: false); defer { rieng.don() }
    try await rieng.dat(.autoEdit)
    let c2 = try await rieng.chat()
    _ = try await rieng.gui(c2.id).value
    #expect(rieng.ketQua(1).contains("thư mục kết quả"))
}

@Test func chonThuMucKetQuaPhaiLaThuMucDuocCapQuyenGhi() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let con = e.lam.appendingPathComponent("ket-qua"); try FileManager.default.createDirectory(at: con, withIntermediateDirectories: true)
    #expect(try await e.f.selectOutput(chatId: c.id, dir: con.path) == PathGuard.canonical(con.path))
    #expect(try await e.f.outputDirectory(chatId: c.id) == PathGuard.canonical(con.path))
    await #expect(throws: PVTAError.self) { _ = try await e.f.selectOutput(chatId: c.id, dir: e.ngoai.path) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.selectOutput(chatId: c.id, dir: e.lam.path + "/khong-co") }
    let tep = try e.tep("la-tep.txt")
    await #expect(throws: PVTAError.self) { _ = try await e.f.selectOutput(chatId: c.id, dir: tep) }
    // Tệp tương đối ghi vào thư mục đã chọn.
    let ch = try await e.f.write(path: "bai.txt", content: "a", overwrite: false, chatId: c.id)
    #expect(ch.path == (PathGuard.canonical(con.path) ?? "") + "/bai.txt")
    // Gỡ cấp quyền thì quay về thư mục khác (hoặc không có).
    try await e.core.permissions.removeGrant(path: e.lam.path)
    #expect(try await e.f.outputDirectory(chatId: c.id) == nil)
}

@Test func moTepChiTrongPhamViDaCapHoacDinhKem() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let p = try e.tep("mo.txt")
    #expect(try await e.f.open(ref: p, chatId: nil, reveal: false) == (PathGuard.canonical(p) ?? p))
    _ = try await e.f.open(ref: p, chatId: nil, reveal: true)
    #expect(e.he.mo.map(\.1) == [false, true])
    let mat = e.ngoai.path + "/mat.txt"; try Data("x".utf8).write(to: URL(fileURLWithPath: mat))
    await #expect(throws: PVTAError.self) { _ = try await e.f.open(ref: mat, chatId: c.id, reveal: false) }
    await #expect(throws: PVTAError.self) { _ = try await e.f.open(ref: "khong-co.txt", chatId: c.id, reveal: false) }
    #expect(e.he.mo.count == 2)                                                         // lỗi thì không mở gì
    // Tệp đính kèm mở được dù thư mục chưa được cấp.
    _ = try await e.core.attachments.add(chatId: c.id, paths: [mat])
    _ = try await e.f.open(ref: "mat.txt", chatId: c.id, reveal: false)
    #expect(e.he.mo.count == 3)
}

// MARK: Qua giao diện gọi chung

@Test func goiQuaLoiPhienSuaHoanTacVaThuMucKetQuaGiuaHaiNut() async throws {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: paths.home) }
    let lam = tam(); defer { try? FileManager.default.removeItem(at: lam) }
    let he = NhatKyHeThong()
    let ai = AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore(), transport: FakeTransport([]), retry: .none, cli: Gia().moi())
    let host = try await PVTANode.open(paths: paths, ai: ai, hostActions: he.hanhDong)
    let a = try await PVTANode.open(paths: paths), b = try await PVTANode.open(paths: paths)
    let tep = lam.appendingPathComponent("rpc.md"); try Data("Dòng một\nDòng hai\n".utf8).write(to: tep)
    let id = try await a.call("chat.create")["id"]!.string!

    await #expect(throws: PVTAError.self) { try await a.call("edit.open", ["path": .string(tep.path)]) }      // chưa cấp thư mục
    _ = try await a.call("grant.add", ["path": .string(lam.path), "write": true])
    let ss = try await b.call("edit.open", ["path": .string(tep.path)]).decode(FileService.SessionView.self)
    let ap = try await a.call("edit.apply", ["sessionId": .string(ss.id), "revision": .number(Double(ss.revision)),
                                              "edits": [["find": "Dòng hai", "replace": "Dòng 2"]]]).decode(FileService.SessionView.self)
    #expect(ap.dirty)
    #expect(try await b.call("edit.read", ["sessionId": .string(ss.id)])["text"]?.string == "Dòng một\nDòng 2\n")
    #expect(try await a.call("edit.diff", ["sessionId": .string(ss.id)]).string?.contains("+ Dòng 2") == true)
    let u = try await b.call("edit.undo", ["sessionId": .string(ss.id), "revision": .number(Double(ap.revision))]).decode(FileService.SessionView.self)
    let r = try await a.call("edit.redo", ["sessionId": .string(ss.id), "revision": .number(Double(u.revision))]).decode(FileService.SessionView.self)
    _ = try await b.call("edit.save", ["sessionId": .string(ss.id), "revision": .number(Double(r.revision))])
    #expect(try String(contentsOf: tep, encoding: .utf8) == "Dòng một\nDòng 2\n")
    let ds = try await a.call("change.list").decode(Array<FileChange>.self)
    let luu = try #require(ds.first { $0.kind == "save" })
    _ = try await b.call("change.undo", ["id": .string(luu.id)])
    #expect(try String(contentsOf: tep, encoding: .utf8) == "Dòng một\nDòng hai\n")

    let con = lam.appendingPathComponent("kq"); try FileManager.default.createDirectory(at: con, withIntermediateDirectories: true)
    let vt = try await a.call("output.location", ["chatId": .string(id)])
    #expect(vt["dir"]?.string == PathGuard.canonical(lam.path) && vt["choices"] != nil)
    #expect(try await b.call("output.select", ["chatId": .string(id), "dir": .string(con.path)]).string == PathGuard.canonical(con.path))
    _ = try await a.call("file.open", ["ref": .string(tep.path), "reveal": true])
    #expect(he.mo.last?.1 == true)
    await a.shutdown(); await b.shutdown(); await host.shutdown()
}
