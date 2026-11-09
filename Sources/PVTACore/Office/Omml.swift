import Foundation

/// Đổi công thức viết kiểu LaTeX (tập con thường dùng ở trường phổ thông) và công thức hóa học `\ce{...}`
/// sang phương trình chuẩn của Word (OMML). Công thức sai cú pháp bị từ chối bằng thông báo rõ, không chèn nửa chừng.
enum Omml {
    static let namespace = "http://schemas.openxmlformats.org/officeDocument/2006/math"

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `<m:oMath>` (cùng dòng) hoặc `<m:oMathPara>` (riêng một dòng).
    static func convert(_ latex: String, display: Bool) throws -> String {
        var p = Parser(Array(latex.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !p.chars.isEmpty else { throw PVTAError("Công thức đang trống.") }
        let inner = try p.expression(until: nil)
        if p.pos < p.chars.count { throw PVTAError("Công thức có dấu “\(p.chars[p.pos])” không khớp: \(latex.prefix(80))") }
        let math = "<m:oMath>\(inner)</m:oMath>"
        return display ? "<m:oMathPara>\(math)</m:oMathPara>" : math
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι",
        "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "⋅", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "cong": "≅", "infty": "∞", "partial": "∂", "nabla": "∇", "degree": "°", "circ": "∘",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "rightleftharpoons": "⇌", "uparrow": "↑", "downarrow": "↓", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀", "exists": "∃", "perp": "⊥", "parallel": "∥", "angle": "∠", "triangle": "△",
        "therefore": "∴", "because": "∵", "ldots": "…", "cdots": "⋯", "dots": "…", "prime": "′", "mid": "∣", "land": "∧", "lor": "∨", "neg": "¬",
        "lt": "<", "gt": ">", "ll": "≪", "gg": "≫", "propto": "∝", "setminus": "∖", "Re": "ℜ", "Im": "ℑ",
    ]

    /// Tên hàm viết thẳng (không nghiêng).
    private static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "log", "ln", "lg", "exp", "lim", "max", "min", "det", "gcd", "sup", "inf"]

    private static let nary: [String: (chr: String, limits: String)] = ["sum": ("∑", "undOvr"), "prod": ("∏", "undOvr"), "int": ("∫", "subSup"),
                                                                       "iint": ("∬", "subSup"), "oint": ("∮", "subSup"), "bigcup": ("⋃", "undOvr"), "bigcap": ("⋂", "undOvr")]

    private static let delimiters: [Character: String] = ["(": "(", ")": ")", "[": "[", "]": "]", "|": "|", ".": ""]

    static func run(_ text: String, plain: Bool = false) -> String {
        let pr = plain ? "<m:rPr><m:sty m:val=\"p\"/></m:rPr>" : ""
        return "<m:r>\(pr)<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/></w:rPr><m:t xml:space=\"preserve\">\(escape(text))</m:t></m:r>"
    }

    private enum Atom {
        case text(String, plain: Bool)
        case xml(String)
        var xml: String {
            switch self { case .text(let t, let plain): return Omml.run(t, plain: plain); case .xml(let x): return x }
        }
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0
        var depth = 0
        init(_ c: [Character]) { chars = c }

        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        mutating func skipSpaces() { while let c = peek(), c == " " || c == "\n" || c == "\t" { pos += 1 } }

        mutating func command() -> String {
            var name = ""
            while let c = peek(), c.isLetter, c.isASCII { name.append(c); pos += 1 }
            if name.isEmpty, let c = peek() { name = String(c); pos += 1 }   // \\ \{ \, ...
            return name
        }

        /// `{...}` bắt buộc, hoặc một ký tự/lệnh đơn lẻ.
        mutating func argument() throws -> String {
            skipSpaces()
            guard let c = peek() else { throw PVTAError("Công thức thiếu phần trong ngoặc { }.") }
            if c == "{" {
                pos += 1
                let inner = try expression(until: "}")
                guard peek() == "}" else { throw PVTAError("Công thức thiếu dấu } đóng.") }
                pos += 1
                return inner
            }
            let atoms = try atom()
            return atoms.map(\.xml).joined()
        }

        mutating func rawGroup() throws -> String {
            skipSpaces()
            guard peek() == "{" else { throw PVTAError("Công thức thiếu phần trong ngoặc { }.") }
            pos += 1
            var level = 1, out = ""
            while let c = peek() {
                pos += 1
                if c == "{" { level += 1 } else if c == "}" { level -= 1; if level == 0 { return out } }
                out.append(c)
            }
            throw PVTAError("Công thức thiếu dấu } đóng.")
        }

        mutating func expression(until end: Character?) throws -> String {
            depth += 1
            defer { depth -= 1 }
            guard depth < 40 else { throw PVTAError("Công thức lồng quá sâu.") }
            var items: [Atom] = []
            while let c = peek() {
                if let end, c == end { break }
                if c == "}" { if end == nil { throw PVTAError("Công thức có dấu } thừa.") }; break }
                if c == "^" || c == "_" {
                    pos += 1
                    let script = try argument()
                    var sup: String?, sub: String?
                    if c == "^" { sup = script } else { sub = script }
                    skipSpaces()
                    if let d = peek(), d == "^" || d == "_", d != c {
                        pos += 1
                        let second = try argument()
                        if d == "^" { sup = second } else { sub = second }
                    }
                    let base = Self.popBase(&items)
                    items.append(.xml(Omml.scripts(base: base, sup: sup, sub: sub)))
                    continue
                }
                items += try atom()
            }
            // Gộp các ký tự thường liền nhau thành một run.
            var out = "", buffer = "", plain = false
            func flush() { if !buffer.isEmpty { out += Omml.run(buffer, plain: plain); buffer = "" } }
            for a in items {
                if case .text(let t, let p) = a { if p != plain { flush(); plain = p }; buffer += t } else { flush(); out += a.xml }
            }
            flush()
            return out
        }

        static func popBase(_ items: inout [Atom]) -> String {
            guard let last = items.popLast() else { return Omml.run("") }
            if case .text(let t, let plain) = last, t.count > 1 {
                items.append(.text(String(t.dropLast()), plain: plain))
                return Omml.run(String(t.last!), plain: plain)
            }
            return last.xml
        }

        mutating func atom() throws -> [Atom] {
            guard let c = peek() else { return [] }
            pos += 1
            switch c {
            case " ", "\n", "\t": return []
            case "{":
                let inner = try expression(until: "}")
                guard peek() == "}" else { throw PVTAError("Công thức thiếu dấu } đóng.") }
                pos += 1
                return [.xml(inner)]
            case "\\": return try control()
            case "&": return [.text(" ", plain: false)]
            default: return [.text(String(c), plain: false)]
            }
        }

        mutating func control() throws -> [Atom] {
            let name = command()
            switch name {
            case "frac", "dfrac", "tfrac":
                let n = try argument(), d = try argument()
                return [.xml("<m:f><m:num>\(n)</m:num><m:den>\(d)</m:den></m:f>")]
            case "sqrt":
                skipSpaces()
                var degree: String?
                if peek() == "[" {
                    pos += 1
                    var raw = ""
                    while let c = peek(), c != "]" { raw.append(c); pos += 1 }
                    guard peek() == "]" else { throw PVTAError("Căn thức thiếu dấu ].") }
                    pos += 1
                    degree = try Omml.inner(raw)
                }
                let e = try argument()
                let deg = degree.map { "<m:deg>\($0)</m:deg>" } ?? "<m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>"
                return [.xml("<m:rad>\(degree == nil ? deg : "<m:radPr/>" + deg)<m:e>\(e)</m:e></m:rad>")]
            case "overline", "bar":
                return [.xml("<m:bar><m:barPr><m:pos m:val=\"top\"/></m:barPr><m:e>\(try argument())</m:e></m:bar>")]
            case "vec", "overrightarrow":
                return [.xml("<m:acc><m:accPr><m:chr m:val=\"⃗\"/></m:accPr><m:e>\(try argument())</m:e></m:acc>")]
            case "hat", "widehat":
                return [.xml("<m:acc><m:accPr><m:chr m:val=\"̂\"/></m:accPr><m:e>\(try argument())</m:e></m:acc>")]
            case "text", "mathrm", "textrm", "mathbf":
                return [.text(try rawGroup(), plain: true)]
            case "ce":
                return [.xml(try Omml.chemistry(try rawGroup()))]
            case "left":
                guard let open = peek() else { throw PVTAError("Sau \\left cần một dấu ngoặc.") }
                pos += 1
                let begin = open == "\\" ? command() : String(open)
                let inner = try delimited()
                return [.xml(inner.closing.map { "<m:d><m:dPr><m:begChr m:val=\"\(Omml.escape(Omml.bracket(begin)))\"/><m:endChr m:val=\"\(Omml.escape(Omml.bracket($0)))\"/></m:dPr><m:e>\(inner.xml)</m:e></m:d>" } ?? inner.xml)]
            case "right":
                throw PVTAError("Có \\right không có \\left đi trước.")
            case "begin":
                let env = try rawGroup()
                return [.xml(try matrix(env))]
            case "end": throw PVTAError("Có \\end không có \\begin đi trước.")
            case "\\": return [.text(" ", plain: false)]
            case ",", ";", ":", "!", " ", "quad", "qquad": return [.text(" ", plain: false)]
            case "{", "}", "%", "$", "_", "&", "#": return [.text(name, plain: false)]
            default:
                if let n = Omml.nary[name] {
                    var sub = "", sup = ""
                    for _ in 0..<2 {
                        skipSpaces()
                        if peek() == "_" { pos += 1; sub = try argument() } else if peek() == "^" { pos += 1; sup = try argument() }
                    }
                    // Biểu thức theo sau là thân của tổng/tích phân: lấy một nhóm hoặc một ký tự.
                    skipSpaces()
                    let body = (peek() != nil && peek() != "}") ? try argument() : ""
                    let hide = (sub.isEmpty ? "<m:subHide m:val=\"1\"/>" : "") + (sup.isEmpty ? "<m:supHide m:val=\"1\"/>" : "")
                    return [.xml("<m:nary><m:naryPr><m:chr m:val=\"\(n.chr)\"/><m:limLoc m:val=\"\(n.limits)\"/>\(hide)</m:naryPr><m:sub>\(sub)</m:sub><m:sup>\(sup)</m:sup><m:e>\(body)</m:e></m:nary>")]
                }
                if let s = Omml.symbols[name] { return [.text(s, plain: false)] }
                if Omml.functions.contains(name) { return [.text(name, plain: true)] }
                throw PVTAError("Công thức dùng lệnh \\\(name) mà PVTA chưa hỗ trợ. Hãy dùng ký hiệu có sẵn (phân số, căn, mũ, chỉ số, tổng, tích phân, chữ Hy Lạp…).")
            }
        }

        mutating func delimited() throws -> (xml: String, closing: String?) {
            var items = ""
            var closing: String?
            // Tìm \right khớp với \left vừa đọc.
            var level = 0
            let start = pos
            var i = pos
            while i < chars.count {
                if chars[i] == "\\" {
                    let rest = String(chars[(i + 1)...].prefix(5))
                    if rest.hasPrefix("left") { level += 1 } else if rest.hasPrefix("right") {
                        if level == 0 {
                            var j = i + 6
                            while j < chars.count, chars[j] == " " { j += 1 }
                            guard j < chars.count else { throw PVTAError("Sau \\right cần một dấu ngoặc.") }
                            var close = String(chars[j]); j += 1
                            if close == "\\" { var nm = ""; while j < chars.count, chars[j].isLetter { nm.append(chars[j]); j += 1 }; close = nm }
                            let body = Array(chars[start..<i])
                            var inner = Parser(body)
                            inner.depth = depth
                            items = try inner.expression(until: nil)
                            closing = close
                            pos = j
                            break
                        }
                        level -= 1
                    }
                }
                i += 1
            }
            guard closing != nil else { throw PVTAError("Có \\left không có \\right đi kèm.") }
            return (items, closing)
        }

        mutating func matrix(_ env: String) throws -> String {
            let endTag = "\\end{\(env)}"
            let rest = String(chars[pos...])
            guard let r = rest.range(of: endTag) else { throw PVTAError("Thiếu \\end{\(env)}.") }
            let content = String(rest[..<r.lowerBound])
            pos += rest.distance(from: rest.startIndex, to: r.upperBound)
            let rows = content.components(separatedBy: "\\\\").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !rows.isEmpty else { throw PVTAError("Khối \(env) đang trống.") }
            switch env {
            case "cases":
                let eq = try rows.map { "<m:e>\(try Omml.inner($0))</m:e>" }.joined()
                return "<m:d><m:dPr><m:begChr m:val=\"{\"/><m:endChr m:val=\"\"/></m:dPr><m:e><m:eqArr>\(eq)</m:eqArr></m:e></m:d>"
            case "matrix", "pmatrix", "bmatrix", "vmatrix":
                let cells = try rows.map { try $0.components(separatedBy: "&").map { try Omml.inner($0.trimmingCharacters(in: .whitespaces)) } }
                guard let width = cells.first?.count, cells.allSatisfy({ $0.count == width }) else { throw PVTAError("Các hàng của ma trận phải có cùng số cột.") }
                let body = cells.map { "<m:mr>" + $0.map { "<m:e>\($0)</m:e>" }.joined() + "</m:mr>" }.joined()
                let (o, c) = ["pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "vmatrix": ("|", "|")][env] ?? ("", "")
                let m = "<m:m>\(body)</m:m>"
                return o.isEmpty ? m : "<m:d><m:dPr><m:begChr m:val=\"\(o)\"/><m:endChr m:val=\"\(c)\"/></m:dPr><m:e>\(m)</m:e></m:d>"
            case "aligned", "align", "gather":
                let eq = try rows.map { "<m:e>\(try Omml.inner($0))</m:e>" }.joined()
                return "<m:eqArr>\(eq)</m:eqArr>"
            default:
                throw PVTAError("Khối \\begin{\(env)} chưa được hỗ trợ (có cases, matrix, pmatrix, bmatrix, vmatrix, aligned).")
            }
        }
    }

    static func bracket(_ s: String) -> String {
        switch s {
        case ".": return ""
        case "{", "\\{", "lbrace": return "{"
        case "}", "\\}", "rbrace": return "}"
        case "langle": return "⟨"
        case "rangle": return "⟩"
        case "lfloor": return "⌊"
        case "rfloor": return "⌋"
        case "lceil": return "⌈"
        case "rceil": return "⌉"
        case "|", "vert": return "|"
        default: return s
        }
    }

    static func inner(_ latex: String) throws -> String {
        var p = Parser(Array(latex))
        let x = try p.expression(until: nil)
        if p.pos < p.chars.count { throw PVTAError("Công thức có dấu “\(p.chars[p.pos])” không khớp.") }
        return x
    }

    fileprivate static func scripts(base: String, sup: String?, sub: String?) -> String {
        switch (sup, sub) {
        case let (s?, b?): return "<m:sSubSup><m:e>\(base)</m:e><m:sub>\(b)</m:sub><m:sup>\(s)</m:sup></m:sSubSup>"
        case let (s?, nil): return "<m:sSup><m:e>\(base)</m:e><m:sup>\(s)</m:sup></m:sSup>"
        case let (nil, b?): return "<m:sSub><m:e>\(base)</m:e><m:sub>\(b)</m:sub></m:sSub>"
        default: return base
        }
    }

    /// Công thức hóa học: chữ số sau ký hiệu nguyên tố hoặc ")" là chỉ số dưới; điện tích sau ^ là chỉ số trên; `->`, `<=>` thành mũi tên.
    static func chemistry(_ text: String) throws -> String {
        let c = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !c.isEmpty else { throw PVTAError("Công thức hóa học đang trống.") }
        var out = "", buffer = "", i = 0
        func flush() { if !buffer.isEmpty { out += run(buffer, plain: true); buffer = "" } }
        func charge(from at: Int) -> (String, Int) {
            var j = at + 1, s = ""
            if j < c.count, c[j] == "{" { j += 1; while j < c.count, c[j] != "}" { s.append(c[j]); j += 1 }; j += 1 }
            else { while j < c.count, c[j].isNumber || c[j] == "+" || c[j] == "-" { s.append(c[j]); j += 1 } }
            return (s, j)
        }
        func attach(_ sub: String?, _ sup: String?) {
            // Gắn chỉ số vào ký tự cuối đã gom.
            var last = String(buffer.removeLast())
            if last.first!.isLowercase, let up = buffer.last, up.isUppercase { last = String(buffer.removeLast()) + last }   // Ca, Fe, Cl…
            flush()
            out += scripts(base: run(last, plain: true), sup: sup.map { run($0, plain: true) }, sub: sub.map { run($0, plain: true) })
        }
        while i < c.count {
            let ch = c[i]
            if ch == "-", i + 1 < c.count, c[i + 1] == ">" { buffer += "→"; i += 2; continue }
            if ch == "<", i + 2 < c.count, c[i + 1] == "=", c[i + 2] == ">" { buffer += "⇌"; i += 3; continue }
            if ch == "^" {
                let (s, j) = charge(from: i)
                guard !s.isEmpty, !buffer.isEmpty else { throw PVTAError("Điện tích sau dấu ^ trong \\ce thiếu hoặc không có nguyên tố đứng trước.") }
                attach(nil, s)
                i = j
                continue
            }
            if ch.isNumber, let prev = buffer.last, prev.isLetter || prev == ")" || prev == "]" {
                var j = i, n = ""
                while j < c.count, c[j].isNumber { n.append(c[j]); j += 1 }
                if j < c.count, c[j] == "^" {   // ví dụ SO4^{2-}: chỉ số dưới và điện tích cùng một nguyên tố
                    let (s, k) = charge(from: j)
                    attach(n, s.isEmpty ? nil : s)
                    i = k
                } else { attach(n, nil); i = j }
                continue
            }
            buffer.append(ch)
            i += 1
        }
        flush()
        return out
    }
}
