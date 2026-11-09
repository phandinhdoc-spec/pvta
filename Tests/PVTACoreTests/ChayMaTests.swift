import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let M = "anthropic/claude-haiku-5-5"
private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

private func tam() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = tam(), dau = tam(), ngoai = tam()
    let mang: FakeTransport
    let core: Core

    init(_ replies: [FakeTransport.Reply] = [], grant: Bool = true, write: Bool = true) async throws {
        mang = FakeTransport(replies)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: nha, approvalTimeout: .seconds(8))
        if grant { _ = try await core.permissions.addGrant(path: dau.path, write: write) }
    }

    func don() { for u in [paths.home, nha, dau, ngoai] { try? FileManager.default.removeItem(at: u) } }
    func chat() async throws -> Chat { try await core.store.createChat() }
    func thuMucChay() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: PathGuard.canonical(dau.path) ?? dau.path)) ?? []).filter { $0.hasPrefix("chay-ma-") }.sorted()
    }
    func tepTrongLanChay(_ name: String) -> String? {
        guard let d = thuMucChay().last else { return nil }
        return try? String(contentsOfFile: (PathGuard.canonical(dau.path) ?? dau.path) + "/\(d)/\(name)", encoding: .utf8)
    }
    func ketQua(_ i: Int) -> String {
        guard let b = try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data()), case .array(let ms)? = b["messages"] else { return "" }
        return ms.last?["content"]?.string ?? ""
    }
    func choDeXuat() async -> ActionProposal? {
        for _ in 0..<300 {
            if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func gui(_ id: String) -> Task<ChatTurnResult, Error> {
        Task { try await core.chat.send(chatId: id, text: "chạy giúp", model: M, emit: { _, _ in }) }
    }
}

private func goiMa(_ lang: String, _ code: String) -> [String] {
    let a = String(decoding: (try? JSONEncoder().encode(JSONValue.object(["lang": .string(lang), "code": .string(code)]))) ?? Data(), as: UTF8.self)
    return claudeSSE(["```pvta-tool\n{\"tool\":\"run_code\",\"args\":\(a)}\n```\n"])
}

private let phanBienSach = claudeSSE(["[]"])
private let xong = claudeSSE(["Xong"])

// MARK: Quét tĩnh, phản biện, trình thông dịch

@Test func quetTinhBatDungCacMucRuiRo() {
    func muc(_ code: String) -> Set<String> { Set(CodeScanner.scan(code).map(\.level)) }
    #expect(CodeScanner.scan("print('xin chào')\nx = 1 + 2").isEmpty)
    #expect(muc("rm -rf ~/Documents") == ["high"] && muc("import shutil\nshutil.rmtree('x')") == ["high"])
    #expect(muc("sudo apt install x").contains("high") && muc("cat ~/.ssh/id_rsa").contains("high"))
    #expect(muc("import requests\nrequests.get('http://x')").contains("medium"))
    #expect(muc("open('/etc/hosts')").contains("medium") && muc("os.chdir('../..')").contains("medium"))
    #expect(muc("import subprocess").contains("medium") && muc("eval(x)").contains("medium"))
    #expect(muc("open('a.txt', 'w')") == ["low"] && muc("echo hi > ra.txt") == ["low"])
    #expect(Set(CodeScanner.scan("rm -rf x; curl http://a").map(\.level)) == ["high", "medium"])     // nhiều mức cùng lúc
}

@Test func docCauTraLoiPhanBienKeCaKhiSaiDinhDang() {
    let ok = CodeScanner.parseReview(#"Đây: [{"level":"high","text":"Xóa tệp"},{"level":"khác","text":"Ghi chú"},{"text":"  "}]"#)
    #expect(ok.map(\.level) == ["high", "medium"] && ok.allSatisfy { $0.source == "ai" })
    #expect(CodeScanner.parseReview("[]").isEmpty)
    for bad in ["không có json", "[1, 2", "{\"level\":\"high\"}"] {
        let r = CodeScanner.parseReview(bad)
        #expect(r.count == 1 && r[0].level == "medium" && r[0].text.contains("không đúng định dạng"))
    }
}

@Test func timTrinhThongDichVaBaoThieuBangTiengViet() {
    #expect(Interpreter.find("bash")?.path.hasSuffix("/bash") == true && Interpreter.find("sh")?.lang == "bash")
    #expect(Interpreter.normalize("PY") == "python" && Interpreter.normalize("node") == "javascript" && Interpreter.normalize("zsh") == "bash")
    #expect(Interpreter.find("python")?.ext == "py")
    #expect(Interpreter.find("ruby") == nil)
    #expect(Interpreter.find("python", searchDirs: []) == nil)
    #expect(Interpreter.missingMessage("python").contains("không tự cài trình thông dịch") && Interpreter.missingMessage("python").contains("Python 3"))
    #expect(Interpreter.missingMessage("javascript").contains("Node.js"))
    #expect(Interpreter.missingMessage("ruby").contains("bash, javascript, python"))
}

// MARK: Chạy trong thư mục riêng

@Test func chayMaTrongThuMucMoiMoiLuotVaThuDuocDauRaVaTepTaoRa() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let r1 = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo xin chao\necho noi dung > ra.txt\nexit 0\n"), chatId: c.id)
    #expect(r1.ok && r1.exitCode == 0 && r1.output.contains("xin chao") && r1.files == ["ra.txt"])
    #expect(r1.runDir.contains("/chay-ma-") && FileManager.default.fileExists(atPath: r1.runDir + "/ra.txt"))
    let r2 = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "pwd; ls"), chatId: c.id)
    #expect(r2.runDir != r1.runDir && r2.output.contains("chay-ma-") && !r2.output.contains("ra.txt"))   // hai lượt không dùng chung thư mục
    #expect(e.thuMucChay().count == 2)
    let loi = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo lỗi >&2; exit 3"), chatId: c.id)
    #expect(!loi.ok && loi.exitCode == 3 && loi.output.contains("lỗi"))
    #expect(CodeService.describe(loi).contains("Mã báo lỗi (thoát 3)") && CodeService.describe(r1).contains("không phải môi trường cô lập"))
    if Interpreter.find("python") != nil {
        let py = try await e.core.code.runApproved(CodeRequest(lang: "py", code: "print(sum(range(10)))\nprint('Việt Nam')"), chatId: c.id)
        #expect(py.ok && py.output.contains("45") && py.output.contains("Việt Nam"))
    }
    if Interpreter.find("node") != nil {
        #expect(try await e.core.code.runApproved(CodeRequest(lang: "js", code: "console.log(2 + 3)"), chatId: c.id).output.contains("5"))
    }
    let acts = try await e.core.store.activities().filter { $0.kind == "code.run" }
    #expect(acts.count >= 4 && acts.contains { $0.state == .error && $0.detail == "Mã thoát 3" })
}

