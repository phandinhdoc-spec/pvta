import Foundation

/// Công cụ tệp cho model. Chỉ làm việc trong thư mục người dùng đã cấp; công cụ ghi khai báo tác động để người dùng xem và duyệt.
/// Đường dẫn tương đối tính từ thư mục kết quả của hội thoại.
extension FileService {
    private static func chatId(_ a: JSONValue) -> String? { a["chatId"]?.string }

    private static func str(_ a: JSONValue, _ k: String) throws -> String {
        guard let s = a[k]?.string, !s.isEmpty else { throw PVTAError("Thiếu tham số \"\(k)\".") }
        return s
    }

    /// Đường dẫn tuyệt đối để khai báo tác động (chưa kiểm phạm vi: bước duyệt sẽ kiểm và chặn nếu ngoài phạm vi).
    private func absolute(_ raw: String, chatId: String?) async throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") || p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        guard let chatId, let dir = try await outputDirectory(chatId: chatId) else {
            throw PVTAError("Đường dẫn tương đối cần thư mục kết quả của hội thoại. Hãy dùng đường dẫn tuyệt đối trong thư mục đã cấp.")
        }
        return dir + "/" + p
    }

    private func inScope(_ path: String) async -> Bool { await permissions.check(path, .write).denied == nil }

    var toolSpecs: [ToolSpec] {
        wordToolSpecs + excelToolSpecs + powerpointToolSpecs + [
            ToolSpec(name: "fs_list", summary: "Liệt kê tệp và thư mục trong một thư mục đã cấp quyền.",
                     parameters: #"{"path": "thư mục", "depth": "độ sâu 1–3 (mặc định 1)"}"#) { [self] a in
                let items = try await list(path: Self.str(a, "path"), chatId: Self.chatId(a), depth: max(1, min(3, Int(a["depth"]?.number ?? 1))))
                if items.isEmpty { return "(thư mục trống)" }
                return items.map { "\($0.kind == "dir" ? "[thư mục]" : $0.kind == "link" ? "[liên kết]" : "\($0.bytes) byte") \($0.path)" }.joined(separator: "\n")
            },
            ToolSpec(name: "fs_read", summary: "Đọc một đoạn nội dung tệp (văn bản, Word, Excel, PowerPoint, PDF) trong thư mục đã cấp quyền.",
                     parameters: #"{"path": "tệp", "start": "ký tự bắt đầu (mặc định 0)", "length": "số ký tự (mặc định 8000, tối đa 20000)"}"#) { [self] a in
                try await read(path: Self.str(a, "path"), chatId: Self.chatId(a), start: Int(a["start"]?.number ?? 0), length: a["length"]?.number.map { Int($0) })
            },
            ToolSpec(name: "fs_find", summary: "Tìm tệp theo tên và/hoặc theo nội dung (không phân biệt dấu) trong một thư mục đã cấp quyền.",
                     parameters: #"{"root": "thư mục", "name": "từ khóa trong tên tệp (tùy chọn)", "content": "từ khóa trong nội dung (tùy chọn)"}"#) { [self] a in
                let r = try await find(root: Self.str(a, "root"), chatId: Self.chatId(a), name: a["name"]?.string, content: a["content"]?.string)
                if r.hits.isEmpty { return "Không tìm thấy." + (r.note.map { " " + $0 } ?? "") }
                let lines: [String] = r.hits.map { hit in
                    guard let n = hit.line else { return hit.path }
                    return "\(hit.path):\(n): \(hit.text ?? "")"
                }
                return lines.joined(separator: "\n") + (r.note.map { "\n(\($0))" } ?? "")
            },
            ToolSpec(name: "fs_write", summary: "Tạo tệp văn bản mới hoặc ghi đè (cần overwrite=true; bản cũ được sao lưu để hoàn tác). Cần người dùng duyệt.",
                     parameters: #"{"path": "tệp", "content": "nội dung", "overwrite": "true để ghi đè tệp có sẵn"}"#, access: .write,
                     plan: { [self] a in
                         let p = try await absolute(Self.str(a, "path"), chatId: Self.chatId(a))
                         let exists = FileManager.default.fileExists(atPath: p)
                         return ActionPlan(kind: .write, summary: (exists ? "Ghi đè tệp " : "Tạo tệp mới ") + p, preview: a["content"]?.string ?? "", paths: [p])
                     }) { [self] a in
                let c = try await write(path: Self.str(a, "path"), content: a["content"]?.string ?? "", overwrite: a["overwrite"]?.bool ?? false, chatId: Self.chatId(a))
                return "Đã ghi \(c.path) (mã hoàn tác \(c.id))."
            },
            ToolSpec(name: "fs_edit", summary: "Sửa một phần tệp văn bản: thay đúng các đoạn nêu trong edits. Cần người dùng duyệt.",
                     parameters: #"{"path": "tệp", "edits": "[{\"find\": \"đoạn cũ\", \"replace\": \"đoạn mới\", \"all\": false}]"}"#, access: .write,
                     plan: { [self] a in
                         let p = try await absolute(Self.str(a, "path"), chatId: Self.chatId(a))
                         if !(await inScope(p)) { return ActionPlan(kind: .write, summary: "Sửa tệp " + p, paths: [p]) }
                         let r = try await previewEdit(path: p, edits: TextEdit.parse(a["edits"]), chatId: Self.chatId(a))
                         return ActionPlan(kind: .write, summary: "Sửa tệp " + r.path, preview: r.diff, paths: [r.path])
                     }) { [self] a in
                let c = try await edit(path: Self.str(a, "path"), edits: TextEdit.parse(a["edits"]), chatId: Self.chatId(a))
                return "Đã sửa \(c.path) (mã hoàn tác \(c.id))."
            },
            ToolSpec(name: "fs_move", summary: "Di chuyển hoặc đổi tên tệp/thư mục (không ghi đè). Cần người dùng duyệt.",
                     parameters: #"{"from": "nguồn", "to": "đích"}"#, access: .write,
                     plan: { [self] a in
                         let f = try await absolute(Self.str(a, "from"), chatId: Self.chatId(a)), t = try await absolute(Self.str(a, "to"), chatId: Self.chatId(a))
                         return ActionPlan(kind: .move, summary: "Di chuyển \(f) → \(t)", paths: [f, t])
                     }) { [self] a in
                let c = try await move(from: Self.str(a, "from"), to: Self.str(a, "to"), chatId: Self.chatId(a))
                return "Đã di chuyển tới \(c.path) (mã hoàn tác \(c.id))."
            },
            ToolSpec(name: "fs_trash", summary: "Chuyển tệp hoặc thư mục vào Thùng rác (không xóa hẳn). Cần người dùng duyệt.",
                     parameters: #"{"paths": ["tệp hoặc thư mục", "..."]}"#, access: .write,
                     plan: { [self] a in
                         guard case .array(let items)? = a["paths"], !items.isEmpty else { throw PVTAError("Thiếu danh sách đường dẫn (paths).") }
                         var ps: [String] = []
                         for i in items { ps.append(try await absolute(i.string ?? "", chatId: Self.chatId(a))) }
                         return ActionPlan(kind: .delete, summary: "Chuyển \(ps.count) mục vào Thùng rác", preview: ps.joined(separator: "\n"), paths: ps)
                     }) { [self] a in
                guard case .array(let items)? = a["paths"] else { throw PVTAError("Thiếu danh sách đường dẫn (paths).") }
                let cs = try await trash(paths: items.compactMap(\.string), chatId: Self.chatId(a))
                return "Đã chuyển \(cs.count) mục vào Thùng rác (mã hoàn tác: \(cs.map(\.id).joined(separator: ", ")))."
            },
        ]
    }
}
