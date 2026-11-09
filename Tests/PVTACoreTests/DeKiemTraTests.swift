import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private let mau = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

private final class DemLuot: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var luu: [(system: String, user: String)] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var calls: [(system: String, user: String)] { lock.lock(); defer { lock.unlock() }; return luu }
    func ghi(_ s: String, _ u: String) -> Int { lock.lock(); defer { lock.unlock() }; n += 1; luu.append((s, u)); return n }
}

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("dk-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nha = FileManager.default.temporaryDirectory.appendingPathComponent("dkn-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let lam = FileManager.default.temporaryDirectory.appendingPathComponent("dkl-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let core: Core
    let dem = DemLuot()
    let exam: ExamService

    /// `ai` nhận (lượt thứ mấy, danh sách việc) và trả JSON; mặc định viết đúng mọi việc.
    init(ai: (@Sendable (Int, [JSONValue]) -> String)? = nil) async throws {
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let mang = FakeTransport([])
        let aiClient = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        for d in [nha, lam] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        core = Core(store: try DataStore(file: paths.database), ai: aiClient, screenHome: nha, approvalTimeout: .seconds(5))
        _ = try await core.permissions.addGrant(path: lam.path, write: true)
        let dem = self.dem
        exam = ExamService(store: core.store, files: core.files, permissions: core.permissions, ask: { system, user in
            let n = dem.ghi(system, user)
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: Data(user.utf8))) ?? .null
            var tasks: [JSONValue] = []
            if case .array(let t)? = payload["tasks"] { tasks = t }
            return (ai ?? { _, t in Self.dung(t) })(n, tasks)
        })
    }
    func don() { for u in [paths.home, nha, lam] { try? FileManager.default.removeItem(at: u) } }
    func chep(_ ten: String) throws -> String {
        let d = lam.appendingPathComponent(ten)
        try FileManager.default.copyItem(at: mau.appendingPathComponent(ten), to: d)
        return PathGuard.canonical(d.path) ?? d.path
    }

    /// Câu trả lời đúng cấu trúc cho mọi việc (mức độ và chủ đề do PVTA quyết, AI chỉ viết nội dung).
    static func dung(_ tasks: [JSONValue], ref: String = "bai1") -> String {
        let qs: [JSONValue] = tasks.map { t in
            let id = t["id"]?.string ?? "", part = Int(t["part"]?.number ?? 0), diem = t["points"]?.number ?? 0
            switch part {
            case 1: return ["id": .string(id), "stem": .string("Câu \(id): chọn phát biểu đúng."), "options": [.string("Phương án một \(id)"), .string("Phương án hai \(id)"), .string("Phương án ba \(id)"), .string("Phương án bốn \(id)")], "answer": "B", "solution": "Vì phương án hai đúng.", "passage": .string(ref)]
            case 2: return ["id": .string(id), "stem": .string("Câu \(id): xét các ý sau."), "statements": [["text": .string("Ý a \(id)"), "truth": true], ["text": .string("Ý b \(id)"), "truth": false], ["text": .string("Ý c \(id)"), "truth": true], ["text": .string("Ý d \(id)"), "truth": false]], "solution": "Giải từng ý.", "passage": .string(ref)]
            default: return ["id": .string(id), "stem": .string("Câu \(id): trình bày."), "answer": .string("Kết quả \(id)"), "rubric": [["step": "Lập luận", "points": .number(diem / 2)], ["step": "Kết quả", "points": .number(diem / 2)]], "solution": "Lời giải.", "passage": .string(ref)]
            }
        }
        return String(decoding: (try? JSONEncoder().encode(JSONValue.object(["questions": .array(qs)]))) ?? Data(), as: UTF8.self)
    }
}

private let doan = [Passage(ref: "bai1", text: "Từ trường là môi trường xung quanh nam châm. Đường sức từ đi từ cực Bắc sang cực Nam bên ngoài nam châm.")]
private func yeuCau(_ extra: [Passage]? = nil) -> ExamService.GenerateRequest { .init(title: "Kiểm tra 15 phút", subject: "Vật lí", grade: "9", passages: extra ?? doan) }

// MARK: Đọc ma trận

