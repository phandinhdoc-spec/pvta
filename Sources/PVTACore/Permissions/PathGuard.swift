import Darwin
import Foundation

public struct Grant: Codable, Sendable, Equatable {
    /// Đường dẫn chuẩn (đã giải liên kết tượng trưng, đúng hoa thường trên đĩa).
    public var path: String
    /// Cho phép ghi (nếu mức quyền cho phép). Không có thì chỉ đọc.
    public var write: Bool
    public var addedAt: Date
}

enum PathAccess { case read, write }

/// Kiểm tra mọi đường dẫn công cụ muốn đụng tới: phải nằm trong thư mục đã cấp, kể cả sau khi giải liên kết tượng trưng.
struct PathGuard: Sendable {
    let grants: [Grant]
    /// Nơi không bao giờ đọc/ghi được dù nằm trong thư mục đã cấp (dữ liệu PVTA, khóa, hệ thống).
    let protectedRoots: [String]

    private static func text(_ buf: [CChar]) -> String { buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }

    /// Đường dẫn chuẩn của một đường dẫn đang tồn tại: giải liên kết tượng trưng và lấy đúng hoa thường trên đĩa.
    static func canonical(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buf) != -1 { return text(buf) }
        }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return realpath(path, &buf) != nil ? text(buf) : nil
    }

    /// Như `canonical` nhưng cho phép phần cuối chưa tồn tại (tạo tệp mới): giải phần đã có, nối phần chưa có.
    /// Từ chối đường dẫn chứa `..` hoặc không tuyệt đối.
    static func resolve(_ path: String) -> (path: String?, problem: String?) {
        guard path.hasPrefix("/") else { return (nil, "Cần đường dẫn tuyệt đối.") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") { return (nil, "Đường dẫn chứa “..” nên PVTA không nhận.") }
        let clean = parts.filter { $0 != "." }
        var existing = clean.count
        while existing > 0 {
            var st = stat()
            if lstat("/" + clean[0..<existing].joined(separator: "/"), &st) == 0 { break }
            existing -= 1
        }
        let head = "/" + clean[0..<existing].joined(separator: "/")
        guard let base = canonical(head) else { return (nil, "Không đọc được đường dẫn.") }
        let rest = clean[existing...]
        return (rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/"), nil)
    }

    private static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }

    struct Verdict: Equatable {
        var path: String?
        var denied: String?
    }

    func check(_ raw: String, _ access: PathAccess) -> Verdict {
        let (resolved, problem) = Self.resolve((raw as NSString).expandingTildeInPath)
        guard let path = resolved else { return Verdict(path: nil, denied: problem ?? "Đường dẫn không hợp lệ.") }
        if let hit = protectedRoots.first(where: { Self.inside(path, $0) }) {
            return Verdict(path: path, denied: "“\(path)” nằm trong vùng được bảo vệ (\(hit)) nên PVTA không đụng tới.")
        }
        for g in grants where Self.inside(path, g.path) {
            // Thư mục đã cấp phải vẫn là chính thư mục đó (chưa bị thay bằng liên kết tượng trưng).
            guard Self.canonical(g.path) == g.path else { continue }
            if access == .write, !g.write {
                return Verdict(path: path, denied: "Thư mục “\(g.path)” mới được cấp quyền đọc, chưa cấp quyền ghi.")
            }
            return Verdict(path: path, denied: nil)
        }
        return Verdict(path: path, denied: "“\(path)” nằm ngoài các thư mục bạn đã cấp cho PVTA. Hãy cấp thư mục này (grant.add) nếu muốn PVTA làm việc ở đó.")
    }

    /// Vùng không thể cấp quyền (gốc ổ đĩa, hệ thống, dữ liệu PVTA, khóa cá nhân).
    static func protectedRoots(dataHome: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let system = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Library", "/Applications", "/dev", "/cores", "/private/var/db", "/private/var/root"]
        let personal = [".ssh", ".gnupg", ".aws", ".config/gcloud", "Library/Keychains", "Library/Application Support/PVTA"]
            .map { home.appendingPathComponent($0).path }
        return (system + personal + [dataHome.path]).compactMap { canonical($0) ?? $0 }
    }
}

extension DataStore {
    public func grants() throws -> [Grant] {
        try db.query("SELECT path, write, addedAt FROM grants ORDER BY path") {
            Grant(path: $0.text(0), write: $0.int(1) != 0, addedAt: Date(timeIntervalSince1970: $0.double(2)))
        }
    }

    func putGrant(_ g: Grant) throws {
        try db.run("INSERT INTO grants(path, write, addedAt) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET write = excluded.write",
                   [.text(g.path), .int(g.write ? 1 : 0), .double(g.addedAt.timeIntervalSince1970)])
    }

    func deleteGrant(path: String) throws -> Bool { try db.run("DELETE FROM grants WHERE path = ?", [.text(path)]) > 0 }
}
