import Foundation
import Testing
@testable import PVTACore

private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

private func tinh(_ f: String, _ cells: [String: JSONValue] = [:]) -> XValue {
    var dict: [String: (value: XValue, formula: String?)] = [:]
    for (k, v) in cells {
        switch v {
        case .number(let d): dict[k] = (.number(d), nil)
        case .string(let s) where s.hasPrefix("="): dict[k] = (.empty, s)
        case .string(let s): dict[k] = (.text(s), nil)
        case .bool(let b): dict[k] = (.bool(b), nil)
        default: break
        }
    }
    dict["Z99"] = (.empty, f)
    var e = FormulaEngine(sheets: ["S": dict, "Tổng kết": ["A1": (.number(5), nil)]])
    return e.value(sheet: "S", ref: "Z99")
}

private let diem: [String: JSONValue] = ["A1": 9, "A2": 8.5, "A3": 10, "A4": 4, "B1": "Giỏi", "B2": "Khá", "B3": "Giỏi", "B4": "Yếu", "C1": 1, "C2": 2, "C3": 3, "C4": 4]

// MARK: Bộ tính công thức

@Test func soHocVaThuTuUuTien() {
    #expect(tinh("=1+2*3") == .number(7) && tinh("=(1+2)*3") == .number(9) && tinh("=2^3^2") == .number(64))
    #expect(tinh("=-2^2") == .number(4))     // giống Excel: dấu trừ đứng trước được tính trước phép mũ
    #expect(tinh("=10/4") == .number(2.5) && tinh("=50%") == .number(0.5) && tinh("=1/0") == .error("#DIV/0!"))
    #expect(tinh("=\"a\"&\"b\"&1") == .text("ab1") && tinh("=A1*2", ["A1": 4]) == .number(8))
}

@Test func lamTronGiongExcel() {
    #expect(tinh("=ROUND(2.675,2)") == .number(2.68) && tinh("=ROUND(9.25,1)") == .number(9.3) && tinh("=ROUND(-1.5,0)") == .number(-2))
    #expect(tinh("=ROUND(1234,-2)") == .number(1200) && tinh("=ROUNDUP(1.21,1)") == .number(1.3) && tinh("=ROUNDDOWN(-1.29,1)") == .number(-1.2))
    #expect(tinh("=INT(-1.5)") == .number(-2) && tinh("=MOD(-7,3)") == .number(2))
}