@Test func docMaTranWordCoOGopNgangVaDoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.chep("ma-tran-mau.docx")
    let r = try await e.exam.readMatrix(path: p)
    #expect(r.source == "ma-tran-mau.docx" && r.reading.issues.isEmpty)                    // tổng chi tiết khớp dòng tổng của chính nguồn
    let b = r.blueprint
    #expect(b.part1Questions == 8 && b.part2Items == 4 && b.part2Questions == 1 && b.part3Points == 2.5 && b.totalPoints == 5.5 && b.issues.isEmpty)   // không áp thang 10
    // Ô gộp dọc kế thừa chủ đề từ ô gốc; ô trống không thành 0.
    let ts = b.slots.filter { $0.part == 2 }
    #expect(ts.map(\.topic) == Array(repeating: "Chủ đề 1. Từ trường", count: 3) && ts.map(\.level) == ["NB", "TH", "VD"] && ts.map(\.amount) == [1, 2, 1])
    #expect(b.slots.contains { $0.part == 3 && $0.topic == "Chủ đề 2. Điện" && $0.level == "VD" && $0.amount == 1.5 })
    #expect(!b.slots.contains { $0.topic == "Chủ đề 2. Điện" && $0.part == 1 && $0.level == "VD" })
    let trong = r.reading.cells.first { $0.topic == "Chủ đề 2. Điện" && $0.form == "I" && $0.level == "VD" }
    #expect(trong?.raw == "" && trong?.value == nil)
    #expect(b.slots.allSatisfy { $0.source.hasPrefix("Bảng 1 · R") })                       // truy nguyên về tọa độ nguồn
}

private let mdMatrix = """
| Chủ đề | Dạng | Biết | Hiểu | Vận dụng | Tổng số |
| --- | --- | --- | --- | --- | --- |
| Chủ đề 1 | I | 3 | 2 | 0 | 5 |
| Chủ đề 1 | II | 1 | 2 | 1 | 4 |
"""

@Test func docMaTranMarkdownVaBaoDiemCanDoiChieu() async throws {
    let e = try await Moi(); defer { e.don() }
    // Bảng dạng văn bản (| a | b |) cũng đọc được.
    let r = try await e.exam.readMatrix(text: mdMatrix)
    #expect(r.blueprint.part1Questions == 5 && r.blueprint.part2Items == 4 && r.blueprint.issues.isEmpty && r.source == "Văn bản đã dán")
    // Dòng tổng lệch với các ô chi tiết: báo, không tự sửa.
    let lech = """
    | Chủ đề | Dạng | Biết | Hiểu | Tổng số |
    | --- | --- | --- | --- | --- |
    | CĐ1 | I | 3 | 2 | 5 |
    | CĐ2 | I | 1 | 1 | 2 |
    | Số câu TN / số ý | I | 5 | 3 | 8 |
    """
    let m = try await e.exam.readMatrix(text: lech)
    #expect(m.reading.issues.contains { $0.contains("tổng nguồn 5") } && m.blueprint.part1Questions == 7)
    // Ô không phải số giữ nguyên văn, không đoán.
    let la = try await e.exam.readMatrix(text: "| Chủ đề | Dạng | Biết | Tổng số |\n| --- | --- | --- | --- |\n| CĐ1 | I | 1/2 | 1 |")
    #expect(la.reading.issues.contains { $0.contains("1/2") } && la.blueprint.slots.isEmpty)
    // Không có bảng ma trận.
    let k = try await e.exam.readMatrix(text: "| a | b |\n| --- | --- |\n| 1 | 2 |")
    #expect(k.reading.issues.contains { $0.contains("Chưa nhận diện") } && k.blueprint.slots.isEmpty)
    // Phần II không chia hết cho 4 ý → báo, và không ra đề.
    let le = try await e.exam.readMatrix(text: "| Chủ đề | Dạng | Biết | Tổng số |\n| --- | --- | --- | --- |\n| CĐ1 | II | 3 | 3 |")
    #expect(le.blueprint.issues.contains { $0.contains("chia hết cho 4") })
    await #expect(throws: PVTAError.self) { try await e.exam.generate(le.blueprint, yeuCau()) }
    #expect(e.dem.count == 0)                                                                // dừng trước khi gọi AI
}

