import Foundation

enum CalendarKind: String, Codable, Sendable { case event = "calendar", task = "tasks", note = "notes" }
struct CalendarAttachment: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var localPath: String
    var bytes: Int
    var sha256: String
    var mime: String
}
struct CalendarRecord: Codable, Sendable, Equatable {
    var localId: String
    var kind: CalendarKind
    var rev: Int
    var updatedAt: Double
    var deleted: Bool = false
    var data: JSONValue
    var attachments: [CalendarAttachment] = []
    var owner: String? = nil
}
struct CalendarState: Codable, Sendable {
    var revision = 0
    var records: [String: CalendarRecord] = [:]
}
struct CalendarMutation: Codable, Sendable {
    var id: String = UUID().uuidString
    var action: String
    var kind: CalendarKind
    var localId: String
    var baseRev: Int
    var data: JSONValue? = nil
    var attachment: CalendarAttachment? = nil
    var attachmentId: String? = nil
    var sourcePath: String? = nil
    var sourceHash: String? = nil
}
struct CalendarWriteResult: Codable, Sendable {
    var ok: Bool
    var revision: Int
    var records: [CalendarRecord] = []
    var reason: String? = nil
    var current: CalendarRecord? = nil
}
struct CalendarProposal: Codable, Sendable {
    var id: String = UUID().uuidString
    var revision: Int
    var reply: String
    var operations: [CalendarMutation]
    var conflicts: [CalendarOverlap]
    var expiresAt: Double
}
struct CalendarOverlap: Codable, Sendable, Equatable {
    var first: String
    var second: String
    var start: String
    var end: String
}
struct CalendarSlot: Codable, Sendable, Equatable { var start: String; var end: String }

enum CalendarValidation {
    static func integer(_ value: JSONValue?, name: String, minimum: Int = 0, maximum: Int = Int(Int32.max)) throws -> Int {
        guard let n = value?.number, n.isFinite, n.rounded() == n, n >= Double(minimum), n <= Double(maximum) else { throw PVTAError("\(name) phải là số nguyên từ \(minimum) đến \(maximum).") }
        return Int(n)
    }
    static func text(_ value: JSONValue?, name: String, max: Int, required: Bool = false) throws -> String? {
        guard let value, value != .null else { if required { throw PVTAError("Thiếu \(name).") }; return nil }
        guard let s = value.string, s.count <= max, !required || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PVTAError("\(name) không hợp lệ hoặc vượt \(max) ký tự.") }
        return s
    }
    static func identifier(_ value: String) throws {
        guard value.range(of: #"^[A-Za-z0-9_-]{1,120}$"#, options: .regularExpression) != nil else { throw PVTAError("Mã mục lịch không hợp lệ.") }
    }
    static func data(_ raw: JSONValue, kind: CalendarKind) throws -> JSONValue {
        guard case .object(let input) = raw else { throw PVTAError("Dữ liệu lịch phải là đối tượng.") }
        var out: [String: JSONValue] = [:]
        let title = kind == .event ? "summary" : "title"
        out[title] = .string(try text(input[title], name: "Tiêu đề", max: 1024, required: true)!)
        for key in kind == .event ? ["location", "description", "calendarId", "colorId"] : (kind == .note ? ["content"] : ["notes", "tasklistId"]) {
            if let s = try text(input[key], name: key, max: kind == .note ? 60000 : 8192) { out[key] = .string(s) }
        }
        if kind == .event {
            let zone = try text(input["timeZone"], name: "Múi giờ", max: 100) ?? "Asia/Ho_Chi_Minh"
            guard TimeZone(identifier: zone) != nil else { throw PVTAError("Múi giờ không hợp lệ.") }
            if let v = input["allDay"], v.bool == nil { throw PVTAError("allDay phải là true hoặc false.") }
            let allDay = input["allDay"]?.bool ?? false
            let start = try text(input["start"], name: "Bắt đầu", max: 40, required: true)!
            let end = try text(input["end"], name: "Kết thúc", max: 40, required: true)!
            let a = try CalendarDates.parse(start, allDay: allDay, zone: zone), b = try CalendarDates.parse(end, allDay: allDay, zone: zone)
            guard a < b, b.timeIntervalSince(a) <= 366 * 86400 else { throw PVTAError("Kết thúc phải sau bắt đầu, thời lượng tối đa một năm.") }
            out["start"] = .string(start); out["end"] = .string(end); out["allDay"] = .bool(allDay); out["timeZone"] = .string(zone)
            if let recurrence = input["recurrence"] {
                guard case .array(let list) = recurrence, list.count <= 1, list.allSatisfy({ $0.string != nil }) else { throw PVTAError("Chỉ nhận một quy tắc lặp hằng ngày hoặc hằng tuần.") }
                if let rule = list.first?.string { _ = try CalendarRepeat(rule) }
                out["recurrence"] = recurrence
            }
            if let v = input["remindersMinutes"] {
                guard case .array(let list) = v, list.count <= 10 else { throw PVTAError("Tối đa 10 mốc nhắc.") }
                for n in list { _ = try integer(n, name: "Phút nhắc", maximum: 40320) }; out["remindersMinutes"] = v
            }
        } else if kind == .task {
            if let due = try text(input["due"], name: "Hạn công việc", max: 10), !due.isEmpty { _ = try CalendarDates.parse(due, allDay: true); out["due"] = .string(due) }
            if let done = input["done"], done.bool == nil { throw PVTAError("done phải là true hoặc false.") }
            out["done"] = .bool(input["done"]?.bool ?? false)
        }
        let allowed = kind == .event ? Set(["summary", "location", "description", "calendarId", "colorId", "timeZone", "start", "end", "allDay", "recurrence", "remindersMinutes"]) : (kind == .note ? Set(["title", "content"]) : Set(["title", "notes", "tasklistId", "due", "done"]))
        guard Set(input.keys).isSubset(of: allowed) else { throw PVTAError("Có trường lịch chưa được hỗ trợ; không lưu bỏ sót dữ liệu.") }
        return .object(out)
    }
}

