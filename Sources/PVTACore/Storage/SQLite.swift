import Foundation
import SQLite3

enum SQLValue {
    case text(String), int(Int64), double(Double), null
}

struct Row {
    let stmt: OpaquePointer
    func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
    func optText(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i) }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
}

/// Lớp mỏng quanh SQLite. Lỗi kỹ thuật được đổi thành thông báo tiếng Việt.
final class SQLiteDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw PVTAError("PVTA không mở được tệp dữ liệu tại \(path). Hãy kiểm tra quyền truy cập thư mục.")
        }
        sqlite3_busy_timeout(handle, 5000)
        // WAL để CLI và Desktop cùng đọc ghi; bật khóa ngoại để xóa dây chuyền đúng.
        try exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close(handle) }

    private func failure() -> PVTAError {
        switch sqlite3_errcode(handle) {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return PVTAError("Dữ liệu đang được tiến trình PVTA khác sử dụng. Hãy thử lại sau ít giây.")
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return PVTAError("Tệp dữ liệu của PVTA bị hỏng. Hãy khôi phục từ bản sao lưu.")
        default:
            return PVTAError("PVTA không đọc hoặc ghi được dữ liệu. Hãy kiểm tra dung lượng ổ đĩa và quyền ghi.")
        }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    /// Chạy một câu lệnh ghi, trả về số dòng bị tác động.
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(map(Row(stmt: stmt)))
            case SQLITE_DONE: return out
            default: throw failure()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