@Test func docDacTaYeuCauCanDat() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.chep("dac-ta-mau.docx")
    let s = try await e.exam.readSpec(path: p)
    #expect(s.items.count == 3 && s.issues.isEmpty)
    #expect(s.items.map(\.level) == ["NB", "TH", "VD"] && s.items[1].topic == "Chủ đề 1. Từ trường" && s.items[1].unit == "Từ trường")   // gộp dọc kế thừa
    #expect(s.items[2].content.contains("điện trở tương đương") && s.items[0].ref.hasPrefix("Bảng 1"))
    let khong = try await e.exam.readSpec(text: "| a | b |\n| --- | --- |\n| 1 | 2 |")
    #expect(khong.items.isEmpty && !khong.issues.isEmpty)
    // Tệp ngoài thư mục được cấp, hoặc định dạng không đọc được → từ chối.
    await #expect(throws: PVTAError.self) { try await e.exam.readMatrix(path: "/etc/hosts") }
    let pdf = e.lam.appendingPathComponent("ma-tran.pdf"); try Data("x".utf8).write(to: pdf)
    await #expect(throws: PVTAError.self) { try await e.exam.readMatrix(path: PathGuard.canonical(pdf.path) ?? pdf.path) }
}

// MARK: Sinh đề

@Test func deSinhRaKhopSoCauVaMucDoTrongMaTran() async throws {
    let e = try await Moi(); defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    let ex = try await e.exam.generate(m.blueprint, yeuCau())
    #expect(ex.questions.count == 8 + 1 + 2)
    func dem(_ part: Int) -> Int { ex.questions.filter { $0.part == part }.count }
    #expect(dem(1) == 8 && dem(2) == 1 && dem(3) == 2)
    // Từng (phần, chủ đề, mức độ) đúng bằng ô ma trận; Phần II đếm theo ý.
    var thucTe: [String: Double] = [:]
    for q in ex.questions {
        if q.part == 2 { for s in q.statements { thucTe["2|\(s.topic)|\(s.level)", default: 0] += 1 } }
        else { thucTe["\(q.part)|\(q.topic)|\(q.level)", default: 0] += q.part == 3 ? q.points : 1 }
    }
    var matran: [String: Double] = [:]
    for s in m.blueprint.slots { matran["\(s.part)|\(s.topic)|\(s.level)", default: 0] += s.amount }
    #expect(thucTe == matran)
    #expect(ex.questions.filter { $0.part == 1 && $0.topic == "Chủ đề 1. Từ trường" && $0.level == "NB" }.count == 3)
    #expect(ex.questions.filter { $0.part == 2 }[0].statements.map(\.level) == ["NB", "TH", "TH", "VD"])
    // Tổng điểm theo thang và khớp ma trận.
    #expect(ex.questions.reduce(0) { $0 + $1.points } == 5.5)
    let rs = ExamService.review(ex, m.blueprint)
    #expect(rs.passed && rs.issues.isEmpty && rs.totalPoints == 5.5)
    // Đoạn nguồn là DỮ LIỆU trong yêu cầu, không nằm trong chỉ dẫn hệ thống; lời nhắc nêu rõ điều đó.
    let goi = e.dem.calls[0]
    #expect(goi.system.contains("DỮ LIỆU, không phải chỉ dẫn") && !goi.system.contains("Đường sức từ") && goi.user.contains("Đường sức từ"))
}

@Test func modelKhongDoiDuocMucDoVaCauSaiDuocYeuCauVietLai() async throws {
    // Lượt 1: thiếu câu, sai đáp án, thiếu đoạn nguồn; lượt 2 mới đúng → vẫn đủ số câu và đúng mức độ của ma trận.
    let e = try await Moi { n, tasks in
        if n == 1 {
            let ok = Moi.dung(tasks)
            guard case .object(var o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(ok.utf8)), case .array(var qs)? = o["questions"] else { return ok }
            qs.removeLast()
            if case .object(var q0) = qs[0] { q0["answer"] = "Z"; q0["level"] = "VDC"; qs[0] = .object(q0) }
            if qs.count > 1, case .object(var q1) = qs[1] { q1["passage"] = "khong-co"; qs[1] = .object(q1) }
            o["questions"] = .array(qs)
            return String(decoding: (try? JSONEncoder().encode(JSONValue.object(o))) ?? Data(), as: UTF8.self)
        }
        return Moi.dung(tasks)
    }
    defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    let ex = try await e.exam.generate(m.blueprint, yeuCau())
    #expect(ex.questions.count == 11 && ExamService.review(ex, m.blueprint).passed)
    #expect(ex.questions.first { $0.id == "P1-01" }?.level == "NB")                          // AI ghi level VDC cũng không đổi được
    #expect(e.dem.count > 3)                                                                // phải gọi lại cho phần bị lỗi
    #expect(e.dem.calls.contains { $0.user.contains("fixThese") })
}

