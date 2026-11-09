import os

/// Nhật ký chẩn đoán của hệ thống (Console.app, `log show --predicate 'subsystem == "vn.pvta"'`).
/// Chỉ ghi chữ đã che khóa. Nhật ký bền cho người dùng nằm ở bảng hoạt động, không phải ở đây.
enum Log {
    static let core = Logger(subsystem: "vn.pvta", category: "core")
}
