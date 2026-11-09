import Foundation
import PDFKit
import Testing
@testable import PVTACore

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



private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
private func source(_ e: Moi, _ name: String = "de-cuong.pdf") throws -> String {
    let dest = e.lam.appendingPathComponent(name)
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dest)
    return dest.path
}
private func call(_ e: Moi, _ method: String, _ args: JSONValue) async throws -> JSONValue {
    try await e.core.dispatch(method, args, scoped: { _, _ in })
}

@Test func pdfDocVungGopTachVaMoLai() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    let input = try source(e)
    let read = try await call(e, "pdf.read", ["path": .string(input)])
    #expect(read["pageCount"]?.number == 2)
    let region = try await call(e, "pdf.region", ["path": .string(input), "page": 1, "x": 60, "y": 700, "width": 500, "height": 50])
    #expect(region["text"]?.string?.contains("Trang mot") == true)
    let split = e.lam.appendingPathComponent("tach.pdf").path
    _ = try await call(e, "pdf.split", ["path": .string(input), "output": .string(split), "chatId": "thu", "pages": [2, 1]])
    let doc = try PDFService.document(Data(contentsOf: URL(fileURLWithPath: split)))
    #expect(doc.pageCount == 2 && doc.page(at: 0)?.string?.contains("Trang hai") == true)
    let merged = e.lam.appendingPathComponent("gop.pdf").path
    _ = try await call(e, "pdf.merge", ["paths": [.string(input), .string(split)], "output": .string(merged), "chatId": "thu"])
    let joined = try PDFService.document(Data(contentsOf: URL(fileURLWithPath: merged)))
    #expect(joined.pageCount == 4 && joined.page(at: 2)?.string?.contains("Trang hai") == true)
    #expect(try PDFService.document(Data(contentsOf: URL(fileURLWithPath: input))).pageCount == 2)
    await #expect(throws: PVTAError.self) { try await call(e, "pdf.split", ["path": .string(input), "output": .string(input), "chatId": "thu", "pages": [1]]) }
    await #expect(throws: PVTAError.self) { try await call(e, "pdf.region", ["path": .string(input), "page": 3, "x": 0, "y": 0, "width": 50, "height": 50]) }
}
@Test func pdfTrangKhongChuVaPhongViet() async throws {
    let e = try await Moi(); defer { e.don() }
    let input = try source(e, "trang-trong.pdf")
    let result = try await call(e, "pdf.read", ["path": .string(input)])
    guard case .array(let pages)? = result["pages"] else { Issue.record("Thiếu trang"); return }
    #expect(pages[0]["warning"]?.string?.contains("OCR") == true)
    let font = try await call(e, "pdf.font", [:])
    #expect(font["name"]?.string == "Arial")
    #expect(Data(base64Encoded: font["data"]?.string ?? "")?.isEmpty == false)
}
@Test func pdfGhiDoHuyVaSaiThuTu() async throws {
    let e = try await Moi(); defer { e.don() }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("de-cuong.pdf"))
    let path = e.lam.appendingPathComponent("ghi.pdf").path
    let id = try await e.core.pdf.begin(path: path, chat: "thu", size: data.count)
    _ = try await e.core.pdf.chunk(id: id, chat: "thu", offset: 0, base64: data.prefix(100).base64EncodedString())
    await #expect(throws: PVTAError.self) { try await e.core.pdf.chunk(id: id, chat: "thu", offset: 0, base64: data.base64EncodedString()) }
    await #expect(throws: PVTAError.self) { try await e.core.pdf.abort(id: id, chat: "khac") }
    try await e.core.pdf.abort(id: id, chat: "thu")
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.lam.path).isEmpty)
    await #expect(throws: PVTAError.self) { try await e.core.pdf.finish(id: id, chat: "thu") }
    let short = try await e.core.pdf.begin(path: path, chat: "thu", size: data.count)
    _ = try await e.core.pdf.chunk(id: short, chat: "thu", offset: 0, base64: data.prefix(100).base64EncodedString())
    await #expect(throws: PVTAError.self) { try await e.core.pdf.finish(id: short, chat: "thu") }
    #expect(!FileManager.default.fileExists(atPath: path))
}
@Test func pdfGhiDayDuQuaRPCVaQuyen() async throws {
    let e = try await Moi(); defer { e.don() }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("de-cuong.pdf"))
    let path = e.lam.appendingPathComponent("ghi.pdf").path
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    let id = try #require(try await call(e, "pdf.writeBegin", ["path": .string(path), "chatId": "thu", "size": .number(Double(data.count))]).string)
    let cut = data.count / 2
    _ = try await call(e, "pdf.writeChunk", ["id": .string(id), "chatId": "thu", "offset": 0, "data": .string(data.prefix(cut).base64EncodedString())])
    _ = try await call(e, "pdf.writeChunk", ["id": .string(id), "chatId": "thu", "offset": .number(Double(cut)), "data": .string(data.dropFirst(cut).base64EncodedString())])
    #expect(!FileManager.default.fileExists(atPath: path))
    let result = try await call(e, "pdf.writeFinish", ["id": .string(id), "chatId": "thu"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    _ = try await e.f.undo(id: result.requireString("changeId"))
    #expect(!FileManager.default.fileExists(atPath: path))
    await #expect(throws: PVTAError.self) { try await e.core.pdf.begin(path: e.ngoai.appendingPathComponent("x.pdf").path, chat: "thu", size: 100) }
    let bad = try await e.core.pdf.begin(path: path, chat: "thu", size: 10)
    _ = try await e.core.pdf.chunk(id: bad, chat: "thu", offset: 0, base64: Data("1234567890".utf8).base64EncodedString())
    await #expect(throws: PVTAError.self) { try await e.core.pdf.finish(id: bad, chat: "thu") }
    #expect(!FileManager.default.fileExists(atPath: path))
}
@Test func pdfChoDuyetTuChoiVaChiDoc() async throws {
    let e = try await Moi(); defer { e.don() }
    let input = try source(e), output = e.lam.appendingPathComponent("duyet.pdf").path
    let task = Task { try await e.core.pdf.combine(paths: [input], pages: [1], output: output, chat: "thu") }
    var proposal: ActionProposal?
    for _ in 0..<200 {
        proposal = await e.core.permissions.queue.list().first { $0.state == .pending }
        if proposal != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let p = try #require(proposal)
    #expect(!FileManager.default.fileExists(atPath: output))
    try await e.core.permissions.queue.decline(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output))
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.core.pdf.combine(paths: [input], pages: [1], output: output, chat: "thu") }
}

