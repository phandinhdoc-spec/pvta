import Foundation

public struct ExamScoring: Codable, Sendable, Equatable {
    /// Điểm mỗi câu Phần I (trắc nghiệm nhiều lựa chọn).
    public var part1PerQuestion = 0.25
    /// Điểm mỗi câu Phần II (đúng/sai, 4 ý).
    public var part2PerQuestion = 1.0
    /// true khi thầy cô không nêu mà dùng mặc định (báo trong hồ sơ).
    public var assumed = true
    public init(part1PerQuestion: Double = 0.25, part2PerQuestion: Double = 1.0, assumed: Bool = true) {
        self.part1PerQuestion = part1PerQuestion; self.part2PerQuestion = part2PerQuestion; self.assumed = assumed
    }
}

/// Một ô của kế hoạch ra đề, lấy thẳng từ ô ma trận.
public struct ExamSlot: Codable, Sendable, Equatable {
    public var id: String
    /// 1, 2, 3
    public var part: Int
    public var topic: String
    public var level: String
    public var code: String
    /// Phần I: số câu; Phần II: số ý; Phần III: điểm.
    public var amount: Double
    public var source: String
}

public struct ExamBlueprint: Codable, Sendable, Equatable {
    public var slots: [ExamSlot]
    public var part1Questions: Int
    public var part2Items: Int
    public var part2Questions: Int
    public var part3Points: Double
    public var totalPoints: Double
    public var issues: [String]
}

/// Việc cần viết: đúng một câu, kèm chủ đề, mức độ (và mức độ từng ý ở Phần II) lấy từ kế hoạch.
public struct ExamTask: Codable, Sendable, Equatable {
    public var id: String
    public var part: Int
    public var topic: String
    public var level: String
    /// Phần II: mức độ của 4 ý a–d.
    public var itemLevels: [String]
    public var itemTopics: [String]
    public var points: Double
    public var slotIds: [String]
}

public struct ExamStatement: Codable, Sendable, Equatable {
    public var text: String
    public var truth: Bool
    public var level: String
    public var topic: String
}

public struct ExamQuestion: Codable, Sendable, Equatable {
    public var id: String
    public var part: Int
    public var topic: String
    public var level: String
    public var points: Double
    public var stem: String
    /// Phần I: 4 phương án (không kèm nhãn A–D).
    public var options: [String]
    /// Phần I: chỉ số phương án đúng (0–3).
    public var answer: Int?
    public var statements: [ExamStatement]
    /// Phần III: đáp án ngắn / kết quả.
    public var answerText: String?
    public var rubric: [RubricStep]
    public var solution: String
    /// Mã đoạn nguồn được dùng.
    public var passage: String?
    public var slotIds: [String]
}

public struct RubricStep: Codable, Sendable, Equatable {
    public var step: String
    public var points: Double
}

public struct Passage: Codable, Sendable, Equatable {
    public var ref: String
    public var text: String
}

public struct Exam: Codable, Sendable, Equatable {
    public var title: String
    public var subject: String
    public var grade: String
    public var questions: [ExamQuestion]
    public var scoring: ExamScoring
}

/// Một mã đề: thứ tự câu, phương án và ý đã xáo, kèm đáp án của riêng mã đề đó.
public struct ExamVersion: Codable, Sendable, Equatable {
    public var code: String
    public var questions: [ExamQuestion]
    public var key: [KeyEntry]
}

public struct KeyEntry: Codable, Sendable, Equatable {
    public var number: Int
    public var questionId: String
    public var part: Int
    /// Phần I: A–D; Phần II: "a:Đ b:S c:Đ d:S"; Phần III: đáp án.
    public var answer: String
    public var points: Double
}

public struct CoverageRow: Codable, Sendable, Equatable {
    public var part: Int
    public var topic: String
    public var level: String
    public var expected: Double
    public var actual: Double
}

public struct ExamReview: Codable, Sendable, Equatable {
    public var passed: Bool
    public var issues: [String]
    public var coverage: [CoverageRow]
    public var totalPoints: Double
}

public struct ExamDossier: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var createdAt: Double
    public var matrixSource: String
    public var matrixIssues: [String]
    public var blueprint: ExamBlueprint
    public var exam: Exam
    public var versions: [ExamVersion]
    public var review: ExamReview
    public var rules: [ExamRule]
}
