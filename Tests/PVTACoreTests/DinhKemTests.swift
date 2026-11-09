import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
private func tep(_ name: String) -> URL { mau.appendingPathComponent(name) }
private let M = "anthropic/claude-haiku-5-5"

private func thuMuc() -> DataPaths {
    DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
}

private func tam() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Bộ chụp màn hình giả.
private final class ChupGia: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Bool
    private let huy: Bool
    private(set) var xinQuyen = 0
    private(set) var lanChup = 0
    init(coQuyen: Bool, huy: Bool = false) { cap = coQuyen; self.huy = huy }
    func hasPermission() -> Bool { cap }
    private func dem(_ xin: Bool) { lock.lock(); if xin { xinQuyen += 1 } else { lanChup += 1 }; lock.unlock() }
    func requestPermission() { dem(true) }
    func capture(mode: ScreenMode, to url: URL) async throws -> Bool {
        dem(false)
        if huy { return false }
        try Data(contentsOf: tep("anh-do.png")).write(to: url)
        return true
    }
}

private struct Moi {
    let paths = thuMuc()
    let keys = MemoryKeyStore()
    let mang: FakeTransport
    let core: Core
    let nha = tam()
    init(_ replies: [FakeTransport.Reply] = [], capturer: ScreenCapturing = ChupGia(coQuyen: true), cli: CLIEnvironment? = nil) async throws {
        mang = FakeTransport(replies)
        try keys.save("k", provider: "anthropic")
        try keys.save("k2", provider: "openai")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: cli ?? Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, capturer: capturer, screenHome: nha)
    }
    func don() { try? FileManager.default.removeItem(at: paths.home); try? FileManager.default.removeItem(at: nha) }
    func chat() async throws -> Chat { try await core.store.createChat() }
    func gui(_ id: String, _ text: String, model: String = M) async throws -> ChatTurnResult {
        try await core.chat.send(chatId: id, text: text, model: model, emit: { _, _ in })
    }
    func body(_ i: Int) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[i].httpBody ?? Data())) ?? .null }
    func raw(_ i: Int) -> String { String(decoding: mang.requests[i].httpBody ?? Data(), as: UTF8.self) }
}

private func khoi(_ tool: String, _ args: String) -> String { "```pvta-tool\n{\"tool\":\"\(tool)\",\"args\":\(args)}\n```" }

// MARK: Trích văn bản

@Test func trichVanBanTuCacLoaiTepMau() throws {
    let md = try TextExtractor.extract(tep("quy-che.md"))
    #expect(md.kind == "text" && md.text.contains("Quy tắc làm tròn"))
    #expect(try TextExtractor.extract(tep("diem.csv")).text.contains("Học sinh mẫu B,7,6.5"))
    let html = try TextExtractor.extract(tep("trang-web.html")).text
    #expect(html.contains("Họp tổ & chuyên môn") && !html.contains("<p>") && !html.contains("var x"))

    let docx = try TextExtractor.extract(tep("giao-an.docx"))
    #expect(docx.kind == "docx")
    #expect(docx.text.contains("Giáo án Toán 8") && docx.text.contains("Quy tắc nhân đơn thức & đa thức\t(tiết 12)"))
    #expect(docx.text.contains("Bước | Nội dung |") && docx.text.contains("1 | Khởi động |"))

    let xlsx = try TextExtractor.extract(tep("bang-diem.xlsx"))
    #expect(xlsx.segments.map(\.label) == ["Trang tính “Điểm lớp 8A”", "Trang tính “Tổng kết”"])
    #expect(xlsx.segments[0].text == "Họ tên\t\tXếp loại\nHọc sinh mẫu A\t9.5\tGiỏi")      // ô trống giữ đúng cột
    #expect(xlsx.segments[1].text == "Tổng\t3")                                              // công thức lấy giá trị đã tính

    let pptx = try TextExtractor.extract(tep("bai-giang.pptx"))
    #expect(pptx.segments.map(\.label) == ["Slide 1", "Slide 2"] && pptx.segments[0].text == "Hằng đẳng thức\nBình phương một tổng")

    let pdf = try TextExtractor.extract(tep("de-cuong.pdf"))
    #expect(pdf.kind == "pdf" && pdf.segments.count == 2 && pdf.text.contains("[Trang 2]") && pdf.segments[1].text.contains("nhan tu"))
}