extension DataStore {
    func calendarState() throws -> CalendarState {
        guard let raw = try setting("calendar.v1") else { return CalendarState() }
        do { return try JSONDecoder().decode(CalendarState.self, from: Data(raw.utf8)) }
        catch { throw PVTAError("Kho lịch không đọc được; dữ liệu được giữ nguyên để khôi phục.") }
    }
    /// Kiểm phiên bản và ghi cả nhóm trong một giao dịch, không có await giữa đọc và ghi.
    func calendarCommit(_ changes: [CalendarMutation], revision: Int? = nil) throws -> CalendarWriteResult {
        try db.transaction {
            var state = try calendarState()
            if let revision, state.revision != revision { return CalendarWriteResult(ok: false, revision: state.revision, reason: "conflict") }
            guard !changes.isEmpty, changes.count <= 100 else { throw PVTAError("Mỗi lượt cần 1–100 thao tác lịch.") }
            var affected: [CalendarRecord] = []
            for change in changes {
                try CalendarValidation.identifier(change.localId)
                let old = state.records[change.localId]
                if old?.deleted == true { return CalendarWriteResult(ok: false, revision: state.revision, reason: "deleted", current: old) }
                if let old, old.kind != change.kind { throw PVTAError("Loại bản ghi không khớp.") }
                guard change.baseRev == (old?.rev ?? 0) else { return CalendarWriteResult(ok: false, revision: state.revision, reason: old == nil ? "not-found" : "conflict", current: old) }
                var record: CalendarRecord
                if let old { record = old }
                else {
                    guard change.action == "save", let data = change.data else { return CalendarWriteResult(ok: false, revision: state.revision, reason: "not-found") }
                    record = CalendarRecord(localId: change.localId, kind: change.kind, rev: 0, updatedAt: 0, data: data, owner: try setting("google.activeOwner").flatMap { $0.isEmpty ? nil : $0 })
                }
                switch change.action {
                case "save": guard let data = change.data else { throw PVTAError("Thiếu dữ liệu lịch.") }; record.data = try CalendarValidation.data(data, kind: change.kind)
                case "delete": record.deleted = true
                case "attach":
                    guard let attachment = change.attachment, record.attachments.count < 100 else { throw PVTAError("Thiếu đính kèm hoặc đã đủ 100 tệp.") }
                    record.attachments.append(attachment)
                case "detach":
                    guard let aid = change.attachmentId, record.attachments.contains(where: { $0.id == aid }) else { throw PVTAError("Không tìm thấy đính kèm.") }
                    record.attachments.removeAll { $0.id == aid }
                default: throw PVTAError("Thao tác lịch không được hỗ trợ.")
                }
                record.rev += 1; record.updatedAt = now().timeIntervalSince1970
                state.records[record.localId] = record; affected.append(record)
            }
            guard state.records.count <= 10000 else { throw PVTAError("Kho lịch đã đạt 10.000 mục.") }
            state.revision += 1
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try setSetting("calendar.v1", String(decoding: encoder.encode(state), as: UTF8.self))
            return CalendarWriteResult(ok: true, revision: state.revision, records: affected)
        }
    }
}
