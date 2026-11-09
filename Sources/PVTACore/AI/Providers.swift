import Foundation

/// Một nhà cung cấp AI qua API. Đổi nhà cung cấp không đổi mã gọi ở phía trên.
public protocol AIProvider: Sendable {
    var info: ProviderInfo { get }
    func stream(model: String, _ request: ChatRequest) -> AsyncThrowingStream<AIEvent, Error>
    func listModels() async throws -> [ModelInfo]
}

private let modelPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,149}$")
private let notChat = try! NSRegularExpression(
    pattern: "(embed|rerank|whisper|tts|transcribe|moderation|speech|realtime|audio|dall-e|gpt-image|imagen|veo|aqa|davinci|babbage)",
    options: .caseInsensitive)
private let notChatStrict = try! NSRegularExpression(
    pattern: "(image|vision-preview|search-preview|computer-use|live|robotics)", options: .caseInsensitive)

private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Bỏ model không trò chuyện được (nhúng, giọng nói, ảnh…), bỏ tiền tố `models/`, bỏ trùng.
func cleanModels(provider: String, _ raw: [ModelInfo]) -> [ModelInfo] {
    var seen = Set<String>()
    var out: [ModelInfo] = []
    for e in raw {
        var id = e.id.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("models/") { id.removeFirst(7) }
        guard !id.isEmpty, matches(modelPattern, id), !seen.contains(id), !matches(notChat, id) else { continue }
        if (provider == "openai" || provider == "gemini") && matches(notChatStrict, id) { continue }
        seen.insert(id)
        out.append(ModelInfo(id: id, label: e.label == id ? nil : e.label))
    }
    if provider != "anthropic" { out.sort { $0.id.compare($1.id, options: .numeric) == .orderedDescending } }
    return Array(out.prefix(300))
}

private func listFailure(_ status: Int, base: String, label: String) -> ProviderError {
    switch status {
    case 401, 403: return ProviderError(.auth, "Khóa API của \(label) không đúng hoặc không có quyền xem danh sách model.")
    case 404: return ProviderError(.model, "Địa chỉ này không có danh sách model (\(base)/models). Bạn vẫn có thể gõ tên model bằng tay.")
    default: return ProviderError.http(status: status, body: "", retryAfter: nil, label: label)
    }
}

private func transportFailure(_ error: Error) -> Error {
    if let e = error as? URLError, e.code != .cancelled { return ProviderError(.network, UserMessage.text(for: e)) }
    return error
}

private func jsonBody(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

// MARK: Anthropic

public struct AnthropicProvider: AIProvider {
    public let info: ProviderInfo
    let base: URL
    let key: String
    let transport: HTTPTransport
    let retry: RetryPolicy

    private func request(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return r
    }

    public func stream(model: String, _ request: ChatRequest) -> AsyncThrowingStream<AIEvent, Error> {
        var body: [String: JSONValue] = [
            "model": .string(model), "max_tokens": .number(Double(request.maxTokens)), "stream": true,
            "messages": .array(request.messages.map { m in
                guard !m.images.isEmpty else { return ["role": .string(m.role.rawValue), "content": .string(m.content)] }
                let blocks = m.images.map { img -> JSONValue in
                    ["type": "image", "source": ["type": "base64", "media_type": .string(img.mime), "data": .string(img.data.base64EncodedString())]]
                } + [["type": "text", "text": .string(m.content)]]
                return ["role": .string(m.role.rawValue), "content": .array(blocks)]
            }),
        ]
        // Phần cố định ở system có đánh dấu cache: các lượt sau đọc lại từ cache, nhanh và rẻ hơn.
        if let system = request.system {
            body["system"] = [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]]
        }
        do {
            let req = self.request(base.absoluteString + "/messages", method: "POST", body: try jsonBody(.object(body)))
            return StreamDriver(transport: transport, retry: retry, label: info.label).run(req, parser: AnthropicParser())
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        var raw: [ModelInfo] = []
        var after = ""
        for _ in 0..<5 {
            let url = base.absoluteString + "/models?limit=1000" + (after.isEmpty ? "" : "&after_id=\(after)")
            let reply: (status: Int, headers: [String: String], body: Data)
            do { reply = try await transport.data(for: request(url)) } catch { throw transportFailure(error) }
            guard (200..<300).contains(reply.status) else { throw listFailure(reply.status, base: base.absoluteString, label: info.label) }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: reply.body), case .array(let items)? = json["data"] else {
                throw ProviderError(.invalidResponse, "Máy chủ trả về dữ liệu không đọc được (không phải JSON). Hãy kiểm tra lại địa chỉ.")
            }
            raw += items.compactMap { m in m["id"]?.string.map { ModelInfo(id: $0, label: m["display_name"]?.string) } }
            if json["has_more"]?.bool == true, let last = json["last_id"]?.string { after = last } else { break }
        }
        let out = cleanModels(provider: info.id, raw)
        guard !out.isEmpty else { throw ProviderError(.invalidResponse, "Máy chủ không trả về model nào dùng để trò chuyện được.") }
        return out
    }
}

struct AnthropicParser: SSEParser {
    private var input = 0
    private var output = 0
    private var sawUsage = false
    var completeAtEnd: Bool { false }

