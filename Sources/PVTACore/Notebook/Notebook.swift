import Foundation
import CryptoKit

public struct Notebook: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Model riêng của sổ (mã đầy đủ `nhà-cung-cấp/model`); nil = tự chọn.
    public var model: String?
    public var createdAt: Double
    public var updatedAt: Double
}

public struct NotebookSource: Codable, Sendable, Equatable {
    public var id: String
    public var notebookId: String
    /// "file" | "web"
    public var kind: String
    public var ref: String
    public var title: String
    public var enabled: Bool
    public var hash: String?
    /// ok | stale (làm mới lỗi, đang dùng bản cũ) | missing (tệp không còn) | unreadable
    public var status: String
    public var note: String?
    public var chars: Int
    public var fetchedAt: Double?
    public var addedAt: Double
}

public struct SourceRef: Codable, Sendable, Equatable {
    public var n: Int
    public var sourceId: String
    public var title: String
    public var ref: String
}

public struct CitationCheck: Codable, Sendable, Equatable {
    /// Số trích dẫn không trỏ tới nguồn nào đã đưa vào.
    public var unknown: [Int]
    /// Đoạn trích nguyên văn trong dấu ngoặc kép/«» không tìm thấy trong nguồn được trích.
    public var quotesNotFound: [String]
    /// Câu khẳng định dài không kèm trích dẫn.
    public var uncited: Int
    public var ok: Bool { unknown.isEmpty && quotesNotFound.isEmpty }
}

public struct NotebookAnswer: Codable, Sendable, Equatable {
    public var text: String
    public var sources: [SourceRef]
    public var check: CitationCheck
    public var usedAI: Bool
}

extension DataStore {
    private static func nb(_ r: Row) -> Notebook { Notebook(id: r.text(0), name: r.text(1), model: r.optText(2), createdAt: r.double(3), updatedAt: r.double(4)) }
    private static func src(_ r: Row) -> NotebookSource {
        NotebookSource(id: r.text(0), notebookId: r.text(1), kind: r.text(2), ref: r.text(3), title: r.text(4), enabled: r.int(5) != 0, hash: r.optText(6), status: r.text(7),
                       note: r.optText(8), chars: Int(r.int(9)), fetchedAt: r.int(10) == 0 && r.double(10) == 0 ? nil : r.double(10), addedAt: r.double(11))
    }
    static let srcColumns = "id, nbId, kind, ref, title, enabled, hash, status, note, chars, COALESCE(fetchedAt, 0), addedAt"

    public func notebooks() throws -> [Notebook] { try db.query("SELECT id, name, model, createdAt, updatedAt FROM notebooks ORDER BY updatedAt DESC, id", [], Self.nb) }
    public func notebook(id: String) throws -> Notebook? { try db.query("SELECT id, name, model, createdAt, updatedAt FROM notebooks WHERE id = ?", [.text(id)], Self.nb).first }
    func saveNotebook(_ n: Notebook) throws {
        try db.run("""
            INSERT INTO notebooks(id, name, model, createdAt, updatedAt) VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, model = excluded.model, updatedAt = excluded.updatedAt
            """, [.text(n.id), .text(n.name), n.model.map { .text($0) } ?? .null, .double(n.createdAt), .double(n.updatedAt)])
    }
    func deleteNotebook(id: String) throws { try db.run("DELETE FROM notebooks WHERE id = ?", [.text(id)]) }

    public func nbSources(notebook: String) throws -> [NotebookSource] {
        try db.query("SELECT \(Self.srcColumns) FROM nb_sources WHERE nbId = ? ORDER BY addedAt, id", [.text(notebook)], Self.src)
    }
    public func nbSource(id: String) throws -> NotebookSource? { try db.query("SELECT \(Self.srcColumns) FROM nb_sources WHERE id = ?", [.text(id)], Self.src).first }
    func saveNbSource(_ s: NotebookSource) throws {
        try db.run("""
            INSERT INTO nb_sources(id, nbId, kind, ref, title, enabled, hash, status, note, chars, fetchedAt, addedAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, enabled = excluded.enabled, hash = excluded.hash, status = excluded.status,
                note = excluded.note, chars = excluded.chars, fetchedAt = excluded.fetchedAt
            """, [.text(s.id), .text(s.notebookId), .text(s.kind), .text(s.ref), .text(s.title), .int(s.enabled ? 1 : 0), s.hash.map { .text($0) } ?? .null, .text(s.status),
                  s.note.map { .text($0) } ?? .null, .int(Int64(s.chars)), s.fetchedAt.map { .double($0) } ?? .null, .double(s.addedAt)])
    }
    func deleteNbSource(id: String) throws { try db.run("DELETE FROM nb_sources WHERE id = ?", [.text(id)]) }
    func setNbChunks(source: String, _ chunks: [String]) throws {
        try db.transaction {
            try db.run("DELETE FROM nb_chunks WHERE sourceId = ?", [.text(source)])
            for (i, c) in chunks.enumerated() { try db.run("INSERT INTO nb_chunks(sourceId, idx, text) VALUES(?,?,?)", [.text(source), .int(Int64(i)), .text(c)]) }
        }
    }
    func nbChunks(source: String) throws -> [String] { try db.query("SELECT text FROM nb_chunks WHERE sourceId = ? ORDER BY idx", [.text(source)]) { $0.text(0) } }
}
