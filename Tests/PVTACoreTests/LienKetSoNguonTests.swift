import Foundation
import Testing
@testable import PVTACore

private struct Moi {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("lk-\(UUID().uuidString.prefix(8))", isDirectory: true))
    let nguon = FileManager.default.temporaryDirectory.appendingPathComponent("lkng-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let mang = FakeTransport((0..<8).map { _ in FakeTransport.Reply(lines: claudeSSE(["ok"])) })
    let core: Core
    var nb: NotebookService { core.notebooks }
    init() async throws {
        try FileManager.default.createDirectory(at: nguon, withIntermediateDirectories: true)
        let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai)
        _ = try await core.permissions.addGrant(path: nguon.path, write: false)
    }
    func don() { for u in [paths.home, nguon] { try? FileManager.default.removeItem(at: u) } }
    func sổ(_ ten: String, _ file: String, _ nd: String) async throws -> (Notebook, NotebookSource) {
        let p = nguon.appendingPathComponent(file); try Data(nd.utf8).write(to: p)
        let n = try await nb.create(name: ten)
        return (n, try await nb.addFile(n.id, path: p.path))
    }
    func gui(_ chat: String, _ text: String) async throws -> String {
        let n = mang.requests.count
        _ = try await core.chat.send(chatId: chat, text: text, model: "anthropic/claude-haiku-5-5", emit: { _, _ in })
        let body = (try? JSONDecoder().decode(JSONValue.self, from: mang.requests[n].httpBody ?? Data())) ?? .null
        if let t = body["system"]?.string { return t }
        if case .array(let b)? = body["system"] { return b.compactMap { $0["text"]?.string }.joined(separator: "\n") }
        return ""
    }
}

@Test func lienKetKiemTraPhamViDoiTuongVaSoKhongCo() async throws {
    let e = try await Moi(); defer { e.don() }
    let (a, _) = try await e.sổ("A", "a.txt", "Nội dung sổ A về hệ số điểm.")
    let chat = try await e.core.store.createChat().id
    await #expect(throws: PVTAError.self) { try await e.nb.setLinks(scope: "tuan", id: chat, notebookIds: [a.id]) }
    await #expect(throws: PVTAError.self) { try await e.nb.setLinks(scope: "chat", id: "khong-co", notebookIds: [a.id]) }
    await #expect(throws: PVTAError.self) { try await e.nb.setLinks(scope: "project", id: "khong-co", notebookIds: [a.id]) }
    await #expect(throws: PVTAError.self) { try await e.nb.setLinks(scope: "workflow", id: "khong-co", notebookIds: [a.id]) }
    await #expect(throws: PVTAError.self) { try await e.nb.links(scope: "xyz", id: chat) }
    // Sổ không tồn tại bị bỏ qua, trùng chỉ giữ một, giữ thứ tự.
    let b = try await e.nb.create(name: "B")
    #expect(try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: [b.id, "khong-co", a.id, b.id]) == [b.id, a.id])
    #expect(try await e.nb.links(scope: "chat", id: chat) == [b.id, a.id])
    #expect(try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: []).isEmpty)                         // thay toàn bộ
    // Tối đa 12 sổ.
    var ids: [String] = []
    for i in 0..<14 { ids.append(try await e.nb.create(name: "S\(i)").id) }
    #expect(try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: ids).count == 12)
}

@Test func soLienKetDuaDoanKhopVaoNguCanhVaSoTatNguonThiKhong() async throws {
    let e = try await Moi(); defer { e.don() }
    let (a, sa) = try await e.sổ("Quy chế", "quy-che.txt", "Bài kiểm tra giữa kì có hệ số hai theo quy chế nhà trường.")
    let (b, _) = try await e.sổ("Riêng", "rieng.txt", "Tài liệu riêng về cảm biến siêu âm cho robot.")
    let chat = try await e.core.store.createChat().id
    let q = "kiểm tra giữa kì hệ số mấy và cảm biến siêu âm"
    // Chưa liên kết: không có sổ nào trong ngữ cảnh.
    let truoc = try await e.gui(chat, q)
    #expect(!truoc.contains("SỔ NGUỒN ĐÃ LIÊN KẾT") && !truoc.contains("hệ số hai"))
    try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: [a.id])
    let sau = try await e.gui(chat, q)
    #expect(sau.contains("SỔ NGUỒN ĐÃ LIÊN KẾT") && sau.contains("[Sổ “Quy chế” · quy-che.txt]") && sau.contains("hệ số hai"))
    #expect(!sau.contains("cảm biến siêu âm") && !sau.contains("Sổ “Riêng”"))                                // sổ chưa liên kết không rò vào
    // Tắt nguồn thì đoạn không xuất hiện nữa (chỉ còn tên sổ để model biết).
    try await e.nb.setEnabled(sa.id, false)
    let tat = try await e.gui(chat, q)
    #expect(!tat.contains("hệ số hai") && tat.contains("Không có đoạn nào khớp"))
    try await e.nb.setEnabled(sa.id, true)
    try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: [a.id, b.id])
    let hai = try await e.gui(chat, q)
    #expect(hai.contains("hệ số hai") && hai.contains("[Sổ “Riêng” · rieng.txt]") && hai.contains("cảm biến siêu âm"))
    // Gỡ liên kết: hết.
    try await e.nb.setLinks(scope: "chat", id: chat, notebookIds: [])
    #expect(!(try await e.gui(chat, q)).contains("SỔ NGUỒN ĐÃ LIÊN KẾT"))
}

