import Foundation

/// Lỗi gửi ra cho người dùng: thông báo tiếng Việt, không chứa khóa hay chi tiết kỹ thuật.
public struct PVTAError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
