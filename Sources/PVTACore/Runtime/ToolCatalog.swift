import Foundation

/// Danh mục phương thức, sinh tự động từ `Builtin.methods()` mà không cần khởi động kho dữ liệu.
/// CLI dùng danh sách tĩnh này cho lệnh `pvta tools`; test so khớp với `Builtin.methods().keys`.
public enum ToolCatalog {

    /// Tất cả tên phương thức, theo thứ tự chữ cái.
    public static let methodNames: [String] = Builtin.methods().keys.sorted()

    /// Nhóm theo tiền tố trước dấu chấm đầu tiên. Ví dụ: `chat.send` → nhóm `chat`.
    public static let groups: [(name: String, methods: [String])] = {
        var dict: [String: [String]] = [:]
        for name in methodNames {
            let group = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
            dict[group, default: []].append(name)
        }
        return dict.sorted { $0.key < $1.key }.map { (name: $0.key, methods: $0.value) }
    }()

    /// Tên các nhóm, theo thứ tự chữ cái.
    public static let groupNames: [String] = groups.map(\.name)

    /// Lọc phương thức theo nhóm.
    public static func methods(inGroup group: String) -> [String] {
        groups.first { $0.name == group }?.methods ?? []
    }

    /// Xuất dạng JSON (dùng cho `--json`).
    public static func json(group: String? = nil) throws -> Data {
        struct Entry: Encodable {
            let method: String
            let group: String
        }
        let filtered: [String]
        if let group {
            filtered = methods(inGroup: group)
        } else {
            filtered = methodNames
        }
        let entries = filtered.map { name in
            let g = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
            return Entry(method: name, group: g)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(entries)
    }
}
