import Foundation
import PDFKit
import AppKit

extension FileService {
    /// Đọc toàn bộ nguồn/mẫu được cấp quyền, không lấy trích đoạn thay cho tài liệu.
    private func typstInput(_ path: String, chat: String) async throws -> String {
        let p = try await resolve(path, chatId: chat, write: false)
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1_000_000,
              let data = FileManager.default.contents(atPath: p), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PVTAError("Không đọc được toàn bộ nguồn UTF-8 hoặc nguồn vượt 1 MB: " + (p as NSString).lastPathComponent)
        }
        return text
    }
    func typstExport(_ args: JSONValue, compileTimeout: Duration = .seconds(120)) async throws -> JSONValue {
        let chat = try args.requireString("chatId"), output = try args.requireString("output")
        let dest = try await resolve(output, chatId: chat, write: true)
        guard dest.lowercased().hasSuffix(".zip"), !FileManager.default.fileExists(atPath: dest) else { throw PVTAError("Chọn tên ZIP mới; PVTA không ghi đè tên trùng.") }
        var layout = TypstLayout()
        if let value = args["templates"] {
            guard case .array(let paths) = value, paths.count <= 10 else { throw PVTAError("templates phải là danh sách tối đa 10 mẫu.") }
            for item in paths {
                guard let path = item.string, ["typ", "md"].contains((path as NSString).pathExtension.lowercased()) else { throw PVTAError("Mẫu cần là tệp .typ hoặc .md đã cấp quyền.") }
                layout.learn(try await typstInput(path, chat: chat), name: (path as NSString).lastPathComponent)
            }
        }
        let format = args["format"]?.string ?? "markdown"
        guard ["markdown", "text", "typst"].contains(format) else { throw PVTAError("format phải là markdown, text hoặc typst.") }
        guard (args["text"] != nil) != (args["path"] != nil) else { throw PVTAError("Cần đúng một nguồn: text hoặc path.") }
        let source: String
        if let path = args["path"]?.string {
            guard ["md", "txt", "typ"].contains((path as NSString).pathExtension.lowercased()) else { throw PVTAError("Nguồn chỉ nhận .md, .txt hoặc .typ.") }
            source = try await typstInput(path, chat: chat)
        } else { source = try args.requireString("text") }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 1_000_000 else { throw PVTAError("Nguồn trống hoặc vượt 1 MB.") }
        let code = format == "typst" ? source : try layout.convert(source, markdown: format == "markdown")
        if format == "typst" {
            // Không cho mã tùy ý đọc tài nguyên, tải gói hay tạo mã động. Mẫu chỉ được phân tích, không chạy.
            let forbidden = #"\b(import|include|read|image|csv|json|yaml|xml|cbor|bibliography|eval|plugin)\b|@preview|https?://"#
            guard code.range(of: forbidden, options: .regularExpression) == nil else { throw PVTAError("Typst phải tự chứa; chưa hỗ trợ đọc tệp, ảnh, import/package hay mã động.") }
            guard layout.evidence.isEmpty else { throw PVTAError("Mã Typst có sẵn tự quyết định bố cục; chỉ áp mẫu khi nguồn là Markdown/văn bản.") }
        }
        let rules = layout.evidence.isEmpty ? "Không dùng mẫu đính kèm; dùng bố cục A4 mặc định." : layout.evidence.joined(separator: "\n")
        let plan = ActionPlan(kind: .write, summary: "Xuất ZIP Typst", preview: "PDF để xem/in, mã .typ để chỉnh sửa, ảnh xem trước và hướng dẫn.\n" + dest + "\n" + rules + "\nChạy trình biên dịch cục bộ, tối đa 120 giây.", paths: [dest])
        // Biên dịch là chạy mã: luôn hỏi, kể cả mức Tự sửa.
        let runTool = ToolSpec(name: "typst_export", summary: "Xuất Typst", parameters: "{}", access: .run, plan: { _ in
            ActionPlan(kind: .run, summary: plan.summary, preview: plan.preview, paths: plan.paths)
        }) { _ in "" }
        switch await PermissionPolicy(permissions).decide(runTool, args: args, chatId: chat) {
        case .deny(let why): throw PVTAError(why)
        case .allow: break
        }
        try Task.checkCancellation()
        guard permissions.level() != .readOnly else { throw PVTAError("Chế độ Chỉ đọc không cho xuất tài liệu.") }
        _ = try await resolve(dest, chatId: chat, write: true)
        let binary = ["/opt/homebrew/bin/typst", "/usr/local/bin/typst"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary else { throw PVTAError("Chưa có trình biên dịch Typst trên máy. Hãy cài Typst trước khi xuất.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-typst-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        try code.write(to: work.appendingPathComponent("document.typ"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["compile", "--root", work.path, "--package-path", work.path, "--package-cache-path", work.path, "document.typ", "document.pdf"]
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": work.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: min(compileTimeout, .seconds(120)))
        do {
            while process.isRunning {
                if ContinuousClock.now >= deadline { throw PVTAError("Biên dịch Typst vượt 120 giây; không tạo ZIP.") }
                try await Task.sleep(for: .milliseconds(30))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw error
        }
        guard process.terminationStatus == 0, let pdf = try? Data(contentsOf: work.appendingPathComponent("document.pdf")),
              let doc = PDFDocument(data: pdf), doc.pageCount > 0, doc.pageCount <= 100 else { throw PVTAError("Biên dịch Typst lỗi hoặc tài liệu vượt 100 trang. Hãy kiểm tra mã nguồn; chưa tạo ZIP.") }
        var zip = ZipWriter()
        zip.add("document.typ", Data(code.utf8)); zip.add("document.pdf", pdf)
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let tiff = page.thumbnail(of: NSSize(width: 900, height: 1200), for: .mediaBox).tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw PVTAError("Không tạo được đủ ảnh xem trước; chưa công bố ZIP.") }
            zip.add("preview-\(i + 1).png", png)
        }
        zip.add("README.txt", Data(("PDF dùng xem/in; sửa document.typ rồi chạy: typst compile document.typ document.pdf\nẢnh preview tương ứng từng trang.\n" + rules + "\nMarkdown: đề mục, bảng và khối mã được dàn trang; ký hiệu định dạng nội dòng khác giữ nguyên chữ để không mất nội dung.\n").utf8))
        let checked = try await resolve(dest, chatId: chat, write: true)
        guard permissions.level() != .readOnly else { throw PVTAError("Quyền ghi đã bị thu hồi.") }
        try Task.checkCancellation()
        let data = zip.finish()
        try Self.atomicWrite(data, to: checked, exclusive: true)
        let change = FileChange(id: UUID().uuidString, chatId: chat, kind: "create", path: checked, original: nil, backup: nil, trashPath: nil, beforeHash: nil, afterHash: FileHash.of(data), detail: "Xuất ZIP Typst", createdAt: Date(), undone: false)
        try await store.recordChange(change)
        return ["path": .string(checked), "pages": .number(Double(doc.pageCount)), "rules": .string(rules), "changeId": .string(change.id)]
    }
}
