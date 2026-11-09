import Foundation

extension Builtin {
    static func automationMethods() -> [(String, Core.Handler)] {
        @Sendable func revision(_ p: JSONValue) throws -> Int { try PDFService.integer(p["revision"], "revision", max: Int(Int32.max)) }
        @Sendable func save(_ c: CallContext, kind: String) async throws -> JSONValue {
            let p = c.params
            guard case .array(let list)? = p["steps"] else { throw PVTAError("Thiếu danh sách steps.") }
            let steps = try list.map(WorkStep.parse)
            let concurrency = p["concurrency"] == nil ? 2 : try PDFService.integer(p["concurrency"], "concurrency", max: 4)
            let questions: [String]
            if case .array(let a)? = p["questions"], a.allSatisfy({ $0.string != nil }) { questions = a.compactMap(\.string) }
            else if p["questions"] == nil { questions = [] }
            else { throw PVTAError("questions phải là danh sách câu hỏi.") }
            var d = WorkDefinition(id: p["id"]?.string ?? UUID().uuidString, name: try p.requireString("name"), kind: kind, chatId: try p.requireString("chatId"), steps: steps, parallel: p["parallel"]?.bool ?? (kind != "workflow"), concurrency: concurrency, input: p["input"] ?? ["kind": "text", "value": ""], questions: questions)
            if let raw = p["frames"] { d.advanced = WorkAdvanced(frames: try raw.decode([WorkFrame].self)) }
            if d.input["kind"]?.string == "chat" {
                let source = try d.input.requireString("value")
                guard try await c.core.store.chat(id: source) != nil else { throw PVTAError("Hội thoại nguồn không tồn tại.") }
                let text = try await c.core.store.messages(chatId: source).filter { $0.role == .user }.map(\.text).joined(separator: "\n")
                guard text.count <= 60000 else { throw PVTAError("Đầu vào chat vượt 60.000 ký tự.") }
                d.input = ["kind": "text", "value": .string(text)]
            } else if d.input["kind"]?.string == "prompt" {
                let expanded = try await c.core.writing.prompts.expand(d.input.requireString("value"))
                guard expanded.missing.isEmpty, expanded.text.count <= 60000 else { throw PVTAError("Đầu vào lời nhắc mẫu thiếu thông tin hoặc quá dài.") }
                d.input = ["kind": "text", "value": .string(expanded.text)]
            }
            return try JSONValue(encoding: await c.core.work.save(d, expectedRevision: p["id"] == nil ? nil : revision(p)))
        }
        @Sendable func resources(_ p: JSONValue) -> [String] {
            if case .array(let a)? = p["resources"] { return a.compactMap(\.string) }
            return []
        }
        func entry(_ name: String, _ handler: @escaping Core.Handler) -> (String, Core.Handler) { (name, handler) }
        var methods: [(String, Core.Handler)] = []
        for group in ["plan", "workflow"] {
            methods += [
                entry(group + ".list", { c in try JSONValue(encoding: await c.core.work.list(kind: group)) }),
                entry(group + ".get", { c in try JSONValue(encoding: await c.core.work.get(c.params.requireString("id"))) }),
                entry(group + ".save", { c in try await save(c, kind: group == "plan" && c.params["pro"]?.bool == true ? "pro" : group) }),
                entry(group + ".run", { c in
                    let kind = try await c.core.work.get(c.params.requireString("id")).definition.kind
                    guard group == "workflow" ? kind == "workflow" : kind != "workflow" else { throw PVTAError("Phương thức chạy không đúng loại công việc.") }
                    if group == "workflow" {
                        return try JSONValue(encoding: await c.core.work.runReviewed(c.params.requireString("id"), revision: revision(c.params), approved: c.params["approved"]?.bool == true, token: c.params["draftId"]?.string, retry: c.params["retry"]?.bool ?? false, edits: c.params["edits"]?.decode([String: [String: String]].self) ?? [:]))
                    }
                    return try JSONValue(encoding: await c.core.work.run(c.params.requireString("id"), revision: revision(c.params), approved: c.params["approved"]?.bool == true, stepId: c.params["stepId"]?.string, retry: c.params["retry"]?.bool ?? false))
                }),
                entry(group + ".cancel", { c in await c.core.work.cancel(try c.params.requireString("id")); return .null }),
                entry(group + ".delete", { c in try await c.core.work.delete(c.params.requireString("id")); return .null }),
                entry(group + ".pin", { c in try JSONValue(encoding: await c.core.work.pin(c.params.requireString("id"), value: c.params["pinned"]?.bool ?? true)) }),
                entry(group + ".openChat", { c in
                    let r = try await c.core.work.get(c.params.requireString("id"))
                    guard let chat = try await c.core.store.chat(id: r.definition.chatId) else { throw PVTAError("Hội thoại liên kết không còn tồn tại.") }
                    return try JSONValue(encoding: chat)
                })
            ]
        }
        methods += [
            entry("plan.suggest", { c in try JSONValue(encoding: await c.core.work.suggest(chatId: c.params.requireString("chatId"), request: c.params.requireString("request"), model: c.params["model"]?.string ?? "auto", pro: c.params["pro"]?.bool ?? false, input: c.params["input"], resources: resources(c.params))) }),
            entry("plan.skipStep", { c in try JSONValue(encoding: await c.core.work.skip(c.params.requireString("id"), step: c.params.requireString("stepId"), replacement: nil)) }),
            entry("plan.replaceInput", { c in try JSONValue(encoding: await c.core.work.skip(c.params.requireString("id"), step: c.params.requireString("stepId"), replacement: c.params.requireString("text"))) }),
            entry("plan.inspectRecovery", { c in try await c.core.work.inspect(c.params.requireString("id"), step: c.params.requireString("stepId")) }),
            entry("plan.resolveRecovery", { c in
                guard let value = c.params["observed"] else { throw PVTAError("Thiếu dấu vân tay observed vừa đối chiếu.") }
                return try JSONValue(encoding: await c.core.work.recover(c.params.requireString("id"), step: c.params.requireString("stepId"), revision: revision(c.params), observed: value.decode([String: String].self), decision: c.params.requireString("decision"), output: c.params["output"]?.string, confirmed: c.params["confirmed"]?.bool == true))
            }),
            entry("chat.workflow", { c in
                let id = try c.params.requireString("chatId")
                return try JSONValue(encoding: await c.core.work.list(kind: nil).filter { $0.definition.chatId == id })
            })
        ]
        return methods + advancedAutomationMethods()
    }
}
