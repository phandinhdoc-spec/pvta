import Foundation
import CoreText
import CoreGraphics
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private final class MangGia: @unchecked Sendable {
    struct Route { var status = 200; var headers: [String: String] = [:]; var body = Data(); var fail = false }
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var log: [(url: String, limit: Int)] = []
    func set(_ url: String, _ r: Route) { lock.lock(); routes[url] = r; lock.unlock() }
    func remove(_ url: String) { lock.lock(); routes[url] = nil; lock.unlock() }
    var calls: [(url: String, limit: Int)] { lock.lock(); defer { lock.unlock() }; return log }
    func get(_ url: URL, _ limit: Int) throws -> (status: Int, headers: [String: String], body: Data) {
        lock.lock(); defer { lock.unlock() }
        log.append((url.absoluteString, limit))
        guard let r = routes[url.absoluteString], !r.fail else { throw URLError(.notConnectedToInternet) }
        return (r.status, r.headers, r.body)
    }
}

private final class DongHo: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ d: Date) { t = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private final class MayHoi: @unchecked Sendable {
    private let lock = NSLock()
    private var systems: [String] = [], users: [String] = []
    var fail = false
    func record(_ s: String, _ u: String) { lock.lock(); systems.append(s); users.append(u); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return systems.count }
    var lastSystem: String { lock.lock(); defer { lock.unlock() }; return systems.last ?? "" }
    var lastUser: String { lock.lock(); defer { lock.unlock() }; return users.last ?? "" }
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("d-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let core: Core
    let mang = MangGia()
    let ho = DongHo(Date(timeIntervalSince1970: 1_790_000_000))     // ~ 2026-09
    let hoi = MayHoi()
    let docs: GroupDocs

    init() async throws {
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: Gia().moi())
        try paths.prepare()
        let c = Core(store: try DataStore(file: paths.database), ai: ai)
        core = c
        let mang = self.mang, ho = self.ho, hoi = self.hoi
        docs = GroupDocs(store: c.store, groups: c.groups, home: paths.home, fetch: { url, limit in try mang.get(url, limit) },
                         ask: { s, u in
                             hoi.record(s, u)
                             if hoi.fail { throw URLError(.notConnectedToInternet) }
                             return "**Hiệu lực**: văn bản không nêu\n**Nội dung chính**: bản tóm tắt thử lần \(hoi.count)"
                         }, now: { ho.now })
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
}

private func pdfVanBan(_ lines: [String]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Arial" as CFString, 11, nil)
    var y = 800.0
    for l in lines {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        ctx.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(line, ctx)
        y -= 16
    }
    ctx.endPDFPage(); ctx.closePDF()
    return data as Data
}

private let moetFeed = """
    <?xml version="1.0"?><rss version="2.0"><channel>
    <item><title>Công văn 1234/BGDĐT-GDTrH hướng dẫn kiểm tra giáo viên &amp; giảng dạy</title><link>https://moet.gov.vn/vb/cv-1234.pdf</link></item>
    <item><title><![CDATA[Thông tư 99/2024/TT-BGDĐT về giáo dục giáo viên]]></title><link>https://moet.gov.vn/vb/tt-99.pdf</link></item>
    <item><title>Tin thể thao cuối tuần</title><link>https://moet.gov.vn/tin/the-thao</link></item>
    <item><title>Hướng dẫn giáo viên theo thông tin trên mạng xã hội</title><link>https://facebook.com/xyz</link></item>
    </channel></rss>
    """

private func taoNguon(_ e: Moi, url: String = "https://moet.gov.vn/rss.xml", kind: String = "feed", body: String = moetFeed) async throws -> DiscoverySource {
    e.mang.set(url, .init(body: Data(body.utf8)))
    return try await e.docs.addSource(name: "Bộ GDĐT", url: url, kind: kind, groups: ["giao-vien"])
}

private func vanBan(_ e: Moi, title: String, no: String, replaces: String? = nil, amends: String? = nil, partial: String? = nil, effective: String = "01 tháng 1 năm 2025",
                    host: String = "https://moet.gov.vn/vb/", name: String = "tt") async throws -> DocRecord {
    var lines = ["BỘ GIÁO DỤC VÀ ĐÀO TẠO", "Số: \(no)", "Hà Nội, ngày 15 tháng 6 năm 2024", title, "Điều 1. Phạm vi điều chỉnh", "1. Thông tư này quy định về việc kiểm tra giáo viên.", "Điều 2. Đối tượng áp dụng", "1. Giáo viên trung học cơ sở.", "2. Cán bộ quản lý."]
    if let replaces { lines.append("Điều 3. Điều khoản thi hành: Thông tư này thay thế Thông tư \(replaces).") }
    if let amends { lines.append("Điều 4. Sửa đổi, bổ sung một số nội dung của Thông tư \(amends).") }
    if let partial { lines.append("Điều 5. Thay thế khoản 2 Điều 5 của Thông tư \(partial).") }
    lines.append("Thông tư này có hiệu lực từ ngày \(effective).")
    let url = host + name + ".pdf"
    e.mang.set(url, .init(body: pdfVanBan(lines)))
    let d = try await e.docs.addDocument(group: "giao-vien", title: title, url: url, no: nil)
    return try await e.docs.download(id: d.id)
}

// MARK: Đọc nguồn tin

@Test func docNguonRssAtomVaTrangDanhMuc() {
    let items = GroupDocs.parseFeed(moetFeed)
    #expect(items.count == 4 && items[0].title == "Công văn 1234/BGDĐT-GDTrH hướng dẫn kiểm tra giáo viên & giảng dạy" && items[1].title.hasPrefix("Thông tư 99/2024"))
    let atom = #"<feed><entry><title>Quyết định 05/QĐ-THCS về kế hoạch năm học</title><link href="https://x.edu.vn/a?b=1&amp;c=2"/></entry></feed>"#
    #expect(GroupDocs.parseFeed(atom).first?.url == "https://x.edu.vn/a?b=1&c=2")
    let html = #"<a href="/vb/1.pdf">Công văn hướng dẫn thực hiện nhiệm vụ năm học mới</a><a href="/lien-he">Liên hệ</a><a href="https://other.vn/x.pdf">Thông báo về lịch kiểm tra học kỳ</a>"#
    let rows = GroupDocs.parsePage(html, base: URL(string: "https://moet.gov.vn/van-ban")!)
    #expect(rows.map(\.url) == ["https://moet.gov.vn/vb/1.pdf", "https://other.vn/x.pdf"])
}

@Test func nguonTheoDoiChiNhanGovEduHttpsCongKhai() async throws {
    let e = try await Moi(); defer { e.don() }
    for bad in ["http://moet.gov.vn/x", "https://example.com/x", "https://127.0.0.1/x", "https://user:pw@moet.gov.vn/x", "https://moet.gov.vn:8443/x", "https://localhost/x", "khong-phai-url"] {
        await #expect(throws: PVTAError.self, "\(bad)") { try await e.docs.addSource(name: "x", url: bad) }
    }
    let s = try await e.docs.addSource(name: "Sở", url: "https://hcm.edu.vn/")
    await #expect(throws: PVTAError.self) { try await e.docs.addSource(name: "Sở", url: "https://hcm.edu.vn/") }          // trùng
    #expect(try await e.docs.sources().count == 1)
    try await e.docs.removeSource(s.id)
    await #expect(throws: PVTAError.self) { try await e.docs.removeSource(s.id) }
}

// MARK: Tìm văn bản mới

@Test func timVanBanMoiLocTheoTuKhoaVaMienTinCay() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await taoNguon(e)
    let r = try await e.docs.discover(group: "giao-vien")
    #expect(r.errors.isEmpty && r.checked == 1 && r.skipped == nil)
    #expect(r.added.map(\.url) == ["https://moet.gov.vn/vb/cv-1234.pdf", "https://moet.gov.vn/vb/tt-99.pdf"])     // bỏ tin thể thao, bỏ facebook
    #expect(r.added.allSatisfy { $0.isNew && $0.state == .chuaTai && $0.source == "tim-moi" } && r.added[0].no == "1234/BGDĐT-GDTrH")
    #expect(e.mang.calls.count == 1)                                                                                // chỉ tải trang nguồn, chưa tải văn bản
    // Chưa đủ 24 giờ thì bỏ qua; ép chạy thì không thêm trùng.
    let again = try await e.docs.discover(group: "giao-vien")
    #expect(again.skipped == "recent" && again.added.isEmpty)
    let forced = try await e.docs.discover(group: "giao-vien", force: true)
    #expect(forced.added.isEmpty && forced.skipped == nil)
    e.ho.advance(25 * 3600)
    #expect(try await e.docs.discover(group: "giao-vien").skipped == nil)
    #expect(try await e.docs.documents(group: "giao-vien").count == 2)
    let rp = try await e.docs.reports()
    #expect(rp.first?.group == "giao-vien" && rp.count >= 2)
}

@Test func timVanBanBoQuaKhiNgoaiTuyenNhomCongCuHoacKhongCoNguon() async throws {
    let e = try await Moi(); defer { e.don() }
    #expect(try await e.docs.discover(group: "giao-vien").skipped == "no-source")
    #expect(try await e.docs.discover(group: "excel", force: true).skipped == "no-source")
    _ = try await taoNguon(e)
    try await e.docs.setOffline(true)
    let r = try await e.docs.discover(group: "giao-vien", force: true)
    #expect(r.skipped == "offline" && e.mang.calls.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.docs.discover(group: "khong-co") }
}

@Test func mangLoiThiBaoLoiTungNguonVaGiuVanBanDaCo() async throws {
    let e = try await Moi(); defer { e.don() }
    let s = try await taoNguon(e)
    let ok = try await e.docs.discover(group: "giao-vien")
    #expect(ok.added.count == 2)
    e.mang.set("https://moet.gov.vn/rss.xml", .init(fail: true))
    let r = try await e.docs.discover(group: "giao-vien", force: true)
    #expect(r.added.isEmpty && r.errors.count == 1 && r.errors[0].contains("Bộ GDĐT") && r.errors[0].contains("Không tải được"))
    let saved = try await e.docs.sources().first { $0.id == s.id }
    #expect(saved?.lastError != nil)
    #expect(try await e.docs.documents(group: "giao-vien").count == 2)           // văn bản đã có vẫn còn
    e.mang.set("https://moet.gov.vn/rss.xml", .init(status: 503))
    #expect(try await e.docs.discover(group: "giao-vien", force: true).errors[0].contains("503"))
}

// MARK: Tải về kho

@Test func taiVanBanVeKhoDocDuocSoHieuNgayVaQuanHe() async throws {
    let e = try await Moi(); defer { e.don() }
    let d = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT về kiểm tra giáo viên", no: "99/2024/TT-BGDĐT", replaces: "50/2020/TT-BGDĐT", effective: "01 tháng 1 năm 2099")
    #expect(d.state == .daTai && d.hash != nil && d.no == "99/2024/TT-BGDĐT" && d.issuedAt == "2024-06-15" && d.effectiveAt == "2099-01-01")
    #expect(d.replaces == ["50/2020/TT-BGDĐT"] && d.status == .sapCoHieuLuc)                    // hiệu lực ở tương lai
    let t = await e.docs.text(of: d)
    #expect(t?.contains("Đối tượng áp dụng") == true && t?.contains("Điều 2") == true)
    #expect(FileManager.default.fileExists(atPath: e.paths.home.appendingPathComponent("groups/giao-vien/kho/\(d.hash!).pdf").path))
    #expect(e.mang.calls.last?.limit == 25 * 1024 * 1024)
}

@Test func taiVeTuChoiNguonLaTrangWebHoacNguonKhongCon() async throws {
    let e = try await Moi(); defer { e.don() }
    e.mang.set("https://moet.gov.vn/web", .init(body: Data("<html>trang web</html>".utf8)))
    e.mang.set("https://moet.gov.vn/mat", .init(status: 404))
    e.mang.set("https://moet.gov.vn/loi", .init(status: 500))
    let web = try await e.docs.addDocument(group: "giao-vien", title: "Trang web", url: "https://moet.gov.vn/web", no: nil)
    do { _ = try await e.docs.download(id: web.id); Issue.record("phải từ chối") } catch let x as PVTAError { #expect(x.message.contains("không phải tệp PDF hoặc Word")) }
    let mat = try await e.docs.addDocument(group: "giao-vien", title: "Mất", url: "https://moet.gov.vn/mat", no: nil)
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: mat.id) }
    #expect(try await e.core.store.doc(id: mat.id)?.state == .nguonKhongCon)
    let loi = try await e.docs.addDocument(group: "giao-vien", title: "Lỗi", url: "https://moet.gov.vn/loi", no: nil)
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: loi.id) }
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: "khong-co") }
    let khongLink = try await e.docs.addDocument(group: "giao-vien", title: "Chưa có link", url: nil, no: nil)
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: khongLink.id) }
}

