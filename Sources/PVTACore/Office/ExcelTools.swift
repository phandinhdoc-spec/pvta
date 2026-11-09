import Foundation

/// Công cụ Excel cho model: đọc, tạo mới, sửa trên bản sao. Tệp gốc không bao giờ bị ghi; kết quả là tệp mới cần người dùng duyệt.
extension FileService {
    private func requireXlsx(_ path: String) throws {
        guard path.lowercased().hasSuffix(".xlsx") else { throw PVTAError("Công cụ Excel chỉ làm việc với tệp .xlsx (tệp .xls cũ hãy lưu lại thành .xlsx trong Excel trước).") }
    }

    private func readXlsx(_ raw: String, chatId: String?) async throws -> Data {
        try requireXlsx(raw)
        let p = try await resolve(raw, chatId: chatId, write: false)
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw PVTAError("Không tìm thấy tệp “\((p as NSString).lastPathComponent)”.") }
        guard Int(st.st_size) <= XlsxBook.maxInput, let d = FileManager.default.contents(atPath: p) else { throw PVTAError("Không đọc được tệp “\((p as NSString).lastPathComponent)” (tối đa 50 MB).") }
        return d
    }

    /// Nội dung các trang tính: giá trị, kèm công thức trong { }.
    public func excelRead(path: String, chatId: String?) async throws -> String {
        try XlsxBook(data: try await readXlsx(path, chatId: chatId)).describe()
    }

    private func writeNew(_ data: Data, at raw: String, chatId: String?, detail: String) async throws -> FileChange {
        let p = try await resolve(raw, chatId: chatId, write: true)
        try requireXlsx(p)
        try Self.atomicWrite(data, to: p, exclusive: true)
        let c = FileChange(id: UUID().uuidString, chatId: chatId, kind: "create", path: p, original: nil, backup: nil, trashPath: nil,
                           beforeHash: nil, afterHash: FileHash.of(data), detail: detail, createdAt: Date(), undone: false)
        try await store.recordChange(c)
        return c
    }

    public func excelCreate(path: String, title: String?, sheets: [JSONValue], chatId: String?) async throws -> (change: FileChange, report: [String]) {
        let r = try Xlsx.create(title: title, sheets: sheets)
        return (try await writeNew(r.data, at: path, chatId: chatId, detail: "Tạo sổ tính Excel"), r.report)
    }

    private func copyNameXlsx(of source: String) -> String {
        let dir = (source as NSString).deletingLastPathComponent, base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        var n = 1, candidate = "\(dir)/\(base) (đã sửa).xlsx"
        while FileManager.default.fileExists(atPath: candidate) { n += 1; candidate = "\(dir)/\(base) (đã sửa \(n)).xlsx" }
        return candidate
    }

    private func targetPath(_ raw: String, chatId: String?) async throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") || p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        guard let chatId, let dir = try await outputDirectory(chatId: chatId) else {
            throw PVTAError("Đường dẫn tương đối cần thư mục kết quả của hội thoại. Hãy dùng đường dẫn tuyệt đối trong thư mục đã cấp.")
        }
        return dir + "/" + p
    }

    public func excelEdit(path: String, output: String?, ops: [JSONValue], chatId: String?) async throws -> (change: FileChange, report: [String]) {
        let src = try await resolve(path, chatId: chatId, write: false)
        let dest: String
        if let output { dest = try await targetPath(output, chatId: chatId) } else { dest = copyNameXlsx(of: src) }
        guard PathGuard.canonical(dest) != PathGuard.canonical(src) else { throw PVTAError("PVTA chỉ sửa trên bản sao, không ghi đè tệp gốc. Hãy chọn tên khác cho bản sửa.") }
        let r = try Xlsx.edit(try await readXlsx(path, chatId: chatId), ops: ops)
        return (try await writeNew(r.data, at: dest, chatId: chatId, detail: "Bản sửa của " + (src as NSString).lastPathComponent), r.report)
    }

    var excelToolSpecs: [ToolSpec] {
        @Sendable func str(_ a: JSONValue, _ k: String) throws -> String {
            guard let s = a[k]?.string, !s.isEmpty else { throw PVTAError("Thiếu tham số \"\(k)\".") }
            return s
        }
        @Sendable func list(_ v: JSONValue?, _ name: String) throws -> [JSONValue] {
            guard case .array(let a)? = v, !a.isEmpty else { throw PVTAError("Thiếu danh sách \"\(name)\".") }
            return a
        }
        return [
            ToolSpec(name: "excel_read", summary: "Đọc tệp Excel (.xlsx): giá trị từng ô theo trang tính, ô có công thức hiện thêm {=công thức}. Dùng để kiểm tra số liệu trước khi sửa.",
                     parameters: #"{"path": "tệp .xlsx"}"#) { [self] a in try await excelRead(path: str(a, "path"), chatId: a["chatId"]?.string) },
            ToolSpec(name: "excel_create", summary: "Tạo sổ tính Excel mới. Cần người dùng duyệt; không ghi đè. Số liệu truyền dạng số thật (8.5), không dùng chuỗi có dấu chấm ngăn cách. Chuỗi bắt đầu bằng = là công thức. PVTA tính sẵn giá trị công thức và báo lỗi nếu có.",
                     parameters: #"{"path": "tệp .xlsx mới", "title": "tiêu đề (tùy chọn)", "sheets": "[{\"name\":\"Điểm 8A\",\"rows\":[[\"STT\",\"Họ tên\",\"Điểm\"],[1,\"An\",8.5]],\"formulas\":[{\"cell\":\"C4\",\"formula\":\"=AVERAGE(C2:C3)\"}],\"merges\":[\"A6:C6\"],\"charts\":[{\"type\":\"bar\",\"title\":\"Điểm\",\"categories\":\"B2:B3\",\"series\":[{\"name\":\"Điểm\",\"values\":\"C2:C3\"}],\"anchor\":\"F2\"}]}]; hàng đầu là tiêu đề (tự tô, đóng băng, bật lọc)"}"#,
                     access: .write, plan: { [self] a in
                         let p = try await targetPath(str(a, "path"), chatId: a["chatId"]?.string)
                         let sheets = try list(a["sheets"], "sheets")
                         let r = try Xlsx.create(title: a["title"]?.string, sheets: sheets)   // chạy thử để báo lỗi trước khi hỏi duyệt
                         return ActionPlan(kind: .write, summary: "Tạo sổ tính Excel " + p, preview: "Gồm \(sheets.count) trang tính.\n" + r.report.joined(separator: "\n"), paths: [p])
                     }) { [self] a in
                let r = try await excelCreate(path: str(a, "path"), title: a["title"]?.string, sheets: list(a["sheets"], "sheets"), chatId: a["chatId"]?.string)
                return "Đã tạo \(r.change.path) (mã hoàn tác \(r.change.id)).\n" + r.report.joined(separator: "\n")
            },
            ToolSpec(name: "excel_edit", summary: "Sửa tệp Excel trên BẢN SAO (tệp gốc không đổi): ghi ô, công thức, tô màu, lọc, đóng băng, gộp ô, độ rộng cột, thêm trang tính, biểu đồ. Cần người dùng duyệt. Công thức được tính lại và báo lỗi.",
                     parameters: #"{"path": "tệp .xlsx gốc", "output": "bản sao mới (tùy chọn, mặc định '<tên> (đã sửa).xlsx')", "ops": "[{\"op\":\"set\",\"sheet\":\"Điểm 8A\",\"cell\":\"D2\",\"value\":9} hoặc {\"op\":\"set\",\"cell\":\"E2\",\"formula\":\"=IF(D2>=8,\\\"Giỏi\\\",\\\"Khá\\\")\"}, {\"op\":\"setRows\",\"at\":\"A10\",\"rows\":[[..]]}, {\"op\":\"style\",\"range\":\"A1:E1\",\"color\":\"FFFF00\",\"fontColor\":\"000000\",\"bold\":true,\"numFmt\":\"0.0\",\"align\":\"center\",\"border\":true}, {\"op\":\"filter\",\"range\":\"A1:E30\"}, {\"op\":\"freeze\",\"cell\":\"A2\"}, {\"op\":\"merge\",\"range\":\"A1:E1\"}, {\"op\":\"width\",\"column\":\"B\",\"width\":24}, {\"op\":\"addSheet\",\"name\":\"Tổng kết\"}, {\"op\":\"chart\",\"type\":\"bar|line|pie\",\"categories\":\"B2:B9\",\"series\":[{\"name\":\"Điểm\",\"values\":\"D2:D9\"}],\"anchor\":\"G2\"}]; sheet bỏ trống = trang đầu"}"#,
                     access: .write, plan: { [self] a in
                         let chat = a["chatId"]?.string
                         let src = try await targetPath(str(a, "path"), chatId: chat)
                         let ops = try list(a["ops"], "ops")
                         let dest: String
                         if let o = a["output"]?.string { dest = try await targetPath(o, chatId: chat) } else { dest = copyNameXlsx(of: src) }
                         var preview = "Gốc (không đổi): \(src)\n"
                         if await permissions.check(src, .read).denied == nil, let data = try? await readXlsx(src, chatId: chat) {
                             preview += try Xlsx.edit(data, ops: ops).report.joined(separator: "\n")   // chạy thử
                         }
                         return ActionPlan(kind: .write, summary: "Tạo bản sửa " + dest, preview: preview, paths: [dest])
                     }) { [self] a in
                let r = try await excelEdit(path: str(a, "path"), output: a["output"]?.string, ops: list(a["ops"], "ops"), chatId: a["chatId"]?.string)
                return "Đã tạo bản sửa \(r.change.path) (mã hoàn tác \(r.change.id)); tệp gốc không đổi.\n" + r.report.joined(separator: "\n")
            },
        ]
    }
}