@Test func lienKetCuaDuAnApDungChoMoiHoiThoaiTrongDuAn() async throws {
    let e = try await Moi(); defer { e.don() }
    let (a, _) = try await e.sổ("Chung", "chung.txt", "Quy định chung của dự án: nộp báo cáo trước ngày mười lăm.")
    let (b, _) = try await e.sổ("Của chat", "chat.txt", "Ghi chú riêng của hội thoại: dùng màu xanh cho tiêu đề.")
    let p = try await e.core.store.createProject(name: "D")
    let trong = try await e.core.store.createChat(title: "x", projectId: p.id).id
    let ngoai = try await e.core.store.createChat().id
    try await e.nb.setLinks(scope: "project", id: p.id, notebookIds: [a.id])
    try await e.nb.setLinks(scope: "chat", id: trong, notebookIds: [b.id, a.id])
    let books = try await e.nb.linkedNotebooks(chatId: trong)
    #expect(books.map(\.name) == ["Chung", "Của chat"])                                                       // của dự án trước, không trùng
    let q = "nộp báo cáo ngày nào và màu tiêu đề"
    let s1 = try await e.gui(trong, q)
    #expect(s1.contains("nộp báo cáo trước ngày mười lăm") && s1.contains("màu xanh cho tiêu đề"))
    let s2 = try await e.gui(ngoai, q)                                                                         // hội thoại ngoài dự án không được hưởng
    #expect(!s2.contains("SỔ NGUỒN ĐÃ LIÊN KẾT"))
    #expect(try await e.nb.linkedNotebooks(chatId: ngoai).isEmpty)
}

@Test func xoaHoiThoaiHoacSoThiLienKetBiDonVaPhuongThucQuaCongGoi() async throws {
    let e = try await Moi(); defer { e.don() }
    func call(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await e.core.dispatch(m, p, scoped: { _, _ in }) }
    let (a, _) = try await e.sổ("A", "a.txt", "Nội dung A.")
    let c1 = try await e.core.store.createChat().id, c2 = try await e.core.store.createChat().id
    _ = try await call("nb.setLinks", ["scope": "chat", "id": .string(c1), "notebookIds": [.string(a.id)]])
    _ = try await call("nb.setLinks", ["scope": "chat", "id": .string(c2), "notebookIds": [.string(a.id)]])
    try await e.core.store.deleteChat(id: c1)
    _ = try await call("nb.setLinks", ["scope": "chat", "id": .string(c2), "notebookIds": [.string(a.id)]])     // lần ghi sau dọn liên kết mồ côi
    #expect(try await e.core.store.notebookLinks(scope: "chat", id: c1).isEmpty)
    #expect(try await call("nb.links", ["scope": "chat", "id": .string(c2)]) == [.string(a.id)])
    try await e.nb.delete(a.id)
    #expect(try await call("nb.links", ["scope": "chat", "id": .string(c2)]) == [])
    await #expect(throws: PVTAError.self) { _ = try await call("nb.setLinks", ["scope": "chat", "id": "khong-co", "notebookIds": []]) }
}

@Test func lienKetVoiQuyTrinhDaCoTrongKhoTuDong() async throws {
    let e = try await Moi(); defer { e.don() }
    let (a, _) = try await e.sổ("A", "a.txt", "Nội dung A.")
    try await e.core.store.setSetting("automation.v1", #"{"wf-1":{"id":"wf-1"}}"#)
    #expect(try await e.nb.setLinks(scope: "workflow", id: "wf-1", notebookIds: [a.id]) == [a.id])
    #expect(try await e.nb.links(scope: "workflow", id: "wf-1") == [a.id])
    await #expect(throws: PVTAError.self) { try await e.nb.setLinks(scope: "workflow", id: "wf-khac", notebookIds: [a.id]) }
}
