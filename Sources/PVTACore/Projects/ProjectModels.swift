import Foundation

public struct Workspace: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var createdAt: Double
}

public struct ProjectMeta: Codable, Sendable, Equatable {
    public var projectId: String
    public var workspaceId: String?
    /// Công tắc: tắt thì lượt AI sau không gửi tài liệu hiện tại / kinh nghiệm của dự án.
    public var sendSources: Bool
    public var sendLearning: Bool
    public var notes: String
    public var noteFile: String?
    public var noteFingerprint: String?
}

public struct ProjectFolder: Codable, Sendable, Equatable {
    public var id: String
    public var projectId: String
    public var path: String
    /// "source" (tài liệu hiện tại) | "learning" (Học hỏi: nguồn cũ)
    public var role: String
}

public struct ProjectDoc: Codable, Sendable, Equatable {
    public var id: String
    public var projectId: String
    public var folderId: String?
    public var role: String
    public var path: String
    public var hash: String?
    public var size: Int
    public var mtime: Double
    public var status: String       // ok | unreadable
    public var note: String?
    public var chars: Int
}

public struct ImportReport: Codable, Sendable, Equatable {
    public var added: Int
    public var updated: Int
    public var removed: Int
    /// Tệp vượt giới hạn mỗi lượt nhập (60 tệp) nên chưa nhập.
    public var skippedOverLimit: Int
    /// Tệp nằm sâu hơn 8 cấp thư mục nên bỏ qua.
    public var skippedTooDeep: Int
    public var unreadable: [String]
}

extension DataStore {
    func workspaces() throws -> [Workspace] { try db.query("SELECT id, name, createdAt FROM workspaces ORDER BY name", [], { Workspace(id: $0.text(0), name: $0.text(1), createdAt: $0.double(2)) }) }
    func saveWorkspace(_ w: Workspace) throws {
        try db.run("INSERT INTO workspaces(id, name, createdAt) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name = excluded.name", [.text(w.id), .text(w.name), .double(w.createdAt)])
    }
    func deleteWorkspace(id: String) throws { try db.run("DELETE FROM workspaces WHERE id = ?", [.text(id)]) }

    func projectMeta(_ projectId: String) throws -> ProjectMeta {
        try db.query("SELECT projectId, workspaceId, sendSources, sendLearning, notes, noteFile, noteFingerprint FROM project_meta WHERE projectId = ?", [.text(projectId)]) {
            ProjectMeta(projectId: $0.text(0), workspaceId: $0.optText(1), sendSources: $0.int(2) != 0, sendLearning: $0.int(3) != 0, notes: $0.text(4), noteFile: $0.optText(5), noteFingerprint: $0.optText(6))
        }.first ?? ProjectMeta(projectId: projectId, workspaceId: nil, sendSources: true, sendLearning: true, notes: "", noteFile: nil, noteFingerprint: nil)
    }
    func saveProjectMeta(_ m: ProjectMeta) throws {
        try db.run("""
            INSERT INTO project_meta(projectId, workspaceId, sendSources, sendLearning, notes, noteFile, noteFingerprint, updatedAt) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(projectId) DO UPDATE SET workspaceId = excluded.workspaceId, sendSources = excluded.sendSources, sendLearning = excluded.sendLearning,
                notes = excluded.notes, noteFile = excluded.noteFile, noteFingerprint = excluded.noteFingerprint, updatedAt = excluded.updatedAt
            """, [.text(m.projectId), m.workspaceId.map { .text($0) } ?? .null, .int(m.sendSources ? 1 : 0), .int(m.sendLearning ? 1 : 0), .text(m.notes),
                  m.noteFile.map { .text($0) } ?? .null, m.noteFingerprint.map { .text($0) } ?? .null, .double(Date().timeIntervalSince1970)])
    }

    func projectFolders(_ projectId: String) throws -> [ProjectFolder] {
        try db.query("SELECT id, projectId, path, role FROM project_folders WHERE projectId = ? ORDER BY addedAt, id", [.text(projectId)]) {
            ProjectFolder(id: $0.text(0), projectId: $0.text(1), path: $0.text(2), role: $0.text(3))
        }
    }
    func addProjectFolder(_ f: ProjectFolder) throws {
        try db.run("INSERT INTO project_folders(id, projectId, path, role, addedAt) VALUES(?,?,?,?,?)", [.text(f.id), .text(f.projectId), .text(f.path), .text(f.role), .double(Date().timeIntervalSince1970)])
    }
    func deleteProjectFolder(id: String) throws { try db.run("DELETE FROM project_folders WHERE id = ?", [.text(id)]) }

    func projectDocs(_ projectId: String, role: String? = nil) throws -> [ProjectDoc] {
        try db.query("""
            SELECT id, projectId, folderId, role, path, hash, size, mtime, status, note, chars FROM project_docs
            WHERE projectId = ? AND (? IS NULL OR role = ?) ORDER BY path
            """, [.text(projectId), role.map { .text($0) } ?? .null, role.map { .text($0) } ?? .null]) {
            ProjectDoc(id: $0.text(0), projectId: $0.text(1), folderId: $0.optText(2), role: $0.text(3), path: $0.text(4), hash: $0.optText(5), size: Int($0.int(6)),
                       mtime: $0.double(7), status: $0.text(8), note: $0.optText(9), chars: Int($0.int(10)))
        }
    }
    func saveProjectDoc(_ d: ProjectDoc, chunks: [String]) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO project_docs(id, projectId, folderId, role, path, hash, size, mtime, status, note, chars) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET hash = excluded.hash, size = excluded.size, mtime = excluded.mtime, status = excluded.status, note = excluded.note, chars = excluded.chars
                """, [.text(d.id), .text(d.projectId), d.folderId.map { .text($0) } ?? .null, .text(d.role), .text(d.path), d.hash.map { .text($0) } ?? .null, .int(Int64(d.size)),
                      .double(d.mtime), .text(d.status), d.note.map { .text($0) } ?? .null, .int(Int64(d.chars))])
            try db.run("DELETE FROM project_chunks WHERE docId = ?", [.text(d.id)])
            for (i, c) in chunks.enumerated() { try db.run("INSERT INTO project_chunks(docId, idx, text) VALUES(?,?,?)", [.text(d.id), .int(Int64(i)), .text(c)]) }
        }
    }
    func deleteProjectDoc(id: String) throws { try db.run("DELETE FROM project_docs WHERE id = ?", [.text(id)]) }
    func projectChunks(_ projectId: String, role: String) throws -> [(doc: ProjectDoc, index: Int, text: String)] {
        let docs = Dictionary(uniqueKeysWithValues: try projectDocs(projectId, role: role).filter { $0.status == "ok" }.map { ($0.id, $0) })
        return try db.query("""
            SELECT c.docId, c.idx, c.text FROM project_chunks c JOIN project_docs d ON d.id = c.docId WHERE d.projectId = ? AND d.role = ? ORDER BY d.path, c.idx
            """, [.text(projectId), .text(role)]) { r in (r.text(0), Int(r.int(1)), r.text(2)) }.compactMap { x in docs[x.0].map { ($0, x.1, x.2) } }
    }
}
