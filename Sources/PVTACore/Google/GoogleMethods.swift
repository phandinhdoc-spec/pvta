import Foundation

extension Builtin {
    static func googleMethods() -> [(String, Core.Handler)] {
        func entry(_ name: String, _ handler: @escaping Core.Handler) -> (String, Core.Handler) { (name, handler) }
        var methods: [(String, Core.Handler)] = [
            entry("google.configure", { c in
                try await c.core.google.auth.configure(clientId: c.params.requireString("clientId"), secret: c.params["clientSecret"]?.string)
                return try await c.core.google.status()
            }),
            entry("google.login", { c in try await c.core.google.auth.begin(confirmed: c.params["confirmed"]?.bool == true) }),
            entry("google.cancelLogin", { c in await c.core.google.auth.cancelLogin(); return .null }),
            entry("google.logout", { c in try await c.core.google.auth.logout(); return try await c.core.google.status() }),
            entry("google.status", { c in try await c.core.google.status() }),
            entry("google.syncStatus", { c in try await c.core.google.status() }),
            entry("google.catalogs", { c in try await c.core.google.catalogs() }),
            entry("google.select", { c in
                try await c.core.google.select(calendarId: c.params["calendarId"]?.string, tasklistId: c.params["tasklistId"]?.string, notes: c.params["notes"]?.bool ?? false, enabled: c.params["enabled"]?.bool ?? false, confirmed: c.params["confirmed"]?.bool == true)
            }),
            entry("google.syncNow", { c in try await c.core.google.sync(confirmed: c.params["confirmed"]?.bool == true) }),
            entry("google.resolveConflict", { c in
                try await c.core.google.resolve(id: c.params.requireString("localId"), baseRev: CalendarValidation.integer(c.params["baseRev"], name: "baseRev"), stamp: c.params.requireString("remoteStamp"), choice: c.params.requireString("choice"), confirmed: c.params["confirmed"]?.bool == true)
            }),
            entry("google.retryPendingCreate", { c in try await c.core.google.retryCreate(id: c.params.requireString("localId"), confirmed: c.params["confirmed"]?.bool == true); return try await c.core.google.status() }),
            entry("google.saveNote", { c in
                guard let data = c.params["data"] else { throw PVTAError("Thiếu nội dung ghi chú.") }
                return try JSONValue(encoding: await c.core.calendar.save(kind: .note, id: c.params["localId"]?.string, baseRev: c.params["localId"] == nil && c.params["baseRev"] == nil ? 0 : CalendarValidation.integer(c.params["baseRev"], name: "baseRev"), data: data))
            }),
            entry("google.deleteNote", { c in try JSONValue(encoding: await c.core.calendar.delete(kind: .note, id: c.params.requireString("localId"), baseRev: CalendarValidation.integer(c.params["baseRev"], name: "baseRev"), confirmed: c.params["confirmed"]?.bool == true)) }),
            entry("google.listNotes", { c in try await c.core.calendar.list(includeDeleted: c.params["includeDeleted"]?.bool ?? false)["notes"] ?? .array([]) })
        ]
        // Dùng đúng cổng đề xuất/duyệt của nhiệm vụ 31, không có đường AI ghi thẳng Google.
        methods += calendarMethods().filter { $0.0.hasPrefix("calendar.ai") }.map { ($0.0.replacingOccurrences(of: "calendar.", with: "google."), $0.1) }
        return methods
    }
}
