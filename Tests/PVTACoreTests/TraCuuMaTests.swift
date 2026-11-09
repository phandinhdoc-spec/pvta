import Foundation
import Testing
@testable import PVTACore

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let duAn = FileManager.default.temporaryDirectory.appendingPathComponent("da-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let khac = FileManager.default.temporaryDirectory.appendingPathComponent("khac-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let core: Core
    init() async throws {
        for d in [duAn, khac] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai)
        _ = try await core.permissions.addGrant(path: duAn.path, write: false)
        _ = try await core.permissions.addGrant(path: khac.path, write: false)
    }
    func don() { for u in [paths.home, duAn, khac] { try? FileManager.default.removeItem(at: u) } }
    var brain: BrainService { core.brain }
    @discardableResult func tep(_ rel: String, _ nd: String, in base: URL? = nil) throws -> String {
        let u = (base ?? duAn).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(nd.utf8).write(to: u)
        return u.path
    }
    func scope(_ root: URL? = nil) async throws -> BrainScope { try await brain.scope(chatId: nil, root: (root ?? duAn).path) }
}

private let swiftMau = """
    import Foundation

    /// Quy tắc lõi của PVTA.
    public final class BrainProjectRoot {
        let name: String
        public init(name: String) { self.name = name }

        func tinhDiemTrungBinh(_ diem: [Double]) -> Double {
            guard !diem.isEmpty else { return 0 }
            return diem.reduce(0, +) / Double(diem.count)
        }

        func xepLoai(_ d: Double) -> String {
            if d >= 8 { return "Giỏi" }
            return "Khá"
        }
    }

    struct SoDiem { var ten: String }

    func hamRoi() {}
    """

private let tsMau = """
    import { BrainProjectRoot } from './goc';
    export interface HocSinh { ten: string }
    export function layDanhSach(lop: string): HocSinh[] {
      return [];
    }
    export const tinhTong = (a: number, b: number) => {
      return a + b;
    };
    class Kho {
      constructor(private x: number) {}
      timKiem(tu: string): string {
        return tu;
      }
    }
    """

private let pyMau = """
    import os
    from datetime import date

    class SoLienLacDienTu:
        def them_diem(self, ten, diem):
            return diem

        def xuat(self):
            return 1

    def tinh_tong(a, b):
        return a + b
    """

private let mdMau = """
    # Hướng dẫn dự án

    ## Quy tắc lõi
    Mô tả quy tắc.

    ## Cài đặt
    Nội dung.
    """

private func du(_ e: Moi) throws {
    try e.tep("Sources/Goc.swift", swiftMau)
    try e.tep("Sources/Dung.swift", "import Foundation\nfunc chay() { let r = BrainProjectRoot(name: \"x\"); _ = r }\n")
    try e.tep("web/app.ts", tsMau)
    try e.tep("tools/so.py", pyMau)
    try e.tep("README.md", mdMau)
    try e.tep("node_modules/x/index.js", "function bi_bo() {}")
    try e.tep("Package.swift", "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"X\")\n")
}

// MARK: Tổng quan và dàn ý

@Test func tongQuanDuAnMauCoNgonNguVungMaVaTepTrungTam() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    let o = try await e.brain.overview(s)
    #expect(o.contains("swift") && o.contains("typescript") && o.contains("python") && o.contains("markdown"))
    #expect(o.contains("Sources/ (") && o.contains("BrainProjectRoot") && o.contains("web/ (1 tệp)"))
    #expect(!o.contains("node_modules") && !o.contains("bi_bo"))
    #expect(o.contains("ĐIỂM VÀO / CẤU HÌNH") && o.contains("Package.swift") && o.contains("README.md"))
    #expect(o.contains("TỆP TRUNG TÂM") && o.contains("Sources/Goc.swift (2 tệp)"))                  // Dung.swift nhắc tới BrainProjectRoot
}

