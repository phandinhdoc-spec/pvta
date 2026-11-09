import Foundation
import Testing
@testable import PVTACore

private struct CalendarEnv {
    let root: URL
    let folder: URL
    let database: URL
    let core: Core
    let transport: FakeTransport
    let chat: String
    init(_ answers: [String] = []) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-test-" + UUID().uuidString)
        let paths = DataPaths(home: root.appendingPathComponent("data")); try paths.prepare(); database = paths.database
        folder = root.appendingPathComponent("files"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys = MemoryKeyStore(); try keys.save("test", provider: "anthropic")
        transport = FakeTransport(answers.map { FakeTransport.Reply(lines: claudeSSE([$0])) })
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: transport, retry: .none, cli: Gia().moi())
        core = Core(store: try DataStore(file: paths.database), ai: ai, screenHome: root)
        _ = try await core.permissions.addGrant(path: folder.path, write: true)
        chat = try await core.store.createChat().id
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func call(_ method: String, _ args: JSONValue = [:]) async throws -> JSONValue { try await core.dispatch(method, args, scoped: { _, _ in }) }
    func event(_ summary: String = "KHTN 8A", start: String = "2026-11-09T07:30:00+07:00", end: String = "2026-11-09T08:15:00+07:00") -> JSONValue {
        ["summary": .string(summary), "start": .string(start), "end": .string(end)]
    }
    func command(_ text: String = "Thêm lịch sáng thứ hai") async throws -> CalendarProposal {
        try await call("calendar.aiCommand", ["prompt": .string(text), "cursorDate": "2026-11-09", "model": "anthropic/claude-haiku-5-5", "chatId": .string(chat)]).decode(CalendarProposal.self)
    }
}

@Test func calendar31ThemSuaXoaSuKienVaViecCoPhienBan() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let created = try await e.call("calendar.saveEvent", ["data": e.event()]).decode(CalendarWriteResult.self)
    let event = try #require(created.records.first)
    #expect(created.ok && event.rev == 1 && !event.deleted)
    let changed = try await e.call("calendar.writeRev", ["kind": "calendar", "localId": .string(event.localId), "baseRev": 1, "data": e.event("KHTN 8B")]).decode(CalendarWriteResult.self)
    #expect(changed.ok && changed.records[0].rev == 2)
    let stale = try await e.call("calendar.saveEvent", ["localId": .string(event.localId), "baseRev": 1, "data": e.event("Bản cũ")]).decode(CalendarWriteResult.self)
    #expect(!stale.ok && stale.reason == "conflict" && stale.current?.data["summary"]?.string == "KHTN 8B")
    let task = try await e.call("calendar.saveTask", ["data": ["title": "Chấm bài", "due": "2026-11-10"]]).decode(CalendarWriteResult.self).records[0]
    let done = try await e.call("calendar.saveTask", ["localId": .string(task.localId), "baseRev": 1, "data": ["title": "Chấm bài 8A", "due": "2026-11-10", "done": true]]).decode(CalendarWriteResult.self)
    #expect(done.records[0].data["done"] == true)
    await #expect(throws: PVTAError.self) { try await e.call("calendar.deleteRecord", ["kind": "calendar", "localId": .string(event.localId), "baseRev": 2]) }
    for (kind, id) in [("calendar", event.localId), ("tasks", task.localId)] {
        let deleted = try await e.call("calendar.deleteRecord", ["kind": .string(kind), "localId": .string(id), "baseRev": 2, "confirmed": true]).decode(CalendarWriteResult.self)
        #expect(deleted.ok && deleted.records[0].deleted && deleted.records[0].rev == 3)
    }
    let list = try await e.call("calendar.listLocal")
    #expect(list["events"] == .array([]) && list["tasks"] == .array([]))
    let reopened = try DataStore(file: e.database)
    #expect(try await reopened.calendarState().records.count == 2)
    #expect(try await reopened.exportData().settings["calendar.v1"] != nil)
}

@Test func calendar31HaiCuaSoVaGiaiQuyetXungDotKhongGhiDeAmTham() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let r = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event()).records[0]
    async let a = e.core.calendar.save(kind: .event, id: r.localId, baseRev: 1, data: e.event("Cửa sổ A"))
    async let b = e.core.calendar.save(kind: .event, id: r.localId, baseRev: 1, data: e.event("Cửa sổ B"))
    let results = try await [a, b]
    #expect(results.filter(\.ok).count == 1)
    let conflict = try #require(results.first { !$0.ok })
    #expect(conflict.current?.rev == 2)
    let keep = try await e.core.calendar.resolve(kind: .event, id: r.localId, baseRev: 1, choice: "keep-current", data: nil)
    #expect(keep.records[0].rev == 2)
    let mine = try await e.core.calendar.resolve(kind: .event, id: r.localId, baseRev: 2, choice: "use-mine", data: e.event("Đã đối chiếu"))
    #expect(mine.ok && mine.records[0].rev == 3)
    let staleDelete = try await e.core.calendar.delete(kind: .event, id: r.localId, baseRev: 2, confirmed: true)
    #expect(!staleDelete.ok && staleDelete.reason == "conflict")
}

