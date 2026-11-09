import Foundation
import PVTACore

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Lệnh không cần kho dữ liệu

func printHelp() {
    print("""
    pvta \(PVTAInfo.version) — Phụ tá thông minh cho giáo viên

    Dùng:
      pvta [--cwd <thư-mục>]               Mở giao diện trò chuyện tương tác trên terminal
      pvta --version                       In phiên bản
      pvta --help                          Trang trợ giúp này
      pvta tools [nhóm] [--json]           Liệt kê phương thức theo nhóm
      pvta call <phương_thức> [JSON]       Gọi phương thức, kết quả JSON ra stdout
          --events                           Sự kiện ra stderr dạng NDJSON
          --file <đường-dẫn>                 Đọc tham số từ tệp
          --stdin                            Đọc tham số từ stdin
      pvta serve                           Giữ lõi chạy nền
      pvta watch                           Theo dõi sự kiện dạng NDJSON
      pvta doctor                          Kiểm tra sức khỏe hệ thống
      pvta config                          Xem cấu hình
      pvta key set <nhà-cung-cấp>          Lưu khóa API vào Keychain
          [--file <đường-dẫn>]
      pvta key delete <nhà-cung-cấp>       Xóa khóa API
    """)
}

func printTools() {
    var group: String?
    var jsonOutput = false
    var i = 1
    while i < args.count {
        if args[i] == "--json" { jsonOutput = true }
        else if group == nil { group = args[i] }
        i += 1
    }

    if jsonOutput {
        do {
            let data = try ToolCatalog.json(group: group)
            print(String(decoding: data, as: UTF8.self))
        } catch { fail("Không thể xuất JSON: \(error.localizedDescription)") }
        return
    }

    if let group {
        let methods = ToolCatalog.methods(inGroup: group)
        if methods.isEmpty { fail("Không có nhóm \"\(group)\". Các nhóm: \(ToolCatalog.groupNames.joined(separator: ", "))") }
        print("Nhóm \(group) (\(methods.count) phương thức):")
        for m in methods { print("  \(m)") }
    } else {
        print("Các nhóm phương thức (\(ToolCatalog.methodNames.count) tổng cộng):\n")
        for g in ToolCatalog.groups {
            print("  \(g.name) (\(g.methods.count))")
        }
        print("\nDùng: pvta tools <nhóm> để xem chi tiết, hoặc pvta tools --json để xuất JSON.")
    }
}

// MARK: - Lệnh cần kho dữ liệu

func callMethod() async throws {
    guard args.count >= 2 else { fail("Dùng: pvta call <phương_thức> [JSON] [--events] [--file đường-dẫn] [--stdin]") }
    let method = args[1]

    // Tìm tham số: --file, --stdin, hoặc JSON trực tiếp.
    var params: JSONValue = .null
    let hasFile = args.contains("--file")
    let hasStdin = args.contains("--stdin")
    let hasEvents = args.contains("--events")

    if hasFile {
        guard let idx = args.firstIndex(of: "--file"), idx + 1 < args.count else { fail("Thiếu đường dẫn sau --file.") }
        let path = (args[idx + 1] as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        params = try JSONDecoder().decode(JSONValue.self, from: data)
    } else if hasStdin {
        var input = Data()
        while let line = readLine(strippingNewline: false) { input.append(Data(line.utf8)) }
        if !input.isEmpty {
            params = try JSONDecoder().decode(JSONValue.self, from: input)
        }
    } else {
        // Tìm JSON arg: đầu tiên không phải flag và không phải method.
        for j in 2..<args.count {
            if args[j].hasPrefix("--") { continue }
            if hasFile, let fi = args.firstIndex(of: "--file"), j == fi + 1 { continue }
            params = try JSONDecoder().decode(JSONValue.self, from: Data(args[j].utf8))
            break
        }
    }

    let paths = DataPaths.resolve()
    let node = try await PVTANode.open(paths: paths)

    if hasEvents {
        // Theo dõi sự kiện trên luồng riêng, in ra stderr dạng NDJSON.
        let events = node.events
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        Task {
            for await event in events {
                var obj: [String: JSONValue] = ["event": .string(event.name), "data": event.data]
                if let rid = event.requestId { obj["requestId"] = .number(Double(rid)) }
                if let line = try? encoder.encode(obj) {
                    stderr(String(decoding: line, as: UTF8.self))
                }
            }
        }
    }

    let result: JSONValue
    do { result = try await node.call(method, params) } catch { await node.shutdown(); throw error }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
    await node.shutdown()
}

func serve() async throws {
    let paths = DataPaths.resolve()
    let node = try await PVTANode.open(paths: paths)
    print("Đang chạy với vai trò \(await node.role == .host ? "giữ dữ liệu" : "kết nối") (pid \(ProcessInfo.processInfo.processIdentifier)). Nhấn Ctrl-C để dừng.")
    let (stop, signal) = AsyncStream.makeStream(of: Void.self)
    let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        Foundation.signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { signal.yield() }
        source.resume()
        return source
    }
    for await _ in stop { break }
    sources.forEach { $0.cancel() }
    await node.shutdown()
}