@Test func tepKhongDocDuocBaoBangTiengViet() throws {
    let d = tam(); defer { try? FileManager.default.removeItem(at: d) }
    func thu(_ name: String, _ data: Data) throws -> String {
        let u = d.appendingPathComponent(name)
        try data.write(to: u)
        do { _ = try TextExtractor.extract(u); return "" } catch { return (error as? PVTAError)?.message ?? "?" }
    }
    #expect(try thu("cu.doc", Data("x".utf8)).contains("định dạng Office cũ"))
    #expect(try thu("chuongtrinh.exe", Data("x".utf8)).contains("chưa đọc được tệp .exe"))
    #expect(try thu("nhi-phan.txt", Data([0, 1, 2, 3])).contains("không phải tệp văn bản"))
    #expect(try thu("hong.docx", Data("không phải zip".utf8)).contains("không phải tài liệu Office hợp lệ"))
    #expect(try thu("hong.pdf", Data("không phải pdf".utf8)).contains("không phải tệp PDF hợp lệ"))
    var zipRong = Data([0x50, 0x4b, 0x05, 0x06]); zipRong.append(Data(count: 18))                // zip hợp lệ nhưng không có document.xml
    #expect(try thu("rong.docx", zipRong).contains("không phải tệp Word hợp lệ"))
}

// MARK: Đính kèm

@Test func dinhKemCacLoaiTepVaThayKhiCungTen() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let r = try await e.core.attachments.add(chatId: c.id, paths: ["giao-an.docx", "bang-diem.xlsx", "bai-giang.pptx", "de-cuong.pdf", "quy-che.md", "diem.csv"].map { tep($0).path })
    #expect(r.errors.isEmpty && r.added.map(\.kind) == Array(repeating: "file", count: 6))
    let ds = try await e.core.attachments.list(chatId: c.id)
    #expect(ds.map(\.name) == ["giao-an.docx", "bang-diem.xlsx", "bai-giang.pptx", "de-cuong.pdf", "quy-che.md", "diem.csv"])
    #expect(ds.allSatisfy { $0.chars > 0 && $0.path != nil })
    // Cùng tên thì thay, không nhân đôi.
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("giao-an.docx").path])
    #expect(try await e.core.attachments.list(chatId: c.id).count == 6)

    // Một tệp hỏng không làm hỏng cả lô.
    let d = tam(); defer { try? FileManager.default.removeItem(at: d) }
    let rong = d.appendingPathComponent("rong.txt"); try Data().write(to: rong)
    let lan = try await e.core.attachments.add(chatId: c.id, paths: [rong.path, "tuong-doi/a.txt", d.appendingPathComponent("khong-co.txt").path, tep("trang-trong.pdf").path, tep("quy-che.md").path])
    #expect(lan.errors.count == 4 && lan.added.count == 1)
    #expect(lan.errors.contains { $0.contains("không có chữ để đọc") && !$0.contains("quét") })
    #expect(lan.errors.contains { $0.contains("PDF quét ảnh") })                      // PDF quét ảnh báo rõ, không bỏ qua im lặng
    #expect(lan.errors.contains { $0.contains("Cần đường dẫn tuyệt đối") } && lan.errors.contains { $0.contains("Không tìm thấy") })
}

@Test func gioiHanSoTepLienKetTuongTrungVaThuMucGoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let d = tam(); defer { try? FileManager.default.removeItem(at: d) }
    var paths: [String] = []
    for i in 0..<61 { let u = d.appendingPathComponent("t\(i).txt"); try Data("nội dung \(i)".utf8).write(to: u); paths.append(u.path) }
    let r = try await e.core.attachments.add(chatId: c.id, paths: Array(paths.prefix(60)))
    #expect(r.added.count == 60)
    let them = try await e.core.attachments.add(chatId: c.id, paths: [paths[60]])
    #expect(them.errors.first?.contains("Đã đủ 60 tệp") == true)

    let lien = d.appendingPathComponent("lien-ket.txt")
    try FileManager.default.createSymbolicLink(at: lien, withDestinationURL: d.appendingPathComponent("t0.txt"))
    let l = try await e.core.attachments.add(chatId: c.id, paths: [lien.path])
    #expect(l.errors.first?.contains("liên kết tượng trưng") == true)
    let g = try await e.core.attachments.add(chatId: c.id, paths: ["/"])
    #expect(g.errors.first?.contains("toàn bộ ổ đĩa") == true)
    await #expect(throws: PVTAError.self) { _ = try await e.core.attachments.add(chatId: "khong-co", paths: [paths[0]]) }
}

// MARK: Ảnh