@Test func calendar31GiaoDichLoiKhongGhiMotPhan() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let changes = [CalendarMutation(action: "save", kind: .event, localId: "new-a", baseRev: 0, data: e.event()), CalendarMutation(action: "save", kind: .task, localId: "new-b", baseRev: 0, data: ["title": ""])]
    await #expect(throws: PVTAError.self) { try await e.core.store.calendarCommit(changes) }
    #expect(try await e.core.store.calendarState().revision == 0)
    #expect(try await e.core.store.calendarState().records.isEmpty)
    let existing = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event()).records[0]
    let conflict = try await e.core.store.calendarCommit([changes[0], CalendarMutation(action: "delete", kind: .event, localId: existing.localId, baseRev: 0)])
    #expect(!conflict.ok)
    #expect(try await e.core.store.calendarState().records["new-a"] == nil)
}

@Test func calendar31KiemNgayGioKhongNhanDuLieuSai() throws {
    #expect(throws: PVTAError.self) { try CalendarValidation.data(["summary": "Họp", "start": "2026-11-09T09:00:00+07:00", "end": "2026-11-09T08:00:00+07:00"], kind: .event) }
    #expect(throws: PVTAError.self) { try CalendarValidation.data(["title": "Việc", "due": "2026-02-30"], kind: .task) }
    #expect(throws: PVTAError.self) { try CalendarValidation.data(["title": "Việc", "done": "true"], kind: .task) }
    #expect(throws: PVTAError.self) { try CalendarRepeat("RRULE:FREQ=MONTHLY") }
    #expect(throws: PVTAError.self) { try CalendarRepeat("RRULE:FREQ=WEEKLY;INTERVAL=0") }
    #expect(throws: PVTAError.self) { try CalendarRepeat("RRULE:FREQ=WEEKLY;COUNT=2;UNTIL=20261120T000000Z") }
    #expect(throws: PVTAError.self) { try CalendarDates.parse("2026-11-09", allDay: true, zone: "Không có") }
}

@Test func calendar31TimKhoangTrongGopLichTrungVaBienTiepGiap() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    for (a, b) in [("08:00", "09:00"), ("08:30", "09:30"), ("09:30", "10:00")] {
        _ = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event(start: "2026-11-09T\(a):00+07:00", end: "2026-11-09T\(b):00+07:00"))
    }
    let slots = try await e.core.calendar.freeSlots(from: "2026-11-09T07:00:00+07:00", to: "2026-11-09T11:00:00+07:00", minutes: 45, zone: "Asia/Ho_Chi_Minh")
    #expect(slots == [CalendarSlot(start: "2026-11-09T00:00:00Z", end: "2026-11-09T01:00:00Z"), CalendarSlot(start: "2026-11-09T03:00:00Z", end: "2026-11-09T04:00:00Z")])
    let conflicts = try await e.core.calendar.conflicts(from: "2026-11-09", to: "2026-11-10", zone: "Asia/Ho_Chi_Minh")
    #expect(conflicts.count == 1)
}

