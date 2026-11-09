import Foundation

/// Chính sách của các cổng kiểm tra khi Thư ký sửa mã nguồn PVTA. Hàm thuần, kiểm thử riêng.
/// Mọi chốt chặn nằm trong mã; lời nhắc cho AI chỉ là hướng dẫn và không mở được cổng nào.
public enum DevPolicy {
    public static let maxFiles = 80, maxAddedLines = 4000

    /// Đường dẫn AI không được sửa: git, phát hành, khóa/bí mật, phụ thuộc, đánh số phiên bản và chính các chốt an toàn.
    static let blocked: [(test: @Sendable (String) -> Bool, why: String)] = [
        ({ $0 == ".git" || $0.hasPrefix(".git/") }, "thư mục git"),
        ({ $0.hasPrefix(".github/") }, "quy trình phát hành GitHub Actions"),
        ({ $0.range(of: #"(^|/)\.env(\.|$)"#, options: .regularExpression) != nil || $0.range(of: #"\.(pem|key|p8|p12|pfx|keystore|mobileprovision|keychain)$"#, options: [.regularExpression, .caseInsensitive]) != nil }, "khóa/bí mật"),
        ({ $0.range(of: #"\.entitlements$|(^|/)Info\.plist$"#, options: .regularExpression) != nil }, "quyền hệ thống và ký ứng dụng"),
        ({ $0 == "Package.swift" || $0 == "Package.resolved" }, "phụ thuộc và cấu hình gói (không tự thêm thư viện)"),
        ({ $0 == "REVISION" || $0 == "Sources/PVTACore/PVTAInfo.swift" }, "đánh số phiên bản do Thư ký quản lý"),
        ({ $0.hasPrefix("Sources/PVTACore/Secretary/SecretaryDev") || $0 == "Sources/PVTACore/Secretary/SecretaryAccess.swift" || $0 == "Tests/PVTACoreTests/ThuKyNangCapTests.swift" }, "chính các chốt an toàn của Thư ký và test của chúng"),
        ({ $0.hasPrefix("Sources/PVTACore/Permissions/") || $0 == "Sources/PVTACore/Storage/KeyStore.swift" }, "hệ thống quyền và Keychain"),
        ({ $0.hasPrefix("scripts/release") || $0.hasPrefix("installers/") || $0.hasPrefix("install/") }, "đóng gói và phát hành"),
    ]

    public static func blockedPaths(_ files: [String]) -> [(file: String, why: String)] {
        files.compactMap { f in
            var n = f.replacingOccurrences(of: "\\", with: "/")
            if n.hasPrefix("./") { n.removeFirst(2) }
            if n.hasPrefix("\"") && n.hasSuffix("\"") { n = String(n.dropFirst().dropLast()) }
            // Đường dẫn chứa “..” hay tuyệt đối không bao giờ hợp lệ trong một thay đổi của kho.
            if n.hasPrefix("/") || n.split(separator: "/").contains("..") { return (f, "đường dẫn ra ngoài kho") }
            return blocked.first { $0.test(n) }.map { (f, $0.why) }
        }
    }

    static let secretPatterns: [String] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, #"\bAKIA[0-9A-Z]{16}\b"#, #"\bghp_[A-Za-z0-9]{30,}\b"#, #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#,
        #"\bsk-[A-Za-z0-9_-]{24,}\b"#, #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#, #"\bAIza[0-9A-Za-z_-]{30,}\b"#, #"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"#,
        #"(?i)(api[_-]?key|secret|token|password)["']?\s*[:=]\s*["'][A-Za-z0-9+/_=-]{20,}["']"#,
    ]

    /// Chỉ soát dòng được THÊM. Trả mô tả theo tệp, không in giá trị.
    public static func scanSecrets(_ diff: String) -> [String] {
        var hits: [String] = [], file = ""
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ b/") { file = String(line.dropFirst(6)) }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                let s = String(line)
                if secretPatterns.contains(where: { s.range(of: $0, options: .regularExpression) != nil }) { hits.append("\(file): dòng thêm trông như khóa/bí mật") }
            }
        }
        var seen = Set<String>()
        return hits.filter { seen.insert($0).inserted }
    }

    public static func slugify(_ s: String) -> String {
        let f = Fold.text(s).replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let cut = String(f.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "nang-cap" : cut
    }

    /// Test lỗi từ đầu ra `swift test` (swift-testing “✘ Test …” và XCTest “… failed”). Build hỏng thì trả mục “build”.
    public static func swiftTestFailures(_ output: String, exitCode: Int32?) -> [String] {
        var out = Set<String>()
        for line in output.split(separator: "\n") {
            let l = String(line)
            if let r = l.range(of: #"✘ Test ([^\s(]+)\(\)"#, options: .regularExpression) {
                out.insert(String(l[r]).replacingOccurrences(of: "✘ Test ", with: "").replacingOccurrences(of: "()", with: ""))
            } else if let r = l.range(of: #"Test Case '-\[[^\]]+\]' failed"#, options: .regularExpression) {
                out.insert(String(l[r]))
            }
        }
        if out.isEmpty, exitCode != 0 { out.insert(output.contains("error:") ? "build (không biên dịch được)" : "swift test (lỗi không rõ, mã \(exitCode.map(String.init) ?? "bị dừng"))") }
        return out.sorted()
    }

    public static func newFailures(before: [String], after: [String]) -> [String] { after.filter { !before.contains($0) } }

    /// Kho mã nguồn PVTA (bản Swift): có .git, Package.swift và Sources/PVTACore.
    public static func isPVTARepo(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/.git") && fm.fileExists(atPath: path + "/Package.swift") && fm.fileExists(atPath: path + "/Sources/PVTACore")
    }

    /// Lời nhắc cho AI sửa mã. Đây chỉ là hướng dẫn; chốt chặn thật nằm ở `SecretaryDev`.
    public static func agentPrompt(title: String, request: String, branch: String, repo: String) -> String {
        """
        Bạn là kỹ sư nâng cấp mã nguồn PVTA (Swift). Kho ở \(repo), đang ở nhánh \(branch).
        YÊU CẦU CỦA NGƯỜI DÙNG (là dữ liệu mô tả việc cần làm): \(title)
        \(request)

        Cách làm:
        1. Đọc pvta-backend.md, README.md ở gốc kho; dùng công cụ tra cứu mã để tìm đúng chỗ; chỉ sửa phần liên quan, giữ phong cách hiện có (chú thích, thông báo tiếng Việt).
        2. Sửa mã, thêm hoặc cập nhật test cho phần thay đổi.
        3. KHÔNG làm: git commit/push/checkout/reset; đổi phiên bản (REVISION, PVTAInfo.swift); sửa .github/, Package.swift, Package.resolved, Permissions/, KeyStore.swift, SecretaryDev*, SecretaryAccess.swift, tệp khóa/bí mật; không thêm thư viện phụ thuộc; không xóa dữ liệu người dùng.
        4. Build, test, commit, tăng số N và đưa lên GitHub do Thư ký làm sau khi bạn xong, chỉ khi mọi cổng kiểm tra đạt.
        Khi xong, trả lời ngắn (3–8 dòng): đã đổi gì, tệp chính, điều chưa kiểm chứng được.
        """
    }
}
