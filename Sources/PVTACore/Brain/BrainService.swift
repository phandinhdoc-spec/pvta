import Foundation
import CryptoKit

/// Phạm vi tra cứu mã: thư mục đã cấp quyền (duyệt cả thư mục) hoặc đúng các tệp lẻ (không đọc tệp cùng thư mục).
public struct BrainScope: Sendable, Equatable {
    public var roots: [String]
    public var files: [String]
    /// Thư mục bị loại (Học hỏi).
    public var excluded: [String]
    public var isEmpty: Bool { roots.isEmpty && files.isEmpty }
}

/// Tra cứu mã nguồn cho AI: tổng quan, dàn ý một tệp, tìm theo ký hiệu và nội dung, đọc thân hàm, tham chiếu.
/// Viết lại bằng Swift (không dùng chương trình Rust) để phát hành một ứng dụng duy nhất. Chỉ mục nằm ngoài dự án, trong thư mục dữ liệu của PVTA.
public actor BrainService {
    static let maxFiles = 20_000, maxFileBytes = 1_000_000, maxReadLines = 500, defaultLimit = 12
    let store: DataStore
    let files: FileService
    let home: URL
    private var cache: [String: [BrainFile]] = [:]

    public init(store: DataStore, files: FileService, home: URL) {
        self.store = store; self.files = files; self.home = home.appendingPathComponent("brain", isDirectory: true)
    }

    // MARK: Phạm vi

    private func canon(_ p: String) -> String { PathGuard.canonical(p) ?? p }
    private static func inside(_ f: String, _ d: String) -> Bool { f == d || f.hasPrefix(d.hasSuffix("/") ? d : d + "/") }

    func learningRoots() async -> [String] {
        var out: [String] = []
        for p in (try? await store.projects()) ?? [] { for f in (try? await store.projectFolders(p.id)) ?? [] where f.role == "learning" { out.append(canon(f.path)) } }
        return out
    }

    /// Phạm vi của một lượt: `root` (phải được cấp quyền đọc) hoặc các thư mục nguồn của dự án chứa hội thoại cộng tệp lẻ đính kèm.
    /// Một tệp lẻ không bao giờ mở rộng thành cả thư mục; thư mục Học hỏi luôn bị loại.
    public func scope(chatId: String?, root: String? = nil) async throws -> BrainScope {
        let learning = await learningRoots()
        var roots: [String] = [], single: [String] = []
        if let root, !root.isEmpty {
            let real = canon(try await files.permissions.authorize(path: (root as NSString).expandingTildeInPath, write: false))
            var st = stat()
            guard lstat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PVTAError("“root” phải là một thư mục đã được cấp quyền đọc.") }
            if learning.contains(where: { Self.inside(real, $0) }) { throw PVTAError("Thư mục Học hỏi không nằm trong phạm vi tra cứu mã.") }
            roots.append(real)
        }
        if let chatId, let chat = try await store.chat(id: chatId) {
            if roots.isEmpty, let pid = chat.projectId {
                for f in try await store.projectFolders(pid) where f.role == "source" && FileManager.default.fileExists(atPath: f.path) { roots.append(canon(f.path)) }
            }
            for a in try await files.attachments.list(chatId: chatId) where a.kind == "file" {
                guard let p = a.path else { continue }
                let c = canon(p)
                if !roots.contains(where: { Self.inside(c, $0) }), !learning.contains(where: { Self.inside(c, $0) }), BrainParse.language(c) != nil { single.append(c) }
            }
        }
        // Bỏ thư mục nằm trong thư mục khác cùng phạm vi.
        let kept = roots.filter { r in !roots.contains { $0 != r && Self.inside(r, $0) } }
        let s = BrainScope(roots: Array(Set(kept)).sorted(), files: Array(Set(single)).sorted(), excluded: learning)
        guard !s.isEmpty else { throw PVTAError("Chưa có phạm vi để tra cứu mã. Hãy cấp quyền một thư mục dự án (truyền root), nối thư mục nguồn vào dự án, hoặc đính kèm tệp mã.") }
        return s
    }

    // MARK: Chỉ mục

    private func key(_ s: BrainScope) -> String {
        SHA256.hash(data: Data((s.roots.joined(separator: "|") + "#" + s.files.joined(separator: "|")).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func discover(_ s: BrainScope) -> [(abs: String, rel: String)] {
        var out: [(String, String)] = []
        let fm = FileManager.default
        func walk(_ dir: String, rootName: String, rel: String, depth: Int) {
            guard out.count < Self.maxFiles, depth < 30 else { return }
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !n.hasPrefix(".") {
                let p = dir + "/" + n, r = rel.isEmpty ? n : rel + "/" + n
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    if BrainParse.skipDirs.contains(n) || s.excluded.contains(where: { Self.inside(canon(p), $0) }) { continue }
                    walk(p, rootName: rootName, rel: r, depth: depth + 1)
                } else if (st.st_mode & S_IFMT) == S_IFREG, BrainParse.language(n) != nil, st.st_size <= Self.maxFileBytes {
                    out.append((p, (s.roots.count > 1 ? rootName + "/" : "") + r))
                }
            }
        }
        for r in s.roots { walk(r, rootName: (r as NSString).lastPathComponent, rel: "", depth: 0) }
        for f in s.files { var st = stat(); if lstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxFileBytes { out.append((f, "tệp/" + (f as NSString).lastPathComponent)) } }
        return out
    }

    private func indexURL(_ s: BrainScope) -> URL { home.appendingPathComponent(key(s) + ".json") }

    /// Cập nhật chỉ mục tăng dần: chỉ đọc lại tệp có kích thước hoặc giờ sửa đổi khác.
    public func index(_ s: BrainScope) throws -> [BrainFile] {
        var old: [String: BrainFile] = [:]
        let k = key(s)
        for f in cache[k] ?? ((try? Data(contentsOf: indexURL(s))).flatMap { try? JSONDecoder().decode([BrainFile].self, from: $0) } ?? []) { old[f.abs] = f }
        var out: [BrainFile] = [], changed = false
        for (abs, rel) in discover(s) {
            var st = stat()
            guard lstat(abs, &st) == 0 else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if var o = old[abs], o.size == Int(st.st_size), abs_(o.mtime - mtime) < 0.001 { o.path = rel; out.append(o); continue }
            guard let data = FileManager.default.contents(atPath: abs), !data.prefix(4000).contains(0), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            let lang = BrainParse.language(abs) ?? "text"
            let p = BrainParse.parse(text: text, lang: lang)
            out.append(BrainFile(path: rel, abs: abs, lang: lang, size: Int(st.st_size), mtime: mtime, lines: p.lines, symbols: p.symbols, imports: p.imports))
            changed = true
        }
        if out.count != old.count { changed = true }
        out.sort { $0.path < $1.path }
        cache[k] = out
        if changed {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? JSONEncoder().encode(out).write(to: indexURL(s), options: .atomic)
        }
        return out
    }

    private func abs_(_ d: Double) -> Double { Swift.abs(d) }

    private func text(_ f: BrainFile) -> String? {
        guard let d = FileManager.default.contents(atPath: f.abs) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    private func file(_ idx: [BrainFile], _ path: String) throws -> BrainFile {
        let p = path.trimmingCharacters(in: .whitespaces)
        if let f = idx.first(where: { $0.path == p }) { return f }
        let tail = idx.filter { $0.path.hasSuffix("/" + p) || ($0.path as NSString).lastPathComponent == p }
        if tail.count == 1 { return tail[0] }
        if tail.count > 1 { throw PVTAError("Tên “\(p)” khớp nhiều tệp: " + tail.prefix(5).map(\.path).joined(separator: ", ") + ". Hãy nêu đường dẫn đầy đủ.") }
        throw PVTAError("Tệp “\(p)” không nằm trong phạm vi tra cứu. Phạm vi chỉ gồm các tệp đã được cấp quyền hoặc đính kèm.")
    }

    // MARK: Lệnh

    static let typeKinds: Set<String> = ["class", "struct", "enum", "protocol", "type", "module"]

    /// Tầng 1: ngôn ngữ, vùng mã kèm ký hiệu chính, tệp cấu hình/điểm vào, tệp trung tâm (nhiều tệp khác nhắc tới ký hiệu của nó).
    public func overview(_ s: BrainScope) throws -> String {
        let idx = try index(s)
        guard !idx.isEmpty else { return "Phạm vi không có tệp mã nào đọc được." }
        var out = "PHẠM VI: " + (s.roots.map { ($0 as NSString).lastPathComponent } + (s.files.isEmpty ? [] : ["\(s.files.count) tệp lẻ"])).joined(separator: ", ") + " — \(idx.count) tệp, \(idx.reduce(0) { $0 + $1.symbols.count }) ký hiệu\n"
        var langs: [String: Int] = [:]
        for f in idx { langs[f.lang, default: 0] += 1 }
        out += "Ngôn ngữ: " + langs.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"
        if s.roots.isEmpty {
            out += "\nDÀN Ý TỪNG TỆP (phạm vi tệp lẻ):\n"
            for f in idx.prefix(30) { out += "- \(f.path) (\(f.lines) dòng): " + f.symbols.filter { $0.depth == 0 }.prefix(12).map(\.name).joined(separator: ", ") + "\n" }
            return out
        }
        var regions: [String: [BrainFile]] = [:]
        for f in idx { regions[f.path.contains("/") ? String(f.path.split(separator: "/").prefix(f.path.hasPrefix("tệp/") ? 1 : (s.roots.count > 1 ? 2 : 1)).joined(separator: "/")) : ".", default: []].append(f) }
        out += "\nVÙNG MÃ:\n"
        for (dir, fs) in regions.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }).prefix(25) {
            let top = fs.flatMap { $0.symbols.filter { $0.depth == 0 && (Self.typeKinds.contains($0.kind) || $0.kind == "function") } }.prefix(8).map(\.name)
            out += "- \(dir)/ (\(fs.count) tệp): " + top.joined(separator: ", ") + "\n"
        }
        let entry = idx.filter { f in ["main.swift", "main.py", "main.go", "main.rs", "index.ts", "index.js", "app.py", "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Makefile", "README.md"].contains((f.path as NSString).lastPathComponent) }
        if !entry.isEmpty { out += "\nĐIỂM VÀO / CẤU HÌNH: " + entry.prefix(12).map(\.path).joined(separator: ", ") + "\n" }
        let central = try centrality(idx).prefix(8)
        if !central.isEmpty { out += "\nTỆP TRUNG TÂM (nhiều tệp khác nhắc tới): " + central.map { "\($0.path) (\($0.count) tệp)" }.joined(separator: ", ") + "\n" }
        return out
    }

    private func identifiers(_ text: String) -> Set<String> {
        var out = Set<String>(), cur = ""
        for ch in text { if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { if cur.count >= 3 { out.insert(cur) }; cur = "" } }
        if cur.count >= 3 { out.insert(cur) }
        return out
    }

    /// Tệp được nhiều tệp khác nhắc tới nhất (qua tên ký hiệu cấp cao nhất của nó).
    private func centrality(_ idx: [BrainFile]) throws -> [(path: String, count: Int)] {
        var ids: [String: Set<String>] = [:]
        for f in idx where BrainParse.hasSymbols.contains(f.lang) && f.lang != "markdown" { if let t = text(f) { ids[f.path] = identifiers(t) } }
        var out: [(String, Int)] = []
        for f in idx {
            let names = Set(f.symbols.filter { $0.depth == 0 && Self.typeKinds.contains($0.kind) && $0.name.count >= 4 }.map { $0.name })
            guard !names.isEmpty else { continue }
            let c = ids.filter { $0.key != f.path && !$0.value.isDisjoint(with: names) }.count
            if c > 0 { out.append((f.path, c)) }
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// Tầng 2: cây ký hiệu lồng nhau của một tệp, import, và các tệp nhắc tới ký hiệu của nó.
    public func outline(_ s: BrainScope, file path: String) throws -> String {
        let idx = try index(s)
        let f = try file(idx, path)
        var out = "\(f.path) — \(f.lang), \(f.lines) dòng\n"
        if f.symbols.isEmpty { out += "(không có ký hiệu)\n" }
        for sym in f.symbols { out += String(repeating: "  ", count: sym.depth) + "\(sym.kind) \(sym.name) [\(sym.line)-\(sym.end)]\n" }
        if !f.imports.isEmpty { out += "Import: " + f.imports.prefix(30).joined(separator: ", ") + "\n" }
        let names = Set(f.symbols.filter { $0.depth == 0 && $0.name.count >= 4 }.map { $0.name })
        if !names.isEmpty {
            var users: [String] = []
            for g in idx where g.path != f.path && users.count < 20 { if let t = text(g), !identifiers(t).isDisjoint(with: names) { users.append(g.path) } }
            if !users.isEmpty { out += "Tệp nhắc tới: " + users.joined(separator: ", ") + "\n" }
        }
        return out
    }

    private static func parts(_ name: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in name {
            if ch == "_" || ch == "-" || ch == "." || ch == " " { if !cur.isEmpty { out.append(cur.lowercased()); cur = "" } }
            else if ch.isUppercase, !cur.isEmpty, !(cur.last?.isUppercase ?? false) { out.append(cur.lowercased()); cur = String(ch) }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[y.count]
    }

    public struct Found: Sendable, Equatable { public var kind: String; public var name: String; public var path: String; public var line: Int; public var score: Double; public var evidence: String? }

    /// Tìm xếp hạng: ký hiệu (nguyên tên, tiền tố, chuỗi con, từng mảnh camelCase/snake_case, chịu 1 lỗi gõ) và nội dung (không phân biệt dấu).
    /// Bộ lọc: `in:<đường dẫn>`, `kind:<loại>`, `lang:<ngôn ngữ>`. Không thấy gì thì trả gợi ý tên gần giống.
    public func find(_ s: BrainScope, query: String, limit: Int = 12) throws -> (hits: [Found], hint: String?) {
        var words: [String] = [], inPath: String?, kind: String?, lang: String?
        for w in query.split(separator: " ").map(String.init) {
            if w.hasPrefix("in:") { inPath = String(w.dropFirst(3)) } else if w.hasPrefix("kind:") { kind = String(w.dropFirst(5)).lowercased() } else if w.hasPrefix("lang:") { lang = String(w.dropFirst(5)).lowercased() } else { words.append(w) }
        }
        let idx = try index(s).filter { (inPath == nil || $0.path.contains(inPath!)) && (lang == nil || $0.lang == lang) }
        var hits: [Found] = []
        let q = words.joined(separator: " ")
        if words.isEmpty {
            guard kind != nil || inPath != nil || lang != nil else { throw PVTAError("Nhập truy vấn hoặc bộ lọc (in:, kind:, lang:).") }
            for f in idx { for sym in f.symbols where kind == nil || sym.kind == kind { hits.append(Found(kind: sym.kind, name: sym.name, path: f.path, line: sym.line, score: 1, evidence: nil)) } }
            return (Array(hits.prefix(limit)), nil)
        }
        let ql = q.lowercased(), qparts = Self.parts(q.replacingOccurrences(of: " ", with: "_"))
        let abbreviation = q.filter(\.isUppercase).lowercased()
        var allNames: [String] = []
        for f in idx {
            for sym in f.symbols where kind == nil || sym.kind == kind {
                allNames.append(sym.name)
                let nl = sym.name.lowercased(), np = Self.parts(sym.name)
                var score = 0.0
                if nl == ql { score = 100 } else if nl.hasPrefix(ql) { score = 70 } else if nl.contains(ql) { score = 50 }
                else if !qparts.isEmpty, qparts.allSatisfy({ p in np.contains { $0.hasPrefix(p) } }) { score = 40 + Double(qparts.count) * 2 }
                else if q.count >= 3, q.allSatisfy({ !$0.isLowercase }), abbreviation.count >= 2, np.map({ String($0.prefix(1)) }).joined().hasPrefix(abbreviation) { score = 30 }
                else if q.count >= 4, Self.distance(nl, ql) <= 1 { score = 25 }
                if score > 0 {
                    score *= ["class": 1.3, "struct": 1.3, "enum": 1.2, "protocol": 1.2, "type": 1.2, "function": 1.1, "method": 1.0, "test": 0.6, "heading": 0.8][sym.kind] ?? 1
                    hits.append(Found(kind: sym.kind, name: sym.name, path: f.path, line: sym.line, score: score, evidence: nil))
                }
            }
        }
        // Nội dung: dòng khớp nhiều từ khóa nhất (đã gấp dấu tiếng Việt); tệp có từ hiếm được điểm cao hơn.
        if kind == nil {
            let toks = Array(Set(TextIndex.tokens(q)))
            if !toks.isEmpty {
                var df: [String: Int] = [:], per: [(BrainFile, [(Int, Int, String)])] = []
                for f in idx {
                    guard let t = text(f) else { continue }
                    var best: [(Int, Int, String)] = [], seen = Set<String>()
                    for (i, line) in t.components(separatedBy: "\n").enumerated() where line.count < 500 {
                        let ft = Fold.text(line)
                        let m = toks.filter { ft.contains($0) }
                        if !m.isEmpty { best.append((i + 1, m.count, line)); m.forEach { seen.insert($0) } }
                    }
                    for x in seen { df[x, default: 0] += 1 }
                    if !best.isEmpty { per.append((f, best)) }
                }
                for (f, lines) in per {
                    let top = lines.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(1)
                    guard let t = top.first, t.1 >= max(1, (toks.count + 1) / 2) else { continue }
                    let rare = toks.reduce(0.0) { $0 + log(1 + Double(idx.count) / Double(max(df[$1] ?? 1, 1))) }
                    hits.append(Found(kind: "text", name: (f.path as NSString).lastPathComponent, path: f.path, line: t.0, score: 5 + Double(t.1) * rare + Double(lines.count).squareRoot(),
                                      evidence: String(t.2.trimmingCharacters(in: .whitespaces).prefix(200))))
                }
            }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : ($0.path, $0.line) < ($1.path, $1.line) }
        if hits.isEmpty {
            let near = Array(Set(allNames)).filter { $0.count >= 3 && Self.distance($0.lowercased(), ql) <= max(2, q.count / 3) }.sorted().prefix(5)
            return ([], near.isEmpty ? "Không thấy. Thử từ khóa khác (tên hàm, một phần tên, hoặc cụm từ trong chú thích); không kết luận “không có mã” chỉ vì một lần tìm không ra." : "Không thấy. Tên gần giống: " + near.joined(separator: ", "))
        }
        return (Array(hits.prefix(limit)), nil)
    }

    /// Đọc theo dòng (tối đa 500 dòng) hoặc trọn thân một ký hiệu. Kèm SHA-256 của cả tệp.
    public func read(_ s: BrainScope, file path: String, start: Int? = nil, end: Int? = nil, symbol: String? = nil) throws -> String {
        let idx = try index(s)
        let f = try file(idx, path)
        guard let t = text(f) else { throw PVTAError("Không đọc được tệp.") }
        let lines = t.components(separatedBy: "\n")
        var a = start ?? 1, b = end ?? min(lines.count, (start ?? 1) + 199)
        var label = ""
        if let symbol {
            let m = f.symbols.filter { $0.name == symbol }
            guard let sym = m.first else { throw PVTAError("Không thấy ký hiệu “\(symbol)” trong \(f.path). Dùng brain_outline để xem danh sách.") }
            a = sym.line; b = sym.end; label = " (\(sym.kind) \(sym.name)" + (m.count > 1 ? ", có \(m.count) ký hiệu trùng tên, đang đọc cái đầu" : "") + ")"
        }
        guard a >= 1, a <= lines.count, b >= a else { throw PVTAError("Phạm vi dòng không hợp lệ (tệp có \(lines.count) dòng).") }
        b = min(b, lines.count)
        var note = ""
        if b - a + 1 > Self.maxReadLines { b = a + Self.maxReadLines - 1; note = "\n… (đã cắt ở \(Self.maxReadLines) dòng; đọc tiếp từ dòng \(b + 1))" }
        let sha = SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
        let body = (a...b).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        return "\(f.path):\(a)-\(b)\(label) sha256=\(sha)\n\(body)\(note)"
    }

    /// Ứng viên tham chiếu theo từ (định nghĩa, import, dùng, chú thích). Có thể có chú thích/chuỗi và bỏ sót lời gọi động; đọc nguồn trước khi khẳng định.
    public func refs(_ s: BrainScope, identifier: String, limit: Int = 40) throws -> String {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard id.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil else { throw PVTAError("Tên cần tra là một định danh (chữ, số, gạch dưới).") }
        let re = try NSRegularExpression(pattern: "(?<![\\w$])" + NSRegularExpression.escapedPattern(for: id) + "(?![\\w$])")
        var out: [String] = [], total = 0
        for f in try index(s) {
            guard let t = text(f), t.contains(id) else { continue }
            let defs = Set(f.symbols.filter { $0.name == id }.map(\.line))
            for (i, line) in t.components(separatedBy: "\n").enumerated() where line.count < 600 {
                let ns = line as NSString
                guard re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                total += 1
                guard out.count < limit else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let kind = defs.contains(i + 1) ? "định nghĩa" : (trimmed.hasPrefix("import ") || trimmed.hasPrefix("use ") || trimmed.hasPrefix("#include") || trimmed.hasPrefix("from ") || trimmed.contains("require(")) ? "import"
                    : (trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")) ? "chú thích" : "dùng"
                out.append("\(f.path):\(i + 1) [\(kind)] \(String(trimmed.prefix(160)))")
            }
        }
        if out.isEmpty { return "Không thấy “\(id)” trong phạm vi." }
        return out.joined(separator: "\n") + (total > out.count ? "\n… còn \(total - out.count) chỗ nữa" : "")
    }

    // MARK: Công cụ cho model

    nonisolated var toolSpecs: [ToolSpec] {
        @Sendable func arg(_ a: JSONValue, _ k: String) throws -> String { guard let s = a[k]?.string, !s.isEmpty else { throw PVTAError("Thiếu tham số \"\(k)\".") }; return s }
        let rootDoc = #""root": "thư mục dự án đã cấp quyền (tùy chọn; không có thì dùng thư mục nguồn của dự án và tệp đính kèm)""#
        return [
            ToolSpec(name: "brain_overview", summary: "Tổng quan mã nguồn trong phạm vi: ngôn ngữ, vùng mã kèm ký hiệu chính, điểm vào, tệp trung tâm. Dùng đầu tiên.", parameters: "{\(rootDoc)}") { [self] a in
                try await overview(scope(chatId: a["chatId"]?.string, root: a["root"]?.string))
            },
            ToolSpec(name: "brain_outline", summary: "Dàn ý một tệp: cây ký hiệu lồng nhau có dòng đầu–cuối thật, import, tệp nhắc tới.", parameters: #"{"file": "đường dẫn tương đối trong phạm vi", \#(rootDoc)}"#) { [self] a in
                try await outline(scope(chatId: a["chatId"]?.string, root: a["root"]?.string), file: arg(a, "file"))
            },
            ToolSpec(name: "brain_find", summary: "Tìm theo ký hiệu (tên, một phần tên, camelCase, viết tắt) và nội dung (không phân biệt dấu). Bộ lọc: in:<đường dẫn> kind:<loại> lang:<ngôn ngữ>.", parameters: #"{"query": "từ khóa kèm bộ lọc", "limit": "tối đa (mặc định 12)", \#(rootDoc)}"#) { [self] a in
                let r = try await find(scope(chatId: a["chatId"]?.string, root: a["root"]?.string), query: arg(a, "query"), limit: min(50, max(1, Int(a["limit"]?.number ?? 12))))
                if r.hits.isEmpty { return r.hint ?? "Không thấy." }
                return r.hits.map { "\($0.path):\($0.line) [\($0.kind)] \($0.name)" + ($0.evidence.map { " — \($0)" } ?? "") }.joined(separator: "\n")
            },
            ToolSpec(name: "brain_read", summary: "Đọc tối đa 500 dòng của một tệp (start, end) hoặc trọn thân một ký hiệu (symbol). Kèm SHA-256 của tệp.", parameters: #"{"file": "đường dẫn", "start": "dòng đầu", "end": "dòng cuối", "symbol": "tên ký hiệu", \#(rootDoc)}"#) { [self] a in
                try await read(scope(chatId: a["chatId"]?.string, root: a["root"]?.string), file: arg(a, "file"), start: a["start"]?.number.map { Int($0) }, end: a["end"]?.number.map { Int($0) }, symbol: a["symbol"]?.string)
            },
            ToolSpec(name: "brain_refs", summary: "Ứng viên tham chiếu theo từ của một định danh: định nghĩa, import, dùng, chú thích. Đọc nguồn trước khi khẳng định.", parameters: #"{"identifier": "tên cần tra", \#(rootDoc)}"#) { [self] a in
                try await refs(scope(chatId: a["chatId"]?.string, root: a["root"]?.string), identifier: arg(a, "identifier"))
            },
        ]
    }
}
