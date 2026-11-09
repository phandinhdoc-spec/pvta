import Foundation

public enum Tier: Sendable { case fast, standard, strong }

/// Loại việc, dùng để chọn model Tự động.
public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case background, simple, standard, office, coding, workflow, planning, pro, exam

    public var label: String {
        switch self {
        case .background: "tác vụ nền"
        case .simple: "việc đơn giản"
        case .standard: "trao đổi, soạn thảo thông thường"
        case .office: "xử lý tài liệu"
        case .coding: "lập trình, công thức"
        case .workflow: "quy trình tự động"
        case .planning: "lập kế hoạch"
        case .pro: "suy luận chuyên sâu"
        case .exam: "ra đề, ma trận, đặc tả"
        }
    }

    var tier: Tier {
        switch self {
        case .background, .simple: .fast
        case .standard, .office, .coding, .workflow: .standard
        case .planning, .pro, .exam: .strong
        }
    }
}

public struct TaskHints: Sendable {
    public var text: String
    public var attachmentNames: [String]
    /// Tác vụ nền nhẹ (tóm tắt, đặt tên, gợi ý).
    public var background: Bool
    public var planning: Bool
    public var proPlanning: Bool
    public var workflow: Bool

    public init(text: String = "", attachmentNames: [String] = [], background: Bool = false, planning: Bool = false,
                proPlanning: Bool = false, workflow: Bool = false) {
        self.text = text
        self.attachmentNames = attachmentNames
        self.background = background
        self.planning = planning
        self.proPlanning = proPlanning
        self.workflow = workflow
    }
}

enum TaskClassifier {
    private static func has(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Phân loại tất định (không gọi AI) từ yêu cầu và tệp đính kèm.
    static func classify(_ h: TaskHints) -> TaskKind {
        let text = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let n = text.count
        if h.background { return .background }
        if h.proPlanning { return .pro }
        if has(#"ma trận|đặc tả|đề kiểm tra|đề thi|trộn đề|kiểm định đề|thang điểm|đáp án chi tiết"#, in: lower) { return .exam }
        if h.planning { return .planning }
        if h.workflow || has(#"!bien\b|!gan\b|!ham\b|!goi\b|!dau-vao\b|!dau-ra\b|!lap-lai\b|quy trình tự động"#, in: lower) { return .workflow }
        if has(#"```|\b(typescript|javascript|python|rust|golang|java|c\+\+|html|css|sql|typst|latex|debug|refactor|stack trace|regex)\b|lỗi mã|viết hàm|thuật toán|\.(ts|tsx|js|py|rs|typ|sh|json|yaml)\b"#, in: lower) { return .coding }
        let office = h.attachmentNames.contains { $0.range(of: #"\.(docx|xlsx|pptx|pdf)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
        if office || !h.attachmentNames.isEmpty
            || has(#"\.(docx|xlsx|pptx|pdf)\b|\b(word|excel|powerpoint|slide|bảng tính|giáo án|kế hoạch bài dạy|khbd|công văn|tờ trình|báo cáo|biên bản|nhận xét học bạ)\b"#, in: lower) { return .office }
        if has(#"suy luận|phân tích chuyên sâu|chứng minh|tối ưu hóa|so sánh chi tiết|phản biện|kiến trúc|đa chiều|phức tạp|bài toán khó|nghiên cứu sâu"#, in: lower) || n > 1800 { return .pro }
        if n <= 220, !text.contains("\n"), !has(#"phân tích|tổng hợp|lập bảng|so sánh|chi tiết"#, in: lower) { return .simple }
        return .standard
    }
}
