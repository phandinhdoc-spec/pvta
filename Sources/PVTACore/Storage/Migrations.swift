import Foundation

/// Một bước đổi cấu trúc dữ liệu. `version` tăng dần, bắt đầu từ 1.
public struct Migration: Sendable {
    public let version: Int
    public let sql: String
    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

public enum Schema {
    /// Khi cần đổi cấu trúc, thêm một Migration mới ở cuối; không sửa các bước cũ.
    public static let all: [Migration] = [
        Migration(version: 1, sql: """
            CREATE TABLE projects(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE TABLE chats(
                id TEXT PRIMARY KEY, title TEXT NOT NULL,
                projectId TEXT REFERENCES projects(id) ON DELETE SET NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL, updatedAt REAL NOT NULL);
            CREATE TABLE messages(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                role TEXT NOT NULL, text TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE INDEX messages_chat ON messages(chatId, seq);
            CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """),
        // Nhật ký hoạt động: không ràng buộc khóa ngoại để xóa hội thoại không làm mất dấu vết.
        Migration(version: 2, sql: """
            CREATE TABLE activities(
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL, chatId TEXT, projectId TEXT, model TEXT,
                state TEXT NOT NULL, startedAt REAL NOT NULL, endedAt REAL, detail TEXT);
            CREATE INDEX activities_started ON activities(startedAt);
            """),
        // Hội thoại: model riêng, bản nháp ô soạn, tóm tắt khi ngữ cảnh dài, hàng đợi lời lệnh.
        Migration(version: 3, sql: """
            ALTER TABLE chats ADD COLUMN model TEXT;
            ALTER TABLE chats ADD COLUMN draft TEXT;
            ALTER TABLE chats ADD COLUMN summary TEXT;
            ALTER TABLE chats ADD COLUMN summaryCovered INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE chats ADD COLUMN queuePaused INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE messages ADD COLUMN model TEXT;
            ALTER TABLE messages ADD COLUMN error TEXT;
            ALTER TABLE messages ADD COLUMN tools TEXT;
            CREATE TABLE queued_prompts(
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                pos INTEGER NOT NULL, text TEXT NOT NULL, mode TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE INDEX queued_chat ON queued_prompts(chatId, pos);
            """),
        // Tệp, ảnh đính kèm và thư mục nguồn của hội thoại.
        Migration(version: 4, sql: """
            CREATE TABLE attachments(
                id TEXT PRIMARY KEY, chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, name TEXT NOT NULL, path TEXT, stored TEXT, mime TEXT,
                bytes INTEGER NOT NULL DEFAULT 0, chars INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0,
                text TEXT, sent INTEGER NOT NULL DEFAULT 0, addedAt REAL NOT NULL);
            CREATE INDEX attachments_chat ON attachments(chatId, addedAt);
            """),
        // Thư mục người dùng đã cấp cho PVTA đọc (và ghi nếu `write` = 1).
        Migration(version: 5, sql: """
            CREATE TABLE grants(path TEXT PRIMARY KEY, write INTEGER NOT NULL DEFAULT 0, addedAt REAL NOT NULL);
            """),
        // Nhật ký thay đổi tệp do PVTA thực hiện (để hoàn tác) và thư mục kết quả của hội thoại.
        Migration(version: 6, sql: """
            CREATE TABLE file_changes(
                id TEXT PRIMARY KEY, chatId TEXT, kind TEXT NOT NULL, path TEXT NOT NULL, original TEXT, backup TEXT,
                trashPath TEXT, beforeHash TEXT, afterHash TEXT, detail TEXT, createdAt REAL NOT NULL,
                undone INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX file_changes_time ON file_changes(createdAt);
            ALTER TABLE chats ADD COLUMN outputDir TEXT;
            """),
        // Chế độ viết riêng (kèm lịch sử để khôi phục), quy tắc gọi bằng #khóa, thư viện lời nhắc riêng gọi bằng @.
        Migration(version: 7, sql: """
            CREATE TABLE modes(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT, hint TEXT, instructions TEXT NOT NULL,
                origin TEXT, pos INTEGER NOT NULL, updatedAt REAL NOT NULL);
            CREATE TABLE mode_history(id TEXT PRIMARY KEY, modeId TEXT NOT NULL, snapshot TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE INDEX mode_history_mode ON mode_history(modeId, createdAt);
            CREATE TABLE rules(
                id TEXT PRIMARY KEY, scope TEXT NOT NULL, scopeId TEXT NOT NULL DEFAULT '', key TEXT NOT NULL,
                title TEXT NOT NULL, text TEXT NOT NULL, always INTEGER NOT NULL DEFAULT 0, updatedAt REAL NOT NULL,
                UNIQUE(scope, scopeId, key));
            CREATE TABLE prompts(
                id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, title TEXT NOT NULL, text TEXT NOT NULL,
                category TEXT NOT NULL, updatedAt REAL NOT NULL);
            CREATE TABLE prompt_favorites(id TEXT PRIMARY KEY, pos INTEGER NOT NULL);
            """),
        Migration(version: 8, sql: """
            CREATE TABLE group_docs(
                id TEXT PRIMARY KEY, groupId TEXT NOT NULL, no TEXT, state TEXT NOT NULL, isNew INTEGER NOT NULL DEFAULT 0,
                hidden INTEGER NOT NULL DEFAULT 0, hash TEXT, url TEXT, addedAt REAL NOT NULL, json TEXT NOT NULL);
            CREATE INDEX group_docs_group ON group_docs(groupId, addedAt);
            CREATE INDEX group_docs_url ON group_docs(groupId, url);
            CREATE TABLE doc_summaries(hash TEXT PRIMARY KEY, text TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE TABLE learned(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL DEFAULT '',
                skillName TEXT, createdAt REAL NOT NULL, updatedAt REAL NOT NULL);
            CREATE INDEX learned_status ON learned(status, kind);
            CREATE TABLE learned_history(id TEXT PRIMARY KEY, learnedId TEXT NOT NULL, snapshot TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE INDEX learned_history_item ON learned_history(learnedId, createdAt);
            CREATE TABLE answer_ratings(
                id TEXT PRIMARY KEY, chatId TEXT NOT NULL, messageId TEXT NOT NULL UNIQUE, rating INTEGER NOT NULL,
                note TEXT NOT NULL DEFAULT '', createdAt REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0);
            """),
        // Sổ nguồn (nguồn đã chia khúc để tra cứu), nhóm dự án, thư mục nguồn và Học hỏi của dự án.
        Migration(version: 9, sql: """
            CREATE TABLE notebooks(id TEXT PRIMARY KEY, name TEXT NOT NULL, model TEXT, createdAt REAL NOT NULL, updatedAt REAL NOT NULL);
            CREATE TABLE nb_sources(
                id TEXT PRIMARY KEY, nbId TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE, kind TEXT NOT NULL, ref TEXT NOT NULL,
                title TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, hash TEXT, status TEXT NOT NULL DEFAULT 'ok', note TEXT,
                chars INTEGER NOT NULL DEFAULT 0, fetchedAt REAL, addedAt REAL NOT NULL);
            CREATE INDEX nb_sources_nb ON nb_sources(nbId);
            CREATE TABLE nb_chunks(
                sourceId TEXT NOT NULL REFERENCES nb_sources(id) ON DELETE CASCADE, idx INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(sourceId, idx));
            CREATE TABLE workspaces(id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, createdAt REAL NOT NULL);
            CREATE TABLE project_meta(
                projectId TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE, workspaceId TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
                sendSources INTEGER NOT NULL DEFAULT 1, sendLearning INTEGER NOT NULL DEFAULT 1, notes TEXT NOT NULL DEFAULT '',
                noteFile TEXT, noteFingerprint TEXT, updatedAt REAL NOT NULL);
            CREATE TABLE project_folders(
                id TEXT PRIMARY KEY, projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, path TEXT NOT NULL, role TEXT NOT NULL,
                addedAt REAL NOT NULL, UNIQUE(projectId, path, role));
            CREATE TABLE project_docs(
                id TEXT PRIMARY KEY, projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                folderId TEXT REFERENCES project_folders(id) ON DELETE CASCADE, role TEXT NOT NULL, path TEXT NOT NULL, hash TEXT,
                size INTEGER NOT NULL DEFAULT 0, mtime REAL NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'ok', note TEXT,
                chars INTEGER NOT NULL DEFAULT 0, UNIQUE(projectId, path));
            CREATE TABLE project_chunks(
                docId TEXT NOT NULL REFERENCES project_docs(id) ON DELETE CASCADE, idx INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(docId, idx));
            """),
        // Liên kết sổ nguồn với hội thoại, dự án hoặc quy trình.
        Migration(version: 10, sql: """
            CREATE TABLE notebook_links(
                scope TEXT NOT NULL, scopeId TEXT NOT NULL, notebookId TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
                pos INTEGER NOT NULL, PRIMARY KEY(scope, scopeId, notebookId));
            CREATE INDEX notebook_links_scope ON notebook_links(scope, scopeId, pos);
            """),
        // Thư ký Sign: việc tôi giao (có thùng rác, phiên bản chống ghi đè) và thông báo nhắc việc.
        Migration(version: 11, sql: """
            CREATE TABLE secretary_tasks(
                id INTEGER PRIMARY KEY AUTOINCREMENT, assignedAt TEXT NOT NULL, content TEXT NOT NULL CHECK(length(trim(content)) > 0),
                deadline TEXT, done INTEGER NOT NULL DEFAULT 0 CHECK(done IN (0,1)), completedAt TEXT, notes TEXT, progress TEXT, priority TEXT,
                metadata TEXT NOT NULL DEFAULT '{}', revision INTEGER NOT NULL DEFAULT 1, deletedAt TEXT);
            CREATE TABLE secretary_notices(
                id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
                at REAL NOT NULL, read INTEGER NOT NULL DEFAULT 0, dismissed INTEGER NOT NULL DEFAULT 0);
            """),
    ]
}

enum Migrator {
    static func run(_ db: SQLiteDB, _ migrations: [Migration]) throws {
        let current = try db.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        if current > (migrations.last?.version ?? 0) {
            throw PVTAError("Dữ liệu này do một bản PVTA mới hơn tạo ra. Hãy cập nhật PVTA rồi mở lại.")
        }
        for m in migrations where m.version > current {
            // Mỗi bước nằm trong một giao dịch: lỗi thì dữ liệu giữ nguyên như trước.
            try db.transaction {
                try db.exec(m.sql)
                try db.exec("PRAGMA user_version = \(m.version)")
            }
        }
    }
}