@Test func nguonNgoaiDanhSachCanXacNhanVaChuyenHuongBiKiemTraLai() async throws {
    let e = try await Moi(); defer { e.don() }
    let pdf = pdfVanBan(["Thông báo 7/TB-THCS", "Điều 1. Nội dung"])
    e.mang.set("https://tailieu.example.org/a.pdf", .init(body: pdf))
    let ngoai = try await e.docs.addDocument(group: "giao-vien", title: "Tài liệu ngoài", url: "https://tailieu.example.org/a.pdf", no: nil)
    do { _ = try await e.docs.download(id: ngoai.id); Issue.record("phải hỏi xác nhận") } catch let x as PVTAError { #expect(x.message.contains("không nằm trong danh sách tin cậy")) }
    #expect(e.mang.calls.isEmpty)
    #expect(try await e.docs.download(id: ngoai.id, confirmed: true).state == .daTai)
    // Chuyển hướng sang nguồn lạ hoặc địa chỉ IP bị chặn.
    e.mang.set("https://moet.gov.vn/cv1", .init(status: 302, headers: ["Location": "https://doc-hai.example.net/x.pdf"]))
    let c1 = try await e.docs.addDocument(group: "giao-vien", title: "Chuyển hướng 1", url: "https://moet.gov.vn/cv1", no: nil)
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: c1.id) }
    e.mang.set("https://moet.gov.vn/cv2", .init(status: 302, headers: ["Location": "https://192.168.1.5/x.pdf"]))
    let c2 = try await e.docs.addDocument(group: "giao-vien", title: "Chuyển hướng 2", url: "https://moet.gov.vn/cv2", no: nil)
    await #expect(throws: PVTAError.self) { try await e.docs.download(id: c2.id, confirmed: true) }
    e.mang.set("https://moet.gov.vn/cv3", .init(status: 302, headers: ["Location": "https://chinhphu.gov.vn/ok.pdf"]))
    e.mang.set("https://chinhphu.gov.vn/ok.pdf", .init(body: pdf))
    let c3 = try await e.docs.addDocument(group: "giao-vien", title: "Chuyển hướng 3", url: "https://moet.gov.vn/cv3", no: nil)
    #expect(try await e.docs.download(id: c3.id).state == .daTai)
}

