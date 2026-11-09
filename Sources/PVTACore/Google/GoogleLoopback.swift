import Foundation
import Darwin

/// Chỉ nghe trên IPv4 loopback, một lượt đăng nhập, không ghi URL callback vào nhật ký.
final class GoogleLoopback: @unchecked Sendable {
    let redirect: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    init(receive: @escaping @Sendable (String) async -> Bool) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw PVTAError("Không mở được cổng đăng nhập Google.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketFD, 4) == 0 else { close(socketFD); throw PVTAError("Không mở được cổng đăng nhập Google.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        guard found == 0 else { close(socketFD); throw PVTAError("Không xác định được cổng đăng nhập.") }
        fd = socketFD; redirect = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth2/callback"
        let redirect = redirect
        Thread { [self] in
            let deadline = Date().addingTimeInterval(600)
            defer { close(socketFD) }
            while !isStopped && Date() < deadline {
                var p = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let client = accept(socketFD, nil, nil); if client < 0 { continue }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = recv(client, &bytes, bytes.count, 0)
                let request = count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
                let parts = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth2/callback?") else { close(client); continue }
                let target = redirect.components(separatedBy: "/oauth2/callback")[0] + String(parts[1])
                Task { [self] in
                    let accepted = await receive(target)
                    let body = accepted ? "Đã nhận đăng nhập Google. Bạn có thể đóng trang này và trở lại PVTA." : "Không nhận được đăng nhập hợp lệ. Hãy trở lại PVTA để thử lại."
                    let data = Data("HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
                    data.withUnsafeBytes { ptr in _ = send(client, ptr.baseAddress, data.count, 0) }; close(client)
                    if accepted { stop() }
                }
            }
        }.start()
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
