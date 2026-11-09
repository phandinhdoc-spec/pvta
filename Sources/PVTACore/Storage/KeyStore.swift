import Foundation
import Security

/// Nơi cất khóa API và token. Bản thật là Keychain; kiểm thử dùng bản trong bộ nhớ.
public protocol KeyStore: Sendable {
    func save(_ secret: String, provider: String) throws
    func read(provider: String) throws -> String?
    func delete(provider: String) throws
}

enum ProviderName {
    /// Tên nhà cung cấp chỉ gồm chữ thường, số, gạch ngang.
    static func validate(_ name: String) throws {
        guard !name.isEmpty, name.count <= 40,
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else { throw PVTAError("Tên nhà cung cấp chỉ gồm chữ thường không dấu, số và dấu gạch ngang (ví dụ: anthropic).") }
    }
}

/// Lưu trong Keychain của macOS. Khóa không bao giờ xuất hiện trong thông báo lỗi.
public struct KeychainKeyStore: KeyStore {
    public let service: String

    public init(service: String = "vn.pvta.api") { self.service = service }

    private func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    public func save(_ secret: String, provider: String) throws {
        try ProviderName.validate(provider)
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PVTAError("Không lưu được khóa vào Keychain (mã \(status)). Hãy mở khóa Keychain rồi thử lại.")
        }
    }

    public func read(provider: String) throws -> String? {
        try ProviderName.validate(provider)
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PVTAError("Không đọc được khóa từ Keychain (mã \(status)). Hãy mở khóa Keychain rồi thử lại.")
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(provider: String) throws {
        try ProviderName.validate(provider)
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PVTAError("Không xóa được khóa khỏi Keychain (mã \(status)).")
        }
    }
}

/// Đọc khóa từ stdin hoặc tệp để khóa không nằm trong lịch sử shell.
public enum SecretInput {
    public static func read(file: URL?, stdin: FileHandle = .standardInput) throws -> String {
        let data: Data
        if let file {
            guard let d = try? Data(contentsOf: file) else {
                throw PVTAError("Không đọc được tệp chứa khóa: \(file.path).")
            }
            data = d
        } else {
            data = stdin.readDataToEndOfFile()
        }
        let secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw PVTAError("Không có khóa nào được nhập.") }
        return secret
    }
}