@Test func pdfQuetAnhChuaCoChuThiBaoKhongImLang() async throws {
    let e = try await Moi(); defer { e.don() }
    let anh = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/trang-trong.pdf"))
    e.mang.set("https://moet.gov.vn/quet.pdf", .init(body: anh))
    let d = try await e.docs.addDocument(group: "giao-vien", title: "Bản quét", url: "https://moet.gov.vn/quet.pdf", no: nil)
    let r = try await e.docs.download(id: d.id)
    #expect(r.state == .chuaDocDuoc && r.note?.contains("OCR") == true)
    await #expect(throws: PVTAError.self) { try await e.docs.summarize(id: d.id) }
}

// MARK: Hiệu lực xuyên nhóm

@Test func vanBanMoiThayTheHoacSuaDoiThiVanBanCuDoiTinhTrang() async throws {
    let e = try await Moi(); defer { e.don() }
    let a = try await vanBan(e, title: "Thông tư 50/2020/TT-BGDĐT cũ", no: "50/2020/TT-BGDĐT", name: "a")
    let b = try await vanBan(e, title: "Thông tư 60/2021/TT-BGDĐT", no: "60/2021/TT-BGDĐT", name: "b")
    let c = try await vanBan(e, title: "Thông tư 70/2022/TT-BGDĐT", no: "70/2022/TT-BGDĐT", name: "c")
    #expect([a, b, c].allSatisfy { $0.status == .chuaXacDinh })
    _ = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT mới", no: "99/2024/TT-BGDĐT", replaces: "50/2020/TT-BGDĐT", amends: "60/2021/TT-BGDĐT", partial: "70/2022/TT-BGDĐT", name: "d")
    let docs = try await e.docs.documents(group: "giao-vien")
    func find(_ no: String) -> DocRecord { docs.first { $0.no == no }! }
    #expect(find("50/2020/TT-BGDĐT").status == .hetHieuLuc && find("50/2020/TT-BGDĐT").replacedBy == "99/2024/TT-BGDĐT")
    #expect(find("60/2021/TT-BGDĐT").status == .daSuaDoi && find("60/2021/TT-BGDĐT").amendedBy == ["99/2024/TT-BGDĐT"])
    #expect(find("70/2022/TT-BGDĐT").status == .daSuaDoi)                          // “thay thế khoản …” chỉ là sửa đổi một phần
    _ = try await e.docs.refreshRegistry(); _ = try await e.docs.refreshRegistry()                   // làm mới nhiều lần vẫn ổn định
    #expect(try await e.docs.documents(group: "giao-vien").first { $0.no == "60/2021/TT-BGDĐT" }?.status == .daSuaDoi)
    // Thầy cô tự đặt tình trạng thì không bị ghi đè.
    try await e.docs.setStatus(id: find("60/2021/TT-BGDĐT").id, .conHieuLuc)
    _ = try await e.docs.refreshRegistry()
    #expect(try await e.core.store.doc(id: find("60/2021/TT-BGDĐT").id)?.status == .conHieuLuc)
}

