import Foundation

/// Một dòng JSON trên socket. Yêu cầu: `id` + `method`; phản hồi: `id` + `result`/`error`;
/// sự kiện: `event` + `data` (kèm `requestId` nếu thuộc riêng một lời gọi).
struct Frame: Codable, Sendable {
    var id: Int?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: String?
    var event: String?
    var data: JSONValue?
    var requestId: Int?
}

func socketAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        throw PVTAError("Đường dẫn thư mục dữ liệu quá dài nên PVTA không mở được cổng nội bộ. Hãy chọn thư mục ngắn hơn.")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
    }
    return addr
}

func connectSocket(_ path: String) -> Int32? {
    guard var addr = try? socketAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return nil }
    return fd
}

/// Kết nối đọc ghi theo dòng. Luồng `lines()` giữ đúng thứ tự dòng và kết thúc khi một bên đóng.
final class LineConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread { [self] in
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buffer.append(chunk, count: n)
                    while let nl = buffer.firstIndex(of: 10) {
                        continuation.yield(buffer.subdata(in: buffer.startIndex..<nl))
                        buffer.removeSubrange(buffer.startIndex...nl)
                    }
                }
                lock.lock(); closed = true; Darwin.close(fd); lock.unlock()
                continuation.finish()
            }
            thread.start()
        }
    }

    @discardableResult
    func send(_ frame: Frame) -> Bool {
        guard var data = try? JSONEncoder().encode(frame) else { return false }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Đóng kết nối; luồng đọc sẽ tự kết thúc và giải phóng mô tả tệp.
    func close() { shutdown(fd, SHUT_RDWR) }
}

/// Khóa độc quyền (flock) quyết định tiến trình nào giữ dữ liệu. Hệ điều hành tự nhả khi tiến trình chết.
final class LockFile: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    static func tryAcquire(_ path: String) -> LockFile? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        // Tệp khóa có thể vừa bị tiến trình giữ trước xóa: khi đó khóa này vô nghĩa, thử lại.
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, stat(path, &b) == 0, a.st_ino == b.st_ino else { close(fd); return nil }
        return LockFile(fd: fd, path: path)
    }

    func release(removing: Bool) {
        if removing { unlink(path) }
        close(fd)
    }
}
