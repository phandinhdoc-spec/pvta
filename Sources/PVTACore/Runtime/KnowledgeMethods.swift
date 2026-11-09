import Foundation

/// Phương thức `call` cho sổ nguồn, dự án (thư mục nguồn và Học hỏi), tra cứu mã và hướng dẫn.
extension Builtin {
    static func knowledgeMethods() -> [(String, Core.Handler)] {
        @Sendable func changed(_ c: CallContext, _ name: String) { c.core.broadcast("data.changed", ["method": .string(name)]) }
        return [
            // Sổ nguồn
            ("nb.list", { c in try JSONValue(encoding: await c.core.notebooks.list()) }),
            ("nb.create", { c in
                let n = try await c.core.notebooks.create(name: c.params.requireString("name"), model: c.params["model"]?.string); changed(c, "nb.create"); return try JSONValue(encoding: n)
            }),
            ("nb.rename", { c in try await c.core.notebooks.rename(c.params.requireString("id"), name: c.params.requireString("name")); changed(c, "nb.rename"); return .null }),
            ("nb.delete", { c in try await c.core.notebooks.delete(c.params.requireString("id")); changed(c, "nb.delete"); return .null }),
            ("nb.setModel", { c in try await c.core.notebooks.setModel(c.params.requireString("id"), model: c.params["model"]?.string); changed(c, "nb.setModel"); return .null }),
            ("nb.sources", { c in try JSONValue(encoding: await c.core.notebooks.sources(c.params.requireString("id"))) }),
            ("nb.addFile", { c in
                let s = try await c.core.track(kind: "nb.addFile") { try await c.core.notebooks.addFile(c.params.requireString("id"), path: c.params.requireString("path"), chatId: c.params["chatId"]?.string) }
                changed(c, "nb.addFile"); return try JSONValue(encoding: s)
            }),
            ("nb.addURL", { c in
                let s = try await c.core.track(kind: "nb.addURL") { try await c.core.notebooks.addURL(c.params.requireString("id"), url: c.params.requireString("url")) }
                changed(c, "nb.addURL"); return try JSONValue(encoding: s)
            }),
            ("nb.toggle", { c in try await c.core.notebooks.setEnabled(c.params.requireString("sourceId"), c.params["enabled"]?.bool ?? true); changed(c, "nb.toggle"); return .null }),
            ("nb.removeSource", { c in try await c.core.notebooks.removeSource(c.params.requireString("sourceId")); changed(c, "nb.removeSource"); return .null }),
            ("nb.refresh", { c in
                let r = try await c.core.track(kind: "nb.refresh") { try await c.core.notebooks.refresh(c.params.requireString("id"), sourceId: c.params["sourceId"]?.string) }
                changed(c, "nb.refresh"); return try JSONValue(encoding: r)
            }),
            ("nb.clearIndex", { c in try await c.core.track(kind: "nb.clearIndex") { try await c.core.notebooks.clearIndex(c.params.requireString("id")) }; changed(c, "nb.clearIndex"); return .null }),
            ("nb.search", { c in
                let r = try await c.core.notebooks.search(c.params.requireString("id"), query: c.params.requireString("query"), limit: Int(c.params["limit"]?.number ?? 8))
                return .array(r.map { ["sourceId": .string($0.source.id), "title": .string($0.source.title), "text": .string($0.text)] })
            }),
            ("nb.ask", { c in
                let r = try await c.core.track(kind: "nb.ask") { try await c.core.notebooks.ask(c.params.requireString("id"), question: c.params.requireString("question"), askId: c.params["askId"]?.string ?? UUID().uuidString) }
                return try JSONValue(encoding: r)
            }),
            ("nb.setLinks", { c in
                var ids: [String] = []
                if case .array(let a)? = c.params["notebookIds"] { ids = a.compactMap(\.string) }
                let r = try await c.core.notebooks.setLinks(scope: c.params.requireString("scope"), id: c.params.requireString("id"), notebookIds: ids)
                changed(c, "nb.setLinks"); return .array(r.map { .string($0) })
            }),
            ("nb.links", { c in .array(try await c.core.notebooks.links(scope: c.params.requireString("scope"), id: c.params.requireString("id")).map { .string($0) }) }),
            ("nb.cancel", { c in await c.core.notebooks.cancel(try c.params.requireString("askId")); return .null }),

            // Dự án
            ("project.connectFolder", { c in
                let r = try await c.core.track(kind: "project.connectFolder", projectId: c.params["projectId"]?.string) {
                    try await c.core.projects.connectFolder(c.params.requireString("projectId"), path: c.params.requireString("path"), role: c.params["role"]?.string ?? "source")
                }
                changed(c, "project.connectFolder")
                return ["folder": try JSONValue(encoding: r.folder), "report": try JSONValue(encoding: r.report)]
            }),
            ("project.addFile", { c in
                let d = try await c.core.projects.addFile(c.params.requireString("projectId"), path: c.params.requireString("path"), role: c.params["role"]?.string ?? "source")
                changed(c, "project.addFile"); return try JSONValue(encoding: d)
            }),
            ("project.reread", { c in
                let r = try await c.core.track(kind: "project.reread", projectId: c.params["projectId"]?.string) { try await c.core.projects.reread(c.params.requireString("projectId")) }
                changed(c, "project.reread"); return try JSONValue(encoding: r)
            }),
            ("project.unlinkFolder", { c in try await c.core.projects.unlinkFolder(c.params.requireString("folderId")); changed(c, "project.unlinkFolder"); return .null }),
            ("project.removeDoc", { c in try await c.core.projects.removeDoc(c.params.requireString("docId"), projectId: c.params.requireString("projectId")); changed(c, "project.removeDoc"); return .null }),
            ("project.overview", { c in
                let o = try await c.core.projects.overview(c.params.requireString("projectId"))
                return ["project": try JSONValue(encoding: o.project), "meta": try JSONValue(encoding: o.meta), "folders": try JSONValue(encoding: o.folders), "docs": try JSONValue(encoding: o.docs)]
            }),
            ("project.setSwitches", { c in
                try await c.core.projects.setSwitches(c.params.requireString("projectId"), sendSources: c.params["sendSources"]?.bool, sendLearning: c.params["sendLearning"]?.bool)
                changed(c, "project.setSwitches"); return .null
            }),
            ("project.learningDraft", { c in
                .string(try await c.core.track(kind: "project.learningDraft", projectId: c.params["projectId"]?.string) { try await c.core.projects.learningDraft(c.params.requireString("projectId")) })
            }),
            ("project.saveLearning", { c in
                let r = try await c.core.projects.saveLearning(c.params.requireString("projectId"), notes: c.params.requireString("notes")); changed(c, "project.saveLearning")
                return ["path": .string(r.path), "fingerprint": .string(r.fingerprint)]
            }),
            ("project.suggestName", { c in
                var paths: [String] = []
                if case .array(let a)? = c.params["paths"] { paths = a.compactMap(\.string) }
                return .string(await c.core.projects.suggestName(paths: paths))
            }),
            ("workspace.list", { c in try JSONValue(encoding: await c.core.projects.workspaces()) }),
            ("workspace.save", { c in
                let w = try await c.core.projects.saveWorkspace(id: c.params["id"]?.string, name: c.params.requireString("name")); changed(c, "workspace.save"); return try JSONValue(encoding: w)
            }),
            ("workspace.delete", { c in try await c.core.projects.deleteWorkspace(c.params.requireString("id")); changed(c, "workspace.delete"); return .null }),
            ("project.moveToWorkspace", { c in
                try await c.core.projects.moveProject(c.params.requireString("projectId"), to: c.params["workspaceId"]?.string); changed(c, "project.moveToWorkspace"); return .null
            }),

            // Tra cứu mã
            ("brain.command", { c in
                let p = c.params
                let scope = try await c.core.brain.scope(chatId: p["chatId"]?.string, root: p["root"]?.string)
                switch try p.requireString("command") {
                case "overview": return .string(try await c.core.brain.overview(scope))
                case "outline": return .string(try await c.core.brain.outline(scope, file: p.requireString("file")))
                case "find":
                    let r = try await c.core.brain.find(scope, query: p.requireString("query"), limit: Int(p["limit"]?.number ?? 12))
                    return ["hits": .array(r.hits.map { ["kind": .string($0.kind), "name": .string($0.name), "path": .string($0.path), "line": .number(Double($0.line)), "evidence": $0.evidence.map { .string($0) } ?? .null] }),
                            "hint": r.hint.map { .string($0) } ?? .null]
                case "read": return .string(try await c.core.brain.read(scope, file: p.requireString("file"), start: p["start"]?.number.map { Int($0) }, end: p["end"]?.number.map { Int($0) }, symbol: p["symbol"]?.string))
                case "refs": return .string(try await c.core.brain.refs(scope, identifier: p.requireString("identifier")))
                default: throw PVTAError("Lệnh tra cứu mã là overview, outline, find, read hoặc refs.")
                }
            }),

            // Hướng dẫn (không gọi AI)
            ("help.toc", { c in
                .array(c.core.help.toc().map { ["group": .string($0.group), "chapters": .array($0.chapters.map { ["id": .string($0.id), "title": .string($0.title), "number": .number(Double($0.number))] })] })
            }),
            ("help.chapter", { c in
                guard let ch = c.core.help.chapter(try c.params.requireString("id")) else { throw PVTAError("Không có chương này trong hướng dẫn.") }
                return try JSONValue(encoding: ch)
            }),
            ("help.search", { c in try JSONValue(encoding: c.core.help.search(c.params.requireString("query"))) }),
            ("help.ask", { c in
                try JSONValue(encoding: c.core.help.ask(question: c.params["question"]?.string, label: c.params["label"]?.string, x: c.params["x"]?.number, y: c.params["y"]?.number))
            }),
        ]
    }
}
