import Foundation

public enum DocStatus: String, Codable, Sendable, CaseIterable {
    case conHieuLuc = "con-hieu-luc", sapCoHieuLuc = "sap-co-hieu-luc", daSuaDoi = "da-sua-doi", hetHieuLuc = "het-hieu-luc", chuaXacDinh = "chua-xac-dinh"

    var label: String {
        switch self {
        case .conHieuLuc: return "Còn hiệu lực"; case .sapCoHieuLuc: return "Sắp có hiệu lực"; case .daSuaDoi: return "Đã sửa đổi"
        case .hetHieuLuc: return "Hết hiệu lực"; case .chuaXacDinh: return "Chưa xác định"
        }
    }
}

public enum DocState: String, Codable, Sendable {
    case chuaTai = "chua-tai", daTai = "da-tai", chuaDocDuoc = "chua-doc-duoc", nguonKhongCon = "nguon-khong-con"

    var label: String {
        switch self {
        case .chuaTai: return "Chưa tải"; case .daTai: return "Đã tải"; case .chuaDocDuoc: return "Chưa đọc được"; case .nguonKhongCon: return "Nguồn không còn"
        }
    }
}

public struct DocRecord: Codable, Sendable, Equatable {
    public var id: String
    public var group: String
    /// Số hiệu, ví dụ “115/2020/NĐ-CP” (có thể chưa biết).
    public var no: String?
    public var title: String
    public var agency: String = ""
    public var issuedAt: String?
    public var effectiveAt: String?
    public var status: DocStatus = .chuaXacDinh
    /// "tay": thầy cô tự đặt (không bị ghi đè); "van-ban": suy ra từ chữ của văn bản khác.
    public var statusSource: String?
    public var url: String?
    public var host: String?
    public var state: DocState = .chuaTai
    /// Tệp trong kho (tên tệp), mã băm SHA-256 của tệp đã tải.
    public var file: String?
    public var hash: String?
    public var note: String?
    public var isNew: Bool = false
    public var hidden: Bool = false
    public var replacedBy: String?
    public var amendedBy: [String] = []
    public var replaces: [String] = []
    public var amends: [String] = []
    public var addedAt: Double
    /// "tay" | "tim-moi"
    public var source: String
}

extension DataStore {
    private func record(_ r: Row) -> DocRecord? {
        try? JSONDecoder().decode(DocRecord.self, from: Data(r.text(0).utf8))
    }

    public func docs(group: String? = nil, includeHidden: Bool = false) throws -> [DocRecord] {
        try db.query("""
            SELECT json FROM group_docs WHERE (? IS NULL OR groupId = ?) AND (? = 1 OR hidden = 0) ORDER BY addedAt DESC, id
            """, [group.map { .text($0) } ?? .null, group.map { .text($0) } ?? .null, .int(includeHidden ? 1 : 0)]) { self.record($0) }.compactMap { $0 }
    }

    public func doc(id: String) throws -> DocRecord? {
        try db.query("SELECT json FROM group_docs WHERE id = ?", [.text(id)]) { self.record($0) }.first.flatMap { $0 }
    }

    func docExists(group: String, url: String) throws -> Bool {
        try !db.query("SELECT 1 FROM group_docs WHERE groupId = ? AND url = ?", [.text(group), .text(url)], { _ in 1 }).isEmpty
    }

    func saveDoc(_ d: DocRecord) throws {
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        try db.run("""
            INSERT INTO group_docs(id, groupId, no, state, isNew, hidden, hash, url, addedAt, json) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET groupId = excluded.groupId, no = excluded.no, state = excluded.state, isNew = excluded.isNew,
                hidden = excluded.hidden, hash = excluded.hash, url = excluded.url, json = excluded.json
            """, [.text(d.id), .text(d.group), d.no.map { .text($0) } ?? .null, .text(d.state.rawValue), .int(d.isNew ? 1 : 0), .int(d.hidden ? 1 : 0),
                  d.hash.map { .text($0) } ?? .null, d.url.map { .text($0) } ?? .null, .double(d.addedAt), .text(json)])
    }

    func deleteDoc(id: String) throws { try db.run("DELETE FROM group_docs WHERE id = ?", [.text(id)]) }

    func docSummary(hash: String) throws -> String? {
        try db.query("SELECT text FROM doc_summaries WHERE hash = ?", [.text(hash)]) { $0.text(0) }.first
    }

    func saveDocSummary(hash: String, text: String) throws {
        try db.run("INSERT OR REPLACE INTO doc_summaries(hash, text, createdAt) VALUES(?,?,?)", [.text(hash), .text(text), .double(Date().timeIntervalSince1970)])
    }
}
