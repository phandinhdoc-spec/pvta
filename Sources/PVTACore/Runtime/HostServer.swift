import Foundation

/// Máy chủ socket cục bộ của tiến trình giữ dữ liệu. Chỉ chủ sở hữu kết nối được (quyền 0600).
final class HostServer: @unchecked Sendable {
    private let core: Core
    private let path: String
    private let listenFd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var connections: [ObjectIdentifier: LineConnection] = [:]
    private let finished = DispatchSemaphore(value: 0)

    init(core: Core, path: String) throws {
        self.core = core
        self.path = path
        var addr = try socketAddress(path)
        unlink(path)  // socket cũ do tiến trình đã chết để lại; ta đang giữ khóa nên an toàn
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = fd >= 0 && withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard bound, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            if fd >= 0 { close(fd) }
            throw PVTAError("PVTA không mở được cổng nội bộ để dùng chung dữ liệu. Hãy kiểm tra quyền thư mục dữ liệu.")
        }
        listenFd = fd
        Thread { [self] in acceptLoop() }.start()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        while !isStopped {
            var p = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let client = accept(listenFd, nil, nil)
            if client >= 0 { serve(LineConnection(fd: client)) }
        }
        close(listenFd)
        finished.signal()
    }

    private func serve(_ conn: LineConnection) {
        let key = ObjectIdentifier(conn)
        lock.lock(); connections[key] = conn; lock.unlock()
        let subscription = core.bus.subscribe { event in
            conn.send(Frame(event: event.name, data: event.data))
        }
        let core = core
        Task {
            for await line in conn.lines() {
                guard let frame = try? JSONDecoder().decode(Frame.self, from: line),
                      let id = frame.id, let method = frame.method else { continue }
                Task {
                    let scoped: @Sendable (String, JSONValue) -> Void = { name, data in
                        conn.send(Frame(event: name, data: data, requestId: id))
                    }
                    do {
                        let result = try await core.dispatch(method, frame.params ?? .null, scoped: scoped)
                        conn.send(Frame(id: id, result: result))
                    } catch {
                        conn.send(Frame(id: id, error: (error as? PVTAError)?.message ?? "Đã xảy ra lỗi, vui lòng thử lại."))
                    }
                }
            }
            core.bus.unsubscribe(subscription)
            forget(key)
        }
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.lock(); connections[key] = nil; lock.unlock()
    }

    /// Dừng nhận kết nối và ngắt các bên đang nối. `removeSocket` false mô phỏng tiến trình chết đột ngột.
    func stop(removeSocket: Bool) {
        lock.lock(); stopped = true; lock.unlock()
        finished.wait()
        if removeSocket { unlink(path) }
        lock.lock(); let all = Array(connections.values); lock.unlock()
        for c in all { c.close() }
    }
}
