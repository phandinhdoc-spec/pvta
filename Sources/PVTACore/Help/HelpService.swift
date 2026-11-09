import Foundation

public struct HelpAnswer: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable { public var chapter: String; public var title: String; public var text: String }
    /// Có căn cứ trong hướng dẫn hay không. Không có thì `message` đề nghị nêu tên chức năng.
    public var found: Bool
    public var message: String
    public var sources: [Source]
    public var label: String?
    public var x: Double?
    public var y: Double?
}

/// Tra cứu hướng dẫn cục bộ, dùng chung cho sách hướng dẫn và “Hỏi PVTA về chỗ này”.
/// Cố ý không có đường nào tới model AI và không nhận nội dung hội thoại hay giá trị ô nhập: chỉ nhận câu hỏi/tên chức năng và nhãn của chỗ được chọn.
public final class HelpService: Sendable {
    let chapters: [HelpChapter]
    let index: TextIndex
    private let chunkTokens: [String: [Set<String>]]
    private let df: [String: Int]
    private let chunkCount: Int
    static let minScore = 2.0

    public convenience init() { self.init(chapters: HelpContent.all) }

    public init(chapters: [HelpChapter]) {
        self.chapters = chapters
        var entries: [TextIndex.Entry] = []
        var tokens: [String: [Set<String>]] = [:], df: [String: Int] = [:]
        for c in chapters {
            for (i, para) in c.body.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }).enumerated() {
                entries.append(.init(doc: c.id, index: i, title: c.title, text: para))
                let set = Set(TextIndex.tokens(c.title + " " + para))
                tokens[c.id, default: []].append(set)
                for t in set { df[t, default: 0] += 1 }
            }
        }
        index = TextIndex(entries)
        chunkTokens = tokens
        self.df = df
        chunkCount = entries.count
    }

    /// Từ khóa có ích của câu hỏi: bỏ từ xuất hiện ở quá nhiều đoạn (như “không”, “như”, “này”); từ lạ (chưa có trong sách) được giữ.
    private func informative(_ query: String) -> [String] {
        let all = Array(Set(TextIndex.tokens(query)))
        let rare = all.filter { Double(df[$0] ?? 0) <= Double(chunkCount) * 0.4 }
        return rare.isEmpty ? all : rare
    }

    /// Mục lục theo nhóm.
    public func toc() -> [(group: String, chapters: [(id: String, title: String, number: Int)])] {
        var order: [String] = []
        for c in chapters where !order.contains(c.group) { order.append(c.group) }
        return order.map { g in (g, chapters.enumerated().filter { $0.element.group == g }.map { ($0.element.id, $0.element.title, $0.offset + 1) }) }
    }

    public func chapter(_ id: String) -> HelpChapter? { chapters.first { $0.id == id } }

    /// Tra cứu cho ô tìm của sách: trả các chương theo độ khớp (không phân biệt dấu).
    public func search(_ query: String, limit: Int = 8, coverage: Double = 0) -> [HelpAnswer.Source] {
        var seen = Set<String>(), out: [HelpAnswer.Source] = []
        let key = informative(query)
        for h in index.search(query, limit: 40) where h.score >= Self.minScore {
            // Đoạn phải chứa ít nhất một (hoặc theo `coverage`, một phần) từ khóa có ích của câu hỏi.
            let have = (chunkTokens[h.doc].flatMap { $0.indices.contains(h.index) ? $0[h.index] : nil }) ?? []
            let matched = key.filter { have.contains($0) }.count
            guard !key.isEmpty, matched >= max(1, Int((Double(key.count) * coverage).rounded(.up))) else { continue }
            guard seen.insert(h.doc).inserted, let c = chapter(h.doc) else { continue }
            out.append(.init(chapter: c.id, title: c.title, text: TextIndex.snippet(h.text, query: query, max: 300)))
            if out.count >= limit { break }
        }
        return out
    }

    /// “Hỏi PVTA về chỗ này”. `label` là nhãn giao diện (ví dụ tên nút), `question` là câu hỏi hoặc tên chức năng.
    /// Chỉ hai trường chữ ngắn này được dùng; trả lời là trích đoạn hướng dẫn, không gọi AI.
    public func ask(question: String?, label: String?, x: Double? = nil, y: Double? = nil) -> HelpAnswer {
        let lab = label.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        let q = String((question ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        // Câu hỏi chung chung (“Chỗ này dùng như thế nào?”) không mang thông tin: lấy nhãn của chỗ được chọn làm câu hỏi.
        let generic = try! NSRegularExpression(pattern: #"\b(cho nay|dung nhu the nao|nhu the nao|la gi|de lam gi|dung de lam gi|tac dung|cach dung|cach su dung|su dung|dung|nay|o day|the nao)\b"#)
        let folded = Fold.text(q)
        let specific = generic.stringByReplacingMatches(in: folded, range: NSRange(location: 0, length: (folded as NSString).length), withTemplate: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,"))
        let query = [lab ?? "", specific.isEmpty ? "" : q].filter { !$0.isEmpty }.joined(separator: " ")
        var answer = HelpAnswer(found: false, message: "", sources: [], label: lab, x: x, y: y)
        guard !query.isEmpty else {
            answer.message = "Hãy nêu tên chức năng cần hỏi, ví dụ “duyệt thao tác”, “chọn mô hình” hoặc “Excel”."
            return answer
        }
        let hits = search(query, limit: 3, coverage: 0.75)
        guard !hits.isEmpty else {
            answer.message = "Chưa thấy căn cứ trong hướng dẫn cho “\(query)”. Hãy nêu tên chức năng cụ thể (ví dụ “duyệt thao tác”, “chọn mô hình”, “Excel”)."
            return answer
        }
        answer.found = true
        answer.sources = hits
        answer.message = (lab.map { "Về “\($0)”: " } ?? "") + "Hướng dẫn trên máy có \(hits.count) mục liên quan. Bấm tên chương để đọc đầy đủ."
        return answer
    }
}
