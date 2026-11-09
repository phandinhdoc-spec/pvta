import Foundation
import Testing
@testable import PVTACore

private struct MathEnv {
    let root: URL
    let output: URL
    let paths: DataPaths
    let core: Core
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("math37-" + UUID().uuidString)
        output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        paths = DataPaths(home: root.appendingPathComponent("data")); try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore(), transport: FakeTransport([]), retry: .none, cli: Gia().moi()), approvalTimeout: .seconds(5))
        _ = try await core.permissions.addGrant(path: output.path, write: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ args: JSONValue = [:]) async throws -> JSONValue { try await core.dispatch(method, args, scoped: { _, _ in }) }
    func save(_ title: String = "Phân số", latex: String = #"\frac{a}{b}"#) async throws -> MathFormula {
        try await call("math.save", ["title": .string(title), "subject": "math", "latex": .string(latex)]).decode(MathFormula.self)
    }
    func params(_ items: [MathFormula], name: String = "cong-thuc.docx") -> JSONValue {
        ["path": .string(output.appendingPathComponent(name).path), "chatId": "math-test", "title": "Công thức Toán Lý Hóa", "items": .array(items.map { ["id": .string($0.id), "revision": .number(Double($0.revision))] })]
    }
    func pending() async throws -> ActionProposal {
        for _ in 0..<200 {
            if let p = await core.permissions.queue.list().first(where: { $0.state == .pending }) { return p }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PVTAError("Không thấy yêu cầu duyệt xuất công thức.")
    }
}

@Test func math37LuuSuaLietKeVaMoLaiKho() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    let item = try await e.save()
    #expect(item.revision == 1)
    let edited = try await e.call("math.save", ["id": .string(item.id), "baseRevision": 1, "title": "Động năng", "subject": "physics", "latex": #"E=\frac{mv^2}{2}"#]).decode(MathFormula.self)
    #expect(edited.id == item.id && edited.revision == 2)
    await #expect(throws: PVTAError.self) { try await e.call("math.save", ["id": .string(item.id), "baseRevision": 1, "title": "Cũ", "subject": "math", "latex": "x"]) }
    #expect(try await e.call("math.list", ["subject": "math"]) == .array([]))
    #expect(try await e.call("math.list", ["subject": "physics"]).decode([MathFormula].self) == [edited])
    let reopened = try DataStore(file: e.paths.database)
    let persisted = try #require(await reopened.mathFormulas().first)
    #expect(persisted.id == edited.id && persisted.revision == edited.revision && persisted.latex == edited.latex)
    #expect(abs(persisted.updatedAt.timeIntervalSince(edited.updatedAt)) < 0.001)
    #expect(String(decoding: try await e.core.store.exportJSON(), as: UTF8.self).contains("math.workshop.v1"))
}

@Test func math37CongThucSaiVaKhoHongKhongBiGhiDe() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    for latex in ["", #"\frac{a}"#, #"\unknown{x}"#, "x\u{01}", String(repeating: "x", count: 8001)] {
        await #expect(throws: PVTAError.self) { try await e.save(latex: latex) }
    }
    await #expect(throws: PVTAError.self) { try await e.call("math.save", ["title": "Sai môn", "subject": "other", "latex": "x"]) }
    #expect(try await e.call("math.list") == .array([]))
    try await e.core.store.setSetting("math.workshop.v1", "{hỏng")
    await #expect(throws: PVTAError.self) { try await e.save() }
    #expect(try await e.core.store.setting("math.workshop.v1") == "{hỏng")
}

