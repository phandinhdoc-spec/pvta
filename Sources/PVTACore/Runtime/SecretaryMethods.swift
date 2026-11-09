import Foundation

extension Builtin {
    static func secretaryMethods() -> [(String, Core.Handler)] {
        @Sendable func changed(_ c: CallContext, _ n: String) { c.core.broadcast("data.changed", ["method": .string(n)]) }
        return [
            ("secretary.state", { c in try await c.core.secretary.state() }),
            ("secretary.saveSettings", { c in try JSONValue(encoding: await c.core.secretary.saveSettings(c.params)) }),
            ("secretary.ask", { c in
                let r = try await c.core.track(kind: "secretary.ask") { try await c.core.secretary.ask(c.params.requireString("text"), screenshot: c.params["screenshot"]?.bool ?? false, emit: c.emit) }
                return try JSONValue(encoding: r)
            }),
            ("secretary.sign", { c in
                let r = try await c.core.track(kind: "secretary.sign") { try await c.core.secretary.sign(c.params.requireString("text"), emit: c.emit) }
                return try JSONValue(encoding: r)
            }),
            ("secretary.commands", { c in try JSONValue(encoding: c.core.secretary.commandTemplates()) }),
            ("secretary.command", { c in
                var collected: [String: String] = [:]
                if case .object(let o)? = c.params["values"] { collected = o.compactMapValues(\.string) }
                let values = collected
                let r = try await c.core.track(kind: "secretary.command") { try await c.core.secretary.command(template: c.params.requireString("template"), values: values, screenshot: c.params["screenshot"]?.bool ?? false, emit: c.emit) }
                return try JSONValue(encoding: r)
            }),
            ("secretary.cancel", { c in .bool(await c.core.secretary.cancel()) }),
            ("secretary.thread", { c in .string(try await c.core.secretary.thread()) }),
            ("secretary.clearThread", { c in try await c.core.secretary.clearThread(); changed(c, "secretary.clearThread"); return .null }),
            ("secretary.tasks", { c in try JSONValue(encoding: await c.core.secretary.tasks()) }),
            ("secretary.saveTask", { c in try JSONValue(encoding: await c.core.secretary.saveTask(c.params)) }),
            ("secretary.deleteTask", { c in
                try await c.core.secretary.deleteTask(id: Int(c.params["id"]?.number ?? 0), revision: Int(c.params["revision"]?.number ?? 0)); return .null
            }),
            ("secretary.taskTrash", { c in try JSONValue(encoding: await c.core.secretary.taskTrash()) }),
            ("secretary.restoreTask", { c in
                try await c.core.secretary.restoreTask(id: Int(c.params["id"]?.number ?? 0), revision: Int(c.params["revision"]?.number ?? 0)); return .null
            }),
            ("secretary.briefing", { c in try JSONValue(encoding: await c.core.secretary.briefing()) }),
            ("secretary.briefingShown", { c in try await c.core.secretary.briefingShown(key: c.params.requireString("key")); return .null }),
            ("secretary.dismiss", { c in
                if case .array(let ids)? = c.params["ids"] { try await c.core.secretary.dismiss(ids.compactMap(\.string)) }
                else { try await c.core.secretary.dismissBriefing(day: c.params["day"]?.string) }
                return .null
            }),
            ("secretary.notices", { c in try JSONValue(encoding: await c.core.secretary.notices(unreadOnly: c.params["unreadOnly"]?.bool ?? false)) }),
            ("secretary.markRead", { c in
                if case .array(let ids)? = c.params["ids"] { try await c.core.secretary.markRead(ids.compactMap(\.string)) }
                return .null
            }),
            ("secretary.tick", { c in try JSONValue(encoding: await c.core.secretary.tick(force: c.params["force"]?.bool ?? false)) }),
            ("secretary.search", { c in
                var only: [String]?
                if case .array(let l)? = c.params["sources"] { only = l.compactMap(\.string) }
                return try JSONValue(encoding: await c.core.secretary.search(c.params.requireString("query"), sources: only))
            }),
            ("secretary.reindex", { c in try JSONValue(encoding: await c.core.secretary.reindex()) }),
            ("secretary.scan", { c in try JSONValue(encoding: await c.core.secretary.scan()) }),
            ("secretary.clearIndex", { c in await c.core.secretary.clearIndex(); return .null }),
            ("secretary.grants", { c in try JSONValue(encoding: await c.core.secretary.grants()) }),
            ("secretary.grant", { c in try JSONValue(encoding: await c.core.secretary.editGrant(c.params)) }),
            ("secretary.permissionDraft", { c in
                let d = try await c.core.track(kind: "secretary.permissionDraft") { try await c.core.secretary.permissionDraft(c.params.requireString("description")) }
                return try JSONValue(encoding: d)
            }),
            ("secretary.permissionDrafts", { c in try JSONValue(encoding: await c.core.secretary.permissionDrafts()) }),
            ("secretary.permissionConfirm", { c in
                guard let approve = c.params["approve"]?.bool else { throw PVTAError("Cần xác nhận rõ cấp hoặc từ chối quyền.") }
                return try JSONValue(encoding: await c.core.secretary.permissionConfirm(id: c.params.requireString("id"), approve: approve))
            }),
            ("secretary.approve", { c in
                let id = try c.params.requireString("id")
                if c.params["approve"]?.bool == false { try await c.core.permissions.queue.decline(id: id) }
                else { try await c.core.permissions.queue.approve(id: id, force: c.params["force"]?.bool ?? false) }
                return .null
            }),
            ("secretary.resolvePath", { c in
                let expected = c.params["expected"]?.string
                guard expected == nil || ["file", "directory"].contains(expected!) else { throw PVTAError("expected là file hoặc directory.") }
                let r = try c.core.secretary.resolvePath(c.params.requireString("path"), expected: expected)
                return ["path": .string(r.path), "kind": .string(r.kind)]
            }),
            ("secretary.read", { c in
                if case .array(let ids)? = c.params["ids"] { try await c.core.secretary.markRead(ids.compactMap(\.string)) }
                return .null
            }),
            ("secretary.readFile", { c in
                try await c.core.secretary.readFile(c.params.requireString("path"), start: c.params["start"]?.number.map(Int.init) ?? 0, limit: c.params["limit"]?.number.map(Int.init) ?? 12_000)
            }),
            ("secretary.departments", { c in try JSONValue(encoding: await c.core.secretary.departments()) }),
            ("secretary.department", { c in try await c.core.secretary.departmentCall(c.params.requireString("op"), c.params["args"] ?? [:]) }),
            ("secretary.import.prepare", { c in
                guard case .array(let a)? = c.params["paths"] else { throw PVTAError("Cần danh sách paths.") }
                return try JSONValue(encoding: await c.core.secretary.importPrepare(paths: a.compactMap(\.string)))
            }),
            ("secretary.import.confirm", { c in try JSONValue(encoding: await c.core.secretary.importConfirm(token: c.params.requireString("token"))) }),
            ("secretary.devStart", { c in
                guard case .object(let o) = c.params, Set(o.keys).isSubset(of: ["title", "request"]) else { throw PVTAError("devStart chỉ nhận title và request; các cổng kiểm tra không thể bỏ qua.") }
                return try JSONValue(encoding: await c.core.secretaryDev.start(title: c.params["title"]?.string ?? "", request: c.params.requireString("request")))
            }),
            ("secretary.devCancel", { c in .bool(await c.core.secretaryDev.cancel()) }),
            ("secretary.devRevert", { c in try JSONValue(encoding: await c.core.secretaryDev.revertLast()) }),
            ("secretary.devJobs", { c in try JSONValue(encoding: await c.core.secretaryDev.jobs()) }),
            ("secretary.devWait", { c in try JSONValue(encoding: await c.core.secretaryDev.wait()) }),
            ("secretary.learning.learn", { c in
                let r = try await c.core.track(kind: "secretary.learning") { try await c.core.secretary.learnFromThread() }
                return try JSONValue(encoding: r)
            }),
        ]
    }
}
