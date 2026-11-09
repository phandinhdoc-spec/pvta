import Foundation

/// Mỗi hội thoại chỉ chạy một lượt tại một thời điểm; các hội thoại khác nhau chạy song song.
public actor TurnGate {
    private var running: [String: Task<JSONValue, Error>] = [:]

    public init() {}

    public func run(chatId: String, _ body: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        guard running[chatId] == nil else {
            throw PVTAError("Hội thoại này đang chạy một lượt. Hãy chờ lượt đó xong, bấm Dừng, hoặc xếp hàng lời lệnh (chat.queue) để chạy ngay sau đó.")
        }
        let task = Task { try await body() }
        running[chatId] = task
        defer { running[chatId] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Dừng lượt đang chạy của hội thoại; trả về false nếu hội thoại không có lượt nào.
    @discardableResult
    public func cancel(chatId: String) -> Bool {
        guard let task = running[chatId] else { return false }
        task.cancel()
        return true
    }

    public func isRunning(chatId: String) -> Bool { running[chatId] != nil }

    public func runningChats() -> [String] { running.keys.sorted() }
}