@Test func anhDuocKiemTheoNoiDungVaGioiHan() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let d = tam(); defer { try? FileManager.default.removeItem(at: d) }
    let r = try await e.core.attachments.add(chatId: c.id, paths: ["anh-do.png", "anh-gia.jpg", "anh-gia.gif", "anh-gia.webp"].map { tep($0).path })
    #expect(r.errors.isEmpty && r.added.map(\.mime) == ["image/png", "image/jpeg", "image/gif", "image/webp"])
    // Đuôi .png nhưng nội dung là chữ → từ chối; ảnh quá 5 MB → từ chối.
    let gia = d.appendingPathComponent("gia.png"); try Data("đây là chữ".utf8).write(to: gia)
    let lon = d.appendingPathComponent("lon.png"); try (Data(contentsOf: tep("anh-do.png")) + Data(count: ImageKind.maxBytes)).write(to: lon)
    let bad = try await e.core.attachments.add(chatId: c.id, paths: [gia.path, lon.path])
    #expect(bad.added.isEmpty && bad.errors.count == 2)
    #expect(bad.errors[0].contains("không phải ảnh PNG") && bad.errors[1].contains("lớn hơn 5 MB"))
    // Tối đa 6 ảnh chưa gửi.
    var more: [String] = []
    for i in 0..<3 { let u = d.appendingPathComponent("a\(i).png"); try Data(contentsOf: tep("anh-xanh.png")).write(to: u); more.append(u.path) }
    let capped = try await e.core.attachments.add(chatId: c.id, paths: more)
    #expect(capped.added.count == 2 && capped.errors.first?.contains("tối đa 6 ảnh") == true)

    // Xem lại ảnh từ bản đã lưu; gỡ ảnh thì xóa luôn tệp đã lưu.
    let anh = r.added[0]
    let img = try await e.core.attachments.image(id: anh.id)
    let goc = try Data(contentsOf: tep("anh-do.png"))
    #expect(img.mime == "image/png" && img.data == goc)
    let stored = try #require(await e.core.store.attachmentStored(id: anh.id))
    #expect(FileManager.default.fileExists(atPath: stored))
    try await e.core.attachments.remove(id: anh.id)
    #expect(!FileManager.default.fileExists(atPath: stored))
    await #expect(throws: PVTAError.self) { try await e.core.attachments.remove(id: anh.id) }
}

@Test func anhGuiKemLuotDungDinhDangCuaTungNhaCungCapVaChiGuiMotLan() async throws {
    let e = try await Moi([.init(lines: claudeSSE(["Thấy ảnh đỏ"])), .init(lines: claudeSSE(["Lượt hai"])), .init(lines: openaiOK)]); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("anh-do.png").path])
    let r = try await e.gui(c.id, "Trong ảnh có gì?")
    #expect(r.message.text == "Thấy ảnh đỏ")
    let png = try Data(contentsOf: tep("anh-do.png")).base64EncodedString()
    guard case .array(let ms)? = e.body(0)["messages"], case .array(let blocks)? = ms[0]["content"] else { Issue.record("sai cấu trúc"); return }
    #expect(blocks[0]["type"]?.string == "image" && blocks[0]["source"]?["media_type"]?.string == "image/png" && blocks[0]["source"]?["data"]?.string == png)
    #expect(blocks[1]["type"]?.string == "text" && blocks[1]["text"]?.string == "Trong ảnh có gì?")
    #expect(String(describing: e.body(0)["system"] ?? .null).contains("ẢNH GỬI KÈM LƯỢT NÀY: anh-do.png"))
    #expect(try await e.core.attachments.list(chatId: c.id).first?.sent == true)
    // Lượt sau không gửi lại ảnh cũ.
    _ = try await e.gui(c.id, "Còn gì nữa?")
    #expect(!e.raw(1).contains(png))
    // OpenAI: ảnh ở dạng image_url.
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("anh-xanh.png").path])
    _ = try await e.gui(c.id, "Ảnh mới?", model: "openai/gpt-5.5")
    guard case .array(let ms2)? = e.body(2)["messages"], case .array(let parts)? = ms2.last?["content"] else { Issue.record("sai cấu trúc OpenAI"); return }
    #expect(parts[1]["type"]?.string == "image_url" && parts[1]["image_url"]?["url"]?.string?.hasPrefix("data:image/png;base64,") == true)
    #expect(parts[0]["text"]?.string == "Ảnh mới?")
}

