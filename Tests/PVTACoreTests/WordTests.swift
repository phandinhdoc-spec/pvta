import Foundation
import Testing
@testable import PVTACore

private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
private func anh() throws -> Data { try Data(contentsOf: mau.appendingPathComponent("anh-do.png")) }
private let khongAnh: Docx.ImageLoader = { _ in throw PVTAError("không có ảnh") }

private func khoiMau() -> [JSONValue] {
    [
        ["type": "heading", "text": "I. MỤC TIÊU", "level": 1],
        ["type": "paragraph", "text": "Giải $ax^2+bx+c=0$ với $x=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}$.", "align": "justify"],
        ["type": "list", "items": ["Một", "Hai"], "ordered": true],
        ["type": "list", "items": ["A", "B"]],
        ["type": "table", "rows": [["Bước", "Nội dung"], ["1", "Khởi động"]]],
        ["type": "equation", "latex": "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"],
        ["type": "equation", "latex": "\\ce{2H2 + O2 -> 2H2O}"],
        ["type": "page_break"],
        ["type": "paragraph", "text": "Hết."],
    ]
}

private func phan(_ data: Data, _ name: String) throws -> String {
    let raw = String(decoding: try #require(try ZipArchive(data: data).read(name)), as: UTF8.self)
    // XMLDocument ghi phần tử rỗng dạng <a></a>; đưa về <a/> để so sánh chữ.
    return raw.replacingOccurrences(of: #"<([A-Za-z:]+)((?:\s[^>]*)?)></\1>"#, with: "<$1$2/>", options: .regularExpression)
}

private func hopLe(_ data: Data) throws {
    let zip = try ZipArchive(data: data)
    for n in zip.names where n.hasSuffix(".xml") || n.hasSuffix(".rels") {
        _ = try XMLDocument(data: try #require(try zip.read(n)), options: [])   // ném lỗi nếu XML hỏng
    }
}

/// Gói Word tối giản nhưng đủ các phần, có chữ bị chia thành nhiều run.
private func goiMau(_ bodyXML: String) -> Data {
    var z = ZipWriter()
    z.add("[Content_Types].xml", Data(Docx.contentTypes.utf8))
    z.add("_rels/.rels", Data(Docx.rootRels.utf8))
    z.add("word/document.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(Docx.w)\"><w:body>\(bodyXML)</w:body></w:document>".utf8))
    z.add("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>".utf8))
    z.add("word/styles.xml", Data(Docx.styles().utf8))
    return z.finish()
}

private let haiRun = "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">Xin </w:t></w:r><w:r><w:t>chào cả lớp</w:t></w:r></w:p>"

// MARK: ZIP

@Test func ghiZipRoiDocLaiDungTungMuc() throws {
    var z = ZipWriter()
    let lon = Data((0..<20_000).map { UInt8($0 % 7) }), nhieu = Data((0..<300).map { _ in UInt8.random(in: 0...255) })
    z.add("a.txt", Data("Xin chào".utf8)); z.add("rong", Data()); z.add("thu-muc/lon.bin", lon); z.add("nhieu.bin", nhieu)
    let r = try ZipArchive(data: z.finish())
    #expect(r.names == ["a.txt", "rong", "thu-muc/lon.bin", "nhieu.bin"])
    #expect(try r.read("a.txt") == Data("Xin chào".utf8) && r.read("rong") == Data() && r.read("thu-muc/lon.bin") == lon && r.read("nhieu.bin") == nhieu)
    #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF43926)
}

// MARK: Tạo và đọc

@Test func taoTaiLieuMoiRoiDocLaiBangPVTA() async throws {
    let data = try await Docx.create(title: "Giáo án thử", blocks: khoiMau(), images: khongAnh)
    try hopLe(data)
    let out = try Docx.outline(data)
    #expect(out.contains("[0] (Title) Giáo án thử") && out.contains("[1] (Heading1) I. MỤC TIÊU"))
    #expect(out.contains("Bảng 2 hàng × 2 cột") && out.contains("| 1 | Khởi động |") && out.contains("Hết."))
    #expect(out.contains("[công thức]"))
    // Bộ đọc văn bản chung của PVTA cũng đọc được.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString.prefix(6)).docx")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try data.write(to: tmp)
    let text = try TextExtractor.extract(tmp).text
    #expect(text.contains("Giáo án thử") && text.contains("Khởi động") && text.contains("Một"))
    // Đủ phần của gói Word, danh sách số bắt đầu lại, phương trình chuẩn của Word.
    let doc = try phan(data, "word/document.xml")
    #expect(doc.contains("<m:oMathPara>") && doc.contains("<m:f>") && doc.contains("<m:rad>") && doc.contains("<m:nary>") && doc.contains("w:tblHeader"))
    #expect(doc.contains("w:numId w:val=\"2\"") && doc.contains("w:numId w:val=\"1\"") && doc.contains("w:br w:type=\"page\""))
    #expect(try phan(data, "[Content_Types].xml").contains("wordprocessingml.document.main+xml"))
}

@Test func taoTaiLieuCoAnhVaTuChoiKhoiSai() async throws {
    let png = try anh()
    let data = try await Docx.create(title: nil, blocks: [["type": "image", "path": "a.png", "widthCm": 6]], images: { _ in png })
    try hopLe(data)
    let zip = try ZipArchive(data: data)
    let rels = try phan(data, "word/_rels/document.xml.rels")
    #expect(zip.names.contains("word/media/image1.png") && rels.contains("media/image1.png"))
    #expect(try Docx.outline(data).contains("[ảnh]"))
    await #expect(throws: PVTAError.self) { try await Docx.create(title: nil, blocks: [], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.create(title: nil, blocks: [["type": "video"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.create(title: nil, blocks: [["type": "table", "rows": [["a", "b"], ["c"]]]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.create(title: nil, blocks: [["type": "image", "path": "x.txt"]], images: { _ in Data("không phải ảnh".utf8) }) }
}

@Test func tepKhongPhaiWordBaoLoiTiengViet() throws {
    #expect(throws: PVTAError.self) { try Docx.outline(Data("không phải zip".utf8)) }
    var z = ZipWriter(); z.add("a.txt", Data("x".utf8))
    #expect(throws: PVTAError.self) { try Docx.outline(z.finish()) }
}

// MARK: Phương trình

@Test func congThucToanVaHoaDoiSangPhuongTrinhWord() throws {
    func ok(_ l: String) throws -> String { let x = try Omml.convert(l, display: true); _ = try XMLDocument(xmlString: "<r xmlns:m=\"\(Omml.namespace)\" xmlns:w=\"\(Docx.w)\">\(x)</r>"); return x }
    #expect(try ok("\\frac{a+1}{b}").contains("<m:f><m:num>"))
    #expect(try ok("\\sqrt[3]{x}").contains("<m:deg>") && ok("\\sqrt{x}").contains("degHide"))
    #expect(try ok("x^2_i").contains("<m:sSubSup>") && ok("a_1").contains("<m:sSub>") && ok("(a+b)^2").contains("<m:sSup>"))
    #expect(try ok("\\alpha \\leq \\pi").contains("α") && ok("\\alpha \\leq \\pi").contains("≤"))
    #expect(try ok("\\left( \\frac{1}{2} \\right)^2").contains("<m:d>"))
    #expect(try ok("\\begin{cases} x=1 \\\\ y=2 \\end{cases}").contains("<m:eqArr>"))
    #expect(try ok("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}").contains("<m:mr>"))
    #expect(try ok("\\int_0^1 x\\,dx").contains("∫") && ok("\\sin x").contains("sin"))
    let hoa = try ok("\\ce{2H2 + O2 -> 2H2O}")
    #expect(hoa.contains("<m:sSub>") && hoa.contains("→"))
    let ion = try ok("\\ce{SO4^{2-} + Ca^2+}")
    #expect(ion.contains("<m:sSubSup>") && ion.contains("<m:sSup>"))
    #expect(try ok("\\ce{Ca(OH)2 <=> Ca^2+}").contains("⇌"))
    #expect(try ok("a < b & c > d").contains("&lt;"))
}

@Test func congThucSaiBiTuChoiBangLoiRo() {
    for sai in ["\\frac{a}{", "x}", "\\unknowncmd{x}", "\\left( x", "\\right)", "\\begin{foo} x \\end{foo}", "", "\\ce{^2+}"] {
        #expect(throws: PVTAError.self, "\(sai)") { try Omml.convert(sai, display: false) }
    }
    let loi = (try? Omml.convert("\\unknowncmd", display: false)) == nil
    #expect(loi)
}

@Test func dauDoLaTrongDoanVanKhongThanhCongThuc() async throws {
    let data = try await Docx.create(title: nil, blocks: [["type": "paragraph", "text": "Giá 5$ và 7$ mỗi cái; $x^2$ là công thức"]], images: khongAnh)
    let doc = try phan(data, "word/document.xml")
    #expect(doc.components(separatedBy: "<m:oMath>").count == 2)       // đúng một công thức
    #expect(try Docx.outline(data).contains("Giá 5$ và 7$ mỗi cái; [công thức] là công thức"))
}

// MARK: Sửa

@Test func thayChuQuaNhieuRunGiuDinhDangRunDau() async throws {
    let src = goiMau(haiRun)
    let r = try await Docx.edit(src, ops: [["op": "replace", "find": "Xin chào", "replace": "Chào"]], images: khongAnh)
    try hopLe(r.data)
    #expect(try Docx.outline(r.data).contains("[0] Chào cả lớp"))
    let doc = try phan(r.data, "word/document.xml")
    #expect(doc.contains("<w:b/>") && doc.contains("w:jc"))              // định dạng đoạn và run đầu còn nguyên
    #expect(try Docx.outline(src).contains("Xin chào cả lớp"))           // đầu vào không đổi
}

@Test func thayChuMoHoHoacKhongThayThiTuChoi() async throws {
    let src = goiMau(haiRun + haiRun)
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "replace", "find": "lớp", "replace": "nhóm"]], images: khongAnh) }
    let all = try await Docx.edit(src, ops: [["op": "replace", "find": "lớp", "replace": "nhóm", "all": true]], images: khongAnh)
    #expect(try Docx.outline(all.data).components(separatedBy: "nhóm").count == 3)
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "replace", "find": "không có", "replace": "x"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "xoa-het"]], images: khongAnh) }
}

