import Foundation
import Darwin

/// Đi từng thành phần bằng descriptor; không đi theo symlink kể cả thư mục bị đổi giữa hai lần kiểm tra.
enum GitHubFiles {
    static func open(root: String, relative: String) throws -> Int32 {
        _ = try GitHubInput.path(relative)
        var fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PVTAError("Thư mục nguồn đã đổi hoặc không mở được.") }
        let parts = relative.split(separator: "/")
        for (index, part) in parts.enumerated() {
            let next = openat(fd, String(part), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
            close(fd)
            guard next >= 0 else { throw PVTAError("Nguồn không tồn tại hoặc có liên kết tượng trưng.") }; fd = next
        }
        return fd
    }
}