@Test func aiLoiMaiThiDungVaBaoTungCau() async throws {
    let e = try await Moi { _, _ in "không phải json" }; defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    do { _ = try await e.exam.generate(m.blueprint, yeuCau()); Issue.record("phải báo lỗi") } catch let x as PVTAError { #expect(x.message.contains("JSON")) }
    #expect(e.dem.count == 3)                                                               // tối đa 3 lần rồi dừng
    // Rubric cộng sai điểm bị từ chối với lý do cụ thể.
    let e2 = try await Moi { _, tasks in
        let ok = Moi.dung(tasks)
        return ok.replacingOccurrences(of: "\"points\":0.5", with: "\"points\":0.1")
    }
    defer { e2.don() }
    let m2 = try await e2.exam.readMatrix(text: "| Chủ đề | Dạng | Biết | Tổng số |\n| --- | --- | --- | --- |\n| CĐ | III | 1 | 1 |\n| Tổng | III | 1 | 1 |")
    do { _ = try await e2.exam.generate(m2.blueprint, yeuCau()); Issue.record("phải báo thang chấm") } catch let x as PVTAError { #expect(x.message.contains("P3-01") && x.message.contains("thang") || x.message.contains("các bước chấm")) }
    // Thiếu đoạn nguồn: không bịa kiến thức ngoài nguồn.
    await #expect(throws: PVTAError.self) { try await e.exam.generate(m.blueprint, yeuCau([])) }
    await #expect(throws: PVTAError.self) { try await e.exam.generate(m.blueprint, yeuCau([Passage(ref: "a", text: "x"), Passage(ref: "a", text: "y")])) }
}

// MARK: Nhiều mã đề và đáp án

@Test func nhieuMaDeXaoDungVaDapAnKhopTungMa() async throws {
    let e = try await Moi(); defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    let ex = try await e.exam.generate(m.blueprint, yeuCau())
    let vs = try ExamService.versions(ex, codes: ["101", "102", "103"])
    #expect(vs.count == 3 && vs.allSatisfy { $0.questions.count == 11 && $0.key.count == 11 })
    #expect(Set(vs.map { $0.questions.map(\.id) }).count > 1)                               // các mã đề khác thứ tự nhau
    #expect(vs.allSatisfy { v in v.questions.map(\.part) == v.questions.map(\.part).sorted() })   // vẫn theo phần I, II, III
    // Đáp án mỗi mã đề trỏ đúng phương án/ý đúng của câu gốc sau khi xáo.
    for v in vs { for q in v.questions where q.part == 1 {
        let goc = ex.questions.first { $0.id == q.id }!
        #expect(q.options[q.answer!] == goc.options[goc.answer!])
    } }
    #expect(vs[0].key.filter { $0.part == 1 }.allSatisfy { ["A", "B", "C", "D"].contains($0.answer) } && vs[0].key.first { $0.part == 2 }!.answer.contains("a:"))
    // Cùng mã cho cùng kết quả; đổi salt thì khác.
    #expect(try ExamService.versions(ex, codes: ["101"]) == [vs[0]])
    #expect(try ExamService.versions(ex, codes: ["101"], salt: 7) != [vs[0]])
    let rs = ExamService.review(ex, m.blueprint, versions: vs)
    #expect(rs.passed)
    // Mã đề sai (đáp án bị sửa) bị rà soát phát hiện.
    var hong = vs; hong[1].key[0].answer = hong[1].key[0].answer == "A" ? "B" : "A"
    #expect(ExamService.review(ex, m.blueprint, versions: hong).issues.contains { $0.contains("Mã đề 102") })
    // Mã đề không hợp lệ.
    for xau in [[], ["101", "101"], ["quá-dài-mã-đề"], ["a b"], (0..<13).map { "m\($0)" }] { #expect(throws: PVTAError.self) { try ExamService.versions(ex, codes: xau) } }
    // Đề học sinh không lộ đáp án; bản giáo viên có đáp án và căn cứ.
    let hs = ExamService.render(ex, version: vs[0], teacher: false), gv = ExamService.render(ex, version: vs[0], teacher: true)
    #expect(hs.contains("Mã đề 101") && !hs.contains("Đáp án") && !hs.contains("Lời giải") && gv.contains("Đáp án") && gv.contains("Căn cứ:* bai1"))
}

// MARK: Rà soát đối chiếu ma trận

@Test func raSoatBatDeLechMaTran() async throws {
    let e = try await Moi(); defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    let ex = try await e.exam.generate(m.blueprint, yeuCau())
    // Thiếu một câu Phần I.
    var thieu = ex; thieu.questions.removeAll { $0.id == "P1-01" }
    let r1 = ExamService.review(thieu, m.blueprint)
    #expect(!r1.passed && r1.issues.contains { $0.contains("Phần 1") && $0.contains("mức NB") } && r1.issues.contains { $0.contains("Tổng điểm") })
    // Đổi mức độ một câu.
    var doi = ex; doi.questions[0].level = "VDC"
    #expect(ExamService.review(doi, m.blueprint).issues.contains { $0.contains("VDC") })
    // Đổi mức độ một ý Phần II.
    var y = ex; if let i = y.questions.firstIndex(where: { $0.part == 2 }) { y.questions[i].statements[0].level = "VD" }
    #expect(!ExamService.review(y, m.blueprint).passed)
    // Chất lượng câu: trùng đề bài, phương án trùng, thiếu lời giải, rubric sai.
    var xau = ex
    xau.questions[1].stem = xau.questions[0].stem
    xau.questions[2].options[1] = xau.questions[2].options[0]
    xau.questions[3].solution = ""
    if let i = xau.questions.firstIndex(where: { $0.part == 3 }) { xau.questions[i].rubric = [RubricStep(step: "x", points: 0.1)] }
    let r = ExamService.review(xau, m.blueprint)
    #expect(r.issues.contains { $0.contains("trùng với câu khác") } && r.issues.contains { $0.contains("phương án thiếu hoặc trùng") } && r.issues.contains { $0.contains("thiếu lời giải") } && r.issues.contains { $0.contains("thang chấm") })
    // Đề đúng có bảng bao phủ đầy đủ, mỗi hàng khớp.
    let ok = ExamService.review(ex, m.blueprint)
    #expect(ok.coverage.allSatisfy { $0.expected == $0.actual } && ok.coverage.count == Set(m.blueprint.slots.map { "\($0.part)|\($0.topic)|\($0.level)" }).count)
}

// MARK: Hồ sơ kiểm tra

@Test func hoSoKiemTraKemQuyDinhCoNguonVaXuatWord() async throws {
    let e = try await Moi(); defer { e.don() }
    let m = try await e.exam.readMatrix(path: try e.chep("ma-tran-mau.docx"))
    let ex = try await e.exam.generate(m.blueprint, yeuCau())
    let vs = try ExamService.versions(ex, codes: ["101", "102"])
    // Đề lệch ma trận thì chưa lập hồ sơ.
    var lech = ex; lech.questions.removeLast()
    await #expect(throws: PVTAError.self) { try await e.exam.saveDossier(name: "Hỏng", matrixSource: m.source, matrixIssues: [], blueprint: m.blueprint, exam: lech, versions: []) }
    let rong = try await e.exam.dossiers()
    #expect(rong.isEmpty)
    let d = try await e.exam.saveDossier(name: "Kiểm tra 15 phút – Lí 9", matrixSource: m.source, matrixIssues: m.reading.issues, blueprint: m.blueprint, exam: ex, versions: vs)
    #expect(d.review.passed && d.versions.count == 2 && !d.rules.isEmpty && d.rules.allSatisfy { !$0.source.isEmpty })
    let md = ExamService.dossierMarkdown(d)
    #expect(md.contains("Hồ sơ kiểm tra: Kiểm tra 15 phút") && md.contains("ĐẠT") && md.contains("Công văn 7991/BGDĐT-GDTrH") && md.contains("Quyết định 764/QĐ-BGDĐT") && md.contains("chưa đối chiếu bản gốc") && md.contains("Thang điểm dùng mặc định") && md.contains("dự thảo"))
    let ds = try await e.exam.dossiers()
    #expect(ds.map(\.id) == [d.id])
    // Xuất Word vào thư mục được cấp: đề học sinh, đáp án từng mã, hồ sơ; không ghi đè.
    let ra = try await e.exam.exportDocx(dossierId: d.id, folder: e.lam.path)
    #expect(ra.count == 5 && ra.allSatisfy { FileManager.default.fileExists(atPath: $0) } && ra.contains { $0.hasSuffix("de-101.docx") } && ra.contains { $0.hasSuffix("dap-an-102.docx") } && ra.contains { $0.hasSuffix("ho-so.docx") })
    let hs = try TextExtractor.extract(URL(fileURLWithPath: ra.first { $0.hasSuffix("de-101.docx") }!)).text
    #expect(hs.contains("Mã đề 101") && !hs.contains("Lời giải"))
    await #expect(throws: PVTAError.self) { try await e.exam.exportDocx(dossierId: d.id, folder: e.lam.path) }
    await #expect(throws: PVTAError.self) { try await e.exam.exportDocx(dossierId: d.id, folder: e.nha.path) }              // ngoài thư mục được cấp
    // Chỉ đọc: không xuất.
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.exam.exportDocx(dossierId: d.id, folder: e.lam.path) }
    try await e.exam.deleteDossier(id: d.id)
    let sau = try await e.exam.dossiers()
    #expect(sau.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.exam.deleteDossier(id: d.id) }
}

@Test func quyDinhRaDeDeuCoNguonVaGhiRoChuaDoiChieu() {
    #expect(ExamRules.all.count >= 5 && ExamRules.all.allSatisfy { !$0.source.isEmpty && !$0.text.isEmpty })
    #expect(Set(ExamRules.all.map(\.id)).count == ExamRules.all.count)
    // Quy định ngoài PVTA mới đối chiếu qua trang tin thì không được đánh dấu đã xác minh.
    for r in ExamRules.all where r.source.contains("Công văn") || r.source.contains("Quyết định") { #expect(!r.verified) }
}

// MARK: Cổng gọi và công cụ

@Test func suDungQuaCongGoiVaCongCuDoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let p = try e.chep("ma-tran-mau.docx")
    func goi(_ m: String, _ ps: JSONValue = [:]) async throws -> JSONValue { try await e.core.dispatch(m, ps, scoped: { _, _ in }) }
    let r = try await goi("assessment.readMatrix", ["path": .string(p), "scoring": ["part1PerQuestion": 0.5, "part2PerQuestion": 2]])
    #expect(r["blueprint"]?["totalPoints"]?.number == 8.5)                                   // 8×0,5 + 1×2 + 2,5
    await #expect(throws: PVTAError.self) { _ = try await goi("assessment.readMatrix", ["path": .string(p), "scoring": ["part1PerQuestion": 0, "part2PerQuestion": 1]]) }
    if case .array(let a) = try await goi("assessment.rules") { #expect(a.count == ExamRules.all.count) } else { Issue.record("rules") }
    let tool = try #require(e.core.tools.spec("exam_matrix"))
    #expect(tool.access == .read)
    let t = try await tool.run(["path": .string(p)])
    #expect(t.contains("Phần I: 8 câu") && t.contains("Phần II: 1 câu (4 ý)") && t.contains("2,5") || t.contains("2.5"))
    await #expect(throws: PVTAError.self) { try await tool.run(["path": "/etc/hosts"]) }
    // Đoạn nguồn từ tệp trong thư mục được cấp, ngoài thư mục thì từ chối.
    let nd = e.lam.appendingPathComponent("bai1.md"); try Data("# Bài 1\nTừ trường là gì.".utf8).write(to: nd)
    #expect(try await e.exam.passageText(path: PathGuard.canonical(nd.path) ?? nd.path).contains("Từ trường"))
    await #expect(throws: PVTAError.self) { try await e.exam.passageText(path: "/etc/hosts") }
}