@Test func suaMotDoanThemBangPhuongTrinhAnhVaXoa() async throws {
    let png = try anh()
    let src = try await Docx.create(title: "Bài", blocks: khoiMau(), images: khongAnh)
    // Chỉ số luôn là của tài liệu gốc: ba lần chèn sau khối 1 giữ đúng thứ tự, xóa khối 8 không làm lệch.
    let r = try await Docx.edit(src, ops: [
        ["op": "setText", "index": 1, "text": "Mục tiêu bài học"],
        ["op": "insertParagraph", "after": 1, "text": "Đoạn thứ nhất"],
        ["op": "insertTable", "after": 1, "rows": [["a", "b"], ["c", "d"]]],
        ["op": "insertEquation", "after": 1, "latex": "x^2+y^2=r^2"],
        ["op": "insertImage", "after": "end", "path": "a.png", "widthCm": 5],
        ["op": "insertParagraph", "after": "start", "text": "Đầu trang", "heading": 2],
        ["op": "delete", "index": 11],
        ["op": "format", "index": 2, "bold": true, "size": 14, "font": "Arial", "align": "center"],
    ], images: { _ in png })
    try hopLe(r.data)
    let out = try Docx.outline(r.data)
    let lines = out.split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    let t = lines.map { $0.drop { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces) }
    #expect(t.first == "(Heading2) Đầu trang")
    #expect(t[2] == "(Heading1) Mục tiêu bài học")
    #expect(t[3] == "Đoạn thứ nhất" && t[4].hasPrefix("Bảng 2 hàng") && t[5] == "[công thức]")
    #expect(!out.contains("Hết.") && out.contains("[ảnh]"))
    let doc = try phan(r.data, "word/document.xml")
    #expect(doc.contains("w:ascii=\"Arial\"") && doc.contains("w:sz w:val=\"28\"") && doc.contains("w:jc w:val=\"center\""))
    // Ảnh thêm đúng chuẩn: tệp ảnh, liên kết, loại nội dung.
    let zip = try ZipArchive(data: r.data)
    #expect(zip.names.contains { $0.hasPrefix("word/media/pvta-") })
    #expect(try phan(r.data, "word/_rels/document.xml.rels").contains("rIdPvta1") && phan(r.data, "[Content_Types].xml").contains("Extension=\"png\""))
    // Phần không đụng tới giữ nguyên từng byte.
    #expect(try phan(r.data, "word/styles.xml") == phan(src, "word/styles.xml") && phan(r.data, "word/numbering.xml") == phan(src, "word/numbering.xml"))
}

