import Foundation

/// Phía client: gửi lời gọi tới tiến trình giữ dữ liệu và nhận phản hồi, sự kiện.
actor ClientLink {
    private let conn: LineConnection
    private let onEvent: @Sendable (Event) -> Void
    private let onClose: @Sendable () -> Void
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var scoped: [Int: @Sendable (Event) -> Void] = [:]
    private var nextId = 1
    private var closed = false

    init(fd: Int32, onEvent: @escaping @Sendable (Event) -> Void, onClose: @escaping @Sendable () -> Void) {
        conn = LineConnection(fd: fd)
        self.onEvent = onEvent
        self.onClose = onClose
    }

    /// Lời gọi chưa tới được host (an toàn để gửi lại sau khi chuyển quyền).
    struct NotSent: Error {}

    private static let lost = PVTAError("Tiến trình giữ dữ liệu của PVTA vừa thoát. Hãy thử lại sau giây lát.")

    func start() {
        let lines = conn.lines()
        Task { await self.read(lines) }
    }

    private func read(_ lines: AsyncStream<Data>) async {
        for await line in lines {
            guard let frame = try? JSONDecoder().decode(Frame.self, from: line) else { continue }
            if let id = frame.id, let cont = pending.removeValue(forKey: id) {
                scoped[id] = nil
                if let message = frame.error { cont.resume(throwing: PVTAError(message)) }
                else { cont.resume(returning: frame.result ?? .null) }
            } else if let name = frame.event {
                let event = Event(name: name, data: frame.data ?? .null, requestId: frame.requestId)
                if let id = event.requestId {
                    guard pending[id] != nil else { continue }
                    if let receive = scoped[id] { receive(event) } else { onEvent(event) }
                } else { onEvent(event) }
            }
        }
        closed = true
        for cont in pending.values { cont.resume(throwing: Self.lost) }
        pending.removeAll(); scoped.removeAll()
        onClose()
    }

    func call(_ method: String, _ params: JSONValue, onEvent: (@Sendable (Event) -> Void)? = nil) async throws -> JSONValue {
        guard !closed else { throw NotSent() }
        let id = nextId
        nextId += 1
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            scoped[id] = onEvent
            if !conn.send(Frame(id: id, method: method, params: params)) {
                pending[id] = nil; scoped[id] = nil
                cont.resume(throwing: NotSent())
            }
        }
    }

    func close() { conn.close() }
}