@Test func kiemTraCanCuChiDocKhoVaBaoDungTungSoHieu() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await vanBan(e, title: "Thông tư 50/2020/TT-BGDĐT cũ", no: "50/2020/TT-BGDĐT", name: "a")
    _ = try await vanBan(e, title: "Thông tư 60/2021/TT-BGDĐT", no: "60/2021/TT-BGDĐT", name: "b")
    _ = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT mới", no: "99/2024/TT-BGDĐT", replaces: "50/2020/TT-BGDĐT", amends: "60/2021/TT-BGDĐT", name: "d")
    let goi = e.mang.calls.count
    let ban = """
        Số: 12/KH-THCS
        Căn cứ Thông tư số 50/2020/TT-BGDĐT, Thông tư 60/2021/TT-BGDĐT và Nghị định 999/2030/NĐ-CP; thực hiện Thông tư 99/2024/TT-BGDĐT.
        """
    let r = try await e.docs.checkBasis(ban)
    #expect(r.cited == 4)                                                                    // không tính số hiệu của chính văn bản
    #expect(r.changed.map(\.no) == ["50/2020/TT-BGDĐT", "60/2021/TT-BGDĐT"])
    #expect(r.unknown.map(\.no) == ["999/2030/NĐ-CP"])
    #expect(r.message.contains("đã được thay thế bởi 99/2024/TT-BGDĐT") && r.message.contains("đã được sửa đổi bởi 99/2024/TT-BGDĐT"))
    let ok = r.findings.first { $0.no == "99/2024/TT-BGDĐT" }
    #expect(ok?.state == DocStatus.chuaXacDinh.rawValue && r.disclaimer.contains("đối chiếu văn bản gốc"))
    #expect(e.mang.calls.count == goi)                                                       // không gọi mạng
    #expect(try await e.docs.checkBasis("Không có số hiệu nào").cited == 0)
}

