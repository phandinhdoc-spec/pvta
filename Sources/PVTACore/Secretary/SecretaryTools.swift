import Foundation

public struct SecretaryHit: Codable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var title: String
    public var snippet: String
    public var ref: String?
    public var score: Double
}

extension SecretaryService {
    static let indexTTL: TimeInterval = 60

    // MARK: Lớp tra cứu trên dữ liệu của PVTA

    func buildIndex() async throws -> [IndexDoc] {
        let s = try await settings()
        var docs: [IndexDoc] = []
        for t in try await store.assignedTasks() {
            docs.append(IndexDoc(id: "việc:\(t.id)", source: "tasks", title: t.content, text: [t.content, t.notes, t.done ? "đã xong" : "chưa xong", t.nextAction].compactMap { $0 }.joined(separator: " · "),
                                 at: t.deadline.flatMap(SecretaryCalendar.parseISO), ref: String(t.id)))
        }
        if sourceOn(s, "calendar") {
            for r in try await store.calendarState().records.values where !r.deleted {
                let d = r.data
                if r.kind == .event {
                    docs.append(IndexDoc(id: "lịch:\(r.localId)", source: "calendar", title: d["summary"]?.string ?? "Sự kiện", text: [d["summary"]?.string, d["location"]?.string, d["description"]?.string].compactMap { $0 }.joined(separator: " · "),
                                         at: d["start"]?.string.flatMap { try? CalendarDates.parse($0, allDay: d["allDay"]?.bool ?? false, zone: d["timeZone"]?.string ?? "Asia/Ho_Chi_Minh") }, ref: r.localId))
                } else {
                    docs.append(IndexDoc(id: "việc-lịch:\(r.localId)", source: "calendar", title: d["title"]?.string ?? "Công việc", text: [d["title"]?.string, d["notes"]?.string].compactMap { $0 }.joined(separator: " · "), at: nil, ref: r.localId))
                }
            }
        }
        if sourceOn(s, "projects") {
            for p in try await store.projects() {
                let folders = try await store.projectFolders(p.id).map { ($0.path as NSString).lastPathComponent }
                docs.append(IndexDoc(id: "dự-án:\(p.id)", source: "projects", title: p.name, text: ([p.name] + folders).joined(separator: " · "), at: nil, ref: p.id))
            }
        }
        if sourceOn(s, "notebooks") {
            for n in try await store.notebooks() {
                let titles = try await store.nbSources(notebook: n.id).filter(\.enabled).map(\.title)
                docs.append(IndexDoc(id: "sổ:\(n.id)", source: "notebooks", title: n.name, text: ([n.name] + titles).joined(separator: " · "), at: nil, ref: n.id))
            }
        }
        if sourceOn(s, "skills") {
            for k in await skills.list() where k.enabled { docs.append(IndexDoc(id: "skill:\(k.name)", source: "skills", title: "/" + k.name, text: "\(k.name) \(k.description)", at: nil, ref: k.name)) }
        }
        if sourceOn(s, "chats") {
            for c in try await store.chats() { docs.append(IndexDoc(id: "chat:\(c.id)", source: "chats", title: c.title, text: c.title, at: c.updatedAt, ref: c.id)) }
        }
        return docs
    }

    @discardableResult
    public func reindex() async throws -> [String: Int] {
        let docs = try await buildIndex()
        index = (docs, now())
        return Dictionary(docs.map { ($0.source, 1) }, uniquingKeysWith: +)
    }

    /// Số mục theo nguồn (dựng lại chỉ mục).
    public func scan() async throws -> [String: Int] { try await reindex() }

    public func clearIndex() { index = nil }

    nonisolated func indexStatsFrom(_ idx: (docs: [IndexDoc], at: Date)?) -> JSONValue {
        guard let idx else { return ["built": false, "docs": 0] }
        return ["built": true, "docs": .number(Double(idx.docs.count)), "at": .number(idx.at.timeIntervalSince1970)]
    }

    func indexStats() -> JSONValue { indexStatsFrom(index) }