@Test func pdfHuyTrongLucChoDuyetKhongCongBo() async throws {
    let e = try await Moi(); defer { e.don() }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("pdf-tieng-viet.pdf"))
    let path = e.lam.appendingPathComponent("huy.pdf").path
    let id = try await e.core.pdf.begin(path: path, chat: "thu", size: data.count)
    _ = try await e.core.pdf.chunk(id: id, chat: "thu", offset: 0, base64: data.base64EncodedString())
    let task = Task { try await e.core.pdf.finish(id: id, chat: "thu") }
    var proposal: ActionProposal?
    for _ in 0..<200 {
        proposal = await e.core.permissions.queue.list().first { $0.state == .pending }
        if proposal != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let p = try #require(proposal)
    try await e.core.pdf.abort(id: id, chat: "thu")
    try await e.core.permissions.queue.approve(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func pdfTiengVietVaAnhQuet() async throws {
    let e = try await Moi(); defer { e.don() }
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    let viet = try source(e, "pdf-tieng-viet.pdf"), scan = try source(e, "pdf-anh-quet.pdf")
    let output = e.lam.appendingPathComponent("hon-hop.pdf").path
    _ = try await e.core.pdf.combine(paths: [viet, scan], pages: nil, output: output, chat: "thu")
    let result = try await e.core.pdf.read(path: output, chat: nil)
    guard case .array(let pages)? = result["pages"] else { Issue.record("Thiếu trang"); return }
    #expect(pages[0]["text"]?.string?.contains("Tiếng Việt") == true)
    #expect(pages[0]["text"]?.string?.contains("ă â đ ê ô ơ ư") == true)
    #expect(pages[1]["warning"]?.string?.contains("OCR") == true)
}
