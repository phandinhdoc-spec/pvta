import Foundation

extension Builtin {
    static func calendarMethods() -> [(String, Core.Handler)] {
        @Sendable func kind(_ p: JSONValue) throws -> CalendarKind {
            guard let value = p["kind"]?.string, let k = CalendarKind(rawValue: value) else { throw PVTAError("kind phải là calendar hoặc tasks.") }; return k
        }
        @Sendable func rev(_ p: JSONValue) throws -> Int { try CalendarValidation.integer(p["baseRev"], name: "baseRev") }
        @Sendable func data(_ p: JSONValue) throws -> JSONValue { guard let d = p["data"] else { throw PVTAError("Thiếu data.") }; return d }
        @Sendable func strings(_ p: JSONValue, _ key: String) throws -> [String] {
            guard let v = p[key] else { return [] }
            guard case .array(let a) = v, a.allSatisfy({ $0.string != nil }) else { throw PVTAError("\(key) phải là danh sách đường dẫn.") }; return a.compactMap(\.string)
        }
        func entry(_ name: String, _ handler: @escaping Core.Handler) -> (String, Core.Handler) { (name, handler) }
        var result: [(String, Core.Handler)] = [
            entry("calendar.listLocal", { c in try await c.core.calendar.list(includeDeleted: c.params["includeDeleted"]?.bool ?? false) }),
            entry("calendar.getRecord", { c in try JSONValue(encoding: await c.core.calendar.get(c.params.requireString("localId"), kind: kind(c.params))) }),
            entry("calendar.writeRev", { c in try JSONValue(encoding: await c.core.calendar.save(kind: kind(c.params), id: c.params["localId"]?.string, baseRev: rev(c.params), data: data(c.params))) }),
            entry("calendar.deleteRecord", { c in try JSONValue(encoding: await c.core.calendar.delete(kind: kind(c.params), id: c.params.requireString("localId"), baseRev: rev(c.params), confirmed: c.params["confirmed"]?.bool == true)) }),
            entry("calendar.resolveConflict", { c in try JSONValue(encoding: await c.core.calendar.resolve(kind: kind(c.params), id: c.params.requireString("localId"), baseRev: rev(c.params), choice: c.params.requireString("choice"), data: c.params["data"])) }),
            entry("calendar.addAttachment", { c in try JSONValue(encoding: await c.core.calendar.addAttachment(kind: kind(c.params), id: c.params.requireString("localId"), baseRev: rev(c.params), path: c.params.requireString("sourcePath"), chatId: c.params["chatId"]?.string)) }),
            entry("calendar.detachAttachment", { c in try JSONValue(encoding: await c.core.calendar.detach(kind: kind(c.params), id: c.params.requireString("localId"), baseRev: rev(c.params), attachmentId: c.params.requireString("attachmentId"))) }),
            entry("calendar.openAttachment", { c in try await c.core.calendar.attachmentPath(kind: kind(c.params), id: c.params.requireString("localId"), attachmentId: c.params.requireString("attachmentId")) }),
            entry("calendar.findFreeSlots", { c in try JSONValue(encoding: await c.core.calendar.freeSlots(from: c.params.requireString("start"), to: c.params.requireString("end"), minutes: c.params["minutes"] == nil ? 45 : CalendarValidation.integer(c.params["minutes"], name: "minutes", minimum: 1, maximum: 1440), zone: c.params["timeZone"]?.string ?? "Asia/Ho_Chi_Minh")) }),
            entry("calendar.conflicts", { c in try JSONValue(encoding: await c.core.calendar.conflicts(from: c.params.requireString("start"), to: c.params.requireString("end"), zone: c.params["timeZone"]?.string ?? "Asia/Ho_Chi_Minh")) }),
            entry("calendar.aiGetProposal", { c in try JSONValue(encoding: await c.core.calendar.proposal(c.params.requireString("proposalId"))) }),
            entry("calendar.aiCancel", { c in await c.core.calendar.cancelProposal(try c.params.requireString("proposalId")); return .null }),
            entry("calendar.aiApplyOps", { c in try JSONValue(encoding: await c.core.calendar.apply(c.params.requireString("proposalId"), approved: c.params["approved"]?.bool == true, allowConflicts: c.params["allowConflicts"]?.bool ?? false, chatId: c.params["chatId"]?.string)) }),
            entry("calendar.aiRevise", { c in
                guard case .array(let operations)? = c.params["operations"] else { throw PVTAError("Thiếu danh sách operations đã sửa.") }
                return try JSONValue(encoding: await c.core.calendar.revise(c.params.requireString("proposalId"), operations: operations, zone: c.params["timeZone"]?.string ?? "Asia/Ho_Chi_Minh", chatId: c.params["chatId"]?.string))
            })
        ]
        for k in [CalendarKind.event, .task] {
            result.append(entry(k == .event ? "calendar.saveEvent" : "calendar.saveTask", { c in
                let p = c.params
                return try JSONValue(encoding: await c.core.calendar.save(kind: k, id: p["localId"]?.string, baseRev: p["localId"] == nil && p["baseRev"] == nil ? 0 : rev(p), data: data(p)))
            }))
        }
        for scan in [false, true] {
            result.append(entry(scan ? "calendar.aiScanTimetable" : "calendar.aiCommand", { c in
                let p = c.params
                return try JSONValue(encoding: await c.core.calendar.command(prompt: p["prompt"]?.string ?? "", paths: strings(p, "paths"), rawText: p["rawText"]?.string ?? "", cursorDate: p["cursorDate"]?.string ?? p["weekStartDate"]?.string, zone: p["timeZone"]?.string ?? "Asia/Ho_Chi_Minh", scan: scan, repeatWeekly: p["repeatWeekly"]?.bool ?? scan, model: p["model"]?.string ?? "auto", chatId: p["chatId"]?.string))
            }))
        }
        return result
    }
}