@Test func calendar31LapTuanVaCaNgayVaMuiGio() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    _ = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: ["summary": "Tiết tuần", "start": "2026-11-02T07:30:00", "end": "2026-11-02T08:15:00", "recurrence": ["RRULE:FREQ=WEEKLY;COUNT=2"]])
    #expect(try await e.core.calendar.freeSlots(from: "2026-11-09T07:30:00", to: "2026-11-09T08:15:00", minutes: 45, zone: "Asia/Ho_Chi_Minh").isEmpty)
    #expect(try await e.core.calendar.freeSlots(from: "2026-11-16T07:30:00", to: "2026-11-16T08:15:00", minutes: 45, zone: "Asia/Ho_Chi_Minh").count == 1)
    _ = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: ["summary": "Nghỉ", "allDay": true, "start": "2026-11-10", "end": "2026-11-11"])
    #expect(try await e.core.calendar.freeSlots(from: "2026-11-10", to: "2026-11-11", minutes: 45, zone: "Asia/Ho_Chi_Minh").isEmpty)
    #expect(try await e.core.calendar.freeSlots(from: "2026-11-11", to: "2026-11-12", minutes: 45, zone: "Asia/Ho_Chi_Minh").count == 1)
    let data = try CalendarValidation.data(["summary": "Múi giờ", "start": "2026-03-07T09:00:00", "end": "2026-03-07T10:00:00", "timeZone": "America/New_York", "recurrence": ["RRULE:FREQ=DAILY;COUNT=3"]], kind: .event)
    let rec = CalendarRecord(localId: "dst", kind: .event, rev: 1, updatedAt: 0, data: data)
    let range = try CalendarDates.range("2026-03-07T00:00:00Z", "2026-03-10T00:00:00Z")
    let occurrences = try CalendarSchedule.occurrences([rec], from: range.0, to: range.1)
    #expect(occurrences.map { CalendarDates.iso($0.start) } == ["2026-03-07T14:00:00Z", "2026-03-08T13:00:00Z", "2026-03-09T13:00:00Z"])
}

@Test func calendar31DinhKemBanSaoGiuTepGocVaKiemRev() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let file = e.folder.appendingPathComponent("đề bài.txt"); try Data("Đề gốc".utf8).write(to: file)
    let event = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event()).records[0]
    let result = try await e.core.calendar.addAttachment(kind: .event, id: event.localId, baseRev: 1, path: file.path, chatId: e.chat)
    let attachment = try #require(result.records.first?.attachments.first)
    let stored = try await e.core.calendar.attachmentPath(kind: .event, id: event.localId, attachmentId: attachment.id).requireString("path")
    #expect(stored != file.path && attachment.sha256 == FileHash.of(Data("Đề gốc".utf8)))
    try Data("Đề mới".utf8).write(to: file)
    #expect(try String(contentsOfFile: stored, encoding: .utf8) == "Đề gốc")
    let stale = try await e.core.calendar.addAttachment(kind: .event, id: event.localId, baseRev: 1, path: file.path, chatId: e.chat)
    #expect(!stale.ok && stale.reason == "conflict")
    let detached = try await e.core.calendar.detach(kind: .event, id: event.localId, baseRev: 2, attachmentId: attachment.id)
    #expect(detached.records[0].attachments.isEmpty)
    #expect(FileManager.default.fileExists(atPath: stored) && FileManager.default.fileExists(atPath: file.path))
}

@Test func calendar31AIChiDeXuatDuyetMotLanVaKhongNhanLenhTuDo() async throws {
    let answer = #"{"reply":"Đề xuất tiết dạy và việc chấm bài","operations":[{"op":"create_event","summary":"KHTN 8A","date":"2026-11-09","periodId":"morning_p1"},{"op":"create_task","summary":"Chấm bài","due":"2026-11-10"}]}"#
    let e = try await CalendarEnv([answer]); defer { e.clean() }
    let proposal = try await e.command()
    #expect(proposal.operations.count == 2)
    #expect(try await e.core.store.calendarState().records.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.call("calendar.aiApplyOps", ["proposalId": .string(proposal.id), "approved": false]) }
    await #expect(throws: PVTAError.self) { try await e.call("calendar.aiApplyOps", ["proposalId": "giả", "approved": true, "operations": []]) }
    #expect(try await e.core.store.calendarState().revision == 0)
    let result = try await e.call("calendar.aiApplyOps", ["proposalId": .string(proposal.id), "approved": true]).decode(CalendarWriteResult.self)
    #expect(result.ok && result.records.count == 2)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(proposal.id, approved: true, allowConflicts: false, chatId: e.chat) }
}

@Test func calendar31DeXuatCuVaHuyKhongDuocGhi() async throws {
    let answer = #"{"reply":"Đề xuất việc","operations":[{"op":"create_task","summary":"Chấm bài"}]}"#
    let e = try await CalendarEnv([answer, answer]); defer { e.clean() }
    let old = try await e.command("Tạo việc chấm bài")
    _ = try await e.core.calendar.save(kind: .task, id: nil, baseRev: 0, data: ["title": "Việc mới ở cửa sổ khác"])
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(old.id, approved: true, allowConflicts: false, chatId: e.chat) }
    let canceled = try await e.command("Tạo việc")
    await e.core.calendar.cancelProposal(canceled.id)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(canceled.id, approved: true, allowConflicts: false, chatId: e.chat) }
    #expect(try await e.core.store.calendarState().records.count == 1)
}

