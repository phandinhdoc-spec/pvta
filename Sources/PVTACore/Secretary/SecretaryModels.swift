import Foundation

public struct SecretarySettings: Codable, Sendable, Equatable {
    public struct Proactive: Codable, Sendable, Equatable {
        public var enabled = true
        /// Chu kỳ kiểm tra nhắc việc (phút).
        public var intervalMin = 15
        /// Nhắc trước hạn hoặc trước giờ bắt đầu bao nhiêu phút.
        public var leadMinutes = 30
        /// Hiện bản tin đầu ngày.
        public var dailyPopup = true
    }
    public var enabled = true
    /// "auto" hoặc mã đầy đủ `nhà-cung-cấp/model`: model riêng của Thư ký.
    public var model = "auto"
    public var proactive = Proactive()
    /// Nguồn dữ liệu của PVTA mà Thư ký được tra cứu. Việc tôi giao luôn đọc được vì là dữ liệu của chính Thư ký.
    public var sources: [String: Bool] = ["calendar": true, "projects": true, "notebooks": true, "skills": true, "chats": false]

    static let sourceNames = ["calendar", "projects", "notebooks", "skills", "chats"]
}

/// Việc tôi giao cho Thư ký. Có phiên bản (`revision`) để hai nơi sửa cùng lúc không ghi đè nhau, và thùng rác.
public struct AssignedTask: Codable, Sendable, Equatable {
    public var id: Int
    public var assignedAt: String
    public var content: String
    public var deadline: String?
    public var done: Bool
    public var completedAt: String?
    public var notes: String?
    /// not-started | in-progress | completed
    public var progress: String?
    /// low | normal | high
    public var priority: String?
    public var preparationDate: String?
    /// duty | routine-teaching | special-teaching
    public var category: String?
    public var sourceStatus: String?
    public var sourceRef: String?
    public var nextAction: String?
    public var schoolYear: String?
    public var revision: Int
    public var deletedAt: String?
}

public struct SecretaryNotice: Codable, Sendable, Equatable {
    public var id: String
    public var key: String
    /// upcoming | task | overdue | info
    public var kind: String
    public var title: String
    public var body: String
    public var at: Double
    public var read: Bool
    public var dismissed: Bool
}

public struct BriefingItem: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String          // task | event
    public var title: String
    public var detail: String
    public var start: String?
    public var location: String?
    public var done: Bool
    public var overdue: Bool
    /// today | week | upcoming
    public var section: String
    public var source: String
}

public struct DailyBriefing: Codable, Sendable, Equatable {
    public var key: String
    public var day: String
    public var period: String
    public var weekEnd: String
    public var enabled: Bool
    /// Đến lúc hiện: bật, có nội dung và chưa xác nhận đã hiện ở buổi này.
    public var due: Bool
    public var items: [BriefingItem]
    public var warnings: [String]
}

public struct CommandTemplate: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// Nội dung lệnh; `[mô tả]` là chỗ cần điền.
    public var text: String
    public var fields: [String]
}

enum SecretaryCalendar {
    /// Giờ Việt Nam (UTC+7), không phụ thuộc múi giờ máy.
    static var vn: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!; return c }
    static func day(_ d: Date) -> String {
        let c = vn.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func hour(_ d: Date) -> Int { vn.component(.hour, from: d) }
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!; f.formatOptions = [.withInternetDateTime, .withTimeZone]; return f.string(from: d) }
    static func validDay(_ s: String) -> Bool {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = vn.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: s).map { f.string(from: $0) == s } ?? false
    }
}
