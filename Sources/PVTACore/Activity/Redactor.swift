import Foundation

/// Che khóa API, token, mật khẩu trong chữ trước khi ghi vào nhật ký hoặc gửi ra thông báo.
public enum Redactor {
    public static let mask = "[đã ẩn]"

    private static let patterns: [(String, String)] = [
        // "api_key: xxx", "token=xxx", "Authorization: Bearer xxx"...
        (#"(?i)\b(authorization|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd)\b(["']?\s*[:=]\s*["']?)(?:Bearer\s+)?[^\s"',;&]+"#, "$1$2\(mask)"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer \(mask)"),
        // Tham số trên địa chỉ web.
        (#"(?i)([?&](?:key|api_key|apikey|access_token|token)=)[^&\s]+"#, "$1\(mask)"),
        // Khóa có dạng nhận ra được.
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, mask),
        (#"\bAIza[0-9A-Za-z_-]{20,}"#, mask),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, mask),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, mask),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, mask),
        (#"\bya29\.[A-Za-z0-9._-]{20,}"#, mask),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#, mask),
    ]

    public static func clean(_ text: String) -> String {
        var out = text
        for (pattern, template) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
