import Foundation

/// Phương thức nhập dữ liệu từ MySoft (phần mềm cũ).
/// Chỉ đọc dữ liệu nguồn, không sửa, không xóa gì.
extension Builtin {
    static func legacyMethods() -> [(String, Core.Handler)] {
        return [
            /// Nhập dữ liệu từ MySoft vào PVTA.
            /// Tham số: `path` (tùy chọn) — đường dẫn thư mục, mặc định `~/.phananh-office`.
            ("legacy.import", { ctx in
                let path = ctx.params["path"]?.string ?? "~/.phananh-office"
                let skillsDir = await ctx.core.skills.store.skillsDirectory
                let importer = MySoftImporter()
                let result = try await importer.run(
                    sourcePath: path,
                    store: ctx.core.store,
                    skillsDir: skillsDir
                )
                ctx.core.broadcast("data.changed", ["method": .string("legacy.import")])
                return try JSONValue(encoding: result)
            }),

            /// Trạng thái nhập: đã nhập chưa, nhập lần cuối lúc nào.
            ("legacy.status", { ctx in
                let at = try await ctx.core.store.setting("legacy.import.at")
                return ["done": .bool(at != nil), "importedAt": at.map { .string($0) } ?? .null]
            }),
        ]
    }
}
