import Foundation

/// Giá trị trong bảng tính.
enum XValue: Equatable, Sendable {
    case empty, number(Double), text(String), bool(Bool), error(String)

    var display: String {
        switch self {
        case .empty: return ""
        case .number(let d): return XValue.format(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        }
    }

    static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        let s = String(format: "%.15g", d)
        return s
    }
}

/// Bộ tính công thức Excel thường dùng ở trường học (điểm, xếp loại, thống kê). Công thức ngoài phạm vi hỗ trợ trả về lỗi
/// `unsupported` để người gọi biết là chưa tính được (Excel vẫn tự tính khi mở tệp).
struct FormulaEngine {
    struct Unsupported: Error { let name: String }

    /// Sheet → ref ("A1") → ô.
    private(set) var sheets: [String: [String: (value: XValue, formula: String?)]]
    private var memo: [String: XValue] = [:]
    private var busy: Set<String> = []

    init(sheets: [String: [String: (value: XValue, formula: String?)]]) { self.sheets = sheets }

    // MARK: Tham chiếu

    static func column(_ letters: String) -> Int { letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } }

    static func letters(_ n: Int) -> String {
        var n = n, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    /// "B12" → (cột 2, hàng 12).
    static func split(_ ref: String) -> (col: Int, row: Int)? {
        let r = ref.replacingOccurrences(of: "$", with: "")
        let l = r.prefix { $0.isLetter }
        guard !l.isEmpty, l.count <= 3, let row = Int(r.dropFirst(l.count)), row >= 1, row <= 1_048_576 else { return nil }
        return (column(String(l)), row)
    }

    // MARK: Tính

    /// Giá trị của một ô: công thức được tính, ô thường lấy giá trị đã lưu.
    mutating func value(sheet: String, ref: String) -> XValue {
        guard let cell = sheets[sheet]?[ref] else { return .empty }
        guard let f = cell.formula else { return cell.value }
        let key = sheet + "!" + ref
        if let m = memo[key] { return m }
        if busy.contains(key) { return .error("#REF!") }   // tham chiếu vòng
        busy.insert(key)
        defer { busy.remove(key) }
        var p = Parser(f.hasPrefix("=") ? String(f.dropFirst()) : f, sheet: sheet)
        let out: XValue
        do { out = try p.parse(&self).scalar } catch let u as Unsupported { out = .error("#UNSUPPORTED:" + u.name) } catch { out = .error("#NAME?") }
        memo[key] = out
        return out
    }

    // MARK: Phân tích cú pháp và tính ngay

    private indirect enum V {
        case one(XValue)
        case grid([[XValue]])
        var scalar: XValue {
            switch self {
            case .one(let v): return v
            case .grid(let g): return g.first?.first ?? .empty
            }
        }
        var flat: [XValue] {
            switch self {
            case .one(let v): return [v]
            case .grid(let g): return g.flatMap { $0 }
            }
        }
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0
        let sheet: String
        init(_ s: String, sheet: String) { chars = Array(s); self.sheet = sheet }

        mutating func parse(_ e: inout FormulaEngine) throws -> V {
            let v = try compare(&e)
            skip()
            if pos < chars.count { throw Unsupported(name: "cú pháp") }
            return v
        }

        mutating func skip() { while pos < chars.count, chars[pos] == " " { pos += 1 } }
        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        mutating func eat(_ s: String) -> Bool {
            skip()
            let a = Array(s)
            if pos + a.count <= chars.count, Array(chars[pos..<pos + a.count]) == a { pos += a.count; return true }
            return false
        }

        static func num(_ v: XValue) -> Double? {
            switch v {
            case .number(let d): return d
            case .bool(let b): return b ? 1 : 0
            case .empty: return 0
            case .text(let s): return Double(s.trimmingCharacters(in: .whitespaces))
            case .error: return nil
            }
        }

        static func err(_ a: XValue, _ b: XValue? = nil) -> XValue? {
            if case .error = a { return a }
            if let b, case .error = b { return b }
            return nil
        }

        mutating func compare(_ e: inout FormulaEngine) throws -> V {
            var l = try concat(&e)
            while true {
                skip()
                var op: String?
                for c in ["<=", ">=", "<>", "=", "<", ">"] where eat(c) { op = c; break }
                guard let op else { return l }
                let r = try concat(&e)
                l = .one(Self.cmp(l.scalar, r.scalar, op))
            }
        }

        static func cmp(_ a: XValue, _ b: XValue, _ op: String) -> XValue {
            if let e = err(a, b) { return e }
            func rank(_ v: XValue) -> Int { switch v { case .number, .empty: return 0; case .text: return 1; default: return 2 } }
            var c = 0
            switch (a, b) {
            case (.text(let x), .text(let y)): c = x.lowercased() < y.lowercased() ? -1 : x.lowercased() == y.lowercased() ? 0 : 1
            case (.bool(let x), .bool(let y)): c = x == y ? 0 : (!x ? -1 : 1)
            default:
                if rank(a) != rank(b) { c = rank(a) < rank(b) ? -1 : 1 }
                else { let x = num(a) ?? 0, y = num(b) ?? 0; c = x < y ? -1 : x == y ? 0 : 1 }
            }
            switch op {
            case "=": return .bool(c == 0)
            case "<>": return .bool(c != 0)
            case "<": return .bool(c < 0)
            case ">": return .bool(c > 0)
            case "<=": return .bool(c <= 0)
            default: return .bool(c >= 0)
            }
        }

        mutating func concat(_ e: inout FormulaEngine) throws -> V {
            var l = try additive(&e)
            while eat("&") {
                let r = try additive(&e)
                if let er = Self.err(l.scalar, r.scalar) { l = .one(er) } else { l = .one(.text(l.scalar.display + r.scalar.display)) }
            }
            return l
        }

        mutating func additive(_ e: inout FormulaEngine) throws -> V {
            var l = try term(&e)
            while true {
                skip()
                let plus = peek() == "+", minus = peek() == "-"
                guard plus || minus else { return l }
                pos += 1
                let r = try term(&e)
                l = .one(Self.arith(l.scalar, r.scalar) { plus ? $0 + $1 : $0 - $1 })
            }
        }

        static func arith(_ a: XValue, _ b: XValue, _ f: (Double, Double) -> Double) -> XValue {
            if let e = err(a, b) { return e }
            guard let x = num(a), let y = num(b) else { return .error("#VALUE!") }
            let r = f(x, y)
            return r.isFinite ? .number(r) : .error("#NUM!")
        }

        mutating func term(_ e: inout FormulaEngine) throws -> V {
            var l = try power(&e)
            while true {
                skip()
                let mul = peek() == "*", div = peek() == "/"
                guard mul || div else { return l }
                pos += 1
                let r = try power(&e)
                if div, let y = Self.num(r.scalar), y == 0, Self.err(l.scalar) == nil { l = .one(.error("#DIV/0!")); continue }
                l = .one(Self.arith(l.scalar, r.scalar) { mul ? $0 * $1 : $0 / $1 })
            }
        }

        mutating func power(_ e: inout FormulaEngine) throws -> V {
            var l = try unary(&e)
            while eat("^") {
                let r = try unary(&e)
                l = .one(Self.arith(l.scalar, r.scalar) { Foundation.pow($0, $1) })
            }
            return l
        }

        mutating func unary(_ e: inout FormulaEngine) throws -> V {
            skip()
            if eat("-") {
                let v = try unary(&e).scalar
                if let er = Self.err(v) { return .one(er) }
                return .one(Self.num(v).map { .number(-$0) } ?? .error("#VALUE!"))
            }
            if eat("+") { return try unary(&e) }
            var v = try primary(&e)
            while eat("%") { v = .one(Self.arith(v.scalar, .number(100)) { $0 / $1 }) }
            return v
        }

        mutating func primary(_ e: inout FormulaEngine) throws -> V {
            skip()
            guard let c = peek() else { throw Unsupported(name: "cú pháp") }
            if c == "(" {
                pos += 1
                let v = try compare(&e)
                guard eat(")") else { throw Unsupported(name: "cú pháp") }
                return v
            }
            if c == "\"" {
                pos += 1
                var s = ""
                while pos < chars.count {
                    if chars[pos] == "\"" { if pos + 1 < chars.count, chars[pos + 1] == "\"" { s.append("\""); pos += 2; continue }; pos += 1; return .one(.text(s)) }
                    s.append(chars[pos]); pos += 1
                }
                throw Unsupported(name: "cú pháp")
            }
            if c.isNumber || c == "." {
                var s = ""
                while let d = peek(), d.isNumber || d == "." { s.append(d); pos += 1 }
                if let d = peek(), d == "e" || d == "E", pos + 1 < chars.count, chars[pos + 1].isNumber || chars[pos + 1] == "-" || chars[pos + 1] == "+" {
                    s.append(d); pos += 1
                    while let d = peek(), d.isNumber || d == "-" || d == "+" { s.append(d); pos += 1 }
                }
                guard let v = Double(s) else { throw Unsupported(name: "số") }
                return .one(.number(v))
            }
            if c == "#" {
                var s = ""
                while let d = peek(), d != ")" && d != "," && d != " " { s.append(d); pos += 1 }
                return .one(.error(s))
            }
            // Tên sheet có dấu nháy: 'Điểm HK1'!A1
            var sheetName: String?
            if c == "'" {
                pos += 1
                var s = ""
                while pos < chars.count, chars[pos] != "'" { s.append(chars[pos]); pos += 1 }
                pos += 1
                guard peek() == "!" else { throw Unsupported(name: "cú pháp") }
                pos += 1
                sheetName = s
            }
            var word = ""
            while let d = peek(), d.isLetter || d.isNumber || d == "_" || d == "." || d == "$" { word.append(d); pos += 1 }
            if sheetName == nil, peek() == "!" {   // Sheet1!A1 không nháy
                pos += 1; sheetName = word; word = ""
                while let d = peek(), d.isLetter || d.isNumber || d == "$" { word.append(d); pos += 1 }
            }
            guard !word.isEmpty else { throw Unsupported(name: "cú pháp") }
            if sheetName == nil, peek() == "(" {
                pos += 1
                var args: [V] = [], raw: [(Int, Int)] = []
                skip()
                if !eat(")") {
                    while true {
                        raw.append((pos, 0))
                        args.append(try compare(&e))
                        if eat(",") || eat(";") { continue }
                        guard eat(")") else { throw Unsupported(name: "cú pháp") }
                        break
                    }
                }
                return try e.call(word.uppercased(), args, sheet: sheet, &self, raw: raw)
            }
            let up = word.uppercased()
            if sheetName == nil, up == "TRUE" { return .one(.bool(true)) }
            if sheetName == nil, up == "FALSE" { return .one(.bool(false)) }
            guard FormulaEngine.split(word) != nil else { throw Unsupported(name: word) }
            let target = sheetName ?? sheet
            guard e.sheets[target] != nil else { return .one(.error("#REF!")) }
            if peek() == ":" {
                pos += 1
                var w2 = ""
                while let d = peek(), d.isLetter || d.isNumber || d == "$" { w2.append(d); pos += 1 }
                guard let a = FormulaEngine.split(word), let b = FormulaEngine.split(w2) else { throw Unsupported(name: "vùng") }
                let (c1, c2, r1, r2) = (min(a.col, b.col), max(a.col, b.col), min(a.row, b.row), max(a.row, b.row))
                guard (c2 - c1 + 1) * (r2 - r1 + 1) <= 200_000 else { throw Unsupported(name: "vùng quá lớn") }
                var grid: [[XValue]] = []
                for r in r1...r2 { grid.append((c1...c2).map { e.value(sheet: target, ref: FormulaEngine.letters($0) + String(r)) }) }
                return .grid(grid)
            }
            return .one(e.value(sheet: target, ref: word.replacingOccurrences(of: "$", with: "").uppercased()))
        }
    }

    // MARK: Hàm

    private static func numbers(_ args: [V], strict: Bool = false) -> (nums: [Double], error: XValue?) {
        var out: [Double] = []
        for a in args {
            switch a {
            case .grid(let g):
                for v in g.flatMap({ $0 }) { if case .error = v { return ([], v) }; if case .number(let d) = v { out.append(d) } }
            case .one(let v):
                if case .error = v { return ([], v) }
                if case .number(let d) = v { out.append(d) } else if case .bool(let b) = v { out.append(b ? 1 : 0) }
                else if case .text(let s) = v { if let d = Double(s) { out.append(d) } else { return ([], .error("#VALUE!")) } }
            }
        }
        return (out, nil)
    }

    private static func roundHalfAway(_ x: Double, _ digits: Int) -> Double {
        let p = Foundation.pow(10.0, Double(digits))
        let scaled = Double(String(format: "%.12g", x * p)) ?? x * p     // bỏ nhiễu số thực như Excel (15 chữ số có nghĩa)
        return scaled.rounded(.toNearestOrAwayFromZero) / p
    }

    /// Điều kiện của COUNTIF/SUMIF: "5", ">=5", "<>x", "Giỏi", có ký tự đại diện * và ?.
    private static func matcher(_ crit: XValue) -> (XValue) -> Bool {
        var op = "=", rest = crit.display
        if case .text(let s) = crit {
            for o in ["<=", ">=", "<>", "<", ">", "="] where s.hasPrefix(o) { op = o; rest = String(s.dropFirst(o.count)); break }
        }
        let number = Double(rest)
        return { v in
            if let n = number {
                if case .number(let d) = v { return Parser.cmp(.number(d), .number(n), op) == .bool(true) }
                if case .text(let t) = v, let d = Double(t) { return Parser.cmp(.number(d), .number(n), op) == .bool(true) }
                return op == "<>"
            }
            guard case .text(let t) = v else { return op == "<>" && rest != "" }
            if rest.contains("*") || rest.contains("?") {
                let pat = "^" + NSRegularExpression.escapedPattern(for: rest).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
                let hit = t.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
                return op == "<>" ? !hit : hit
            }
            return Parser.cmp(.text(t), .text(rest), op) == .bool(true)
        }
    }

    private mutating func call(_ name: String, _ args: [V], sheet: String, _ parser: inout Parser, raw: [(Int, Int)]) throws -> V {
        func one(_ v: XValue) -> V { .one(v) }
        func arg(_ i: Int) -> XValue { i < args.count ? args[i].scalar : .empty }
        func need(_ n: ClosedRange<Int>) throws { if !n.contains(args.count) { throw Unsupported(name: name + " (số đối số)") } }
        func n(_ i: Int) -> Double? { Parser.num(arg(i)) }
        switch name {
        case "SUM", "AVERAGE", "MIN", "MAX", "MEDIAN", "PRODUCT":
            let (nums, e) = Self.numbers(args)
            if let e { return one(e) }
            switch name {
            case "SUM": return one(.number(nums.reduce(0, +)))
            case "PRODUCT": return one(.number(nums.reduce(1, *)))
            case "MIN": return one(.number(nums.min() ?? 0))
            case "MAX": return one(.number(nums.max() ?? 0))
            case "MEDIAN":
                guard !nums.isEmpty else { return one(.error("#NUM!")) }
                let s = nums.sorted(); let m = s.count / 2
                return one(.number(s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2))
            default:
                guard !nums.isEmpty else { return one(.error("#DIV/0!")) }
                return one(.number(nums.reduce(0, +) / Double(nums.count)))
            }
        case "COUNT": return one(.number(Double(args.flatMap(\.flat).filter { if case .number = $0 { return true }; return false }.count)))
        case "COUNTA": return one(.number(Double(args.flatMap(\.flat).filter { $0 != .empty && $0 != .text("") }.count)))
        case "COUNTBLANK": return one(.number(Double(args.flatMap(\.flat).filter { $0 == .empty || $0 == .text("") }.count)))
        case "COUNTIF":
            try need(2...2)
            let m = Self.matcher(arg(1))
            return one(.number(Double(args[0].flat.filter(m).count)))
        case "SUMIF", "AVERAGEIF":
            try need(2...3)
            let m = Self.matcher(arg(1))
            let test = args[0].flat, sum = args.count == 3 ? args[2].flat : test
            let hit = zip(test, sum).filter { m($0.0) }.compactMap { Parser.num($0.1) }
            if name == "SUMIF" { return one(.number(hit.reduce(0, +))) }
            return hit.isEmpty ? one(.error("#DIV/0!")) : one(.number(hit.reduce(0, +) / Double(hit.count)))
        case "IF":
            try need(2...3)
            if case .error = arg(0) { return one(arg(0)) }
            let cond: Bool
            switch arg(0) { case .bool(let b): cond = b; case .text: return one(.error("#VALUE!")); default: cond = (n(0) ?? 0) != 0 }
            return cond ? args[1] : (args.count == 3 ? args[2] : one(.bool(false)))
        case "IFS":
            guard args.count >= 2, args.count % 2 == 0 else { throw Unsupported(name: "IFS (số đối số)") }
            for i in stride(from: 0, to: args.count, by: 2) {
                if case .error = args[i].scalar { return args[i] }
                if case .bool(true) = args[i].scalar { return args[i + 1] }
                if case .number(let d) = args[i].scalar, d != 0 { return args[i + 1] }
            }
            return one(.error("#N/A"))
        case "IFERROR":
            try need(2...2)
            if case .error = arg(0) { return args[1] }
            return args[0]
        case "AND", "OR":
            var bs: [Bool] = []
            for v in args.flatMap(\.flat) {
                if case .error = v { return one(v) }
                if case .bool(let b) = v { bs.append(b) } else if case .number(let d) = v { bs.append(d != 0) }
            }
            guard !bs.isEmpty else { return one(.error("#VALUE!")) }
            return one(.bool(name == "AND" ? !bs.contains(false) : bs.contains(true)))
        case "NOT":
            try need(1...1)
            if case .bool(let b) = arg(0) { return one(.bool(!b)) }
            return one(n(0).map { .bool($0 == 0) } ?? .error("#VALUE!"))
        case "ROUND", "ROUNDUP", "ROUNDDOWN":
            try need(1...2)
            if case .error = arg(0) { return one(arg(0)) }
            guard let x = n(0) else { return one(.error("#VALUE!")) }
            let d = Int(n(1) ?? 0)
            if name == "ROUND" { return one(.number(Self.roundHalfAway(x, d))) }
            let p = Foundation.pow(10.0, Double(d))
            let s = Double(String(format: "%.12g", abs(x) * p)) ?? abs(x) * p
            let r = (name == "ROUNDUP" ? s.rounded(.up) : s.rounded(.down)) / p
            return one(.number(x < 0 ? -r : r))
        case "INT": try need(1...1); return one(n(0).map { .number($0.rounded(.down)) } ?? .error("#VALUE!"))
        case "ABS": try need(1...1); return one(n(0).map { .number(abs($0)) } ?? .error("#VALUE!"))
        case "SQRT": try need(1...1); return one(n(0).map { $0 < 0 ? .error("#NUM!") : .number($0.squareRoot()) } ?? .error("#VALUE!"))
        case "POWER": try need(2...2); return one(Parser.arith(arg(0), arg(1)) { Foundation.pow($0, $1) })
        case "MOD":
            try need(2...2)
            guard let a = n(0), let b = n(1) else { return one(.error("#VALUE!")) }
            return b == 0 ? one(.error("#DIV/0!")) : one(.number(a - b * (a / b).rounded(.down)))
        case "SUMPRODUCT":
            guard let first = args.first, case .grid(let g0) = first else { throw Unsupported(name: "SUMPRODUCT") }
            var total = 0.0
            for (i, v) in g0.flatMap({ $0 }).enumerated() {
                var p = Parser.num(v) ?? 0
                for a in args.dropFirst() { let f = a.flat; p *= i < f.count ? (Parser.num(f[i]) ?? 0) : 0 }
                total += p
            }
            return one(.number(total))
        case "RANK":
            try need(2...3)
            guard let x = n(0) else { return one(.error("#VALUE!")) }
            let asc = (n(2) ?? 0) != 0
            let vals = args[1].flat.compactMap { v -> Double? in if case .number(let d) = v { return d }; return nil }
            guard vals.contains(x) else { return one(.error("#N/A")) }
            return one(.number(Double(vals.filter { asc ? $0 < x : $0 > x }.count + 1)))
        case "VLOOKUP":
            try need(3...4)
            guard case .grid(let table) = args[1], let col = n(2), Int(col) >= 1, Int(col) <= (table.first?.count ?? 0) else { return one(.error("#REF!")) }
            let exact = args.count == 4 && { if case .bool(false) = arg(3) { return true }; return (n(3) ?? 1) == 0 }()
            let key = arg(0)
            if exact {
                for row in table where Parser.cmp(row[0], key, "=") == .bool(true) { return one(row[Int(col) - 1]) }
                return one(.error("#N/A"))
            }
            var found: [XValue]?
            for row in table { if Parser.cmp(row[0], key, "<=") == .bool(true) { found = row } else { break } }
            return found.map { one($0[Int(col) - 1]) } ?? one(.error("#N/A"))
        case "CONCATENATE", "CONCAT":
            let all = args.flatMap(\.flat)
            if let e = all.first(where: { if case .error = $0 { return true }; return false }) { return one(e) }
            return one(.text(all.map(\.display).joined()))
        case "LEN": try need(1...1); return one(.number(Double(arg(0).display.count)))
        case "UPPER": try need(1...1); return one(.text(arg(0).display.uppercased()))
        case "LOWER": try need(1...1); return one(.text(arg(0).display.lowercased()))
        case "TRIM": try need(1...1); return one(.text(arg(0).display.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")))
        case "LEFT", "RIGHT":
            try need(1...2)
            let s = arg(0).display, k = max(0, Int(n(1) ?? 1))
            return one(.text(name == "LEFT" ? String(s.prefix(k)) : String(s.suffix(k))))
        default:
            throw Unsupported(name: name)
        }
    }
}
