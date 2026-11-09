import Foundation
import Testing
@testable import PVTACore

// MARK: - Tiện ích

/// Đường dẫn tới thư mục fixture mysoftdata.
private let fixtureRoot: URL = {
    // #filePath cho đường dẫn tuyệt đối (chuẩn của các test khác trong dự án)
    let thisFile = URL(fileURLWithPath: #filePath)
    return thisFile
        .deletingLastPathComponent()          // PVTACoreTests
        .deletingLastPathComponent()          // Tests
        .appendingPathComponent("Fixtures/mysoftdata", isDirectory: true)
}()
/// Tạo thư mục PVTA tạm cho mỗi test.
private func moKhoTam() throws -> (store: DataStore, home: URL, skillsDir: URL) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pvta-nhap-\(UUID().uuidString)", isDirectory: true)
    let skillsDir = home.appendingPathComponent("skills", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    let store = try DataStore(file: home.appendingPathComponent("pvta.sqlite"))
    return (store, home, skillsDir)
}

private func don(_ home: URL) { try? FileManager.default.removeItem(at: home) }

// MARK: - Test cases

/// Nhập lần đầu: đúng số hội thoại, tin nhắn, skill, quy tắc.
@Test func nhapLanDau() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    let result = try await importer.run(
        sourcePath: fixtureRoot.path,
        store: store,
        skillsDir: skillsDir
    )

    // 3 chat trong fixture, tất cả có file tin nhắn
    #expect(result.chatsImported == 3)
    #expect(result.chatsSkipped == 0)
    // Tin nhắn: 5 + 3 + 2 = 10
    #expect(result.messagesImported == 10)
    // Skill: learned-test-skill + user-custom-skill = 2 nhập, pvta-word bị bỏ
    #expect(result.skillsImported == 2)
    #expect(result.skillsSkipped >= 1)  // ít nhất pvta-word bị bỏ
    // Quy tắc: 2 globalRules
    #expect(result.rulesImported == 2)
    #expect(result.rulesSkipped == 0)
    #expect(!result.alreadyDone)

    // Kiểm tra dữ liệu thực sự đã vào kho
    let chats = try await store.chats()
    #expect(chats.count == 3)

    // Chat có title trống phải dùng "Hội thoại cũ"
    let empty = chats.first { $0.title == "Hội thoại cũ" }
    #expect(empty != nil)

    // Quy tắc profile
    let rules = try await store.rules(scope: "profile")
    #expect(rules.count == 2)
    #expect(rules.contains { $0.always == true })

    // Skill files tồn tại
    #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("learned-test-skill/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("user-custom-skill/SKILL.md").path))
    #expect(!FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("pvta-word").path))
}

/// Nhập lần 2: không tạo bản trùng, số đếm giữ nguyên.
@Test func nhapLanHai_KhongTao_Trung() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    let first  = try await importer.run(sourcePath: fixtureRoot.path, store: store, skillsDir: skillsDir)
    let second = try await importer.run(sourcePath: fixtureRoot.path, store: store, skillsDir: skillsDir)

    // Lần 2 không nhập thêm chat nào
    #expect(second.chatsImported == 0)
    #expect(second.chatsSkipped == first.chatsImported)
    // Lần 2 không nhập thêm skill nào (thư mục đích đã tồn tại)
    #expect(second.skillsImported == 0)
    // Lần 2 không nhập thêm quy tắc nào
    #expect(second.rulesImported == 0)
    #expect(second.rulesSkipped == first.rulesImported)

    // Tổng chat trong kho vẫn bằng lần đầu
    let chats = try await store.chats()
    #expect(chats.count == first.chatsImported)

    // Tổng quy tắc trong kho vẫn bằng lần đầu
    let rules = try await store.rules()
    #expect(rules.count == first.rulesImported)
}

/// Skill có tiền tố `pvta-` bị bỏ qua kèm lý do rõ ràng.
@Test func skillHeThong_BiBo_Qua() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    let result = try await importer.run(sourcePath: fixtureRoot.path, store: store, skillsDir: skillsDir)

    let pvtaWordBo = result.skippedReasons.contains { $0.contains("pvta-word") }
    #expect(pvtaWordBo, "Phải có lý do bỏ qua skill pvta-word")
}

