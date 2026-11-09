import Foundation

public struct WritingMode: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var icon: String?
    /// Mô tả ngắn hiện dưới tên.
    public var hint: String?
    /// Chỉ dẫn đưa vào lời nhắc hệ thống (dùng được với mọi model).
    public var instructions: String
    /// Chế độ có sẵn (chỉ đọc) hay chế độ người dùng tự tạo.
    public var builtin: Bool
    /// Nhân bản từ chế độ nào.
    public var origin: String?
}

public struct ModeBackup: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
}

public struct ModePreview: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var line: Int
        /// "add", "remove" hoặc "change" (so với bản hiện tại)
        public var kind: String
    }
    public var revision: String
    public var backupRevision: String
    public var changedFields: [String]
    public var lines: [Line]
}

enum BuiltinModes {
    static let defaultID = "su-pham"

    static let all: [WritingMode] = [
        mode("su-pham", "Sư phạm", "📘", "Rõ ràng, thân thiện, đúng chương trình GDPT 2018", [
            "CHẾ ĐỘ SƯ PHẠM (mặc định):",
            "- Trả lời như một đồng nghiệp sư phạm: rõ ràng, thân thiện, đúng chương trình giáo dục phổ thông 2018 và sách giáo khoa hiện hành.",
            "- Giải thích từ dễ đến khó, có ví dụ gần gũi với học sinh; thuật ngữ khó thì giải thích ngắn.",
            "- Khi soạn bài, đề, nhận xét: đúng mục tiêu, đúng mức độ nhận thức, phù hợp lứa tuổi; không bịa số liệu, trích dẫn hay căn cứ pháp lý.",
            "- Thiếu thông tin thiết yếu (lớp, môn, bài, thời lượng) thì hỏi lại ngắn gọn thay vì đoán.",
        ]),
        mode("chinh-xac", "Chính xác", "📐", "Toán, Khoa học tự nhiên: từng bước, đúng đơn vị", [
            "CHẾ ĐỘ CHÍNH XÁC (Toán, Khoa học tự nhiên):",
            "- Giải từng bước, mỗi bước một dòng; nêu công thức trước khi thay số.",
            "- Giữ đơn vị SI trong mọi phép tính; không làm tròn ở bước trung gian; kết quả cuối làm tròn hợp lí và ghi đơn vị.",
            "- Tự kiểm tra lại phép tính và đơn vị trước khi trả lời; nếu thiếu dữ kiện thì nói rõ thiếu gì, không đoán.",
            "- Viết số thập phân bằng dấu phẩy theo cách viết của Việt Nam (vd 9,8 m/s²); kí hiệu, thuật ngữ đúng chương trình giáo dục phổ thông 2018.",
            "- Không thêm lời bình, ví dụ hay chi tiết không được hỏi.",
        ]),
        mode("hoc-thuat", "Học thuật", "🎓", "Khoa học, khách quan, có lập luận và chứng minh", [
            "CHẾ ĐỘ HỌC THUẬT:",
            "- Văn phong khoa học, khách quan, dùng thuật ngữ chính xác; định nghĩa thuật ngữ ở lần dùng đầu.",
            "- Lập luận chặt chẽ: luận điểm → luận cứ → kết luận; phân biệt rõ dữ kiện với nhận định.",
            "- KHÔNG bịa trích dẫn, số liệu, tên tác giả hay tài liệu tham khảo; chỗ cần nguồn thì ghi [cần nguồn].",
            "- Khi góp ý, nhận xét hay phản biện nội dung: MỖI nhận định phải kèm chứng minh: lập luận từng bước, phản ví dụ, số liệu, hoặc căn cứ có thật (SGK, chương trình GDPT 2018, định luật / định nghĩa chuẩn). Nêu rõ mức độ chắc chắn; chỗ còn tranh luận thì trình bày các quan điểm.",
            "- Lời khuyên phải cụ thể: sửa câu nào, thành câu gì, vì sao tốt hơn.",
        ]),
        mode("ke-toan", "Kế toán", "🧮", "Số liệu chính xác tuyệt đối, mọi con số có nguồn", [
            "CHẾ ĐỘ KẾ TOÁN (gần Học thuật; số liệu phải chính xác tuyệt đối):",
            "- MỌI phép tính (cộng, nhân, chia, phần trăm, thuế, điểm trung bình, làm tròn, thống kê, xếp hạng) phải do công cụ tính ra (chạy mã bằng run_code hoặc công thức bảng tính); KHÔNG tự nhẩm. Chỉ ghi con số do công cụ trả về.",
            "- Khi tài liệu đã có sẵn con số (ô, bảng, câu văn): đọc ra rồi tính lại tổng, phần trăm, chênh lệch và báo chỗ nào lệch; không tự sửa số của người dùng, hãy nêu chỗ lệch và số đúng.",
            "- Mỗi con số phải có nguồn: lấy từ ô/bảng/dữ kiện nào do người dùng cung cấp. Thiếu dữ kiện, tỉ giá, thuế suất thì hỏi lại; không đoán, không bịa số liệu.",
            "- Không làm tròn ở bước trung gian; chỉ làm tròn ở kết quả cuối, nói rõ quy ước (mặc định nguyên đồng cho VND, nửa lên). Ghi rõ đơn vị tiền tệ.",
            "- Bảng tính: ưu tiên đặt CÔNG THỨC thay vì dán số cứng; đặt xong đọc lại giá trị và đối chiếu.",
            "- Viết số theo cách Việt Nam khi trình bày (1.234.567,5), nhưng đưa vào công cụ tính bằng dấu chấm thập phân, không dấu phân cách hàng nghìn (1234567.5).",
            "- Cuối câu trả lời: một dòng báo cáo đã kiểm bao nhiêu số, lệch những chỗ nào (nếu có).",
        ]),
        mode("sang-tao", "Sáng tạo", "🎨", "Giàu hình ảnh, nhiều phương án, gần gũi học sinh", [
            "CHẾ ĐỘ SÁNG TẠO:",
            "- Giàu hình ảnh, gần gũi với học sinh: ví dụ đời sống, câu chuyện ngắn, so sánh, câu hỏi gợi mở, trò chơi.",
            "- Đưa ra nhiều phương án khác nhau khi phù hợp; giọng văn tươi vui.",
            "- Sáng tạo về cách trình bày nhưng kiến thức phải đúng.",
        ]),
        mode("hanh-chinh", "Hành chính", "📄", "Văn bản hành chính đúng thể thức", [
            "CHẾ ĐỘ HÀNH CHÍNH:",
            "- Văn phong hành chính – công vụ: chuẩn mực, khách quan, ngắn gọn, một nghĩa; không dùng từ cảm xúc hay khẩu ngữ.",
            "- Khi soạn văn bản hoàn chỉnh, theo thể thức văn bản hành chính hiện hành (Nghị định 30/2020/NĐ-CP về công tác văn thư): quốc hiệu, tiêu ngữ, số và kí hiệu, địa danh và thời gian, trích yếu, nơi nhận.",
        ]),
        mode("ngan-gon", "Ngắn gọn", "✂️", "Trả lời ngắn nhất có thể mà vẫn đủ ý", [
            "CHẾ ĐỘ NGẮN GỌN: trả lời ngắn nhất có thể mà vẫn đủ ý; ưu tiên gạch đầu dòng; không mở bài, không tóm tắt lại.",
        ]),
    ]