    /// Tìm trong dữ liệu của PVTA (chỉ các nguồn đang cho phép), không phân biệt dấu. Chỉ mục tự làm mới sau 60 giây.
    public func search(_ query: String, sources only: [String]? = nil, limit: Int = 10) async throws -> [SecretaryHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 300 else { throw PVTAError("Nhập từ khóa cần tìm (tối đa 300 ký tự).") }
        if index == nil || now().timeIntervalSince(index!.at) > Self.indexTTL { _ = try await reindex() }
        let docs = index!.docs
        let byId = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ti = TextIndex(docs.map { .init(doc: $0.id, index: 0, title: $0.title, text: $0.text) })
        return ti.search(q, limit: limit * 3, allow: { id in only.map { $0.contains(byId[id]?.source ?? "") } ?? true }).prefix(limit).compactMap { h in
            byId[h.doc].map { SecretaryHit(id: $0.id, source: $0.source, title: $0.title, snippet: TextIndex.snippet(h.text, query: q, max: 240), ref: $0.ref, score: h.score) }
        }
    }

    // MARK: Công cụ cho Thư ký (chỉ có trong hội thoại của Thư ký)

    nonisolated var toolSpecs: [ToolSpec] {
        @Sendable func clip(_ s: String, _ n: Int = 160) -> String { String(s.prefix(n)) }
        return [
            ToolSpec(name: "sec_tasks", summary: "Danh sách việc tôi giao (kèm mã và phiên bản để sửa). Lọc: all, open, overdue, today, done.",
                     parameters: #"{"filter": "all|open|overdue|today|done (mặc định open)"}"#) { [self] a in
                let f = a["filter"]?.string ?? "open"
                guard ["all", "open", "overdue", "today", "done"].contains(f) else { throw PVTAError("filter là all, open, overdue, today hoặc done.") }
                let t = await now(), day = SecretaryCalendar.day(t)
                let all = try await tasks().filter { x in
                    let due = x.deadline.flatMap(SecretaryCalendar.parseISO)
                    switch f {
                    case "open": return !x.done
                    case "done": return x.done
                    case "overdue": return !x.done && (due.map { $0 < t } ?? false)
                    case "today": return !x.done && (due.map { SecretaryCalendar.day($0) <= day } ?? false)
                    default: return true
                    }
                }
                if all.isEmpty { return "Không có việc nào theo bộ lọc “\(f)”." }
                return all.prefix(50).map { "#\($0.id) r\($0.revision) [\($0.done ? "xong" : "chưa xong")] \(clip($0.content))" + ($0.deadline.map { " — hạn \($0)" } ?? "") + ($0.priority.map { " — ưu tiên \($0)" } ?? "") + ($0.notes.map { " — ghi chú: \(clip($0, 120))" } ?? "") }.joined(separator: "\n")
            },
            ToolSpec(name: "sec_calendar", summary: "Sự kiện lịch trong một khoảng ngày (cần nguồn Lịch đang bật).", parameters: #"{"from": "YYYY-MM-DD (mặc định hôm nay)", "to": "YYYY-MM-DD (mặc định 7 ngày sau)"}"#) { [self] a in
                guard try await settings().sources["calendar"] == true else { throw PVTAError("Nguồn Lịch đang tắt trong cài đặt Thư ký.") }
                let t = await now()
                let start = SecretaryCalendar.vn.startOfDay(for: t)
                func day(_ k: String, _ d: Date) throws -> Date {
                    guard let s = a[k]?.string else { return d }
                    guard SecretaryCalendar.validDay(s), let x = SecretaryCalendar.vn.date(from: DateComponents(year: Int(s.prefix(4)), month: Int(s.dropFirst(5).prefix(2)), day: Int(s.suffix(2)))) else { throw PVTAError("\(k) phải có dạng YYYY-MM-DD.") }
                    return x
                }
                let from = try day("from", start), to = try day("to", start.addingTimeInterval(7 * 86400)).addingTimeInterval(86400)
                guard to > from, to.timeIntervalSince(from) <= 62 * 86400 else { throw PVTAError("Khoảng ngày phải hợp lệ và tối đa 62 ngày.") }
                let records = Array(try await store.calendarState().records.values.filter { !$0.deleted })
                let occ = try CalendarSchedule.occurrences(records, from: from, to: to)
                if occ.isEmpty { return "Không có sự kiện nào trong khoảng này." }
                return occ.prefix(60).map { o in
                    let r = records.first { $0.localId == o.id }
                    return "\(Self.hhmm(o.start)) – \(r?.data["summary"]?.string ?? "Sự kiện")" + (r?.data["location"]?.string.map { " tại \($0)" } ?? "") + " [lịch:\(o.id)]"
                }.joined(separator: "\n")
            },
            ToolSpec(name: "sec_search", summary: "Tìm trong dữ liệu của PVTA (việc, lịch, dự án, sổ nguồn, kỹ năng… theo nguồn đang cho phép), không phân biệt dấu.",
                     parameters: #"{"query": "từ khóa", "sources": "danh sách nguồn (tùy chọn): tasks, calendar, projects, notebooks, skills, chats"}"#) { [self] a in
                guard let q = a["query"]?.string else { throw PVTAError("Thiếu tham số \"query\".") }
                var only: [String]?
                if case .array(let l)? = a["sources"] { only = l.compactMap(\.string) }
                let hits = try await search(q, sources: only)
                if hits.isEmpty { return "Không thấy gì khớp trong các nguồn đang cho phép. Không kết luận “không có” chỉ vì một lần tìm." }
                return hits.map { "[\($0.source)] \($0.title) — \($0.snippet) (\($0.id))" }.joined(separator: "\n")
            },
            ToolSpec(name: "sec_task_save", summary: "Giao việc mới (không có id) hoặc sửa một việc (có id và revision lấy từ sec_tasks). Cần thầy cô duyệt.",
                     parameters: #"{"id": "mã việc (khi sửa)", "revision": "phiên bản (khi sửa)", "content": "nội dung việc", "deadline": "hạn dạng 2026-11-09T17:00:00+07:00 hoặc null", "notes": "ghi chú", "priority": "low|normal|high", "done": "true/false"}"#,
                     access: .write, plan: { a in
                         let content = a["content"]?.string.map { String($0.prefix(200)) } ?? "(giữ nguyên nội dung)"
                         let isNew = a["id"] == nil
                         return ActionPlan(kind: .run, summary: isNew ? "Thư ký: giao việc “\(content)”" : "Thư ký: sửa việc #\(a["id"]?.number.map { String(Int($0)) } ?? "?")",
                                           preview: [a["deadline"]?.string.map { "Hạn: \($0)" }, a["priority"]?.string.map { "Ưu tiên: \($0)" }, a["notes"]?.string.map { "Ghi chú: \($0)" }, a["done"]?.bool.map { "Hoàn thành: \($0 ? "có" : "không")" }].compactMap { $0 }.joined(separator: "\n"), paths: [])
                     }) { [self] a in
                var input = a
                if case .object(var o) = a { o["chatId"] = nil; input = .object(o) }
                let t = try await saveTask(input)
                return "Đã lưu việc #\(t.id) (phiên bản \(t.revision)): \(t.content)" + (t.deadline.map { ", hạn \($0)" } ?? "")
            },
            ToolSpec(name: "sec_task_delete", summary: "Chuyển một việc vào thùng rác (khôi phục được). Cần id và revision từ sec_tasks. Cần thầy cô duyệt.",
                     parameters: #"{"id": "mã việc", "revision": "phiên bản"}"#, access: .write,
                     plan: { a in ActionPlan(kind: .run, summary: "Thư ký: chuyển việc #\(a["id"]?.number.map { String(Int($0)) } ?? "?") vào thùng rác", preview: "Có thể khôi phục từ thùng rác.", paths: []) }) { [self] a in
                guard let id = a["id"]?.number, let r = a["revision"]?.number else { throw PVTAError("Cần id và revision.") }
                try await deleteTask(id: Int(id), revision: Int(r))
                return "Đã chuyển việc #\(Int(id)) vào thùng rác."
            },
        ] + departmentToolSpecs()
    }
}
