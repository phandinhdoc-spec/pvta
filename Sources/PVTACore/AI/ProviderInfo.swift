import Foundation

public enum APIProtocol: Sendable { case anthropic, openai }

/// Thông tin cố định của từng nhà cung cấp.
public struct ProviderInfo: Sendable {
    public let id: String
    public let label: String
    public let baseURL: String
    public let apiProtocol: APIProtocol
    public let needsKey: Bool
    public let defaultModel: String
    public let keyHint: String
    /// Địa chỉ không cho đổi (khóa chỉ gửi tới đúng máy chủ chính thức).
    public let fixedURL: Bool
    /// Xem được danh sách model mà không cần khóa.
    public let publicModels: Bool
    /// Xin máy chủ báo mức dùng trong luồng (`stream_options.include_usage`).
    public let usageInStream: Bool

    public static let all: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", label: "Anthropic (Claude)", baseURL: "https://api.anthropic.com/v1", apiProtocol: .anthropic,
                     needsKey: true, defaultModel: "claude-sonnet-5-5", keyHint: "Khóa bắt đầu bằng sk-ant-, lấy ở console.anthropic.com",
                     fixedURL: false, publicModels: false, usageInStream: false),
        ProviderInfo(id: "openai", label: "OpenAI (GPT)", baseURL: "https://api.openai.com/v1", apiProtocol: .openai,
                     needsKey: true, defaultModel: "gpt-5.4-mini", keyHint: "Khóa bắt đầu bằng sk-, lấy ở platform.openai.com",
                     fixedURL: false, publicModels: false, usageInStream: true),
        ProviderInfo(id: "gemini", label: "Google (Gemini)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                     apiProtocol: .openai, needsKey: true, defaultModel: "gemini-flash-latest", keyHint: "Khóa lấy ở aistudio.google.com",
                     fixedURL: false, publicModels: false, usageInStream: false),
        ProviderInfo(id: "commandcode", label: "Command Code (Provider API)", baseURL: "https://api.commandcode.ai/provider/v1",
                     apiProtocol: .openai, needsKey: true, defaultModel: "deepseek/deepseek-v4-flash",
                     keyHint: "Tạo khóa ở commandcode.ai/settings/keys", fixedURL: true, publicModels: true, usageInStream: false),
        ProviderInfo(id: "ollama", label: "Ollama (chạy trên máy)", baseURL: "http://127.0.0.1:11434/v1", apiProtocol: .openai,
                     needsKey: false, defaultModel: "", keyHint: "Ollama chạy cục bộ không cần khóa",
                     fixedURL: false, publicModels: true, usageInStream: true),
        ProviderInfo(id: "compatible", label: "Máy chủ tương thích OpenAI (LM Studio…)", baseURL: "", apiProtocol: .openai,
                     needsKey: false, defaultModel: "", keyHint: "Máy chủ cục bộ thường không cần khóa; máy chủ ngoài cần HTTPS",
                     fixedURL: false, publicModels: true, usageInStream: true),
    ]

    public static func find(_ id: String) -> ProviderInfo? { all.first { $0.id == id } }

    /// Tách mã model dạng `<nhà-cung-cấp>/<model>` (model có thể chứa dấu `/`).
    public static func split(_ full: String) -> (provider: ProviderInfo, model: String)? {
        guard let slash = full.firstIndex(of: "/"), let info = find(String(full[..<slash])) else { return nil }
        let model = String(full[full.index(after: slash)...])
        return model.isEmpty ? nil : (info, model)
    }

    /// Chỉ nhận HTTPS, hoặc HTTP tới chính máy này; không nhận địa chỉ có tên đăng nhập.
    public static func validateBaseURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else {
            throw PVTAError("Địa chỉ máy chủ không hợp lệ. Ví dụ: https://api.example.com/v1 hoặc http://localhost:11434/v1.")
        }
        let local = ["127.0.0.1", "localhost", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw PVTAError("Địa chỉ máy chủ cần dùng HTTPS (chỉ máy này mới được dùng HTTP) để khóa API không bị lộ trên đường truyền.")
        }
        return url
    }
}
