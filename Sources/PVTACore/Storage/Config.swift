import Foundation

/// Ba mức quyền (mặc định Hỏi duyệt).
public enum PermissionLevel: String, Codable, Sendable, CaseIterable {
    case readOnly = "chi-doc"
    case askApproval = "hoi-duyet"
    case autoEdit = "tu-sua"
}

/// Cài đặt riêng của một nhà cung cấp AI. Khóa API không nằm ở đây mà ở Keychain.
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var baseUrl: String?
    public var model: String?
    public init(baseUrl: String? = nil, model: String? = nil) {
        self.baseUrl = baseUrl
        self.model = model
    }
}

/// Cấu hình người dùng. Không chứa khóa API (khóa nằm trong Keychain).
public struct Config: Codable, Sendable, Equatable {
    public var permission: PermissionLevel = .askApproval
    /// "auto" hoặc mã model người dùng chọn.
    public var model: String = "auto"
    public var writingMode: String?
    /// Cài đặt từng nhà cung cấp AI, khóa theo mã (anthropic, openai…).
    public var providers: [String: ProviderSettings] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case permission, model, writingMode, providers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permission = try c.decodeIfPresent(PermissionLevel.self, forKey: .permission) ?? .askApproval
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "auto"
        writingMode = try c.decodeIfPresent(String.self, forKey: .writingMode)
        providers = try c.decodeIfPresent([String: ProviderSettings].self, forKey: .providers) ?? [:]
    }
}

/// Đọc, ghi cấu hình ở thư mục dữ liệu chung. Tệp chỉ chủ sở hữu đọc được, ghi nguyên tử.
public struct ConfigStore: Sendable {
    public let paths: DataPaths

    public init(paths: DataPaths) { self.paths = paths }

    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: paths.config.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: paths.config))
        } catch {
            throw PVTAError("Tệp cấu hình \(paths.config.path) bị hỏng nên PVTA không đọc được. Hãy sửa hoặc đổi tên tệp này rồi mở lại.")
        }
    }

    public func save(_ config: Config) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(config).write(to: paths.config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.config.path)
        } catch {
            throw PVTAError("Không ghi được cấu hình vào \(paths.config.path). Hãy kiểm tra quyền ghi.")
        }
    }

    /// Đọc, sửa rồi ghi lại.
    @discardableResult
    public func update(_ change: (inout Config) -> Void) throws -> Config {
        var config = try load()
        change(&config)
        try save(config)
        return config
    }
}
