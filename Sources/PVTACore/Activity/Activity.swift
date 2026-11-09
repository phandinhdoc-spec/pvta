import Foundation

public enum ActivityState: String, Codable, Sendable {
    case running, done, error, interrupted
}

/// Một dòng nhật ký hoạt động: tác vụ, kết quả hoặc lỗi. Không chứa nội dung hội thoại.
public struct Activity: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var chatId: String?
    public var projectId: String?
    public var model: String?
    public var state: ActivityState
    public var startedAt: Date
    public var endedAt: Date?
    public var detail: String?
}

extension DataStore {
    static let activityDetailLimit = 6000
    static let activityKeep = 2000

    private static func activity(_ r: Row) -> Activity {
        Activity(id: r.text(0), kind: r.text(1), chatId: r.optText(2), projectId: r.optText(3), model: r.optText(4),
                 state: ActivityState(rawValue: r.text(5)) ?? .error,
                 startedAt: Date(timeIntervalSince1970: r.double(6)),
                 endedAt: r.optText(7).map { _ in Date(timeIntervalSince1970: r.double(7)) },
                 detail: r.optText(8))
    }

    public func startActivity(kind: String, chatId: String? = nil, projectId: String? = nil, model: String? = nil) throws -> String {
        let id = UUID().uuidString
        try db.run("INSERT INTO activities(id, kind, chatId, projectId, model, state, startedAt) VALUES(?,?,?,?,?,?,?)",
                   [.text(id), .text(kind), chatId.map { .text($0) } ?? .null, projectId.map { .text($0) } ?? .null,
                    model.map { .text($0) } ?? .null, .text(ActivityState.running.rawValue),
                    .double(now().timeIntervalSince1970)])
        return id
    }

    /// Ghi kết quả. Chi tiết luôn được che khóa/token trước khi lưu.
    public func finishActivity(id: String, state: ActivityState, detail: String? = nil) throws {
        let clean = detail.map { String(Redactor.clean($0).prefix(Self.activityDetailLimit)) }
        try db.run("UPDATE activities SET state = ?, endedAt = ?, detail = ? WHERE id = ?",
                   [.text(state.rawValue), .double(now().timeIntervalSince1970), clean.map { .text($0) } ?? .null, .text(id)])
    }

    /// Mới nhất trước.
    public func activities(projectId: String? = nil, limit: Int = 500) throws -> [Activity] {
        try db.query("""
            SELECT id, kind, chatId, projectId, model, state, startedAt, endedAt, detail FROM activities
            WHERE (? IS NULL OR projectId = ?) ORDER BY startedAt DESC, seq DESC LIMIT ?
            """, [projectId.map { .text($0) } ?? .null, projectId.map { .text($0) } ?? .null, .int(Int64(limit))],
            Self.activity)
    }

    /// Gọi khi tiến trình giữ dữ liệu khởi động: tác vụ còn "đang chạy" của lần trước đã bị ngắt;
    /// đồng thời bỏ bớt dòng quá cũ để nhật ký không phình mãi.
    public func recoverActivities() throws {
        try db.run("UPDATE activities SET state = 'interrupted', endedAt = ?, detail = ? WHERE state = 'running'",
                   [.double(now().timeIntervalSince1970), .text("Ứng dụng đã đóng trước khi ghi nhận kết quả.")])
        try db.run("DELETE FROM activities WHERE seq <= (SELECT MAX(seq) FROM activities) - ?", [.int(Int64(Self.activityKeep))])
    }
}