@Test func calendar31LichTrungCanDoiChieuVaSuaDeXuat() async throws {
    let answer = #"{"reply":"Đề xuất lịch","operations":[{"op":"create_event","summary":"Họp","date":"2026-11-09","periodId":"morning_p1"}]}"#
    let e = try await CalendarEnv([answer]); defer { e.clean() }
    _ = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event())
    let p = try await e.command()
    #expect(p.conflicts.count == 1)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(p.id, approved: true, allowConflicts: false, chatId: e.chat) }
    let revised = try await e.core.calendar.revise(p.id, operations: [["op": "create_event", "summary": "Họp đã dời", "date": "2026-11-09", "periodId": "morning_p3"]], zone: "Asia/Ho_Chi_Minh", chatId: e.chat)
    #expect(revised.conflicts.isEmpty)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(p.id, approved: true, allowConflicts: true, chatId: e.chat) }
    #expect(try await e.core.calendar.apply(revised.id, approved: true, allowConflicts: false, chatId: e.chat).ok)
}

@Test func calendar31QuetAnhVaTepThanhBanNhapsKhongTuLuu() async throws {
    let answer = #"{"reply":"Quét được một tiết sáng thứ hai","operations":[{"op":"create_event","summary":"KHTN 8A","date":"2026-11-09","periodId":"morning_p2"}]}"#
    let e = try await CalendarEnv([answer]); defer { e.clean() }
    let text = e.folder.appendingPathComponent("tkb.txt"); try "Thứ hai: tiết 2 sáng, KHTN 8A".write(to: text, atomically: true, encoding: .utf8)
    let image = e.folder.appendingPathComponent("tkb.png")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/anh-do.png"), to: image)
    let p = try await e.call("calendar.aiScanTimetable", ["paths": [.string(text.path), .string(image.path)], "weekStartDate": "2026-11-09", "model": "anthropic/claude-haiku-5-5", "repeatWeekly": true]).decode(CalendarProposal.self)
    #expect(p.operations[0].data?["start"] == "2026-11-09T08:15:00")
    #expect(p.operations[0].data?["recurrence"] == ["RRULE:FREQ=WEEKLY"])
    #expect(try await e.core.store.calendarState().records.isEmpty)
    let request = try #require(e.transport.requests.first?.httpBody)
    let body = WorkExpression.text(try JSONDecoder().decode(JSONValue.self, from: request))
    #expect(body.contains("image/png"))
    #expect(body.contains("KHTN 8A"))
}

@Test func calendar31NguonThieuQuaDaiNgoaiPhamViKhongGoiAI() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let missing = e.folder.appendingPathComponent("mất.docx")
    await #expect(throws: PVTAError.self) { try await e.core.calendar.command(prompt: "Quét", paths: [missing.path], rawText: "", cursorDate: "2026-11-09", zone: "Asia/Ho_Chi_Minh", scan: true, repeatWeekly: false, model: "auto", chatId: e.chat) }
    let outside = e.root.appendingPathComponent("ngoài.txt"); try "Không được cấp".write(to: outside, atomically: true, encoding: .utf8)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.command(prompt: "Quét", paths: [outside.path], rawText: "", cursorDate: "2026-11-09", zone: "Asia/Ho_Chi_Minh", scan: true, repeatWeekly: false, model: "auto", chatId: e.chat) }
    let huge = e.folder.appendingPathComponent("dài.txt"); try String(repeating: "a", count: 20001).write(to: huge, atomically: true, encoding: .utf8)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.command(prompt: "Quét", paths: [huge.path], rawText: "", cursorDate: "2026-11-09", zone: "Asia/Ho_Chi_Minh", scan: true, repeatWeekly: false, model: "auto", chatId: e.chat) }
    #expect(e.transport.requests.isEmpty)
}

@Test func calendar31AIDeXuatSaiKhongLuuMotPhan() async throws {
    let answer = #"{"reply":"Đề xuất","operations":[{"op":"create_task","summary":"Việc hợp lệ"},{"op":"delete_event","eventId":"không-có"}]}"#
    let e = try await CalendarEnv([answer]); defer { e.clean() }
    await #expect(throws: PVTAError.self) { try await e.command() }
    #expect(try await e.core.store.calendarState().records.isEmpty)
}

@Test func calendar31QuetKhongLapKhongChoAIBatLapThay() async throws {
    let answer = #"{"reply":"Tiết học","operations":[{"op":"create_event","summary":"KHTN","date":"2026-11-09","periodId":"morning_p1","recurrence":["RRULE:FREQ=WEEKLY"]}]}"#
    let e = try await CalendarEnv([answer]); defer { e.clean() }
    let p = try await e.call("calendar.aiScanTimetable", ["rawText": "Thứ hai tiết 1 sáng KHTN", "weekStartDate": "2026-11-09", "repeatWeekly": false, "model": "anthropic/claude-haiku-5-5"]).decode(CalendarProposal.self)
    #expect(p.operations[0].data?["recurrence"] == .array([]))
}

