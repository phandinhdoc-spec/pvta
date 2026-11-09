import Foundation
@testable import PVTACore

/// Kho khóa trong bộ nhớ: test không đụng Keychain thật.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func save(_ secret: String, provider: String) throws { lock.lock(); items[provider] = secret; lock.unlock() }
    func read(provider: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return items[provider] }
    func delete(provider: String) throws { lock.lock(); items[provider] = nil; lock.unlock() }
}

/// Đường mạng giả: trả lần lượt các phản hồi đã dựng sẵn và ghi lại yêu cầu đã gửi.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var lines: [String] = []
        var body: String?
        var openError: Error?
        var midStreamError: Error?
        var hang = false
        /// Giữ luồng mở (sau khi gửi hết các dòng) cho tới khi cổng được mở.
        var gate: Gate?
        /// Các dòng gửi tiếp sau khi cổng mở.
        var afterGate: [String] = []

        /// Phản hồi Anthropic bị giữ giữa chừng cho tới khi `gate` mở rồi mới kết thúc.
        static func held(_ chunks: [String], gate: Gate) -> Reply {
            let all = claudeSSE(chunks)
            return Reply(lines: Array(all.dropLast(2)), gate: gate, afterGate: Array(all.suffix(2)))
        }

        /// Phản hồi Anthropic dừng giữa chừng và treo (chờ bị hủy).
        static func hung(_ chunks: [String]) -> Reply { Reply(lines: Array(claudeSSE(chunks).dropLast(2)), hang: true) }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [URLRequest] = []
    private var cancelled = 0

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    var cancelledStreams: Int { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func next(_ request: URLRequest) throws -> Reply {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        if let e = reply.openError { throw e }
        return reply
    }

    func stream(_ request: URLRequest) async throws -> HTTPResponseStream {
        let reply = try next(request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                for l in reply.lines { continuation.yield(l) }
                if let e = reply.midStreamError { continuation.finish(throwing: e); return }
                if reply.hang { try? await Task.sleep(for: .seconds(60)) }
                if let gate = reply.gate {
                    await gate.wait()
                    for l in reply.afterGate { continuation.yield(l) }
                }
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                lock.lock(); cancelled += 1; lock.unlock()
                task.cancel()
            }
        }
        return HTTPResponseStream(status: reply.status, headers: reply.headers, lines: lines)
    }

    func download(_ request: URLRequest, limit: Int) async throws -> (status: Int, headers: [String: String], body: Data) {
        let reply = try next(request)
        let body = Data((reply.body ?? reply.lines.joined(separator: "\n")).utf8)
        if body.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        return (reply.status, reply.headers, body)
    }

    func data(for request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        let reply = try next(request)
        return (reply.status, reply.headers, Data((reply.body ?? reply.lines.joined(separator: "\n")).utf8))
    }
}

func sse(_ events: [String]) -> [String] { events.map { "data: \($0)" } }

let anthropicOK = [
    "event: message_start",
    #"data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}"#,
    "event: content_block_delta",
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Xin "}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"chào"}}"#,
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":34}}"#,
    #"data: {"type":"message_stop"}"#,
]

let openaiOK = sse([
    #"{"choices":[{"delta":{"content":"Xin "}}]}"#,
    #"{"choices":[{"delta":{"content":"chào"}}]}"#,
    #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
    #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#,
    "[DONE]",
])

/// Cổng đồng bộ cho kiểm thử: `wait` chờ tới khi `open`.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Phản hồi SSE kiểu Anthropic cho các đoạn chữ cho trước.
func claudeSSE(_ chunks: [String]) -> [String] {
    var lines = [#"data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}"#]
    for c in chunks {
        let json = String(decoding: (try? JSONEncoder().encode(JSONValue.string(c))) ?? Data(), as: UTF8.self)
        lines.append(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":\#(json)}}"#)
    }
    lines.append(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#)
    lines.append(#"data: {"type":"message_stop"}"#)
    return lines
}
