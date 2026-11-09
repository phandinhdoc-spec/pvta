import Foundation

public struct CodeRequest: Sendable, Equatable {
    public var lang: String
    public var code: String
    /// Tệp/thư mục đính kèm (tên hoặc mã) được chép vào thư mục chạy.
    public var attachments: [String]
    public var outputDir: String?
    public var goal: String
    public var timeoutMinutes: Int

    static let maxCodeBytes = 200_000
    public static let defaultTimeoutMinutes = 30

    public init(lang: String, code: String, attachments: [String] = [], outputDir: String? = nil, goal: String = "", timeoutMinutes: Int = 30) {
        self.lang = lang
        self.code = code
        self.attachments = attachments
        self.outputDir = outputDir
        self.goal = goal
        self.timeoutMinutes = timeoutMinutes
    }

    init(_ a: JSONValue) throws {
        guard let lang = a["lang"]?.string, !lang.isEmpty else { throw PVTAError("Thiếu ngôn ngữ của mã (lang): python, javascript hoặc bash.") }
        guard let code = a["code"]?.string, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PVTAError("Thiếu mã cần chạy (code).") }
        var names: [String] = []
        if case .array(let items)? = a["attachments"] { names = items.compactMap(\.string) }
        self.init(lang: lang, code: code, attachments: names, outputDir: a["outputDir"]?.string, goal: a["goal"]?.string ?? "",
                  timeoutMinutes: max(1, min(240, Int(a["timeoutMinutes"]?.number ?? Double(Self.defaultTimeoutMinutes)))))
    }
}

public struct CodeResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var exitCode: Int?
    public var timedOut: Bool
    public var output: String
    public var runDir: String
    public var files: [String]
    public var seconds: Double
}

/// Chạy mã do AI viết: quét tĩnh + AI phản biện → thẻ duyệt → chạy trong thư mục riêng của lượt, bản gốc không bị sửa.
/// Thư mục con chỉ là nơi làm việc, KHÔNG phải môi trường cô lập: mã chạy với quyền tài khoản của người dùng.
public final class CodeService: Sendable {
    static let outputLimit = 20_000

    let permissions: PermissionService
    let files: FileService
    let attachments: AttachmentService
    let router: ModelRouter
    let ai: AIClient
    let store: DataStore
    let searchDirs: [String]?

    init(permissions: PermissionService, files: FileService, attachments: AttachmentService, router: ModelRouter, ai: AIClient,
         store: DataStore, searchDirs: [String]? = nil) {
        self.permissions = permissions
        self.files = files
        self.attachments = attachments
        self.router = router
        self.ai = ai
        self.store = store
        self.searchDirs = searchDirs
    }

    public func interpreters() -> [Interpreter] { Interpreter.supported.compactMap { Interpreter.find($0, searchDirs: searchDirs) } }

    // MARK: Phản biện

    /// Quét tĩnh, rồi (nếu `useAI`) nhờ AI phản biện. AI không chạy được thì thêm cảnh báo để người dùng tự đọc mã.
    public func review(lang: String, code: String, goal: String = "", useAI: Bool = true) async -> [CodeFinding] {
        var out = CodeScanner.scan(code)
        guard useAI else { return out }
        do {
            let choice = try await router.choose(kind: .coding)
            let request = ChatRequest(system: "Bạn là AI phản biện mã cho trợ lý PVTA.",
                                      messages: [ChatMessage(role: .user, content: CodeScanner.reviewPrompt(code: code, lang: Interpreter.normalize(lang), goal: goal))])
            var text = ""
            for try await e in ai.stream(model: choice.model, request) { if case .text(let t) = e { text += t } }
            try Task.checkCancellation()
            out += CodeScanner.parseReview(text)
        } catch is CancellationError {
            return out
        } catch {
            out.append(CodeFinding(level: "medium", text: "AI phản biện không chạy được (\(UserMessage.text(for: error))); hãy tự đọc kỹ mã trước khi duyệt.", source: "ai"))
        }
        return out
    }

    // MARK: Chạy

