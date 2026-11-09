import Darwin
import Foundation

/// Nơi nhận luồng chữ và các dòng thông báo từ phiên CLI tương tác.
public protocol CLIOutputSink: Sendable {
    func writeLine(_ text: String)
    func writeDelta(_ text: String)
    func endDelta()
    func promptChanged(_ prompt: String)
}

/// Bộ thu đầu ra dùng cho kiểm thử tự động (thread-safe).
public final class CollectingOutputSink: CLIOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _deltas: [String] = []
    private var currentStream = ""

    public init() {}

    public func writeLine(_ text: String) {
        lock.lock()
        if !currentStream.isEmpty {
            _lines.append(currentStream)
            currentStream = ""
        }
        _lines.append(text)
        lock.unlock()
    }

    public func writeDelta(_ text: String) {
        lock.lock()
        _deltas.append(text)
        currentStream += text
        lock.unlock()
    }

    public func endDelta() {
        lock.lock()
        if !currentStream.isEmpty {
            _lines.append(currentStream)
            currentStream = ""
        }
        lock.unlock()
    }

    public func promptChanged(_ prompt: String) {}

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines + (currentStream.isEmpty ? [] : [currentStream])
    }

    public var deltas: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _deltas
    }

    public var joined: String {
        lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        _lines.removeAll()
        _deltas.removeAll()
        currentStream = ""
        lock.unlock()
    }
}

/// Mục gợi ý cho phím Tab hoặc menu (`/` lệnh & skill, `#` quy tắc, `@` lời nhắc, `$` tệp, `$$` thư mục).
public struct CLISuggestion: Sendable, Equatable {
    public var trigger: String
    public var token: String
    public var title: String
    public var detail: String
    public var path: String?
    public var sourceKind: String?

    public init(trigger: String, token: String, title: String, detail: String, path: String? = nil, sourceKind: String? = nil) {
        self.trigger = trigger
        self.token = token
        self.title = title
        self.detail = detail
        self.path = path
        self.sourceKind = sourceKind
    }
}

