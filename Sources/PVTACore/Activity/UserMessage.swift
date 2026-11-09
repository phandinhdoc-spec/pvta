import Foundation

/// Đổi lỗi kỹ thuật thành thông báo tiếng Việt dễ hiểu với giáo viên. Không lộ khóa hay chi tiết hệ thống.
public enum UserMessage {
    public static let generic = "Đã xảy ra lỗi, vui lòng thử lại. Nếu lỗi lặp lại, hãy xuất nhật ký để báo lỗi."

    public static func text(for error: Error) -> String {
        if let e = error as? PVTAError { return Redactor.clean(e.message) }
        if let e = error as? ProviderError { return Redactor.clean(e.message) }
        if error is CancellationError { return "Tác vụ đã được dừng." }
        if let e = error as? URLError { return network(e.code) }
        if let e = error as? CocoaError { return file(e.code) }
        if error is DecodingError || error is EncodingError {
            return "Dữ liệu không đúng định dạng nên PVTA không đọc được."
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ENOSPC: return "Ổ đĩa đã đầy. Hãy giải phóng dung lượng rồi thử lại."
            case EACCES, EPERM: return "PVTA không có quyền truy cập vào tệp hoặc thư mục này."
            case ENOENT: return "Không tìm thấy tệp hoặc thư mục."
            case EEXIST: return "Đã có tệp hoặc thư mục trùng tên."
            default: break
            }
        }
        return generic
    }

    /// Lỗi trả về từ máy chủ AI theo mã HTTP.
    public static func text(forHTTPStatus status: Int) -> String {
        switch status {
        case 400: return "Máy chủ AI không chấp nhận yêu cầu. Hãy thử rút gọn nội dung hoặc đổi model."
        case 401, 403: return "Khóa API không đúng, đã hết hạn hoặc không có quyền dùng model này. Hãy kiểm tra lại khóa trong Cài đặt."
        case 404: return "Không tìm thấy model hoặc địa chỉ máy chủ. Hãy kiểm tra tên model và địa chỉ trong Cài đặt."
        case 408: return "Máy chủ AI phản hồi quá lâu. Hãy thử lại sau ít phút."
        case 413: return "Nội dung gửi đi quá dài. Hãy bớt tệp đính kèm hoặc rút gọn câu hỏi."
        case 429: return "Nhà cung cấp AI đang giới hạn lượt dùng hoặc đã hết hạn mức. Hãy chờ một lúc hoặc chọn nhà cung cấp khác."
        case 500...599: return "Dịch vụ AI đang gặp sự cố. Hãy thử lại sau ít phút."
        default: return "Máy chủ AI trả về lỗi (mã \(status)). Hãy thử lại sau."
        }
    }

    private static func network(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "Không có kết nối mạng. Hãy kiểm tra Wi-Fi hoặc cáp mạng rồi thử lại."
        case .timedOut:
            return "Máy chủ phản hồi quá lâu. Hãy thử lại sau ít phút."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "Không kết nối được tới máy chủ. Hãy kiểm tra mạng hoặc địa chỉ máy chủ."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "Không thiết lập được kết nối an toàn (HTTPS) nên PVTA dừng lại để bảo vệ dữ liệu của bạn."
        case .cancelled:
            return "Tác vụ đã được dừng."
        default:
            return "Lỗi mạng. Hãy kiểm tra kết nối rồi thử lại."
        }
    }

    private static func file(_ code: CocoaError.Code) -> String {
        switch code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return "Không tìm thấy tệp hoặc thư mục."
        case .fileReadNoPermission, .fileWriteNoPermission:
            return "PVTA không có quyền truy cập tệp này. Hãy cấp quyền trong Cài đặt hệ thống hoặc chọn nơi khác."
        case .fileWriteOutOfSpace:
            return "Ổ đĩa đã đầy. Hãy giải phóng dung lượng rồi thử lại."
        case .fileWriteFileExists:
            return "Đã có tệp trùng tên."
        default:
            return generic
        }
    }
}
