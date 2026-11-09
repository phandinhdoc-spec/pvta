import Foundation

/// Việc cần hệ điều hành làm hộ: chuyển vào Thùng rác, mở tệp, hiện trong Finder. Kiểm thử thay bằng bản giả.
public struct HostActions: Sendable {
    /// Chuyển vào Thùng rác; trả về nơi tệp nằm sau đó.
    public var trash: @Sendable (URL) throws -> URL
    /// Mở bằng ứng dụng mặc định, hoặc (reveal = true) hiện trong Finder.
    public var open: @Sendable (URL, Bool) -> Void

    public init(trash: @escaping @Sendable (URL) throws -> URL, open: @escaping @Sendable (URL, Bool) -> Void) {
        self.trash = trash
        self.open = open
    }

    public static let system = HostActions(
        trash: { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return (result as URL?) ?? url
        },
        open: { url, reveal in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = (reveal ? ["-R"] : []) + [url.path]
            try? p.run()
        })
}