@Test func thongKeTrenVung() {
    #expect(tinh("=SUM(A1:A4)", diem) == .number(31.5) && tinh("=AVERAGE(A1:A4)", diem) == .number(7.875))
    #expect(tinh("=MIN(A1:A4)", diem) == .number(4) && tinh("=MAX(A1:A4)", diem) == .number(10) && tinh("=MEDIAN(A1:A4)", diem) == .number(8.75))
    #expect(tinh("=COUNT(A1:B4)", diem) == .number(4) && tinh("=COUNTA(A1:B4)", diem) == .number(8))
    #expect(tinh("=COUNTIF(B1:B4,\"Giỏi\")", diem) == .number(2) && tinh("=COUNTIF(A1:A4,\">=8.5\")", diem) == .number(3) && tinh("=COUNTIF(B1:B4,\"<>Giỏi\")", diem) == .number(2))
    #expect(tinh("=COUNTIF(B1:B4,\"G*\")", diem) == .number(2))
    #expect(tinh("=SUMIF(B1:B4,\"Giỏi\",A1:A4)", diem) == .number(19) )
    if case .number(let d) = tinh("=AVERAGEIF(A1:A4,\">5\")", diem) { #expect(abs(d - 27.5 / 3) < 1e-9) } else { Issue.record("AVERAGEIF") }
    #expect(tinh("=SUMPRODUCT(A1:A4,C1:C4)", diem) == .number(9 + 17 + 30 + 16))
    #expect(tinh("=RANK(A2,A1:A4)", diem) == .number(3) && tinh("=RANK(A4,A1:A4,1)", diem) == .number(1))
    #expect(tinh("=SUM(A1:A2,10)", diem) == .number(27.5))
}

@Test func tinhDiemVaXepLoai() {
    let hs: [String: JSONValue] = ["C2": 9, "D2": 8.5, "E2": 10, "F2": 9, "G2": 9.5,
                                   "H2": "=ROUND((SUM(C2:E2)+F2*2+G2*3)/8,1)",
                                   "I2": "=IF(H2>=8,\"Giỏi\",IF(H2>=6.5,\"Khá\",IF(H2>=5,\"Trung bình\",\"Yếu\")))",
                                   "J2": "=IFS(H2>=8,\"G\",H2>=6.5,\"K\",TRUE,\"Y\")"]
    #expect(tinh("=H2", hs) == .number(9.3) && tinh("=I2", hs) == .text("Giỏi") && tinh("=J2", hs) == .text("G"))
    #expect(tinh("=IF(AND(H2>=8,F2>=8),\"Đạt\",\"Chưa\")", hs) == .text("Đạt") && tinh("=IF(OR(H2<5,F2<5),1,0)", hs) == .number(0) && tinh("=IF(NOT(H2>5),1,2)", hs) == .number(2))
    #expect(tinh("=IFERROR(1/0,\"lỗi\")") == .text("lỗi") && tinh("=IFERROR(4,\"lỗi\")") == .number(4))
    #expect(tinh("=VLOOKUP(7,A1:B3,2)", ["A1": 0, "B1": "Yếu", "A2": 5, "B2": "TB", "A3": 8, "B3": "Giỏi"]) == .text("TB"))
    #expect(tinh("=VLOOKUP(8,A1:B3,2,FALSE)", ["A1": 0, "B1": "Yếu", "A2": 5, "B2": "TB", "A3": 8, "B3": "Giỏi"]) == .text("Giỏi"))
}

@Test func thamChieuCheoSheetVongVaLoi() {
    #expect(tinh("='Tổng kết'!A1*2") == .number(10) && tinh("=Z98+1", ["Z98": "=Z99"]) == .error("#REF!"))
    #expect(tinh("=KhongCo!A1") == .error("#REF!") && tinh("=LEN(\"Xin chào\")") == .number(8))
    if case .error(let e) = tinh("=XLOOKUP(1,A1:A2,B1:B2)"), e.hasPrefix("#UNSUPPORTED") {} else { Issue.record("hàm lạ phải báo chưa hỗ trợ") }
    #expect(tinh("=A1+1", ["A1": "chữ"]) == .error("#VALUE!") && tinh("=SUM(A1:A2)", ["A1": 1, "A2": "=1/0"]) == .error("#DIV/0!"))
}

// MARK: Tạo, đọc, sửa

private func bangDiem() -> JSONValue {
    var rows: [JSONValue] = [["STT", "Họ tên", "TX1", "TX2", "TX3", "GK", "CK", "ĐTB", "Xếp loại", "Hạng"]]
    let data: [(String, [Double])] = [("Học sinh A", [9, 8.5, 10, 9, 9.5]), ("Học sinh B", [6, 7, 6.5, 7, 6]), ("Học sinh C", [4, 5, 4.5, 5, 4]), ("Học sinh D", [7.5, 8, 7, 8, 7.5])]
    for (i, (name, s)) in data.enumerated() {
        let r = i + 2
        var row: [JSONValue] = [.number(Double(i + 1)), .string(name)]
        for x in s { row.append(.number(x)) }
        row.append(.string("=ROUND((SUM(C\(r):E\(r))+F\(r)*2+G\(r)*3)/8,1)"))
        row.append(.string("=IF(H\(r)>=8,\"Giỏi\",IF(H\(r)>=6.5,\"Khá\",IF(H\(r)>=5,\"Trung bình\",\"Yếu\")))"))
        row.append(.string("=RANK(H\(r),$H$2:$H$5)"))
        rows.append(.array(row))
    }
    rows.append(["Trung bình", "", "", "", "", "", "", "=ROUND(AVERAGE(H2:H5),2)", "=COUNTIF(I2:I5,\"Giỏi\")&\" giỏi\"", ""])
    return ["name": "Điểm 8A", "rows": .array(rows),
            "charts": [["type": "bar", "title": "ĐTB", "categories": "B2:B5", "series": [["name": "ĐTB", "values": "H2:H5"]], "anchor": "L2"]]]
}

private func hopLe(_ data: Data) throws {
    let zip = try ZipArchive(data: data)
    for n in zip.names where n.hasSuffix(".xml") || n.hasSuffix(".rels") { _ = try XMLDocument(data: try #require(try zip.read(n)), options: []) }
}

private func xml(_ data: Data, _ name: String) throws -> String {
    let raw = String(decoding: try #require(try ZipArchive(data: data).read(name)), as: UTF8.self)
    // XMLDocument ghi phần tử rỗng dạng <a></a>; đưa về <a/> để so sánh chữ.
    return raw.replacingOccurrences(of: #"<([A-Za-z:]+)((?:\s[^>]*)?)></\1>"#, with: "<$1$2/>", options: .regularExpression)
}

@Test func taoSoDiemTinhDungDiemVaXepLoai() throws {
    let r = try Xlsx.create(title: "Sổ điểm", sheets: [bangDiem()])
    try hopLe(r.data)
    let book = try XlsxBook(data: r.data)
    var eng = try book.engine()
    func v(_ ref: String) -> XValue { eng.value(sheet: "Điểm 8A", ref: ref) }
    #expect([v("H2"), v("H3"), v("H4"), v("H5")] == [.number(9.3), .number(6.4), .number(4.4), .number(7.6)])
    #expect([v("I2"), v("I3"), v("I4"), v("I5")] == [.text("Giỏi"), .text("Trung bình"), .text("Yếu"), .text("Khá")])
    #expect([v("J2"), v("J3"), v("J4"), v("J5")] == [.number(1), .number(3), .number(4), .number(2)])
    #expect(v("H6") == .number(6.93) && v("I6") == .text("1 giỏi"))
    // Giá trị tính sẵn được ghi vào tệp (đọc lại không cần tính), và bật tính lại khi mở.
    let sheet = try xml(r.data, "xl/worksheets/sheet1.xml")
    let wb = try xml(r.data, "xl/workbook.xml")
    #expect(sheet.contains("<f>ROUND((SUM(C2:E2)+F2*2+G2*3)/8,1)</f><v>9.3</v>") && sheet.contains("<v>Giỏi</v>") && wb.contains("fullCalcOnLoad=\"1\""))
    // Tiêu đề tô màu, đóng băng, lọc, kẻ khung, biểu đồ.
    #expect(sheet.contains("<pane") && sheet.contains("state=\"frozen\"") && sheet.contains("<autoFilter ref=\"A1:J6\"/>"))
    let styles = try xml(r.data, "xl/styles.xml")
    #expect(styles.contains("FF1F3864") && styles.contains("style=\"thin\""))
    let chart = try xml(r.data, "xl/charts/chart1.xml"), rels = try xml(r.data, "xl/worksheets/_rels/sheet1.xml.rels"), ct = try xml(r.data, "[Content_Types].xml")
    #expect(chart.contains("<c:barChart>") && rels.contains("drawing1.xml") && ct.contains("drawingml.chart+xml"))
}

@Test func docLaiBangVaTextExtractorDocDuoc() throws {
    let r = try Xlsx.create(title: nil, sheets: [bangDiem()])
    let out = try XlsxBook(data: r.data).describe()
    #expect(out.contains("[Trang tính “Điểm 8A” — vùng A1:J6]") && out.contains("9.3 {=ROUND((SUM(C2:E2)+F2*2+G2*3)/8,1)}") && out.contains("Giỏi {=IF("))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString.prefix(6)).xlsx")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try r.data.write(to: tmp)
    let text = try TextExtractor.extract(tmp).text
    #expect(text.contains("Học sinh A") && text.contains("9.3") && text.contains("Giỏi"))
}

@Test func docTepMauCoSanVaTinhCongThuc() throws {
    let data = try Data(contentsOf: mau.appendingPathComponent("bang-diem.xlsx"))
    let out = try XlsxBook(data: data).describe()
    #expect(out.contains("Điểm lớp 8A") && out.contains("Học sinh mẫu A") && out.contains("9.5") && out.contains("Giỏi"))
}

@Test func suaOGhiCongThucToMauLocVaBieuDo() throws {
    let src = try Xlsx.create(title: nil, sheets: [bangDiem()]).data
    let r = try Xlsx.edit(src, ops: [
        ["op": "set", "cell": "C2", "value": 3],                                   // điểm TX1 của HS A: 9 → 3
        ["op": "set", "cell": "K1", "value": "Ghi chú"],
        ["op": "set", "cell": "K2", "formula": "=IF(H2<5,\"Cần phụ đạo\",\"Ổn\")"],
        ["op": "style", "range": "A3:J3", "color": "FFFF00", "bold": true, "numFmt": "0.0"],
        ["op": "width", "column": "B", "width": 30],
        ["op": "merge", "range": "A8:C8"],
        ["op": "addSheet", "name": "Tổng kết"],
        ["op": "set", "sheet": "Tổng kết", "cell": "A1", "formula": "='Điểm 8A'!H2+'Điểm 8A'!H3"],
        ["op": "chart", "type": "line", "sheet": "Điểm 8A", "categories": "B2:B5", "series": [["values": "H2:H5"]], "anchor": "L20"],
    ])
    try hopLe(r.data)
    let book = try XlsxBook(data: r.data)
    var eng = try book.engine()
    #expect(eng.value(sheet: "Điểm 8A", ref: "H2") == .number(8.5))            // (3+8.5+10+18+28.5)/8 = 8.5
    #expect(eng.value(sheet: "Điểm 8A", ref: "K2") == .text("Ổn") && eng.value(sheet: "Điểm 8A", ref: "I2") == .text("Giỏi"))
    #expect(eng.value(sheet: "Tổng kết", ref: "A1") == .number(14.9))
    #expect(book.sheets.map(\.name) == ["Điểm 8A", "Tổng kết"])
    // Biểu đồ cũ còn, biểu đồ mới thêm vào cùng phần vẽ.
    let drawing = try xml(r.data, "xl/drawings/drawing1.xml")
    let names = try ZipArchive(data: r.data).names
    #expect(drawing.components(separatedBy: "<xdr:twoCellAnchor").count == 3 && names.contains("xl/charts/chart2.xml"))
    let sheet = try xml(r.data, "xl/worksheets/sheet1.xml")
    #expect(sheet.contains("<mergeCell ref=\"A8:C8\"/>") && sheet.contains("width=\"30\""))
    let styles = try xml(r.data, "xl/styles.xml")
    #expect(styles.contains("formatCode=\"0.0\"") && styles.contains("FFFFFF00"))
    #expect(styles.components(separatedBy: "<border>").count == 3)      // khung viền không bị nhân đôi
}

@Test func suaGiuNguyenPhanKhongDungToi() throws {
    let src = try Xlsx.create(title: nil, sheets: [bangDiem()]).data
    let r = try Xlsx.edit(src, ops: [["op": "set", "cell": "B2", "value": "Tên mới"]])
    for name in ["_rels/.rels", "xl/charts/chart1.xml", "xl/drawings/drawing1.xml", "docProps/core.xml"] {
        let a = try xml(r.data, name), b = try xml(src, name)
        #expect(a == b, "\(name)")
    }
    #expect(try XlsxBook(data: r.data).describe().contains("Tên mới"))
}

@Test func thaoTacSaiBaoLoiRoVaKhongTaoTep() throws {
    let src = try Xlsx.create(title: nil, sheets: [bangDiem()]).data
    func loi(_ ops: [JSONValue]) { #expect(throws: PVTAError.self) { try Xlsx.edit(src, ops: ops) } }
    loi([]); loi([["op": "xoa"]]); loi([["op": "set", "cell": "ZZZZ1", "value": 1]]); loi([["op": "set", "sheet": "Không có", "cell": "A1", "value": 1]])
    loi([["op": "style", "range": "A1", "color": "xanh"]]); loi([["op": "style", "range": "A1"]]); loi([["op": "merge", "range": "A1"]])
    loi([["op": "merge", "range": "A8:C8"], ["op": "merge", "range": "B8:D9"]])
    loi([["op": "addSheet", "name": "Điểm 8A"]]); loi([["op": "addSheet", "name": "a/b"]])
    loi([["op": "chart", "type": "radar", "series": [["values": "A1:A2"]], "anchor": "A1"]]); loi([["op": "chart", "type": "bar", "series": [], "anchor": "A1"]])
    #expect(throws: PVTAError.self) { try XlsxBook(data: Data("không phải zip".utf8)) }
    #expect(throws: PVTAError.self) { try Xlsx.create(title: nil, sheets: []) }
    #expect(throws: PVTAError.self) { try Xlsx.create(title: nil, sheets: [["name": "A", "rows": [["x"]]], ["name": "a", "rows": [["y"]]]]) }
}

@Test func congThucLoiVaHamChuaHoTroDuocBaoCao() throws {
    let r = try Xlsx.create(title: nil, sheets: [["name": "T", "rows": [["a", "b"], [1, "=A2/0"], [2, "=XLOOKUP(1,A2:A3,A2:A3)"]]]])
    #expect(r.report.contains { $0.contains("#DIV/0!") } && r.report.contains { $0.contains("XLOOKUP") && $0.contains("Excel sẽ tự tính") })
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

private func keHoach(_ t: ToolSpec, _ a: JSONValue) async throws -> ActionPlan { try await t.plan!(a) }

@Test func suaBanSaoExcelKhongDungTepGoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let goc = e.lam.appendingPathComponent("diem.xlsx").path
    _ = try await e.f.excelCreate(path: goc, title: nil, sheets: [bangDiem()], chatId: nil)
    let truoc = FileHash.of(URL(fileURLWithPath: goc))
    let r = try await e.f.excelEdit(path: goc, output: nil, ops: [["op": "set", "cell": "C2", "value": 5]], chatId: nil)
    #expect((r.change.path as NSString).lastPathComponent == "diem (đã sửa).xlsx" && FileHash.of(URL(fileURLWithPath: goc)) == truoc)
    #expect(try await e.f.excelRead(path: r.change.path, chatId: nil).contains("{=ROUND("))
    await #expect(throws: PVTAError.self) { try await e.f.excelEdit(path: goc, output: goc, ops: [["op": "set", "cell": "A1", "value": 1]], chatId: nil) }
    await #expect(throws: PVTAError.self) { try await e.f.excelEdit(path: goc, output: r.change.path, ops: [["op": "set", "cell": "A1", "value": 1]], chatId: nil) }
    _ = try await e.f.undo(id: r.change.id)
    #expect(!FileManager.default.fileExists(atPath: r.change.path) && FileManager.default.fileExists(atPath: goc))
}

@Test func congCuExcelNgoaiPhamViVaKhaiBaoTacDong() async throws {
    let e = try await Moi(); defer { e.don() }
    await #expect(throws: PVTAError.self) { try await e.f.excelCreate(path: e.ngoai.appendingPathComponent("x.xlsx").path, title: nil, sheets: [bangDiem()], chatId: nil) }
    await #expect(throws: PVTAError.self) { try await e.f.excelCreate(path: e.lam.appendingPathComponent("x.xls").path, title: nil, sheets: [bangDiem()], chatId: nil) }
    let goc = e.lam.appendingPathComponent("bai.xlsx").path
    let create = e.tool("excel_create")
    #expect(create.access == .write)
    let plan = try await keHoach(create, ["path": .string(goc), "sheets": [bangDiem()]])
    #expect(plan.paths == [goc] && plan.preview.contains("H2 = 9.3") && !FileManager.default.fileExists(atPath: goc))
    await #expect(throws: PVTAError.self) { try await keHoach(create, ["path": .string(goc), "sheets": [["name": "A/B", "rows": [["x"]]]]]) }
    _ = try await create.run(["path": .string(goc), "sheets": [bangDiem()]])
    let edit = e.tool("excel_edit")
    let ep = try await keHoach(edit, ["path": .string(goc), "ops": [["op": "set", "cell": "C2", "value": 1]]])
    #expect(ep.paths.first?.hasSuffix("bai (đã sửa).xlsx") == true && ep.preview.contains("Gốc (không đổi)") && ep.preview.contains("H2 = "))
    await #expect(throws: PVTAError.self) { try await keHoach(edit, ["path": .string(goc), "ops": [["op": "set", "cell": "?", "value": 1]]]) }
    #expect(try await e.tool("excel_read").run(["path": .string(goc)]).contains("Học sinh A"))
}
