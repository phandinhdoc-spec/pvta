import Foundation

/// Phương thức `call` cho văn bản mới theo nhóm. Chỉ các lệnh tìm và tải mới đi ra mạng, và chỉ khi thầy cô bấm.
extension Builtin {
    static func docMethods() -> [(String, Core.Handler)] {
        @Sendable func strings(_ v: JSONValue?) -> [String] { if case .array(let a)? = v { return a.compactMap(\.string) }; return [] }
        @Sendable func changed(_ c: CallContext, _ name: String) { c.core.broadcast("data.changed", ["method": .string(name)]) }
        return [
            ("groups.discover", { c in
                let r = try await c.core.track(kind: "groups.discover") { try await c.core.docs.discover(group: c.params.requireString("id"), force: c.params["force"]?.bool ?? false) }
                changed(c, "groups.discover")
                return try JSONValue(encoding: r)
            }),
            ("groups.discoverEnabled", { c in
                let r = try await c.core.track(kind: "groups.discover") { try await c.core.docs.discoverEnabled(force: c.params["force"]?.bool ?? false) }
                changed(c, "groups.discover")
                return try JSONValue(encoding: r)
            }),
            ("groups.docs", { c in try JSONValue(encoding: await c.core.docs.documents(group: c.params["group"]?.string, includeHidden: c.params["includeHidden"]?.bool ?? false)) }),
            ("groups.addDocument", { c in
                let p = c.params
                let d = try await c.core.docs.addDocument(group: p.requireString("group"), title: p.requireString("title"), url: p["url"]?.string, no: p["no"]?.string)
                changed(c, "groups.addDocument")
                return try JSONValue(encoding: d)
            }),
            ("groups.download", { c in
                let d = try await c.core.track(kind: "groups.download") { try await c.core.docs.download(id: c.params.requireString("id"), confirmed: c.params["confirmed"]?.bool ?? false) }
                changed(c, "groups.download")
                return try JSONValue(encoding: d)
            }),
            ("groups.summaryEstimate", { c in
                let e = try await c.core.docs.estimateSummary(id: c.params.requireString("id"))
                return ["chars": .number(Double(e.chars)), "calls": .number(Double(e.calls)), "long": .bool(e.long), "truncated": .bool(e.truncated)]
            }),
            ("groups.summary", { c in
                let r = try await c.core.track(kind: "groups.summary") { try await c.core.docs.summarize(id: c.params.requireString("id"), confirmedLong: c.params["confirmed"]?.bool ?? false) }
                return try JSONValue(encoding: r)
            }),
            ("groups.markSeen", { c in try await c.core.docs.markSeen(strings(c.params["ids"])); changed(c, "groups.markSeen"); return .null }),
            ("groups.hide", { c in try await c.core.docs.hide(c.params.requireString("id"), c.params["hidden"]?.bool ?? true); changed(c, "groups.hide"); return .null }),
            ("groups.setStatus", { c in
                guard let s = DocStatus(rawValue: try c.params.requireString("status")) else { throw PVTAError("Tình trạng không hợp lệ.") }
                try await c.core.docs.setStatus(id: c.params.requireString("id"), s); changed(c, "groups.setStatus"); return .null
            }),
            ("groups.search", { c in
                let only = strings(c.params["groups"])
                return try JSONValue(encoding: await c.core.docs.search(c.params.requireString("query"), groups: only.isEmpty ? nil : only))
            }),
            ("groups.checkBasis", { c in try JSONValue(encoding: await c.core.docs.checkBasis(c.params.requireString("text"))) }),
            ("groups.alerts", { c in try JSONValue(encoding: await c.core.docs.alerts(for: c.params.requireString("text"))) }),
            ("groups.muteFinding", { c in try await c.core.docs.muteFinding(c.params.requireString("no")); return .null }),
            ("groups.unmuteAll", { c in try await c.core.docs.unmuteAll(); return .null }),
            ("groups.setAlerts", { c in try await c.core.docs.setAlerts(group: c.params.requireString("group"), on: c.params["on"]?.bool ?? true); return .null }),
            ("groups.offline", { c in
                if let on = c.params["on"]?.bool { try await c.core.docs.setOffline(on); changed(c, "groups.offline") }
                return .bool(try await c.core.docs.isOffline())
            }),
            ("groups.briefing", { c in try JSONValue(encoding: await c.core.docs.briefing(name: c.params["name"]?.string, proposals: Int(c.params["proposals"]?.number ?? 0))) }),
            ("groups.briefingShown", { c in try await c.core.docs.markBriefingShown(); return .null }),
            ("groups.briefingDismiss", { c in try await c.core.docs.dismissBriefing(); return .null }),
            ("groups.briefingEnabled", { c in try await c.core.docs.setBriefingEnabled(c.params["on"]?.bool ?? true); return .null }),
            ("groups.sources", { c in try JSONValue(encoding: await c.core.docs.sources()) }),
            ("groups.addSource", { c in
                let s = try await c.core.docs.addSource(name: c.params["name"]?.string ?? "", url: c.params.requireString("url"), kind: c.params["kind"]?.string ?? "page", groups: strings(c.params["groups"]))
                changed(c, "groups.addSource")
                return try JSONValue(encoding: s)
            }),
            ("groups.removeSource", { c in try await c.core.docs.removeSource(c.params.requireString("id")); changed(c, "groups.removeSource"); return .null }),
            ("groups.profile", { c in
                if let p = c.params["profile"] {
                    try await c.core.docs.setProfile(try JSONDecoder().decode(DiscoveryProfile.self, from: JSONEncoder().encode(p)))
                }
                return try JSONValue(encoding: await c.core.docs.profile())
            }),
            ("groups.reports", { c in try JSONValue(encoding: await c.core.docs.reports()) }),
        ]
    }
}
