import Foundation

public enum ToolAccess: String, Codable, Sendable {
    /// Chỉ đọc, không đổi gì trên máy.
    case read
    /// Ghi, sửa, xóa, di chuyển tệp: phải được duyệt, hoặc tự chạy trong thư mục đã cấp ở mức Tự sửa.
    case write
    /// Chạy lệnh hoặc mã: luôn phải được duyệt.
    case run
    /// Truy cập mạng hoặc gửi dữ liệu ra ngoài: luôn phải được duyệt.
    case network
}

/// Một công cụ model được phép gọi trong vòng lặp hội thoại.
public struct ToolSpec: Sendable {
    public let name: String
    public let summary: String
    /// Mô tả tham số cho model, ví dụ `{"path": "đường dẫn tệp"}`.
    public let parameters: String
    public let access: ToolAccess
    /// Khai báo tác động của một lời gọi (tệp bị đụng tới, nội dung sẽ ghi) để kiểm phạm vi và cho người dùng xem trước khi duyệt.
    /// Công cụ ghi không khai báo thì luôn phải hỏi.
    public let plan: (@Sendable (JSONValue) async throws -> ActionPlan)?
    public let run: @Sendable (JSONValue) async throws -> String

    public init(name: String, summary: String, parameters: String = "{}", access: ToolAccess = .read,
                plan: (@Sendable (JSONValue) async throws -> ActionPlan)? = nil,
                run: @escaping @Sendable (JSONValue) async throws -> String) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.access = access
        self.plan = plan
        self.run = run
    }
}

public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: ToolSpec] = [:]

    public init() {}

    public func register(_ spec: ToolSpec) { lock.lock(); items[spec.name] = spec; lock.unlock() }
    public func spec(_ name: String) -> ToolSpec? { lock.lock(); defer { lock.unlock() }; return items[name] }
    public var all: [ToolSpec] { lock.lock(); defer { lock.unlock() }; return items.values.sorted { $0.name < $1.name } }
}

public enum ToolDecision: Sendable, Equatable {
    case allow
    case deny(String)
}

/// Quyết định có cho chạy một công cụ không (cơ chế thật là `PermissionPolicy`).
public protocol ToolPolicy: Sendable {
    /// Có thể chờ người dùng duyệt trước khi trả lời.
    func decide(_ tool: ToolSpec, args: JSONValue, chatId: String) async -> ToolDecision
}

/// Tách các khối gọi công cụ ra khỏi luồng chữ model trả về.
/// Khối có dạng một dòng ```pvta-tool, nội dung JSON, rồi dòng ``` đóng lại.
struct ToolFence {
    static let marker = "```pvta-tool"

    private var buffer = ""
    private var inFence = false
    /// Đang bỏ phần còn lại của dòng đóng khối (tới hết dòng).
    private var skipLine = false

    /// Nhận thêm một đoạn chữ; trả về phần chữ hiển thị được và các khối công cụ (JSON thô) vừa hoàn chỉnh.
    mutating func feed(_ chunk: String) -> (text: String, calls: [String]) {
        buffer += chunk
        var text = "", calls: [String] = []
        if skipLine {
            // Phần còn lại của dòng đóng khối: chỉ bỏ khoảng trắng và dấu xuống dòng, chữ khác được giữ.
            buffer = String(buffer.drop { $0 == " " || $0 == "\t" || $0 == "\r" })
            if buffer.isEmpty { return ("", []) }
            if buffer.first == "\n" { buffer.removeFirst() }
            skipLine = false
        }
        while true {
            if inFence {
                guard let bodyStart = buffer.firstIndex(of: "\n").map({ buffer.index(after: $0) }),
                      let close = buffer.range(of: "\n```", range: buffer.index(before: bodyStart)..<buffer.endIndex) else { break }
                calls.append(String(buffer[bodyStart..<close.lowerBound]))
                let rest = buffer[close.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\r" }
                if rest.isEmpty { buffer = ""; skipLine = true }                          // chưa biết ký tự kế tiếp
                else if rest.first == "\n" { buffer = String(rest.dropFirst()) }
                else { buffer = String(rest) }                                            // chữ liền sau khối đóng vẫn được giữ
                inFence = false
            } else if let open = buffer.range(of: Self.marker) {
                text += buffer[..<open.lowerBound]
                buffer = String(buffer[open.lowerBound...])
                inFence = true
            } else {
                // Giữ lại phần đuôi có thể là đầu của dấu mở khối.
                var keep = 0
                for n in stride(from: min(Self.marker.count - 1, buffer.count), through: 1, by: -1) where Self.marker.hasPrefix(buffer.suffix(n)) {
                    keep = n
                    break
                }
                text += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                break
            }
        }
        return (text, calls)
    }

    /// Hết luồng: khối chưa đóng thì giữ lại như chữ thường để không mất nội dung.
    mutating func finish() -> String {
        defer { buffer = ""; inFence = false; skipLine = false }
        return buffer
    }
}