@Test func danYMotTepCoKyHieuLongNhauVaDongDauCuoiThat() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    let sw = try await e.brain.outline(s, file: "Sources/Goc.swift")
    #expect(sw.contains("class BrainProjectRoot [4-"))
    #expect(sw.contains("  method tinhDiemTrungBinh [") && sw.contains("  method xepLoai [") && sw.contains("struct SoDiem ["))
    #expect(sw.contains("Import: Foundation") && sw.contains("Tệp nhắc tới: Sources/Dung.swift"))
    let idx = try await e.brain.index(s)
    let goc = try #require(idx.first { $0.path == "Sources/Goc.swift" })
    let cls = try #require(goc.symbols.first { $0.name == "BrainProjectRoot" })
    #expect(cls.line == 4 && cls.end == 17)                                                               // khép đúng ngoặc nhọn của lớp
    let m = try #require(goc.symbols.first { $0.name == "xepLoai" })
    #expect(m.end - m.line == 3 && m.scope == "BrainProjectRoot")
    let ts = try await e.brain.outline(s, file: "app.ts")                                                  // gọi bằng tên tệp
    #expect(ts.contains("function layDanhSach") && ts.contains("function tinhTong") && ts.contains("protocol HocSinh") && ts.contains("method timKiem"))
    let py = try await e.brain.outline(s, file: "tools/so.py")
    #expect(py.contains("class SoLienLacDienTu [4-") && py.contains("  method them_diem") && py.contains("function tinh_tong [11-12]"))
    let md = try await e.brain.outline(s, file: "README.md")
    #expect(md.contains("heading Hướng dẫn dự án") && md.contains("  heading Quy tắc lõi [3-5]"))
    await #expect(throws: PVTAError.self) { try await e.brain.outline(s, file: "khong-co.swift") }
}

// MARK: Tìm

@Test func timKyHieuNguyenTenTienToCamelVietTatVaLoiGo() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    func top(_ q: String) async throws -> String? { try await e.brain.find(s, query: q).hits.first?.name }
    #expect(try await top("BrainProjectRoot") == "BrainProjectRoot")
    #expect(try await top("tinhDiem") == "tinhDiemTrungBinh")                                              // tiền tố
    #expect(try await top("diem trung binh") == "tinhDiemTrungBinh")                                        // từng mảnh định danh
    #expect(try await top("them_diem") == "them_diem")
    #expect(try await top("BPR") == "BrainProjectRoot")                                                     // viết tắt
    #expect(try await top("tinhDiemTrungBihh") == "tinhDiemTrungBinh")                                      // gõ sai một ký tự
    let r = try await e.brain.find(s, query: "BrainProjectRoot")
    #expect(r.hits.first?.path == "Sources/Goc.swift" && r.hits.first?.line == 4 && r.hits.first?.kind == "class")
}

@Test func timNoiDungKhongPhanBietDauVaBoLoc() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    let r = try await e.brain.find(s, query: "quy tac loi")                                                  // không dấu khớp “Quy tắc lõi”
    #expect(r.hits.contains { $0.path == "Sources/Goc.swift" && $0.evidence?.contains("Quy tắc lõi") == true })
    #expect(r.hits.contains { $0.path == "README.md" })
    let f1 = try await e.brain.find(s, query: "kind:heading")
    #expect(f1.hits.map(\.name) == ["Hướng dẫn dự án", "Quy tắc lõi", "Cài đặt"])
    let f2 = try await e.brain.find(s, query: "tinh lang:python")
    #expect(f2.hits.allSatisfy { $0.path.hasSuffix(".py") } && f2.hits.first?.name == "tinh_tong")
    let f3 = try await e.brain.find(s, query: "xuat in:tools kind:function")
    #expect(f3.hits.isEmpty || f3.hits.allSatisfy { $0.path.hasPrefix("tools") })
    await #expect(throws: PVTAError.self) { try await e.brain.find(s, query: "   ") }
    let none = try await e.brain.find(s, query: "tinhDiemTrungBinhh2024xyz")
    #expect(none.hits.isEmpty && none.hint?.contains("tinhDiemTrungBinh") == true)                           // gợi ý tên gần giống
    let khong = try await e.brain.find(s, query: "zzzzqqq")
    #expect(khong.hits.isEmpty && khong.hint?.contains("không kết luận") == true)
}

// MARK: Đọc và tham chiếu

