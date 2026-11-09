import Foundation

public struct BrainSymbol: Codable, Sendable, Equatable {
    public var name: String
    /// function, method, class, struct, enum, protocol, type, test, module, heading, constant
    public var kind: String
    public var line: Int
    public var end: Int
    /// Tên ký hiệu bao quanh (nếu có).
    public var scope: String?
    public var depth: Int
}

public struct BrainFile: Codable, Sendable, Equatable {
    /// Đường dẫn tương đối trong phạm vi (dấu `/`).
    public var path: String
    public var abs: String
    public var lang: String
    public var size: Int
    public var mtime: Double
    public var lines: Int
    public var symbols: [BrainSymbol]
    public var imports: [String]
}

/// Rút ký hiệu và import bằng quy tắc theo ngôn ngữ (không cần ctags). Đủ dùng để điều hướng; không thay cho trình biên dịch.
enum BrainParse {
    static let langs: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "py": "python",
        "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "c",
        "rb": "ruby", "php": "php", "lua": "lua", "sh": "shell", "bash": "shell", "zsh": "shell", "md": "markdown", "markdown": "markdown", "typ": "typst", "scala": "scala",
        "dart": "dart", "sql": "sql", "css": "css", "scss": "css", "toml": "toml", "yaml": "yaml", "yml": "yaml", "json": "json", "html": "html",
    ]
    static let hasSymbols: Set<String> = ["swift", "typescript", "javascript", "python", "go", "rust", "java", "kotlin", "csharp", "c", "cpp", "ruby", "php", "lua", "shell", "markdown", "typst", "scala", "dart"]
    static let braceLangs: Set<String> = ["swift", "typescript", "javascript", "go", "rust", "java", "kotlin", "csharp", "c", "cpp", "php", "scala", "dart", "shell"]
    static let skipDirs: Set<String> = ["node_modules", "target", "dist", "build", ".build", "Pods", "vendor", "__pycache__", ".git", "DerivedData", ".venv", "venv", ".next", "coverage"]

    private struct Rule { let regex: NSRegularExpression; let kind: String; let nameGroup: Int; let keyword: String? }
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let rules: [String: [Rule]] = [
        "swift": [
            Rule(regex: rx(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|class|override|mutating|nonisolated|indirect|async|convenience|required)\s+)*(func)\s+([A-Za-z_]\w*)"#), kind: "function", nameGroup: 2, keyword: "func"),
            Rule(regex: rx(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|indirect)\s+)*(class|struct|enum|protocol|actor|extension|typealias)\s+([A-Za-z_][\w.]*)"#), kind: "type", nameGroup: 2, keyword: nil),
            Rule(regex: rx(#"^\s*(?:(?:public|internal|private|convenience|required)\s+)*(init)\??\s*\("#), kind: "function", nameGroup: 1, keyword: "init"),
        ],
        "typescript": jsRules, "javascript": jsRules,
        "python": [Rule(regex: rx(#"^\s*(?:async\s+)?(def|class)\s+(\w+)"#), kind: "function", nameGroup: 2, keyword: nil)],
        "go": [
            Rule(regex: rx(#"^func\s+(?:\([^)]*\)\s*)?(\w+)"#), kind: "function", nameGroup: 1, keyword: "func"),
            Rule(regex: rx(#"^type\s+(\w+)\s+(?:struct|interface)"#), kind: "struct", nameGroup: 1, keyword: "type"),
        ],
        "rust": [
            Rule(regex: rx(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+(\w+)"#), kind: "function", nameGroup: 1, keyword: "fn"),
            Rule(regex: rx(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(struct|enum|trait|mod|type)\s+(\w+)"#), kind: "type", nameGroup: 2, keyword: nil),
            Rule(regex: rx(#"^\s*impl(?:<[^>]*>)?\s+(?:[\w:<>]+\s+for\s+)?(\w+)"#), kind: "type", nameGroup: 1, keyword: "impl"),
        ],
        "java": jvmRules, "csharp": jvmRules, "scala": jvmRules, "dart": jvmRules,
        "kotlin": [
            Rule(regex: rx(#"^\s*(?:(?:public|private|protected|internal|override|suspend|open|abstract|inline)\s+)*fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?(\w+)"#), kind: "function", nameGroup: 1, keyword: "fun"),
            Rule(regex: rx(#"^\s*(?:(?:public|private|protected|internal|open|abstract|data|sealed|enum)\s+)*(class|interface|object)\s+(\w+)"#), kind: "type", nameGroup: 2, keyword: nil),
        ],
        "c": cRules, "cpp": cRules,
        "ruby": [
            Rule(regex: rx(#"^\s*def\s+(?:self\.)?([\w?!=]+)"#), kind: "function", nameGroup: 1, keyword: "def"),
            Rule(regex: rx(#"^\s*(class|module)\s+([A-Z][\w:]*)"#), kind: "type", nameGroup: 2, keyword: nil),
        ],
        "php": [
            Rule(regex: rx(#"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+(\w+)"#), kind: "function", nameGroup: 1, keyword: "function"),
            Rule(regex: rx(#"^\s*(?:abstract\s+|final\s+)?(class|interface|trait)\s+(\w+)"#), kind: "type", nameGroup: 2, keyword: nil),
        ],
        "lua": [Rule(regex: rx(#"^\s*(?:local\s+)?function\s+([\w.:]+)"#), kind: "function", nameGroup: 1, keyword: "function")],
        "shell": [
            Rule(regex: rx(#"^\s*(?:function\s+)?(\w[\w-]*)\s*\(\)\s*\{"#), kind: "function", nameGroup: 1, keyword: "("),
            Rule(regex: rx(#"^\s*function\s+(\w[\w-]*)"#), kind: "function", nameGroup: 1, keyword: "function"),
        ],
    ]
    private static let jsRules: [Rule] = [
        Rule(regex: rx(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#), kind: "function", nameGroup: 1, keyword: "function"),
        Rule(regex: rx(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?(class|interface|enum)\s+([A-Za-z_$][\w$]*)"#), kind: "type", nameGroup: 2, keyword: nil),
        Rule(regex: rx(#"^\s*(?:export\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*="#), kind: "type", nameGroup: 1, keyword: "type"),
        Rule(regex: rx(#"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::\s*[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)"#), kind: "function", nameGroup: 1, keyword: "="),
        Rule(regex: rx(#"^\s+(?:(?:public|private|protected|static|async|readonly|get|set)\s+)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?::\s*[^{]+)?\{\s*$"#), kind: "method", nameGroup: 1, keyword: "("),
        Rule(regex: rx(#"^\s*(?:it|test|describe)\(\s*['"`]([^'"`]+)['"`]"#), kind: "test", nameGroup: 1, keyword: "("),
    ]
    private static let jvmRules: [Rule] = [
        Rule(regex: rx(#"^\s*(?:(?:public|private|protected|internal|static|final|abstract|sealed|partial|data|open)\s+)*(class|interface|enum|record|object|trait|struct)\s+(\w+)"#), kind: "type", nameGroup: 2, keyword: nil),
        Rule(regex: rx(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|protected|internal|static|final|abstract|override|virtual|async|synchronized|native)\s+)+(?:<[^>]*>\s*)?[\w<>\[\],.?]+\s+(\w+)\s*\([^;]*$"#), kind: "method", nameGroup: 1, keyword: "("),
        Rule(regex: rx(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|protected)\s+)?(?:static\s+)?void\s+(\w+)\s*\("#), kind: "method", nameGroup: 1, keyword: "void"),
        Rule(regex: rx(#"^\s*(?:Future<[^>]*>|void|[\w<>?]+)\s+(\w+)\s*\([^;]*\)\s*(?:async\s*)?(?:\{|=>)"#), kind: "method", nameGroup: 1, keyword: "("),
    ]
    private static let cRules: [Rule] = [
        Rule(regex: rx(#"^\s*(?:typedef\s+)?(struct|class|enum|union|namespace)\s+(\w+)"#), kind: "type", nameGroup: 2, keyword: nil),
        Rule(regex: rx(#"^[A-Za-z_][\w\s\*&:<>,]*?[\s\*&]+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const\s*)?(?:\{|$)"#), kind: "function", nameGroup: 1, keyword: "("),
    ]
    private static let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "return", "else", "guard", "do", "sizeof", "defined", "function", "constructor", "super"]

    private static let importRules: [String: NSRegularExpression] = [
        "swift": rx(#"^\s*(?:@\w+\s+)?import\s+(\w+)"#),
        "typescript": rx(#"(?:from\s+|require\(\s*|import\s+)['"]([^'"]+)['"]"#), "javascript": rx(#"(?:from\s+|require\(\s*|import\s+)['"]([^'"]+)['"]"#),
        "python": rx(#"^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))"#),
        "go": rx(#"^\s*(?:import\s+)?(?:\w+\s+)?"([\w./-]+)"\s*$"#),
        "rust": rx(#"^\s*(?:pub\s+)?use\s+([\w:]+)"#),
        "java": rx(#"^\s*import\s+(?:static\s+)?([\w.]+)"#), "kotlin": rx(#"^\s*import\s+([\w.]+)"#), "csharp": rx(#"^\s*using\s+([\w.]+)\s*;"#),
        "c": rx(#"^\s*#\s*include\s+[<"]([^>"]+)"#), "cpp": rx(#"^\s*#\s*include\s+[<"]([^>"]+)"#),
        "ruby": rx(#"^\s*require(?:_relative)?\s+['"]([^'"]+)['"]"#), "php": rx(#"^\s*(?:use|require(?:_once)?|include(?:_once)?)\s+['"]?([\w\\/.]+)"#),
    ]

    static func language(_ path: String) -> String? { langs[(path as NSString).pathExtension.lowercased()] ?? ((path as NSString).lastPathComponent == "Makefile" ? "makefile" : nil) }

    static func parse(text: String, lang: String) -> (symbols: [BrainSymbol], imports: [String], lines: Int) {
        let lines = text.components(separatedBy: "\n")
        var imports: [String] = []
        if let ir = importRules[lang] {
            for l in lines where l.count < 300 {
                let ns = l as NSString
                if let m = ir.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                    for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound { imports.append(ns.substring(with: m.range(at: g))); break }
                }
            }
        }
        guard hasSymbols.contains(lang) else { return ([], Array(Set(imports)).sorted(), lines.count) }
        var syms: [BrainSymbol] = []
        if lang == "markdown" || lang == "typst" {
            let h = lang == "markdown" ? rx(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#) : rx(#"^(=+)\s+(.+)$"#)
            var inFence = false
            for (i, l) in lines.enumerated() {
                if lang == "markdown", l.hasPrefix("```") { inFence.toggle() }
                guard !inFence, let m = h.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { continue }
                syms.append(BrainSymbol(name: (l as NSString).substring(with: m.range(at: 2)), kind: "heading", line: i + 1, end: i + 1, scope: nil, depth: (l as NSString).substring(with: m.range(at: 1)).count))
            }
            for i in syms.indices {
                let next = syms[(i + 1)...].first { $0.depth <= syms[i].depth }
                syms[i].end = (next?.line ?? lines.count + 1) - 1
            }
            return (nest(syms, headings: true), [], lines.count)
        }
        let list = rules[lang] ?? []
        for (i, l) in lines.enumerated() {
            guard l.count < 400, !l.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let ns = l as NSString
            for r in list {
                if let k = r.keyword, !l.contains(k) { continue }
                guard let m = r.regex.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)), m.range(at: r.nameGroup).location != NSNotFound else { continue }
                var name = ns.substring(with: m.range(at: r.nameGroup))
                if keywords.contains(name) && r.kind != "type" { continue }
                var kind = r.kind
                if kind == "type", m.numberOfRanges > 2, m.range(at: 1).location != NSNotFound {
                    let k = ns.substring(with: m.range(at: 1))
                    kind = ["class": "class", "struct": "struct", "enum": "enum", "protocol": "protocol", "trait": "protocol", "interface": "protocol", "actor": "class", "extension": "type", "mod": "module", "namespace": "module", "record": "class", "object": "class", "module": "module"][k] ?? "type"
                }
                if lang == "swift", l.contains("@Test") || (i > 0 && lines[i - 1].contains("@Test")) { kind = "test" }
                if lang == "python", ns.substring(with: m.range(at: 1)) == "class" { kind = "class" }
                if lang == "rust", kind == "type", l.contains("impl") { name = "impl " + name }
                if lang == "go", r.kind == "function", l.range(of: #"^func\s+\("#, options: .regularExpression) != nil { kind = "method" }
                if (name.hasPrefix("test") || name.hasPrefix("Test")) && kind == "function" { kind = "test" }
                syms.append(BrainSymbol(name: name, kind: kind, line: i + 1, end: i + 1, scope: nil, depth: 0))
                break
            }
        }
        // Dòng kết thúc: theo ngoặc nhọn hoặc theo thụt lề (Python/Ruby/Lua).
        for i in syms.indices { syms[i].end = endLine(lang, lines, start: syms[i].line, next: i + 1 < syms.count ? syms[i + 1].line : lines.count + 1) }
        return (nest(syms, headings: false), Array(Set(imports)).sorted(), lines.count)
    }

    private static func endLine(_ lang: String, _ lines: [String], start: Int, next: Int) -> Int {
        let i = start - 1
        if lang == "python" || lang == "ruby" || lang == "lua" {
            let indent = lines[i].prefix { $0 == " " || $0 == "\t" }.count
            var last = start
            for j in (i + 1)..<max(i + 1, lines.count) {
                let l = lines[j], t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                let ind = l.prefix { $0 == " " || $0 == "\t" }.count
                if ind <= indent {
                    if lang != "python", t == "end" || t.hasPrefix("end ") { last = j + 1 }   // Ruby, Lua: dòng end khép khối
                    break
                }
                last = j + 1
            }
            return last
        }
        guard braceLangs.contains(lang) else { return start }
        var depth = 0, seen = false
        var j = i
        while j < lines.count && j < i + 2000 {
            var inStr: Character?
            var prev: Character = " "
            for ch in lines[j] {
                if let q = inStr { if ch == q && prev != "\\" { inStr = nil } }
                else if ch == "\"" || ch == "'" || ch == "`" { inStr = ch }
                else if ch == "{" { depth += 1; seen = true }
                else if ch == "}" { depth -= 1 }
                prev = ch
            }
            if seen && depth <= 0 { return j + 1 }
            if !seen && j - i >= 3 { return start }          // khai báo không có thân ({ ở dòng xa) hoặc một dòng
            if !seen, lines[j].trimmingCharacters(in: .whitespaces).hasSuffix(";") { return j + 1 }
            j += 1
        }
        return min(next - 1, lines.count)
    }

    /// Gán ký hiệu cha (ký hiệu gần nhất bao quanh), độ sâu và đổi `function` lồng trong kiểu thành `method`.
    private static func nest(_ syms: [BrainSymbol], headings: Bool) -> [BrainSymbol] {
        var out = syms, stack: [Int] = []
        for i in out.indices {
            while let top = stack.last, !(out[top].line <= out[i].line && out[i].line <= out[top].end && top != i) || (headings && out[top].depth >= out[i].depth) { stack.removeLast() }
            if let p = stack.last, !headings {
                out[i].scope = out[p].name; out[i].depth = stack.count
                if out[i].kind == "function", ["type", "class", "struct", "enum", "protocol", "module"].contains(out[p].kind) { out[i].kind = "method" }
            } else if let p = stack.last { out[i].scope = out[p].name }
            if !headings { out[i].depth = stack.count }
            stack.append(i)
        }
        return out
    }
}