@Test func calendar31AIHoanThanhSuaXoaDungMaMuc() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let event = try await e.core.calendar.save(kind: .event, id: nil, baseRev: 0, data: e.event()).records[0]
    let task = try await e.core.calendar.save(kind: .task, id: nil, baseRev: 0, data: ["title": "Chấm bài"]).records[0]
    let snapshot = try await e.core.store.calendarState()
    let p = try await e.core.calendar.makeProposal([["op": "move_event", "eventId": .string(event.localId), "start": "2026-11-09T09:30:00+07:00", "end": "2026-11-09T10:15:00+07:00"], ["op": "complete_task", "taskId": .string(task.localId)]], reply: "Dời và hoàn thành", snapshot: snapshot, zone: "Asia/Ho_Chi_Minh", chatId: e.chat)
    #expect(try await e.core.calendar.get(event.localId, kind: .event).rev == 1)
    let applied = try await e.core.calendar.apply(p.id, approved: true, allowConflicts: false, chatId: e.chat)
    #expect(applied.ok && applied.records.count == 2)
    #expect(try await e.core.calendar.get(task.localId, kind: .task).data["done"] == true)
    #expect(try await e.core.calendar.get(event.localId, kind: .event).data["summary"] == "KHTN 8A")
    let removal = try await e.core.calendar.makeProposal([["op": "delete_event", "eventId": .string(event.localId)], ["op": "delete_task", "taskId": .string(task.localId)]], reply: "Xóa", snapshot: e.core.store.calendarState(), zone: "Asia/Ho_Chi_Minh", chatId: e.chat)
    #expect(try await e.core.calendar.apply(removal.id, approved: true, allowConflicts: false, chatId: e.chat).ok)
    #expect(try await e.core.calendar.get(event.localId, kind: .event).deleted)
}

@Test func calendar31AIDinhKemDoiTepSauDuyetThiChan() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let file = e.folder.appendingPathComponent("bài.txt"); try "Bản một".write(to: file, atomically: true, encoding: .utf8)
    let task = try await e.core.calendar.save(kind: .task, id: nil, baseRev: 0, data: ["title": "Soạn bài"]).records[0]
    let op: JSONValue = ["op": "attach_file", "taskId": .string(task.localId), "filePath": .string(file.path)]
    let p = try await e.core.calendar.makeProposal([op], reply: "Gắn tệp", snapshot: e.core.store.calendarState(), zone: "Asia/Ho_Chi_Minh", chatId: e.chat)
    #expect(try await e.core.calendar.get(task.localId, kind: .task).attachments.isEmpty)
    try "Bản hai".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: PVTAError.self) { try await e.core.calendar.apply(p.id, approved: true, allowConflicts: false, chatId: e.chat) }
    #expect(try await e.core.calendar.get(task.localId, kind: .task).attachments.isEmpty)
    let new = try await e.core.calendar.revise(p.id, operations: [op], zone: "Asia/Ho_Chi_Minh", chatId: e.chat)
    #expect(try await e.core.calendar.apply(new.id, approved: true, allowConflicts: false, chatId: e.chat).records[0].attachments.count == 1)
}

@Test func calendar31KhoHongVaDuongDanDinhKemKhongThoatRaNgoai() async throws {
    let e = try await CalendarEnv(); defer { e.clean() }
    let r = try await e.core.calendar.save(kind: .task, id: nil, baseRev: 0, data: ["title": "Việc"]).records[0]
    let bad = CalendarAttachment(id: "bad", name: "Sai", localPath: "../../ngoai.txt", bytes: 1, sha256: "hash", mime: "text/plain")
    _ = try await e.core.store.calendarCommit([CalendarMutation(action: "attach", kind: .task, localId: r.localId, baseRev: 1, attachment: bad)])
    await #expect(throws: PVTAError.self) { try await e.core.calendar.attachmentPath(kind: .task, id: r.localId, attachmentId: "bad") }
    try await e.core.store.setSetting("calendar.v1", "{hỏng")
    await #expect(throws: PVTAError.self) { try await e.core.calendar.save(kind: .task, id: nil, baseRev: 0, data: ["title": "Không ghi đè kho hỏng"]) }
    #expect(try await e.core.store.setting("calendar.v1") == "{hỏng")
}
