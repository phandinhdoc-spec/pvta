import Foundation

struct WorkFunction: Codable, Sendable, Equatable {
    var name: String
    var parameters: [String]
    var description: String
    var fields: [String]
    var outputDescription: String
    var signature: String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return FileHash.of((try? e.encode(self)) ?? Data())
    }
}
struct WorkFunctionApproval: Codable, Sendable, Equatable {
    var signature: String
    var expression: String
}
struct WorkFrame: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var steps: [String]
    var decl: String? = nil
}
struct WorkLink: Codable, Sendable, Equatable { var from: String; var to: String }
struct WorkAdvanced: Codable, Sendable, Equatable {
    var frames: [WorkFrame] = []
    var functions: [String: WorkFunctionApproval] = [:]
    var suggestedLinks: [WorkLink] = []
}
struct WorkProgram: Sendable {
    enum Command: Sendable {
        case declare(String, WorkExpression), assign(String, WorkExpression), input(String, String?)
        case output(WorkExpression), print(WorkExpression), repeatFrom(String, WorkExpression), stop(WorkExpression)
        case function(WorkFunction), call(String?, String, [WorkExpression])
    }
    var commands: [(Int, Command)] = []
    var prompt = ""
    static func validName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil && !["input", "prev", "__proto__", "prototype", "constructor"].contains(s)
    }
    static func match(_ pattern: String, _ value: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : (value as NSString).substring(with: m.range(at: $0)) }
    }
    init(_ source: String) throws {
        guard source.count <= 60000 else { throw PVTAError("Prompt vượt 60.000 ký tự.") }
        let lines = source.components(separatedBy: .newlines); var i = 0; var fence: String?; var outputs = 0
        func name(_ s: String) throws -> String { guard Self.validName(s) else { throw PVTAError("Tên không hợp lệ hoặc dành riêng: \(s).") }; return s }
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces); i += 1
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3)); if fence == nil { fence = marker } else if fence == marker { fence = nil }
                prompt += lines[i - 1] + "\n"; continue
            }
            guard fence == nil, line.hasPrefix("!") else { prompt += lines[i - 1] + "\n"; continue }
            let number = i
            do {
                let c: Command
                if let m = Self.match(#"^!(bien|gan)\s+([^\s=]+)\s*=\s*(.+)$"#, line) {
                    let n = try name(m[1]), e = try WorkExpression.parse(m[2])
                    if m[0] == "bien" { guard e.variables.isEmpty else { throw PVTAError("!bien chỉ nhận hằng, dùng !gan để tính từ biến.") }; _ = try e.evaluate([:]); c = .declare(n, e) }
                    else { c = .assign(n, e) }
                } else if let m = Self.match(#"^!dau-vao\s+([^\s=]+)\s*=\s*(.+)$"#, line) {
                    let n = try name(m[0]); var path: String?
                    if m[1] != "@truoc" {
                        let raw = m[1].replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                        guard let str = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { throw PVTAError("Đường dẫn !dau-vao phải nằm trong dấu nháy kép.") }
                        let link = Self.match(#"^!?\[[^\]]*\]\((?:<([^>]+)>|([^\)]+))\)$"#, str)
                        path = link.map { $0.first(where: { !$0.isEmpty }) ?? "" } ?? str
                        guard path?.hasPrefix("/") == true else { throw PVTAError("!dau-vao cần đường dẫn tệp tuyệt đối.") }
                    }
                    c = .input(n, path)
                } else if let m = Self.match(#"^!dau-ra\s*=\s*(.+)$"#, line) {
                    outputs += 1; guard outputs == 1 else { throw PVTAError("Mỗi nút chỉ có một !dau-ra.") }; c = .output(try WorkExpression.parse(m[0]))
                } else if let m = Self.match(#"^!in\s+(.+)$"#, line) { c = .print(try WorkExpression.parse(m[0])) }
                else if let m = Self.match(#"^!lap-lai\s+\"([^\"]+)\"\s+neu\s+(.+)$"#, line) { c = .repeatFrom(m[0], try WorkExpression.parse(m[1])) }
                else if let m = Self.match(#"^!dung\s+neu\s+(.+)$"#, line) { c = .stop(try WorkExpression.parse(m[0])) }
                else if let m = Self.match(#"^!ham\s+([^\s(]+)\(([^)]*)\)\s*$"#, line) {
                    let n = try name(m[0]), args = try m[1].split(separator: ",").map { try name($0.trimmingCharacters(in: .whitespaces)) }
                    guard Set(args).count == args.count else { throw PVTAError("Tham số hàm trùng nhau.") }
                    func block(_ open: String, _ close: String, required: Bool) throws -> String {
                        while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                        guard i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(open) else {
                            if required { throw PVTAError("Hàm cần khối \(open) ... \(close).") }; return ""
                        }
                        var parts: [String] = []; var first = true
                        while i < lines.count {
                            var t = lines[i].trimmingCharacters(in: .whitespaces); i += 1
                            if first { t = String(t.dropFirst()); first = false }
                            if t.hasSuffix(close) { parts.append(String(t.dropLast())); return parts.joined(separator: "\n") }
                            parts.append(t)
                        }
                        throw PVTAError("Khối hàm chưa đóng.")
                    }
                    let description = try block("[", "]", required: true), output = try block("{", "}", required: false)
                    let fields = try output.split(whereSeparator: { $0 == "," || $0 == "\n" }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { part in
                        guard let m = Self.match(#"^\s*([^:]+):\s*.+$"#, String(part)) else { throw PVTAError("Đầu ra hàm cần tên: mô tả.") }; return try name(m[0].trimmingCharacters(in: .whitespaces))
                    }
                    guard Set(fields).count == fields.count else { throw PVTAError("Trường đầu ra hàm trùng nhau.") }
                    c = .function(WorkFunction(name: n, parameters: args, description: description, fields: fields, outputDescription: output))
                } else if let m = Self.match(#"^!goi\s+(?:([^\s=]+)\s*=\s*)?([^\s(]+)\((.*)\)\s*$"#, line) {
                    let e = try WorkExpression.parse("[" + m[2] + "]")
                    guard case .array(let args) = e else { throw PVTAError("Tham số gọi hàm không hợp lệ.") }
                    c = .call(m[0].isEmpty ? nil : try name(m[0]), try name(m[1]), args)
                } else { throw PVTAError("Chỉ thị không hợp lệ: \(line)") }
                commands.append((number, c))
            } catch { throw PVTAError("Dòng \(number): " + UserMessage.text(for: error)) }
        }
        prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WorkDefinition {
    func scopes(for step: String) -> [String] {
        [""] + (advanced?.frames ?? []).filter { $0.steps.contains(step) }.sorted { $0.steps.count > $1.steps.count }.map(\.id)
    }
    func validateAdvanced() throws {
        let frames = advanced?.frames ?? [], ids = Set(steps.map(\.id))
        if kind != "workflow", frames.contains(where: { !($0.decl ?? "").isEmpty }) { throw PVTAError("Khai báo khung chỉ dùng trong quy trình độc lập.") }
        guard Set(frames.map(\.id)).count == frames.count, frames.allSatisfy({ !$0.id.isEmpty && !$0.steps.isEmpty && Set($0.steps).count == $0.steps.count && Set($0.steps).isSubset(of: ids) }) else { throw PVTAError("Khung cần mã riêng và danh sách nút có thật, không lặp.") }
        for (i, a) in frames.enumerated() {
            let x = Set(a.steps)
            for b in frames.dropFirst(i + 1) {
                let y = Set(b.steps)
                guard x != y, x.isDisjoint(with: y) || x.isSubset(of: y) || y.isSubset(of: x) else { throw PVTAError("Khung chồng một phần hoặc có cùng tập nút.") }
            }
            guard frames.filter({ x.isSubset(of: Set($0.steps)) }).count <= 3 else { throw PVTAError("Khung chỉ được lồng tối đa 3 tầng.") }
        }
        var declarations: [String: Set<String>] = [:]
        func add(_ program: WorkProgram, scope: String) throws {
            for (_, c) in program.commands {
                let n: String?
                switch c { case .declare(let v, _), .input(let v, _): n = v; case .function(let f): n = f.name; default: n = nil }
                if let n { guard declarations[scope, default: []].insert(n).inserted else { throw PVTAError("Trùng khai báo \(n) trong cùng phạm vi.") } }
            }
        }
        for f in frames { try add(WorkProgram(f.decl ?? ""), scope: f.id) }
        for s in steps {
            do {
                let p = try WorkProgram(s.prompt)
                if kind != "workflow", !p.commands.isEmpty { throw PVTAError("Chỉ thị trạng thái chỉ dùng trong quy trình độc lập.") }
                try add(p, scope: scopes(for: s.id).last!)
            } catch { throw PVTAError("Bước \(s.id): " + UserMessage.text(for: error)) }
        }
        for f in frames {
            let parents = frames.filter { $0.id != f.id && Set(f.steps).isSubset(of: Set($0.steps)) }.map(\.id) + [""]
            for parent in parents where !(declarations[f.id, default: []].isDisjoint(with: declarations[parent, default: []])) { throw PVTAError("Khai báo trong khung che tên ở phạm vi cha.") }
        }
    }
    var hasLanguage: Bool {
        steps.contains { (try? WorkProgram($0.prompt).commands.isEmpty) == false } || (advanced?.frames.contains { !($0.decl ?? "").isEmpty } ?? false)
    }
}