/// Thư mục nguồn không tồn tại → báo lỗi tiếng Việt rõ.
@Test func thuMucKhongTonTai_BaoLoi() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    await #expect(throws: PVTAError.self) {
        _ = try await importer.run(sourcePath: "/thu-muc-khong-co-that-pvta-test", store: store, skillsDir: skillsDir)
    }
}

/// Chat thiếu file tin nhắn → ghi vào skippedReasons, không crash.
@Test func chatThieuFileTinNhan_BoBuaKhongCrash() async throws {
    let fm = FileManager.default
    // Tạo fixture tạm: chỉ có 1 chat trong index nhưng không có file chats/{id}.json
    let src = fm.temporaryDirectory.appendingPathComponent("pvta-mysoft-tmp-\(UUID().uuidString)", isDirectory: true)
    let chatsDir = src.appendingPathComponent("chats", isDirectory: true)
    let skillsDir = src.appendingPathComponent("skills", isDirectory: true)
    defer { try? fm.removeItem(at: src) }
    try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let index = """
    {"version":1,"chats":[{"id":"deadbeef00000000deadbeef00000000","title":"Chat thiếu file","updatedAt":1700000000000}],"globalRules":[]}
    """
    try Data(index.utf8).write(to: src.appendingPathComponent("chats.json"))
    // Không tạo chats/deadbeef....json

    let (store, home, pvtaSkillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    let result = try await importer.run(sourcePath: src.path, store: store, skillsDir: pvtaSkillsDir)

    #expect(result.chatsSkipped == 1)
    #expect(result.chatsImported == 0)
    let coLyDo = result.skippedReasons.contains { $0.contains("deadbeef") || $0.contains("Chat thiếu file") }
    #expect(coLyDo, "Phải ghi lý do bỏ qua chat thiếu file tin nhắn")
}

/// Chat có title rỗng → dùng "Hội thoại cũ".
@Test func chatTitleRong_DungFallback() async throws {
    let fm = FileManager.default
    let src = fm.temporaryDirectory.appendingPathComponent("pvta-mysoft-tmp-\(UUID().uuidString)", isDirectory: true)
    let chatsDir = src.appendingPathComponent("chats", isDirectory: true)
    let skillsDir = src.appendingPathComponent("skills", isDirectory: true)
    defer { try? fm.removeItem(at: src) }
    try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let chatId = "00000000aaaa1111000000000aaaa1111"
    let index = """
    {"version":1,"chats":[{"id":"\(chatId)","title":"   ","updatedAt":1700000000000}],"globalRules":[]}
    """
    try Data(index.utf8).write(to: src.appendingPathComponent("chats.json"))
    let msgs = """
    [{"id":"m1","role":"user","text":"Xin chào."}]
    """
    try Data(msgs.utf8).write(to: chatsDir.appendingPathComponent("\(chatId).json"))

    let (store, home, pvtaSkillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    let result = try await importer.run(sourcePath: src.path, store: store, skillsDir: pvtaSkillsDir)
    #expect(result.chatsImported == 1)

    let chats = try await store.chats()
    #expect(chats.first?.title == "Hội thoại cũ")
}

/// GlobalRules nhập đúng scope "profile".
@Test func quyTacNhapDung_ScopeProfile() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    _ = try await importer.run(sourcePath: fixtureRoot.path, store: store, skillsDir: skillsDir)

    let rules = try await store.rules(scope: "profile")
    #expect(!rules.isEmpty)
    #expect(rules.allSatisfy { $0.scope == "profile" })
}

/// legacy.import.at được ghi sau khi nhập.
@Test func ghiMocThoiGianSauNhap() async throws {
    let (store, home, skillsDir) = try moKhoTam()
    defer { don(home) }

    let importer = MySoftImporter()
    _ = try await importer.run(sourcePath: fixtureRoot.path, store: store, skillsDir: skillsDir)

    let at = try await store.setting("legacy.import.at")
    #expect(at != nil)
    // Phải là chuỗi ISO 8601 hợp lệ
    let parsed = ISO8601DateFormatter().date(from: at ?? "")
    #expect(parsed != nil)
}