@Test func doanChenGiuDinhDangDoanDungTruoc() async throws {
    let src = goiMau("<w:p><w:pPr><w:jc w:val=\"both\"/></w:pPr><w:r><w:rPr><w:i/></w:rPr><w:t>Gốc</w:t></w:r></w:p>")
    let r = try await Docx.edit(src, ops: [["op": "insertParagraph", "after": 0, "text": "Thêm"]], images: khongAnh)
    let doc = try phan(r.data, "word/document.xml")
    #expect(doc.components(separatedBy: "<w:jc w:val=\"both\"/>").count == 3 && doc.components(separatedBy: "<w:i/>").count == 3)
}

@Test func chiSoSaiHoacBiXoaBaoLoiRo() async throws {
    let src = goiMau(haiRun + haiRun)
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "setText", "index": 5, "text": "x"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "delete", "index": 0], ["op": "setText", "index": 0, "text": "x"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "insertParagraph", "text": "thiếu vị trí"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "insertEquation", "after": 0, "latex": "\\frac{1}{"]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "format", "index": 0]], images: khongAnh) }
    await #expect(throws: PVTAError.self) { try await Docx.edit(src, ops: [["op": "format", "index": 0, "size": 2]], images: khongAnh) }
}

@Test func suaTepMauCoSanGiuBangVaDoanKhac() async throws {
    let src = try Data(contentsOf: mau.appendingPathComponent("giao-an.docx"))
    let r = try await Docx.edit(src, ops: [["op": "replace", "find": "Toán 8", "replace": "Toán 9"], ["op": "insertTable", "after": 1, "rows": [["Thêm", "Bảng"]]]], images: khongAnh)
    let out = try Docx.outline(r.data)
    #expect(out.contains("Giáo án Toán 9") && out.contains("| Thêm | Bảng |") && out.contains("| 1 | Khởi động |"))
    #expect(try ZipArchive(data: r.data).names == ZipArchive(data: src).names)
}

