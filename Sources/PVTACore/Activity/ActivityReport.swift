import Foundation

/// Báo cáo văn bản để gửi kèm khi báo lỗi. Chỉ có thông tin tác vụ, không có nội dung hội thoại, đã che khóa.
public enum ActivityReport {
    public static func render(_ items: [Activity], now: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let failed = items.filter { $0.state == .error }.count
        var lines = [
            "Báo cáo hoạt động PVTA",
            "PVTA \(PVTAInfo.version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Tạo lúc: \(time.string(from: now))",
            "Số tác vụ: \(items.count) (lỗi: \(failed))",
            "",
        ]
        for a in items {
            var head = "[\(time.string(from: a.startedAt))] \(label(a.state)) · \(a.kind)"
            if let m = a.model { head += " · model \(m)" }
            if let c = a.chatId { head += " · hội thoại \(c)" }
            if let end = a.endedAt { head += " · \(String(format: "%.1f", end.timeIntervalSince(a.startedAt))) giây" }
            lines.append(Redactor.clean(head))
            if let d = a.detail, !d.isEmpty { lines.append("    \(Redactor.clean(d))") }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ s: ActivityState) -> String {
        switch s {
        case .running: "Đang chạy"
        case .done: "Xong"
        case .error: "Lỗi"
        case .interrupted: "Bị ngắt"
        }
    }
}