@Test func docThanHamTheoKyHieuHoacDongKemMaBam() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    let body = try await e.brain.read(s, file: "Sources/Goc.swift", symbol: "xepLoai")
    #expect(body.contains("sha256=") && body.contains("if d >= 8") && body.contains("(method xepLoai)") && !body.contains("tinhDiemTrungBinh"))
    let lines = try await e.brain.read(s, file: "Sources/Goc.swift", start: 4, end: 6)
    #expect(lines.contains(":4-6") && lines.contains("4\tpublic final class BrainProjectRoot"))
    await #expect(throws: PVTAError.self) { try await e.brain.read(s, file: "Sources/Goc.swift", symbol: "khongCo") }
    await #expect(throws: PVTAError.self) { try await e.brain.read(s, file: "Sources/Goc.swift", start: 900, end: 905) }
    await #expect(throws: PVTAError.self) { try await e.brain.read(s, file: "Sources/Goc.swift", start: 5, end: 2) }
    // Tối đa 500 dòng mỗi lần đọc.
    try e.tep("dai.py", (1...900).map { "x\($0) = \($0)" }.joined(separator: "\n"))
    let s2 = try await e.scope()
    let dai = try await e.brain.read(s2, file: "dai.py", start: 1, end: 900)
    #expect(dai.contains("đã cắt ở 500 dòng") && dai.contains("500\tx500 = 500") && !dai.contains("501\tx501"))
}

@Test func thamChieuPhanLoaiDinhNghiaImportDungVaChuThich() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let s = try await e.scope()
    let r = try await e.brain.refs(s, identifier: "BrainProjectRoot")
    #expect(r.contains("Sources/Goc.swift:4 [định nghĩa]") && r.contains("Sources/Dung.swift:2 [dùng]") && r.contains("web/app.ts:1 [import]"))
    #expect(try await e.brain.refs(s, identifier: "datetime").contains("[import]"))
    #expect(try await e.brain.refs(s, identifier: "KhongCoGi").contains("Không thấy"))
    await #expect(throws: PVTAError.self) { try await e.brain.refs(s, identifier: "a b; rm") }
}

// MARK: Phạm vi

@Test func phamViTepLeKhongDocTepCungThuMuc() async throws {
    let e = try await Moi(); defer { e.don() }
    try e.tep("bai/dinh-kem.py", "def ham_duoc_phep():\n    return 1\n", in: e.khac)
    try e.tep("bai/bi-mat.py", "def ham_cung_thu_muc_khong_duoc_doc():\n    return 2\n", in: e.khac)
    let loose = e.khac.appendingPathComponent("bai/dinh-kem.py").path
    let chat = try await e.core.store.createChat().id
    _ = try await e.core.attachments.add(chatId: chat, paths: [loose])
    let s = try await e.brain.scope(chatId: chat)
    #expect(s.roots.isEmpty && s.files.count == 1)
    #expect(try await e.brain.index(s).map(\.path) == ["tệp/dinh-kem.py"])
    #expect(try await e.brain.overview(s).contains("ham_duoc_phep"))
    await #expect(throws: PVTAError.self) { try await e.brain.read(s, file: "bi-mat.py", symbol: "ham_cung_thu_muc_khong_duoc_doc") }
    await #expect(throws: PVTAError.self) { try await e.brain.outline(s, file: "tệp/bi-mat.py") }
    #expect(try await e.brain.find(s, query: "ham_cung_thu_muc").hits.isEmpty)
    #expect(try await e.brain.refs(s, identifier: "ham_cung_thu_muc_khong_duoc_doc").contains("Không thấy"))
    // Công cụ cho model đi qua cùng phạm vi.
    let find = try #require(e.core.tools.spec("brain_find"))
    #expect(try await find.run(["chatId": .string(chat), "query": "ham_duoc_phep"]).contains("tệp/dinh-kem.py"))
    #expect(try await find.run(["chatId": .string(chat), "query": "ham_cung_thu_muc"]).contains("Không thấy"))
}

@Test func khongCoPhamViHoacThuMucChuaCapQuyenThiTuChoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let chat = try await e.core.store.createChat().id
    await #expect(throws: PVTAError.self) { try await e.brain.scope(chatId: chat) }                          // không dự án, không tệp, không root
    let chuaCap = FileManager.default.temporaryDirectory.appendingPathComponent("chuacap-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: chuaCap, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chuaCap) }
    await #expect(throws: PVTAError.self) { try await e.brain.scope(chatId: nil, root: chuaCap.path) }
    try e.tep("a.py", "def a(): pass")
    await #expect(throws: PVTAError.self) { try await e.brain.scope(chatId: nil, root: e.duAn.appendingPathComponent("a.py").path) }   // root phải là thư mục
    // Đính kèm một thư mục chỉ để chọn tệp, không cấp quyền duyệt mã.
    _ = try await e.core.attachments.add(chatId: chat, paths: [e.duAn.path])
    await #expect(throws: PVTAError.self) { try await e.brain.scope(chatId: chat) }
}