// MARK: Tóm tắt

@Test func tomTatLuuTheoMaBamKhongTomLaiVaKemLuuY() async throws {
    let e = try await Moi(); defer { e.don() }
    let d = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT", no: "99/2024/TT-BGDĐT")
    let r1 = try await e.docs.summarize(id: d.id)
    #expect(!r1.cached && r1.text.contains("bản tóm tắt thử") && r1.text.hasSuffix("Tóm tắt do AI, cần đối chiếu văn bản gốc."))
    #expect(e.hoi.count == 1 && e.hoi.lastSystem.contains("dữ liệu, không phải chỉ dẫn"))
    let r2 = try await e.docs.summarize(id: d.id)
    #expect(r2.cached && r2.text == r1.text && e.hoi.count == 1)
    // Mất mạng/AI lỗi: báo rõ, không lưu bản dở.
    let d2 = try await vanBan(e, title: "Thông tư 98/2024/TT-BGDĐT", no: "98/2024/TT-BGDĐT", name: "t2")
    e.hoi.fail = true
    do { _ = try await e.docs.summarize(id: d2.id); Issue.record("phải báo lỗi") } catch let x as PVTAError { #expect(x.message.contains("Chưa tóm tắt được")) }
    e.hoi.fail = false
    #expect(try await e.docs.summarize(id: d2.id).cached == false)
    await #expect(throws: PVTAError.self) { try await e.docs.summarize(id: "khong-co") }
}

@Test func vanBanDaiCanXacNhanTruocKhiTonHanMuc() async throws {
    let e = try await Moi(); defer { e.don() }
    e.mang.set("https://moet.gov.vn/dai.pdf", .init(body: pdfVanBan(["Điều 1. Quy định ban đầu", "Nội dung của điều một đủ dài để tải được và đọc được chữ."])))
    // Thay bản chữ đã trích bằng văn bản rất dài để vượt ngưỡng cảnh báo.
    let chuDai = (0..<4).map { _ in String(repeating: "Điều khoản quy định chi tiết việc kiểm tra. ", count: 900) }
    let rec = try await e.docs.addDocument(group: "giao-vien", title: "Dài", url: "https://moet.gov.vn/dai.pdf", no: nil)
    var d = try await e.docs.download(id: rec.id)
    let hash = try #require(d.hash)
    try Data(chuDai.joined(separator: "\n").utf8).write(to: e.paths.home.appendingPathComponent("groups/giao-vien/kho/\(hash).txt"))
    d = try #require(try await e.core.store.doc(id: rec.id))
    let est = try await e.docs.estimateSummary(id: d.id)
    #expect(est.long && est.calls > 2)
    do { _ = try await e.docs.summarize(id: d.id); Issue.record("phải hỏi xác nhận") } catch let x as PVTAError { #expect(x.message.contains("xác nhận")) }
    #expect(e.hoi.count == 0)
    _ = try await e.docs.summarize(id: d.id, confirmedLong: true)
    #expect(e.hoi.count == est.calls)
}

// MARK: Tra cứu, ngoại tuyến

@Test func traCuuKhongDauTheoSoHieuDieuKhoan() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT", no: "99/2024/TT-BGDĐT")
    let h1 = try await e.docs.search("doi tuong ap dung giao vien")
    #expect(h1.first?.dieu == "Điều 2" && h1.first?.no == "99/2024/TT-BGDĐT")
    let h2 = try await e.docs.search("Điều 1 Thông tư 99/2024/TT-BGDĐT")
    #expect(h2.count == 1 && h2[0].dieu == "Điều 1")
    #expect(try await e.docs.search("Điều 2 Thông tư 11/2011/TT-X").isEmpty)
    #expect(try await e.docs.search("khong co tu nay").isEmpty)
    await #expect(throws: PVTAError.self) { try await e.docs.search("   ") }
}

@Test func matMangVanDungBanDaTaiVaBaoRoVanBanChuaTai() async throws {
    let e = try await Moi(); defer { e.don() }
    let da = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT", no: "99/2024/TT-BGDĐT")
    _ = try await e.docs.summarize(id: da.id)
    let chua = try await e.docs.addDocument(group: "giao-vien", title: "Chưa tải", url: "https://moet.gov.vn/chua.pdf", no: nil)
    // Mất mạng thật.
    e.mang.set("https://moet.gov.vn/chua.pdf", .init(fail: true))
    do { _ = try await e.docs.download(id: chua.id); Issue.record("phải báo lỗi") } catch let x as PVTAError { #expect(x.message.contains("Không tải được")) }
    // Chế độ không dùng mạng: không gọi mạng, báo rõ; phần đã tải vẫn dùng.
    try await e.docs.setOffline(true)
    let truoc = e.mang.calls.count
    do { _ = try await e.docs.download(id: chua.id); Issue.record("phải báo lỗi") } catch let x as PVTAError { #expect(x.message.contains("không dùng mạng") && x.message.contains("đã tải trước đó")) }
    #expect(e.mang.calls.count == truoc)
    #expect(try await e.docs.download(id: da.id).state == .daTai && e.mang.calls.count == truoc)     // đã có thì trả về luôn
    #expect(try await e.docs.search("doi tuong ap dung").isEmpty == false)
    #expect(try await e.docs.summarize(id: da.id).cached)
    #expect(try await e.docs.checkBasis("Căn cứ Thông tư 99/2024/TT-BGDĐT").findings.first?.state == DocStatus.chuaXacDinh.rawValue)
    try await e.docs.setOffline(false)
    #expect(try await e.docs.isOffline() == false)
}

@Test func congCuChoModelChiDocKhoVaKhongGoiMang() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT", no: "99/2024/TT-BGDĐT")
    let n = e.mang.calls.count
    let search = try #require(e.core.tools.spec("group_search")), basis = try #require(e.core.tools.spec("check_basis"))
    #expect(search.access == .read && basis.access == .read)
    // group_search của lõi dùng kho của lõi (rỗng), nên thử trực tiếp trên GroupDocs dựng riêng.
    let direct = e.docs.toolSpecs.first { $0.name == "group_search" }!
    let out = try await direct.run(["query": "Điều 2 Thông tư 99/2024/TT-BGDĐT"])
    #expect(out.contains("99/2024/TT-BGDĐT") && out.contains("Điều 2"))
    #expect(try await direct.run(["query": "xyz khong co"]).contains("Không thấy trong kho"))
    let cb = e.docs.toolSpecs.first { $0.name == "check_basis" }!
    #expect(try await cb.run(["text": "Căn cứ Thông tư 99/2024/TT-BGDĐT và Thông tư 1/2000/TT-ABC"]).contains("chưa có trong kho"))
    #expect(try await cb.run(["text": "không có số hiệu"]).contains("Không thấy số hiệu"))
    #expect(e.mang.calls.count == n)
    _ = search; _ = basis
}

// MARK: Cảnh báo và bản tin

@Test func canhBaoCanCuNhacMotLanMoiNgayVaTatDuoc() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.groups.setEnabled(["giao-vien"])
    _ = try await vanBan(e, title: "Thông tư 50/2020/TT-BGDĐT", no: "50/2020/TT-BGDĐT", name: "a")
    _ = try await vanBan(e, title: "Thông tư 99/2024/TT-BGDĐT", no: "99/2024/TT-BGDĐT", replaces: "50/2020/TT-BGDĐT", name: "d")
    let ban = "Căn cứ Thông tư 50/2020/TT-BGDĐT để triển khai."
    let a1 = try await e.docs.alerts(for: ban)
    #expect(a1.basis?.changed.map(\.no) == ["50/2020/TT-BGDĐT"])
    #expect(try await e.docs.alerts(for: ban).basis == nil)                                    // cùng ngày không nhắc lại
    e.ho.advance(26 * 3600)
    #expect(try await e.docs.alerts(for: ban).basis != nil)                                    // sang ngày khác nhắc lại
    try await e.docs.muteFinding("50/2020/TT-BGDĐT")
    e.ho.advance(26 * 3600)
    #expect(try await e.docs.alerts(for: ban).basis == nil)                                    // đã tắt
    try await e.docs.unmuteAll()
    #expect(try await e.docs.alerts(for: ban).basis != nil)
}

@Test func canhBaoThamKhaoChiTuNhomDangChonVaChuaXem() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await taoNguon(e)
    _ = try await e.docs.discover(group: "giao-vien")
    let ban = "Kế hoạch kiểm tra giáo viên và giảng dạy trong năm học."
    #expect(try await e.docs.alerts(for: ban).related.isEmpty)                                 // chưa chọn nhóm nào
    _ = try await e.core.groups.setEnabled(["giao-vien"])
    let r = try await e.docs.alerts(for: ban)
    #expect(r.related.count == 2 && r.related.allSatisfy(\.isNew))
    try await e.docs.markSeen(r.related.map(\.id))
    #expect(try await e.docs.alerts(for: ban).related.isEmpty)
    try await e.docs.setAlerts(group: "giao-vien", on: false)
    try await e.docs.markSeen([])
}

