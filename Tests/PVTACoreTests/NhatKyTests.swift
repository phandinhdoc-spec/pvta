import Foundation
import Testing
@testable import PVTACore

private func thuMuc() -> DataPaths {
    DataPaths(home: FileManager.default.temporaryDirectory
        .appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
}

private func moKho(_ paths: DataPaths) throws -> DataStore {
    try paths.prepare()
    return try DataStore(file: paths.database)
}

private let khoaMau = [
    "sk-ant-api03-ABCDEFGH12345678",
    "AIzaSyA1234567890abcdefghijklmnop",
    "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "ya29.a0AfH6SMBabcdefghijklmnopqrstuv",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk",
]

@Test func cheKhoaVaTokenNhungGiuNguyenChuThuong() {
    for k in khoaMau {
        let ra = Redactor.clean("Lỗi gọi API với \(k) tại máy chủ")
        #expect(!ra.contains(k))
        #expect(ra.contains("[đã ẩn]"))
    }
    #expect(!Redactor.clean("Authorization: Bearer abc.def-123456789").contains("abc.def"))
    #expect(!Redactor.clean(#"{"api_key":"mat-khau-rieng-1"}"#).contains("mat-khau-rieng-1"))
    #expect(!Redactor.clean("https://x.test/v1?key=BIMAT123&a=1").contains("BIMAT123"))
    #expect(Redactor.clean("https://x.test/v1?key=BIMAT123&a=1").contains("&a=1"))
    #expect(Redactor.clean("Soạn bài Toán lớp 8, tiết 12") == "Soạn bài Toán lớp 8, tiết 12")
}

@Test func doiLoiKyThuatThanhThongBaoTiengViet() {
    #expect(UserMessage.text(for: URLError(.notConnectedToInternet)).contains("kết nối mạng"))
    #expect(UserMessage.text(for: URLError(.timedOut)).contains("quá lâu"))
    #expect(UserMessage.text(for: URLError(.secureConnectionFailed)).contains("HTTPS"))
    #expect(UserMessage.text(for: CocoaError(.fileNoSuchFile)).contains("Không tìm thấy"))
    #expect(UserMessage.text(for: CocoaError(.fileWriteOutOfSpace)).contains("đã đầy"))
    #expect(UserMessage.text(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).contains("đã đầy"))
    #expect(UserMessage.text(for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))).contains("định dạng"))
    #expect(UserMessage.text(for: CancellationError()) == "Tác vụ đã được dừng.")
    #expect(UserMessage.text(forHTTPStatus: 401).contains("Khóa API"))
    #expect(UserMessage.text(forHTTPStatus: 429).contains("hạn mức"))
    #expect(UserMessage.text(forHTTPStatus: 503).contains("sự cố"))
    // Lỗi lạ: không đưa nguyên chữ kỹ thuật (có thể chứa khóa) ra màn hình.
    let la = NSError(domain: "Lạ", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom sk-LO-BI-MAT-123456 0xDEADBEEF"])
    #expect(UserMessage.text(for: la) == UserMessage.generic)
    #expect(!UserMessage.text(for: PVTAError("Sai khóa sk-LO-BI-MAT-123456")).contains("LO-BI-MAT"))
}

@Test func tacVuXongLoiVaBiDungDeuCoDongNhatKy() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let core = Core(store: try moKho(paths), ai: AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore()))

    let ok: Int = try await core.track(kind: "chat.turn", chatId: "c1", model: "gia") { 42 }
    #expect(ok == 42)
    await #expect(throws: URLError.self) {
        try await core.track(kind: "chat.turn", chatId: "c2") { throw URLError(.notConnectedToInternet) }
    }
    await #expect(throws: CancellationError.self) {
        try await core.track(kind: "pdf.write", chatId: "c3") { throw CancellationError() }
    }

    let ds = try await core.store.activities()
    #expect(ds.count == 3)
    let theoHoiThoai = Dictionary(uniqueKeysWithValues: ds.map { ($0.chatId ?? "", $0) })
    #expect(theoHoiThoai["c1"]?.state == .done)
    #expect(theoHoiThoai["c1"]?.model == "gia")
    #expect(theoHoiThoai["c1"]?.endedAt != nil)
    #expect(theoHoiThoai["c2"]?.state == .error)
    #expect(theoHoiThoai["c2"]?.detail?.contains("kết nối mạng") == true)   // đã đổi sang tiếng Việt
    #expect(theoHoiThoai["c3"]?.state == .interrupted)
}

