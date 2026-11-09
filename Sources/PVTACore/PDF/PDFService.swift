import Foundation
import PDFKit
import CoreText

/// Phiên nhận dữ liệu giữ trong bộ nhớ có giới hạn. Chỉ công bố tệp sau khi kiểm tra và duyệt.
public actor PDFService {
    static let maxBytes = 50 * 1024 * 1024
    static let maxChunk = 512 * 1024
    private struct Pending {
        let path: String
        let chat: String
        let size: Int
        var data = Data()
        var updated = Date()
    }
    private var pending: [String: Pending] = [:]
    private var finishing: Set<String> = []
    private let files: FileService
    init(files: FileService) { self.files = files }

    static func document(_ data: Data) throws -> PDFDocument {
        guard data.count <= maxBytes, data.starts(with: Data("%PDF-".utf8)),
              String(decoding: data.suffix(1024), as: UTF8.self).contains("%%EOF"),
              let doc = PDFDocument(data: data), !doc.isLocked, doc.pageCount > 0, doc.pageCount <= 2000 else {
            throw PVTAError("PDF không hợp lệ, chưa nhận đủ, có mật khẩu hoặc vượt giới hạn 50 MB/2.000 trang.")
        }
        return doc
    }
    private func source(_ path: String, chat: String?) async throws -> Data {
        let real = try await files.resolve(path, chatId: chat, write: false)
        guard real.lowercased().hasSuffix(".pdf") else { throw PVTAError("Chỉ nhận tệp .pdf.") }
        var st = stat()
        guard lstat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= Self.maxBytes,
              let data = FileManager.default.contents(atPath: real) else { throw PVTAError("Không đọc được PDF hoặc tệp lớn hơn 50 MB.") }
        return data
    }
    public func read(path: String, chat: String?) async throws -> JSONValue {
        let doc = try Self.document(await source(path, chat: chat))
        var pages: [JSONValue] = []
        for i in 0..<doc.pageCount {
            let text = (doc.page(at: i)?.string ?? "").precomposedStringWithCanonicalMapping
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pages.append(["page": .number(Double(i + 1)), "text": .string(text), "warning": .string(empty ? "Trang chưa có lớp chữ đọc được (có thể là ảnh quét hoặc trang trống); cần OCR nếu có nội dung." : "")])
        }
        return ["pages": .array(pages), "pageCount": .number(Double(doc.pageCount))]
    }
    /// Vùng theo tọa độ PDF: đơn vị point, gốc dưới trái, trước phép xoay trang.
    public func region(path: String, chat: String?, page: Int, rect: CGRect) async throws -> JSONValue {
        let doc = try Self.document(await source(path, chat: chat))
        guard page >= 1, page <= doc.pageCount, let p = doc.page(at: page - 1),
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy({ $0.isFinite }), rect.width > 0, rect.height > 0,
              p.bounds(for: .mediaBox).contains(rect) else { throw PVTAError("Số trang hoặc vùng đọc nằm ngoài trang PDF.") }
        let text = (p.selection(for: rect)?.string ?? "").precomposedStringWithCanonicalMapping
        return ["text": .string(text), "warning": .string(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Vùng chọn không có chữ đọc được; ảnh quét cần OCR." : "")]
    }
    static func integer(_ v: JSONValue?, _ label: String, max: Int) throws -> Int {
        guard let n = v?.number, n.isFinite, n.rounded() == n, n >= 0, n <= Double(max) else { throw PVTAError("Giá trị “\(label)” phải là số nguyên từ 0 đến \(max).") }
        return Int(n)
    }
    private func destination(_ path: String, chat: String) async throws -> String {
        let real = try await files.resolve(path, chatId: chat, write: true)
        guard real.lowercased().hasSuffix(".pdf"), !FileManager.default.fileExists(atPath: real) else { throw PVTAError("Hãy chọn tên PDF mới; PVTA không ghi đè tệp có sẵn.") }
        return real
    }
    private func publish(_ data: Data, path: String, chat: String, sessionID: String? = nil) async throws -> JSONValue {
        let count = try Self.document(data).pageCount
        let plan = ActionPlan(kind: .write, summary: "Lưu PDF mới", preview: "\(path)\n\(count) trang, \(data.count) byte", paths: [path])
        let tool = ToolSpec(name: "pdf_write", summary: "Lưu PDF", parameters: "{}", access: .write, plan: { _ in plan }) { _ in "" }
        switch await PermissionPolicy(files.permissions).decide(tool, args: [:], chatId: chat) {
        case .deny(let why): throw PVTAError(why)
        case .allow: break
        }
        try Task.checkCancellation()
        guard files.permissions.level() != .readOnly else { throw PVTAError("Chế độ Chỉ đọc không cho lưu PDF.") }
        let checked = try await destination(path, chat: chat)
        if let sessionID, pending[sessionID] == nil { throw PVTAError("Đã hủy phiên ghi PDF.") }
        try Task.checkCancellation()
        try FileService.atomicWrite(data, to: checked, exclusive: true)
        let c = FileChange(id: UUID().uuidString, chatId: chat, kind: "create", path: checked, original: nil, backup: nil, trashPath: nil, beforeHash: nil, afterHash: FileHash.of(data), detail: "Lưu PDF", createdAt: Date(), undone: false)
        try await files.store.recordChange(c)
        return ["path": .string(checked), "size": .number(Double(data.count)), "pages": .number(Double(count)), "changeId": .string(c.id)]
    }
    /// Tách thành một PDF mới gồm các trang được chọn; gộp giữ thứ tự nguồn rồi thứ tự trang.
    public func combine(paths: [String], pages: [Int]?, output: String, chat: String) async throws -> JSONValue {
        guard !paths.isEmpty, paths.count <= 100, pages == nil || paths.count == 1 else { throw PVTAError("Gộp cần 1–100 nguồn; tách chỉ nhận một nguồn.") }
        let dest = try await destination(output, chat: chat)
        let result = PDFDocument()
        for path in paths {
            try Task.checkCancellation()
            let doc = try Self.document(await source(path, chat: chat))
            let selected = pages ?? Array(1...doc.pageCount)
            guard !selected.isEmpty, selected.count <= 2000, result.pageCount + selected.count <= 2000 else { throw PVTAError("Cần từ 1 đến 2.000 trang kết quả.") }
            for n in selected {
                guard n > 0, n <= doc.pageCount, let copy = doc.page(at: n - 1)?.copy() as? PDFPage else { throw PVTAError("Trang được chọn không tồn tại.") }
                result.insert(copy, at: result.pageCount)
            }
        }
        guard let data = result.dataRepresentation() else { throw PVTAError("Không tạo được PDF kết quả.") }
        return try await publish(data, path: dest, chat: chat)
    }
    public func begin(path: String, chat: String, size: Int) async throws -> String {
        pending = pending.filter { Date().timeIntervalSince($0.value.updated) < 600 }
        guard size > 0, size <= Self.maxBytes, pending.count < 4 else { throw PVTAError("PDF tối đa 50 MB, chỉ nhận đồng thời 4 phiên ghi.") }
        let dest = try await destination(path, chat: chat)
        guard pending.count < 4 else { throw PVTAError("Đã đủ 4 phiên ghi PDF.") }
        let id = UUID().uuidString
        pending[id] = Pending(path: dest, chat: chat, size: size)
        return id
    }
    private func session(_ id: String, chat: String) throws -> Pending {
        guard let w = pending[id], w.chat == chat else { throw PVTAError("Phiên ghi PDF không tồn tại trong hội thoại này.") }
        guard Date().timeIntervalSince(w.updated) < 600 else { pending[id] = nil; throw PVTAError("Phiên ghi PDF đã hết hạn.") }
        return w
    }
    public func chunk(id: String, chat: String, offset: Int, base64: String) throws -> Int {
        var w = try session(id, chat: chat)
        guard !finishing.contains(id) else { throw PVTAError("Phiên PDF đang hoàn tất, không nhận thêm dữ liệu.") }
        guard base64.utf8.count <= Self.maxChunk * 2, let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= Self.maxChunk,
              offset == w.data.count, w.data.count + bytes.count <= w.size else { throw PVTAError("Đoạn PDF sai thứ tự, sai base64 hoặc vượt kích thước đã khai báo.") }
        w.data.append(bytes); w.updated = Date(); pending[id] = w
        return w.data.count
    }
    public func finish(id: String, chat: String) async throws -> JSONValue {
        let w = try session(id, chat: chat)
        guard !finishing.contains(id) else { throw PVTAError("Phiên PDF đang hoàn tất.") }
        finishing.insert(id)
        defer { pending[id] = nil; finishing.remove(id) }
        guard w.data.count == w.size else { throw PVTAError("Chưa nhận đủ dữ liệu PDF; đã bỏ phiên ghi.") }
        return try await publish(w.data, path: w.path, chat: chat, sessionID: id)
    }
    public func abort(id: String, chat: String) throws {
        if pending[id] == nil { return }
        _ = try session(id, chat: chat)
        pending[id] = nil
    }
    public static func font() throws -> JSONValue {
        let path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        let font = CTFontCreateWithName("Arial" as CFString, 12, nil)
        let sample = Array("Tiếng Việt: ăâđêôơư ÁÀẢÃẠ ắằẳẵặ ấầẩẫậ ếềểễệ ốồổỗộ ớờởỡợ ứừửữự".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: sample.count)
        guard CTFontGetGlyphsForCharacters(font, sample, &glyphs, sample.count), let data = FileManager.default.contents(atPath: path), data.count < 2 * 1024 * 1024 else { throw PVTAError("Không tìm thấy phông Arial có đủ dấu tiếng Việt.") }
        return ["name": "Arial", "data": .string(data.base64EncodedString())]
    }
}
