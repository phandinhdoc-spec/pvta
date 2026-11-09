import Foundation
import Testing
import PDFKit
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
private func proposal(_ e: Moi) async throws -> ActionProposal {
    for _ in 0..<300 {
        if let p = await e.core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PVTAError("Không xuất hiện yêu cầu duyệt.")
}
@Test func typstXuatDuBonPhanVaDocMau() async throws {
    let e = try await Moi(); defer { e.don() }
    for name in ["typst-mau.typ", "typst-nguon.md"] { try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: e.lam.appendingPathComponent(name)) }
    let output = e.lam.appendingPathComponent("ket-qua.zip").path
    let args: JSONValue = ["chatId": "thu", "path": .string(e.lam.appendingPathComponent("typst-nguon.md").path), "templates": [.string(e.lam.appendingPathComponent("typst-mau.typ").path)], "output": .string(output)]
    let task = Task { try await e.core.dispatch("typst.export", args, scoped: { _, _ in }) }
    let p = try await proposal(e)
    #expect(p.preview.contains("24mm") && !FileManager.default.fileExists(atPath: output))
    try await e.core.permissions.queue.approve(id: p.id)
    let result = try await task.value
    let zip = try ZipArchive(data: Data(contentsOf: URL(fileURLWithPath: output)))
    #expect(Set(zip.names) == Set(["document.pdf", "document.typ", "preview-1.png", "README.txt"]))
    let pdf = try #require(try zip.read("document.pdf"))
    let text = try #require(PDFDocument(data: pdf)?.string)
    #expect(text.contains("12345") && text.contains("cuối tài liệu") && text.contains("Đáp án"))
    let code = String(decoding: try zip.read("document.typ")!, as: UTF8.self)
    #expect(code.contains("24mm") && code.contains("13pt") && code.contains("164B36") && code.contains("8pt"))
    await #expect(throws: PVTAError.self) { try await e.f.typstExport(args) }
    if ProcessInfo.processInfo.environment["PVTA_KEEP_TYPST"] == "1" {
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("pvta19-" + UUID().uuidString + ".png")
        try zip.read("preview-1.png")!.write(to: preview)
        print("TYPST_QA=" + preview.path)
    }
    _ = try await e.f.undo(id: result.requireString("changeId"))
}
@Test func typstLoiBienDichKhongCongBo() async throws {
    let e = try await Moi(); defer { e.don() }
    let output = e.lam.appendingPathComponent("loi.zip").path
    let task = Task { try await e.f.typstExport(["chatId": "thu", "text": "#let x = (", "format": "typst", "output": .string(output)]) }
    let p = try await proposal(e)
    try await e.core.permissions.queue.approve(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.lam.path).isEmpty)
}
@Test func typstThieuDuLieuVaTaiNguyenNgoaiBiChan() async throws {
    let e = try await Moi(); defer { e.don() }
    let output = e.lam.appendingPathComponent("x.zip").path
    for text in ["", "![Ảnh](missing.png)", "| A | B |\n| 1 |", "```swift\nlet a = 1"] {
        await #expect(throws: PVTAError.self) { try await e.f.typstExport(["chatId": "thu", "text": .string(text), "output": .string(output)]) }
    }
    await #expect(throws: PVTAError.self) { try await e.f.typstExport(["chatId": "thu", "text": "#read(\"/etc/passwd\")", "format": "typst", "output": .string(output)]) }
    await #expect(throws: PVTAError.self) { try await e.f.typstExport(["chatId": "thu", "text": "Nội dung", "templates": [.string(e.lam.appendingPathComponent("thieu.typ").path)], "output": .string(output)]) }
    #expect(await e.core.permissions.queue.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: output))
}
@Test func typstTuChoiVaChiDocKhongTaoTep() async throws {
    let e = try await Moi(); defer { e.don() }
    let output = e.lam.appendingPathComponent("x.zip").path
    let args: JSONValue = ["chatId": "thu", "text": "Văn bản", "output": .string(output)]
    let task = Task { try await e.f.typstExport(args) }
    let p = try await proposal(e)
    try await e.core.permissions.queue.decline(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.f.typstExport(args) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: e.lam.path).isEmpty)
}

@Test func typstHetGioKhongCoZip() async throws {
    let e = try await Moi(); defer { e.don() }
    let output = e.lam.appendingPathComponent("qua-han.zip").path
    let task = Task { try await e.f.typstExport(["chatId": "thu", "text": "#while true {}", "format": "typst", "output": .string(output)], compileTimeout: .milliseconds(100)) }
    let p = try await proposal(e)
    try await e.core.permissions.queue.approve(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output))
}

@Test func typstMauMarkdownVaVanBanKhongThucThiMa() throws {
    var layout = TypstLayout()
    layout.learn("""
# Mẫu

## Mục

| A |
| --- |
| B |
""", name: "mau.md")
    #expect(layout.evidence[0].contains("phân cấp") && layout.evidence[0].contains("hàng đầu"))
    let code = try layout.convert("""
#read("/etc/passwd")
Dòng cuối
""", markdown: false)
    #expect(code.contains("#text(") && code.contains("/etc/passwd"))
    #expect(code.contains("Dòng cuối"))
}