    private func outputDirectory(_ req: CodeRequest, chatId: String?) async throws -> String {
        let raw: String
        if let d = req.outputDir, !d.isEmpty { raw = d }
        else if let chatId, let d = try await files.outputDirectory(chatId: chatId) { raw = d }
        else { throw PVTAError("Chạy mã cần thư mục đầu ra. Hãy chọn thư mục đầu ra (output.select) hoặc cấp quyền ghi cho một thư mục.") }
        let dir = try await permissions.authorize(path: raw, write: true)
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PVTAError("Thư mục đầu ra “\(dir)” không tồn tại hoặc không phải thư mục.") }
        return dir
    }

    /// Chép tệp/thư mục đính kèm vào thư mục chạy (không theo liên kết tượng trưng, không ghi đè). Bản gốc không bị đụng tới.
    private func copyAttachments(_ names: [String], chatId: String?, into dest: URL) async throws -> [String] {
        guard !names.isEmpty else { return [] }
        guard let chatId else { throw PVTAError("Chỉ đính kèm được tệp của một hội thoại; hãy chạy mã trong hội thoại.") }
        var copied: [String] = [], used = Set<String>()
        for ref in names {
            let (url, _) = try await attachments.resolve(chatId: chatId, ref: ref)
            var name = url.lastPathComponent, k = 2
            while !used.insert(name).inserted { name = "\(url.lastPathComponent)-\(k)"; k += 1 }
            try Self.copyTree(url, to: dest.appendingPathComponent(name))
            copied.append(name)
        }
        return copied
    }

    static func copyTree(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(src.path, &st) == 0 else { throw PVTAError("Không tìm thấy “\(src.lastPathComponent)” để chép vào thư mục chạy.") }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for n in try fm.contentsOfDirectory(atPath: src.path) { try copyTree(src.appendingPathComponent(n), to: dst.appendingPathComponent(n)) }
        case S_IFREG:
            try fm.copyItem(at: src, to: dst)
        default:
            break   // liên kết tượng trưng và loại đặc biệt bị bỏ qua
        }
    }

    /// Môi trường tối thiểu cho mã: không mang theo khóa API hay biến bí mật của PVTA.
    static func environment(for interp: Interpreter) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out = ["PATH": ((interp.path as NSString).deletingLastPathComponent) + ":/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                   "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONUNBUFFERED": "1", "PYTHONUTF8": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        for k in ["HOME", "USER", "TMPDIR"] { if let v = env[k] { out[k] = v } }
        return out
    }

    /// Chạy mã đã được duyệt. Chỉ gọi sau khi `PermissionPolicy` cho phép (công cụ `run_code` và `runWithApproval` đảm bảo điều đó).
    public func runApproved(_ req: CodeRequest, chatId: String?, timeout: Duration? = nil) async throws -> CodeResult {
        guard req.code.utf8.count <= CodeRequest.maxCodeBytes else { throw PVTAError("Mã quá dài (tối đa 200 KB).") }
        guard let interp = Interpreter.find(req.lang, searchDirs: searchDirs) else { throw PVTAError(Interpreter.missingMessage(req.lang)) }
        let outDir = try await outputDirectory(req, chatId: chatId)
        let id = UUID().uuidString.prefix(8).lowercased()
        let run = URL(fileURLWithPath: outDir).appendingPathComponent("chay-ma-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)   // mỗi lượt một thư mục mới
        let copied = try await copyAttachments(req.attachments, chatId: chatId, into: run)
        let script = run.appendingPathComponent("ma-\(id).\(interp.ext)")
        try Data(req.code.utf8).write(to: script, options: .withoutOverwriting)

        let record = try? await store.startActivity(kind: "code.run", chatId: chatId)
        let box = TailBox()
        let started = Date()
        do {
            let exit = try await CLIProcess.run(binary: interp.path, args: [script.lastPathComponent], environment: Self.environment(for: interp),
                                                directory: run, stdin: .none, timeout: timeout ?? .seconds(req.timeoutMinutes * 60)) { _, chunk in box.add(chunk) }
            try Task.checkCancellation()
            let elapsed = Date().timeIntervalSince(started)
            var text = Redactor.clean(box.text)
            if text.count > Self.outputLimit { text = "[… đầu ra dài, chỉ giữ phần cuối …]\n" + String(text.suffix(Self.outputLimit)) }
            let made = Self.listNew(run, excluding: Set(copied + [script.lastPathComponent]))
            let result = CodeResult(ok: exit.code == 0 && !exit.timedOut, exitCode: exit.code.map(Int.init), timedOut: exit.timedOut,
                                    output: text, runDir: run.path, files: made, seconds: elapsed)
            if let record {
                try? await store.finishActivity(id: record, state: result.ok ? .done : .error,
                                                detail: exit.timedOut ? "Hết thời gian, đã dừng." : "Mã thoát \(exit.code.map(String.init) ?? "bị dừng")")
            }
            return result
        } catch {
            if let record { try? await store.finishActivity(id: record, state: .interrupted, detail: "Bị dừng.") }
            throw error
        }
    }

    private static func listNew(_ dir: URL, excluding: Set<String>) -> [String] {
        var out: [String] = []
        guard let it = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        while let rel = it.nextObject() as? String, out.count < 200 {
            if excluding.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
            if (it.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { out.append(rel) }
        }
        return out.sorted()
    }

    static func describe(_ r: CodeResult) -> String {
        var s = r.timedOut ? "Hết thời gian cho phép nên PVTA đã dừng mã."
            : r.ok ? "Mã chạy xong (thoát 0, \(String(format: "%.1f", r.seconds)) giây)." : "Mã báo lỗi (thoát \(r.exitCode.map(String.init) ?? "bị dừng")). Hãy đọc đầu ra để sửa mã."
        s += "\nThư mục chạy: \(r.runDir) (nơi làm việc, không phải môi trường cô lập)."
        if !r.files.isEmpty { s += "\nTệp tạo ra: " + r.files.prefix(30).joined(separator: ", ") + (r.files.count > 30 ? " …" : "") }
        return s + "\n--- Đầu ra:\n" + (r.output.isEmpty ? "(không có)" : r.output)
    }

    // MARK: Qua cơ chế duyệt

    /// Chạy mã có xin duyệt: dùng đúng cơ chế duyệt như công cụ của model (mức quyền, thẻ Duyệt mã, "Vẫn chạy" cho cảnh báo cao).
    public func runWithApproval(_ req: CodeRequest, chatId: String) async throws -> CodeResult {
        let spec = runTool
        var args: [String: JSONValue] = ["lang": .string(req.lang), "code": .string(req.code), "goal": .string(req.goal),
                                         "timeoutMinutes": .number(Double(req.timeoutMinutes)), "chatId": .string(chatId),
                                         "attachments": .array(req.attachments.map { .string($0) })]
        if let d = req.outputDir { args["outputDir"] = .string(d) }
        switch await PermissionPolicy(permissions).decide(spec, args: .object(args), chatId: chatId) {
        case .deny(let why): throw PVTAError(why)
        case .allow: return try await runApproved(req, chatId: chatId)
        }
    }

    // MARK: Công cụ cho model

    private var runTool: ToolSpec {
        ToolSpec(name: "run_code", summary: "Chạy mã Python, JavaScript hoặc bash trong thư mục riêng của lượt (tệp đính kèm được chép vào, bản gốc không đổi). Luôn cần người dùng duyệt; mã chạy với quyền tài khoản người dùng, không cô lập.",
                 parameters: #"{"lang": "python|javascript|bash", "code": "mã", "goal": "mục đích của mã", "attachments": ["tên tệp đính kèm cần chép vào"], "outputDir": "thư mục đầu ra (mặc định: thư mục kết quả của hội thoại)", "timeoutMinutes": "mặc định 30"}"#,
                 access: .run,
                 plan: { [self] a in
                     let req = try CodeRequest(a)
                     guard Interpreter.find(req.lang, searchDirs: searchDirs) != nil else { throw PVTAError(Interpreter.missingMessage(req.lang)) }
                     let out = try await outputDirectory(req, chatId: a["chatId"]?.string)
                     let findings = await review(lang: req.lang, code: req.code, goal: req.goal)
                     return ActionPlan(kind: .run, summary: "Chạy mã \(Interpreter.normalize(req.lang)) (\(req.code.split(separator: "\n").count) dòng) trong thư mục mới tạo ở \(out). Mã chạy với quyền tài khoản của bạn, không được cô lập.",
                                       preview: req.code, paths: [out], warnings: findings.map(\.warning))
                 },
                 run: { [self] a in
                     let r = try await runApproved(CodeRequest(a), chatId: a["chatId"]?.string)
                     return Self.describe(r)
                 })
    }

    private var reviewTool: ToolSpec {
        ToolSpec(name: "review_code", summary: "Quét tĩnh và nhờ AI phản biện một đoạn mã, không chạy mã. Dùng được ở mọi mức quyền.",
                 parameters: #"{"lang": "python|javascript|bash", "code": "mã", "goal": "mục đích của mã"}"#) { [self] a in
            let req = try CodeRequest(a)
            let f = await review(lang: req.lang, code: req.code, goal: req.goal)
            if f.isEmpty { return "Không phát hiện vấn đề (nhưng điều này không bảo đảm mã an toàn)." }
            let label = ["high": "Cao", "medium": "Trung bình", "low": "Thấp"]
            return f.map { "[\(label[$0.level] ?? $0.level)] \($0.source == "ai" ? "AI: " : "")\($0.text)" }.joined(separator: "\n")
        }
    }

    var toolSpecs: [ToolSpec] { [reviewTool, runTool] }
}

/// Giữ phần cuối của đầu ra (mã chạy lâu in nhiều thì phần cuối mới là phần cần xem).
final class TailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private static let keep = 200_000

    func add(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > Self.keep * 2 { data.removeFirst(data.count - Self.keep) }
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data.suffix(Self.keep), as: UTF8.self) }
}