@Test func khoaKhongBaoGioXuatHienTrongNhatKyHayTepDuLieu() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let store = try moKho(paths)
    let core = Core(store: store, ai: AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore()))
    let bimat = "sk-LO-BI-MAT-\(UUID().uuidString)"

    await #expect(throws: PVTAError.self) {
        try await core.track(kind: "chat.turn") { throw PVTAError("Khóa \(bimat) bị từ chối") }
    }
    // Ghi trực tiếp chi tiết có khóa: kho vẫn che trước khi lưu.
    let id = try await store.startActivity(kind: "api.test")
    try await store.finishActivity(id: id, state: .error, detail: "Authorization: Bearer \(bimat) và token=\(bimat)")

    let ds = try await store.activities()
    #expect(ds.allSatisfy { !($0.detail ?? "").contains(bimat) })
    #expect(!ActivityReport.render(ds).contains(bimat))
    // Dò byte trong mọi tệp của thư mục dữ liệu (kể cả -wal).
    let files = (try? FileManager.default.contentsOfDirectory(at: paths.home, includingPropertiesForKeys: nil)) ?? []
    #expect(files.count >= 1)
    for url in files {
        let data = (try? Data(contentsOf: url)) ?? Data()
        #expect(data.range(of: Data("LO-BI-MAT".utf8)) == nil)
    }
}

@Test func tacVuDangChayCuBiDanhDauBiNgat() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    var id = ""
    do {
        let kho = try moKho(paths)
        id = try await kho.startActivity(kind: "chat.turn", chatId: "c1")   // ứng dụng đóng trước khi xong
    }
    let kho = try moKho(paths)
    try await kho.recoverActivities()
    let a = try await kho.activities().first { $0.id == id }
    #expect(a?.state == .interrupted)
    #expect(a?.detail?.contains("đã đóng") == true)
}

@Test func nhatKyConSauKhiHostChetVaXuatDuocBaoCao() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let cong = Cong()
    let host = try await PVTANode.open(paths: paths, extraMethods: lenhGia(cong))
    let client = try await PVTANode.open(paths: paths)
    let x = try await client.call("chat.create")["id"]!.string!

    _ = try await client.call("test.ok", ["chatId": .string(x)])
    await #expect(throws: PVTAError.self) { try await client.call("test.fail", ["chatId": .string(x)]) }
    // Một lượt đang chạy thì host chết đột ngột.
    let treo = Task { try await host.call("test.hang", ["chatId": .string(x)]) }
    try await Task.sleep(for: .milliseconds(200))
    await host.abandon()
    // Đợi nút còn lại nhận quyền giữ dữ liệu rồi mới hỏi (lời gọi đang bay đúng lúc host chết sẽ báo lỗi, đúng thiết kế).
    var nhanQuyen = false
    for _ in 0..<200 where !nhanQuyen {
        nhanQuyen = await client.role == .host
        if !nhanQuyen { try await Task.sleep(for: .milliseconds(25)) }
    }
    #expect(nhanQuyen)

    // Nút còn lại nhận quyền: dòng đang chạy thành "bị ngắt", các dòng cũ còn.
    let ds = try await client.call("activity.list").decode([Activity].self)
    #expect(ds.count == 3)
    #expect(Set(ds.map(\.state)) == [.done, .error, .interrupted])
    let loi = ds.first { $0.state == .error }
    #expect(loi?.detail?.contains("mạng") == true)

    let bc = try await client.call("activity.export")["text"]!.string!
    #expect(bc.contains("Báo cáo hoạt động PVTA"))
    #expect(bc.contains("PVTA \(PVTAInfo.version)"))
    #expect(bc.contains("Lỗi · chat.turn"))
    #expect(!bc.contains("LO-BI-MAT"))
    treo.cancel()   // tiến trình giả lập đã chết; dọn tác vụ treo của nó
    await client.shutdown()
}

private actor Cong { }

private func lenhGia(_ cong: Cong) -> [String: Core.Handler] {
    ["test.ok": { ctx in try await ctx.core.runTurn(chatId: try ctx.params.requireString("chatId")) { "xong" } },
     "test.fail": { ctx in
         try await ctx.core.runTurn(chatId: try ctx.params.requireString("chatId")) { throw URLError(.notConnectedToInternet) }
     },
     "test.hang": { ctx in
         try await ctx.core.runTurn(chatId: try ctx.params.requireString("chatId")) {
             try await Task.sleep(for: .seconds(60)); return .null
         }
     }]
}
