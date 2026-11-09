import Foundation

enum CalendarDates {
    static func calendar(_ zone: String) throws -> Calendar {
        guard let tz = TimeZone(identifier: zone) else { throw PVTAError("Múi giờ không hợp lệ.") }
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; c.locale = Locale(identifier: "en_US_POSIX"); c.firstWeekday = 2
        return c
    }
    static func parse(_ text: String, allDay: Bool = false, zone: String = "Asia/Ho_Chi_Minh") throws -> Date {
        let c = try calendar(zone)
        let formats = allDay ? ["yyyy-MM-dd"] : ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        for format in formats {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = c; f.timeZone = c.timeZone; f.isLenient = false; f.dateFormat = format
            if let date = f.date(from: text) {
                // DateFormatter có thể chấp nhận ngày ngắn hoặc phần đuôi; kiểm tra lại định dạng.
                if allDay { if f.string(from: date) == text { return date } }
                else if text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{3})?)?(?:Z|[+-]\d{2}:\d{2})?$"#, options: .regularExpression) != nil { return date }
            }
        }
        throw PVTAError("Ngày/giờ không hợp lệ: \(text). Dùng YYYY-MM-DD hoặc ISO-8601.")
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func day(_ date: Date, zone: String) throws -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = try calendar(zone); f.timeZone = f.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func range(_ start: String, _ end: String, zone: String = "Asia/Ho_Chi_Minh") throws -> (Date, Date) {
        let a = try parse(start, allDay: start.count == 10, zone: zone), b = try parse(end, allDay: end.count == 10, zone: zone)
        guard a < b, b.timeIntervalSince(a) <= 366 * 86400 else { throw PVTAError("Khoảng tìm lịch phải lớn hơn không và tối đa 366 ngày.") }
        return (a, b)
    }
}
struct CalendarRepeat {
    var days: Int
    var count: Int?
    var until: Date?
    init(_ rule: String) throws {
        guard rule.hasPrefix("RRULE:") else { throw PVTAError("Quy tắc lặp cần bắt đầu RRULE:.") }
        var fields: [String: String] = [:]
        for pair in rule.dropFirst(6).split(separator: ";", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, fields[String(parts[0])] == nil else { throw PVTAError("Quy tắc lặp không hợp lệ.") }
            fields[String(parts[0])] = String(parts[1])
        }
        guard Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL", "COUNT", "UNTIL"]), ["DAILY", "WEEKLY"].contains(fields["FREQ"] ?? "") else { throw PVTAError("Hiện hỗ trợ RRULE DAILY/WEEKLY với INTERVAL, COUNT hoặc UNTIL; không bỏ qua quy tắc khác.") }
        let interval = Int(fields["INTERVAL"] ?? "1") ?? 0
        guard (1...52).contains(interval) else { throw PVTAError("Khoảng lặp từ 1 đến 52.") }
        days = interval * (fields["FREQ"] == "WEEKLY" ? 7 : 1)
        if let raw = fields["COUNT"] {
            guard let n = Int(raw), (1...1000).contains(n), fields["UNTIL"] == nil else { throw PVTAError("COUNT từ 1 đến 1000, không dùng cùng UNTIL.") }; count = n
        }
        if let raw = fields["UNTIL"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.isLenient = false
            guard let date = f.date(from: raw), f.string(from: date) == raw else { throw PVTAError("UNTIL cần dạng UTC yyyyMMddTHHmmssZ.") }; until = date
        }
    }
}
struct CalendarOccurrence: Sendable { var id: String; var start: Date; var end: Date }
enum CalendarSchedule {
    static func occurrences(_ records: [CalendarRecord], from: Date, to: Date) throws -> [CalendarOccurrence] {
        var out: [CalendarOccurrence] = []
        for r in records where !r.deleted && r.kind == .event {
            let d = r.data, allDay = d["allDay"]?.bool ?? false, zone = d["timeZone"]?.string ?? "Asia/Ho_Chi_Minh"
            let calendar = try CalendarDates.calendar(zone)
            let a = try CalendarDates.parse(d.requireString("start"), allDay: allDay, zone: zone), b = try CalendarDates.parse(d.requireString("end"), allDay: allDay, zone: zone)
            var rule: CalendarRepeat?
            if case .array(let rules)? = d["recurrence"], let raw = rules.first?.string { rule = try CalendarRepeat(raw) }
            let daysLong = calendar.dateComponents([.day], from: a, to: b).day ?? 1
            let elapsed = calendar.dateComponents([.day], from: a, to: from.addingTimeInterval(-b.timeIntervalSince(a))).day ?? 0
            var index = rule.map { max(0, elapsed / $0.days - 1) } ?? 0
            while true {
                if let count = rule?.count, index >= count { break }
                guard let start = calendar.date(byAdding: .day, value: index * (rule?.days ?? 0), to: a) else { throw PVTAError("Ngày lặp vượt giới hạn.") }
                if start >= to || (rule?.until.map { start > $0 } ?? false) { break }
                let end = allDay ? calendar.date(byAdding: .day, value: daysLong, to: start)! : start.addingTimeInterval(b.timeIntervalSince(a))
                if start < to && end > from { out.append(CalendarOccurrence(id: r.localId, start: start, end: end)) }
                guard out.count <= 10000 else { throw PVTAError("Khoảng xem có quá 10.000 lần xuất hiện; hãy chọn khoảng ngắn hơn.") }
                guard rule != nil else { break }; index += 1
            }
        }
        return out.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    static func overlaps(_ records: [CalendarRecord], from: Date, to: Date, touching: Set<String>? = nil) throws -> [CalendarOverlap] {
        let all = try occurrences(records, from: from, to: to); var out: [CalendarOverlap] = []
        for (i, a) in all.enumerated() {
            for b in all.dropFirst(i + 1) {
                if b.start >= a.end { break }
                if a.id == b.id || (touching != nil && !touching!.contains(a.id) && !touching!.contains(b.id)) { continue }
                out.append(CalendarOverlap(first: a.id, second: b.id, start: CalendarDates.iso(max(a.start, b.start)), end: CalendarDates.iso(min(a.end, b.end))))
                guard out.count <= 1000 else { throw PVTAError("Có quá nhiều lịch trùng; hãy chia nhỏ phạm vi xử lý.") }
            }
        }
        return out
    }
    static func freeSlots(_ records: [CalendarRecord], from: Date, to: Date, minutes: Int) throws -> [CalendarSlot] {
        guard (1...1440).contains(minutes) else { throw PVTAError("Thời lượng cần tìm từ 1 đến 1.440 phút.") }
        let busy = try occurrences(records, from: from, to: to); var cursor = from; var out: [CalendarSlot] = []
        for item in busy {
            let start = max(from, item.start), end = min(to, item.end)
            if start.timeIntervalSince(cursor) >= Double(minutes * 60) { out.append(CalendarSlot(start: CalendarDates.iso(cursor), end: CalendarDates.iso(start))) }
            cursor = max(cursor, end)
        }
        if to.timeIntervalSince(cursor) >= Double(minutes * 60) { out.append(CalendarSlot(start: CalendarDates.iso(cursor), end: CalendarDates.iso(to))) }
        return out
    }
}