@Test func lanLoiGiuAnhChoLanSauVaModelKhongNhanAnhBiTuChoi() async throws {
    let e = try await Moi([.init(status: 500, lines: ["{}"]), .init(lines: claudeSSE(["Ổn rồi"]))]); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("anh-do.png").path])
    let hong = try await e.gui(c.id, "Xem ảnh")
    #expect(hong.message.error != nil)
    #expect(try await e.core.attachments.list(chatId: c.id).first?.sent == false)       // lượt lỗi thì ảnh chưa coi là đã gửi
    let ok = try await e.gui(c.id, "Thử lại")
    #expect(ok.message.text == "Ổn rồi" && e.raw(1).contains("\"image\""))

    // Chọn thẳng công cụ không nhận ảnh: báo rõ, không âm thầm bỏ ảnh.
    let g = Gia(); claude(g)
    let e2 = try await Moi([], cli: g.moi()); defer { e2.don() }
    let c2 = try await e2.chat()
    _ = try await e2.core.attachments.add(chatId: c2.id, paths: [tep("anh-do.png").path])
    let r2 = try await e2.gui(c2.id, "Xem ảnh", model: "claude/sonnet")
    #expect(r2.message.error?.contains("chưa nhận ảnh") == true)
    #expect(g.doc("claude.args").isEmpty)                                                // chưa chạy công cụ
}

@Test func tuDongChonNguonNhanAnhVaCodexNhanAnhQuaTepTam() async throws {
    let g = Gia()
    claude(g)
    g.viet("codex", """
    case "$1" in --version) echo "codex-cli 1"; exit 0;; login) exit 0;; app-server) exit 1;; esac
    printf '%s\\n' "$@" > "$FAKE_DIR/codex.args"
    cat > /dev/null
    img=""; while [ $# -gt 0 ]; do [ "$1" = "--image" ] && img="$2"; shift; done
    cp "$img" "$FAKE_DIR/codex.img" 2>/dev/null; echo "$img" > "$FAKE_DIR/codex.imgpath"
    echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"Codex thấy ảnh"}}'
    """)
    let e = try await Moi([.init(lines: claudeSSE(["API"]))], cli: g.moi()); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("anh-do.png").path])
    // Tự động: claude đứng trước API nhưng không nhận ảnh nên bị bỏ qua; codex đứng trước API và nhận ảnh.
    let r = try await e.gui(c.id, "Mô tả ảnh", model: "auto")
    #expect(r.message.text == "Codex thấy ảnh" && r.message.model?.hasPrefix("codex/") == true)
    #expect(g.doc("codex.args").contains("--image"))
    let truyen = g.doc("codex.imgpath").trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(truyen.contains("/.anh-") && truyen.hasSuffix(".png"))
    let goc = try Data(contentsOf: tep("anh-do.png"))
    #expect((try? Data(contentsOf: g.dir.appendingPathComponent("codex.img"))) == goc)   // tệp tạm có đúng nội dung
    #expect(!FileManager.default.fileExists(atPath: truyen))                                    // và đã bị xóa sau lượt
    #expect(e.mang.requests.isEmpty)
}

// MARK: Công cụ đọc tệp đính kèm và phạm vi quyền đọc

