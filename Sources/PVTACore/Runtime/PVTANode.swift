import Foundation

/// Một tiến trình PVTA (CLI hoặc Desktop) trong mô hình dùng chung dữ liệu.
/// Tiến trình mở đầu tiên giành khóa, giữ dữ liệu và mở socket (vai trò `host`); các tiến trình sau nối vào
/// làm `client`. Host thoát thì một client tự nhận quyền. Mọi bên dùng cùng `call` và `events`.
public actor PVTANode {
    public enum Role: Sendable { case host, client }

    private struct HostState {
        let core: Core
        let server: HostServer
        let lock: LockFile
        let subscription: UUID
    }

    private enum State {
        case switching
        case host(HostState)
        case client(ClientLink)
        case closed
    }

    /// Luồng sự kiện của nút này: sự kiện chung và sự kiện riêng của các lời gọi do nút này gửi.
    /// Chỉ nên có một nơi đọc luồng này.
    public nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private let paths: DataPaths
    private let extraMethods: [String: Core.Handler]
    private let aiOverride: AIClient?
    private let capturer: ScreenCapturing
    private let hostActions: HostActions
    private var state: State = .switching
    private var generation = 0
    private var requestSeq = 0
    private var failure: PVTAError?

    public var role: Role? {
        switch state {
        case .host: .host
        case .client: .client
        default: nil
        }
    }

    private init(paths: DataPaths, extraMethods: [String: Core.Handler], ai: AIClient?, capturer: ScreenCapturing, hostActions: HostActions) {
        self.paths = paths
        self.hostActions = hostActions
        self.capturer = capturer
        self.aiOverride = ai
        self.extraMethods = extraMethods
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    public static func open(paths: DataPaths, extraMethods: [String: Core.Handler] = [:], ai: AIClient? = nil,
                            capturer: ScreenCapturing = SystemScreenCapturer(), hostActions: HostActions = .system) async throws -> PVTANode {
        try paths.prepare()
        let node = PVTANode(paths: paths, extraMethods: extraMethods, ai: ai, capturer: capturer, hostActions: hostActions)
        try await node.join()
        return node
    }

    private var lockPath: String { paths.home.appendingPathComponent("core.lock").path }
    private var socketPath: String { paths.home.appendingPathComponent("core.sock").path }

    private func join() async throws {
        let next = try await acquire()
        if case .closed = state { dispose(next) } else { state = next }
    }

    /// Giành khóa để làm host; nếu đã có host thì nối vào làm client. Thử lại tối đa 10 giây.
    private func acquire() async throws -> State {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let lock = LockFile.tryAcquire(lockPath) {
                do {
                    let store = try DataStore(file: paths.database)
                    try await store.recoverActivities()
                    let core = Core(store: store, ai: aiOverride ?? AIClient(config: ConfigStore(paths: paths)), extraMethods: extraMethods, capturer: capturer, hostActions: hostActions)
                    await core.files.prune()
                    core.startBackground()
                    let server = try HostServer(core: core, path: socketPath)
                    let sink = eventSink
                    let sub = core.bus.subscribe { sink.yield($0) }
                    return .host(HostState(core: core, server: server, lock: lock, subscription: sub))
                } catch {
                    lock.release(removing: true)
                    throw error
                }
            }
            if let fd = connectSocket(socketPath) {
                generation += 1
                let gen = generation
                let sink = eventSink
                let link = ClientLink(fd: fd, onEvent: { sink.yield($0) }, onClose: { [weak self] in
                    Task { await self?.linkClosed(generation: gen) }
                })
                await link.start()
                // Một lời gọi thử để chắc chắn host đã đăng ký nhận sự kiện cho kết nối này trước khi trả về.
                if (try? await link.call("core.ping", .null)) != nil { return .client(link) }
                await link.close()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PVTAError("Không kết nối được với tiến trình giữ dữ liệu của PVTA. Hãy đóng các cửa sổ PVTA rồi mở lại.")
    }

    private func linkClosed(generation closedGeneration: Int) async {
        guard closedGeneration == generation, case .client = state else { return }
        state = .switching
        do {
            let next = try await acquire()
            if case .closed = state { dispose(next) } else { state = next }
        } catch {
            failure = (error as? PVTAError) ?? PVTAError("Mất kết nối với dữ liệu của PVTA.")
            state = .closed
        }
    }

    private func dispose(_ state: State) {
        switch state {
        case .host(let h):
            h.server.stop(removeSocket: true)
            h.core.bus.unsubscribe(h.subscription)
            h.lock.release(removing: true)
        case .client(let link):
            Task { await link.close() }
        default: break
        }
    }

    /// Gọi một phương thức của lõi. Đang chuyển quyền giữ dữ liệu thì chờ tối đa 15 giây.
    /// Nếu có onEvent, sự kiện riêng đi thẳng tới callback này thay vì luồng events chung của nút.
    public func call(_ method: String, _ params: JSONValue = .null,
                     onEvent: (@Sendable (Event) -> Void)? = nil) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(15)
        while true {
            if case .switching = state {
                guard Date() < deadline else { throw PVTAError("PVTA đang kết nối lại với dữ liệu, hãy thử lại sau giây lát.") }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            switch state {
            case .host(let h):
                requestSeq += 1
                let id = requestSeq
                let sink = eventSink
                return try await h.core.dispatch(method, params) { name, data in
                    let event = Event(name: name, data: data, requestId: id)
                    if let onEvent { onEvent(event) } else { sink.yield(event) }
                }
            case .client(let link):
                do {
                    return try await link.call(method, params, onEvent: onEvent)
                } catch is ClientLink.NotSent {
                    // Host vừa thoát trước khi nhận lời gọi: chờ chuyển quyền rồi gửi lại.
                    guard Date() < deadline else { throw PVTAError("PVTA đang kết nối lại với dữ liệu, hãy thử lại sau giây lát.") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            default:
                throw failure ?? PVTAError("PVTA đã đóng kết nối với dữ liệu.")
            }
        }
    }

    /// Thoát gọn: host dọn socket và khóa; các client còn lại tự nhận quyền.
    public func shutdown() {
        let old = state
        state = .closed
        dispose(old)
        eventSink.finish()
    }

    /// Mô phỏng tiến trình chết đột ngột (không dọn tệp), dùng cho kiểm thử.
    func abandon() {
        let old = state
        state = .closed
        switch old {
        case .host(let h):
            h.server.stop(removeSocket: false)
            h.core.bus.unsubscribe(h.subscription)
            h.lock.release(removing: false)
        case .client(let link):
            Task { await link.close() }
        default: break
        }
        eventSink.finish()
    }
}