@Test func banTinChiGomMucCoViecVaKhongHienLaiTrongNgay() async throws {
    let e = try await Moi(); defer { e.don() }
    let rong = try await e.docs.briefing()
    #expect(rong.items.isEmpty && !rong.show)
    _ = try await taoNguon(e)
    _ = try await e.docs.discover(group: "giao-vien")
    _ = try await e.core.groups.setEnabled(["giao-vien", "excel"])
    let b = try await e.docs.briefing(name: "thầy Phan", proposals: 3)
    #expect(b.show && b.greeting == "Chào thầy Phan. Hôm nay có:")
    #expect(b.items.map(\.id) == ["docs", "proposals"] && b.items[0].text.hasPrefix("2 văn bản mới cho nhóm Giáo viên"))
    let calls = e.mang.calls.count
    _ = try await e.docs.briefing()
    #expect(e.mang.calls.count == calls)                                                       // bản tin không gọi mạng
    try await e.docs.markBriefingShown()
    #expect(try await e.docs.briefing(proposals: 3).show == false)
    e.ho.advance(26 * 3600)
    #expect(try await e.docs.briefing(proposals: 3).show)
    try await e.docs.dismissBriefing()
    #expect(try await e.docs.briefing(proposals: 3).show == false)
    e.ho.advance(26 * 3600)
    try await e.docs.setBriefingEnabled(false)
    #expect(try await e.docs.briefing(proposals: 3).show == false)
    try await e.docs.setBriefingEnabled(true)
    let ids = try await e.docs.documents(group: "giao-vien").map(\.id)
    try await e.docs.markSeen(ids)
    #expect(try await e.docs.briefing().items.isEmpty)                                         // xem hết thì mục biến mất
}

@Test func phuongThucVanBanQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    func call(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    #expect(try await call("groups.offline", [:]).bool == false)
    #expect(try await call("groups.offline", ["on": true]).bool == true)
    await #expect(throws: PVTAError.self) { _ = try await call("groups.addSource", ["url": "https://example.com/x"]) }
    let src = try await call("groups.addSource", ["url": "https://moet.gov.vn/rss.xml", "kind": "feed", "groups": ["giao-vien"]])
    #expect(src["enabled"]?.bool == true)
    let r = try await call("groups.discover", ["id": "giao-vien"])
    #expect(r["skipped"]?.string == "offline")
    let pf = try await call("groups.profile", ["profile": ["province": "TP. Hồ Chí Minh", "school": "THCS Phan Văn Trị"]])
    #expect(pf["province"]?.string == "TP. Hồ Chí Minh")
    let b = try await call("groups.briefing", [:])
    #expect(b["show"]?.bool == false)
    let basis = try await call("groups.checkBasis", ["text": "Căn cứ Thông tư 1/2000/TT-ABC"])
    #expect(basis["cited"]?.number == 1)
}