@Test func phamViTheoDuAnLayThuMucNguonVaLoaiHocHoi() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try await e.core.store.createProject(name: "Mã")
    try e.tep("du-an/src/chinh.swift", "struct ChinhCuaDuAn {}\n")
    try e.tep("du-an/hoc-hoi/cu.swift", "struct MaCuNamTruoc {}\n")
    try e.tep("ngoai/khac.swift", "struct KhongThuocDuAn {}\n")
    let nguon = e.duAn.appendingPathComponent("du-an"), hoc = e.duAn.appendingPathComponent("du-an/hoc-hoi")
    _ = try await e.core.projects.connectFolder(p.id, path: hoc.path, role: "learning")
    _ = try await e.core.projects.connectFolder(p.id, path: nguon.path, role: "source")
    let chat = try await e.core.store.createChat(title: "x", projectId: p.id).id
    let s = try await e.brain.scope(chatId: chat)
    #expect(s.roots.count == 1 && s.roots[0].hasSuffix("du-an"))
    let idx = try await e.brain.index(s)
    #expect(idx.map(\.path) == ["src/chinh.swift"])                                                         // Học hỏi bị loại khỏi chỉ mục
    #expect(try await e.brain.find(s, query: "MaCuNamTruoc").hits.isEmpty)
    #expect(try await e.brain.refs(s, identifier: "MaCuNamTruoc").contains("Không thấy"))
    await #expect(throws: PVTAError.self) { try await e.brain.scope(chatId: chat, root: hoc.path) }           // không trỏ thẳng vào Học hỏi
    // Tệp lẻ nằm trong Học hỏi cũng không vào phạm vi.
    _ = try await e.core.attachments.add(chatId: chat, paths: [hoc.appendingPathComponent("cu.swift").path])
    #expect(try await e.brain.scope(chatId: chat).files.isEmpty)
}

// MARK: Chỉ mục

@Test func chiMucNamNgoaiDuAnVaCapNhatTangDan() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    let truoc = try FileManager.default.contentsOfDirectory(atPath: e.duAn.path).sorted()
    let s = try await e.scope()
    _ = try await e.brain.index(s)
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.duAn.path).sorted() == truoc)               // không ghi gì vào dự án
    let luu = try FileManager.default.contentsOfDirectory(atPath: e.paths.home.appendingPathComponent("brain").path)
    #expect(luu.count == 1 && luu[0].hasSuffix(".json"))
    // Tệp đổi và tệp mới được thấy; tệp xóa biến mất. Phiên mới (không dùng bộ nhớ) vẫn đọc chỉ mục đã lưu.
    try await Task.sleep(for: .milliseconds(1100))
    try e.tep("Sources/Goc.swift", swiftMau + "\nfunc hamMoiThem() {}\n")
    try e.tep("moi.go", "package main\nfunc HamGo() {}\ntype CauTruc struct {\n  x int\n}\n")
    try FileManager.default.removeItem(atPath: e.duAn.appendingPathComponent("tools/so.py").path)
    let b2 = BrainService(store: e.core.store, files: e.core.files, home: e.paths.home)
    let r = try await b2.find(s, query: "hamMoiThem")
    #expect(r.hits.first?.name == "hamMoiThem")
    let hamGo = try await b2.find(s, query: "HamGo"), cauTruc = try await b2.find(s, query: "CauTruc")
    #expect(hamGo.hits.first?.kind == "function" && cauTruc.hits.first?.kind == "struct")
    #expect(try await b2.find(s, query: "SoLienLacDienTu").hits.isEmpty)
}

@Test func phuongThucBrainCommandQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    try du(e)
    func call(_ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch("brain.command", p, scoped: { _, _ in }) }
    let root = JSONValue.string(e.duAn.path)
    #expect(try await call(["command": "overview", "root": root]).string?.contains("PHẠM VI") == true)
    let f = try await call(["command": "find", "root": root, "query": "BrainProjectRoot"])
    if case .array(let h)? = f["hits"] { #expect(h.first?["line"]?.number == 4) } else { Issue.record("hits") }
    #expect(try await call(["command": "read", "root": root, "file": "Sources/Goc.swift", "symbol": "xepLoai"]).string?.contains("sha256=") == true)
    await #expect(throws: PVTAError.self) { _ = try await call(["command": "xoa", "root": root]) }
    await #expect(throws: PVTAError.self) { _ = try await call(["command": "overview"]) }
}
