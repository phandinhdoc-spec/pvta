import Foundation

public struct UsageWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double?
    public var resetsAt: Date?
    /// "warning" hoặc "rejected" nếu nhà cung cấp báo trực tiếp.
    public var status: String?
    public var updatedAt: Date
}

/// Hạn mức của một nhà cung cấp: cửa sổ 5 giờ và cửa sổ tuần.
public struct ProviderUsage: Codable, Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var week: UsageWindow?
    public var unlimited = false
    public var updatedAt: Date
}

public enum Quota {
    /// Ngưỡng bắt đầu cảnh báo và đề nghị đổi nhà cung cấp.
    public static let threshold = 90.0
    /// Số liệu cũ hơn mức này không còn được tin. Không biết thì không coi là hết, cũng không coi là không giới hạn.
    static let freshness: TimeInterval = 180

    /// Cảnh báo nếu một cửa sổ hạn mức đã dùng từ 90% (hoặc nhà cung cấp báo sắp hết/từ chối).
    public static func warning(_ usage: ProviderUsage?, now: Date = Date()) -> String? {
        guard let usage, !usage.unlimited else { return nil }
        for (label, window) in [("5 giờ", usage.fiveHour), ("tuần", usage.week)] {
            guard let window else { continue }
            let age = now.timeIntervalSince(window.updatedAt)
            if age > freshness || age < -60 { continue }
            if let reset = window.resetsAt, reset <= now { continue }
            if window.status == "warning" || window.status == "rejected" {
                return "Hạn mức \(label): \(window.usedPercent.map { "\(Int($0.rounded()))% đã dùng" } ?? (window.status == "rejected" ? "đã hết" : "sắp hết"))."
            }
            if let used = window.usedPercent, used >= threshold { return "Hạn mức \(label): \(Int(used.rounded()))% đã dùng." }
        }
        return nil
    }
}

/// Đọc số liệu hạn mức từ phản hồi của từng nguồn (đã đối chiếu với đầu ra thật của claude, codex, agy).
enum UsageParser {
    static func date(_ v: JSONValue?) -> Date? {
        if let s = v?.string {
            // Giữ tối đa 3 chữ số phần giây (đầu vào có thể có 6 chữ số).
            let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: trimmed) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: trimmed)
        }
        if let n = v?.number, n > 0 { return Date(timeIntervalSince1970: n < 10_000_000_000 ? n : n / 1000) }
        return nil
    }

    private static func percent(_ v: JSONValue?) -> Double? {
        guard let n = v?.number, n >= 0, n <= 100 else { return nil }
        return n
    }

    /// Phản hồi `get_usage` của claude (phần trăm 0–100).
    static func claude(_ response: JSONValue, now: Date) -> ProviderUsage? {
        guard let limits = response["rate_limits"] else { return nil }
        var usage = ProviderUsage(updatedAt: now)
        for (field, isWeek) in [("five_hour", false), ("seven_day", true)] {
            guard let item = limits[field], case .object = item else { continue }
            let w = UsageWindow(usedPercent: percent(item["utilization"]), resetsAt: date(item["resets_at"]), status: nil, updatedAt: now)
            guard w.usedPercent != nil || w.resetsAt != nil else { continue }
            if isWeek { usage.week = w } else { usage.fiveHour = w }
        }
        return usage.fiveHour != nil || usage.week != nil ? usage : nil
    }

    /// Kết quả `account/rateLimits/read` của codex app-server.
    static func codex(_ result: JSONValue, now: Date) -> ProviderUsage? {
        guard let limits = result["rateLimits"] ?? result["rate_limits"] else { return nil }
        var usage = ProviderUsage(updatedAt: now)
        for key in ["primary", "secondary"] {
            guard let w = limits[key], let minutes = w["windowDurationMins"]?.number ?? w["window_minutes"]?.number else { continue }
            let window = UsageWindow(usedPercent: percent(w["usedPercent"] ?? w["used_percent"]),
                                     resetsAt: date(w["resetsAt"] ?? w["resets_at"]), status: nil, updatedAt: now)
            guard window.usedPercent != nil || window.resetsAt != nil else { continue }
            if minutes == 300 { usage.fiveHour = window } else if minutes == 10080 { usage.week = window }
        }
        return usage.fiveHour != nil || usage.week != nil ? usage : nil
    }

    /// Kết quả `agy --print /usage --output-format json`; nhóm hạn mức theo họ model (Gemini hoặc Claude/GPT).
    static func agy(_ value: JSONValue, model: String?, now: Date) -> ProviderUsage? {
        let data = value["command"]?["data"] ?? value["result"]?["command"]?["data"] ?? value["data"] ?? value
        guard case .array(let groups)? = data["groups"] else { return nil }
        let thirdParty = model.map { $0.range(of: "^(claude|gpt)", options: [.regularExpression, .caseInsensitive]) != nil } ?? false
        func isThirdParty(_ g: JSONValue) -> Bool {
            (g["name"]?.string ?? "").range(of: "claude|gpt", options: [.regularExpression, .caseInsensitive]) != nil
        }
        let group = groups.first { isThirdParty($0) == thirdParty } ?? groups.first
        guard case .array(let buckets)? = group?["buckets"] else { return nil }
        var usage = ProviderUsage(updatedAt: now)
        for b in buckets {
            let w = (b["window"]?.string ?? b["id"]?.string ?? "").lowercased()
            let isFive = w == "5h" || w.hasSuffix("-5h")
            let isWeek = w == "weekly" || w.hasSuffix("-weekly")
            guard isFive || isWeek else { continue }
            let remaining = b["remaining_fraction"]?.number
            let used = remaining.flatMap { $0 >= 0 && $0 <= 1 ? (1 - $0) * 100 : nil } ?? percent(b["used_percent"])
            let rejected = b["disabled"]?.bool == true || (remaining ?? 1) <= 0
            let window = UsageWindow(usedPercent: used, resetsAt: date(b["reset_time"] ?? b["resets_at"]),
                                     status: rejected ? "rejected" : nil, updatedAt: now)
            guard window.usedPercent != nil || window.resetsAt != nil || window.status != nil else { continue }
            if isFive { usage.fiveHour = window } else { usage.week = window }
        }
        return usage.fiveHour != nil || usage.week != nil ? usage : nil
    }

    /// `/alpha/billing/credits` của Command Code.
    static func commandCode(_ credits: JSONValue, now: Date) throws -> ProviderUsage {
        guard let limits = credits["windowLimits"], let limited = limits["limited"]?.bool else {
            throw PVTAError("Command Code chưa cung cấp phần trăm 5h/tuần cho tài khoản này.")
        }
        var usage = ProviderUsage(updatedAt: now)
        if !limited { usage.unlimited = true; return usage }
        for (field, isWeek) in [("fiveHour", false), ("weekly", true)] {
            guard let w = limits[field], let used = w["used"]?.number, let cap = w["cap"]?.number, used >= 0, cap > 0 else { continue }
            let window = UsageWindow(usedPercent: min(100, used / cap * 100), resetsAt: date(w["resetAt"]), status: nil, updatedAt: now)
            if isWeek { usage.week = window } else { usage.fiveHour = window }
        }
        guard usage.fiveHour != nil || usage.week != nil else {
            throw PVTAError("Command Code chưa cung cấp phần trăm 5h/tuần cho tài khoản này.")
        }
        return usage
    }
}
