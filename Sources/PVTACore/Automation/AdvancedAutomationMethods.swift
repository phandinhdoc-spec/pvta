import Foundation

extension Builtin {
    static func advancedAutomationMethods() -> [(String, Core.Handler)] {
        @Sendable func revision(_ p: JSONValue) throws -> Int { try PDFService.integer(p["revision"], "revision", max: Int(Int32.max)) }
        func entry(_ name: String, _ handler: @escaping Core.Handler) -> (String, Core.Handler) { (name, handler) }
        return [
            entry("workflow.promptPreview", { c in try JSONValue(encoding: await c.core.work.preview(c.params.requireString("id"), revision: revision(c.params))) }),
            entry("workflow.promptSave", { c in try JSONValue(encoding: await c.core.work.savePrompts(c.params.requireString("draftId"), edits: c.params["edits"]?.decode([String: [String: String]].self) ?? [:])) }),
            entry("workflow.promptCancel", { c in await c.core.work.cancelDraft(try c.params.requireString("id")); return .null }),
            entry("workflow.linkResolve", { c in try JSONValue(encoding: await c.core.work.resolveLink(c.params.requireString("id"), revision: revision(c.params), from: c.params.requireString("from"), to: c.params.requireString("to"), accept: c.params["accept"]?.bool == true)) }),
            entry("workflow.duplicate", { c in try JSONValue(encoding: await c.core.work.duplicate(c.params.requireString("id"), chatId: c.params.requireString("chatId"))) }),
            entry("workflow.functionDraft", { c in try JSONValue(encoding: await c.core.work.functionDraft(c.params.requireString("id"), revision: revision(c.params), stepId: c.params.requireString("stepId"), name: c.params.requireString("name"))) }),
            entry("workflow.functionApprove", { c in try JSONValue(encoding: await c.core.work.approveFunction(c.params.requireString("draftId"), approved: c.params["approved"]?.bool == true)) }),
            entry("workflow.designStart", { c in try JSONValue(encoding: await c.core.work.designStart(chatId: c.params.requireString("chatId"), model: c.params["model"]?.string ?? "auto")) }),
            entry("workflow.designContinue", { c in try JSONValue(encoding: await c.core.work.designSuggest(c.params.requireString("id"), text: c.params.requireString("text"))) }),
            entry("workflow.designApply", { c in try JSONValue(encoding: await c.core.work.designApply(c.params.requireString("id"), approved: c.params["approved"]?.bool == true)) }),
            entry("workflow.markdownDraft", { c in
                let design = await c.core.work.designStart(chatId: try c.params.requireString("chatId"), model: c.params["model"]?.string ?? "auto")
                return try JSONValue(encoding: await c.core.work.designSuggest(design.id, text: c.params.requireString("text")))
            }),
            entry("workflow.suggest", { c in try await c.core.work.suggestPrompt(c.params.requireString("id"), stepId: c.params.requireString("stepId"), request: c.params.requireString("request")) }),
            entry("template.list", { c in try JSONValue(encoding: await c.core.work.templates()) }),
            entry("template.save", { c in
                guard let raw = c.params["template"] else { throw PVTAError("Thiếu mẫu.") }
                return try JSONValue(encoding: await c.core.work.saveTemplate(raw.decode(WorkTemplate.self)))
            }),
            entry("template.delete", { c in try await c.core.work.deleteTemplate(c.params.requireString("id")); return .null }),
            entry("template.fromWorkflow", { c in try JSONValue(encoding: await c.core.work.templateFrom(c.params.requireString("id"), name: c.params.requireString("name"))) }),
            entry("template.export", { c in
                let saved = try await c.core.work.get(c.params.requireString("id")).definition
                let d = try await c.core.work.expanded(saved)
                return try JSONValue(encoding: await c.core.work.cleanTemplate(d, name: d.name))
            }),
            entry("template.import", { c in
                let raw = try c.params.requireString("json")
                guard raw.count <= 1_000_000 else { throw PVTAError("Mẫu JSON vượt giới hạn.") }
                var t = try JSONDecoder().decode(WorkTemplate.self, from: Data(raw.utf8)); t.id = UUID().uuidString
                for i in t.steps.indices { t.steps[i].passthrough = nil }
                let safe = try await c.core.work.saveTemplate(t)
                let copy = await c.core.work.remap(safe)
                return try JSONValue(encoding: await c.core.work.save(WorkDefinition(name: copy.name, chatId: c.params.requireString("chatId"), steps: copy.steps, parallel: copy.parallel, advanced: WorkAdvanced(frames: copy.frames)), expectedRevision: nil))
            }),
            entry("template.insert", { c in
                guard let t = try await c.core.work.templates().first(where: { $0.id == c.params["templateId"]?.string }) else { throw PVTAError("Không tìm thấy mẫu.") }
                return try JSONValue(encoding: await c.core.work.insertTemplate(t, target: c.params.requireString("id"), revision: revision(c.params)))
            })
        ]
    }
}
