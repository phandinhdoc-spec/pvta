import Foundation

/// Nhận dạng ảnh theo nội dung (không tin đuôi tệp): PNG, JPEG, GIF, WebP.
enum ImageKind {
    static let maxBytes = 5 * 1024 * 1024
    static let maxTotal = 20 * 1024 * 1024
    static let maxPerTurn = 6

    static func detect(_ d: Data) -> (mime: String, ext: String)? {
        let b = [UInt8](d.prefix(12))
        if b.count >= 8, Array(b[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10] { return ("image/png", "png") }
        if b.count >= 3, b[0] == 255, b[1] == 216, b[2] == 255 { return ("image/jpeg", "jpg") }
        if b.count >= 6, let s = String(bytes: b[0..<6], encoding: .ascii), s == "GIF87a" || s == "GIF89a" { return ("image/gif", "gif") }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WEBP" { return ("image/webp", "webp") }
        return nil
    }

    static func extensionFor(mime: String) -> String? {
        ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][mime]
    }
}
