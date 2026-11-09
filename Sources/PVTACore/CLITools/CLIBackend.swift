import Foundation

/// Công cụ dòng lệnh AI đã đăng nhập mà PVTA dùng được thay cho khóa API.
public enum CLIBackendID: String, CaseIterable, Codable, Sendable {
    case claude, codex, agy, opencode

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "OpenAI Codex"
        case .agy: "Google Antigravity (agy)"
        case .opencode: "OpenCode"
        }
    }

    var binary: String { rawValue }
    var envVar: String { "PVTA_\(rawValue.uppercased())_BIN" }

    /// PVTA chỉ tải bộ cài chính thức của ba công cụ này.
    public var installable: Bool { self != .opencode }

    public var docs: String {
        switch self {
        case .claude: "https://code.claude.com/docs/en/setup"
        case .codex: "https://github.com/openai/codex#quickstart"
        case .agy: "https://www.antigravity.google/docs/cli/install/"
        case .opencode: "https://opencode.ai"
        }
    }

    /// Điều kiện gói dùng (theo tài liệu nhà cung cấp, kiểm tra 10/2026).
    var requirement: String {
        switch self {
        case .claude: "Claude Code cần gói Pro, Max, Team hoặc Enterprise (gói Claude miễn phí không dùng được)."
        case .codex: "Codex dùng được với cả gói ChatGPT Free nhưng hạn mức thấp."
        case .agy: "Antigravity có hạn mức miễn phí theo tuần khá thấp và quyền dùng còn tùy tài khoản Google."
        case .opencode: "OpenCode có sẵn một số model miễn phí; model khác cần tài khoản của nhà cung cấp tương ứng."
        }
    }

    /// Biến môi trường thêm cho tiến trình: tắt việc phụ để khởi động nhanh và khỏi trộn ngữ cảnh lập trình.
    var childEnvironment: [String: String] {
        switch self {
        case .claude:
            ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
             "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1"]
        default: [:]
        }
    }
}

struct CLIInvocation {
    var args: [String]
    var stdin: String
}

/// Trạng thái phân tích luồng sự kiện của một lượt gọi.
struct CLIParseState {
    var text = ""
    var conversationId: String?
    var sawDelta = false
    var resultText: String?
    var error: String?
    var items: [String: String] = [:]
}

extension CLIBackendID {
    /// Mọi công cụ chạy ở chế độ chỉ đọc, không công cụ gốc: việc ghi tệp hay chạy lệnh phải đi qua cơ chế duyệt của PVTA.
    func invocation(model: String, system: String?, prompt: String, conversationId: String?, images: [String] = []) -> CLIInvocation {
        let useModel = !model.isEmpty && model != "default"
        switch self {
        case .claude:
            var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--safe-mode"]
            if let system { a += ["--system-prompt", system] }
            if useModel { a += ["--model", model] }
            if let conversationId { a += ["--resume", conversationId] }
            return CLIInvocation(args: a, stdin: prompt)
        case .codex:
            var a = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never"]
            if useModel { a += ["--model", model] }
            for image in images { a += ["--image", image] }
            if let conversationId { a += ["resume", conversationId] }
            a.append("-")
            return CLIInvocation(args: a, stdin: system.map { $0 + "\n\n" + prompt } ?? prompt)
        case .agy:
            // Chế độ kế hoạch + sandbox + cấm mọi công cụ: agy chỉ trả lời bằng chữ.
            var a = ["--input-format", "stream-json", "--output-format", "stream-json",
                     "--mode", "plan", "--sandbox", "--settings", Self.agyDenyAll,
                     "--disable-slash-commands", "--print-timeout", "15m"]
            if useModel { a += ["--model", model] }
            if let conversationId { a += ["--conversation", conversationId] }
            let text = system.map { $0 + "\n\n" + prompt } ?? prompt
            let line = (try? JSONEncoder().encode(JSONValue.object(["event": "user", "message": ["content": .string(text)]])))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return CLIInvocation(args: a, stdin: line + "\n")
        case .opencode:
            var a = ["run", "--format", "json", "--auto", "--agent", "plan"]
            if useModel { a += ["--model", model] }
            if let conversationId { a += ["--session", conversationId] }
            for image in images { a += ["--file", image] }
            return CLIInvocation(args: a, stdin: system.map { $0 + "\n\n" + prompt } ?? prompt)
        }
    }

    private static let agyDenyAll = """
    {"toolPermission":"strict","permissions":{"allow":[],"ask":[],"deny":["read_file(*)","write_file(*)","command(*)","unsandboxed(*)","read_url(*)","execute_url(*)","mcp(*)"]}}
    """

    /// Đọc một dòng JSON của công cụ; trả về đoạn chữ mới (nếu có).
    func parse(_ line: String, _ st: inout CLIParseState) -> String? {
        guard let ev = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
        switch self {
        case .claude: return Self.parseClaude(ev, &st)
        case .codex: return Self.parseCodex(ev, &st)
        case .agy: return Self.parseAgy(ev, &st)
        case .opencode: return Self.parseOpenCode(ev, &st)
        }
    }

    /// Phần chữ mới của một mục được gửi lại nhiều lần với toàn văn tăng dần.
    private static func growth(_ id: String, _ text: String, _ st: inout CLIParseState) -> String? {
        let prev = st.items[id] ?? ""
        st.items[id] = text
        guard text.hasPrefix(prev) else { return nil }
        let add = String(text.dropFirst(prev.count))
        guard !add.isEmpty else { return nil }
        let sep = prev.isEmpty && !st.text.isEmpty ? "\n\n" : ""
        st.text += sep + add
        return sep + add
    }

