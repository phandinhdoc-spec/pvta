import Foundation

/// Quy tắc được đọc từ mẫu, không chạy mã của mẫu và không dùng nội dung mẫu làm chỉ thị.
struct TypstLayout {
    var margin = "22mm", size = "12pt", leading = "0.65em", accent = "243b53", inset = "6pt"
    var heading = "1.3em"
    var evidence: [String] = []
    mutating func learn(_ text: String, name: String) {
        func capture(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern), let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        var found: [String] = []
        if let v = capture(#"margin:\s*([0-9]+(?:\.[0-9]+)?(?:mm|cm|pt))"#) { margin = v; found.append("lề " + v) }
        if let v = capture(#"text\([^\n]*?size:\s*([0-9]+(?:\.[0-9]+)?pt)"#) { size = v; found.append("cỡ chữ " + v) }
        if let v = capture(#"leading:\s*([0-9]+(?:\.[0-9]+)?(?:em|pt))"#) { leading = v; found.append("giãn dòng " + v) }
        if let v = capture(##"rgb\("#?([0-9A-Fa-f]{6})"\)"##) { accent = v; found.append("màu nhấn " + v) }
        if let v = capture(#"inset:\s*([0-9]+(?:\.[0-9]+)?pt)"#) { inset = v; found.append("đệm ô bảng " + v) }
        if let v = capture(#"heading[^\n]*size:\s*([0-9]+(?:\.[0-9]+)?em)"#) { heading = v; found.append("cỡ đề mục " + v) }
        if name.lowercased().hasSuffix(".md") {
            if text.contains("\n## ") || text.hasPrefix("# ") { found.append("đề mục Markdown phân cấp; giữ cấp của nguồn") }
            if text.contains("|---") || text.contains("| ---") { found.append("bảng có hàng đầu làm tiêu đề") }
            if text.contains("\n\n") { found.append("tách đoạn bằng dòng trống") }
        }
        evidence.append("Đã đọc toàn bộ mẫu \(name): " + (found.isEmpty ? "không rút được quy tắc được hỗ trợ; dùng quy tắc mặc định." : found.joined(separator: "; ") + ". Các thuộc tính khác dùng mặc định."))
    }
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    func convert(_ text: String, markdown: Bool) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000 else { throw PVTAError("Nguồn trống hoặc lớn hơn 1 MB; chưa thể xuất đầy đủ.") }
        if markdown && (text.contains("![") || text.contains("<img") || text.contains("$$") || text.contains("<table")) {
            throw PVTAError("Nguồn có ảnh, công thức khối hoặc bảng HTML chưa được chuyển đầy đủ. Hãy bổ sung bản văn bản/bảng Markdown phù hợp; PVTA chưa xuất để tránh mất nội dung.")
        }
        var out = "#set page(paper: \"a4\", margin: \(margin), numbering: \"1\")\n#set text(font: \"Arial\", size: \(size), lang: \"vi\")\n#set par(leading: \(leading), spacing: 0.8em)\n#show heading: it => text(fill: rgb(\"\(accent)\"), size: \(heading), weight: \"bold\", it)\n#set table(inset: \(inset), stroke: 0.5pt)\n"
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var i = 0, code: [String]? = nil
        while i < lines.count {
            let line = lines[i]; i += 1
            if markdown && line.hasPrefix("```") {
                if let collected = code { out += "#raw(\(Self.quote(collected.joined(separator: "\n"))), block: true)\n"; code = nil }
                else { code = [] }; continue
            }
            if code != nil { code!.append(line); continue }
            if markdown && line.hasPrefix("|") {
                var rows = [line]
                while i < lines.count && lines[i].hasPrefix("|") { rows.append(lines[i]); i += 1 }
                let cells = rows.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                guard cells.count >= 2, cells[1].allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }), let width = cells.first?.count, width > 0, cells.allSatisfy({ $0.count == width }) else { throw PVTAError("Bảng Markdown chưa đủ hàng tiêu đề hoặc các hàng lệch số cột.") }
                let header = cells[0].map { "text(weight: \"bold\", \(Self.quote($0)))" }.joined(separator: ",")
                let body = cells.dropFirst(2).flatMap { $0 }.map { "text(\(Self.quote($0)))" }.joined(separator: ",")
                out += "#table(columns: \(width), table.header(\(header))\(body.isEmpty ? "" : "," + body))\n"; continue
            }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if markdown && hashes > 0 && hashes <= 6 && line.dropFirst(hashes).hasPrefix(" ") {
                out += "#heading(level: \(hashes), text(\(Self.quote(String(line.dropFirst(hashes + 1))))))\n"
            } else if line.isEmpty { out += "#parbreak()\n" }
            else { out += "#text(\(Self.quote(line)))\n#linebreak()\n" }
        }
        guard code == nil else { throw PVTAError("Khối mã Markdown chưa có dấu đóng; hãy bổ sung trước khi xuất.") }
        return out
    }
}
