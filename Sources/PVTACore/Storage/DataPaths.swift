import Foundation

/// Vị trí thư mục dữ liệu chung của PVTA (CLI và Desktop cùng dùng).
/// Mặc định `~/Library/Application Support/PVTA`; biến môi trường `PVTA_HOME` ghi đè (dùng cho kiểm thử).
public struct DataPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DataPaths {
        if let custom = environment["PVTA_HOME"], !custom.isEmpty {
            return DataPaths(home: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PVTA", isDirectory: true)
        return DataPaths(home: support)
    }

    public var config: URL { home.appendingPathComponent("config.json") }
    public var database: URL { home.appendingPathComponent("pvta.sqlite") }

    /// Tạo thư mục dữ liệu (chỉ chủ sở hữu truy cập) nếu chưa có.
    public func prepare() throws {
        do {
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw PVTAError("Không tạo được thư mục dữ liệu của PVTA tại \(home.path). Hãy kiểm tra quyền ghi.")
        }
    }
}
