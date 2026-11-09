import CryptoKit
import Foundation

public struct InstallerInfo: Codable, Sendable, Equatable {
    public var backend: CLIBackendID
    public var name: String
    public var url: String
    public var docs: String
}

/// Tải bộ cài chính thức của công cụ AI. Chỉ nhận HTTPS từ các miền nhà cung cấp đã khai báo,
/// kiểm tra từng chuyển hướng, giới hạn kích thước/thời gian và từ chối trang web.
enum ToolInstaller {
    private struct Source {
        let base: String
        let hosts: [String]
    }

    private static let sources: [CLIBackendID: Source] = [
        .claude: Source(base: "https://claude.ai",
                        hosts: ["claude.ai", "www.claude.ai", "downloads.claude.ai", "claude.com", "www.claude.com", "downloads.claude.com"]),
        .codex: Source(base: "https://chatgpt.com/codex", hosts: ["chatgpt.com", "www.chatgpt.com", "releases.openai.com"]),
        .agy: Source(base: "https://antigravity.google/cli", hosts: ["antigravity.google", "www.antigravity.google"]),
    ]

    static let sizeLimit = 2 * 1024 * 1024

    static func info(_ id: CLIBackendID) throws -> InstallerInfo {
        guard let s = sources[id] else { throw PVTAError("PVTA không tự cài \(id.name). Hãy cài theo hướng dẫn tại \(id.docs).") }
        return InstallerInfo(backend: id, name: id.name, url: s.base + "/install.sh", docs: id.docs)
    }

    static var catalog: [InstallerInfo] { CLIBackendID.allCases.compactMap { try? info($0) } }

    static func trusted(_ id: CLIBackendID, _ url: URL) -> Bool {
        guard let s = sources[id], url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return s.hosts.contains(host)
    }

    struct Downloaded {
        let directory: URL
        let file: URL
        let sha256: String
        let finalURL: String
    }

    /// Bộ cài chạy bằng `bash` (codex dùng `sh`).
    static func command(_ id: CLIBackendID, file: URL) -> (binary: String, args: [String]) {
        (id == .codex ? "/bin/sh" : "/bin/bash", [file.path])
    }

    static func download(_ id: CLIBackendID, into home: URL, transport: HTTPTransport, timeout: Duration = .seconds(90)) async throws -> Downloaded {
        let info = try info(id)
        let fetch = Task { () -> (Data, String) in
            var url = URL(string: info.url)!
            for _ in 0..<6 {
                guard trusted(id, url) else { throw PVTAError("Nguồn chuyển hướng không thuộc nhà cung cấp chính thức nên PVTA không tải.") }
                var request = URLRequest(url: url)
                request.timeoutInterval = 90
                let reply: (status: Int, headers: [String: String], body: Data)
                do { reply = try await transport.download(request, limit: sizeLimit) } catch let e as URLError where e.code == .dataLengthExceedsMaximum {
                    throw PVTAError("Nguồn tải trả về tệp quá lớn nên PVTA chưa mở cài đặt.")
                } catch is CancellationError { throw CancellationError() } catch {
                    throw PVTAError("Không tải được bộ cài chính thức. " + UserMessage.text(for: error))
                }
                if [301, 302, 303, 307, 308].contains(reply.status) {
                    guard let location = reply.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                        throw PVTAError("Nguồn tải không cho biết địa chỉ chuyển hướng.")
                    }
                    url = next
                    continue
                }
                guard (200..<300).contains(reply.status) else {
                    throw PVTAError("Không tải được bộ cài chính thức (mã \(reply.status)). Kiểm tra mạng rồi thử lại.")
                }
                if reply.headers["content-type"]?.range(of: "text/html", options: .caseInsensitive) != nil {
                    throw PVTAError("Nguồn tải trả về trang web thay vì bộ cài nên PVTA chưa mở cài đặt.")
                }
                let head = String(decoding: reply.body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if reply.body.isEmpty || head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || reply.body.contains(0) {
                    throw PVTAError("Bộ cài tải về không hợp lệ nên PVTA chưa mở cài đặt.")
                }
                return (reply.body, url.absoluteString)
            }
            throw PVTAError("Nguồn tải chuyển hướng quá nhiều lần nên PVTA dừng lại.")
        }
        let (data, finalURL) = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Data, String).self) { group in
                group.addTask { try await fetch.value }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    fetch.cancel()
                    throw PVTAError("Tải bộ cài quá thời gian cho phép. Kiểm tra mạng rồi thử lại.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { fetch.cancel() }

        let parent = home.appendingPathComponent("installers", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = parent.appendingPathComponent("\(id.rawValue)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = dir.appendingPathComponent("install.sh")
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            // Ghi nguồn và mã SHA-256 để tra cứu. Đây không phải xác minh chữ ký của nhà phát hành.
            let source: JSONValue = ["backend": .string(id.rawValue), "url": .string(info.url), "finalUrl": .string(finalURL),
                                     "sha256": .string(sha), "downloadedAt": .string(ISO8601DateFormatter().string(from: Date()))]
            try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
            return Downloaded(directory: dir, file: file, sha256: sha, finalURL: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw PVTAError("Không lưu được bộ cài vào thư mục dữ liệu của PVTA. Hãy kiểm tra quyền ghi và dung lượng ổ đĩa.")
        }
    }
}
