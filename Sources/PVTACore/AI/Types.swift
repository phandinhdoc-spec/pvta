import Foundation

/// Ảnh gửi kèm một tin nhắn (đã kiểm tra định dạng và kích thước).
public struct ChatImage: Sendable, Equatable {
    public var name: String
    public var mime: String
    public var data: Data
    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public var images: [ChatImage]
    public init(role: Role, content: String, images: [ChatImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var system: String?
    public var messages: [ChatMessage]
    public var maxTokens: Int
    /// Mã phiên của công cụ dòng lệnh (từ `AIEvent.session` của lượt trước) để nối tiếp hội thoại.
    public var conversationId: String?
    public init(system: String? = nil, messages: [ChatMessage], maxTokens: Int = 8192, conversationId: String? = nil) {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.conversationId = conversationId
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Sự kiện của một lượt gửi: từng đoạn chữ, rồi mức dùng (nếu nhà cung cấp báo) khi lượt kết thúc.
public enum AIEvent: Sendable, Equatable {
    case text(String)
    case usage(TokenUsage)
    /// Mã phiên do công cụ dòng lệnh báo, lưu lại để lượt sau nối tiếp.
    case session(String)
    /// Model thực sự đang trả lời (khi chọn Tự động hoặc sau khi đổi nhà cung cấp).
    case model(String)
}

public struct ModelInfo: Sendable, Equatable, Codable {
    public var id: String
    public var label: String?
    public init(id: String, label: String? = nil) {
        self.id = id
        self.label = label
    }
}

/// Lỗi từ nhà cung cấp AI, có phân loại để lớp trên xử lý (ví dụ `rateLimited` để bàn giao nhà cung cấp).
public struct ProviderError: Error, Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case missingKey, notInstalled, auth, model, rateLimited, server, network, badRequest, incomplete, invalidResponse, other
    }
    public let kind: Kind
    public let message: String
    /// Số giây nhà cung cấp yêu cầu chờ (header Retry-After), nếu có.
    public let retryAfter: TimeInterval?

    public init(_ kind: Kind, _ message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }

    static func http(status: Int, body: String, retryAfter: TimeInterval?, label: String) -> ProviderError {
        let detail = errorDetail(body)
        switch status {
        case 401, 403:
            return ProviderError(.auth, "Khóa API của \(label) không đúng, đã hết hạn hoặc không có quyền dùng model này. Hãy kiểm tra lại khóa trong Cài đặt.")
        case 404:
            return ProviderError(.model, "Model hoặc địa chỉ của \(label) không dùng được\(detail). Hãy kiểm tra tên model và địa chỉ trong Cài đặt.")
        case _ where (status == 400 || status == 422) && body.range(of: "model", options: .caseInsensitive) != nil:
            return ProviderError(.model, "Model không dùng được ở \(label)\(detail). Hãy chọn model khác.")
        case 429:
            var m = UserMessage.text(forHTTPStatus: 429)
            if let s = retryAfter { m += " Có thể thử lại sau khoảng \(Int(s.rounded(.up))) giây." }
            return ProviderError(.rateLimited, m, retryAfter: retryAfter)
        case 300..<400:
            return ProviderError(.other, "\(label) chuyển hướng sang một địa chỉ khác. PVTA không đi theo để bảo vệ khóa API; hãy kiểm tra lại địa chỉ.")
        case 500...599:
            return ProviderError(.server, UserMessage.text(forHTTPStatus: status))
        default:
            return ProviderError(.badRequest, UserMessage.text(forHTTPStatus: status) + detail)
        }
    }

    /// Lấy câu báo lỗi ngắn từ thân phản hồi JSON, đã che khóa.
    private static func errorDetail(_ body: String) -> String {
        guard let data = body.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "" }
        let message = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string
        guard let message, !message.isEmpty else { return "" }
        return " (" + String(Redactor.clean(message).prefix(200)) + ")"
    }
}