func watch() async throws {
    let paths = DataPaths.resolve()
    let node = try await PVTANode.open(paths: paths)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    // Bắt Ctrl-C để tắt sạch.
    let (stop, signal) = AsyncStream.makeStream(of: Void.self)
    let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        Foundation.signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { signal.yield() }
        source.resume()
        return source
    }

    let events = node.events

    // In từng sự kiện dạng NDJSON ra stdout cho tới khi nhận Ctrl-C.
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in events {
                var obj: [String: JSONValue] = ["event": .string(event.name), "data": event.data]
                if let rid = event.requestId { obj["requestId"] = .number(Double(rid)) }
                if let line = try? encoder.encode(obj) {
                    print(String(decoding: line, as: UTF8.self))
                    fflush(stdout)
                }
            }
        }
        group.addTask {
            for await _ in stop { break }
        }
        // Khi một nhánh xong (Ctrl-C hoặc stream hết), tắt hết.
        await group.next()
        group.cancelAll()
    }
    signalSources.forEach { $0.cancel() }
    await node.shutdown()
}

func doctor() async throws {
    let paths = DataPaths.resolve()
    print("🔍 Kiểm tra hệ thống PVTA...\n")

    // 1. Thư mục dữ liệu
    let fm = FileManager.default
    let homeExists = fm.fileExists(atPath: paths.home.path)
    let homeWritable = fm.isWritableFile(atPath: paths.home.path)
    print("📁 Thư mục dữ liệu: \(paths.home.path)")
    print("   Tồn tại: \(homeExists ? "✅" : "❌")")
    print("   Ghi được: \(homeWritable ? "✅" : "❌")")

    // 2. Cơ sở dữ liệu
    let dbExists = fm.fileExists(atPath: paths.database.path)
    print("\n💾 Cơ sở dữ liệu: \(paths.database.path)")
    print("   Tồn tại: \(dbExists ? "✅" : "⚠️  Chưa tạo (sẽ tạo khi chạy lần đầu)")")

    // 3. Khóa API
    print("\n🔑 Khóa API:")
    let keyStore = KeychainKeyStore()
    for provider in ["anthropic", "openai", "google", "openrouter"] {
        let hasKey = (try? keyStore.read(provider: provider)) != nil
        print("   \(provider): \(hasKey ? "✅ Đã lưu" : "— Chưa có")")
    }

    // 4. Công cụ AI
    print("\n🛠  Công cụ AI:")
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("pvta-doctor")
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let env = CLIEnvironment(workDirectory: tmpDir)
    for backend in CLIBackendID.allCases {
        let path = env.find(backend)
        print("   \(backend.rawValue): \(path != nil ? "✅ \(path!)" : "— Chưa cài")")
    }

    // 5. Phương thức
    print("\n📋 Danh mục: \(ToolCatalog.methodNames.count) phương thức, \(ToolCatalog.groupNames.count) nhóm")

    // 6. Quyền mạng
    print("\n🌐 Kết nối:")
    let url = URL(string: "https://api.anthropic.com")!
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "HEAD"
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("   Anthropic API: \(code > 0 ? "✅ Truy cập được" : "⚠️  Không phản hồi")")
    } catch {
        print("   Anthropic API: ❌ Không thể kết nối (\(error.localizedDescription))")
    }

    print("\n✅ Kiểm tra xong.")
}

// MARK: - Điểm vào

func run() async throws {
    switch args.first {
    case "--version":
        print("pvta \(PVTAInfo.version)")
    case "--help", "-h":
        printHelp()
    case "tools":
        printTools()
    case "config":
        let paths = DataPaths.resolve()
        let config = try ConfigStore(paths: paths).load()
        print("Thư mục dữ liệu: \(paths.home.path)")
        print("Quyền: \(config.permission.rawValue)")
        print("Model: \(config.model)")
    case "key" where args.count >= 3 && args[1] == "set":
        var file: URL?
        if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
            file = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        try KeychainKeyStore().save(SecretInput.read(file: file), provider: args[2])
        print("Đã lưu khóa của \(args[2]) vào Keychain.")
    case "key" where args.count >= 3 && args[1] == "delete":
        try KeychainKeyStore().delete(provider: args[2])
        print("Đã xóa khóa của \(args[2]).")
    case "call":
        try await callMethod()
    case "serve":
        try await serve()
    case "watch":
        try await watch()
    case "doctor":
        try await doctor()
    case nil, "--cwd", "chat":
        var cwd = FileManager.default.currentDirectoryPath
        if let idx = args.firstIndex(of: "--cwd") {
            guard idx + 1 < args.count else { fail("Thiếu đường dẫn sau --cwd.") }
            cwd = args[idx + 1]
        }
        try await InteractiveTerminal.run(cwd: cwd)
    default:
        printHelp()
    }
}

do { try await run() } catch { fail((error as? PVTAError)?.message ?? "Đã xảy ra lỗi, vui lòng thử lại.") }
