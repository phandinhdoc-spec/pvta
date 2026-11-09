import Foundation

struct WorkStep: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var model: String = "auto"
    var write: Bool = false
    var directory: String? = nil
    var needs: [String] = []
    var resources: [String] = []
    var outputs: [String] = []
    var criteria: String = "Có kết quả đầy đủ theo yêu cầu."
    var stopOnError: Bool = false
    var subWorkflowId: String? = nil
    var copied: Bool? = nil
    var passthrough: Bool? = nil
    var rewrite: WorkRewrite? = nil
    static func parse(_ v: JSONValue) throws -> Self {
        func strings(_ key: String) throws -> [String] {
            guard let x = v[key] else { return [] }
            guard case .array(let a) = x, a.allSatisfy({ $0.string != nil }) else { throw PVTAError("\(key) phải là danh sách chữ.") }
            return a.compactMap(\.string)
        }
        return try Self(id: v.requireString("id"), name: v["name"]?.string ?? v.requireString("id"), prompt: v.requireString("prompt"), model: v["model"]?.string ?? "auto", write: v["write"]?.bool ?? false, directory: v["directory"]?.string, needs: strings("needs"), resources: strings("resources"), outputs: strings("outputs"), criteria: v["criteria"]?.string ?? "Có kết quả đầy đủ theo yêu cầu.", stopOnError: v["stopOnError"]?.bool ?? false, subWorkflowId: v["subWorkflowId"]?.string, copied: v["copied"]?.bool)
    }
}
struct WorkDefinition: Codable, Sendable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var kind: String = "workflow"
    var chatId: String
    var steps: [WorkStep]
    var parallel: Bool = false
    var concurrency: Int = 2
    var input: JSONValue = ["kind": "text", "value": ""]
    var questions: [String] = []
    var revision: Int = 0
    var pinned: Bool = false
    var advanced: WorkAdvanced? = nil
    func dependencies(_ step: WorkStep) -> [String] {
        guard !parallel, kind == "workflow", let i = steps.firstIndex(where: { $0.id == step.id }), i > 0 else { return step.needs }
        return Array(Set(step.needs + [steps[i - 1].id])).sorted()
    }
    func validate() throws {
        try validateAdvanced()
        guard ["workflow", "plan", "pro"].contains(kind), !name.isEmpty, !steps.isEmpty, steps.count <= 100, (1...4).contains(concurrency), Set(steps.map(\.id)).count == steps.count else { throw PVTAError("Kế hoạch/quy trình cần 1–100 bước có mã riêng và mức song song 1–4.") }
        let ids = Set(steps.map(\.id))
        for s in steps {
            guard !s.id.isEmpty, !s.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.prompt.count <= 60000, s.resources.count <= 100 else { throw PVTAError("Bước \(s.id) thiếu prompt hoặc vượt giới hạn.") }
            guard dependencies(s).allSatisfy({ ids.contains($0) && $0 != s.id }) else { throw PVTAError("Bước \(s.id) tự chờ hoặc chờ mã không tồn tại.") }
            if s.write && (s.directory?.hasPrefix("/") != true) { throw PVTAError("Bước \(s.id) cần thư mục sửa tệp tuyệt đối.") }
        }
        var done = Set<String>()
        while done.count < steps.count {
            let ready = steps.filter { !done.contains($0.id) && Set(dependencies($0)).isSubset(of: done) }
            guard !ready.isEmpty else { throw PVTAError("Quan hệ chờ có vòng lặp.") }
            done.formUnion(ready.map(\.id))
        }
        let outputs = steps.flatMap(\.outputs)
        guard Set(outputs).count == outputs.count else { throw PVTAError("Các bước khai báo trùng tệp kết quả.") }
    }
}
struct StepRecord: Codable, Sendable, Equatable {
    var state = "pending"
    var output = ""
    var reason = ""
    var before: [String: String] = [:]
    var after: [String: String] = [:]
    var value: JSONValue? = nil
    var logs: [String]? = nil
}
struct WorkRecord: Codable, Sendable {
    var definition: WorkDefinition
    var steps: [String: StepRecord] = [:]
    var state = "draft"
    var fingerprint = ""
    var review = ""
}
struct StepContext: Sendable {
    var step: WorkStep
    var chatId: String
    var prompt: String
    var images: [ChatImage] = []
    var kind: TaskKind = .workflow
}
struct PreparedWork: Sendable {
    var input: String
    var extras: [String: String]
    var images: [String: [ChatImage]]
    var fingerprint: String
    var languageInputs: [String: [String: JSONValue]] = [:]
}
/// Khóa chung mọi quy trình: bước sửa không chồng với bất kỳ bước nào của bộ chạy.
actor WorkGate {
    private var readers = 0
    private var writer = false
    func acquire(write: Bool) async throws {
        while writer || (write && readers > 0) { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        if write { writer = true } else { readers += 1 }
    }
    func release(write: Bool) { if write { writer = false } else { readers -= 1 } }
}
