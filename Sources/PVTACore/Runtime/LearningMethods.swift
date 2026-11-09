import Foundation

/// Phương thức `call` cho “Những điều đã học”. Điều chưa duyệt chỉ là bản nháp: không vào ngữ cảnh cho tới khi thầy cô duyệt.
extension Builtin {
    static func learningMethods() -> [(String, Core.Handler)] {
        @Sendable func changed(_ c: CallContext, _ name: String) { c.core.broadcast("data.changed", ["method": .string(name)]) }
        @Sendable func fileText(_ path: String, _ c: CallContext) async throws -> (String, String) {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return (url.lastPathComponent, try TextExtractor.extract(url).text)
        }
        return [
            ("learning.list", { c in
                let st = c.params["status"]?.string.flatMap(LearnedStatus.init)
                return try JSONValue(encoding: await c.core.learning.list(status: st))
            }),
            ("learning.detail", { c in
                let d = try await c.core.learning.detail(c.params.requireString("id"))
                return ["item": try JSONValue(encoding: d.item), "issues": try JSONValue(encoding: d.issues)]
            }),
            ("learning.learn", { c in
                let p = c.params
                let r = try await c.core.track(kind: "learning.learn") { () -> LearnReport in
                    if let chat = p["chatId"]?.string { return try await c.core.learning.learn(chatId: chat) }
                    if let path = p["path"]?.string { let (n, t) = try await fileText(path, c); return try await c.core.learning.learn(title: n, text: t) }
                    return try await c.core.learning.learn(title: p["title"]?.string ?? "Văn bản dán vào", text: p.requireString("text"))
                }
                changed(c, "learning.learn")
                return try JSONValue(encoding: r)
            }),
            ("learning.draftSkill", { c in
                let i = try await c.core.track(kind: "learning.draftSkill") { try await c.core.learning.draftSkill(group: c.params.requireString("group"), goal: c.params.requireString("goal")) }
                changed(c, "learning.draftSkill")
                return try JSONValue(encoding: i)
            }),
            ("learning.edit", { c in
                let i = try await c.core.learning.edit(c.params.requireString("id"), title: c.params["title"]?.string, body: c.params["body"]?.string)
                changed(c, "learning.edit")
                return try JSONValue(encoding: i)
            }),
            ("learning.approve", { c in try changedValue(c, try JSONValue(encoding: await c.core.learning.approve(c.params.requireString("id"))), "learning.approve") }),
            ("learning.enable", { c in
                try await c.core.learning.setEnabled(c.params.requireString("id"), c.params["enabled"]?.bool ?? true); changed(c, "learning.enable"); return .null
            }),
            ("learning.delete", { c in try await c.core.learning.delete(c.params.requireString("id")); changed(c, "learning.delete"); return .null }),
            ("learning.history", { c in
                let h = try await c.core.learning.history(c.params.requireString("id"))
                return .array(try h.map { ["id": .string($0.id), "at": .number($0.at), "item": try JSONValue(encoding: $0.item)] })
            }),
            ("learning.restore", { c in
                try changedValue(c, try JSONValue(encoding: await c.core.learning.restore(c.params.requireString("id"), historyId: c.params.requireString("historyId"))), "learning.restore")
            }),
            ("learning.export", { c in
                let d = try await c.core.learning.exportJSON()
                if let out = c.params["output"]?.string {
                    let dest = (out as NSString).expandingTildeInPath
                    try FileService.atomicWrite(d, to: dest, exclusive: true)
                    return ["path": .string(dest), "bytes": .number(Double(d.count))]
                }
                return ["data": .string(String(decoding: d, as: UTF8.self)), "bytes": .number(Double(d.count))]
            }),
            ("learning.import", { c in
                let data: Data
                if let t = c.params["data"]?.string { data = Data(t.utf8) }
                else { data = try Data(contentsOf: URL(fileURLWithPath: (c.params.requireString("path") as NSString).expandingTildeInPath)) }
                let r = try await c.core.learning.importJSON(data)
                changed(c, "learning.import")
                return try JSONValue(encoding: r)
            }),
            ("learning.rate", { c in
                try await c.core.learning.rateAnswer(chatId: c.params.requireString("chatId"), index: Int(c.params["index"]?.number ?? -1), rating: Int(c.params["rating"]?.number ?? 0), note: c.params["note"]?.string ?? "")
                return .null
            }),
            ("learning.schedule", { c in
                if let en = c.params["enabled"]?.bool { return try JSONValue(encoding: await c.core.learning.configure(enabled: en, intervalHours: c.params["intervalHours"]?.number.map { Int($0) })) }
                return try JSONValue(encoding: await c.core.learning.schedule())
            }),
            ("learning.refineNow", { c in try JSONValue(encoding: await c.core.track(kind: "learning.refine") { try await c.core.learning.refineNow() }) }),
            ("learning.stop", { c in await c.core.learning.stop(); return .null }),
            ("learning.catchUp", { c in try JSONValue(encoding: await c.core.track(kind: "learning.refine") { try await c.core.learning.tick() }) }),
            ("learning.sync", { c in try JSONValue(encoding: await c.core.learning.sync()) }),
        ]
    }

    private static func changedValue(_ c: CallContext, _ v: JSONValue, _ name: String) throws -> JSONValue {
        c.core.broadcast("data.changed", ["method": .string(name)])
        return v
    }
}
