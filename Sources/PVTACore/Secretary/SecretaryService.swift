import Foundation

/// Thư ký Sign: trợ lý riêng với model do người dùng chọn. Việc tôi giao, nhắc việc chủ động, bản tin đầu ngày,
/// tra cứu trên dữ liệu của PVTA, hỏi đáp, mẫu lệnh và `/sign "…"` chạy song song với chat (hội thoại riêng, khóa lượt riêng).
public actor SecretaryService {
    static let settingsKey = "secretary.settings", threadKey = "secretary.thread", briefingKey = "secretary.briefing"
    static let titleThread = "Thư ký Sign"

    let store: DataStore
    let chat: ChatLoop
    let files: FileService
    let screen: ScreenService
    let skills: SkillStore
    let notebooks: NotebookService
    let permissions: PermissionService
    let modelAsk: @Sendable (_ system: String, _ user: String, _ model: String?) async throws -> String
    let learn: @Sendable (String) async throws -> LearnReport
    let now: @Sendable () -> Date
    let changed: @Sendable (JSONValue) -> Void
    var index: (docs: [IndexDoc], at: Date)?
    var lastTick: Date?
    var imports: [String: SecretaryImportSnapshot] = [:]

    struct IndexDoc: Sendable { var id: String; var source: String; var title: String; var text: String; var at: Date?; var ref: String? }

    init(store: DataStore, chat: ChatLoop, files: FileService, screen: ScreenService, skills: SkillStore, notebooks: NotebookService,
         permissions: PermissionService, modelAsk: @escaping @Sendable (String, String, String?) async throws -> String,
         learn: @escaping @Sendable (String) async throws -> LearnReport, now: @escaping @Sendable () -> Date = { Date() }, changed: @escaping @Sendable (JSONValue) -> Void = { _ in }) {
        self.store = store; self.chat = chat; self.files = files; self.screen = screen; self.skills = skills; self.notebooks = notebooks
        self.permissions = permissions; self.modelAsk = modelAsk
        self.learn = learn; self.now = now; self.changed = changed
    }

    // MARK: Cài đặt

    public func settings() async throws -> SecretarySettings {
        guard let raw = try await store.setting(Self.settingsKey), let s = try? JSONDecoder().decode(SecretarySettings.self, from: Data(raw.utf8)) else { return SecretarySettings() }
        return s
    }

    @discardableResult
    public func saveSettings(_ input: JSONValue) async throws -> SecretarySettings {
        var s = try await settings()
        if let e = input["enabled"]?.bool { s.enabled = e }
        if let m = input["model"]?.string {
            guard m == "auto" || (m.contains("/") && m.count <= 200) else { throw PVTAError("Model của Thư ký là “auto” hoặc có dạng nhà-cung-cấp/model, ví dụ anthropic/claude-haiku-5-5.") }
            s.model = m
        }
        if case .object(let p)? = input["proactive"] {
            if let v = p["enabled"]?.bool { s.proactive.enabled = v }
            if let v = p["dailyPopup"]?.bool { s.proactive.dailyPopup = v }
            if let v = p["intervalMin"]?.number { guard v >= 1, v <= 1440, v.rounded() == v else { throw PVTAError("Chu kỳ nhắc từ 1 đến 1440 phút.") }; s.proactive.intervalMin = Int(v) }
            if let v = p["leadMinutes"]?.number { guard v >= 0, v <= 10080, v.rounded() == v else { throw PVTAError("Nhắc trước tối đa 10080 phút (một tuần).") }; s.proactive.leadMinutes = Int(v) }
        }
        if case .object(let src)? = input["sources"] {
            for (k, v) in src {
                guard SecretarySettings.sourceNames.contains(k) else { throw PVTAError("Nguồn “\(k)” không có (calendar, projects, notebooks, skills, chats).") }
                if let b = v.bool { s.sources[k] = b }
            }
            index = nil
        }
        try await store.setSetting(Self.settingsKey, String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
        changed(["method": "secretary.saveSettings"])
        return s
    }

    func sourceOn(_ s: SecretarySettings, _ name: String) -> Bool { s.sources[name] ?? false }

    // MARK: Việc tôi giao

    public func tasks() async throws -> [AssignedTask] { try await store.assignedTasks() }
    public func taskTrash() async throws -> [AssignedTask] { try await store.assignedTasks(trash: true) }

    private func conflict() -> PVTAError { PVTAError("TASK_CONFLICT: Công việc đã thay đổi hoặc đã bị xóa ở nơi khác. Bản nháp được giữ; hãy tải lại để đối chiếu trước khi lưu.") }

    private func dateTime(_ v: JSONValue, _ label: String) throws -> String {
        guard let s = v.string, s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              SecretaryCalendar.validDay(String(s.prefix(10))), let d = SecretaryCalendar.parseISO(s) else { throw PVTAError("\(label) không hợp lệ (cần dạng 2026-11-09T08:00:00+07:00).") }
        return ISO8601DateFormatter().string(from: d)
    }

    /// Thêm (không có `id`) hoặc sửa (có `id` và `revision` đúng) một việc. Trường không gửi thì giữ nguyên.
    @discardableResult
    public func saveTask(_ input: JSONValue) async throws -> AssignedTask {
        var old: AssignedTask?
        if let idv = input["id"] {
            guard let n = idv.number, n >= 1, n.rounded() == n, n < 9e15 else { throw PVTAError("Mã công việc không hợp lệ.") }
            old = try await store.assignedTask(id: Int(n))
            guard let o = old, o.deletedAt == nil, let r = input["revision"]?.number, Int(r) == o.revision else { throw conflict() }
        }
        guard let content = input["content"]?.string ?? old?.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 20_000 else {
            throw PVTAError("Nội dung công việc cần từ 1 đến 20.000 ký tự.")
        }
        var t = old ?? AssignedTask(id: 0, assignedAt: ISO8601DateFormatter().string(from: now()), content: "", deadline: nil, done: false, completedAt: nil, notes: nil, progress: nil, priority: nil,
                                    preparationDate: nil, category: nil, sourceStatus: nil, sourceRef: nil, nextAction: nil, schoolYear: nil, revision: 1, deletedAt: nil)
        t.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = input["assignedAt"] { t.assignedAt = try dateTime(v, "Ngày giờ giao") }
        if let v = input["deadline"] { t.deadline = v == .null || v.string == "" ? nil : try dateTime(v, "Hạn") }
        if let v = input["done"] { guard let b = v.bool else { throw PVTAError("Trạng thái không hợp lệ.") }; t.done = b }
        if let v = input["progress"] {
            if v == .null { t.progress = nil } else {
                guard let p = v.string, ["not-started", "in-progress", "completed"].contains(p) else { throw PVTAError("Tiến độ công việc không hợp lệ.") }
                t.progress = p
            }
        }
        if let v = input["priority"] {
            if v == .null { t.priority = nil } else {
                guard let p = v.string, ["low", "normal", "high"].contains(p) else { throw PVTAError("Mức ưu tiên công việc không hợp lệ.") }
                t.priority = p
            }
        }
        // Tiến độ và hoàn thành phải khớp: chỉ đổi một bên thì bên kia đi theo; đổi cả hai mà lệch nhau thì từ chối.
        let doneGiven = input["done"] != nil, progressGiven = input["progress"] != nil
        if progressGiven, !doneGiven, let p = t.progress { t.done = p == "completed" }
        else if doneGiven, !progressGiven { t.progress = t.done ? "completed" : (t.progress == "completed" ? "not-started" : t.progress) }
        else if doneGiven, progressGiven, let p = t.progress, t.done != (p == "completed") { throw PVTAError("Tiến độ và trạng thái hoàn thành không khớp.") }
        if let v = input["notes"] { if v == .null { t.notes = nil } else { guard let s = v.string, s.count <= 4000 else { throw PVTAError("Ghi chú tối đa 4.000 ký tự.") }; t.notes = s } }
        if let v = input["preparationDate"] {
            if v == .null { t.preparationDate = nil } else { guard let s = v.string, SecretaryCalendar.validDay(s) else { throw PVTAError("Ngày chuẩn bị không hợp lệ.") }; t.preparationDate = s }
        }
        if let v = input["category"] { guard let s = v.string, ["duty", "routine-teaching", "special-teaching"].contains(s) else { throw PVTAError("Loại công việc không hợp lệ.") }; t.category = s }
        if let v = input["sourceStatus"] { guard let s = v.string, ["documented", "assigned", "tentative"].contains(s) else { throw PVTAError("Trạng thái nguồn không hợp lệ.") }; t.sourceStatus = s }
        for (k, max) in [("sourceRef", 4000), ("nextAction", 4000), ("schoolYear", 100)] {
            guard let v = input[k] else { continue }
            guard let s = v.string, s.count <= max else { throw PVTAError("Thông tin “\(k)” không hợp lệ.") }
            switch k { case "sourceRef": t.sourceRef = s; case "nextAction": t.nextAction = s; default: t.schoolYear = s }
        }
        t.completedAt = t.done ? (old?.completedAt ?? ISO8601DateFormatter().string(from: now())) : nil
        let result: AssignedTask
        if let o = old {
            guard try await store.updateAssigned(t, expectedRevision: o.revision) else { throw conflict() }
            result = try await store.assignedTask(id: o.id)!
        } else {
            result = try await store.assignedTask(id: try await store.insertAssigned(t))!
        }
        changed(["method": "secretary.saveTask"])
        return result
    }

    /// Chuyển vào thùng rác (không xóa hẳn). Cần đúng phiên bản.
    public func deleteTask(id: Int, revision: Int) async throws {
        guard try await store.trashAssigned(id: id, revision: revision, at: ISO8601DateFormatter().string(from: now())) else { throw conflict() }
        changed(["method": "secretary.deleteTask"])
    }

    public func restoreTask(id: Int, revision: Int) async throws {
        guard try await store.restoreAssigned(id: id, revision: revision) else { throw conflict() }
        changed(["method": "secretary.restoreTask"])
    }

    // MARK: Nhắc việc chủ động

    static func hhmm(_ d: Date) -> String { let c = SecretaryCalendar.vn.dateComponents([.hour, .minute, .day, .month], from: d); return String(format: "%02d:%02d ngày %02d/%02d", c.hour ?? 0, c.minute ?? 0, c.day ?? 0, c.month ?? 0) }

    /// Tìm việc và sự kiện sắp đến hạn hoặc quá hạn, tạo thông báo (mỗi mốc một lần). Chạy theo chu kỳ; `force` bỏ qua chu kỳ.
    @discardableResult
    public func tick(force: Bool = false) async throws -> [SecretaryNotice] {
        let s = try await settings()
        guard s.enabled, s.proactive.enabled else { return [] }
        let t = now()
        if !force, let last = lastTick, t.timeIntervalSince(last) < Double(s.proactive.intervalMin) * 60 { return [] }
        lastTick = t
        let lead = Double(s.proactive.leadMinutes) * 60
        var cands: [(key: String, kind: String, title: String, body: String)] = []
        func add(_ key: String, _ kind: String, _ title: String, _ body: String) { cands.append((key, kind, title, body)) }
        for task in try await store.assignedTasks() where !task.done {
            guard let dl = task.deadline, let due = SecretaryCalendar.parseISO(dl) else { continue }
            let short = String(task.content.prefix(120))
            if due < t, t.timeIntervalSince(due) <= 7 * 86400 { add("task:\(task.id):\(dl):overdue", "overdue", "Việc đã quá hạn", "“\(short)” hạn \(Self.hhmm(due)) và chưa xong.") }
            else if due >= t, due.timeIntervalSince(t) <= lead { add("task:\(task.id):\(dl):soon", "task", "Việc sắp đến hạn", "“\(short)” hạn lúc \(Self.hhmm(due)).") }
        }
        if sourceOn(s, "calendar") {
            let records = try await store.calendarState().records.values.filter { !$0.deleted }
            for o in (try? CalendarSchedule.occurrences(Array(records), from: t, to: t.addingTimeInterval(lead))) ?? [] where o.start >= t {
                guard let r = records.first(where: { $0.localId == o.id }) else { continue }
                let loc = r.data["location"]?.string.map { " tại \($0)" } ?? ""
                add("event:\(o.id):\(Int(o.start.timeIntervalSince1970))", "upcoming", "Sắp đến giờ", "“\(r.data["summary"]?.string ?? "Sự kiện")” bắt đầu lúc \(Self.hhmm(o.start))\(loc).")
            }
            let today = SecretaryCalendar.day(t)
            for r in records where r.kind == .task && !(r.data["done"]?.bool ?? false) {
                guard let due = r.data["due"]?.string, SecretaryCalendar.validDay(due), due <= today else { continue }
                add("ctask:\(r.localId):\(due)", due < today ? "overdue" : "task", due < today ? "Việc trong lịch đã quá hạn" : "Việc trong lịch đến hạn hôm nay", "“\(r.data["title"]?.string ?? "Công việc")” hạn \(due).")
            }
        }
        var made: [SecretaryNotice] = []
        for c in cands {
            let n = SecretaryNotice(id: UUID().uuidString, key: c.key, kind: c.kind, title: c.title, body: c.body, at: t.timeIntervalSince1970, read: false, dismissed: false)
            if try await store.addNotice(n) { made.append(n) }
        }
        try await store.pruneNotices()
        if !made.isEmpty { changed(["method": "secretary.notices"]) }
        return made
    }

    public func notices(unreadOnly: Bool = false) async throws -> [SecretaryNotice] { try await store.notices(unreadOnly: unreadOnly) }
    public func markRead(_ ids: [String]) async throws { try await store.markNotices(ids: ids, read: true) }
    public func dismiss(_ ids: [String]) async throws { try await store.markNotices(ids: ids, dismissed: true) }

    // MARK: Bản tin đầu ngày

    private struct BriefingState: Codable { var shown: String?; var dismissedDay: String? }
    private func briefingState() async throws -> BriefingState {
        guard let raw = try await store.setting(Self.briefingKey), let s = try? JSONDecoder().decode(BriefingState.self, from: Data(raw.utf8)) else { return BriefingState() }
        return s
    }

    /// Bản tin tổng hợp từ dữ liệu có sẵn, không gọi AI hay mạng. Mục nào không có thì không hiện.
    public func briefing() async throws -> DailyBriefing {
        let s = try await settings(), st = try await briefingState()
        let t = now(), day = SecretaryCalendar.day(t), period = SecretaryCalendar.hour(t) < 12 ? "morning" : "afternoon"
        var weekEnd = SecretaryCalendar.vn.startOfDay(for: t)
        let weekday = SecretaryCalendar.vn.component(.weekday, from: t)               // 1 = Chủ nhật
        weekEnd = SecretaryCalendar.vn.date(byAdding: .day, value: (8 - weekday) % 7, to: weekEnd) ?? weekEnd
        let end = SecretaryCalendar.day(weekEnd)
        func section(_ days: [String?]) -> String {
            guard let action = days.compactMap({ $0 }).filter(SecretaryCalendar.validDay).min() else { return "upcoming" }
            return action <= day ? "today" : (action <= end ? "week" : "upcoming")
        }
        var items: [BriefingItem] = [], warnings: [String] = []
        for task in try await store.assignedTasks() {
            if task.done { guard let c = task.completedAt.flatMap(SecretaryCalendar.parseISO), SecretaryCalendar.day(c) == day else { continue } }
            let due = task.deadline.flatMap(SecretaryCalendar.parseISO)
            let sec = section([due.map(SecretaryCalendar.day), task.preparationDate])
            if task.category == "routine-teaching" && sec != "today" { continue }
            items.append(BriefingItem(id: "assigned:\(task.id)", kind: "task", title: task.content, detail: task.notes ?? "", start: task.deadline, location: nil, done: task.done,
                                      overdue: !task.done && (due.map { $0 < t } ?? false), section: sec, source: "Việc tôi giao"))
        }
        if sourceOn(s, "calendar") {
            let records = Array(try await store.calendarState().records.values.filter { !$0.deleted })
            let from = SecretaryCalendar.vn.startOfDay(for: t)
            for o in (try? CalendarSchedule.occurrences(records, from: from, to: from.addingTimeInterval(14 * 86400))) ?? [] {
                guard let r = records.first(where: { $0.localId == o.id }) else { continue }
                let d = SecretaryCalendar.day(o.start)
                items.append(BriefingItem(id: "event:\(o.id):\(Int(o.start.timeIntervalSince1970))", kind: "event", title: r.data["summary"]?.string ?? "Sự kiện", detail: r.data["description"]?.string ?? "",
                                          start: SecretaryCalendar.iso(o.start), location: r.data["location"]?.string, done: false, overdue: false, section: section([d]), source: "Lịch"))
            }
            for r in records where r.kind == .task && !(r.data["done"]?.bool ?? false) {
                let due = r.data["due"]?.string
                items.append(BriefingItem(id: "task:\(r.localId)", kind: "task", title: r.data["title"]?.string ?? "Công việc", detail: r.data["notes"]?.string ?? "", start: due, location: nil, done: false,
                                          overdue: due.map { $0 < day } ?? false, section: section([due]), source: "Công việc trong lịch"))
            }
        } else { warnings.append("Đang tắt nguồn Lịch nên bản tin không có sự kiện và việc trong lịch.") }
        let order = ["today": 0, "week": 1, "upcoming": 2]
        items.sort { (order[$0.section]!, $0.start ?? "~", $0.id) < (order[$1.section]!, $1.start ?? "~", $1.id) }
        let enabled = s.enabled && s.proactive.enabled && s.proactive.dailyPopup
        let key = "\(day):\(period)"
        return DailyBriefing(key: key, day: day, period: period, weekEnd: end, enabled: enabled, due: enabled && !items.isEmpty && st.shown != key && st.dismissedDay != day, items: items, warnings: warnings)
    }

    /// Chỉ khi cửa sổ bản tin thật sự hiện ra mới ghi nhận đã hiện ở buổi này.
    public func briefingShown(key: String) async throws {
        var st = try await briefingState(); st.shown = key
        try await store.setSetting(Self.briefingKey, String(decoding: try JSONEncoder().encode(st), as: UTF8.self))
    }

    public func dismissBriefing(day: String? = nil) async throws {
        var st = try await briefingState(); st.dismissedDay = day ?? SecretaryCalendar.day(now())
        try await store.setSetting(Self.briefingKey, String(decoding: try JSONEncoder().encode(st), as: UTF8.self))
    }
}