    mutating func parse(_ data: String) throws -> SSEStep {
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { return SSEStep() }
        switch event["type"]?.string {
        case "message_start":
            if let n = event["message"]?["usage"]?["input_tokens"]?.number { input = Int(n); sawUsage = true }
        case "content_block_delta":
            if event["delta"]?["type"]?.string == "text_delta", let t = event["delta"]?["text"]?.string {
                return SSEStep(events: [.text(t)])
            }
        case "message_delta":
            if let n = event["usage"]?["output_tokens"]?.number { output = Int(n); sawUsage = true }
            if ["max_tokens", "model_context_window_exceeded"].contains(event["delta"]?["stop_reason"]?.string ?? "") {
                throw ProviderError(.incomplete, "Câu trả lời chưa hoàn tất vì model đã chạm giới hạn token hoặc ngữ cảnh.")
            }
        case "message_stop":
            return SSEStep(done: true)
        case "error":
            let kind = event["error"]?["type"]?.string
            switch kind {
            case "rate_limit_error": throw ProviderError(.rateLimited, UserMessage.text(forHTTPStatus: 429))
            case "authentication_error", "permission_error": throw ProviderError.http(status: 401, body: "", retryAfter: nil, label: "Anthropic")
            case "overloaded_error", "api_error": throw ProviderError(.server, UserMessage.text(forHTTPStatus: 503))
            default: throw ProviderError(.other, "Nhà cung cấp báo lỗi: " + String(Redactor.clean(event["error"]?["message"]?.string ?? "").prefix(200)))
            }
        default: break
        }
        return SSEStep()
    }

    mutating func finish() -> [AIEvent] {
        sawUsage ? [.usage(TokenUsage(inputTokens: input, outputTokens: output))] : []
    }
}

// MARK: OpenAI và các máy chủ tương thích

public struct OpenAICompatibleProvider: AIProvider {
    public let info: ProviderInfo
    let base: URL
    let key: String?
    let transport: HTTPTransport
    let retry: RetryPolicy

    private func request(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return r
    }

    public func stream(model: String, _ request: ChatRequest) -> AsyncThrowingStream<AIEvent, Error> {
        var messages: [JSONValue] = []
        if let system = request.system { messages.append(["role": "system", "content": .string(system)]) }
        messages += request.messages.map { m in
            guard !m.images.isEmpty else { return ["role": .string(m.role.rawValue), "content": .string(m.content)] }
            let parts = [["type": "text", "text": .string(m.content)]] + m.images.map { img -> JSONValue in
                ["type": "image_url", "image_url": ["url": .string("data:\(img.mime);base64,\(img.data.base64EncodedString())")]]
            }
            return ["role": .string(m.role.rawValue), "content": .array(parts)]
        }
        var body: [String: JSONValue] = ["model": .string(model), "stream": true, "messages": .array(messages)]
        if info.usageInStream { body["stream_options"] = ["include_usage": true] }
        do {
            let req = self.request(base.absoluteString + "/chat/completions", method: "POST", body: try jsonBody(.object(body)))
            return StreamDriver(transport: transport, retry: retry, label: info.label).run(req, parser: OpenAIParser())
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        let reply: (status: Int, headers: [String: String], body: Data)
        do { reply = try await transport.data(for: request(base.absoluteString + "/models")) } catch { throw transportFailure(error) }
        guard (200..<300).contains(reply.status) else { throw listFailure(reply.status, base: base.absoluteString, label: info.label) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: reply.body) else {
            throw ProviderError(.invalidResponse, "Máy chủ trả về dữ liệu không đọc được (không phải JSON). Hãy kiểm tra lại địa chỉ.")
        }
        let list: [JSONValue]
        if case .array(let a)? = json["data"] { list = a } else if case .array(let a)? = json["models"] { list = a }
        else if case .array(let a) = json { list = a } else { list = [] }
        let raw = list.compactMap { m -> ModelInfo? in
            if let s = m.string { return ModelInfo(id: s) }
            return (m["id"]?.string ?? m["name"]?.string).map { ModelInfo(id: $0, label: m["display_name"]?.string) }
        }
        let out = cleanModels(provider: info.id, raw)
        guard !out.isEmpty else { throw ProviderError(.invalidResponse, "Máy chủ không trả về model nào dùng để trò chuyện được. Bạn vẫn có thể gõ tên model bằng tay.") }
        return out
    }
}

struct OpenAIParser: SSEParser {
    private var usage: TokenUsage?
    private var sawFinish = false
    var completeAtEnd: Bool { sawFinish }

    mutating func parse(_ data: String) throws -> SSEStep {
        if data == "[DONE]" { return SSEStep(done: true) }
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { return SSEStep() }
        if let err = event["error"] {
            throw ProviderError(.other, "Nhà cung cấp báo lỗi: " + String(Redactor.clean(err["message"]?.string ?? err.string ?? "").prefix(200)))
        }
        if let u = event["usage"], let p = u["prompt_tokens"]?.number, let c = u["completion_tokens"]?.number {
            usage = TokenUsage(inputTokens: Int(p), outputTokens: Int(c))
        }
        var events: [AIEvent] = []
        if case .array(let choices)? = event["choices"], let first = choices.first {
            if let reason = first["finish_reason"]?.string {
                if reason == "length" { throw ProviderError(.incomplete, "Câu trả lời chưa hoàn tất vì model đã chạm giới hạn token.") }
                if reason == "content_filter" { throw ProviderError(.incomplete, "Câu trả lời chưa hoàn tất vì bị bộ lọc của nhà cung cấp dừng lại.") }
                sawFinish = true
            }
            if let text = first["delta"]?["content"]?.string, !text.isEmpty { events.append(.text(text)) }
        }
        return SSEStep(events: events)
    }

    mutating func finish() -> [AIEvent] { usage.map { [.usage($0)] } ?? [] }
}
