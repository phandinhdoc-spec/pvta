import Foundation
import Testing
@testable import PVTACore

@Test func taoVaSuaPowerPoint() throws {
    let original = try Pptx.create(slides: [
        ["layout": "title", "title": "Khoa học & đời sống", "text": "Lớp 8"],
        ["layout": "twoColumns", "title": "So sánh", "left": "Chất rắn", "right": "Chất lỏng"]
    ], subject: "Khoa học tự nhiên")
    #expect(try Pptx.read(original).contains("Chất lỏng"))
    let edited = try Pptx.edit(original, ops: [
        ["op": "text", "slide": 2, "shape": 3, "text": "Nội dung đã sửa"],
        ["op": "style", "slide": 2, "shape": 3, "font": "Georgia", "color": "FF0000"],
        ["op": "move", "slide": 2, "shape": 3, "x": 2, "y": 4]
    ])
    #expect(try Pptx.read(edited).contains("Nội dung đã sửa"))
    #expect(try Pptx.read(original).contains("Chất rắn"))
    let before = try ZipArchive(data: original), after = try ZipArchive(data: edited)
    for name in before.names where name != "ppt/slides/slide2.xml" { #expect(try before.read(name) == after.read(name)) }
    let slide = String(decoding: try after.read("ppt/slides/slide2.xml")!, as: UTF8.self)
    #expect(slide.contains("FF0000") && slide.contains("Georgia") && slide.contains("1440000"))
    for name in after.names where name.hasSuffix(".xml") || name.hasSuffix(".rels") { _ = try Pptx.xml(after.read(name)!) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { if ProcessInfo.processInfo.environment["PVTA_KEEP_PPTX"] != "1" { try? FileManager.default.removeItem(at: dir) } }
    let file = dir.appendingPathComponent("mau.pptx")
    try edited.write(to: file)
    if ProcessInfo.processInfo.environment["PVTA_KEEP_PPTX"] == "1" { print("PPTX_QA=" + file.path) }
    #expect(try Pptx.read(Data(contentsOf: file)).contains("Nội dung đã sửa"))
}

@Test func powerPointTuChoiDuLieuSai() throws {
    #expect(throws: PVTAError.self) { try Pptx.create(slides: [], subject: nil) }
    let data = try Pptx.create(slides: [["title": "Toán"]], subject: "Toán")
    #expect(throws: PVTAError.self) { try Pptx.edit(data, ops: [["op": "text", "slide": 5, "shape": 2, "text": "x"]]) }
    #expect(throws: PVTAError.self) { try Pptx.edit(data, ops: [["op": "style", "slide": 1, "shape": 2, "color": "sai"]]) }
    #expect(throws: PVTAError.self) { try Pptx.xml(Data("<!DOCTYPE x><x/>".utf8)) }
    #expect(Pptx.theme("Ngữ văn").1 == "Georgia")
    #expect(Pptx.theme("Sinh học").0 == "16714B")
}

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


@Test func powerPointQuyenVaBanSao() async throws {
    let e = try await Moi(); defer { e.don() }
    let path = e.lam.appendingPathComponent("mau.pptx").path
    let args: JSONValue = ["path": .string(path), "slides": [["title": "Bài học"]]]
    let tool = e.tool("powerpoint_create")
    #expect(tool.access == .write)
    _ = try await tool.plan!(args)
    #expect(!FileManager.default.fileExists(atPath: path))
    _ = try await tool.run(args)
    let original = try Data(contentsOf: URL(fileURLWithPath: path))
    let result = try await e.f.powerpointEdit(path: path, output: nil, ops: [["op": "text", "slide": 1, "shape": 2, "text": "Mới"]], chatId: nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
    await #expect(throws: PVTAError.self) { try await e.f.powerpointEdit(path: path, output: path, ops: [["op": "text", "slide": 1, "shape": 2, "text": "Sai"]], chatId: nil) }
    await #expect(throws: PVTAError.self) { try await e.f.powerpointCreate(path: e.ngoai.appendingPathComponent("x.pptx").path, subject: nil, slides: [["title": "Sai"]], chatId: nil) }
    _ = try await e.f.undo(id: result.change.id)
    #expect(!FileManager.default.fileExists(atPath: result.change.path))
    #expect(e.core.methods.contains("powerpoint.create"))
}

@Test func powerPointChuDeVaTepMau() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/powerpoint-mau.pptx")
    #expect(try Pptx.read(Data(contentsOf: file)).contains("Nội dung đã sửa"))
    let data = try Pptx.create(slides: [["title": "Văn học"]], subject: "Ngữ văn")
    let z = try ZipArchive(data: data)
    let theme = try #require(try z.read("ppt/theme/theme1.xml"))
    #expect(String(decoding: theme, as: UTF8.self).contains("Georgia"))
    let links = try #require(try z.read("ppt/slideMasters/_rels/slideMaster1.xml.rels"))
    #expect(String(decoding: links, as: UTF8.self).contains("../theme/theme1.xml"))
}
