import Foundation

/// Công cụ đọc và tìm trong tệp đã đính kèm. Chỉ truy cập các tệp đính kèm của hội thoại (mã hội thoại do vòng lặp gán, model không tự đổi được).
extension AttachmentService {
    private func fileList(_ chatId: String) async throws -> [Attachment] {
        try await store.attachments(chatId: chatId).filter { $0.kind == "file" }
    }

    private func find(_ chatId: String, _ ref: String) async throws -> Attachment {
        let files = try await fileList(chatId)
        let want = Fold.text(ref.trimmingCharacters(in: .whitespaces))
        guard !want.isEmpty else { throw PVTAError("Thiếu tên tệp (name).") }
        if let a = files.first(where: { Fold.text($0.name) == want }) ?? files.first(where: { $0.path == ref }) { return a }
        let part = files.filter { Fold.text($0.name).contains(want) }
        if part.count == 1 { return part[0] }
        if part.count > 1 { throw PVTAError("Có nhiều tệp khớp “\(ref)”: \(part.map(\.name).joined(separator: "; ")). Hãy ghi rõ tên.") }
        throw PVTAError("Không có tệp “\(ref)” trong hội thoại này. Tệp hiện có: \(files.map(\.name).joined(separator: "; ").isEmpty ? "(chưa có)" : files.map(\.name).joined(separator: "; ")).")
    }

    private func text(_ a: Attachment) async throws -> String { try await store.attachmentText(id: a.id) ?? "" }

    func fileRead(chatId: String, name: String, start: Int, length: Int?) async throws -> String {
        let a = try await find(chatId, name)
        let t = Array(try await text(a))
        let s = max(0, min(t.count, start))
        let len = max(1, min(Self.limits.readMax, length ?? Self.limits.readDefault))
        let e = min(t.count, s + len)
        var out = "Tệp: \(a.name) — ký tự \(s)–\(e) / \(t.count)" + (e < t.count ? " (đọc tiếp từ start=\(e))" : "")
        if a.truncated { out += " — tệp gốc dài hơn, chỉ lưu phần đầu" }
        return out + "\n---\n" + String(t[s..<e])
    }

    func fileSearch(chatId: String, query: String, name: String?) async throws -> String {
        let words = Fold.text(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw PVTAError("Thiếu từ khóa tìm (query).") }
        var files = try await fileList(chatId)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { files = [try await find(chatId, name)] }
        var hits: [(name: String, start: Int, score: Int, text: String)] = []
        for a in files {
            var pos = 0
            for line in try await text(a).components(separatedBy: "\n") {
                let low = Fold.text(line)
                let score = words.filter { low.contains($0) }.count
                if score > 0 { hits.append((a.name, pos, score, String(line.trimmingCharacters(in: .whitespaces).prefix(300)))) }
                pos += line.count + 1
            }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.start < $1.start }
        let top = hits.prefix(Self.limits.searchHits)
        if top.isEmpty { return "Không thấy “\(query)” trong các tệp đính kèm." }
        return top.map { "\($0.name) @\($0.start): \($0.text)" }.joined(separator: "\n") + (hits.count > top.count ? "\n(còn \(hits.count - top.count) kết quả nữa, hãy tìm cụ thể hơn)" : "")
    }

