import Foundation

public struct HTTPResponseStream: Sendable {
    public var status: Int
    /// Tên header viết thường.
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>
    public init(status: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

/// Đường ra mạng của các nhà cung cấp AI. Bản thật dùng URLSession; kiểm thử dùng bản giả.
public protocol HTTPTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> HTTPResponseStream
    func data(for request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data)
    /// Tải về bộ nhớ, dừng và báo lỗi ngay khi vượt `limit` byte (không tải hết rồi mới kiểm).
    func download(_ request: URLRequest, limit: Int) async throws -> (status: Int, headers: [String: String], body: Data)
}

/// Không đi theo chuyển hướng: khóa API không bao giờ bị gửi sang địa chỉ khác.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in response.allHeaderFields { out["\(k)".lowercased()] = "\(v)" }
        return out
    }

    public func stream(_ request: URLRequest) async throws -> HTTPResponseStream {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponseStream(status: http.statusCode, headers: Self.headers(http), lines: lines)
    }

    public func download(_ request: URLRequest, limit: Int) async throws -> (status: Int, headers: [String: String], body: Data) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (http.statusCode, Self.headers(http), body)
    }

    public func data(for request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, Self.headers(http), data)
    }
}