// MARK: Tệp và duyệt

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let lam = FileManager.default.temporaryDirectory.appendingPathComponent("l-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let ngoai = FileManager.default.temporaryDirectory.appendingPathComponent("n-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let core: Core
    var f: FileService { core.files }
    init() async throws {
        try FileManager.default.createDirectory(at: lam, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ngoai, withIntermediateDirectories: true)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai, approvalTimeout: .seconds(5))
        _ = try await core.permissions.addGrant(path: lam.path, write: true)
    }
    func don() { for u in [paths.home, lam, ngoai] { try? FileManager.default.removeItem(at: u) } }
    func tool(_ n: String) -> ToolSpec { core.files.toolSpecs.first { $0.name == n }! }
}

@Test func suaBanSaoKhongDungTepGocVaTranhGhiDe() async throws {
    let e = try await Moi(); defer { e.don() }
    let goc = e.lam.appendingPathComponent("bai.docx").path
    _ = try await e.f.wordCreate(path: goc, title: "Bài 1", blocks: [["type": "paragraph", "text": "Xin chào"]], chatId: nil)
    let truoc = FileHash.of(URL(fileURLWithPath: goc))
    let r = try await e.f.wordEdit(path: goc, output: nil, ops: [["op": "replace", "find": "Xin", "replace": "Chào"]], chatId: nil)
    #expect((r.change.path as NSString).lastPathComponent == "bai (đã sửa).docx")
    #expect(FileHash.of(URL(fileURLWithPath: goc)) == truoc)                                   // tệp gốc không đổi
    #expect(try await e.f.wordRead(path: r.change.path, chatId: nil).contains("Chào"))
    let r2 = try await e.f.wordEdit(path: goc, output: nil, ops: [["op": "setText", "index": 1, "text": "Lần hai"]], chatId: nil)
    #expect((r2.change.path as NSString).lastPathComponent == "bai (đã sửa 2).docx")
    await #expect(throws: PVTAError.self) { try await e.f.wordEdit(path: goc, output: goc, ops: [["op": "setText", "index": 1, "text": "x"]], chatId: nil) }
    await #expect(throws: PVTAError.self) { try await e.f.wordEdit(path: goc, output: r.change.path, ops: [["op": "setText", "index": 1, "text": "x"]], chatId: nil) }   // không ghi đè bản có sẵn
    // Hoàn tác bản sao bằng cơ chế chung (tệp vào Thùng rác, bản gốc còn nguyên).
    _ = try await e.f.undo(id: r2.change.id)
    #expect(!FileManager.default.fileExists(atPath: r2.change.path) && FileManager.default.fileExists(atPath: goc))
}

