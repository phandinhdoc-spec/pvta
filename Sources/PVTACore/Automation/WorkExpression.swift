import Foundation

/// Biểu thức thuần, không có lời gọi hàm, tệp hay mã của hệ điều hành.
indirect enum WorkExpression: Sendable {
    case value(JSONValue), variable(String), array([Self]), object([String: Self])
    case unary(String, Self), binary(String, Self, Self), member(Self, JSONValue)

    static func parse(_ source: String) throws -> Self {
        guard source.count <= 20000 else { throw PVTAError("Biểu thức vượt 20.000 ký tự.") }
        var p = try Parser(source)
        let result = try p.expression()
        guard p.peek == "<end>" else { throw PVTAError("Biểu thức còn ký tự không hợp lệ: \(p.peek)") }
        return result
    }
    func evaluate(_ variables: [String: JSONValue], depth: Int = 0) throws -> JSONValue {
        guard depth < 64 else { throw PVTAError("Biểu thức lồng quá sâu.") }
        func ev(_ x: Self) throws -> JSONValue { try x.evaluate(variables, depth: depth + 1) }
        func num(_ v: JSONValue) throws -> Double { guard let n = v.number else { throw PVTAError("Phép tính cần giá trị số.") }; return n }
        func bool(_ v: JSONValue) throws -> Bool { guard let b = v.bool else { throw PVTAError("Điều kiện cần true hoặc false.") }; return b }
        switch self {
        case .value(let v): return v
        case .variable(let name): guard let v = variables[name] else { throw PVTAError("Chưa khai báo biến $\(name).") }; return v
        case .array(let a): return try .array(a.map(ev))
        case .object(let o): return try .object(o.mapValues(ev))
        case .member(let base, let key):
            let v = try ev(base)
            if let k = key.string, let value = v[k] { return value }
            if case .array(let a) = v, let n = key.number, n >= 0, n < Double(a.count), n.rounded() == n { return a[Int(n)] }
            throw PVTAError("Không tìm thấy trường hoặc chỉ số trong giá trị.")
        case .unary(let op, let x):
            let v = try ev(x)
            return try op == "!" ? .bool(!bool(v)) : .number(-num(v))
        case .binary(let op, let a, let b):
            let x = try ev(a)
            if op == "&&" { return try .bool(bool(x) && bool(ev(b))) }
            if op == "||" { return try .bool(bool(x) || bool(ev(b))) }
            let y = try ev(b)
            if op == "==" { return .bool(x == y) }; if op == "!=" { return .bool(x != y) }
            if op == "+", let l = x.string, let r = y.string {
                guard l.count + r.count <= 60000 else { throw PVTAError("Giá trị chuỗi vượt 60.000 ký tự.") }
                return .string(l + r)
            }
            let l = try num(x), r = try num(y)
            switch op {
            case "<": return .bool(l < r)
            case "<=": return .bool(l <= r)
            case ">": return .bool(l > r)
            case ">=": return .bool(l >= r)
            default:
                if (op == "/" || op == "%") && r == 0 { throw PVTAError("Không chia cho không.") }
                let n: Double
                switch op { case "+": n = l + r; case "-": n = l - r; case "*": n = l * r; case "/": n = l / r; default: n = l.truncatingRemainder(dividingBy: r) }
                guard n.isFinite else { throw PVTAError("Kết quả số vượt giới hạn.") }; return .number(n)
            }
        }
    }
    var variables: Set<String> {
        switch self {
        case .variable(let n): return [n]
        case .array(let a): return a.reduce(into: []) { $0.formUnion($1.variables) }
        case .object(let o): return o.values.reduce(into: []) { $0.formUnion($1.variables) }
        case .unary(_, let a), .member(let a, _): return a.variables
        case .binary(_, let a, let b): return a.variables.union(b.variables)
        case .value: return []
        }
    }
    static func text(_ v: JSONValue) -> String {
        if let s = v.string { return s }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
    }

    private struct Parser {
        var tokens: [String] = []; var i = 0; var depth = 0
        var peek: String { i < tokens.count ? tokens[i] : "<end>" }
        init(_ source: String) throws {
            let regex = try NSRegularExpression(pattern: #"\s+|\"(?:\\.|[^\"\\])*\"|\$[A-Za-z_][A-Za-z0-9_-]*|(?:[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)|[A-Za-z_][A-Za-z0-9_-]*|==|!=|<=|>=|&&|\|\||[+*/%<>()\[\]{},:!.\-]"#)
            let ns = source as NSString; var end = 0
            for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                guard m.range.location == end else { throw PVTAError("Ký tự không hợp lệ trong biểu thức.") }
                let t = ns.substring(with: m.range); end = NSMaxRange(m.range)
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tokens.append(t) }
            }
            guard end == ns.length, tokens.count <= 4000 else { throw PVTAError("Biểu thức không hợp lệ hoặc quá dài.") }
        }
        mutating func take() -> String { let t = peek; i += 1; return t }
        mutating func expect(_ t: String) throws { guard take() == t else { throw PVTAError("Biểu thức cần ký tự \(t).") } }
        mutating func expression(_ minimum: Int = 0) throws -> WorkExpression {
            depth += 1; defer { depth -= 1 }
            guard depth < 64 else { throw PVTAError("Biểu thức lồng quá sâu.") }
            var left = try atom()
            let ranks = ["||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6]
            while let rank = ranks[peek], rank >= minimum {
                let op = take(); left = .binary(op, left, try expression(rank + 1))
            }
            return left
        }
        mutating func atom() throws -> WorkExpression {
            let t = take(); var result: WorkExpression
            if t == "!" || t == "-" { return .unary(t, try expression(7)) }
            if t == "(" { result = try expression(); try expect(")") }
            else if t == "[" {
                var a: [WorkExpression] = []
                while peek != "]" { a.append(try expression()); if peek != "," { break }; _ = take() }
                try expect("]"); result = .array(a)
            } else if t == "{" {
                var o: [String: WorkExpression] = [:]
                while peek != "}" {
                    let raw = take(); let key = raw.hasPrefix("\"") ? try JSONDecoder().decode(String.self, from: Data(raw.utf8)) : raw
                    guard WorkProgram.validName(key), o[key] == nil else { throw PVTAError("Tên trường không hợp lệ hoặc trùng nhau.") }
                    try expect(":"); o[key] = try expression(); if peek != "," { break }; _ = take()
                }
                try expect("}"); result = .object(o)
            } else if t.hasPrefix("$") { result = .variable(String(t.dropFirst())) }
            else if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(t.utf8)) { result = .value(value) }
            else { throw PVTAError("Giá trị không hợp lệ: \(t).") }
            while peek == "." || peek == "[" {
                if take() == "." { let key = take(); guard WorkProgram.validName(key) else { throw PVTAError("Tên trường không hợp lệ.") }; result = .member(result, .string(key)) }
                else {
                    let key = take(); guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(key.utf8)), v.string != nil || v.number != nil else { throw PVTAError("Chỉ số phải là hằng số hoặc chuỗi.") }
                    try expect("]"); result = .member(result, v)
                }
            }
            return result
        }
    }
}