    private static func message(_ v: JSONValue?, fallback: String) -> String {
        if let s = v?.string, !s.isEmpty { return s }
        if let s = v?["message"]?.string ?? v?["data"]?["message"]?.string ?? v?["name"]?.string, !s.isEmpty { return s }
        return fallback
    }

    private static func parseClaude(_ ev: JSONValue, _ st: inout CLIParseState) -> String? {
        switch ev["type"]?.string {
        case "system":
            if ev["subtype"]?.string == "init", let id = ev["session_id"]?.string { st.conversationId = id }
        case "stream_event":
            let d = ev["event"]?["delta"]
            if ev["event"]?["type"]?.string == "content_block_delta", d?["type"]?.string == "text_delta", let t = d?["text"]?.string {
                st.sawDelta = true
                st.text += t
                return t
            }
        case "assistant":
            guard !st.sawDelta, case .array(let parts)? = ev["message"]?["content"] else { return nil }
            let out = parts.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
            if !out.isEmpty { st.text += out; return out }
        case "result":
            if let id = ev["session_id"]?.string { st.conversationId = id }
            if let r = ev["result"]?.string { st.resultText = r }
            let subtype = ev["subtype"]?.string ?? ""
            if ev["is_error"]?.bool == true || subtype.hasPrefix("error") {
                st.error = ev["result"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (subtype.isEmpty ? "error" : subtype)
            }
        default: break
        }
        return nil
    }

    private static func isReconnectNotice(_ ev: JSONValue) -> Bool {
        let t = ev["message"]?.string ?? ev["error"]?["message"]?.string ?? ""
        return t.range(of: #"^\s*Reconnecting\.{3}\s*\d+\s*/\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func parseCodex(_ ev: JSONValue, _ st: inout CLIParseState) -> String? {
        if let id = ev["thread_id"]?.string ?? ev["session_id"]?.string { st.conversationId = id }
        switch ev["type"]?.string {
        case "item.updated", "item.completed":
            let item = ev["item"]
            let kind = item?["type"]?.string ?? item?["item_type"]?.string
            guard kind == "agent_message" || kind == "assistant_message", let text = item?["text"]?.string else { return nil }
            return growth(item?["id"]?.string ?? "", text, &st)
        case "turn.failed":
            st.error = message(ev["error"], fallback: "codex không hoàn thành lượt này")
        case "turn.completed":
            st.error = nil   // lượt đã xong: lỗi tạm thời trước đó (đã tự nối lại) không còn ý nghĩa
        case "error":
            if !isReconnectNotice(ev) { st.error = message(ev, fallback: "codex báo lỗi") }
        default: break
        }
        return nil
    }

    private static func parseAgy(_ ev: JSONValue, _ st: inout CLIParseState) -> String? {
        // Dữ liệu lồng trong khóa cùng tên với sự kiện: {"event":"step_update","step_update":{…}}.
        let kind = ev["event"]?.string ?? ev["type"]?.string ?? ""
        let p = ev[kind] ?? ev
        if let id = p["conversation_id"]?.string ?? p["conversationId"]?.string ?? ev["conversation_id"]?.string { st.conversationId = id }
        switch kind {
        case "step_update":
            if let stepType = p["step_type"]?.string ?? p["step"]?["step_type"]?.string, stepType.lowercased() != "agent_response" { return nil }
            let delta = p["text_delta"]?.string ?? p["agent_response"]?["text_delta"]?.string ?? p["step"]?["agent_response"]?["text_delta"]?.string
            if let delta, !delta.isEmpty {
                st.sawDelta = true
                st.text += delta
                return delta
            }
        case "result":
            if let r = p["response"]?.string ?? p["text"]?.string ?? p["final_response"]?.string { st.resultText = r }
            let status = (p["status"]?.string ?? p["state"]?.string)?.uppercased()
            if let status, ["ERROR", "INVALID", "CANCELED", "CANCELLED", "INTERRUPTED", "FAILED"].contains(status) {
                st.error = message(p["error"] ?? ev["error"], fallback: st.resultText ?? status)
            } else if status == "WAITING", st.resultText == nil {
                st.error = "waiting_for_permission"
            }
        case "error":
            st.error = message(p["error"] ?? p["message"] ?? ev["error"], fallback: "agy báo lỗi")
        default: break
        }
        return nil
    }

    private static func parseOpenCode(_ ev: JSONValue, _ st: inout CLIParseState) -> String? {
        if let id = ev["sessionID"]?.string ?? ev["part"]?["sessionID"]?.string, !id.isEmpty { st.conversationId = id }
        switch ev["type"]?.string {
        case "text":
            guard let t = ev["part"]?["text"]?.string, !t.isEmpty else { return nil }
            return growth(ev["part"]?["id"]?.string ?? "", t, &st)
        case "error":
            st.error = message(ev["error"] ?? ev["part"]?["error"] ?? ev, fallback: "opencode báo lỗi")
        default: break
        }
        return nil
    }
}

extension CLIBackendID {
    /// Công cụ nhận ảnh qua cờ dòng lệnh. claude và agy trong PVTA chạy không có công cụ đọc tệp nên không nhận ảnh.
    var acceptsImages: Bool { self == .codex || self == .opencode }
}

/// Ghép tin nhắn thành một prompt: có phiên cũ thì chỉ cần câu hỏi mới nhất (công cụ giữ lịch sử).
func cliPrompt(_ messages: [ChatMessage], resume: Bool) -> String {
    if resume || messages.count <= 1 { return messages.last?.content ?? "" }
    return messages.map { ($0.role == .user ? "[Người dùng]\n" : "[Trợ lý]\n") + $0.content }.joined(separator: "\n\n")
}
