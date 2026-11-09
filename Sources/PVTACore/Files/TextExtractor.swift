import Foundation
import PDFKit

public struct ExtractedSegment: Codable, Sendable, Equatable {
    public var label: String
    public var text: String
}

public struct ExtractedText: Codable, Sendable, Equatable {
    /// "text", "docx", "xlsx", "pptx", "pdf"
    public var kind: String
    public var text: String
    /// Từng trang, trang tính, slide (rỗng với tệp văn bản thường).
    public var segments: [ExtractedSegment]
}

/// Trích văn bản từ tệp để đưa vào ngữ cảnh. Chỉ đọc, không sửa tệp.
public enum TextExtractor {
    public static let maxFileBytes = 50 * 1024 * 1024
    static let plainExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "htm",
                                               "typ", "tex", "log", "ini", "rtf", "srt", "vtt",
                                               "py", "js", "ts", "tsx", "jsx", "swift", "java", "c", "h", "cpp", "rs", "go", "rb", "php",
                                               "sh", "css", "scss", "sql", "toml", "cfg", "conf", "properties", "kt"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]

    public static func extract(_ url: URL) throws -> ExtractedText {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw PVTAError("“\(name)” lớn hơn 50 MB nên PVTA không đọc. Hãy chia nhỏ tệp.") }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw PVTAError("Không đọc được “\(name)”. Hãy kiểm tra tệp còn tồn tại và PVTA có quyền đọc.")
        }
        switch ext {
        case "docx": return try docx(data, name)
        case "xlsx": return try xlsx(data, name)
        case "pptx": return try pptx(data, name)
        case "pdf": return try pdf(url, name)
        case "doc", "xls", "ppt":
            throw PVTAError("“\(name)” là định dạng Office cũ (.\(ext)). Hãy mở bằng Office rồi lưu sang .\(ext)x trước khi đính kèm.")
        default:
            guard plainExtensions.contains(ext) || ext.isEmpty else {
                throw PVTAError("PVTA chưa đọc được tệp .\(ext) (“\(name)”). Hỗ trợ: văn bản, Markdown, CSV, JSON, Word, Excel, PowerPoint, PDF và ảnh.")
            }
            guard !data.contains(0), var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw PVTAError("“\(name)” không phải tệp văn bản đọc được.")
            }
            if ext == "html" || ext == "htm" { text = stripHTML(text) }
            return ExtractedText(kind: "text", text: text, segments: [])
        }
    }

    // MARK: XML

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] { out = out.replacingOccurrences(of: k, with: v) }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                let hex = (out as NSString).substring(with: m.range(at: 1)) == "x"
                let num = (out as NSString).substring(with: m.range(at: 2))
                if let code = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(t).replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func xmlString(_ data: Data?) -> String? { data.flatMap { String(data: $0, encoding: .utf8) } }

    /// Duyệt tuần tự các thẻ chữ và dấu ngắt của XML Office, ghép thành các dòng.
    private static func officeText(_ xml: String, textTag: String, paragraphEnd: String, extras: [String: String] = [:]) -> String {
        let alternatives = (["<\(textTag)(?: [^>]*)?>([^<]*)</\(textTag)>", paragraphEnd] + extras.keys).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: alternatives) else { return "" }
        var out = ""
        let ns = xml as NSString
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { out += decodeEntities(ns.substring(with: m.range(at: 1))); continue }
            let token = ns.substring(with: m.range)
            if token.hasPrefix("</") && token.hasSuffix("p>") { out += "\n" } else if let e = extras[token] { out += e } else { out += "\n" }
        }
        // Ô bảng: bỏ dấu xuống dòng của đoạn cuối ô để cả hàng nằm trên một dòng.
        return out.replacingOccurrences(of: "\n | ", with: " | ")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numberSuffix(_ name: String) -> Int { Int(name.filter(\.isNumber)) ?? 0 }

    // MARK: Word, Excel, PowerPoint

    static func docx(_ data: Data, _ name: String) throws -> ExtractedText {
        let zip = try ZipArchive(data: data)
        guard let xml = xmlString(try zip.read("word/document.xml")) else { throw PVTAError("“\(name)” không phải tệp Word hợp lệ.") }
        let text = officeText(xml, textTag: "w:t", paragraphEnd: "</w:p>",
                              extras: ["<w:tab/>": "\t", "<w:br/>": "\n", "</w:tc>": " | ", "</w:tr>": "\n"])
        return ExtractedText(kind: "docx", text: text, segments: [])
    }

    static func pptx(_ data: Data, _ name: String) throws -> ExtractedText {
        let zip = try ZipArchive(data: data)
        let slides = zip.entries.keys.filter { $0.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil }
            .sorted { numberSuffix($0) < numberSuffix($1) }
        guard !slides.isEmpty else { throw PVTAError("“\(name)” không phải tệp PowerPoint hợp lệ.") }
        var segments: [ExtractedSegment] = []
        for (i, s) in slides.enumerated() {
            let t = officeText(xmlString(try zip.read(s)) ?? "", textTag: "a:t", paragraphEnd: "</a:p>")
            segments.append(ExtractedSegment(label: "Slide \(i + 1)", text: t))
        }
        return ExtractedText(kind: "pptx", text: segments.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n\n"), segments: segments)
    }

    private static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for c in ref.uppercased().unicodeScalars where c.value >= 65 && c.value <= 90 { n = n * 26 + Int(c.value) - 64 }
        return max(0, n - 1)
    }

    static func xlsx(_ data: Data, _ name: String) throws -> ExtractedText {
        let zip = try ZipArchive(data: data)
        let sheets = zip.entries.keys.filter { $0.range(of: #"^xl/worksheets/sheet\d+\.xml$"#, options: .regularExpression) != nil }
            .sorted { numberSuffix($0) < numberSuffix($1) }
        guard !sheets.isEmpty else { throw PVTAError("“\(name)” không phải tệp Excel hợp lệ.") }
        var shared: [String] = []
        if let xml = xmlString(try zip.read("xl/sharedStrings.xml")), let re = try? NSRegularExpression(pattern: "<si>(.*?)</si>", options: .dotMatchesLineSeparators) {
            let ns = xml as NSString
            for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
                shared.append(officeText(ns.substring(with: m.range(at: 1)), textTag: "t", paragraphEnd: "$^"))
            }
        }
        var names: [String] = []
        if let wb = xmlString(try zip.read("xl/workbook.xml")), let re = try? NSRegularExpression(pattern: #"<sheet [^>]*name="([^"]*)""#) {
            let ns = wb as NSString
            names = re.matches(in: wb, range: NSRange(location: 0, length: ns.length)).map { decodeEntities(ns.substring(with: $0.range(at: 1))) }
        }
        let cell = try NSRegularExpression(pattern: #"<c ([^>]*?)(?:/>|>(.*?)</c>)"#, options: .dotMatchesLineSeparators)
        let row = try NSRegularExpression(pattern: #"<row [^>]*?(?:/>|>(.*?)</row>)"#, options: .dotMatchesLineSeparators)
        var segments: [ExtractedSegment] = []
        for (i, s) in sheets.enumerated() {
            let xml = xmlString(try zip.read(s)) ?? ""
            let nx = xml as NSString
            var lines: [String] = []
            for r in row.matches(in: xml, range: NSRange(location: 0, length: nx.length)) {
                guard r.range(at: 1).location != NSNotFound else { continue }
                let body = nx.substring(with: r.range(at: 1)) as NSString
                var cols: [Int: String] = [:]
                for c in cell.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                    let attrs = body.substring(with: c.range(at: 1))
                    guard c.range(at: 2).location != NSNotFound else { continue }
                    let inner = body.substring(with: c.range(at: 2))
                    let ref = attrs.range(of: #"\br="[A-Z]+\d+""#, options: .regularExpression).map { String(attrs[$0].dropFirst(3).prefix { $0.isLetter }) } ?? ""
                    let type = attrs.range(of: #"t="(\w+)""#, options: .regularExpression).map { String(attrs[$0]).dropFirst(3).dropLast() } ?? ""
                    var value = ""
                    if type == "inlineStr" { value = officeText(inner, textTag: "t", paragraphEnd: "$^") }
                    else if let v = inner.range(of: "<v>(.*?)</v>", options: .regularExpression) {
                        let raw = String(inner[v]).dropFirst(3).dropLast(4)
                        value = type == "s" ? (Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "") : decodeEntities(String(raw))
                    }
                    if !value.isEmpty { cols[columnIndex(ref)] = value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                }
                if let last = cols.keys.max() { lines.append((0...last).map { cols[$0] ?? "" }.joined(separator: "\t")) }
            }
            segments.append(ExtractedSegment(label: names.indices.contains(i) ? "Trang tính “\(names[i])”" : "Trang tính \(i + 1)", text: lines.joined(separator: "\n")))
        }
        return ExtractedText(kind: "xlsx", text: segments.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n\n"), segments: segments)
    }

    // MARK: PDF

    static func pdf(_ url: URL, _ name: String) throws -> ExtractedText {
        guard let doc = PDFDocument(url: url) else { throw PVTAError("“\(name)” không phải tệp PDF hợp lệ hoặc đã bị hỏng.") }
        if doc.isLocked { throw PVTAError("“\(name)” có mật khẩu. Hãy gỡ mật khẩu rồi đính kèm lại.") }
        var segments: [ExtractedSegment] = []
        for i in 0..<doc.pageCount {
            let t = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { segments.append(ExtractedSegment(label: "Trang \(i + 1)", text: t)) }
        }
        return ExtractedText(kind: "pdf", text: segments.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n"), segments: segments)
    }
}
