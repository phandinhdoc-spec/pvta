import Foundation
import Testing
@testable import PVTACore

private func lyDo(_ s: String) -> String { s }

@Test func mucLucTheoNhomVaMoiChuongCoNoiDung() {
    let h = HelpService()
    let toc = h.toc()
    #expect(toc.count >= 5 && toc.first?.group == "Bắt đầu")
    let ids = toc.flatMap { $0.chapters.map(\.id) }
    #expect(Set(ids).count == ids.count && ids.count == HelpContent.all.count)
    let numbers = toc.flatMap { $0.chapters.map(\.number) }
    #expect(numbers.sorted() == Array(1...ids.count))                                                      // đánh số liên tục
    for c in HelpContent.all {
        #expect(c.body.count > 150 && !c.title.isEmpty, "\(c.id)")
        #expect(!c.body.lowercased().contains("add-in") && !c.body.contains("Office.js"), "\(c.id) còn nhắc add-in")
    }
    #expect(h.chapter("quyen")?.title == "Ba mức quyền và duyệt thao tác" && h.chapter("khong-co") == nil)
}

@Test func traCuuCoDauVaKhongDauChoCungKetQua() {
    let h = HelpService()
    let pairs = [("duyệt thao tác", "duyet thao tac"), ("chế độ viết", "che do viet"), ("sổ nguồn trích dẫn", "so nguon trich dan"), ("bảng tính công thức", "bang tinh cong thuc")]
    for (co, khong) in pairs {
        let a = h.search(co).map(\.chapter), b = h.search(khong).map(\.chapter)
        #expect(!a.isEmpty && a == b, "\(co)")
    }
    #expect(h.search("duyệt thao tác").first?.chapter == "quyen")
    #expect(h.search("che do viet").first?.chapter == "che-do-viet")
    #expect(h.search("so nguon trich dan").first?.chapter == "so-nguon")
    #expect(h.search("excel cong thuc").first?.chapter == "excel")
    #expect(h.search("thu muc hoc hoi 60 tep").first?.chapter == "du-an")
    #expect(h.search("tra cuu ma nguon ky hieu").first?.chapter == "tra-cuu-ma")
    #expect(h.search("zzzqqq khong co").isEmpty && h.search("   ").isEmpty)
}

@Test func hoiPVTATraLoiBangTrichDoanVaYeuCauNeuTenChucNangKhiKhongCoCanCu() {
    let h = HelpService()
    let a = h.ask(question: "Chỗ này dùng như thế nào?", label: "Nút Duyệt thao tác", x: 120, y: 340)
    #expect(a.found && a.sources.first?.chapter == "quyen" && a.label == "Nút Duyệt thao tác" && a.x == 120 && a.y == 340)
    #expect(a.sources.allSatisfy { !$0.text.isEmpty })
    let b = h.ask(question: nil, label: "Chọn mô hình")                                                      // chỉ có nhãn: dùng nhãn làm câu hỏi
    #expect(b.found && b.sources.first?.chapter == "mo-hinh-ai")
    let c = h.ask(question: "hôm nay trời đẹp không", label: nil)
    #expect(!c.found && c.sources.isEmpty && c.message.contains("nêu tên chức năng cụ thể"))
    let d = h.ask(question: "", label: nil)
    #expect(!d.found && d.message.contains("tên chức năng"))
    // Nhãn và câu hỏi bị cắt ngắn, không mang theo nội dung dài (ví dụ giá trị ô nhập).
    let dai = String(repeating: "a", count: 500)
    #expect(h.ask(question: nil, label: dai).label?.count == 80)
    #expect(h.ask(question: dai, label: nil).message.count < 400)
}

@Test func hoiPVTAKhongGoiModelAIVaKhongDungDuLieuHoiThoai() async throws {
    let paths = DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("hd-\(UUID().uuidString.prefix(8))", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: paths.home) }
    let mang = FakeTransport([])                                                                           // mọi lời gọi mạng/model sẽ bị ghi lại
    let keys = MemoryKeyStore(); try keys.save("k", provider: "anthropic")
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
    try paths.prepare()
    let core = Core(store: try DataStore(file: paths.database), ai: ai)
    // Có một hội thoại chứa nội dung riêng; hướng dẫn không được dùng tới.
    let chat = try await core.store.createChat(title: "Bí mật BI-MAT-12345").id
    try await core.store.appendMessage(chatId: chat, role: .user, text: "Nội dung riêng BI-MAT-12345 về học sinh")
    func call(_ m: String, _ p: JSONValue) async throws -> JSONValue { try await core.dispatch(m, p, scoped: { _, _ in }) }
    let toc = try await call("help.toc", [:])
    if case .array(let g) = toc { #expect(!g.isEmpty) } else { Issue.record("toc") }
    #expect(try await call("help.chapter", ["id": "quyen"])["title"]?.string == "Ba mức quyền và duyệt thao tác")
    await #expect(throws: PVTAError.self) { _ = try await call("help.chapter", ["id": "khong-co"]) }
    let s = try await call("help.search", ["query": "duyet thao tac"])
    if case .array(let a) = s { #expect(a.first?["chapter"]?.string == "quyen") } else { Issue.record("search") }
    let ans = try await call("help.ask", ["question": "BI-MAT-12345", "label": "Ô nhập"])
    #expect(ans["found"]?.bool == false)                                                                    // nội dung hội thoại không có trong hướng dẫn
    let ans2 = try await call("help.ask", ["question": "Chỗ này dùng như thế nào?", "label": "Quy tắc #khóa", "x": 10, "y": 20])
    #expect(ans2["found"]?.bool == true)
    #expect(mang.requests.isEmpty)                                                                         // không có lời gọi model AI nào
    // Phương thức help không dùng được AI vì bộ tra cứu không có đường nào tới AI hay kho dữ liệu.
    let mirror = Mirror(reflecting: core.help)
    #expect(mirror.children.allSatisfy { !String(describing: type(of: $0.value)).contains("AIClient") && !String(describing: type(of: $0.value)).contains("DataStore") })
    let hoatDong = try await core.store.activities(limit: 50)
    #expect(!hoatDong.contains { $0.kind.contains("ai") || $0.kind.contains("chat") })
}
