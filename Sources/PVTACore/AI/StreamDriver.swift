import Foundation

struct SSEStep {
    var events: [AIEvent] = []
    var done = false
}

/// Đọc từng sự kiện `data:` của luồng SSE theo định dạng của một giao thức.
protocol SSEParser: Sendable {
    mutating func parse(_ data: String) throws -> SSEStep
    /// Luồng hết mà chưa có tín hiệu kết thúc: có coi là hoàn tất không.
    var completeAtEnd: Bool { get }
    /// Sự kiện cuối (mức dùng) khi lượt kết thúc.
    mutating func finish() -> [AIEvent]
}

/// Số lần thử lại và thời gian chờ giữa các lần khi lỗi mạng hoặc máy chủ báo lỗi tạm thời.
public struct RetryPolicy: Sendable {
    public var delays: [Duration]
    public init(delays: [Duration]) { self.delays = delays }
    public static let standard = RetryPolicy(delays: [.milliseconds(500), .seconds(2)])
    public static let none = RetryPolicy(delays: [])
}

struct StreamDriver: Sendable {
    let transport: HTTPTransport
    let retry: RetryPolicy
    let label: String

    private static let transient: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
    ]

    /// Mở kết nối; thử lại khi lỗi mạng tạm thời hoặc máy chủ 5xx. Chưa có chữ nào được gửi ra nên thử lại là an toàn.
    private func open(_ request: URLRequest) async throws -> HTTPResponseStream {
        var attempt = 0
        while true {
            do {
                let response = try await transport.stream(request)
                if (200..<300).contains(response.status) { return response }
                var body = ""
                for try await line in response.lines where body.count < 4000 { body += line + "\n" }
                throw ProviderError.http(status: response.status, body: body,
                                         retryAfter: response.headers["retry-after"].flatMap(Double.init), label: label)
            } catch let error as ProviderError where error.kind == .server && attempt < retry.delays.count {
                try await Task.sleep(for: retry.delays[attempt])
            } catch let error as URLError where Self.transient.contains(error.code) && attempt < retry.delays.count {
                try await Task.sleep(for: retry.delays[attempt])
            } catch let error as URLError where error.code != .cancelled {
                throw ProviderError(.network, UserMessage.text(for: error))
            }
            attempt += 1
        }
    }

    func run<P: SSEParser>(_ request: URLRequest, parser initial: P) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = initial
                    let response = try await open(request)
                    var completed = false
                    do {
                        for try await line in response.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else { continue }
                            var payload = String(line.dropFirst(5))
                            if payload.hasPrefix(" ") { payload.removeFirst() }
                            let step = try parser.parse(payload)
                            step.events.forEach { continuation.yield($0) }
                            if step.done { completed = true; break }
                        }
                    } catch let error as URLError where error.code != .cancelled {
                        throw ProviderError(.network, "Mất kết nối khi đang nhận câu trả lời. Hãy kiểm tra mạng rồi thử lại.")
                    }
                    guard completed || parser.completeAtEnd else {
                        throw ProviderError(.incomplete, "Luồng trả lời bị gián đoạn nên câu trả lời chưa hoàn tất. Hãy thử lại.")
                    }
                    parser.finish().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
