import Foundation

extension Builtin {
    static func assessmentMethods() -> [(String, Core.Handler)] {
        @Sendable func scoring(_ p: JSONValue) throws -> ExamScoring {
            guard let s = p["scoring"], s != .null else { return ExamScoring() }
            guard let a = s["part1PerQuestion"]?.number, let b = s["part2PerQuestion"]?.number, a > 0, b > 0, a <= 10, b <= 10 else { throw PVTAError("Thang điểm cần part1PerQuestion và part2PerQuestion lớn hơn 0.") }
            return ExamScoring(part1PerQuestion: a, part2PerQuestion: b, assumed: false)
        }
        @Sendable func list(_ v: JSONValue?, _ name: String) throws -> [JSONValue] {
            guard case .array(let a)? = v else { throw PVTAError("Thiếu danh sách “\(name)”.") }
            return a
        }
        return [
            ("assessment.rules", { _ in try JSONValue(encoding: ExamRules.all) }),
            ("assessment.readMatrix", { c in
                try JSONValue(encoding: await c.core.exam.readMatrix(path: c.params["path"]?.string, text: c.params["text"]?.string, scoring: try scoring(c.params)))
            }),
            ("assessment.readSpec", { c in try JSONValue(encoding: await c.core.exam.readSpec(path: c.params["path"]?.string, text: c.params["text"]?.string)) }),
            ("assessment.generate", { c in
                let p = c.params
                let sc = try scoring(p)
                let m = try await c.core.exam.readMatrix(path: p["path"]?.string, text: p["text"]?.string, scoring: sc)
                var spec: [SpecItem] = []
                if case .object(let s)? = p["spec"] { spec = try await c.core.exam.readSpec(path: s["path"]?.string, text: s["text"]?.string).items }
                var passages: [Passage] = []
                for x in try list(p["passages"], "passages") {
                    guard let ref = x["ref"]?.string else { throw PVTAError("Mỗi đoạn nguồn cần “ref”.") }
                    if let t = x["text"]?.string { passages.append(Passage(ref: ref, text: t)) }
                    else if let path = x["path"]?.string { passages.append(Passage(ref: ref, text: try await c.core.exam.passageText(path: path))) }
                    else { throw PVTAError("Đoạn nguồn “\(ref)” cần text hoặc path.") }
                }
                let codes = try list(p["codes"], "codes").compactMap(\.string)
                let req = ExamService.GenerateRequest(title: p["title"]?.string ?? "Đề kiểm tra", subject: p["subject"]?.string ?? "", grade: p["grade"]?.string ?? "",
                                                      instructions: p["instructions"]?.string ?? "", passages: passages, spec: spec, scoring: sc)
                let exam = try await c.core.track(kind: "assessment.generate") { try await c.core.exam.generate(m.blueprint, req) }
                let versions = try ExamService.versions(exam, codes: codes, salt: Int(p["salt"]?.number ?? 0))
                let review = ExamService.review(exam, m.blueprint, versions: versions)
                return ["matrix": try JSONValue(encoding: m), "exam": try JSONValue(encoding: exam), "versions": try JSONValue(encoding: versions), "review": try JSONValue(encoding: review)]
            }),
            ("assessment.versions", { c in
                let exam: Exam = try (c.params["exam"] ?? .null).decode()
                let codes = try list(c.params["codes"], "codes").compactMap(\.string)
                return try JSONValue(encoding: ExamService.versions(exam, codes: codes, salt: Int(c.params["salt"]?.number ?? 0)))
            }),
            ("assessment.review", { c in
                let exam: Exam = try (c.params["exam"] ?? .null).decode(), bp: ExamBlueprint = try (c.params["blueprint"] ?? .null).decode()
                var versions: [ExamVersion] = []
                if let v = c.params["versions"], v != .null { versions = try v.decode() }
                return try JSONValue(encoding: ExamService.review(exam, bp, versions: versions))
            }),
            ("assessment.render", { c in
                let exam: Exam = try (c.params["exam"] ?? .null).decode(), v: ExamVersion = try (c.params["version"] ?? .null).decode()
                return .string(ExamService.render(exam, version: v, teacher: c.params["teacher"]?.bool ?? false))
            }),
            ("assessment.saveDossier", { c in
                let exam: Exam = try (c.params["exam"] ?? .null).decode(), bp: ExamBlueprint = try (c.params["blueprint"] ?? .null).decode(), vs: [ExamVersion] = try (c.params["versions"] ?? .null).decode()
                let d = try await c.core.exam.saveDossier(name: c.params.requireString("name"), matrixSource: c.params["matrixSource"]?.string ?? "", matrixIssues: (c.params["matrixIssues"].flatMap { try? $0.decode([String].self) }) ?? [],
                                                          blueprint: bp, exam: exam, versions: vs, allowFailed: c.params["allowFailed"]?.bool ?? false)
                return try JSONValue(encoding: d)
            }),
            ("assessment.dossiers", { c in try JSONValue(encoding: await c.core.exam.dossiers()) }),
            ("assessment.dossier", { c in
                let id = try c.params.requireString("id")
                guard let d = try await c.core.exam.dossiers().first(where: { $0.id == id }) else { throw PVTAError("Không tìm thấy hồ sơ.") }
                return ["dossier": try JSONValue(encoding: d), "markdown": .string(ExamService.dossierMarkdown(d))]
            }),
            ("assessment.deleteDossier", { c in try await c.core.exam.deleteDossier(id: c.params.requireString("id")); return .null }),
            ("assessment.export", { c in
                let r = try await c.core.exam.exportDocx(dossierId: c.params.requireString("id"), folder: c.params.requireString("folder"))
                return .array(r.map { .string($0) })
            }),
        ]
    }
}
