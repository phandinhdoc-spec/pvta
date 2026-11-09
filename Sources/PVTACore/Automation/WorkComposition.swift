import Foundation

struct WorkTemplate: Codable, Sendable {
    var id: String
    var name: String
    var steps: [WorkStep]
    var frames: [WorkFrame]
    var parallel: Bool
}
extension WorkEngine {
    func validateReferences(_ candidate: WorkDefinition) throws {
        var definitions = records.mapValues(\.definition); definitions[candidate.id] = candidate
        func visit(_ d: WorkDefinition, chain: [String]) throws {
            guard chain.count < 3, !chain.contains(d.id) else { throw PVTAError("Quy trình con có vòng tham chiếu hoặc vượt 3 tầng.") }
            for s in d.steps {
                guard let ref = s.subWorkflowId else { continue }
                guard d.kind == "workflow", let child = definitions[ref], child.kind == "workflow" else { throw PVTAError("Bước \(s.id): quy trình con không tồn tại hoặc không đúng loại.") }
                guard !d.hasLanguage, !child.hasLanguage else { throw PVTAError("Chỉ thị trạng thái chưa dùng trong quy trình con trải phẳng.") }
                try visit(child, chain: chain + [d.id])
            }
        }
        for d in definitions.values { try visit(d, chain: []) }
    }
    func expanded(_ d: WorkDefinition, chain: [String] = []) throws -> WorkDefinition {
        guard chain.count < 3, !chain.contains(d.id) else { throw PVTAError("Quy trình con có vòng hoặc vượt 3 tầng.") }
        var result = d; result.steps = []; result.parallel = true
        var expandedIDs: [String: [String]] = [:], childFrames: [WorkFrame] = []
        for step in d.steps {
            var s = step; s.needs = d.dependencies(step)
            guard let ref = s.subWorkflowId else { result.steps.append(s); expandedIDs[s.id] = [s.id]; continue }
            guard let child = records[ref]?.definition, !d.hasLanguage, !child.hasLanguage else { throw PVTAError("Quy trình con thiếu hoặc chứa chỉ thị trạng thái chưa hỗ trợ.") }
            let flat = try expanded(child, chain: chain + [d.id])
            let mapping = Dictionary(uniqueKeysWithValues: flat.steps.map { ($0.id, s.id + "/" + $0.id) })
            for node in flat.steps {
                var n = node; n.id = mapping[node.id]!
                n.resources = Array(Set(s.resources + n.resources)).sorted()
                n.needs = node.needs.isEmpty ? s.needs : node.needs.map { mapping[$0]! }
                result.steps.append(n)
            }
            expandedIDs[s.id] = flat.steps.map { mapping[$0.id]! } + [s.id]
            for frame in flat.advanced?.frames ?? [] {
                var f = frame; f.id = s.id + "/" + f.id; f.steps = frame.steps.map { mapping[$0]! }; childFrames.append(f)
            }
            let used = Set(flat.steps.flatMap(\.needs))
            s.needs = flat.steps.filter { !used.contains($0.id) }.map { mapping[$0.id]! }
            s.subWorkflowId = nil; s.passthrough = true; s.write = false; s.outputs = []; s.resources = []; s.prompt = "{{prev}}"
            result.steps.append(s)
            guard result.steps.count <= 100 else { throw PVTAError("Quy trình sau trải phẳng vượt 100 bước.") }
        }
        if d.advanced != nil || !childFrames.isEmpty {
            var advanced = d.advanced ?? WorkAdvanced()
            advanced.frames = advanced.frames.map { frame in
                var f = frame; f.steps = frame.steps.flatMap { expandedIDs[$0] ?? [] }; return f
            } + childFrames
            result.advanced = advanced
        }
        try result.validate(); return result
    }
    /// Mẫu chỉ chứa cấu trúc và nội dung prompt; không mang quyền, nguồn hay phê duyệt.
    func cleanTemplate(_ d: WorkDefinition, name: String, id: String = UUID().uuidString) throws -> WorkTemplate {
        guard !d.steps.contains(where: { $0.subWorkflowId != nil }) else { throw PVTAError("Hãy chuyển quy trình con thành các bước trước khi xuất mẫu.") }
        func dependencies(_ ids: [String], seen: Set<String> = []) throws -> [String] {
            try ids.flatMap { id in
                guard !seen.contains(id) else { throw PVTAError("Quan hệ chờ có vòng lặp.") }
                guard let node = d.steps.first(where: { $0.id == id }), node.passthrough == true else { return [id] }
                return try dependencies(d.dependencies(node), seen: seen.union([id]))
            }
        }
        var steps = d.steps.filter { $0.passthrough != true }
        for i in steps.indices {
            steps[i].needs = Array(Set(try dependencies(d.dependencies(steps[i])))).sorted(); steps[i].model = "auto"; steps[i].write = false
            steps[i].directory = nil; steps[i].resources = []; steps[i].outputs = []; steps[i].passthrough = nil
            steps[i].copied = true; steps[i].rewrite = nil
            // Tệp khai báo trong ngôn ngữ cũng không được mang theo mẫu.
            let lines = steps[i].prompt.components(separatedBy: .newlines).map { line in
                if let m = WorkProgram.match(#"^\s*!dau-vao\s+([^\s=]+)\s*=.*$"#, line) { return "!dau-vao \(m[0]) = @truoc" }
                return line
            }
            steps[i].prompt = lines.joined(separator: "\n")
        }
        let kept = Set(steps.map(\.id)); var frames: [WorkFrame] = []
        for frame in d.advanced?.frames ?? [] {
            var f = frame; f.steps = frame.steps.filter { kept.contains($0) }
            if !f.steps.isEmpty, !frames.contains(where: { Set($0.steps) == Set(f.steps) }) { frames.append(f) }
        }
        let t = WorkTemplate(id: id, name: name, steps: steps, frames: frames, parallel: true)
        let check = WorkDefinition(name: name, chatId: "", steps: steps, parallel: true, advanced: WorkAdvanced(frames: t.frames))
        try check.validate(); return t
    }
    func templates() async throws -> [WorkTemplate] {
        guard let raw = try await store.setting("automation.templates.v1") else { return [] }
        return try JSONDecoder().decode([WorkTemplate].self, from: Data(raw.utf8))
    }
    func saveTemplate(_ template: WorkTemplate) async throws -> WorkTemplate {
        var safeSteps = template.steps
        for i in safeSteps.indices { safeSteps[i].passthrough = nil }
        let d = WorkDefinition(name: template.name, chatId: "", steps: safeSteps, parallel: template.parallel, advanced: WorkAdvanced(frames: template.frames))
        let clean = try cleanTemplate(d, name: template.name, id: template.id)
        // DataStore thực hiện cập nhật danh sách trong một lượt actor để tránh mất cập nhật.
        try await store.updateWorkTemplate(clean, delete: nil)
        return clean
    }
    func deleteTemplate(_ id: String) async throws { try await store.updateWorkTemplate(nil, delete: id) }
    func templateFrom(_ id: String, name: String) async throws -> WorkTemplate {
        let d = try expanded(await get(id).definition)
        return try await saveTemplate(cleanTemplate(d, name: name))
    }
    func remap(_ template: WorkTemplate) -> WorkTemplate {
        var result = template
        let ids = Dictionary(uniqueKeysWithValues: template.steps.map { ($0.id, UUID().uuidString) })
        for i in result.steps.indices {
            result.steps[i].id = ids[template.steps[i].id]!
            result.steps[i].needs = template.steps[i].needs.compactMap { ids[$0] }
            for (old, new) in ids { result.steps[i].prompt = result.steps[i].prompt.replacingOccurrences(of: "!lap-lai \"\(old)\"", with: "!lap-lai \"\(new)\"") }
        }
        for i in result.frames.indices { result.frames[i].id = UUID().uuidString; result.frames[i].steps = template.frames[i].steps.compactMap { ids[$0] } }
        return result
    }
    func insertTemplate(_ template: WorkTemplate, target: String, revision: Int) async throws -> WorkRecord {
        var d = try await get(target).definition
        guard d.revision == revision else { throw PVTAError("Quy trình đã thay đổi.") }
        let safe = try cleanTemplate(WorkDefinition(name: template.name, chatId: "", steps: template.steps, parallel: template.parallel, advanced: WorkAdvanced(frames: template.frames)), name: template.name)
        let copy = remap(safe)
        let used = Set(d.steps.flatMap { d.dependencies($0) }), ends = d.steps.filter { !used.contains($0.id) }
        let roots = copy.steps.filter { $0.needs.isEmpty }
        var advanced = d.advanced ?? WorkAdvanced()
        advanced.frames += copy.frames
        advanced.suggestedLinks += ends.flatMap { e in roots.map { WorkLink(from: e.id, to: $0.id) } }
        for i in d.steps.indices { d.steps[i].needs = d.dependencies(d.steps[i]) }
        d.parallel = true; d.steps += copy.steps; d.advanced = advanced
        return try await save(d, expectedRevision: revision)
    }
    func resolveLink(_ id: String, revision: Int, from: String, to: String, accept: Bool) async throws -> WorkRecord {
        var d = try await get(id).definition
        guard d.revision == revision, d.advanced?.suggestedLinks.contains(WorkLink(from: from, to: to)) == true, let i = d.steps.firstIndex(where: { $0.id == to }) else { throw PVTAError("Liên kết gợi ý không còn hợp lệ.") }
        d.advanced!.suggestedLinks.removeAll { $0.from == from && $0.to == to }
        if accept { d.steps[i].needs = Array(Set(d.steps[i].needs + [from])).sorted() }
        return try await save(d, expectedRevision: revision)
    }
    func duplicate(_ id: String, chatId: String) async throws -> WorkRecord {
        let d = try expanded(await get(id).definition)
        let copy = remap(try cleanTemplate(d, name: d.name + " — bản sao"))
        return try await save(WorkDefinition(name: copy.name, chatId: chatId, steps: copy.steps, parallel: copy.parallel, advanced: WorkAdvanced(frames: copy.frames)), expectedRevision: nil)
    }
}

extension DataStore {
    func updateWorkTemplate(_ value: WorkTemplate?, delete: String?) throws {
        let raw = try setting("automation.templates.v1") ?? "[]"
        var list = try JSONDecoder().decode([WorkTemplate].self, from: Data(raw.utf8))
        if let delete { list.removeAll { $0.id == delete } }
        if let value { list.removeAll { $0.id == value.id }; list.append(value) }
        guard list.count <= 100 else { throw PVTAError("Tối đa 100 quy trình mẫu.") }
        try setSetting("automation.templates.v1", String(decoding: JSONEncoder().encode(list), as: UTF8.self))
    }
}
