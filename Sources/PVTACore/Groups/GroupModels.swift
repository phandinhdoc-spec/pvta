import Foundation
import CryptoKit

public enum GroupKind: String, Codable, Sendable { case chuyenMon = "chuyen-mon", vaiTro = "vai-tro", dangDoanThe = "dang-doan-the", congCu = "cong-cu"

    var label: String {
        switch self { case .chuyenMon: return "Chuyên môn"; case .vaiTro: return "Vai trò"; case .dangDoanThe: return "Đảng – Đoàn thể"; case .congCu: return "Công cụ" }
    }
}

/// Mức tin cậy: chính thức (đi kèm PVTA) > đồng nghiệp chia sẻ (gói nhập vào) > cá nhân.
public enum GroupTier: String, Codable, Sendable { case chinhThuc = "chinh-thuc", dongNghiep = "dong-nghiep", caNhan = "ca-nhan" }

public struct GroupManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: GroupKind
    public var version: String
    public var author: String
    public var tier: GroupTier
    public var description: String?
    public var skills: [String]
    /// Tên miền tin cậy để theo dõi và tải văn bản (nhiệm vụ 22).
    public var domains: [String]
    public var feeds: [String]?
    public var keywords: [String]
    public var related: [String]
}

public struct QuickPack: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var groups: [String]
}

enum GroupCatalog {
    static let eduDomains = ["moet.gov.vn", "chinhphu.vn", "vbpl.vn", "thuvienphapluat.vn"]

    private static func make(_ kind: GroupKind, _ seeds: [(String, String, [String])]) -> [GroupManifest] {
        seeds.map { GroupManifest(id: $0.0, name: $0.1, kind: kind, version: "1.0.0", author: "PVTA", tier: .chinhThuc, description: nil, skills: [],
                                  domains: kind == .congCu ? [] : eduDomains, feeds: nil, keywords: $0.2, related: []) }
    }

    static let builtin: [GroupManifest] =
        make(.chuyenMon, [
            ("toan", "Toán", ["toán", "đại số", "hình học", "phương trình", "hàm số"]),
            ("ly", "Vật lí", ["vật lí", "lực", "điện", "quang", "nhiệt", "chuyển động"]),
            ("hoa", "Hóa học", ["hóa", "phản ứng", "dung dịch", "nguyên tố", "mol"]),
            ("sinh", "Sinh học", ["sinh học", "tế bào", "di truyền", "hệ sinh thái"]),
            ("khtn", "Khoa học tự nhiên", ["khoa học tự nhiên", "khtn", "thí nghiệm", "năng lực khoa học"]),
            ("gdcd", "Giáo dục công dân", ["giáo dục công dân", "gdcd", "pháp luật", "đạo đức"]),
            ("tin-hoc", "Tin học", ["tin học", "thuật toán", "lập trình", "máy tính"]),
        ]) + make(.vaiTro, [
            ("giao-vien", "Giáo viên", ["giáo viên", "giáo dục", "giảng dạy", "giáo án", "kiểm tra đánh giá", "chuyên đề"]),
            ("to-truong", "Tổ trưởng / Tổ phó chuyên môn", ["tổ chuyên môn", "kế hoạch giáo dục", "dự giờ", "sinh hoạt chuyên môn"]),
            ("hieu-pho", "Hiệu phó", ["phó hiệu trưởng", "chuyên môn", "thời khóa biểu", "kiểm tra nội bộ"]),
            ("hieu-truong", "Hiệu trưởng", ["hiệu trưởng", "quản lý nhà trường", "quyết định", "kế hoạch năm học"]),
            ("van-thu", "Văn thư", ["văn thư", "công văn", "thể thức", "lưu trữ", "số hiệu"]),
            ("ke-toan", "Kế toán", ["kế toán", "dự toán", "thanh toán", "quyết toán", "tài chính"]),
            ("thu-vien", "Thư viện", ["thư viện", "sách", "học liệu"]),
            ("thiet-bi", "Thiết bị", ["thiết bị dạy học", "phòng thí nghiệm", "kiểm kê"]),
        ]) + make(.dangDoanThe, [
            ("dang-vien", "Đảng viên", ["đảng viên", "chi bộ", "nghị quyết", "sinh hoạt đảng"]),
            ("bi-thu", "Bí thư chi bộ", ["bí thư", "chi bộ", "đảng ủy", "nghị quyết"]),
            ("pho-bi-thu", "Phó bí thư", ["phó bí thư", "chi bộ"]),
            ("cong-doan", "Chủ tịch công đoàn", ["công đoàn", "đoàn viên công đoàn", "nghị quyết công đoàn"]),
            ("doan-doi", "Đoàn – Đội", ["đoàn thanh niên", "đội thiếu niên", "sao nhi đồng", "phong trào"]),
        ]) + make(.congCu, [
            ("python", "Python", ["python", "pandas", "tính toán", "biểu đồ"]),
            ("arduino", "Arduino", ["arduino", "cảm biến", "vi điều khiển", "mạch"]),
            ("am-thanh", "Âm thanh", ["âm thanh", "ghi âm", "lọc nhiễu", "audio"]),
            ("typst", "Typst", ["typst", "sắp chữ", "đề thi"]),
            ("pdf", "PDF", ["pdf", "văn bản scan", "tô sáng", "ghi chú"]),
            ("word", "Word", ["word", "soạn thảo", "định dạng văn bản"]),
            ("excel", "Excel", ["excel", "bảng tính", "công thức", "điểm số"]),
            ("powerpoint", "PowerPoint", ["powerpoint", "bài giảng điện tử", "slide"]),
        ])

