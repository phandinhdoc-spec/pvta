import Foundation

public struct TextHit: Sendable, Equatable {
    public var doc: String
    public var index: Int
    public var score: Double
    public var text: String
}

/// Chỉ mục tra cứu chữ cục bộ (BM25) cho sổ nguồn, tài liệu dự án và hướng dẫn. Chữ được gấp dấu tiếng Việt cả hai phía
/// nên “quy tắc lõi” khớp “quy tac loi”. Dựng trong bộ nhớ từ các khúc chữ đã lưu; không gọi mạng, không gọi AI.
public struct TextIndex: Sendable {
    public struct Entry: Sendable { public var doc: String; public var index: Int; public var title: String; public var text: String
        public init(doc: String, index: Int, title: String = "", text: String) { self.doc = doc; self.index = index; self.title = title; self.text = text } }

    private struct Row { var entry: Entry; var tf: [String: Int]; var titleTokens: Set<String>; var length: Int }
    private var rows: [Row] = []
    private var df: [String: Int] = [:]
    private var avgLength = 1.0

    static let stop: Set<String> = ["va", "la", "cua", "cho", "voi", "nhu", "khi", "the", "nao", "gi", "nay", "do", "mot", "cac", "duoc", "trong", "o", "thi", "ma", "hay"]

    public static func tokens(_ s: String) -> [String] {
        Fold.text(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 && !stop.contains($0) }
    }

    public init(_ entries: [Entry]) {
        for e in entries {
            let toks = Self.tokens(e.text)
            var tf: [String: Int] = [:]
            for t in toks { tf[t, default: 0] += 1 }
            for t in tf.keys { df[t, default: 0] += 1 }
            rows.append(Row(entry: e, tf: tf, titleTokens: Set(Self.tokens(e.title)), length: max(toks.count, 1)))
        }
        avgLength = rows.isEmpty ? 1 : Double(rows.reduce(0) { $0 + $1.length }) / Double(rows.count)
    }

    public var count: Int { rows.count }

    /// Các khúc khớp nhất. Chấp nhận cả chữ có dấu lẫn không dấu. Không có từ nào khớp thì trả rỗng.
    public func search(_ query: String, limit: Int = 8, allow: (String) -> Bool = { _ in true }) -> [TextHit] {
        let q = Array(Set(Self.tokens(query)))
        guard !q.isEmpty, !rows.isEmpty else { return [] }
        let n = Double(rows.count)
        var out: [TextHit] = []
        for r in rows where allow(r.entry.doc) {
            var score = 0.0
            for t in q {
                let f = Double(r.tf[t] ?? 0)
                if f > 0 {
                    let idf = log(1 + (n - Double(df[t] ?? 0) + 0.5) / (Double(df[t] ?? 0) + 0.5))
                    score += idf * (f * 2.5) / (f + 1.5 * (0.25 + 0.75 * Double(r.length) / avgLength))
                }
                if r.titleTokens.contains(t) { score += 1.5 }
            }
            if score > 0 { out.append(TextHit(doc: r.entry.doc, index: r.entry.index, score: score, text: r.entry.text)) }
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.doc, $0.index) < ($1.doc, $1.index) }.prefix(limit))
    }

    /// Chia chữ thành khúc cỡ `size` ký tự, ưu tiên cắt ở ranh giới đoạn, rồi câu, rồi từ; không bỏ chữ.
    public static func chunk(_ text: String, size: Int = 1200) -> [String] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [String] = [], buf = ""
        func flush() { let x = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !x.isEmpty { out.append(x) }; buf = "" }
        for para in t.components(separatedBy: "\n\n") {
            var p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            while p.count > size {
                let head = String(p.prefix(size))
                var cut = head.endIndex
                for sep in ["\n", ". ", "; ", ", ", " "] { if let r = head.range(of: sep, options: .backwards), head.distance(from: head.startIndex, to: r.upperBound) > size / 2 { cut = r.upperBound; break } }
                if !buf.isEmpty { flush() }
                out.append(String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
                p = String(p.dropFirst(head.distance(from: head.startIndex, to: cut))).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !buf.isEmpty && buf.count + p.count + 2 > size { flush() }
            buf += (buf.isEmpty ? "" : "\n\n") + p
        }
        flush()
        return out
    }

    /// Đoạn trích quanh từ khớp đầu tiên, tối đa `max` ký tự.
    public static func snippet(_ text: String, query: String, max: Int = 360) -> String {
        guard text.count > max else { return text }
        let toks = tokens(query)
        let folded = Fold.text(text)
        var at = 0
        for t in toks { if let r = folded.range(of: t) { at = folded.distance(from: folded.startIndex, to: r.lowerBound); break } }
        let start = Swift.max(0, at - max / 4)
        let s = text.index(text.startIndex, offsetBy: min(start, text.count))
        return (start > 0 ? "…" : "") + String(text[s...].prefix(max)) + (start + max < text.count ? "…" : "")
    }
}