    func pdfPages(chatId: String, name: String, from: Int, to: Int?, query: String?) async throws -> String {
        let a = try await find(chatId, name)
        let t = try await text(a)
        guard let re = try? NSRegularExpression(pattern: #"^\[Trang (\d{1,5})\]\n"#, options: .anchorsMatchLines) else { return "" }
        let ns = t as NSString
        let marks = re.matches(in: t, range: NSRange(location: 0, length: ns.length))
        var pages: [(Int, String)] = []
        for (i, m) in marks.enumerated() {
            let begin = m.range.location + m.range.length
            let end = i + 1 < marks.count ? marks[i + 1].range.location : ns.length
            pages.append((Int(ns.substring(with: m.range(at: 1))) ?? 0, ns.substring(with: NSRange(location: begin, length: end - begin)).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let last = pages.last?.0 else { throw PVTAError("Tệp này không có nhãn trang; hãy đọc bằng file_read.") }
        if let query, !query.isEmpty {
            let words = Fold.text(query).split(whereSeparator: \.isWhitespace).map(String.init)
            var scored: [(page: Int, score: Int, text: String)] = []
            for p in pages {
                let folded = Fold.text(p.1)
                let score = words.filter { folded.contains($0) }.count
                if score > 0 { scored.append((p.0, score, p.1)) }
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.page < $1.page }
            let lines: [String] = scored.prefix(12).map { hit in
                let flat = hit.text.replacingOccurrences(of: "\n", with: " ")
                return "Trang \(hit.page): " + String(flat.prefix(200))
            }
            return "Các trang có “\(query)” (tổng \(last) trang):\n" + lines.joined(separator: "\n")
        }
        let f = max(1, from), t2 = min(last, max(f, to ?? f), f + Self.limits.pdfPages - 1)
        let body = pages.filter { $0.0 >= f && $0.0 <= t2 }.map { "[Trang \($0.0)]\n\($0.1)" }.joined(separator: "\n\n")
        var out = "Tệp: \(a.name) — trang \(f)–\(t2) / \(last)" + (t2 < last ? " (đọc tiếp từ trang \(t2 + 1))" : "") + "\n---\n" + String(body.prefix(Self.limits.readMax))
        if body.count > Self.limits.readMax { out += "\n[các trang dài quá, đã cắt; đọc ít trang hơn mỗi lần]" }
        if body.isEmpty { out += "\n(các trang này không có chữ, có thể là ảnh quét)" }
        return out
    }

    private static func arg(_ a: JSONValue, _ k: String) -> String { a[k]?.string ?? "" }
    private static func num(_ a: JSONValue, _ k: String) -> Int? { a[k]?.number.map { Int($0) } }
    private static func chatOf(_ a: JSONValue) throws -> String { try a.requireString("chatId") }

    /// Bốn công cụ chỉ đọc cho model, chỉ hiện khi hội thoại có tệp đính kèm.
    var toolSpecs: [ToolSpec] {
        return [
            ToolSpec(name: "file_list", summary: "Liệt kê các tệp đính kèm của hội thoại.", parameters: "{}") { [self] a in
                let files = try await fileList(Self.chatOf(a))
                return files.isEmpty ? "(chưa có tệp đính kèm)" : files.map { "- \($0.name) (\($0.chars) ký tự\($0.truncated ? ", đã cắt bớt" : ""))" }.joined(separator: "\n")
            },
            ToolSpec(name: "file_read", summary: "Đọc một đoạn của tệp đính kèm.", parameters: #"{"name": "tên tệp", "start": "ký tự bắt đầu (mặc định 0)", "length": "số ký tự (mặc định 8000, tối đa 20000)"}"#) { [self] a in
                try await fileRead(chatId: Self.chatOf(a), name: Self.arg(a, "name"), start: Self.num(a, "start") ?? 0, length: Self.num(a, "length"))
            },
            ToolSpec(name: "file_search", summary: "Tìm từ khóa (không phân biệt dấu) trong các tệp đính kèm.", parameters: #"{"query": "từ khóa", "name": "chỉ tìm trong tệp này (tùy chọn)"}"#) { [self] a in
                try await fileSearch(chatId: Self.chatOf(a), query: Self.arg(a, "query"), name: a["name"]?.string)
            },
            ToolSpec(name: "pdf_pages", summary: "Đọc PDF đính kèm theo trang hoặc tìm trang chứa từ khóa.", parameters: #"{"name": "tên tệp", "from": "trang đầu", "to": "trang cuối", "query": "từ khóa (tùy chọn)"}"#) { [self] a in
                try await pdfPages(chatId: Self.chatOf(a), name: Self.arg(a, "name"), from: Self.num(a, "from") ?? 1, to: Self.num(a, "to"), query: a["query"]?.string)
            },
        ]
    }
}
