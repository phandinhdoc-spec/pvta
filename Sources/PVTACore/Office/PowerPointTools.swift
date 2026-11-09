import Foundation

/// Công cụ PowerPoint cho model: đọc, tạo mới, sửa trên bản sao. Tệp gốc không bao giờ bị ghi; kết quả là tệp mới cần người dùng duyệt.
extension FileService {
    private func requirePptx(_ path: String) throws {
        guard path.lowercased().hasSuffix(".pptx") else { throw PVTAError("Công cụ PowerPoint chỉ làm việc với tệp .pptx.") }
    }

    private func readPptx(_ raw: String, chatId: String?) async throws -> Data {
        try requirePptx(raw)
        let p = try await resolve(raw, chatId: chatId, write: false)
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw PVTAError("Không tìm thấy tệp “\((p as NSString).lastPathComponent)”.") }
        guard Int(st.st_size) <= Docx.maxInput, let d = FileManager.default.contents(atPath: p) else { throw PVTAError("Không đọc được tệp “\((p as NSString).lastPathComponent)” (tối đa 50 MB).") }
        return d
    }

    /// Nội dung slide và mã hình để chọn khi sửa.
    public func powerpointRead(path: String, chatId: String?) async throws -> String {
        try Pptx.read(try await readPptx(path, chatId: chatId))
    }

    private func writeNewPptx(_ data: Data, at raw: String, chatId: String?, detail: String) async throws -> FileChange {
        let p = try await resolve(raw, chatId: chatId, write: true)
        try requirePptx(p)
        try Self.atomicWrite(data, to: p, exclusive: true)
        let c = FileChange(id: UUID().uuidString, chatId: chatId, kind: "create", path: p, original: nil, backup: nil, trashPath: nil,
                           beforeHash: nil, afterHash: FileHash.of(data), detail: detail, createdAt: Date(), undone: false)
        try await store.recordChange(c)
        return c
    }

    public func powerpointCreate(path: String, subject: String?, slides: [JSONValue], chatId: String?) async throws -> (change: FileChange, report: [String]) {
        let r = (data: try Pptx.create(slides: slides, subject: subject), report: [String]())
        return (try await writeNewPptx(r.data, at: path, chatId: chatId, detail: "Tạo bộ trình chiếu PowerPoint"), r.report)
    }

    private func copyNamePptx(of source: String) -> String {
        let dir = (source as NSString).deletingLastPathComponent, base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        var n = 1, candidate = "\(dir)/\(base) (đã sửa).pptx"
        while FileManager.default.fileExists(atPath: candidate) { n += 1; candidate = "\(dir)/\(base) (đã sửa \(n)).pptx" }
        return candidate
    }

    private func targetPathPptx(_ raw: String, chatId: String?) async throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") || p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        guard let chatId, let dir = try await outputDirectory(chatId: chatId) else {
            throw PVTAError("Đường dẫn tương đối cần thư mục kết quả của hội thoại. Hãy dùng đường dẫn tuyệt đối trong thư mục đã cấp.")
        }
        return dir + "/" + p
    }

    public func powerpointEdit(path: String, output: String?, ops: [JSONValue], chatId: String?) async throws -> (change: FileChange, report: [String]) {
        let src = try await resolve(path, chatId: chatId, write: false)
        let dest: String
        if let output { dest = try await targetPathPptx(output, chatId: chatId) } else { dest = copyNamePptx(of: src) }
        guard PathGuard.canonical(dest) != PathGuard.canonical(src) else { throw PVTAError("PVTA chỉ sửa trên bản sao, không ghi đè tệp gốc. Hãy chọn tên khác cho bản sửa.") }
        let r = (data: try Pptx.edit(try await readPptx(path, chatId: chatId), ops: ops), report: [String]())
        return (try await writeNewPptx(r.data, at: dest, chatId: chatId, detail: "Bản sửa của " + (src as NSString).lastPathComponent), r.report)
    }

    var powerpointToolSpecs: [ToolSpec] {
        @Sendable func str(_ a: JSONValue, _ k: String) throws -> String {
            guard let s = a[k]?.string, !s.isEmpty else { throw PVTAError("Thiếu tham số " + k) }
            return s
        }
        @Sendable func list(_ a: JSONValue, _ k: String) throws -> [JSONValue] {
            guard case .array(let items)? = a[k], !items.isEmpty else { throw PVTAError("Thiếu danh sách " + k) }
            return items
        }
        return [
            ToolSpec(name: "powerpoint_read", summary: "Đọc slide và mã hình trong PowerPoint.", parameters: #"{"path":"tệp .pptx"}"#) { [self] a in
                try await powerpointRead(path: str(a, "path"), chatId: a["chatId"]?.string)
            },
            ToolSpec(name: "powerpoint_create", summary: "Tạo PowerPoint 16:9 theo môn học, có duyệt và hoàn tác.", parameters: #"{"path":"tệp .pptx mới","subject":"Toán, Ngữ văn, Lịch sử, Sinh học, Khoa học tự nhiên, Địa lí","slides":[{"layout":"title|content|twoColumns","title":"Tiêu đề","text":"Nội dung","left":"Cột trái","right":"Cột phải"}]}"#,
                     access: .write, plan: { [self] a in
                let path = try await targetPathPptx(str(a, "path"), chatId: a["chatId"]?.string)
                _ = try Pptx.create(slides: list(a, "slides"), subject: a["subject"]?.string)
                return ActionPlan(kind: .write, summary: "Tạo PowerPoint", preview: path, paths: [path])
            }) { [self] a in
                let result = try await powerpointCreate(path: str(a, "path"), subject: a["subject"]?.string, slides: list(a, "slides"), chatId: a["chatId"]?.string)
                return "Đã tạo " + result.change.path + " (mã hoàn tác " + result.change.id + ")."
            },
            ToolSpec(name: "powerpoint_edit", summary: "Sửa chữ, phông, màu hoặc vị trí hình trên bản sao PowerPoint. Slide bắt đầu từ 1; mã hình lấy từ powerpoint.read.", parameters: #"{"path":"tệp gốc","output":"bản sao mới (tùy chọn)","ops":[{"op":"text|style|move","slide":1,"shape":2,"text":"Chữ mới","font":"Arial","color":"234E9B","x":2,"y":3}]}"#,
                     access: .write, plan: { [self] a in
                let src = try await targetPathPptx(str(a, "path"), chatId: a["chatId"]?.string)
                let dest: String
                if let output = a["output"]?.string { dest = try await targetPathPptx(output, chatId: a["chatId"]?.string) }
                else { dest = copyNamePptx(of: src) }
                _ = try list(a, "ops")
                return ActionPlan(kind: .write, summary: "Tạo bản sửa PowerPoint", preview: "Gốc: " + src + "\nBản sửa: " + dest, paths: [dest])
            }) { [self] a in
                let result = try await powerpointEdit(path: str(a, "path"), output: a["output"]?.string, ops: list(a, "ops"), chatId: a["chatId"]?.string)
                return "Đã tạo " + result.change.path + " (mã hoàn tác " + result.change.id + ")."
            }
        ]
    }
}