@Test func ngoaiThuMucDuocCapVaTepKhongPhaiDocxBiTuChoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let ngoai = e.ngoai.appendingPathComponent("x.docx").path
    await #expect(throws: PVTAError.self) { try await e.f.wordCreate(path: ngoai, title: "x", blocks: [], chatId: nil) }
    #expect(!FileManager.default.fileExists(atPath: ngoai))
    await #expect(throws: PVTAError.self) { try await e.f.wordCreate(path: e.lam.appendingPathComponent("a.doc").path, title: "x", blocks: [], chatId: nil) }
    try Data("x".utf8).write(to: e.ngoai.appendingPathComponent("y.docx"))
    await #expect(throws: PVTAError.self) { try await e.f.wordRead(path: e.ngoai.appendingPathComponent("y.docx").path, chatId: nil) }
    let hong = e.lam.appendingPathComponent("hong.docx")
    try Data("không phải zip".utf8).write(to: hong)
    await #expect(throws: PVTAError.self) { try await e.f.wordRead(path: hong.path, chatId: nil) }
}

private func keHoach(_ t: ToolSpec, _ a: JSONValue) async throws -> ActionPlan { try await t.plan!(a) }

@Test func congCuWordKhaiBaoTacDongVaBaoLoiTruocKhiHoiDuyet() async throws {
    let e = try await Moi(); defer { e.don() }
    let goc = e.lam.appendingPathComponent("bai.docx").path
    let create = e.tool("word_create")
    #expect(create.access == .write)
    let plan = try await keHoach(create, ["path": .string(goc), "title": "Bài", "blocks": [["type": "paragraph", "text": "a"], ["type": "table", "rows": [["a"]]]]])
    #expect(plan.paths == [goc] && plan.summary.contains("Tạo tài liệu Word") && plan.preview.contains("1 table"))
    #expect(!FileManager.default.fileExists(atPath: goc))                                      // chưa duyệt thì chưa ghi
    _ = try await create.run(["path": .string(goc), "title": "Bài", "blocks": [["type": "paragraph", "text": "a"]]])
    let edit = e.tool("word_edit")
    let ep = try await keHoach(edit, ["path": .string(goc), "ops": [["op": "setText", "index": 1, "text": "mới"]]])
    #expect(ep.paths == [e.lam.path + "/bai (đã sửa).docx"] || ep.paths.first?.hasSuffix("bai (đã sửa).docx") == true)
    #expect(ep.preview.contains("Gốc (không đổi)") && ep.preview.contains("setText"))
    await #expect(throws: PVTAError.self) { try await keHoach(edit, ["path": .string(goc), "ops": [["op": "setText", "index": 99, "text": "x"]]]) }
    let docc = try await e.tool("word_read").run(["path": .string(goc)])
    #expect(docc.contains("[0] (Title) Bài") && docc.contains("[1] a"))
}

@Test func mocXuatHienTrongCongCuTep() async throws {
    let e = try await Moi(); defer { e.don() }
    let names = Set(e.core.files.toolSpecs.map(\.name))
    #expect(names.isSuperset(of: ["word_read", "word_create", "word_edit", "fs_read"]))
}