@Test func mayThieuTrinhThongDichThiBaoKhongTuCai() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let svc = CodeService(permissions: e.core.permissions, files: e.core.files, attachments: e.core.attachments, router: e.core.router,
                          ai: e.core.ai, store: e.core.store, searchDirs: [])
    do { _ = try await svc.runApproved(CodeRequest(lang: "python", code: "print(1)"), chatId: c.id); Issue.record("phải báo thiếu") } catch let err as PVTAError {
        #expect(err.message.contains("không tự cài") && err.message.contains("python"))
    }
    await #expect(throws: PVTAError.self) { _ = try await svc.runApproved(CodeRequest(lang: "ruby", code: "puts 1"), chatId: c.id) }
    #expect(e.thuMucChay().isEmpty)                                                       // không tạo thư mục khi không chạy được
    #expect(svc.interpreters().isEmpty && !e.core.code.interpreters().isEmpty)
}

@Test func hetGioVaBamDungDeuDungCaCayTienTrinh() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let chamLay = "sleep 300 &\necho $! > con.pid\nwait\n"
    let h = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: chamLay), chatId: c.id, timeout: .milliseconds(500))
    #expect(h.timedOut && !h.ok && CodeService.describe(h).contains("Hết thời gian"))
    func daChet(_ r: CodeResult) async throws -> Bool {
        guard let pid = Int32((try? String(contentsOfFile: r.runDir + "/con.pid", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { return false }
        for _ in 0..<100 { if kill(pid, 0) != 0 { return true }; try await Task.sleep(for: .milliseconds(50)) }
        return false
    }
    #expect(try await daChet(h))                                                          // tiến trình con cũng bị dừng

    let t = Task { try await e.core.code.runApproved(CodeRequest(lang: "bash", code: chamLay), chatId: c.id) }
    var dir = ""
    for _ in 0..<200 where dir.isEmpty {
        if let d = e.thuMucChay().last, FileManager.default.fileExists(atPath: (PathGuard.canonical(e.dau.path) ?? "") + "/\(d)/con.pid") { dir = d }
        try await Task.sleep(for: .milliseconds(25))
    }
    t.cancel()
    await #expect(throws: CancellationError.self) { _ = try await t.value }
    let fake = CodeResult(ok: false, exitCode: nil, timedOut: false, output: "", runDir: (PathGuard.canonical(e.dau.path) ?? "") + "/" + dir, files: [], seconds: 0)
    #expect(try await daChet(fake))
}

@Test func banGocKhongDoiDuocChepVaoThuMucChayVaMoiTruongKhongMangKhoa() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let nguon = tam(); defer { try? FileManager.default.removeItem(at: nguon) }
    let docx = nguon.appendingPathComponent("bang-diem.csv"); try Data("Toán,9\nVăn,8\n".utf8).write(to: docx)
    let thuMuc = nguon.appendingPathComponent("tai-lieu"); try FileManager.default.createDirectory(at: thuMuc, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: thuMuc.appendingPathComponent("a.txt"))
    try FileManager.default.createSymbolicLink(at: thuMuc.appendingPathComponent("lk"), withDestinationURL: e.ngoai)
    try Data("bí mật".utf8).write(to: e.ngoai.appendingPathComponent("mat.txt"))
    let truoc = FileHash.of(docx)
    _ = try await e.core.attachments.add(chatId: c.id, paths: [docx.path, thuMuc.path])
    setenv("ANTHROPIC_API_KEY", "sk-ant-KHONG-DUOC-DI-THEO-123456", 1)
    setenv("PVTA_BI_MAT", "gia-tri-bi-mat", 1)
    defer { unsetenv("ANTHROPIC_API_KEY"); unsetenv("PVTA_BI_MAT") }

    let code = "echo 'Sửa' >> bang-diem.csv\ncat bang-diem.csv\nls tai-lieu\nenv | grep -E 'ANTHROPIC|PVTA' || echo khong-co-bien-nhay-cam\n"
    let r = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: code, attachments: ["bang-diem.csv", thuMuc.path]), chatId: c.id)
    #expect(r.ok && r.output.contains("Sửa") && r.output.contains("a.txt"))
    #expect(!r.output.contains("lk") && !r.output.contains("mat.txt"))                    // không đi theo liên kết tượng trưng
    #expect(r.output.contains("khong-co-bien-nhay-cam") && !r.output.contains("KHONG-DUOC-DI-THEO"))
    let sau = try String(contentsOf: docx, encoding: .utf8)
    #expect(FileHash.of(docx) == truoc && sau == "Toán,9\nVăn,8\n")                      // bản gốc không đổi
    #expect(r.files.isEmpty)                                                              // tệp chép vào không tính là tệp tạo ra
    await #expect(throws: PVTAError.self) { _ = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "ls", attachments: ["/etc/hosts"]), chatId: c.id) }
    await #expect(throws: PVTAError.self) { _ = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "ls", attachments: ["khong-co.txt"]), chatId: c.id) }
}

