import Foundation

public struct Project: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
}

public struct Chat: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var projectId: String?
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Model riêng của hội thoại (`nil` = Tự động).
    public var model: String? = nil
}

public enum MessageRole: String, Codable, Sendable {
    case user, assistant
}

public struct Message: Codable, Equatable, Sendable {
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    /// Model đã trả lời (tin của trợ lý).
    public var model: String? = nil
    /// Lý do lượt này không hoàn tất (lỗi, bị dừng); `nil` nếu bình thường.
    public var error: String? = nil
    /// Các lần gọi công cụ trong lượt (để hiển thị và tra cứu).
    public var tools: JSONValue? = nil
}

/// Toàn bộ dữ liệu người dùng ở dạng tệp JSON để sao lưu, chuyển máy.
public struct ExportBundle: Codable, Equatable, Sendable {
    public struct ChatEntry: Codable, Equatable, Sendable {
        public var chat: Chat
        public var messages: [Message]
    }
    public static let currentFormat = 1
    public var format: Int
    public var projects: [Project]
    public var chats: [ChatEntry]
    public var settings: [String: String]
}
