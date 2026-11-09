import Foundation
import Testing
@testable import PVTACore

private func thuMucTam() throws -> DataPaths {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-test-\(UUID().uuidString)")
    return DataPaths(home: url)
}

@Test func vitriMacDinhVaGhiDeBangBienMoiTruong() {
    #expect(DataPaths.resolve(environment: ["PVTA_HOME": "/tmp/x"]).home.path == "/tmp/x")
    #expect(DataPaths.resolve(environment: [:]).home.path.hasSuffix("Library/Application Support/PVTA"))
}

@Test func chuaCoTepThiDungMacDinh() throws {
    let config = try ConfigStore(paths: thuMucTam()).load()
    #expect(config.permission == .askApproval)
    #expect(config.model == "auto")
}

@Test func ghiRoiDocLaiBangHaiStoreCungThuMuc() throws {
    let paths = try thuMucTam()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    try ConfigStore(paths: paths).update { $0.permission = .readOnly; $0.model = "claude" }
    // Một "tiến trình" khác (CLI/Desktop) đọc cùng thư mục.
    let doc = try ConfigStore(paths: paths).load()
    #expect(doc.permission == .readOnly)
    #expect(doc.model == "claude")
    let attrs = try FileManager.default.attributesOfItem(atPath: paths.config.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
}

@Test func tepHongBaoLoiTiengViet() throws {
    let paths = try thuMucTam()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    try paths.prepare()
    try Data("{hỏng".utf8).write(to: paths.config)
    #expect(throws: PVTAError.self) { try ConfigStore(paths: paths).load() }
}

@Test func nhapKhoaTuTepVaBoKhoangTrang() throws {
    let paths = try thuMucTam()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    try paths.prepare()
    let file = paths.home.appendingPathComponent("khoa.txt")
    try Data("  sk-abc\n".utf8).write(to: file)
    #expect(try SecretInput.read(file: file) == "sk-abc")
    try Data("\n".utf8).write(to: file)
    #expect(throws: PVTAError.self) { try SecretInput.read(file: file) }
}

@Test func khoaTrongKeychainVaKhongLoRaTepNao() throws {
    let paths = try thuMucTam()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    let store = KeychainKeyStore(service: "vn.pvta.test.\(UUID().uuidString)")
    let secret = "sk-BI-MAT-\(UUID().uuidString)"
    defer { try? store.delete(provider: "anthropic") }

    try store.save(secret, provider: "anthropic")
    #expect(try store.read(provider: "anthropic") == secret)
    try store.save(secret + "2", provider: "anthropic")
    #expect(try store.read(provider: "anthropic") == secret + "2")

    // Ghi cấu hình, rồi dò mọi tệp trong thư mục dữ liệu: không được có khóa.
    try ConfigStore(paths: paths).update { $0.model = "claude" }
    let files = FileManager.default.enumerator(at: paths.home, includingPropertiesForKeys: nil)!
    for case let url as URL in files {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!content.contains("sk-BI-MAT"))
    }

    try store.delete(provider: "anthropic")
    #expect(try store.read(provider: "anthropic") == nil)
}

@Test func tenNhaCungCapSaiBiTuChoi() {
    #expect(throws: PVTAError.self) { try KeychainKeyStore().save("x", provider: "Có Dấu") }
}
