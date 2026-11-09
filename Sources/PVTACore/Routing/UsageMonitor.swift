import Foundation

/// Giữ số liệu hạn mức đã đọc và những nhà cung cấp vừa từ chối vì hạn mức.
public actor UsageMonitor {
    private let read: @Sendable (String) async throws -> ProviderUsage
    private let now: @Sendable () -> Date
    private var cache: [String: ProviderUsage] = [:]
    private var inflight: [String: Task<ProviderUsage, Error>] = [:]
    private var limited: [String: Date] = [:]

    /// Nhà cung cấp từ chối vì hạn mức mà không nói bao lâu thì tạm nghỉ chừng này.
    static let defaultCooldown: TimeInterval = 10 * 60
    static let cacheLife: TimeInterval = 60

    public init(now: @escaping @Sendable () -> Date = { Date() }, read: @escaping @Sendable (String) async throws -> ProviderUsage) {
        self.now = now
        self.read = read
    }

    /// Đọc hạn mức (dùng bản đã đọc trong 60 giây gần đây, trừ khi `force`).
    public func usage(_ key: String, force: Bool = false) async throws -> ProviderUsage {
        if !force, let c = cache[key], now().timeIntervalSince(c.updatedAt) < Self.cacheLife { return c }
        if let task = inflight[key] { return try await task.value }
        let task = Task { try await read(key) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let value = try await task.value
        cache[key] = value
        return value
    }

    func cached(_ key: String) -> ProviderUsage? { cache[key] }

    /// Dùng để kiểm trước khi gửi: số liệu đủ mới thì dùng ngay, chưa có thì đọc (tối đa vài giây). Đọc không được thì coi là chưa biết.
    func warning(_ key: String) async -> String? {
        if let c = cache[key], now().timeIntervalSince(c.updatedAt) < Quota.freshness { return Quota.warning(c, now: now()) }
        guard let fresh = try? await usage(key, force: true) else { return nil }
        return Quota.warning(fresh, now: now())
    }

    func markLimited(_ key: String, retryAfter: TimeInterval?) {
        limited[key] = now().addingTimeInterval(retryAfter ?? Self.defaultCooldown)
    }

    func limitedUntil(_ key: String) -> Date? {
        guard let until = limited[key] else { return nil }
        if until <= now() { limited[key] = nil; return nil }
        return until
    }

    /// Dùng cho kiểm thử: đặt số liệu hạn mức đã biết.
    func inject(_ key: String, _ usage: ProviderUsage) { cache[key] = usage }
}
