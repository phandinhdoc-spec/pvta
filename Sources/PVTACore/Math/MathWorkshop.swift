import Foundation

struct MathFormula: Codable, Sendable, Equatable {
    var id: String
    var revision: Int
    var title: String
    /// math, physics, chemistry: phân loại do người soạn chọn, không suy đoán nội dung.
    var subject: String
    var latex: String
    var updatedAt: Date

    static func validate(title: String, subject: String, latex: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              ["math", "physics", "chemistry"].contains(subject), !latex.isEmpty, latex.count <= 8000 else {
            throw PVTAError("Cần tên công thức (tối đa 200 ký tự), môn math/physics/chemistry và LaTeX tối đa 8.000 ký tự.")
        }
        guard !(title + latex).unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw PVTAError("Công thức có ký tự điều khiển không hợp lệ.") }
        _ = try Omml.convert(latex, display: true)
    }
}

extension DataStore {
    func mathFormulas() throws -> [MathFormula] {
        guard let raw = try setting("math.workshop.v1") else { return [] }
        guard let items = try? JSONDecoder().decode([MathFormula].self, from: Data(raw.utf8)), items.count <= 1000,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.revision > 0 }) else {
            throw PVTAError("Kho công thức không đọc được; không tự ghi đè kho cũ.")
        }
        return items.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    func mathSave(id: String?, revision: Int, title: String, subject: String, latex: String) throws -> MathFormula {
        try MathFormula.validate(title: title, subject: subject, latex: latex)
        return try db.transaction {
            var all = try mathFormulas()
            let index = id.flatMap { id in all.firstIndex { $0.id == id } }
            if id != nil {
                guard let index, all[index].revision == revision else { throw PVTAError("Công thức đã đổi hoặc không còn trong kho; hãy đọc lại trước khi lưu.") }
            } else { guard revision == 0, all.count < 1000 else { throw PVTAError("Tạo mới cần baseRevision bằng 0; kho tối đa 1.000 công thức.") } }
            let item = MathFormula(id: id ?? UUID().uuidString, revision: revision + 1, title: title, subject: subject, latex: latex, updatedAt: now())
            if let index { all[index] = item } else { all.append(item) }
            try setSetting("math.workshop.v1", String(decoding: JSONEncoder().encode(all), as: UTF8.self))
            return item
        }
    }
}

struct MathWorkshop: Sendable {
    let store: DataStore
    let files: FileService

    func export(_ params: JSONValue) async throws -> JSONValue {
        let path = try params.requireString("path"), chat = try params.requireString("chatId")
        guard path.lowercased().hasSuffix(".docx") else { throw PVTAError("Xưởng Toán xuất công thức chuẩn Word vào tệp .docx mới.") }
        guard case .array(let selections)? = params["items"], !selections.isEmpty, selections.count <= 100 else { throw PVTAError("Chọn từ 1 đến 100 công thức cần xuất.") }
        let all = try await store.mathFormulas()
        var selected: [MathFormula] = [], ids = Set<String>()
        for selection in selections {
            let id = try selection.requireString("id")
            let rev = try CalendarValidation.integer(selection["revision"], name: "revision", minimum: 1)
            guard ids.insert(id).inserted, let formula = all.first(where: { $0.id == id }), formula.revision == rev else { throw PVTAError("Danh sách có công thức trùng, đã đổi hoặc không tồn tại; hãy chọn lại từ math.list.") }
            try MathFormula.validate(title: formula.title, subject: formula.subject, latex: formula.latex)
            selected.append(formula)
        }
        let title = params["title"]?.string ?? "Công thức Toán Lý Hóa"
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw PVTAError("Tên tài liệu cần 1–200 ký tự.") }
        let dest = try await files.resolve(path, chatId: chat, write: true)
        guard !FileManager.default.fileExists(atPath: dest) else { throw PVTAError("Tệp đích đã tồn tại; hãy chọn tên mới.") }
        let blocks: [JSONValue] = selected.flatMap { f in [["type": "heading", "level": 1, "text": .string(f.title)], ["type": "equation", "latex": .string(f.latex)]] }
        // Chuẩn bị toàn bộ tài liệu trước khi hỏi; công thức sai không tạo tệp hoặc yêu cầu duyệt vô ích.
        _ = try await Docx.create(title: title, blocks: blocks, images: { _ in throw PVTAError("Công thức không dùng ảnh.") })
        let preview = selected.map { "\($0.title) — bản \($0.revision)\n\($0.latex)" }.joined(separator: "\n\n")
        let plan = ActionPlan(kind: .write, summary: "Xuất \(selected.count) công thức Word: \(dest)", preview: title + "\n\n" + preview, paths: [dest])
        let tool = ToolSpec(name: "math_export", summary: "Xuất công thức Word", parameters: "{}", access: .write, plan: { _ in plan }) { _ in "" }
        switch await PermissionPolicy(files.permissions).decide(tool, args: [:], chatId: chat) {
        case .deny(let why): throw PVTAError(why)
        case .allow: break
        }
        try Task.checkCancellation()
        guard files.permissions.level() != .readOnly else { throw PVTAError("Chế độ Chỉ đọc không cho xuất công thức.") }
        let latest = try await store.mathFormulas()
        guard selected.allSatisfy({ latest.contains($0) }) else { throw PVTAError("Công thức đã đổi trong lúc chờ duyệt; hãy xem và xuất lại.") }
        let change = try await files.wordCreate(path: dest, title: title, blocks: blocks, chatId: chat)
        return ["path": .string(change.path), "changeId": .string(change.id), "count": .number(Double(selected.count)), "format": "docx-omml"]
    }
}

extension Builtin {
    static func mathMethods() -> [(String, Core.Handler)] {
        [
            ("math.list", { c in
                let items = try await c.core.store.mathFormulas()
                if let subject = c.params["subject"]?.string {
                    guard ["math", "physics", "chemistry"].contains(subject) else { throw PVTAError("Môn phải là math, physics hoặc chemistry.") }
                    return try JSONValue(encoding: items.filter { $0.subject == subject })
                }
                return try JSONValue(encoding: items)
            }),
            ("math.save", { c in
                let p = c.params
                guard c.core.permissions.level() != .readOnly else { throw PVTAError("Chế độ Chỉ đọc không cho lưu công thức.") }
                let revision = try CalendarValidation.integer(p["baseRevision"] ?? (p["id"] == nil ? 0 : nil), name: "baseRevision", maximum: Int(Int32.max) - 1)
                let saved = try await c.core.store.mathSave(id: p["id"]?.string, revision: revision, title: p.requireString("title"), subject: p.requireString("subject"), latex: p.requireString("latex"))
                c.core.broadcast("math.changed", try JSONValue(encoding: saved))
                return try JSONValue(encoding: saved)
            }),
            ("math.export", { c in
                try await c.core.track(kind: "math.export", chatId: c.params["chatId"]?.string) {
                    try await MathWorkshop(store: c.core.store, files: c.core.files).export(c.params)
                }
            })
        ]
    }
}