    /// Bấm một lần là chọn sẵn các nhóm phù hợp; thầy cô chỉnh lại được.
    static let quickPacks: [QuickPack] = [
        QuickPack(id: "gv-khtn", name: "Giáo viên THCS KHTN", groups: ["khtn", "giao-vien", "pdf", "word", "excel", "powerpoint"]),
        QuickPack(id: "to-pho", name: "Tổ phó chuyên môn", groups: ["khtn", "giao-vien", "to-truong", "pdf", "word", "excel", "powerpoint"]),
        QuickPack(id: "hieu-truong", name: "Hiệu trưởng", groups: ["hieu-truong", "van-thu", "pdf", "word", "excel", "powerpoint"]),
        QuickPack(id: "van-thu", name: "Văn thư", groups: ["van-thu", "pdf", "word", "excel"]),
        QuickPack(id: "ke-toan", name: "Kế toán", groups: ["ke-toan", "pdf", "excel", "word"]),
    ]
}

// MARK: Trạng thái nhóm (lưu trong bảng cài đặt)

public struct GroupConfiguration: Codable, Sendable, Equatable {
    public var enabled: [String]?
    public var pack: String?
    public var offline: Bool
    public var alertsOff: [String]
    public var briefing: Bool
}

public struct NamedGroupProfile: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var config: GroupConfiguration
}

public struct DiscoveryProfile: Codable, Sendable, Equatable {
    public var province = "", locality = "", school = "", level = "", subjects = "", keywords = ""

    public init(province: String = "", locality: String = "", school: String = "", level: String = "", subjects: String = "", keywords: String = "") {
        self.province = province; self.locality = locality; self.school = school; self.level = level; self.subjects = subjects; self.keywords = keywords
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? "" }
        self.init(province: try s(.province), locality: try s(.locality), school: try s(.school), level: try s(.level), subjects: try s(.subjects), keywords: try s(.keywords))
    }
}

public struct DiscoverySource: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    public var groups: [String]
    public var kind: String           // "page" | "feed"
    public var lastChecked: Double?
    public var lastError: String?
    public var found: Int?
}

public struct DiscoveryReport: Codable, Sendable, Equatable {
    public var group: String
    public var at: Double
    public var added: Int
    public var checked: Int
    public var skipped: String?
    public var errors: [String]
}

struct GroupsState: Codable, Equatable {
    var enabled: [String]?
    var pack: String?
    var offline = false
    var alertsOff: [String] = []
    var briefingEnabled = true
    var briefingShownDay: String?
    var briefingDismissedDay: String?
    var profiles: [NamedGroupProfile] = []
    var undo: UndoSlot?
    var profile = DiscoveryProfile()
    var sources: [DiscoverySource] = []
    var lastRun: [String: Double] = [:]
    var reports: [DiscoveryReport] = []
    /// Cảnh báo văn bản đã tắt (mã “nhóm:số hiệu”).
    var muted: [String] = []
    /// Số hiệu → ngày đã nhắc (mỗi cảnh báo nhắc tối đa một lần mỗi ngày).
    var shown: [String: String] = [:]

    struct UndoSlot: Codable, Equatable { var config: GroupConfiguration; var applied: String }

    init() {}

    /// Đọc dung sai: thiếu trường (bản lưu cũ hơn) thì dùng giá trị mặc định, không làm mất các trường còn lại.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent([String].self, forKey: .enabled)
        pack = try c.decodeIfPresent(String.self, forKey: .pack)
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
        alertsOff = try c.decodeIfPresent([String].self, forKey: .alertsOff) ?? []
        briefingEnabled = try c.decodeIfPresent(Bool.self, forKey: .briefingEnabled) ?? true
        briefingShownDay = try c.decodeIfPresent(String.self, forKey: .briefingShownDay)
        briefingDismissedDay = try c.decodeIfPresent(String.self, forKey: .briefingDismissedDay)
        profiles = try c.decodeIfPresent([NamedGroupProfile].self, forKey: .profiles) ?? []
        undo = try c.decodeIfPresent(UndoSlot.self, forKey: .undo)
        profile = try c.decodeIfPresent(DiscoveryProfile.self, forKey: .profile) ?? DiscoveryProfile()
        sources = try c.decodeIfPresent([DiscoverySource].self, forKey: .sources) ?? []
        lastRun = try c.decodeIfPresent([String: Double].self, forKey: .lastRun) ?? [:]
        reports = try c.decodeIfPresent([DiscoveryReport].self, forKey: .reports) ?? []
        muted = try c.decodeIfPresent([String].self, forKey: .muted) ?? []
        shown = try c.decodeIfPresent([String: String].self, forKey: .shown) ?? [:]
    }

    private enum Keys: String, CodingKey {
        case enabled, pack, offline, alertsOff, briefingEnabled, briefingShownDay, briefingDismissedDay, profiles, undo, profile, sources, lastRun, reports, muted, shown
    }

    var configuration: GroupConfiguration {
        GroupConfiguration(enabled: enabled, pack: pack, offline: offline, alertsOff: alertsOff, briefing: briefingEnabled)
    }
}

enum Fingerprint {
    static func of<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? enc.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
