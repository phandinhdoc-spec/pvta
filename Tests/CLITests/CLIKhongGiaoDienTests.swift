import Foundation
import Testing
@testable import PVTACore

// MARK: - Danh mục phương thức (không cần kho dữ liệu)

@Suite("Danh mục phương thức")
struct DanhMucTests {

    @Test("Danh sách phương thức không rỗng")
    func danhSachKhongRong() {
        #expect(ToolCatalog.methodNames.count > 100)
    }

    @Test("Danh sách nhóm hợp lý")
    func nhomHopLy() {
        #expect(ToolCatalog.groupNames.count > 10)
        // Phải có các nhóm cơ bản
        for expected in ["chat", "project", "api", "core", "file", "tools", "secretary", "legacy"] {
            #expect(ToolCatalog.groupNames.contains(expected), "Thiếu nhóm \(expected)")
        }
    }

    @Test("Lọc theo nhóm trả về đúng phương thức")
    func locTheoNhom() {
        let chatMethods = ToolCatalog.methods(inGroup: "chat")
        #expect(chatMethods.count > 5)
        for m in chatMethods {
            #expect(m.hasPrefix("chat."), "\(m) không thuộc nhóm chat")
        }
    }

    @Test("Nhóm không tồn tại trả về rỗng")
    func nhomKhongTonTai() {
        let empty = ToolCatalog.methods(inGroup: "khong_ton_tai_xyz")
        #expect(empty.isEmpty)
    }

    @Test("Xuất JSON hợp lệ")
    func jsonHopLe() throws {
        let data = try ToolCatalog.json()
        struct Entry: Decodable { var method: String; var group: String }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        #expect(entries.count == ToolCatalog.methodNames.count)
        // Mỗi entry có group khớp tiền tố
        for e in entries {
            let prefix = e.method.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            #expect(e.group == prefix, "\(e.method) có group \(e.group) khác tiền tố \(prefix)")
        }
    }

    @Test("Xuất JSON theo nhóm")
    func jsonTheoNhom() throws {
        let data = try ToolCatalog.json(group: "core")
        struct Entry: Decodable { var method: String; var group: String }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        #expect(entries.count == ToolCatalog.methods(inGroup: "core").count)
        for e in entries {
            #expect(e.group == "core")
        }
    }

    @Test("Phương thức đã sắp xếp")
    func daSapXep() {
        let names = ToolCatalog.methodNames
        #expect(names == names.sorted(), "Danh sách phương thức chưa sắp xếp")
    }

    @Test("Tổng phương thức các nhóm bằng tổng cộng")
    func tongPhuongThuc() {
        let total = ToolCatalog.groups.reduce(0) { $0 + $1.methods.count }
        #expect(total == ToolCatalog.methodNames.count)
    }

    @Test("Danh mục khớp Builtin.methods().keys")
    func danhMucKhopBuiltin() {
        // So khớp tĩnh ToolCatalog với thực tế Builtin.
        let builtinKeys = Set(Builtin.methods().keys)
        let catalogKeys = Set(ToolCatalog.methodNames)
        let missing = builtinKeys.subtracting(catalogKeys)
        let extra = catalogKeys.subtracting(builtinKeys)
        #expect(missing.isEmpty, "Builtin có nhưng ToolCatalog thiếu: \(missing)")
        #expect(extra.isEmpty, "ToolCatalog có nhưng Builtin thiếu: \(extra)")
    }
}

// MARK: - CLI qua Process (chạy thật, không cần terminal tương tác)