@Test func dauRaCheKhoaVaCatBotKhiQuaDai() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let r = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo 'token sk-ant-BI-MAT-12345678'\nfor i in $(seq 1 3000); do echo 'dòng dài dài dài dài số '$i; done"), chatId: c.id)
    #expect(!r.output.contains("BI-MAT") && r.output.hasPrefix("[… đầu ra dài") && r.output.count <= 20_100)
    #expect(r.output.contains("số 3000"))
    let rieng = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo 'key=sk-ant-BI-MAT-12345678'"), chatId: c.id)
    #expect(rieng.output.contains("[đã ẩn]") && !rieng.output.contains("BI-MAT"))
}

@Test func thuMucDauRaBatBuocVaPhaiNamTrongThuMucDuocCapQuyenGhi() async throws {
    let e = try await Moi(grant: false); defer { e.don() }
    let c = try await e.chat()
    do { _ = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo x"), chatId: c.id); Issue.record("phải báo thiếu") } catch let err as PVTAError {
        #expect(err.message.contains("thư mục đầu ra"))
    }
    await #expect(throws: PVTAError.self) { _ = try await e.core.code.runApproved(CodeRequest(lang: "bash", code: "echo x", outputDir: e.ngoai.path), chatId: c.id) }   // ngoài phạm vi
    let chiDoc = try await Moi(write: false); defer { chiDoc.don() }
    let c2 = try await chiDoc.chat()
    await #expect(throws: PVTAError.self) { _ = try await chiDoc.core.code.runApproved(CodeRequest(lang: "bash", code: "echo x", outputDir: chiDoc.dau.path), chatId: c2.id) }
    #expect(chiDoc.thuMucChay().isEmpty && e.thuMucChay().isEmpty)
    await #expect(throws: PVTAError.self) { _ = try await chiDoc.core.code.runApproved(CodeRequest(lang: "bash", code: String(repeating: "#", count: 200_001)), chatId: c2.id) }
}

