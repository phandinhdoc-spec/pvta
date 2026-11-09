import Foundation

struct GoogleAPI: Sendable {
    let auth: GoogleAuth
    let owner: String
    static func segment(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var u = URLComponents(string: path)!
        u.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return u.url!
    }
    func request(_ path: String, query: [String: String] = [:], method: String = "GET", json: JSONValue? = nil, etag: String? = nil) async throws -> GoogleReply {
        try await auth.request(owner: owner, url: Self.url(path, query), method: method, body: json.map { try JSONEncoder().encode($0) }, etag: etag)
    }
    func collections(kind: CalendarKind) async throws -> [JSONValue] {
        let path = kind == .event ? "https://www.googleapis.com/calendar/v3/users/me/calendarList" : "https://tasks.googleapis.com/tasks/v1/users/@me/lists"
        var result: [JSONValue] = [], page: String?, visited = Set<String>()
        repeat {
            var q = ["maxResults": "100"]; if let page { q["pageToken"] = page }
            let v = try await request(path, query: q).json
            guard case .array(let items)? = v["items"] else { throw PVTAError("Google trả danh sách không hợp lệ.") }
            for item in items {
                if kind == .event, !["owner", "writer"].contains(item["accessRole"]?.string ?? "") { continue }
                result.append(["id": .string(try item.requireString("id")), "title": .string(item[kind == .event ? "summary" : "title"]?.string ?? "Không tên")])
            }
            page = v["nextPageToken"]?.string
            if let page { guard visited.insert(page).inserted, visited.count <= 100 else { throw PVTAError("Phân trang danh sách Google không hợp lệ.") } }
        } while page != nil
        return result
    }
    func path(_ kind: CalendarKind, _ collection: String, id: String? = nil) -> String {
        let base: String
        switch kind {
        case .event: base = "https://www.googleapis.com/calendar/v3/calendars/\(Self.segment(collection))/events"
        case .task: base = "https://tasks.googleapis.com/tasks/v1/lists/\(Self.segment(collection))/tasks"
        case .note: base = "https://www.googleapis.com/drive/v3/files"
        }
        return base + (id.map { "/" + Self.segment($0) } ?? "")
    }
    static let noteFields = "id,name,trashed,modifiedTime,appProperties,mimeType"
    func list(kind: CalendarKind, collection: String, cursor: String?) async throws -> (items: [GoogleRemoteItem], cursor: String?, full: Bool) {
        var result: [GoogleRemoteItem] = [], page: String?, visited = Set<String>(), next: String?
        repeat {
            var q: [String: String]
            switch kind {
            case .event:
                q = ["maxResults": "250", "showDeleted": "true", "singleEvents": "false"]
                if let cursor { q["syncToken"] = cursor }
            case .task: q = ["maxResults": "100", "showDeleted": "true", "showHidden": "true", "showCompleted": "true"]
            case .note: q = ["pageSize": "100", "q": "appProperties has { key='pvtaKind' and value='note' }", "fields": "nextPageToken,files(\(Self.noteFields))"]
            }
            if let page { q["pageToken"] = page }
            let value: JSONValue
            do { value = try await request(path(kind, collection), query: q).json }
            catch let error as GoogleHTTPError where kind == .event && error.status == 410 && cursor != nil {
                return try await list(kind: kind, collection: collection, cursor: nil)
            }
            guard case .object = value else { throw PVTAError("Google trả danh sách không hợp lệ; chưa cập nhật dữ liệu cục bộ.") }
            let key = kind == .note ? "files" : "items"
            let items: [JSONValue]
            if case .array(let a)? = value[key] { items = a } else if value[key] == nil { items = [] } else { throw PVTAError("Google trả danh sách mục không hợp lệ.") }
            for item in items {
                // Calendar có thể trả tombstone của lần lặp riêng. Không biến thành sự kiện gốc.
                if kind == .event, item["recurringEventId"] != nil { throw PVTAError("Lịch có lần lặp đã sửa riêng; chưa thể biểu diễn đầy đủ trong PVTA.") }
                if kind == .note {
                    let id = try item.requireString("id")
                    result.append(try await get(kind: kind, collection: collection, id: id))
                } else { result.append(try decode(item, kind: kind, etag: item["etag"]?.string)) }
            }
            guard result.count <= 10000 else { throw PVTAError("Google có quá 10.000 mục; chưa cập nhật mốc đồng bộ.") }
            page = value["nextPageToken"]?.string; next = value["nextSyncToken"]?.string
            if let page { guard visited.insert(page).inserted, visited.count <= 1000 else { throw PVTAError("Google trả vòng phân trang; chưa cập nhật mốc.") } }
        } while page != nil
        if kind == .event && next == nil { throw PVTAError("Google chưa trả mốc đồng bộ cuối; dữ liệu cũ được giữ.") }
        return (result, next, kind != .event || cursor == nil)
    }
    func decode(_ v: JSONValue, kind: CalendarKind, etag: String?) throws -> GoogleRemoteItem {
        let id = try v.requireString("id")
        let deleted = v["deleted"]?.bool == true || v["status"]?.string == "cancelled" || v["trashed"]?.bool == true
        if deleted { return GoogleRemoteItem(id: id, data: .null, deleted: true, etag: etag) }
        var data: [String: JSONValue] = [:]; var hint: String?
        switch kind {
        case .event:
            let allDay = v["start"]?["date"] != nil
            data = ["summary": .string(v["summary"]?.string ?? "(Không có tiêu đề)"), "start": v["start"]?[allDay ? "date" : "dateTime"] ?? .null, "end": v["end"]?[allDay ? "date" : "dateTime"] ?? .null, "allDay": .bool(allDay), "timeZone": v["start"]?["timeZone"] ?? "Asia/Ho_Chi_Minh"]
            for key in ["location", "description", "colorId", "recurrence"] { if let x = v[key] { data[key] = x } }
            if case .array(let reminders)? = v["reminders"]?["overrides"] {
                data["remindersMinutes"] = .array(reminders.filter { $0["method"]?.string == "popup" }.compactMap { $0["minutes"] })
            }
            hint = v["extendedProperties"]?["private"]?["pvtaLocalId"]?.string
        case .task:
            data = ["title": .string(v["title"]?.string ?? "(Không có tiêu đề)"), "done": .bool(v["status"]?.string == "completed")]
            if let due = v["due"]?.string { data["due"] = .string(String(due.prefix(10))) }
            if let notes = v["notes"]?.string {
                if let m = WorkProgram.match(#"(?s)^(.*)\n\[PVTA-ID:([A-Za-z0-9_-]+)\]$"#, notes) { data["notes"] = .string(m[0]); hint = m[1] }
                else { data["notes"] = .string(notes) }
            }
        case .note: throw PVTAError("Ghi chú cần metadata và nội dung tệp.")
        }
        return GoogleRemoteItem(id: id, data: try CalendarValidation.data(.object(data), kind: kind), etag: etag, localHint: hint)
    }
    func get(kind: CalendarKind, collection: String, id: String) async throws -> GoogleRemoteItem {
        do {
            let r = try await request(path(kind, collection, id: id), query: kind == .note ? ["fields": Self.noteFields] : [:])
            if kind != .note { return try decode(r.json, kind: kind, etag: r.json["etag"]?.string ?? r.headers["etag"]) }
            guard r.json["appProperties"]?["pvtaKind"]?.string == "note" else { throw PVTAError("Tệp Drive không phải ghi chú PVTA; không ghi đè.") }
            if r.json["trashed"]?.bool == true { return GoogleRemoteItem(id: id, data: .null, deleted: true, etag: r.headers["etag"]) }
            let content = try await request(path(kind, collection, id: id), query: ["alt": "media"])
            guard let text = String(data: content.bytes, encoding: .utf8), text.count <= 60000 else { throw PVTAError("Ghi chú Drive không phải UTF-8 hoặc quá 60.000 ký tự.") }
            // Đọc lại metadata tránh ghép tiêu đề cũ với nội dung đang đổi.
            let check = try await request(path(kind, collection, id: id), query: ["fields": Self.noteFields])
            guard check.headers["etag"] == r.headers["etag"], check.json["modifiedTime"] == r.json["modifiedTime"] else { throw PVTAError("Ghi chú Drive đang đổi; thử đồng bộ lại.") }
            let name = r.json["name"]?.string ?? "Ghi chú"
            let data: JSONValue = ["title": .string(name.hasSuffix(".md") ? String(name.dropLast(3)) : name), "content": .string(text)]
            return GoogleRemoteItem(id: id, data: try CalendarValidation.data(data, kind: .note), etag: r.headers["etag"], localHint: r.json["appProperties"]?["pvtaLocalId"]?.string)
        } catch let e as GoogleHTTPError where e.status == 404 || e.status == 410 { return GoogleRemoteItem(id: id, data: .null, deleted: true) }
    }
    func allocate(_ link: GoogleLink) async throws -> String? {
        if link.kind == .event { return "pvta" + link.creationId.lowercased().replacingOccurrences(of: "-", with: "") }
        if link.kind == .note {
            let v = try await request("https://www.googleapis.com/drive/v3/files/generateIds", query: ["count": "1", "space": "drive", "type": "files"]).json
            guard case .array(let a)? = v["ids"], let id = a.first?.string else { throw PVTAError("Google chưa cấp mã tệp ghi chú.") }; return id
        }
        return nil
    }
    func payload(_ record: CalendarRecord) throws -> JSONValue {
        let d = record.data; var out: [String: JSONValue] = [:]
        if record.kind == .event {
            let allDay = d["allDay"]?.bool ?? false
            for key in ["summary", "location", "description", "recurrence"] { out[key] = d[key] ?? (key == "recurrence" ? .array([]) : .string("")) }
            out["colorId"] = d["colorId"] ?? .null
            for key in ["start", "end"] {
                if allDay { out[key] = ["date": d[key]!] }
                else { out[key] = ["dateTime": .string(CalendarDates.iso(try CalendarDates.parse(d.requireString(key), zone: d["timeZone"]?.string ?? "Asia/Ho_Chi_Minh"))), "timeZone": d["timeZone"] ?? "Asia/Ho_Chi_Minh"] }
            }
            if case .array(let minutes)? = d["remindersMinutes"] { out["reminders"] = ["useDefault": false, "overrides": .array(minutes.map { ["method": "popup", "minutes": $0] })] }
            else { out["reminders"] = ["useDefault": true] }
            out["extendedProperties"] = ["private": ["pvtaLocalId": .string(record.localId)]]
        } else {
            let notes = (d["notes"]?.string ?? "") + "\n[PVTA-ID:\(record.localId)]"
            out = ["title": d["title"]!, "notes": .string(notes), "status": .string(d["done"]?.bool == true ? "completed" : "needsAction"), "due": d["due"]?.string.map { .string($0 + "T00:00:00Z") } ?? .null]
        }
        return .object(out)
    }
    func write(_ record: CalendarRecord, link: GoogleLink, create: Bool) async throws -> GoogleRemoteItem {
        if record.deleted {
            guard let id = link.remoteId else { throw PVTAError("Chưa biết mã Google để xóa.") }
            do {
                if record.kind == .note { _ = try await request(path(.note, "", id: id), method: "PATCH", json: ["trashed": true], etag: link.etag) }
                else { _ = try await request(path(record.kind, link.collection, id: id), method: "DELETE", etag: link.etag) }
            } catch let e as GoogleHTTPError where e.status == 404 || e.status == 410 { }
            return GoogleRemoteItem(id: id, data: .null, deleted: true)
        }
        if record.kind == .note {
            guard let id = link.remoteId else { throw PVTAError("Chưa cấp mã ghi chú Drive.") }
            var meta: JSONValue = ["name": .string(try record.data.requireString("title") + ".md"), "mimeType": "text/markdown", "appProperties": ["pvtaKind": "note", "pvtaLocalId": .string(record.localId)]]
            if create, case .object(var o) = meta { o["id"] = .string(id); meta = .object(o) }
            let boundary = "pvta-" + UUID().uuidString
            let data = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8) + (try JSONEncoder().encode(meta)) + Data("\r\n--\(boundary)\r\nContent-Type: text/markdown; charset=UTF-8\r\n\r\n\(record.data["content"]?.string ?? "")\r\n--\(boundary)--\r\n".utf8)
            let endpoint = "https://www.googleapis.com/upload/drive/v3/files" + (create ? "" : "/" + Self.segment(id))
            _ = try await auth.request(owner: owner, url: Self.url(endpoint, ["uploadType": "multipart", "fields": Self.noteFields]), method: create ? "POST" : "PATCH", body: data, contentType: "multipart/related; boundary=\(boundary)", etag: create ? nil : link.etag)
            return try await get(kind: .note, collection: "", id: id)
        }
        var body = try payload(record)
        if create, record.kind == .event, case .object(var o) = body { o["id"] = link.remoteId.map(JSONValue.string); body = .object(o) }
        let r = try await request(path(record.kind, link.collection, id: create ? nil : link.remoteId), method: create ? "POST" : "PATCH", json: body, etag: create ? nil : link.etag)
        return try decode(r.json, kind: record.kind, etag: r.json["etag"]?.string ?? r.headers["etag"])
    }
}