    private static func mode(_ id: String, _ name: String, _ icon: String, _ hint: String, _ lines: [String]) -> WritingMode {
        WritingMode(id: id, name: name, icon: icon, hint: hint, instructions: lines.joined(separator: "\n"), builtin: true, origin: nil)
    }

    static func find(_ id: String) -> WritingMode? { all.first { $0.id == id } }
}

/// Giới hạn của chế độ tự tạo (giống MySoft).
enum ModeLimits {
    static let count = 40, name = 40, icon = 8, hint = 120, instructions = 4000, history = 20
}

extension DataStore {
    private static func mode(_ r: Row) -> WritingMode {
        WritingMode(id: r.text(0), name: r.text(1), icon: r.optText(2), hint: r.optText(3), instructions: r.text(4), builtin: false, origin: r.optText(5))
    }

    public func customModes() throws -> [WritingMode] {
        try db.query("SELECT id, name, icon, hint, instructions, origin FROM modes ORDER BY pos, id", [], Self.mode)
    }

    func customMode(id: String) throws -> WritingMode? {
        try db.query("SELECT id, name, icon, hint, instructions, origin FROM modes WHERE id = ?", [.text(id)], Self.mode).first
    }

    static func modeRevision(_ m: WritingMode) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return FileHash.of((try? enc.encode(m)) ?? Data())
    }

    private func snapshot(_ m: WritingMode) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try db.run("INSERT INTO mode_history(id, modeId, snapshot, createdAt) VALUES(?,?,?,?)",
                   [.text(UUID().uuidString), .text(m.id), .text(String(decoding: try enc.encode(m), as: UTF8.self)), .double(now().timeIntervalSince1970)])
        try db.run("""
            DELETE FROM mode_history WHERE modeId = ? AND id NOT IN
              (SELECT id FROM mode_history WHERE modeId = ? ORDER BY createdAt DESC, rowid DESC LIMIT ?)
            """, [.text(m.id), .text(m.id), .int(Int64(ModeLimits.history))])
    }

    private static func clip(_ s: String?, _ n: Int) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.isEmpty ? nil : String(t.prefix(n))
    }

    /// Thêm mới (không có `id`) hoặc sửa chế độ tự tạo. Bản cũ được lưu vào lịch sử để khôi phục.
    public func saveMode(id: String?, name: String, icon: String?, hint: String?, instructions: String, origin: String? = nil) throws -> String {
        if let id, id.range(of: "^c-[a-z0-9]{6,32}$", options: .regularExpression) == nil {
            throw PVTAError("Chế độ có sẵn chỉ đọc. Hãy nhân bản thành chế độ riêng rồi sửa.")
        }
        guard let n = Self.clip(name, ModeLimits.name) else { throw PVTAError("Hãy đặt tên cho chế độ.") }
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PVTAError("Chỉ dẫn của chế độ “\(n)” đang trống.") }
        guard text.count <= ModeLimits.instructions else { throw PVTAError("Chỉ dẫn của “\(n)” quá dài (tối đa 4.000 ký tự).") }
        if let origin, BuiltinModes.find(origin) == nil, try customMode(id: origin) == nil { throw PVTAError("Chế độ gốc “\(origin)” không tồn tại.") }
        return try db.transaction {
            let ic = Self.clip(icon, ModeLimits.icon), hi = Self.clip(hint, ModeLimits.hint)
            func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
            if let id, let old = try customMode(id: id) {
                let updated = WritingMode(id: id, name: n, icon: ic, hint: hi, instructions: text, builtin: false, origin: origin ?? old.origin)
                if updated != old { try snapshot(old) }
                try db.run("UPDATE modes SET name = ?, icon = ?, hint = ?, instructions = ?, origin = ?, updatedAt = ? WHERE id = ?",
                           [.text(n), opt(ic), opt(hi), .text(text), opt(updated.origin), .double(now().timeIntervalSince1970), .text(id)])
                return id
            }
            let count = try db.query("SELECT COUNT(*) FROM modes", [], { Int($0.int(0)) }).first ?? 0
            guard count < ModeLimits.count else { throw PVTAError("Đã đủ \(ModeLimits.count) chế độ tự tạo; hãy xóa bớt.") }
            let newId = "c-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            let pos = (try db.query("SELECT COALESCE(MAX(pos), 0) + 1 FROM modes", [], { $0.int(0) }).first) ?? 1
            try db.run("INSERT INTO modes(id, name, icon, hint, instructions, origin, pos, updatedAt) VALUES(?,?,?,?,?,?,?,?)",
                       [.text(newId), .text(n), opt(ic), opt(hi), .text(text), opt(origin), .int(pos), .double(now().timeIntervalSince1970)])
            return newId
        }
    }

    public func deleteMode(id: String) throws {
        try db.transaction {
            guard let old = try customMode(id: id) else { throw PVTAError("Không tìm thấy chế độ riêng (chế độ có sẵn không xóa được).") }
            try snapshot(old)
            try db.run("DELETE FROM modes WHERE id = ?", [.text(id)])
        }
    }

    /// Đổi thứ tự theo danh sách mã; mã lạ bỏ qua, chế độ không có trong danh sách giữ ở cuối.
    public func reorderModes(ids: [String]) throws {
        try db.transaction {
            let existing = try customModes().map(\.id)
            let ordered = ids.filter(existing.contains) + existing.filter { !ids.contains($0) }
            for (i, id) in ordered.enumerated() { try db.run("UPDATE modes SET pos = ? WHERE id = ?", [.int(Int64(i + 1)), .text(id)]) }
        }
    }

    /// Lịch sử không trả về nội dung (tên, chỉ dẫn) để không lộ chữ riêng của người dùng khi chỉ liệt kê.
    public func modeHistory(id: String) throws -> [ModeBackup] {
        return try db.query("SELECT id, createdAt FROM mode_history WHERE modeId = ? ORDER BY createdAt DESC, rowid DESC", [.text(id)]) {
            ModeBackup(id: $0.text(0), createdAt: Date(timeIntervalSince1970: $0.double(1)))
        }
    }

    private func backup(id: String, backupId: String) throws -> (mode: WritingMode, revision: String) {
        guard let raw = try db.query("SELECT snapshot FROM mode_history WHERE id = ? AND modeId = ?", [.text(backupId), .text(id)], { $0.text(0) }).first,
              let mode = try? JSONDecoder().decode(WritingMode.self, from: Data(raw.utf8)), mode.id == id else { throw PVTAError("Bản sao lưu không hợp lệ.") }
        return (mode, FileHash.of(Data(raw.utf8)))
    }

    public func previewModeBackup(id: String, backupId: String) throws -> ModePreview {
        let (old, backupRev) = try backup(id: id, backupId: backupId)
        guard let current = try customMode(id: id) else {   // đã xóa: mọi trường đều khác
            return ModePreview(revision: "", backupRevision: backupRev, changedFields: ["name", "instructions"],
                               lines: old.instructions.components(separatedBy: "\n").indices.map { .init(line: $0 + 1, kind: "add") })
        }
        var fields: [String] = []
        if current.name != old.name { fields.append("name") }
        if current.icon != old.icon { fields.append("icon") }
        if current.hint != old.hint { fields.append("hint") }
        if current.instructions != old.instructions { fields.append("instructions") }
        let a = current.instructions.components(separatedBy: "\n"), b = old.instructions.components(separatedBy: "\n")
        var lines: [ModePreview.Line] = []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : nil, y = i < b.count ? b[i] : nil
            if x != y { lines.append(.init(line: i + 1, kind: x == nil ? "add" : y == nil ? "remove" : "change")) }
        }
        return ModePreview(revision: Self.modeRevision(current), backupRevision: backupRev, changedFields: fields, lines: lines)
    }

    /// Khôi phục một bản cũ. Phải kèm mã bản hiện tại và bản sao lưu lúc xem trước để không đè lên thay đổi mới hơn.
    public func restoreMode(id: String, backupId: String, revision: String, backupRevision: String) throws {
        let (old, backupRev) = try backup(id: id, backupId: backupId)
        guard !backupRevision.isEmpty, backupRev == backupRevision else { throw PVTAError("Bản sao lưu đã thay đổi; hãy xem trước lại.") }
        guard let current = try customMode(id: id) else {
            // Chế độ đã bị xóa: dựng lại với cùng mã (mã bản hiện tại phải để trống).
            guard revision.isEmpty else { throw PVTAError("Chế độ đã thay đổi; hãy xem trước lại.") }
            try db.transaction {
                let count = try db.query("SELECT COUNT(*) FROM modes", [], { Int($0.int(0)) }).first ?? 0
                guard count < ModeLimits.count else { throw PVTAError("Đã đủ \(ModeLimits.count) chế độ tự tạo; hãy xóa bớt.") }
                let pos = (try db.query("SELECT COALESCE(MAX(pos), 0) + 1 FROM modes", [], { $0.int(0) }).first) ?? 1
                func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
                try db.run("INSERT INTO modes(id, name, icon, hint, instructions, origin, pos, updatedAt) VALUES(?,?,?,?,?,?,?,?)",
                           [.text(id), .text(old.name), opt(old.icon), opt(old.hint), .text(old.instructions), opt(old.origin), .int(pos), .double(now().timeIntervalSince1970)])
            }
            return
        }
        guard !revision.isEmpty, Self.modeRevision(current) == revision else { throw PVTAError("Chế độ đã thay đổi; hãy xem trước lại.") }
        guard !backupRevision.isEmpty, backupRev == backupRevision else { throw PVTAError("Bản sao lưu đã thay đổi; hãy xem trước lại.") }
        _ = try saveMode(id: id, name: old.name, icon: old.icon, hint: old.hint, instructions: old.instructions)
    }
}