/// Phiên làm việc tương tác của CLI (`pvta`).
/// Điều phối hội thoại, dự án của thư mục làm việc hiện tại, duyệt thao tác, Plan, chỉnh sửa Markdown, và chạy script lập trình.
public actor InteractiveSession {
    public let node: PVTANode
    public let cwd: String
    public let output: any CLIOutputSink

    public private(set) var projectId: String?
    public private(set) var projectName: String
    public private(set) var chatId: String = ""
    public private(set) var chatTitle: String = "Hội thoại mới"
    public private(set) var permission: PermissionLevel = .askApproval
    public private(set) var writingMode: String = BuiltinModes.defaultID
    public private(set) var chatMode: String = "chat"
    public private(set) var model: String = "auto"
    public private(set) var urgencyOn: Bool = false
    public private(set) var selectedFolder: String?
    public private(set) var pendingActions: [ActionProposal] = []
    public private(set) var pendingHandoffs: [HandoffView] = []
    public private(set) var markdownDraft: MarkdownDraftState?
    public private(set) var busy: Bool = false

    private var eventTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var activeScriptPGID: pid_t?
    private var knownActionIds: Set<String> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var actionWaiters: [CheckedContinuation<[ActionProposal], Never>] = []
    private var deltaBufferHasText = false

    public static let writingAliases: [String: String] = [
        "standard": "su-pham",
        "su-pham": "su-pham",
        "exact": "chinh-xac",
        "chinh-xac": "chinh-xac",
        "academic": "hoc-thuat",
        "hoc-thuat": "hoc-thuat",
        "accounting": "ke-toan",
        "ke-toan": "ke-toan",
        "creative": "sang-tao",
        "sang-tao": "sang-tao",
        "admin": "hanh-chinh",
        "hanh-chinh": "hanh-chinh",
        "concise": "ngan-gon",
        "ngan-gon": "ngan-gon",
    ]

    public static let builtinCommands: [(cmd: String, summary: String)] = [
        ("/help", "Hiện hướng dẫn sử dụng các lệnh"),
        ("/models", "Liệt kê công cụ AI và nhà cung cấp API"),
        ("/model", "Xem hoặc chọn model: /model auto | <backend>/<model>"),
        ("/attach", "Đính kèm tệp trong thư mục làm việc: /attach <đường-dẫn>"),
        ("/skills", "Liệt kê các kỹ năng (/tên)"),
        ("/rules", "Liệt kê các quy tắc (#khóa)"),
        ("/writing", "Xem hoặc đổi chế độ viết: /writing <chế-độ>"),
        ("/chats", "Danh sách các hội thoại"),
        ("/chat", "Mở lại hội thoại theo mã: /chat <id>"),
        ("/new", "Tạo hội thoại mới trong dự án hiện tại"),
        ("/access", "Xem hoặc đổi quyền: /access <chi-doc|hoi-duyet|tu-sua>"),
        ("/actions", "Danh sách thao tác đang chờ duyệt"),
        ("/approve", "Duyệt thao tác: /approve [id] [force]"),
        ("/decline", "Từ chối thao tác: /decline [id]"),
        ("/output", "Xem hoặc chọn thư mục đầu ra / kết quả bước Plan"),
        ("/plans", "Danh sách các Plan và trạng thái từng bước"),
        ("/plan", "Lập Plan mới (không tự chạy): /plan <yêu cầu>"),
        ("/pro", "Lập Plan Pro có phản biện: /pro <yêu cầu>"),
        ("/run", "Chạy Plan hoặc quy trình: /run <id> [step-id]"),
        ("/step", "Duyệt và chạy một bước Plan: /step <plan-id> <step-id>"),
        ("/recovery", "Đối chiếu khôi phục bước bị gián đoạn: /recovery <plan-id> <step-id>"),
        ("/stop", "Dừng yêu cầu AI, Plan hoặc script đang chạy"),
        ("/activity", "Xem nhật ký hoạt động gần đây"),
        ("/tools", "Liệt kê phương thức lõi theo nhóm: /tools [nhóm]"),
        ("/do", "Gọi trực tiếp phương thức lõi: /do <phương_thức> [JSON]"),
        ("/sign", "Hỏi nhanh Thư ký song song: /sign <câu hỏi>"),
        ("/handoff", "Xem hoặc chọn chuyển model khi hết hạn mức: /handoff [id] [model|cancel]"),
        ("/gap", "Bật/tắt chế độ việc gấp: /gap [on|off]"),
        ("/open", "Mở tệp trong thư mục làm việc bằng ứng dụng mặc định: /open <tệp>"),
        ("/code", "Đọc tệp kèm số dòng hoặc chuyển chế độ mã: /code [tệp]"),
        ("/diff", "Xem khác biệt bản nháp Markdown hoặc git diff: /diff [--git] [tệp]"),
        ("/test", "Chạy script kiểm thử trong thư mục làm việc: /test [tên-script]"),
        ("/typecheck", "Chạy kiểm tra kiểu (typecheck) trong thư mục làm việc"),
        ("/lint", "Chạy kiểm tra mã (lint) trong thư mục làm việc"),
        ("/build", "Chạy dựng dự án (build) trong thư mục làm việc"),
        ("/edit", "Mở bản nháp Markdown: /edit <tệp.md>"),
        ("/replace", "Thay nội dung dòng trong bản nháp Markdown: /replace <dòng> <nội dung>"),
        ("/toc", "Xem mục lục tiêu đề của bản nháp Markdown"),
        ("/save", "Lưu nguyên tử bản nháp Markdown ra đĩa"),
        ("/discard", "Bỏ thay đổi chưa lưu của bản nháp Markdown"),
        ("/undo", "Hoàn tác lần /save gần nhất của bản nháp Markdown"),
        ("/editor", "Mở bản nháp Markdown bằng $VISUAL / $EDITOR / vi"),
        ("/quit", "Thoát chương trình"),
    ]

    public init(node: PVTANode, cwd: String, output: any CLIOutputSink) throws {
        self.node = node
        self.cwd = try WorkspaceGuard.canonicalCwd(cwd)
        self.projectName = URL(fileURLWithPath: self.cwd).lastPathComponent
        self.output = output
    }

    /// Khởi tạo phiên: đăng ký luồng sự kiện, gắn dự án của thư mục hiện tại và mở hội thoại mới.
    public func start() async throws {
        startEventLoop()

        // 1. Đọc trạng thái quyền, chế độ viết, cờ việc gấp
        if let perm = try? await node.call("permission.get"),
           let raw = perm["level"]?.string,
           let lv = PermissionLevel(rawValue: raw) {
            permission = lv
        }
        if let modes = try? await node.call("mode.list"),
           let sel = modes["selected"]?.string {
            writingMode = sel
        }
        if let urg = try? await node.call("urgency.get"),
           let on = urg["on"]?.bool {
            urgencyOn = on
        }

        // 2. Cấp quyền đọc/ghi cho thư mục hiện tại (nếu chưa có và hợp lệ)
        _ = try? await node.call("grant.add", ["path": .string(cwd), "write": .bool(true)])

        // 3. Tìm hoặc tạo dự án cho thư mục làm việc hiện tại
        var foundProjectId: String?
        if let listVal = try? await node.call("project.list"),
           let projects = try? listVal.decode([Project].self) {
            if let byName = projects.first(where: { $0.name == projectName }) {
                foundProjectId = byName.id
                projectName = byName.name
            }
        }
        if foundProjectId == nil {
            if let created = try? await node.call("project.create", ["name": .string(projectName)]),
               let proj = try? created.decode(Project.self) {
                foundProjectId = proj.id
                projectName = proj.name
            }
        }
        projectId = foundProjectId

        if let pid = projectId {
            _ = try? await node.call("project.connectFolder", ["id": .string(pid), "projectId": .string(pid), "path": .string(cwd)])
        }

        // 4. Mở hội thoại mới trong dự án của thư mục hiện tại
        var createParams: [String: JSONValue] = ["title": .string("Hội thoại mới")]
        if let pid = projectId {
            createParams["projectId"] = .string(pid)
        }
        let createdChat = try await node.call("chat.create", .object(createParams)).decode(Chat.self)
        chatId = createdChat.id
        chatTitle = createdChat.title
        model = createdChat.model ?? "auto"

        // 5. Gắn thư mục làm việc làm nguồn tìm kiếm ($ và $$) và thư mục đầu ra cho hội thoại
        _ = try? await node.call("attachment.add", ["chatId": .string(chatId), "paths": .array([.string(cwd)])])
        _ = try? await node.call("output.select", ["chatId": .string(chatId), "dir": .string(cwd)])

        // 6. Kiểm tra danh sách thao tác chờ duyệt hoặc handoff hiện có
        if let acts = try? await node.call("action.list").decode([ActionProposal].self) {
            pendingActions = acts
            knownActionIds = Set(acts.map(\.id))
        }
        if let hoffs = try? await node.call("handoff.list").decode([HandoffView].self) {
            pendingHandoffs = hoffs
        }

        output.writeLine("PVTA CLI \(PVTAInfo.version) — Dự án: \(projectName) (\(cwd))")
        output.writeLine("Hội thoại mới: \(chatTitle) [\(chatId)] | Quyền: \(permission.rawValue) | Model: \(model) | Chế độ viết: \(writingMode)")
        output.writeLine("Gõ câu hỏi để trò chuyện, /tên để gọi kỹ năng, #khóa cho quy tắc, $ / $$ để chọn nguồn, hoặc /help để xem lệnh.")
        output.promptChanged(promptLabel())
    }

    public func stopSession() async {
        await cancelCurrent(silent: true)
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - Vòng lặp sự kiện từ PVTANode

    private func startEventLoop() {
        eventTask?.cancel()
        let events = node.events
        eventTask = Task { [weak self] in
            for await ev in events {
                guard let self else { break }
                await self.handleEvent(ev)
            }
        }
    }

    private func handleEvent(_ ev: Event) {
        switch ev.name {
        case "chat.delta":
            guard ev.data["chatId"]?.string == chatId,
                  let text = ev.data["text"]?.string, !text.isEmpty else { return }
            deltaBufferHasText = true
            output.writeDelta(text)

        case "chat.tool":
            guard ev.data["chatId"]?.string == chatId,
                  let tool = ev.data["tool"]?.string,
                  let state = ev.data["state"]?.string else { return }
            flushDeltaIfNeeded()
            output.writeLine("[Công cụ: \(tool) — \(state)]")
            output.promptChanged(promptLabel())

        case "chat.notice":
            guard ev.data["chatId"]?.string == chatId,
                  let text = ev.data["text"]?.string else { return }
            flushDeltaIfNeeded()
            output.writeLine("[Lưu ý] \(text)")
            output.promptChanged(promptLabel())

        case "chat.model":
            if ev.data["chatId"]?.string == chatId, let m = ev.data["model"]?.string {
                model = m
                output.promptChanged(promptLabel())
            }

        case "actions":
            if let list = try? ev.data.decode([ActionProposal].self) {
                flushDeltaIfNeeded()
                let newOnes = list.filter { !knownActionIds.contains($0.id) }
                pendingActions = list
                knownActionIds = Set(list.map(\.id))
                for act in newOnes {
                    let isHighRisk = act.risk == "high"
                    let dangerNote = isHighRisk ? " [NGUY HIỂM - dùng: /approve \(act.id) force]" : ""
                    output.writeLine("[Cần duyệt #\(act.id)] \(act.tool): \(act.summary)\(dangerNote)")
                    if !act.preview.isEmpty {
                        let previewLines = act.preview.components(separatedBy: "\n").prefix(6).joined(separator: "\n")
                        output.writeLine("  Xem trước: \(previewLines)")
                    }
                    output.writeLine("  -> Gõ /approve \(act.id)\(isHighRisk ? " force" : "") để duyệt hoặc /decline \(act.id) để từ chối.")
                }
                if !list.isEmpty {
                    let waiters = actionWaiters
                    actionWaiters.removeAll()
                    for w in waiters { w.resume(returning: list) }
                }
                output.promptChanged(promptLabel())
            }

        case "handoff":
            if let list = try? ev.data.decode([HandoffView].self) {
                flushDeltaIfNeeded()
                pendingHandoffs = list
                for h in list {
                    let opts = h.choices.map { "\($0.model) (\($0.label))" }.joined(separator: ", ")
                    output.writeLine("[Chuyển model #\(h.id)] \(h.reason). Lựa chọn: \(opts). Dùng /handoff \(h.id) <model|cancel>.")
                }
                output.promptChanged(promptLabel())
            }

        case "urgency":
            if let on = ev.data["on"]?.bool {
                urgencyOn = on
                output.promptChanged(promptLabel())
            }

        default:
            break
        }
    }

    private func flushDeltaIfNeeded() {
        if deltaBufferHasText {
            output.endDelta()
            deltaBufferHasText = false
        }
    }

    // MARK: - Trạng thái bận & chờ hoàn tất

    private func setBusy(_ value: Bool) {
        busy = value
        if !value {
            output.promptChanged(promptLabel())
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    /// Chờ tới khi tác vụ nền hiện tại (`chat.send`, `/run`, `/test`...) hoàn tất.
    public func waitUntilIdle() async {
        if !busy && activeTask == nil { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if !busy && activeTask == nil {
                cont.resume()
            } else {
                idleWaiters.append(cont)
            }
        }
    }

    /// Chờ tới khi có ít nhất một yêu cầu duyệt thao tác (`ActionProposal`) xuất hiện.
    public func waitForPendingActions() async -> [ActionProposal] {
        if !pendingActions.isEmpty { return pendingActions }
        return await withCheckedContinuation { cont in
            if !pendingActions.isEmpty {
                cont.resume(returning: pendingActions)
            } else {
                actionWaiters.append(cont)
            }
        }
    }

    /// Dòng nhắc hiển thị ở đầu dòng nhập của terminal.
    public func promptLabel() -> String {
        var parts = ["pvta", chatMode]
        if permission != .askApproval { parts.append(permission.rawValue) }
        if writingMode != BuiltinModes.defaultID { parts.append(writingMode) }
        if urgencyOn { parts.append("gấp") }
        if let folder = selectedFolder {
            parts.append("$$" + (folder as NSString).lastPathComponent)
        }
        if let draft = markdownDraft {
            let name = (draft.path as NSString).lastPathComponent
            parts.append(name + (draft.isDirty ? "*" : ""))
        }
        if !pendingActions.isEmpty {
            parts.append("duyệt:\(pendingActions.count)")
        }
        if busy {
            parts.append("đang-chạy")
        }
        return "[\(parts.joined(separator: ":"))]> "
    }

    // MARK: - Hủy tác vụ an toàn (Ctrl-C / /stop)

    /// Hủy tác vụ đang chạy an toàn mà không làm hỏng tệp hay bản nháp.
    public func cancelCurrent(silent: Bool = false) async {
        if let pgid = activeScriptPGID {
            ScriptRunner.killProcessGroup(pgid)
            activeScriptPGID = nil
        }
        activeTask?.cancel()
        if !chatId.isEmpty {
            _ = try? await node.call("chat.cancel", ["chatId": .string(chatId)])
        }
        _ = try? await node.call("secretary.cancel", [:])
        if let plans = try? await node.call("plan.list", ["kind": "plan"]).decode([WorkRecord].self) {
            for p in plans where p.state == "running" {
                _ = try? await node.call("plan.cancel", ["id": .string(p.definition.id)])
            }
        }
        flushDeltaIfNeeded()
        if !silent {
            output.writeLine("Đã gửi yêu cầu dừng.")
        }
        output.promptChanged(promptLabel())
    }

    // MARK: - Gợi ý phím Tab và Chọn nguồn bằng `$` / `$$`

    /// Tìm gợi ý khi người dùng nhấn Tab trên token cuối (`/`, `#`, `@`, `$`, `$$`).
    public func suggestions(for input: String) async -> [CLISuggestion] {
        guard let tokenInfo = Self.extractTrailingTrigger(input) else { return [] }
        let q = Fold.text(tokenInfo.query)

        switch tokenInfo.trigger {
        case "$$":
            guard let hits = try? await node.call("source.search", [
                "chatId": .string(chatId),
                "kind": .string("dir"),
                "query": .string(tokenInfo.query),
                "limit": .number(15)
            ]).decode([SourceHit].self) else { return [] }
            return hits.map {
                let tok = Self.formatSourceToken($0.name)
                return CLISuggestion(trigger: "$$", token: "$$" + tok, title: $0.name, detail: "Thư mục nguồn (\($0.path))", path: $0.path, sourceKind: "dir")
            }

        case "$":
            var params: [String: JSONValue] = [
                "chatId": .string(chatId),
                "kind": .string("file"),
                "query": .string(tokenInfo.query),
                "limit": .number(15)
            ]
            if let folder = selectedFolder {
                params["folder"] = .string(folder)
            }
            guard let hits = try? await node.call("source.search", .object(params)).decode([SourceHit].self) else { return [] }
            return hits.map {
                let tok = Self.formatSourceToken($0.name)
                return CLISuggestion(trigger: "$", token: tok, title: $0.name, detail: $0.inContext ? "Đã đính kèm" : "Tệp trong thư mục nguồn", path: $0.path, sourceKind: "file")
            }

        case "#":
            guard let rules = try? await node.call("rule.list", [:]).decode([Rule].self) else { return [] }
            return rules.filter { q.isEmpty || Fold.text($0.key).contains(q) || Fold.text($0.title).contains(q) }
                .prefix(15)
                .map { CLISuggestion(trigger: "#", token: "#\($0.key)", title: "#\($0.key)", detail: $0.title) }

        case "@":
            guard let res = try? await node.call("prompt.list", ["query": .string(tokenInfo.query)]),
                  let prompts = try? res["prompts"]?.decode([LibraryPrompt].self) else { return [] }
            return prompts.prefix(15).map {
                CLISuggestion(trigger: "@", token: "@\($0.key)", title: "@\($0.key)", detail: $0.title)
            }

        case "/":
            // Chỉ gợi ý `/` khi ở đầu dòng
            guard tokenInfo.isAtLineStart else { return [] }
            var items: [CLISuggestion] = Self.builtinCommands.compactMap { entry in
                let name = String(entry.cmd.dropFirst())
                guard q.isEmpty || Fold.text(name).contains(q) || Fold.text(entry.summary).contains(q) else { return nil }
                return CLISuggestion(trigger: "/", token: entry.cmd, title: entry.cmd, detail: entry.summary)
            }
            if let skillsVal = try? await node.call("skill.list", ["chatId": .string(chatId)]),
               case .array(let arr)? = skillsVal["skills"] {
                for s in arr {
                    guard let id = s["id"]?.string, let name = s["name"]?.string else { continue }
                    if q.isEmpty || Fold.text(id).contains(q) || Fold.text(name).contains(q) {
                        items.append(CLISuggestion(trigger: "/", token: "/\(id)", title: "/\(id)", detail: "Kỹ năng: \(name)"))
                    }
                }
            }
            return Array(items.prefix(20))

        default:
            return []
        }
    }

    /// Áp dụng một mục gợi ý vào dòng đang nhập mà không tự gửi tin.
    /// Nếu là tệp từ `$`, tự động đính kèm tệp vào hội thoại hiện tại. Nếu là thư mục từ `$$`, đặt `selectedFolder`.
    public func applySuggestion(_ suggestion: CLISuggestion, to input: String) async -> String {
        guard let tokenInfo = Self.extractTrailingTrigger(input) else { return input }
        if suggestion.sourceKind == "dir", let path = suggestion.path {
            selectedFolder = path
            output.writeLine("Đã chọn thư mục nguồn ($$): \(path)")
        } else if suggestion.sourceKind == "file", let path = suggestion.path {
            _ = try? await node.call("attachment.add", ["chatId": .string(chatId), "paths": .array([.string(path)])])
            output.writeLine("Đã gắn nguồn ($): \(suggestion.title)")
        }
        let prefix = String(input[..<tokenInfo.range.lowerBound])
        return prefix + suggestion.token + " "
    }

    /// Giải các thẻ `$$thư-mục` và `$tệp` gõ trực tiếp trong câu hỏi trước khi gửi tới model.
    public func resolveInlineSources(in text: String) async -> String {
        var result = text

        // 1. Giải $$<từ-khóa> (chọn thư mục nguồn)
        let dirPattern = #"(?:^|\s)(\$\$[^\s]+)"#
        if let regex = try? NSRegularExpression(pattern: dirPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for m in matches.reversed() {
                guard let r = Range(m.range(at: 1), in: result) else { continue }
                let rawToken = String(result[r])
                let query = String(rawToken.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                guard !query.isEmpty else { continue }
                if let hits = try? await node.call("source.search", [
                    "chatId": .string(chatId),
                    "kind": .string("dir"),
                    "query": .string(query),
                    "limit": .number(5)
                ]).decode([SourceHit].self), let best = hits.first {
                    selectedFolder = best.path
                    output.writeLine("Đã chọn thư mục nguồn ($$): \(best.name) (\(best.path))")
                    result.replaceSubrange(r, with: Self.formatSourceToken(best.name))
                }
            }
        }

        // 2. Giải $<từ-khóa> (chọn và đính kèm tệp nguồn)
        let filePattern = #"(?:^|\s)(\$[^\$\s][^\s]*)"#
        if let regex = try? NSRegularExpression(pattern: filePattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for m in matches.reversed() {
                guard let r = Range(m.range(at: 1), in: result) else { continue }
                let rawToken = String(result[r])
                let query = String(rawToken.dropFirst(1)).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                guard !query.isEmpty else { continue }
                var params: [String: JSONValue] = [
                    "chatId": .string(chatId),
                    "kind": .string("file"),
                    "query": .string(query),
                    "limit": .number(5)
                ]
                if let folder = selectedFolder {
                    params["folder"] = .string(folder)
                }
                if let hits = try? await node.call("source.search", .object(params)).decode([SourceHit].self),
                   let best = hits.first {
                    if !best.inContext && !best.path.isEmpty {
                        _ = try? await node.call("attachment.add", ["chatId": .string(chatId), "paths": .array([.string(best.path)])])
                    }
                    output.writeLine("Đã đính kèm nguồn ($): \(best.name)")
                    result.replaceSubrange(r, with: Self.formatSourceToken(best.name))
                }
            }
        }

        return result
    }

    public static func formatSourceToken(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "`", with: "")
        return clean.contains(where: \.isWhitespace) ? "`\(clean)`" : clean
    }

    private struct TriggerMatch {
        var trigger: String
        var query: String
        var range: Range<String.Index>
        var isAtLineStart: Bool
    }

    private static func extractTrailingTrigger(_ input: String) -> TriggerMatch? {
        guard !input.isEmpty else { return nil }
        // Tìm khoảng trắng cuối cùng
        var tokenStart = input.startIndex
        for idx in input.indices.reversed() {
            if input[idx].isWhitespace {
                tokenStart = input.index(after: idx)
                break
            }
        }
        guard tokenStart < input.endIndex else { return nil }
        let token = String(input[tokenStart...])
        let isStart = input[..<tokenStart].allSatisfy(\.isWhitespace)
        if token.hasPrefix("$$") {
            return TriggerMatch(trigger: "$$", query: String(token.dropFirst(2)), range: tokenStart..<input.endIndex, isAtLineStart: isStart)
        }
        if token.hasPrefix("$") {
            return TriggerMatch(trigger: "$", query: String(token.dropFirst(1)), range: tokenStart..<input.endIndex, isAtLineStart: isStart)
        }
        if token.hasPrefix("#") {
            return TriggerMatch(trigger: "#", query: String(token.dropFirst(1)), range: tokenStart..<input.endIndex, isAtLineStart: isStart)
        }
        if token.hasPrefix("@") {
            return TriggerMatch(trigger: "@", query: String(token.dropFirst(1)), range: tokenStart..<input.endIndex, isAtLineStart: isStart)
        }
        if token.hasPrefix("/") && isStart {
            return TriggerMatch(trigger: "/", query: String(token.dropFirst(1)), range: tokenStart..<input.endIndex, isAtLineStart: true)
        }
        return nil
    }

    // MARK: - Xử lý dòng lệnh hoặc tin nhắn người dùng

    /// Nhận một dòng từ người dùng. Trả về `false` nếu người dùng gọi `/quit` để thoát.
    /// Khi `waitForCompletion == true`, hàm chờ cả tác vụ nền (`chat.send`, `/run`, `/test`...) chạy xong trước khi trả về.
    @discardableResult
    public func submit(_ raw: String, waitForCompletion: Bool = false) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.hasPrefix("/") {
            let cont = await handleSlashCommand(trimmed, waitForCompletion: waitForCompletion)
            return cont
        }

        if busy {
            output.writeLine("Đang có tác vụ chạy. Bạn có thể dùng /actions, /approve, /decline, /handoff, /sign hoặc /stop (Ctrl-C) để dừng.")
            return true
        }

        launchBackgroundTask(waitForCompletion: waitForCompletion) {
            await self.sendUserMessage(trimmed)
        }
        return true
    }

    private func launchBackgroundTask(waitForCompletion: Bool, _ operation: @escaping @Sendable () async -> Void) {
        setBusy(true)
        let task = Task { [weak self] in
            await operation()
            if let self {
                await self.finishBackgroundTask()
            }
        }
        activeTask = task
        if waitForCompletion {
            Task {
                await task.value
            }
        }
    }

    private func finishBackgroundTask() {
        flushDeltaIfNeeded()
        activeTask = nil
        activeScriptPGID = nil
        setBusy(false)
    }

    // MARK: - Gửi tin nhắn trò chuyện hoặc lập Plan

    private func sendUserMessage(_ rawText: String) async {
        do {
            let resolvedText = await resolveInlineSources(in: rawText)
            if chatMode == "plan" || chatMode == "pro" {
                try await runPlanSuggest(request: resolvedText, pro: chatMode == "pro")
                return
            }
            deltaBufferHasText = false
            let res = try await node.call("chat.send", [
                "chatId": .string(chatId),
                "text": .string(resolvedText)
            ]).decode(ChatTurnResult.self)

            flushDeltaIfNeeded()
            if let err = res.message.error, !err.isEmpty {
                output.writeLine("[Thông báo] \(err)")
            } else if !deltaBufferHasText && res.message.text.isEmpty {
                output.writeLine("(Đã hoàn thành lượt trả lời)")
            }
        } catch {
            flushDeltaIfNeeded()
            output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)")
        }
    }

    // MARK: - Bộ điều phối lệnh `/`

    private func handleSlashCommand(_ line: String, waitForCompletion: Bool) async -> Bool {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let cmd = String(parts.first ?? "").lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        do {
            switch cmd {
            case "/quit", "/exit":
                await stopSession()
                output.writeLine("Tạm biệt!")
                return false

            case "/help":
                printHelpCommand()

            case "/models":
                try await handleModels()

            case "/model":
                try await handleModel(arg)

            case "/attach":
                try await handleAttach(arg)

            case "/skills":
                try await handleSkills()

            case "/rules":
                try await handleRules()

            case "/writing":
                try await handleWriting(arg)

            case "/chats":
                try await handleChats()

            case "/chat":
                try await handleChatSwitch(arg)

            case "/new":
                try await handleNewChat(arg)

            case "/access":
                try await handleAccess(arg)

            case "/actions":
                try await handleActions()

            case "/approve":
                try await handleApprove(arg)

            case "/decline":
                try await handleDecline(arg)

            case "/output":
                try await handleOutput(arg)

            case "/plans":
                try await handlePlans()

            case "/plan":
                if arg.isEmpty {
                    chatMode = "plan"
                    output.writeLine("Đã chuyển sang chế độ Plan (chỉ khảo sát và tạo bản nháp, không tự chạy).")
                } else {
                    if busy {
                        output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi tạo Plan mới.")
                    } else {
                        launchBackgroundTask(waitForCompletion: waitForCompletion) {
                            do { try await self.runPlanSuggest(request: arg, pro: false) }
                            catch { self.output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)") }
                        }
                    }
                }

            case "/pro":
                if arg.isEmpty {
                    chatMode = "pro"
                    output.writeLine("Đã chuyển sang chế độ Plan Pro (khảo sát + phản biện độc lập).")
                } else {
                    if busy {
                        output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi tạo Plan Pro mới.")
                    } else {
                        launchBackgroundTask(waitForCompletion: waitForCompletion) {
                            do { try await self.runPlanSuggest(request: arg, pro: true) }
                            catch { self.output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)") }
                        }
                    }
                }

            case "/run":
                guard !arg.isEmpty else {
                    output.writeLine("Dùng: /run <mã-plan-hoặc-quy-trình> [mã-bước]")
                    return true
                }
                if busy {
                    output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi chạy Plan.")
                } else {
                    launchBackgroundTask(waitForCompletion: waitForCompletion) {
                        do { try await self.handleRun(arg) }
                        catch { self.output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)") }
                    }
                }

            case "/step":
                guard !arg.isEmpty else {
                    output.writeLine("Dùng: /step <mã-plan> <mã-bước>")
                    return true
                }
                if busy {
                    output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi chạy bước Plan.")
                } else {
                    launchBackgroundTask(waitForCompletion: waitForCompletion) {
                        do { try await self.handleStep(arg) }
                        catch { self.output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)") }
                    }
                }

            case "/recovery":
                try await handleRecovery(arg)

            case "/stop":
                await cancelCurrent(silent: false)

            case "/activity":
                try await handleActivity()

            case "/tools":
                handleTools(arg)

            case "/do":
                try await handleDo(arg)

            case "/sign":
                guard !arg.isEmpty else {
                    output.writeLine("Dùng: /sign <câu hỏi cho Thư ký>")
                    return true
                }
                if waitForCompletion {
                    await handleSign(arg)
                } else {
                    Task { await self.handleSign(arg) }
                }

            case "/handoff":
                try await handleHandoff(arg)

            case "/gap":
                try await handleGap(arg)

            case "/open":
                try await handleOpen(arg)

            case "/code":
                try handleCode(arg)

            case "/diff":
                try handleDiff(arg)

            case "/test", "/typecheck", "/lint", "/build":
                let defaultScript = String(cmd.dropFirst())
                let scriptName = (cmd == "/test" && !arg.isEmpty) ? arg : defaultScript
                guard permission != .readOnly else {
                    output.writeLine("Quyền hiện tại là chỉ đọc (chi-doc). Dùng /access hoi-duyet hoặc /access tu-sua trước khi chạy \(cmd).")
                    return true
                }
                if busy {
                    output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi chạy script mới.")
                } else {
                    launchBackgroundTask(waitForCompletion: waitForCompletion) {
                        await self.handlePackageScript(commandLabel: cmd, scriptName: scriptName)
                    }
                }

            case "/edit":
                try handleEdit(arg)

            case "/replace":
                try handleReplace(arg)

            case "/toc":
                try handleToc()

            case "/save":
                try handleSave()

            case "/discard":
                try handleDiscard()

            case "/undo":
                try handleUndo()

            case "/editor":
                try handleEditor()

            default:
                // Kiểm tra có phải gọi kỹ năng `/tên` không
                let skillId = String(cmd.dropFirst())
                if await isRegisteredSkill(skillId) {
                    if busy {
                        output.writeLine("Đang có tác vụ chạy. Dùng /stop trước khi gọi kỹ năng.")
                    } else {
                        launchBackgroundTask(waitForCompletion: waitForCompletion) {
                            await self.sendUserMessage(line)
                        }
                    }
                } else {
                    output.writeLine("Lệnh hoặc kỹ năng không tồn tại: \(cmd). Gõ /help để xem danh sách lệnh hoặc /skills để xem kỹ năng.")
                }
            }
        } catch {
            output.writeLine("Lỗi: \((error as? PVTAError)?.message ?? error.localizedDescription)")
        }

        if waitForCompletion, let task = activeTask {
            await task.value
        }
        return true
    }

    // MARK: - Chi tiết từng lệnh

    private func printHelpCommand() {
        var lines = ["Các lệnh trong PVTA CLI tương tác:"]
        for item in Self.builtinCommands {
            let padded = item.cmd.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("  \(padded) \(item.summary)")
        }
        lines.append("\nKý hiệu nhanh trong câu hỏi:")
        lines.append("  /tên-skill     Gọi kỹ năng chuyên môn (xem danh sách bằng /skills)")
        lines.append("  #khóa          Áp dụng quy tắc viết (xem danh sách bằng /rules)")
        lines.append("  $từ-khóa       Tìm và đính kèm tệp trong thư mục nguồn (nhấn Tab để gợi ý)")
        lines.append("  $$từ-khóa      Chọn thư mục nguồn con (nhấn Tab để gợi ý)")
        lines.append("  Ctrl-C         Dừng tác vụ đang chạy hoặc xóa dòng đang gõ an toàn")
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleModels() async throws {
        var lines = ["Model hiện tại của hội thoại: \(model)"]
        if let toolsVal = try? await node.call("tools.status"),
           let tools = try? toolsVal.decode([ToolStatus].self) {
            lines.append("\nCông cụ dòng lệnh AI:")
            for t in tools {
                lines.append("  - \(t.id.rawValue) (\(t.name)): \(t.state.rawValue) — \(t.detail)")
            }
        }
        if let apiVal = try? await node.call("api.status"),
           case .array(let providers) = apiVal {
            lines.append("\nNhà cung cấp API:")
            for p in providers {
                let id = p["id"]?.string ?? "?"
                let name = p["name"]?.string ?? id
                let hasKey = p["hasKey"]?.bool == true
                let defModel = p["model"]?.string ?? ""
                lines.append("  - \(id) (\(name)): \(hasKey ? "đã lưu khóa" : "chưa có khóa")\(defModel.isEmpty ? "" : " [mặc định: \(defModel)]")")
            }
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleModel(_ arg: String) async throws {
        if arg.isEmpty {
            output.writeLine("Model hiện tại: \(model). Dùng /model auto hoặc /model <nhà-cung-cấp>/<model>.")
            return
        }
        if arg.lowercased() == "auto" {
            _ = try await node.call("chat.setModel", ["chatId": .string(chatId), "model": .null])
            model = "auto"
            output.writeLine("Đã đặt model của hội thoại về: auto (Tự động).")
            return
        }
        let tokens = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized: String
        if tokens.count == 1 {
            let item = tokens[0]
            if item.contains("/") {
                normalized = item
            } else {
                normalized = "\(item)/default"
            }
        } else {
            var provider = tokens[0]
            if provider.hasPrefix("api:") {
                provider = String(provider.dropFirst(4))
            }
            let modelName = tokens.dropFirst().joined(separator: " ")
            normalized = "\(provider)/\(modelName)"
        }
        _ = try await node.call("chat.setModel", ["chatId": .string(chatId), "model": .string(normalized)])
        model = normalized
        output.writeLine("Đã đổi model của hội thoại sang: \(normalized)")
    }

    private func handleAttach(_ arg: String) async throws {
        if arg.isEmpty {
            let list = try await node.call("attachment.list", ["chatId": .string(chatId)]).decode([Attachment].self)
            if list.isEmpty {
                output.writeLine("Hội thoại chưa có tệp đính kèm.")
            } else {
                let rows = list.map { "  - [\($0.kind)] \($0.name) (\($0.path ?? ""))" }
                output.writeLine("Tệp/thư mục đã đính kèm (\(list.count)):\n" + rows.joined(separator: "\n"))
            }
            return
        }
        // Kiểm tra đường dẫn thật trong thư mục làm việc (chặn cả symlink trỏ ra ngoài cwd)
        let full = try WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: arg, mustExist: true)
        let res = try await node.call("attachment.add", [
            "chatId": .string(chatId),
            "paths": .array([.string(full)])
        ]).decode(AttachResult.self)
        if let err = res.errors.first {
            throw PVTAError(err)
        }
        let names = res.added.map(\.name).joined(separator: ", ")
        output.writeLine("Đã đính kèm: \(names.isEmpty ? (full as NSString).lastPathComponent : names)")
    }

    private func handleSkills() async throws {
        let res = try await node.call("skill.list", ["chatId": .string(chatId)])
        guard case .array(let arr)? = res["skills"], !arr.isEmpty else {
            output.writeLine("Chưa có kỹ năng (skill) nào.")
            return
        }
        var lines = ["Danh sách kỹ năng (\(arr.count)) — gõ /<mã> <yêu cầu> để dùng:"]
        for s in arr {
            let id = s["id"]?.string ?? "?"
            let name = s["name"]?.string ?? id
            let desc = s["description"]?.string ?? ""
            lines.append("  /\(id) — \(name)\(desc.isEmpty ? "" : ": \(desc)")")
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func isRegisteredSkill(_ id: String) async -> Bool {
        guard let res = try? await node.call("skill.list", ["chatId": .string(chatId)]),
              case .array(let arr)? = res["skills"] else { return false }
        let target = Fold.text(id)
        return arr.contains { item in
            guard let sid = item["id"]?.string else { return false }
            return Fold.text(sid) == target || sid.lowercased() == id.lowercased()
        }
    }

    private func handleRules() async throws {
        let rules = try await node.call("rule.list", [:]).decode([Rule].self)
        if rules.isEmpty {
            output.writeLine("Chưa có quy tắc (#khóa) nào.")
            return
        }
        var lines = ["Danh sách quy tắc (\(rules.count)) — gõ #<khóa> trong câu hỏi để áp dụng:"]
        for r in rules {
            lines.append("  #\(r.key) — \(r.title) [\(r.scope)\(r.always ? ", luôn bật" : "")]")
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleWriting(_ arg: String) async throws {
        if arg.isEmpty {
            let res = try await node.call("mode.list")
            let selected = res["selected"]?.string ?? writingMode
            writingMode = selected
            var lines = ["Chế độ viết hiện tại: \(selected)"]
            if case .array(let modes)? = res["modes"] {
                for m in modes {
                    let id = m["id"]?.string ?? "?"
                    let name = m["name"]?.string ?? id
                    let hint = m["hint"]?.string ?? ""
                    let mark = (id == selected) ? "*" : " "
                    lines.append(" \(mark) \(id) — \(name)\(hint.isEmpty ? "" : " (\(hint))")")
                }
            }
            output.writeLine(lines.joined(separator: "\n"))
            return
        }
        let key = arg.lowercased()
        let target = Self.writingAliases[key] ?? key
        let modeVal = try await node.call("mode.select", ["id": .string(target)])
        writingMode = modeVal["id"]?.string ?? target
        let modeName = modeVal["name"]?.string ?? writingMode
        output.writeLine("Đã chọn chế độ viết: \(writingMode) (\(modeName))")
        output.promptChanged(promptLabel())
    }

    private func handleChats() async throws {
        let chats = try await node.call("chat.list").decode([Chat].self)
        if chats.isEmpty {
            output.writeLine("Chưa có hội thoại nào.")
            return
        }
        var lines = ["Danh sách hội thoại (\(chats.count)):"]
        for c in chats.prefix(30) {
            let mark = (c.id == chatId) ? "*" : " "
            let projNote = (c.projectId == projectId && projectId != nil) ? " [dự án hiện tại]" : ""
            lines.append(" \(mark) \(c.id) | \(c.title)\(projNote)")
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleChatSwitch(_ arg: String) async throws {
        guard !arg.isEmpty else {
            output.writeLine("Hội thoại hiện tại: \(chatTitle) [\(chatId)]. Dùng /chat <id> để mở lại hội thoại cũ hoặc /chats để xem danh sách.")
            return
        }
        let allChats = try await node.call("chat.list").decode([Chat].self)
        let matched: Chat
        if let exact = allChats.first(where: { $0.id == arg }) {
            matched = exact
        } else {
            let prefixes = allChats.filter { $0.id.lowercased().hasPrefix(arg.lowercased()) }
            if prefixes.count == 1, let first = prefixes.first {
                matched = first
            } else if prefixes.count > 1 {
                throw PVTAError("Có \(prefixes.count) hội thoại khớp tiền tố '\(arg)'. Hãy nhập mã đầy đủ hơn.")
            } else {
                throw PVTAError("Không tìm thấy hội thoại có mã: \(arg)")
            }
        }
        let view = try await node.call("chat.view", ["chatId": .string(matched.id)])
        chatId = matched.id
        chatTitle = matched.title
        model = matched.model ?? "auto"
        var lines = ["Đã mở lại hội thoại: \(chatTitle) [\(chatId)]"]
        if let messages = try? view["messages"]?.decode([Message].self), !messages.isEmpty {
            lines.append("Lịch sử tin nhắn (\(messages.count) tin):")
            for m in messages.suffix(6) {
                let who = m.role == .user ? "Giáo viên" : "PVTA"
                let snippet = m.text.replacingOccurrences(of: "\n", with: " ").prefix(120)
                lines.append("  [\(who)] \(snippet)")
            }
        }
        output.writeLine(lines.joined(separator: "\n"))
        output.promptChanged(promptLabel())
    }

    private func handleNewChat(_ titleArg: String) async throws {
        let title = titleArg.isEmpty ? "Hội thoại mới" : titleArg
        var params: [String: JSONValue] = ["title": .string(title)]
        if let pid = projectId {
            params["projectId"] = .string(pid)
        }
        let created = try await node.call("chat.create", .object(params)).decode(Chat.self)
        chatId = created.id
        chatTitle = created.title
        model = created.model ?? "auto"
        _ = try? await node.call("attachment.add", ["chatId": .string(chatId), "paths": .array([.string(cwd)])])
        _ = try? await node.call("output.select", ["chatId": .string(chatId), "dir": .string(cwd)])
        output.writeLine("Đã tạo hội thoại mới: \(chatTitle) [\(chatId)]")
        output.promptChanged(promptLabel())
    }

    private func handleAccess(_ arg: String) async throws {
        if arg.isEmpty {
            let v = try await node.call("permission.get")
            let levelStr = v["level"]?.string ?? permission.rawValue
            if let lv = PermissionLevel(rawValue: levelStr) { permission = lv }
            output.writeLine("Mức quyền hiện tại: \(permission.rawValue). Dùng /access <chi-doc|hoi-duyet|tu-sua> (hoặc read|ask|full) để đổi.")
            return
        }
        let mapped: String
        switch arg.lowercased() {
        case "read", "chi-doc", "chidoc":
            mapped = PermissionLevel.readOnly.rawValue
        case "ask", "hoi-duyet", "hoiduyet":
            mapped = PermissionLevel.askApproval.rawValue
        case "full", "tu-sua", "tusua":
            mapped = PermissionLevel.autoEdit.rawValue
        default:
            throw PVTAError("Mức quyền không hợp lệ: \(arg). Dùng một trong: chi-doc, hoi-duyet, tu-sua (hoặc read, ask, full).")
        }
        let res = try await node.call("permission.set", [
            "level": .string(mapped),
            "acknowledge": .bool(mapped == PermissionLevel.autoEdit.rawValue)
        ])
        if let lv = PermissionLevel(rawValue: mapped) {
            permission = lv
        }
        var msg = "Đã đổi quyền truy cập sang: \(permission.rawValue)"
        if let warning = res["warning"]?.string, !warning.isEmpty {
            msg += "\nLưu ý: \(warning)"
        }
        output.writeLine(msg)
        output.promptChanged(promptLabel())
    }

    private func handleActions() async throws {
        let list = try await node.call("action.list").decode([ActionProposal].self)
        pendingActions = list
        knownActionIds = Set(list.map(\.id))
        if list.isEmpty {
            output.writeLine("Không có thao tác nào đang chờ duyệt.")
            return
        }
        var lines = ["Các thao tác đang chờ duyệt (\(list.count)):"]
        for a in list {
            let danger = a.risk == "high" ? " [NGUY HIỂM - cần force]" : ""
            lines.append("  #\(a.id) | \(a.tool) — \(a.summary)\(danger)")
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleApprove(_ arg: String) async throws {
        let list = try await node.call("action.list").decode([ActionProposal].self)
        pendingActions = list
        let parts = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        let force = parts.contains { $0.lowercased() == "force" || $0 == "--force" }
        let idTokens = parts.filter { $0.lowercased() != "force" && $0 != "--force" }

        let targetId: String
        if let explicit = idTokens.first {
            if let exact = list.first(where: { $0.id == explicit }) {
                targetId = exact.id
            } else if let prefix = list.first(where: { $0.id.lowercased().hasPrefix(explicit.lowercased()) }) {
                targetId = prefix.id
            } else {
                targetId = explicit
            }
        } else if list.count == 1, let only = list.first {
            targetId = only.id
        } else if list.isEmpty {
            output.writeLine("Không có thao tác nào đang chờ duyệt.")
            return
        } else {
            output.writeLine("Đang có \(list.count) thao tác chờ duyệt. Hãy chỉ rõ mã: /approve <id> [force].")
            return
        }

        _ = try await node.call("action.approve", [
            "id": .string(targetId),
            "force": .bool(force)
        ])
        pendingActions.removeAll { $0.id == targetId }
        output.writeLine("Đã duyệt thao tác #\(targetId).")
        output.promptChanged(promptLabel())
    }

    private func handleDecline(_ arg: String) async throws {
        let list = try await node.call("action.list").decode([ActionProposal].self)
        pendingActions = list
        let explicit = arg.trimmingCharacters(in: .whitespacesAndNewlines)

        let targetId: String
        if !explicit.isEmpty {
            if let exact = list.first(where: { $0.id == explicit }) {
                targetId = exact.id
            } else if let prefix = list.first(where: { $0.id.lowercased().hasPrefix(explicit.lowercased()) }) {
                targetId = prefix.id
            } else {
                targetId = explicit
            }
        } else if list.count == 1, let only = list.first {
            targetId = only.id
        } else if list.isEmpty {
            output.writeLine("Không có thao tác nào đang chờ duyệt.")
            return
        } else {
            output.writeLine("Đang có \(list.count) thao tác chờ duyệt. Hãy chỉ rõ mã: /decline <id>.")
            return
        }

        _ = try await node.call("action.decline", ["id": .string(targetId)])
        pendingActions.removeAll { $0.id == targetId }
        output.writeLine("Đã từ chối thao tác #\(targetId).")
        output.promptChanged(promptLabel())
    }

    private func handleOutput(_ arg: String) async throws {
        if arg.isEmpty {
            let loc = try await node.call("output.location", ["chatId": .string(chatId)])
            let dir = loc["dir"]?.string ?? "(chưa chọn)"
            var lines = ["Thư mục đầu ra hiện tại của hội thoại: \(dir)"]
            if case .array(let choices)? = loc["choices"], !choices.isEmpty {
                lines.append("Thư mục được cấp quyền ghi:")
                for (i, c) in choices.enumerated() {
                    lines.append("  [\(i + 1)] \(c.string ?? "")")
                }
            }
            output.writeLine(lines.joined(separator: "\n"))
            return
        }

        // Nếu arg là số thứ tự hoặc đường dẫn thư mục có thật -> chọn thư mục đầu ra
        let loc = try await node.call("output.location", ["chatId": .string(chatId)])
        if let idx = Int(arg), idx >= 1,
           case .array(let choices)? = loc["choices"], idx <= choices.count,
           let chosen = choices[idx - 1].string {
            let selected = try await node.call("output.select", ["chatId": .string(chatId), "dir": .string(chosen)])
            output.writeLine("Đã chọn thư mục đầu ra: \(selected.string ?? chosen)")
            return
        }
        if let dirPath = try? WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: arg, mustExist: true) {
            var st = stat()
            if stat(dirPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                let selected = try await node.call("output.select", ["chatId": .string(chatId), "dir": .string(dirPath)])
                output.writeLine("Đã chọn thư mục đầu ra: \(selected.string ?? dirPath)")
                return
            }
        }

        // Hoặc xem kết quả đầu ra của một Plan / bước Plan theo mã
        if let plans = try? await node.call("plan.list", ["kind": "plan"]).decode([WorkRecord].self) {
            for p in plans {
                if p.definition.id == arg || p.definition.id.hasPrefix(arg) {
                    output.writeLine(formatPlanRecord(p, includeFullOutput: true))
                    return
                }
                if let stepRec = p.steps[arg], !stepRec.output.isEmpty {
                    output.writeLine("Kết quả bước \(arg) (Plan \(p.definition.id)):\n\(stepRec.output)")
                    return
                }
            }
        }
        throw PVTAError("Không tìm thấy thư mục hoặc kết quả bước cho: \(arg)")
    }

    // MARK: - Plan & Quy trình (`/plans`, `/plan`, `/pro`, `/run`, `/step`, `/recovery`)

    private func runPlanSuggest(request: String, pro: Bool) async throws {
        output.writeLine("Đang khảo sát và lập \(pro ? "Plan Pro" : "Plan")...")
        let record = try await node.call("plan.suggest", [
            "chatId": .string(chatId),
            "request": .string(request),
            "pro": .bool(pro)
        ]).decode(WorkRecord.self)
        output.writeLine("Đã tạo \(pro ? "Plan Pro" : "Plan") (bản nháp — chưa tự động chạy):")
        output.writeLine(formatPlanRecord(record, includeFullOutput: false))
    }

    private func handlePlans() async throws {
        let plans = try await node.call("plan.list", ["kind": "plan"]).decode([WorkRecord].self)
        if plans.isEmpty {
            output.writeLine("Chưa có Plan nào. Dùng /plan <yêu cầu> để tạo Plan mới.")
            return
        }
        let blocks = plans.map { formatPlanRecord($0, includeFullOutput: false) }
        output.writeLine(blocks.joined(separator: "\n\n"))
    }

    private func resolveWorkRecord(_ idOrPrefix: String) async throws -> WorkRecord {
        let plans = (try? await node.call("plan.list", ["kind": "plan"]).decode([WorkRecord].self)) ?? []
        let workflows = (try? await node.call("workflow.list", ["kind": "workflow"]).decode([WorkRecord].self)) ?? []
        let all = plans + workflows
        if let exact = all.first(where: { $0.definition.id == idOrPrefix }) {
            return exact
        }
        let matches = all.filter { $0.definition.id.lowercased().hasPrefix(idOrPrefix.lowercased()) }
        if matches.count == 1, let first = matches.first {
            return first
        }
        if matches.count > 1 {
            throw PVTAError("Có \(matches.count) kế hoạch khớp tiền tố '\(idOrPrefix)'. Hãy nhập mã đầy đủ.")
        }
        throw PVTAError("Không tìm thấy Plan hoặc quy trình: \(idOrPrefix)")
    }

    private func handleRun(_ arg: String) async throws {
        let parts = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let planArg = parts.first else {
            throw PVTAError("Dùng: /run <mã-plan> [mã-bước]")
        }
        let record = try await resolveWorkRecord(planArg)
        let explicitStep = parts.count > 1 ? parts[1] : nil

        if record.definition.kind == "workflow" {
            let updated = try await node.call("workflow.run", [
                "id": .string(record.definition.id),
                "revision": .number(Double(record.definition.revision)),
                "approved": .bool(true)
            ]).decode(WorkRecord.self)
            output.writeLine("Đã chạy quy trình \(updated.definition.name) [\(updated.definition.id)]:")
            output.writeLine(formatPlanRecord(updated, includeFullOutput: true))
            return
        }

        // Với Plan: tìm bước được chỉ định hoặc bước đầu tiên chưa xong
        let targetStepId: String
        if let explicitStep {
            targetStepId = explicitStep
        } else if let nextStep = record.definition.steps.first(where: { step in
            let st = record.steps[step.id]?.state ?? "pending"
            return st != "done" && st != "skipped"
        }) {
            targetStepId = nextStep.id
        } else {
            output.writeLine("Tất cả các bước của Plan \(record.definition.id) đã hoàn tất.")
            return
        }

        output.writeLine("Đang duyệt và chạy bước '\(targetStepId)' của Plan \(record.definition.id)...")
        let updated = try await node.call("plan.run", [
            "id": .string(record.definition.id),
            "stepId": .string(targetStepId),
            "revision": .number(Double(record.definition.revision)),
            "approved": .bool(true)
        ]).decode(WorkRecord.self)
        output.writeLine(formatPlanRecord(updated, includeFullOutput: true))
    }

    private func handleStep(_ arg: String) async throws {
        let parts = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2 else {
            throw PVTAError("Dùng: /step <mã-plan> <mã-bước>")
        }
        let record = try await resolveWorkRecord(parts[0])
        let stepId = parts[1]
        output.writeLine("Đang duyệt và chạy bước '\(stepId)' của Plan \(record.definition.id)...")
        let updated = try await node.call("plan.run", [
            "id": .string(record.definition.id),
            "stepId": .string(stepId),
            "revision": .number(Double(record.definition.revision)),
            "approved": .bool(true)
        ]).decode(WorkRecord.self)
        output.writeLine(formatPlanRecord(updated, includeFullOutput: true))
    }

    private func handleRecovery(_ arg: String) async throws {
        let parts = arg.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            throw PVTAError("Dùng: /recovery <mã-plan> <mã-bước> [retry | complete <kết-quả>]")
        }
        let record = try await resolveWorkRecord(parts[0])
        let stepId = parts[1]
        let inspected = try await node.call("plan.inspectRecovery", [
            "id": .string(record.definition.id),
            "stepId": .string(stepId)
        ])
        if parts.count == 2 {
            let warning = inspected["warning"]?.string ?? ""
            let rev = Int(inspected["revision"]?.number ?? Double(record.definition.revision))
            let state = inspected["step"]?["state"]?.string ?? "unknown"
            var lines = [
                "Đối chiếu khôi phục Plan \(record.definition.id) — bước \(stepId) (phiên bản \(rev), trạng thái: \(state)):"
            ]
            if case .object(let current)? = inspected["current"], !current.isEmpty {
                for (k, v) in current.sorted(by: { $0.key < $1.key }) {
                    lines.append("  - \(k): \(v.string ?? "")")
                }
            }
            if !warning.isEmpty {
                lines.append("  Lưu ý: \(warning)")
            }
            lines.append("  Dùng: /recovery \(record.definition.id) \(stepId) retry (hoặc complete <kết-quả>) để xác nhận khôi phục.")
            output.writeLine(lines.joined(separator: "\n"))
            return
        }

        let decision = parts[2].lowercased()
        let outText = parts.count > 3 ? parts[3] : nil
        var resolveParams: [String: JSONValue] = [
            "id": .string(record.definition.id),
            "stepId": .string(stepId),
            "revision": inspected["revision"] ?? .number(Double(record.definition.revision)),
            "observed": inspected["current"] ?? .object([:]),
            "decision": .string(decision),
            "confirmed": .bool(true)
        ]
        if let outText {
            resolveParams["output"] = .string(outText)
        }
        let updated = try await node.call("plan.resolveRecovery", .object(resolveParams)).decode(WorkRecord.self)
        output.writeLine("Đã xử lý khôi phục bước \(stepId) (\(decision)):")
        output.writeLine(formatPlanRecord(updated, includeFullOutput: false))
    }

    private func formatPlanRecord(_ r: WorkRecord, includeFullOutput: Bool) -> String {
        var lines = [
            "Plan [\(r.definition.id)] \(r.definition.name) (loại: \(r.definition.kind), phiên bản: \(r.definition.revision), trạng thái: \(r.state))"
        ]
        if !r.definition.questions.isEmpty {
            lines.append("  Câu hỏi cần bổ sung: " + r.definition.questions.joined(separator: "; "))
        }
        for s in r.definition.steps {
            let sr = r.steps[s.id]
            let st = sr?.state ?? "pending"
            var line = "  - Bước [\(s.id)] \(s.name): \(st)"
            if let reason = sr?.reason, !reason.isEmpty {
                line += " (\(reason))"
            }
            lines.append(line)
            if let out = sr?.output, !out.isEmpty {
                let text = includeFullOutput ? out : String(out.prefix(160))
                lines.append("    Kết quả: \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Nhật ký, Công cụ, Gọi RPC trực tiếp, Thư ký, Handoff, Việc gấp, Mở tệp

    private func handleActivity() async throws {
        let items = try await node.call("activity.list", ["limit": .number(20)]).decode([Activity].self)
        if items.isEmpty {
            output.writeLine("Chưa có hoạt động nào được ghi nhận.")
            return
        }
        var lines = ["Nhật ký hoạt động gần đây (\(items.count)):"]
        for item in items.prefix(15) {
            let modelNote = item.model.map { " [\($0)]" } ?? ""
            let detailNote = item.detail.map { " — \($0)" } ?? ""
            lines.append("  - \(item.kind) (\(item.state.rawValue))\(modelNote)\(detailNote)")
        }
        output.writeLine(lines.joined(separator: "\n"))
    }

    private func handleTools(_ groupArg: String) {
        let grp = groupArg.trimmingCharacters(in: .whitespacesAndNewlines)
        if grp.isEmpty {
            var lines = ["Các nhóm phương thức lõi (\(ToolCatalog.methodNames.count) phương thức):"]
            for g in ToolCatalog.groups {
                lines.append("  - \(g.name) (\(g.methods.count))")
            }
            lines.append("Gõ /tools <nhóm> để xem chi tiết, hoặc /do <phương_thức> [JSON] để gọi.")
            output.writeLine(lines.joined(separator: "\n"))
        } else {
            let methods = ToolCatalog.methods(inGroup: grp)
            if methods.isEmpty {
                output.writeLine("Không có nhóm phương thức '\(grp)'. Các nhóm: \(ToolCatalog.groupNames.joined(separator: ", "))")
            } else {
                output.writeLine("Nhóm \(grp) (\(methods.count) phương thức):\n  " + methods.joined(separator: "\n  "))
            }
        }
    }

    private func handleDo(_ arg: String) async throws {
        let parts = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let methodSub = parts.first else {
            throw PVTAError("Dùng: /do <phương_thức> [JSON]")
        }
        let method = String(methodSub)
        var params: JSONValue = .object([:])
        if parts.count > 1 {
            let jsonRaw = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !jsonRaw.isEmpty {
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonRaw.utf8)) else {
                    throw PVTAError("Tham số JSON không hợp lệ cho lệnh /do.")
                }
                params = decoded
            }
        }
        let res = try await node.call(method, params)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = String(decoding: try enc.encode(res), as: UTF8.self)
        output.writeLine(text)
    }

    private func handleSign(_ question: String) async {
        do {
            let formatted = question.hasPrefix("/sign") ? question : "/sign \"\(question)\""
            let res = try await node.call("secretary.sign", ["text": .string(formatted)])
            let reply = res["message"]?["text"]?.string ?? res["text"]?.string ?? "(Thư ký đã trả lời)"
            output.writeLine("[Thư ký] \(reply)")
        } catch {
            output.writeLine("Lỗi Thư ký: \((error as? PVTAError)?.message ?? error.localizedDescription)")
        }
    }

    private func handleHandoff(_ arg: String) async throws {
        let list = try await node.call("handoff.list").decode([HandoffView].self)
        pendingHandoffs = list
        if arg.isEmpty {
            if list.isEmpty {
                output.writeLine("Không có yêu cầu chuyển model (handoff) nào đang chờ.")
                return
            }
            var lines = ["Yêu cầu chuyển model đang chờ (\(list.count)):"]
            for h in list {
                let opts = h.choices.map { "\($0.model) (\($0.label))" }.joined(separator: ", ")
                lines.append("  #\(h.id) — \(h.reason) | Lựa chọn: \(opts)")
            }
            output.writeLine(lines.joined(separator: "\n"))
            return
        }
        let parts = arg.split(whereSeparator: \.isWhitespace).map(String.init)
        let targetId: String
        let modelChoice: String?
        if parts.count == 1 {
            guard list.count == 1, let only = list.first else {
                throw PVTAError("Dùng: /handoff <id> <model|cancel>")
            }
            targetId = only.id
            modelChoice = parts[0].lowercased() == "cancel" ? nil : parts[0]
        } else {
            targetId = parts[0]
            modelChoice = parts[1].lowercased() == "cancel" ? nil : parts[1]
        }
        _ = try await node.call("handoff.choose", [
            "id": .string(targetId),
            "model": modelChoice.map(JSONValue.string) ?? .null
        ])
        pendingHandoffs.removeAll { $0.id == targetId }
        output.writeLine("Đã xử lý chuyển model #\(targetId) -> \(modelChoice ?? "hủy").")
        output.promptChanged(promptLabel())
    }

    private func handleGap(_ arg: String) async throws {
        if arg.isEmpty {
            let res = try await node.call("urgency.get")
            urgencyOn = res["on"]?.bool ?? false
            output.writeLine("Chế độ việc gấp: \(urgencyOn ? "ĐANG BẬT (on)" : "ĐANG TẮT (off)"). Dùng /gap on hoặc /gap off để đổi.")
            return
        }
        let on: Bool
        switch arg.lowercased() {
        case "on", "bat", "bật", "1", "true":
            on = true
        case "off", "tat", "tắt", "0", "false":
            on = false
        default:
            throw PVTAError("Dùng: /gap [on|off]")
        }
        let res = try await node.call("urgency.set", ["on": .bool(on)])
        urgencyOn = res["on"]?.bool ?? on
        output.writeLine("Đã \(urgencyOn ? "BẬT" : "TẮT") chế độ việc gấp.")
        output.promptChanged(promptLabel())
    }

    private func handleOpen(_ arg: String) async throws {
        guard !arg.isEmpty else {
            throw PVTAError("Dùng: /open <đường-dẫn-tệp-trong-thư-mục-làm-việc>")
        }
        // Kiểm tra đường dẫn thật trong thư mục làm việc (chặn cả symlink trỏ ra ngoài cwd)
        let full = try WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: arg, mustExist: true)
        let opened = try await node.call("file.open", [
            "ref": .string(full),
            "chatId": .string(chatId)
        ])
        output.writeLine("Đã mở tệp: \(opened.string ?? full)")
    }

    // MARK: - Lệnh lập trình (`/code`, `/diff`, `/test`, `/typecheck`, `/lint`, `/build`)

    private func handleCode(_ arg: String) throws {
        if arg.isEmpty {
            chatMode = "code"
            output.writeLine("Đã chuyển sang chế độ lập trình (code).")
            output.promptChanged(promptLabel())
            return
        }
        let (full, numbered) = try WorkspaceGuard.readCodeFile(cwd: cwd, inputPath: arg)
        output.writeLine("Tệp: \(full)\n\(numbered)")
    }

    private func handleDiff(_ arg: String) throws {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != "--git" && !trimmed.hasPrefix("--git ") && trimmed.isEmpty,
           let draft = markdownDraft {
            output.writeLine(MarkdownDraftManager.diff(draft))
            return
        }
        let target: String?
        if trimmed == "--git" {
            target = nil
        } else if trimmed.hasPrefix("--git ") {
            target = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            target = trimmed.isEmpty ? nil : trimmed
        }
        let diffOut = try ScriptRunner.gitDiff(cwd: cwd, target: target)
        output.writeLine(diffOut)
    }

    private func handlePackageScript(commandLabel: String, scriptName: String) async {
        output.writeLine("Đang chạy \(commandLabel) (script: \(scriptName)) trong \(cwd)...")
        do {
            let result = try await ScriptRunner.runPackageScript(cwd: cwd, script: scriptName) { [weak self] pgid in
                guard let self else { return }
                Task { await self.setActiveScriptPGID(pgid) }
            }
            let outTrim = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let errTrim = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !outTrim.isEmpty { output.writeLine(outTrim) }
            if !errTrim.isEmpty { output.writeLine(errTrim) }
            if result.cancelled {
                output.writeLine("[\(commandLabel) ĐÃ DỪNG]")
            } else if result.code == 0 {
                output.writeLine("[\(commandLabel) ĐẠT (mã thoát 0)]")
            } else {
                output.writeLine("[\(commandLabel) LỖI (mã thoát \(result.code))]")
            }
        } catch {
            output.writeLine("Lỗi \(commandLabel): \((error as? PVTAError)?.message ?? error.localizedDescription)")
        }
    }

    private func setActiveScriptPGID(_ pgid: pid_t?) {
        activeScriptPGID = pgid
    }

    // MARK: - Lệnh sửa Markdown (`/edit`, `/replace`, `/toc`, `/save`, `/discard`, `/undo`, `/editor`)

    private func handleEdit(_ arg: String) throws {
        guard !arg.isEmpty else {
            throw PVTAError("Dùng: /edit <tệp.md>")
        }
        let draft = try MarkdownDraftManager.open(cwd: cwd, inputPath: arg)
        markdownDraft = draft
        chatMode = "markdown"
        let lineCount = draft.text.components(separatedBy: "\n").count
        output.writeLine("Đã mở bản nháp Markdown: \(draft.path) (\(lineCount) dòng). Dùng /toc, /replace, /diff, /editor, /save, /discard, /undo.")
        output.promptChanged(promptLabel())
    }

    private func handleReplace(_ arg: String) throws {
        guard permission != .readOnly else {
            throw PVTAError("Quyền hiện tại là chỉ đọc (chi-doc). Dùng /access hoi-duyet hoặc /access tu-sua trước khi sửa bản nháp.")
        }
        guard var draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown. Dùng /edit <tệp.md> trước.")
        }
        let parts = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let lineStr = parts.first, let lineNum = Int(lineStr) else {
            throw PVTAError("Dùng: /replace <số-dòng> <nội-dung-mới>")
        }
        let newContent = parts.count > 1 ? String(parts[1]) : ""
        try MarkdownDraftManager.replaceLine(&draft, line: lineNum, content: newContent)
        markdownDraft = draft
        output.writeLine("Đã cập nhật dòng \(lineNum) trong bản nháp \((draft.path as NSString).lastPathComponent). Dùng /diff để xem hoặc /save để lưu.")
        output.promptChanged(promptLabel())
    }

    private func handleToc() throws {
        guard let draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown. Dùng /edit <tệp.md> trước.")
        }
        output.writeLine(MarkdownDraftManager.toc(draft.text))
    }

    private func handleSave() throws {
        guard permission != .readOnly else {
            throw PVTAError("Quyền hiện tại là chỉ đọc (chi-doc). Dùng /access hoi-duyet hoặc /access tu-sua trước khi lưu.")
        }
        guard var draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown để lưu.")
        }
        try MarkdownDraftManager.save(&draft, cwd: cwd)
        markdownDraft = draft
        output.writeLine("Đã lưu nguyên tử bản nháp vào: \(draft.path)")
        output.promptChanged(promptLabel())
    }

    private func handleDiscard() throws {
        guard var draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown.")
        }
        draft.text = draft.original
        markdownDraft = draft
        output.writeLine("Đã hủy các thay đổi chưa lưu của bản nháp \((draft.path as NSString).lastPathComponent).")
        output.promptChanged(promptLabel())
    }

    private func handleUndo() throws {
        guard permission != .readOnly else {
            throw PVTAError("Quyền hiện tại là chỉ đọc (chi-doc). Dùng /access hoi-duyet hoặc /access tu-sua trước khi hoàn tác.")
        }
        guard var draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown.")
        }
        try MarkdownDraftManager.undo(&draft, cwd: cwd)
        markdownDraft = draft
        output.writeLine("Đã hoàn tác lần lưu gần nhất của: \(draft.path)")
        output.promptChanged(promptLabel())
    }

    private func handleEditor() throws {
        guard permission != .readOnly else {
            throw PVTAError("Quyền hiện tại là chỉ đọc (chi-doc). Dùng /access hoi-duyet hoặc /access tu-sua trước khi mở trình soạn thảo.")
        }
        guard var draft = markdownDraft else {
            throw PVTAError("Chưa mở bản nháp Markdown. Dùng /edit <tệp.md> trước.")
        }
        let ok = try MarkdownDraftManager.runExternalEditor(&draft)
        if ok {
            markdownDraft = draft
            output.writeLine("Đã cập nhật bản nháp từ trình soạn thảo ngoài. Dùng /diff để xem hoặc /save để lưu.")
            output.promptChanged(promptLabel())
        } else {
            output.writeLine("Trình soạn thảo trả mã thoát khác 0; giữ nguyên bản nháp cũ.")
        }
    }
}