@Suite("CLI Commands")
struct CLICommandTests {
    /// Đường dẫn tới pvta binary sau khi build.
    private var pvtaBinary: URL {
        // #filePath → .../Tests/CLITests/CLIKhongGiaoDienTests.swift
        // Cần lên gốc dự án rồi vào .build/debug/pvta
        var dir = URL(fileURLWithPath: #filePath)
        // Tìm thư mục chứa Package.swift
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent(".build/debug/pvta")
            }
        }
        // Fallback
        return URL(fileURLWithPath: "/Users/phananh/pvta/.build/debug/pvta")
    }

    /// Chạy pvta với tham số, trả về (stdout, stderr, exit code).
    private func run(_ arguments: String..., stdin: Data? = nil, timeout: TimeInterval = 10) throws -> (stdout: String, stderr: String, code: Int32) {
        let process = Process()
        process.executableURL = pvtaBinary
        process.arguments = Array(arguments)
        // Dùng thư mục tạm để không đụng dữ liệu thật.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PVTA_HOME": tmpDir.path],
            uniquingKeysWith: { _, new in new }
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin)
            stdinPipe.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }

        process.waitUntilExit()
        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (stdout, stderr, process.terminationStatus)
    }

    @Test("--version in ra phiên bản")
    func versionInPhienBan() throws {
        let result = try run("--version")
        #expect(result.code == 0)
        #expect(result.stdout.contains("pvta"))
        #expect(result.stdout.contains(PVTAInfo.version))
    }

    @Test("--help in ra hướng dẫn")
    func helpInHuongDan() throws {
        let result = try run("--help")
        #expect(result.code == 0)
        #expect(result.stdout.contains("tools"))
        #expect(result.stdout.contains("call"))
        #expect(result.stdout.contains("serve"))
        #expect(result.stdout.contains("doctor"))
    }

    @Test("không có lệnh cũng in trợ giúp")
    func khongCoLenhInTroGiup() throws {
        let result = try run()
        #expect(result.code == 0)
        #expect(result.stdout.contains("pvta"))
    }

    @Test("tools liệt kê nhóm")
    func toolsLietKeNhom() throws {
        let result = try run("tools")
        #expect(result.code == 0)
        #expect(result.stdout.contains("chat"))
        #expect(result.stdout.contains("project"))
        #expect(result.stdout.contains("tổng cộng"))
    }

    @Test("tools --json là JSON hợp lệ")
    func toolsJsonHopLe() throws {
        let result = try run("tools", "--json")
        #expect(result.code == 0)
        struct Entry: Decodable { var method: String; var group: String }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(result.stdout.utf8))
        #expect(entries.count > 100)
    }

    @Test("tools nhóm cụ thể")
    func toolsNhomCuThe() throws {
        let result = try run("tools", "core")
        #expect(result.code == 0)
        #expect(result.stdout.contains("core.ping"))
        #expect(result.stdout.contains("core.info"))
    }

    @Test("tools nhóm không tồn tại trả lỗi")
    func toolsNhomKhongTonTai() throws {
        let result = try run("tools", "khongtontai123")
        #expect(result.code == 1)
        #expect(result.stderr.contains("Không có nhóm"))
    }

    @Test("call phương thức không tồn tại trả mã 1")
    func callPhuongThucKhongTonTai() throws {
        let result = try run("call", "nonexistent.method")
        #expect(result.code == 1)
        #expect(result.stderr.contains("không tồn tại"))
    }

    @Test("call core.ping thành công")
    func callCorePing() throws {
        let result = try run("call", "core.ping")
        #expect(result.code == 0)
        #expect(result.stdout.contains("pong"))
    }

    @Test("call core.info trả phiên bản")
    func callCoreInfo() throws {
        let result = try run("call", "core.info")
        #expect(result.code == 0)
        #expect(result.stdout.contains(PVTAInfo.version))
        #expect(result.stdout.contains("pid"))
    }

    @Test("call với --file đọc tham số từ tệp")
    func callVoiFile() throws {
        // Tạo tệp tham số tạm
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-param-\(UUID().uuidString.prefix(6)).json")
        try Data("{}".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let result = try run("call", "core.ping", "--file", tmpFile.path)
        #expect(result.code == 0)
        #expect(result.stdout.contains("pong"))
    }

    @Test("call với --stdin đọc tham số từ stdin")
    func callVoiStdin() throws {
        let result = try run("call", "core.ping", "--stdin", stdin: Data("{}".utf8))
        #expect(result.code == 0)
        #expect(result.stdout.contains("pong"))
    }

    @Test("call chat.list trả mảng JSON")
    func callChatList() throws {
        let result = try run("call", "chat.list")
        #expect(result.code == 0)
        // Phải là JSON array (có thể rỗng vì dùng thư mục dữ liệu tạm)
        let decoded = try JSONDecoder().decode([JSONValue].self, from: Data(result.stdout.utf8))
        #expect(!decoded.isEmpty || decoded.isEmpty) // Mảng hợp lệ (có thể rỗng vì thư mục tạm)
    }

    @Test("call project.list trả mảng JSON")
    func callProjectList() throws {
        let result = try run("call", "project.list")
        #expect(result.code == 0)
        let decoded = try JSONDecoder().decode([JSONValue].self, from: Data(result.stdout.utf8))
        #expect(!decoded.isEmpty || decoded.isEmpty) // Mảng hợp lệ
    }

    @Test("call tools.status trả trạng thái")
    func callToolsStatus() throws {
        let result = try run("call", "tools.status")
        #expect(result.code == 0)
    }

    @Test("call api.status trả trạng thái khóa")
    func callApiStatus() throws {
        let result = try run("call", "api.status")
        #expect(result.code == 0)
    }

    @Test("call setting.get trả null khi chưa đặt")
    func callSettingGet() throws {
        let result = try run("call", "setting.get", "{\"key\": \"test_key\"}")
        #expect(result.code == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }

    @Test("call mode.list trả mảng")
    func callModeList() throws {
        let result = try run("call", "mode.list")
        #expect(result.code == 0)
    }

    @Test("call legacy.status trả trạng thái")
    func callLegacyStatus() throws {
        let result = try run("call", "legacy.status")
        #expect(result.code == 0)
    }
}
