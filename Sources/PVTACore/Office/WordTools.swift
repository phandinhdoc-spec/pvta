import Foundation

/// Công cụ Word cho model: đọc, tạo mới, sửa trên bản sao. Tệp gốc không bao giờ bị ghi; kết quả luôn là một tệp mới cần người dùng duyệt.
extension FileService {
    private func absoluteWord(_ raw: String, chatId: String?) async throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { throw PVTAError("Thiếu đường dẫn.") }
        if p.hasPrefix("/") || p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        guard let chatId, let dir = try await outputDirectory(chatId: chatId) else {
            throw PVTAError("Đường dẫn tương đối cần thư mục kết quả của hội thoại. Hãy dùng đường dẫn tuyệt đối trong thư mục đã cấp.")
        }
        return dir + "/" + p
    }

    private func readBinary(_ raw: String, chatId: String?, limit: Int) async throws -> Data {
        let p = try await resolve(raw, chatId: chatId, write: false)
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw PVTAError("Không tìm thấy tệp “\((p as NSString).lastPathComponent)”.") }
        guard Int(st.st_size) <= limit else { throw PVTAError("Tệp “\((p as NSString).lastPathComponent)” quá lớn (tối đa \(limit / 1_048_576) MB).") }
        guard let d = FileManager.default.contents(atPath: p) else { throw PVTAError("Không đọc được tệp “\((p as NSString).lastPathComponent)”.") }
        return d
    }

    private func requireDocx(_ path: String) throws {
        guard path.lowercased().hasSuffix(".docx") else { throw PVTAError("Công cụ Word chỉ làm việc với tệp .docx (tệp .doc cũ hãy lưu lại thành .docx trong Word trước).") }
    }

    /// Mục lục nội dung có số khối của một tệp Word.
    public func wordRead(path: String, chatId: String?) async throws -> String {
        try requireDocx(path)
        return try Docx.outline(try await readBinary(path, chatId: chatId, limit: Docx.maxInput))
    }

    private func images(chatId: String?) -> Docx.ImageLoader {
        { [self] p in try await readBinary(p, chatId: chatId, limit: ImageKind.maxBytes) }
    }

    /// Ghi tệp mới (không ghi đè) và lưu vào nhật ký thay đổi để hoàn tác.
    private func createBinary(_ data: Data, at raw: String, chatId: String?, detail: String) async throws -> FileChange {
        let p = try await resolve(raw, chatId: chatId, write: true)
        try requireDocx(p)
        try Self.atomicWrite(data, to: p, exclusive: true)
        let c = FileChange(id: UUID().uuidString, chatId: chatId, kind: "create", path: p, original: nil, backup: nil, trashPath: nil,
                           beforeHash: nil, afterHash: FileHash.of(data), detail: detail, createdAt: Date(), undone: false)
        try await store.recordChange(c)
        return c
    }

    public func wordCreate(path: String, title: String?, blocks: [JSONValue], chatId: String?) async throws -> FileChange {
        let data = try await Docx.create(title: title, blocks: blocks, images: images(chatId: chatId))
        return try await createBinary(data, at: path, chatId: chatId, detail: "Tạo tài liệu Word")
    }

    /// Tên bản sao khi người dùng không chọn: “<tên> (đã sửa).docx”, thêm số nếu đã có.
    private func copyName(of source: String) -> String {
        let dir = (source as NSString).deletingLastPathComponent, base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        var n = 1, candidate = "\(dir)/\(base) (đã sửa).docx"
        while FileManager.default.fileExists(atPath: candidate) { n += 1; candidate = "\(dir)/\(base) (đã sửa \(n)).docx" }
        return candidate
    }

    /// Sửa trên bản sao: đọc tệp gốc, áp dụng thao tác, ghi ra tệp mới. Trả về đường dẫn bản sao và báo cáo từng thao tác.
    public func wordEdit(path: String, output: String?, ops: [JSONValue], chatId: String?) async throws -> (change: FileChange, report: [String]) {
        try requireDocx(path)
        let src = try await resolve(path, chatId: chatId, write: false)
        let dest: String
        if let output { dest = try await absoluteWord(output, chatId: chatId) } else { dest = copyName(of: src) }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: dest)) == nil else { throw PVTAError("Tệp đích là liên kết nên không ghi.") }
        guard PathGuard.canonical(dest) != PathGuard.canonical(src) else { throw PVTAError("PVTA chỉ sửa trên bản sao, không ghi đè tệp gốc. Hãy chọn tên khác cho bản sửa.") }
        let source = try await readBinary(path, chatId: chatId, limit: Docx.maxInput)
        let result = try await Docx.edit(source, ops: ops, images: images(chatId: chatId))
        let c = try await createBinary(result.data, at: dest, chatId: chatId, detail: "Bản sửa của " + (src as NSString).lastPathComponent)
        return (c, result.report)
    }

    var wordToolSpecs: [ToolSpec] {
        @Sendable func str(_ a: JSONValue, _ k: String) throws -> String {
            guard let s = a[k]?.string, !s.isEmpty else { throw PVTAError("Thiếu tham số \"\(k)\".") }
            return s
        }
        @Sendable func list(_ v: JSONValue?, _ name: String) throws -> [JSONValue] {
            guard case .array(let a)? = v, !a.isEmpty else { throw PVTAError("Thiếu danh sách \"\(name)\".") }
            return a
        }
        return [
            ToolSpec(name: "word_read", summary: "Đọc tệp Word (.docx): trả về từng khối có số thứ tự (đoạn, tiêu đề, bảng, công thức) để dùng với word_edit.",
                     parameters: #"{"path": "tệp .docx"}"#) { [self] a in try await wordRead(path: str(a, "path"), chatId: a["chatId"]?.string) },
            ToolSpec(name: "word_create", summary: "Tạo tài liệu Word mới. Cần người dùng duyệt; không ghi đè tệp có sẵn. Chữ thuần, không dùng Markdown; công thức viết trong $...$ (LaTeX, hóa học dùng \\ce{H2O}).",
                     parameters: #"{"path": "tệp .docx mới", "title": "tiêu đề (tùy chọn)", "blocks": "[{\"type\":\"heading\",\"text\":\"..\",\"level\":1}, {\"type\":\"paragraph\",\"text\":\"Cho $x^2+1$\",\"align\":\"justify\"}, {\"type\":\"list\",\"items\":[\"..\"],\"ordered\":false}, {\"type\":\"table\",\"rows\":[[\"Cột 1\",\"Cột 2\"],[\"..\",\"..\"]]}, {\"type\":\"equation\",\"latex\":\"\\\\frac{a}{b}\"}, {\"type\":\"image\",\"path\":\"ảnh.png\",\"widthCm\":10}, {\"type\":\"page_break\"}]"}"#,
                     access: .write, plan: { [self] a in
                         let p = try await absoluteWord(str(a, "path"), chatId: a["chatId"]?.string)
                         let bs = try list(a["blocks"], "blocks")
                         let kinds = Dictionary(grouping: bs.compactMap { $0["type"]?.string }, by: { $0 }).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
                         return ActionPlan(kind: .write, summary: "Tạo tài liệu Word " + p, preview: (a["title"]?.string.map { "Tiêu đề: \($0)\n" } ?? "") + "Gồm: " + kinds, paths: [p])
                     }) { [self] a in
                let c = try await wordCreate(path: str(a, "path"), title: a["title"]?.string, blocks: list(a["blocks"], "blocks"), chatId: a["chatId"]?.string)
                return "Đã tạo \(c.path) (mã hoàn tác \(c.id))."
            },
            ToolSpec(name: "word_edit", summary: "Sửa tệp Word trên BẢN SAO (tệp gốc không đổi). Số khối lấy từ word_read, luôn là số của tài liệu gốc. Cần người dùng duyệt.",
                     parameters: #"{"path": "tệp .docx gốc", "output": "bản sao mới (tùy chọn, mặc định '<tên> (đã sửa).docx')", "ops": "[{\"op\":\"replace\",\"find\":\"cũ\",\"replace\":\"mới\",\"all\":false}, {\"op\":\"setText\",\"index\":3,\"text\":\"..\"}, {\"op\":\"insertParagraph\",\"after\":3,\"text\":\"..\",\"heading\":2}, {\"op\":\"insertTable\",\"after\":3,\"rows\":[[\"..\"]]}, {\"op\":\"insertEquation\",\"after\":3,\"latex\":\"x^2\"}, {\"op\":\"insertImage\",\"after\":3,\"path\":\"a.png\",\"widthCm\":10}, {\"op\":\"delete\",\"index\":5}, {\"op\":\"format\",\"index\":3,\"bold\":true,\"size\":14,\"font\":\"Arial\",\"align\":\"center\"}]; after có thể là số, \"start\" hoặc \"end\""}"#,
                     access: .write, plan: { [self] a in
                         let chat = a["chatId"]?.string
                         let src = try await absoluteWord(str(a, "path"), chatId: chat)
                         let ops = try list(a["ops"], "ops")
                         let dest: String
                         if let o = a["output"]?.string { dest = try await absoluteWord(o, chatId: chat) } else { dest = copyName(of: src) }
                         var preview = "Gốc (không đổi): \(src)\n"
                         if await permissions.check(src, .read).denied == nil, let data = try? await readBinary(src, chatId: chat, limit: Docx.maxInput) {
                             let r = try await Docx.edit(data, ops: ops, images: images(chatId: chat))   // chạy thử để báo lỗi trước khi hỏi duyệt
                             preview += r.report.joined(separator: "\n")
                         }
                         return ActionPlan(kind: .write, summary: "Tạo bản sửa " + dest, preview: preview, paths: [dest])
                     }) { [self] a in
                let r = try await wordEdit(path: str(a, "path"), output: a["output"]?.string, ops: list(a["ops"], "ops"), chatId: a["chatId"]?.string)
                return "Đã tạo bản sửa \(r.change.path) (mã hoàn tác \(r.change.id)); tệp gốc không đổi.\n" + r.report.joined(separator: "\n")
            },
        ]
    }
}