@Test func math37XuatMauToanLyHoaThanhEquationWord() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/math-workshop.json")
    let inputs = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: fixture))
    var formulas: [MathFormula] = []
    for input in inputs { formulas.append(try await e.call("math.save", input).decode(MathFormula.self)) }
    let params = e.params(formulas)
    let task = Task { try await e.call("math.export", params) }
    let p = try await e.pending()
    #expect(p.tool == "math_export" && p.preview.contains("\\ce{"))
    #expect(!FileManager.default.fileExists(atPath: params["path"]!.string!))
    try await e.core.permissions.queue.approve(id: p.id)
    let result = try await task.value
    let url = URL(fileURLWithPath: try result.requireString("path")), bytes = try Data(contentsOf: url)
    #expect(result["count"] == 7 && result["format"] == "docx-omml")
    let zip = try ZipArchive(data: bytes)
    for name in zip.names where name.hasSuffix(".xml") || name.hasSuffix(".rels") { _ = try XMLDocument(data: #require(try zip.read(name)), options: []) }
    let xml = try XMLDocument(data: #require(try zip.read("word/document.xml")), options: [])
    #expect(try xml.nodes(forXPath: "//*[local-name()='oMath']").count == 7)
    #expect(try xml.nodes(forXPath: "//*[local-name()='f']").count == 4)
    #expect(try xml.nodes(forXPath: "//*[local-name()='sSubSup']").count >= 1)
    #expect(xml.xmlString.contains("⇌") && xml.xmlString.contains("→"))
    #expect(!zip.names.contains { $0.hasPrefix("word/media/") })
    #expect(try Docx.outline(bytes).contains("Động năng"))
    #expect(try TextExtractor.extract(url).text.contains("Cân bằng ammonia"))
    let previous = bytes
    await #expect(throws: PVTAError.self) { try await e.call("math.export", params) }
    #expect(try Data(contentsOf: url) == previous)
    // Chỉ giữ mẫu khi người chạy test chủ động chọn một thư mục tạm để mở bằng Word thật.
    if let qa = ProcessInfo.processInfo.environment["PVTA_MATH_QA_DIR"] {
        let dir = URL(fileURLWithPath: qa).resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard dir.path.hasPrefix(temp + "/") || (dir.path.hasPrefix("/private/tmp/") || dir.path.hasPrefix("/tmp/")) else { throw PVTAError("Mẫu kiểm tra chỉ được giữ trong thư mục tạm.") }
        try bytes.write(to: dir.appendingPathComponent("cong-thuc.docx"), options: .withoutOverwriting)
    }
}

@Test func math37TuChoiDuyetChiDocVaNgoaiPhamVi() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    let item = try await e.save(), params = e.params([item])
    let task = Task { try await e.call("math.export", params) }
    let p = try await e.pending(); try await e.core.permissions.queue.decline(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: params["path"]!.string!))
    _ = try await e.core.permissions.setLevel(.readOnly, acknowledge: false)
    await #expect(throws: PVTAError.self) { try await e.call("math.export", params) }
    await #expect(throws: PVTAError.self) { try await e.save() }
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    await #expect(throws: PVTAError.self) { try await e.call("math.export", ["path": .string(e.root.appendingPathComponent("outside.docx").path), "chatId": "math-test", "items": params["items"]!]) }
    await #expect(throws: PVTAError.self) { try await e.call("math.export", e.params([item], name: "sai.pdf")) }
}

@Test func math37DoiCongThucTrongLucDuyetVaHuy() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    let item = try await e.save(), params = e.params([item])
    let task = Task { try await e.call("math.export", params) }
    let p = try await e.pending()
    _ = try await e.call("math.save", ["id": .string(item.id), "baseRevision": 1, "title": "Mới", "subject": "math", "latex": "y"])
    try await e.core.permissions.queue.approve(id: p.id)
    await #expect(throws: PVTAError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: params["path"]!.string!))
    await #expect(throws: PVTAError.self) { try await e.call("math.export", params) }
    let other = try await e.save("Mục mới")
    let cancel = Task { try await e.call("math.export", e.params([other])) }
    _ = try await e.pending(); cancel.cancel()
    await #expect(throws: Error.self) { try await cancel.value }
    #expect(!FileManager.default.fileExists(atPath: params["path"]!.string!))
}

@Test func math37TuSuaVaDanhSachTrungBiChan() async throws {
    let e = try await MathEnv(); defer { e.clean() }
    let item = try await e.save()
    _ = try await e.core.permissions.setLevel(.autoEdit, acknowledge: true)
    await #expect(throws: PVTAError.self) { try await e.call("math.export", e.params([item, item])) }
    let result = try await e.call("math.export", e.params([item]))
    #expect(FileManager.default.fileExists(atPath: result["path"]!.string!))
    #expect(try await e.core.store.fileChanges().count == 1)
}