// MARK: Thẻ Duyệt mã qua model

@Test func modelMuonChayMaPhaiQuaPhanBienVaDuyetRoiMoiChay() async throws {
    let review = claudeSSE([#"[{"level":"medium","text":"Mã ghi tệp ra ngoài thư mục chạy"}]"#])
    let e = try await Moi([.init(lines: goiMa("bash", "echo xin chao > ra.txt\ncat ra.txt")), .init(lines: review), .init(lines: xong)]); defer { e.don() }
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let p = try #require(await e.choDeXuat())
    #expect(p.kind == .run && p.tool == "run_code" && p.preview.contains("echo xin chao"))
    #expect(p.summary.contains("không được cô lập") && p.risk == "normal")
    #expect(p.riskReasons.contains("[Thấp] Mã ghi tệp trong thư mục làm việc.") && p.riskReasons.contains("[Trung bình] AI phản biện: Mã ghi tệp ra ngoài thư mục chạy"))
    #expect(p.paths == [PathGuard.canonical(e.dau.path) ?? ""])
    try await Task.sleep(for: .milliseconds(300))
    #expect(e.thuMucChay().isEmpty)                                                        // chưa duyệt thì chưa tạo gì, chưa chạy gì
    try await e.core.permissions.queue.approve(id: p.id)
    _ = try await luot.value
    #expect(e.tepTrongLanChay("ra.txt") == "xin chao\n")
    #expect(e.ketQua(2).contains("Mã chạy xong") && e.ketQua(2).contains("xin chao") && e.ketQua(2).contains("ra.txt"))
    let reviewReq = String(decoding: e.mang.requests[1].httpBody ?? Data(), as: UTF8.self)
    #expect(reviewReq.contains("AI PHẢN BIỆN") && reviewReq.contains("echo xin chao"))
}

@Test func canhBaoCaoMacDinhChanPhaiChonVanChay() async throws {
    let e = try await Moi([.init(lines: goiMa("bash", "rm -rf thu-muc-khong-co\necho da-xoa")), .init(lines: phanBienSach), .init(lines: xong)]); defer { e.don() }
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let p = try #require(await e.choDeXuat())
    #expect(p.risk == "high" && p.riskReasons.contains("[Cao] Xóa tệp bằng rm -r/-f."))
    await #expect(throws: PVTAError.self) { try await e.core.permissions.queue.approve(id: p.id) }      // chưa đủ
    #expect(e.thuMucChay().isEmpty)
    try await e.core.permissions.queue.approve(id: p.id, force: true)                                   // “Vẫn chạy”
    _ = try await luot.value
    #expect(e.ketQua(2).contains("da-xoa"))
}

@Test func tuChoiThiKhongChayVaMoiLuotMotLanDuyetRieng() async throws {
    let e = try await Moi([.init(lines: goiMa("bash", "echo lan-mot")), .init(lines: phanBienSach), .init(lines: xong),
                           .init(lines: goiMa("bash", "echo lan-hai")), .init(lines: phanBienSach), .init(lines: xong)]); defer { e.don() }
    let c = try await e.chat()
    let l1 = e.gui(c.id)
    let p1 = try #require(await e.choDeXuat())
    try await e.core.permissions.queue.decline(id: p1.id)
    _ = try await l1.value
    #expect(e.thuMucChay().isEmpty && e.ketQua(2).contains("Người dùng đã từ chối"))
    let l2 = e.gui(c.id)                                                                   // lượt sau lại phải xin duyệt
    var p2: ActionProposal?
    for _ in 0..<300 where p2 == nil { p2 = await e.core.permissions.queue.list().first { $0.state == .pending }; try await Task.sleep(for: .milliseconds(20)) }
    #expect(try #require(p2).id != p1.id)
    try await e.core.permissions.queue.approve(id: try #require(p2).id)
    _ = try await l2.value
    #expect(e.thuMucChay().count == 1 && e.ketQua(5).contains("lan-hai"))
}

@Test func tuSuaVanHoiVaChiDocKhongChayNhungVanPhanBienDuoc() async throws {
    let e = try await Moi([.init(lines: goiMa("bash", "echo x")), .init(lines: phanBienSach), .init(lines: xong)]); defer { e.don() }
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let p = try #require(await e.choDeXuat())                                              // Tự sửa không tự chạy mã
    try await e.core.permissions.queue.decline(id: p.id)
    _ = try await luot.value

    // Chỉ đọc: không chạy, không hỏi, không tốn lượt phản biện; nhưng review_code vẫn dùng được.
    let args: JSONValue = ["tool": "review_code", "args": ["lang": "bash", "code": "rm -rf x && curl http://a"]]
    let rv = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
    let e2 = try await Moi([.init(lines: goiMa("bash", "echo x")), .init(lines: xong),
                            .init(lines: claudeSSE(["```pvta-tool\n\(rv)\n```\n"])), .init(lines: claudeSSE([#"[{"level":"low","text":"Thiếu kiểm tra lỗi"}]"#])), .init(lines: xong)]); defer { e2.don() }
    _ = try await e2.core.permissions.setLevel(.readOnly, acknowledge: false)
    let c2 = try await e2.chat()
    _ = try await e2.gui(c2.id).value
    let hangDoi = await e2.core.permissions.queue.list()
    #expect(e2.ketQua(1).contains("Chế độ Chỉ đọc") && e2.thuMucChay().isEmpty && e2.mang.requests.count == 2 && hangDoi.isEmpty)
    _ = try await e2.gui(c2.id).value
    let kq = e2.ketQua(4)
    #expect(kq.contains("[Cao] Xóa tệp bằng rm -r/-f.") && kq.contains("[Thấp] AI: Thiếu kiểm tra lỗi") && e2.thuMucChay().isEmpty)
}

@Test func aiPhanBienLoiThiVanHoiNguoiDungKemCanhBao() async throws {
    let e = try await Moi([.init(lines: goiMa("bash", "echo ok")), .init(status: 500, lines: ["{}"]), .init(lines: xong)]); defer { e.don() }
    let c = try await e.chat()
    let luot = e.gui(c.id)
    let p = try #require(await e.choDeXuat())
    #expect(p.riskReasons.contains { $0.contains("AI phản biện không chạy được") && $0.contains("tự đọc kỹ mã") })
    try await e.core.permissions.queue.approve(id: p.id)
    _ = try await luot.value
    #expect(e.ketQua(2).contains("ok"))
    // Máy thiếu trình thông dịch: báo ngay, không làm phiền người dùng duyệt thứ không chạy được.
    let e2 = try await Moi([.init(lines: goiMa("ruby", "puts 1")), .init(lines: xong)]); defer { e2.don() }
    let c2 = try await e2.chat()
    _ = try await e2.gui(c2.id).value
    let hang2 = await e2.core.permissions.queue.list()
    #expect(e2.ketQua(1).contains("PVTA chưa chạy được mã ruby") && hang2.isEmpty)
}

// MARK: Qua giao diện gọi chung

@Test func goiQuaLoiChayMaCoDuyetGiuaHaiNut() async throws {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: paths.home) }
    let dau = tam(); defer { try? FileManager.default.removeItem(at: dau) }
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([.init(lines: phanBienSach)]), retry: .none, cli: Gia().moi())
    let host = try await PVTANode.open(paths: paths, ai: ai)
    let a = try await PVTANode.open(paths: paths), b = try await PVTANode.open(paths: paths)
    _ = try await a.call("grant.add", ["path": .string(dau.path), "write": true])
    let id = try await a.call("chat.create")["id"]!.string!
    #expect(try await b.call("code.interpreters").decode(Array<Interpreter>.self).contains { $0.lang == "bash" })
    #expect(try await b.call("code.scan", ["code": "rm -rf x"]).decode(Array<CodeFinding>.self).first?.level == "high")

    let chay = Task { try await a.call("code.run", ["chatId": .string(id), "lang": "bash", "code": "echo qua-rpc", "outputDir": .string(dau.path)]) }
    var pid = ""
    for _ in 0..<300 where pid.isEmpty {
        pid = (try await b.call("action.list").decode(Array<ActionProposal>.self).first { $0.state == .pending }?.id) ?? ""
        if pid.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    }
    #expect(!pid.isEmpty)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dau.path))?.isEmpty == true)               // chờ duyệt: chưa tạo gì
    _ = try await b.call("action.approve", ["id": .string(pid)])
    let r = try await chay.value.decode(CodeResult.self)
    #expect(r.ok && r.output.contains("qua-rpc"))
    // Chỉ đọc thì code.run bị từ chối ngay.
    _ = try await b.call("permission.set", ["level": "chi-doc"])
    await #expect(throws: PVTAError.self) { try await a.call("code.run", ["chatId": .string(id), "lang": "bash", "code": "echo x", "outputDir": .string(dau.path)]) }
    await a.shutdown(); await b.shutdown(); await host.shutdown()
}