@Test func modelDocVaTimTrongTepDaDinhKemKhongPhanBietDau() async throws {
    let e = try await Moi([
        .init(lines: claudeSSE([khoi("file_search", #"{"query":"quy tac lam tron"}"#) + "\n" + khoi("file_read", #"{"name":"quy-che","start":0,"length":30}"#) + "\n" + khoi("pdf_pages", #"{"name":"de-cuong.pdf","from":2}"#) + "\n" + khoi("file_list", "{}")])),
        .init(lines: claudeSSE(["Xong"])),
    ]); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("quy-che.md").path, tep("de-cuong.pdf").path])
    _ = try await e.gui(c.id, "Tìm quy tắc làm tròn")
    let sys = String(describing: e.body(0)["system"] ?? .null)
    #expect(sys.contains("file_read") && sys.contains("quy-che.md") && sys.contains("Nội dung quy-che.md"))      // tệp nhỏ được đưa thẳng vào lời nhắc
    guard case .array(let ms)? = e.body(1)["messages"], let kq = ms.last?["content"]?.string else { Issue.record("thiếu kết quả"); return }
    #expect(kq.contains("quy-che.md @") && kq.contains("Quy tắc làm tròn"))                                       // "quy tac" tìm ra "Quy tắc"
    #expect(kq.contains("Tệp: quy-che.md — ký tự 0–30") && kq.contains("đọc tiếp từ start=30"))
    #expect(kq.contains("trang 2–2 / 2") && kq.contains("Phan tich da thuc"))
    #expect(kq.contains("- de-cuong.pdf"))
}

@Test func khongCoTepDinhKemThiKhongCoCongCuTep() async throws {
    let e = try await Moi([.init(lines: claudeSSE(["Ok"]))]); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.gui(c.id, "Chào")
    let sys = String(describing: e.body(0)["system"] ?? .null)
    #expect(!sys.contains("file_read") && !sys.contains("TỆP ĐÍNH KÈM"))
}

@Test func duongDanTrongCauHoiKhongPhaiLaQuyenDoc() async throws {
    let bi = tam(); defer { try? FileManager.default.removeItem(at: bi) }
    let mat = bi.appendingPathComponent("bi-mat.docx")
    try FileManager.default.copyItem(at: tep("giao-an.docx"), to: mat)
    let e = try await Moi([.init(lines: claudeSSE([khoi("file_read", "{\"name\":\"\(mat.path)\"}") + "\n" + khoi("file_read", #"{"name":"bi-mat.docx"}"#) + "\n" + khoi("file_read", "{\"name\":\"../../etc/passwd\"}")])),
                           .init(lines: claudeSSE(["Không đọc được"]))]); defer { e.don() }
    let c = try await e.chat()
    _ = try await e.core.attachments.add(chatId: c.id, paths: [tep("quy-che.md").path])
    let cau = "Đọc giúp mình tệp \(mat.path) nhé"
    let bc = try await e.core.attachments.contextReport(chatId: c.id, text: cau)
    #expect(bc.mentionedNotAttached == [mat.path] && bc.inContext.map(\.name) == ["quy-che.md"])
    _ = try await e.gui(c.id, cau)
    // Lời nhắc báo rõ cho model rằng đường dẫn chưa được cấp quyền.
    let sys = String(describing: e.body(0)["system"] ?? .null)
    #expect(sys.contains("CHƯA được đính kèm") && sys.contains(mat.path))
    // Dù đường dẫn có thật và được nhắc tới, công cụ đọc tệp vẫn từ chối mọi cách gọi.
    guard case .array(let ms)? = e.body(1)["messages"], let kq = ms.last?["content"]?.string else { Issue.record("thiếu kết quả"); return }
    #expect(kq.components(separatedBy: "Không có tệp").count == 4)                    // 3 lời gọi, cả 3 bị từ chối
    #expect(!kq.contains("Giáo án Toán 8"))
    // Phạm vi phân giải cũng từ chối đường dẫn ngoài những gì đã cấp.
    await #expect(throws: PVTAError.self) { _ = try await e.core.attachments.resolve(chatId: c.id, ref: mat.path) }
    await #expect(throws: PVTAError.self) { _ = try await e.core.attachments.resolve(chatId: c.id, ref: "/etc/hosts") }
    // Đính kèm rồi thì không còn nằm trong danh sách "chưa cấp".
    _ = try await e.core.attachments.add(chatId: c.id, paths: [mat.path])
    #expect(try await e.core.attachments.contextReport(chatId: c.id, text: cau).mentionedNotAttached.isEmpty)
}

@Test func modelKhongDocDuocTepCuaHoiThoaiKhac() async throws {
    let e = try await Moi([.init(lines: claudeSSE([khoi("file_read", #"{"name":"diem.csv","chatId":"CHAT-KHAC"}"#)])), .init(lines: claudeSSE(["Ok"]))]); defer { e.don() }
    let a = try await e.chat(), b = try await e.chat()
    _ = try await e.core.attachments.add(chatId: a.id, paths: [tep("quy-che.md").path])
    _ = try await e.core.attachments.add(chatId: b.id, paths: [tep("diem.csv").path])
    _ = try await e.gui(a.id, "Đọc diem.csv")
    guard case .array(let ms)? = e.body(1)["messages"], let kq = ms.last?["content"]?.string else { Issue.record("thiếu kết quả"); return }
    #expect(kq.contains("Không có tệp") && !kq.contains("Học sinh mẫu"))               // model tự điền chatId cũng không đổi được hội thoại
}

// MARK: Chọn nguồn bằng $ và $$

@Test func chonNguonBangDoLaVaHaiDoLaKhongPhanBietDau() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let goc = tam(); defer { try? FileManager.default.removeItem(at: goc) }
    let fm = FileManager.default
    func tao(_ rel: String, _ nd: String = "x") throws {
        let u = goc.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(nd.utf8).write(to: u)
    }
    try tao("Tuần 1/phiếu bài tập.txt")
    for rel in ["Tuần 1/Giáo án Toán.docx", "Tuần 2/Giáo án Văn.docx"] {
        let u = goc.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: tep("giao-an.docx"), to: u)
    }; try tao(".an/giao an an.txt")
    try tao("a/b/c/d/e/f/g/h/i/qua-sau.txt")                              // sâu hơn 8 cấp
    try fm.createSymbolicLink(at: goc.appendingPathComponent("lk"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    let r = try await e.core.attachments.add(chatId: c.id, paths: [goc.path, tep("quy-che.md").path])
    #expect(r.errors.isEmpty && r.added.first?.kind == "folder")

    let files = try await e.core.attachments.sourceSearch(chatId: c.id, kind: "file", query: "giao an")
    #expect(files.map(\.name) == ["Giáo án Toán.docx", "Giáo án Văn.docx"] && files.allSatisfy { $0.source == "folder" && !$0.inContext })
    #expect(try await e.core.attachments.sourceSearch(chatId: c.id, kind: "file", query: "quy che").first?.source == "attachment")
    let dirs = try await e.core.attachments.sourceSearch(chatId: c.id, kind: "dir", query: "tuan")
    #expect(dirs.map(\.name) == ["Tuần 1", "Tuần 2"] && dirs.allSatisfy { $0.kind == "dir" })
    // Chọn thư mục rồi gõ $ để giới hạn tệp trong thư mục đó.
    let trongTuan1 = try await e.core.attachments.sourceSearch(chatId: c.id, kind: "file", query: "", folder: dirs[0].path)
    #expect(Set(trongTuan1.map(\.name)) == ["Giáo án Toán.docx", "phiếu bài tập.txt"])
    // Không thấy mục ẩn, mục quá sâu và tệp qua liên kết tượng trưng.
    let tatCa = try await e.core.attachments.sourceSearch(chatId: c.id, kind: "file", query: "")
    #expect(!tatCa.contains { $0.name.contains("an an") || $0.name == "qua-sau.txt" || $0.path.contains("/lk/") })
    // Đính kèm một tệp trong thư mục thì được đánh dấu đã nằm trong ngữ cảnh.
    let them = try await e.core.attachments.add(chatId: c.id, paths: [files[0].path])
    #expect(them.errors.isEmpty)
    #expect(try await e.core.attachments.sourceSearch(chatId: c.id, kind: "file", query: "giao an toan").first { $0.source == "folder" }?.inContext == true)
    let cay = try await e.core.attachments.sourceTree(chatId: c.id)
    #expect(cay.count == 1 && cay[0]["root"]?.string == goc.path)

    let kinds = AttachmentService.pathKinds([goc.path, tep("quy-che.md").path, "/khong/co", "tuong-doi", goc.appendingPathComponent("lk").path])
    #expect(kinds.dirs == [goc.path] && kinds.files == [tep("quy-che.md").path])
}

@Test func xemNhanhChiTrongPhamViDaCap() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let goc = tam(); defer { try? FileManager.default.removeItem(at: goc) }
    try FileManager.default.copyItem(at: tep("bai-giang.pptx"), to: goc.appendingPathComponent("bai-giang.pptx"))
    try FileManager.default.copyItem(at: tep("anh-do.png"), to: goc.appendingPathComponent("anh-do.png"))
    try Data(count: 100).write(to: goc.appendingPathComponent("nhac.mp3"))
    try Data(count: 100).write(to: goc.appendingPathComponent("lon.png"))
    let ngoai = tam(); defer { try? FileManager.default.removeItem(at: ngoai) }
    try Data("bí mật".utf8).write(to: ngoai.appendingPathComponent("bi-mat.txt"))
    try FileManager.default.createSymbolicLink(at: goc.appendingPathComponent("loi-thoat.txt"), withDestinationURL: ngoai.appendingPathComponent("bi-mat.txt"))
    _ = try await e.core.attachments.add(chatId: c.id, paths: [goc.path, tep("quy-che.md").path])

    let p = try await e.core.attachments.quickPreview(chatId: c.id, ref: "bai-giang.pptx")             // tương đối trong thư mục nguồn
    #expect(p.kind == "pptx" && p.segments.map(\.label) == ["Slide 1", "Slide 2"])
    #expect(try await e.core.attachments.quickPreview(chatId: c.id, ref: "quy-che.md").segments.first?.text.contains("Quy chế mẫu") == true)
    let anh = try await e.core.attachments.quickPreview(chatId: c.id, ref: goc.appendingPathComponent("anh-do.png").path)
    #expect(anh.kind == "image" && anh.data?.hasPrefix("data:image/png;base64,") == true)
    #expect(try await e.core.attachments.previewRef(chatId: c.id, ref: "anh-do.png").data != nil)
    await #expect(throws: PVTAError.self) { _ = try await e.core.attachments.previewRef(chatId: c.id, ref: "bai-giang.pptx") }   // không phải ảnh
    let nhac = try await e.core.attachments.mediaPreview(chatId: c.id, ref: "nhac.mp3")
    #expect(nhac.kind == "audio" && nhac.data?.hasPrefix("data:audio/mpeg;base64,") == true)
    await #expect(throws: PVTAError.self) { _ = try await e.core.attachments.mediaPreview(chatId: c.id, ref: "bai-giang.pptx") }
    // Ngoài phạm vi: đường dẫn lạ, thoát bằng .. hoặc liên kết tượng trưng.
    for ref in [ngoai.appendingPathComponent("bi-mat.txt").path, "../\(ngoai.lastPathComponent)/bi-mat.txt", "loi-thoat.txt", "/etc/hosts"] {
        await #expect(throws: PVTAError.self, "\(ref)") { _ = try await e.core.attachments.quickPreview(chatId: c.id, ref: ref) }
    }
}

// MARK: Chụp màn hình

@Test func chupManHinhBiTuChoiQuyenThiBaoRoVaKhongTaoTep() async throws {
    let chup = ChupGia(coQuyen: false)
    let e = try await Moi(capturer: chup); defer { e.don() }
    do { _ = try await e.core.screen.capture(mode: .selection); Issue.record("phải báo lỗi") } catch let err as PVTAError {
        #expect(err.message.contains("Ghi màn hình") && err.message.contains("Quyền riêng tư & Bảo mật") && err.message.contains("⇧⌘4"))
    }
    #expect(chup.lanChup == 0 && chup.xinQuyen == 0)
    #expect(!FileManager.default.fileExists(atPath: e.paths.home.appendingPathComponent("captures").path))
    _ = try? await e.core.screen.capture(mode: .screen, requestPermission: true)            // chỉ xin quyền khi người dùng yêu cầu
    #expect(chup.xinQuyen == 1 && chup.lanChup == 0)
}

@Test func chupRoiChonNoiNhanAnhLaHoiThoaiHoacThuMuc() async throws {
    let e = try await Moi(); defer { e.don() }
    let c = try await e.chat()
    let cap = try await e.core.screen.capture(mode: .selection)
    #expect(!cap.cancelled && cap.name.hasPrefix("chup-man-hinh-") && cap.bytes > 0)
    let attrs = try FileManager.default.attributesOfItem(atPath: e.paths.home.appendingPathComponent("captures").path)
    #expect((attrs[.posixPermissions] as? Int) == 0o700)

    let vao = try await e.core.screen.deliver(captureId: cap.id, chatId: c.id)
    #expect(vao["to"]?.string == "chat")
    let ds = try await e.core.attachments.list(chatId: c.id)
    #expect(ds.count == 1 && ds[0].kind == "image" && ds[0].sent == false)

    let thuMucNhan = tam(); defer { try? FileManager.default.removeItem(at: thuMucNhan) }
    let ra = try await e.core.screen.deliver(captureId: cap.id, folder: thuMucNhan.path)
    #expect(FileManager.default.fileExists(atPath: ra["path"]?.string ?? ""))
    await #expect(throws: PVTAError.self) { _ = try await e.core.screen.deliver(captureId: cap.id, folder: thuMucNhan.path) }   // không ghi đè
    await #expect(throws: PVTAError.self) { _ = try await e.core.screen.deliver(captureId: cap.id) }                              // phải chọn nơi nhận
    await #expect(throws: PVTAError.self) { _ = try await e.core.screen.deliver(captureId: cap.id, folder: "tuong-doi") }
    await #expect(throws: PVTAError.self) { _ = try await e.core.screen.deliver(captureId: "../../etc/passwd", folder: thuMucNhan.path) }
    let lk = tam().appendingPathComponent("lk"); try FileManager.default.createSymbolicLink(at: lk, withDestinationURL: thuMucNhan)
    await #expect(throws: PVTAError.self) { _ = try await e.core.screen.deliver(captureId: cap.id, folder: lk.path) }

    // Người dùng hủy vùng chọn: không có ảnh.
    let huy = try await Moi(capturer: ChupGia(coQuyen: true, huy: true)); defer { huy.don() }
    #expect(try await huy.core.screen.capture(mode: .selection).cancelled)
}

@Test func anhDanVaTimAnhChupMoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let png = try Data(contentsOf: tep("anh-do.png")).base64EncodedString()
    let ok = try e.core.screen.paste(dataURL: "data:image/png;base64,\(png)")
    #expect(ok.name.hasPrefix("anh-dan-") && ok.name.hasSuffix(".png"))
    for sai in ["data:text/plain;base64,aGk=", "data:image/png;base64,@@@", "data:image/png;base64,\(Data("không phải ảnh, chỉ là chữ khá dài để qua ngưỡng".utf8).base64EncodedString())"] {
        #expect(throws: PVTAError.self) { _ = try e.core.screen.paste(dataURL: sai) }
    }

    let truoc = Date().addingTimeInterval(-60)
    let desk = e.nha.appendingPathComponent("Desktop"); try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
    let anh = try Data(contentsOf: tep("anh-do.png"))
    try anh.write(to: desk.appendingPathComponent("Screenshot 2026-11-09 at 10.00.00.png"))
    try anh.write(to: desk.appendingPathComponent("Ảnh chụp màn hình 2026-11-09.png"))
    try anh.write(to: desk.appendingPathComponent("anh-gia-dinh.png"))                                     // ảnh thường, không phải ảnh chụp
    let cu = desk.appendingPathComponent("Screenshot cu.png"); try anh.write(to: cu)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: cu.path)
    let r = e.core.screen.scan(since: truoc)
    #expect(Set(r.files.map(\.name)) == ["Screenshot 2026-11-09 at 10.00.00.png", "Ảnh chụp màn hình 2026-11-09.png", ok.name])
    #expect(!r.files.contains { $0.name == "anh-gia-dinh.png" || $0.name == "Screenshot cu.png" })
    let thay = e.core.screen.scan(since: truoc, seen: Set(r.files.map(\.path)))
    #expect(thay.files.isEmpty)

    // Thư mục bị hệ điều hành chặn đọc thì được báo, không bỏ qua im lặng.
    let chan = try await Moi(); defer { chan.don() }
    let d2 = chan.nha.appendingPathComponent("Desktop"); try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: d2.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d2.path) }
    #expect(chan.core.screen.scan(since: truoc).denied.contains(d2.path))
}

// MARK: Qua giao diện gọi chung

@Test func goiQuaLoiDinhKemChupVaChonNguon() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: Gia().moi())
    let host = try await PVTANode.open(paths: paths, ai: ai, capturer: ChupGia(coQuyen: false))
    let client = try await PVTANode.open(paths: paths)
    let id = try await client.call("chat.create")["id"]!.string!

    let r = try await client.call("attachment.add", ["chatId": .string(id), "paths": [.string(tep("giao-an.docx").path), .string(tep("anh-do.png").path), "tuong-doi.txt"]])
    #expect(try r.decode(AttachResult.self).added.count == 2 && r["errors"] != nil)
    let ds = try await client.call("attachment.list", ["chatId": .string(id)]).decode(Array<PVTACore.Attachment>.self)
    #expect(ds.map(\.kind) == ["file", "image"])
    #expect(try await client.call("attachment.image", ["id": .string(ds[1].id)])["data"]?.string?.hasPrefix("data:image/png;base64,") == true)
    let kq = try await client.call("file.extractText", ["path": .string(tep("de-cuong.pdf").path)])
    #expect(kq["kind"]?.string == "pdf")
    #expect(try await client.call("file.pathKinds", ["paths": [.string(tep("giao-an.docx").path)]])["files"] != nil)
    #expect(try await client.call("file.resolveRef", ["chatId": .string(id), "ref": "giao-an.docx"])["attached"]?.bool == true)
    #expect(try await client.call("attachment.context", ["chatId": .string(id), "text": "mở /tmp/chua-dinh-kem.docx"])["mentionedNotAttached"] != nil)

    do { _ = try await client.call("screen.capture", ["mode": "screen"]); Issue.record("phải báo lỗi quyền") } catch let e as PVTAError {
        #expect(e.message.contains("Ghi màn hình"))
    }
    // Xóa hội thoại dọn luôn ảnh đã lưu.
    let dir = paths.home.appendingPathComponent("attachments/\(id)")
    #expect(FileManager.default.fileExists(atPath: dir.path))
    _ = try await client.call("chat.delete", ["id": .string(id)])
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    #expect(try await client.call("source.search", ["chatId": .string(id), "kind": "file"]).decode([SourceHit].self).isEmpty)
    await client.shutdown(); await host.shutdown()
}
