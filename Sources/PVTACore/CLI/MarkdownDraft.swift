import Darwin
import Foundation

/// Trạng thái bản nháp Markdown trong phiên làm việc CLI tương tác.
public struct MarkdownDraftState: Sendable, Equatable {
    public var path: String
    public var original: String
    public var text: String
    public var saved: String?
    public var previous: String?

    public init(path: String, original: String, text: String, saved: String? = nil, previous: String? = nil) {
        self.path = path
        self.original = original
        self.text = text
        self.saved = saved
        self.previous = previous
    }

    public var isDirty: Bool { text != original }
}

/// Quản lý các lệnh sửa Markdown của CLI tương tác (`/edit`, `/replace`, `/toc`, `/diff`, `/save`, `/discard`, `/undo`, `/editor`).
public enum MarkdownDraftManager {
    public static let allowedExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Mở tệp Markdown trong thư mục làm việc để tạo bản nháp.
    public static func open(cwd: String, inputPath: String) throws -> MarkdownDraftState {
        let full = try WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: inputPath, mustExist: true)
        let ext = (full as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw PVTAError("Chế độ sửa Markdown chỉ hỗ trợ tệp .md, .markdown, .txt: \(inputPath)")
        }
        var st = stat()
        guard stat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw PVTAError("Đường dẫn không phải tệp văn bản hợp lệ: \(inputPath)")
        }
        guard Int(st.st_size) <= WorkspaceGuard.maxMarkdownFileBytes else {
            throw PVTAError("Tệp Markdown quá lớn (> 1 MB): \(inputPath)")
        }
        guard let data = FileManager.default.contents(atPath: full),
              let content = String(data: data, encoding: .utf8) else {
            throw PVTAError("Tệp không phải văn bản UTF-8 hợp lệ: \(inputPath)")
        }
        return MarkdownDraftState(path: full, original: content, text: content)
    }

    /// Thay nội dung một dòng (đánh số từ 1) trong bản nháp.
    public static func replaceLine(_ draft: inout MarkdownDraftState, line: Int, content: String) throws {
        var lines = draft.text.components(separatedBy: "\n")
        guard line >= 1 && line <= lines.count else {
            throw PVTAError("Số dòng không hợp lệ (\(line)). Tệp có \(lines.count) dòng.")
        }
        lines[line - 1] = content
        draft.text = lines.joined(separator: "\n")
    }

    /// Trích mục lục tiêu đề Markdown (bỏ qua khối mã ``` hoặc ~~~).
    public static func toc(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var items: [String] = []
        var activeFence: Character? = nil

        for (index, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first!
                if activeFence == nil {
                    activeFence = marker
                } else if activeFence == marker {
                    activeFence = nil
                }
                continue
            }
            if activeFence != nil { continue }

            // Kiểm tra tiêu đề dạng #{1,6} <tiêu đề>
            var hashes = 0
            var idx = line.startIndex
            while idx < line.endIndex && line[idx] == "#" && hashes < 7 {
                hashes += 1
                idx = line.index(after: idx)
            }
            guard (1...6).contains(hashes), idx < line.endIndex, line[idx] == " " || line[idx] == "\t" else {
                continue
            }
            let title = line[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let indent = String(repeating: "  ", count: hashes - 1)
            let num = String(index + 1).leftPadding(toLength: 4, withPad: " ")
            items.append("\(num) | \(indent)\(title)")
        }
        return items.isEmpty ? "Không có tiêu đề Markdown." : items.joined(separator: "\n")
    }

    /// Tạo diff giữa bản gốc trên đĩa lúc mở và bản nháp hiện tại.
    public static func diff(_ draft: MarkdownDraftState) -> String {
        let out = DiffText.unified(old: draft.original, new: draft.text)
        return out.isEmpty ? "Không có thay đổi so với bản gốc." : out
    }

    /// Ghi nguyên tử (atomic write) để Ctrl-C không bao giờ để lại tệp ghi dở.
    public static func atomicWrite(_ text: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".pvta-md-\(UUID().uuidString).tmp")
        let data = Data(text.utf8)
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw PVTAError("Không tạo được tệp tạm để lưu an toàn.")
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(tmp)
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PVTAError("Lỗi khi ghi dữ liệu ra đĩa.")
                }
                written += n
            }
        }
        _ = fsync(fd)
        close(fd)
        closed = true
        guard rename(tmp, path) == 0 else {
            throw PVTAError("Không thể hoàn tất ghi tệp: \((path as NSString).lastPathComponent)")
        }
    }

    /// Lưu bản nháp ra đĩa nếu tệp gốc chưa bị sửa bên ngoài.
    public static func save(_ draft: inout MarkdownDraftState, cwd: String) throws {
        let verified = try WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: draft.path, mustExist: true)
        guard verified == draft.path else {
            throw PVTAError("Đường dẫn tệp bản nháp đã thay đổi ngoài dự kiến.")
        }
        guard let diskData = FileManager.default.contents(atPath: verified),
              let currentDisk = String(data: diskData, encoding: .utf8) else {
            throw PVTAError("Không đọc được tệp gốc để đối chiếu trước khi lưu.")
        }
        guard currentDisk == draft.original else {
            throw PVTAError("Tệp đã thay đổi trên đĩa ngoài phiên sửa. Dùng /diff để kiểm tra hoặc /discard rồi /edit lại.")
        }
        try atomicWrite(draft.text, to: verified)
        draft.previous = draft.original
        draft.saved = draft.text
        draft.original = draft.text
    }

    /// Hoàn tác lần `/save` gần nhất trong phiên nếu tệp trên đĩa chưa bị sửa bên ngoài.
    public static func undo(_ draft: inout MarkdownDraftState, cwd: String) throws {
        guard let previous = draft.previous, let saved = draft.saved else {
            throw PVTAError("Không có lần lưu trước trong phiên hiện tại để hoàn tác.")
        }
        let verified = try WorkspaceGuard.resolveInWorkspace(cwd: cwd, inputPath: draft.path, mustExist: true)
        guard let diskData = FileManager.default.contents(atPath: verified),
              let currentDisk = String(data: diskData, encoding: .utf8) else {
            throw PVTAError("Không đọc được tệp trên đĩa để kiểm tra trước khi hoàn tác.")
        }
        guard currentDisk == saved else {
            throw PVTAError("Tệp đã thay đổi trên đĩa sau lần /save gần nhất. Không thể /undo tự động.")
        }
        try atomicWrite(previous, to: verified)
        draft.original = previous
        draft.text = previous
        draft.saved = nil
        draft.previous = nil
    }

    /// Tách lệnh `$VISUAL` / `$EDITOR` / `vi` theo dấu nháy, không chạy qua shell.
    public static func editorArgs(env: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let raw = (env["VISUAL"] ?? env["EDITOR"] ?? "vi").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw PVTAError("Biến môi trường VISUAL/EDITOR trống.")
        }
        var args: [String] = []
        var current = ""
        var quote: Character? = nil
        var tokenStarted = false

        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            if quote == "'" {
                if ch == "'" { quote = nil }
                else { current.append(ch) }
                i = raw.index(after: i)
                continue
            }
            if ch == "\\" {
                let next = raw.index(after: i)
                guard next < raw.endIndex else {
                    throw PVTAError("Cấu hình VISUAL/EDITOR kết thúc bằng dấu \\ không hợp lệ.")
                }
                let nextCh = raw[next]
                if quote == "\"" && nextCh != "\"" && nextCh != "\\" && nextCh != "$" && nextCh != "`" {
                    current.append(ch)
                }
                current.append(nextCh)
                tokenStarted = true
                i = raw.index(after: next)
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                else { current.append(ch) }
                i = raw.index(after: i)
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                tokenStarted = true
                i = raw.index(after: i)
                continue
            }
            if ch.isWhitespace {
                if tokenStarted {
                    args.append(current)
                    current = ""
                    tokenStarted = false
                }
                i = raw.index(after: i)
                continue
            }
            current.append(ch)
            tokenStarted = true
            i = raw.index(after: i)
        }

        if quote != nil {
            throw PVTAError("Cấu hình VISUAL/EDITOR có dấu nháy chưa đóng.")
        }
        if tokenStarted {
            args.append(current)
        }
        guard let first = args.first, !first.isEmpty else {
            throw PVTAError("Không xác định được trình soạn thảo từ VISUAL/EDITOR.")
        }
        return args
    }

    /// Mở trình soạn thảo ngoài (`$VISUAL` / `$EDITOR` / `vi`) trên tệp tạm `0600` và cập nhật lại bản nháp.
    public static func runExternalEditor(_ draft: inout MarkdownDraftState, env: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        let parsed = try editorArgs(env: env)
        let cmd = parsed[0]
        let extraArgs = Array(parsed.dropFirst())

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pvta-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseName = (draft.path as NSString).lastPathComponent
        let safeName = baseName.replacingOccurrences(of: "/", with: "_")
        let tempFile = tempDir.appendingPathComponent(safeName.isEmpty ? "draft.md" : safeName)
        try atomicWrite(draft.text, to: tempFile.path)

        let proc = Process()
        if cmd.contains("/") {
            proc.executableURL = URL(fileURLWithPath: cmd)
            proc.arguments = extraArgs + [tempFile.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [cmd] + extraArgs + [tempFile.path]
        }
        proc.environment = env
        proc.standardInput = FileHandle.standardInput
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw PVTAError("Không mở được trình soạn thảo '\(cmd)': \(error.localizedDescription)")
        }

        guard proc.terminationStatus == 0 else {
            return false
        }
        guard let updatedData = FileManager.default.contents(atPath: tempFile.path),
              let updatedText = String(data: updatedData, encoding: .utf8) else {
            throw PVTAError("Không đọc lại được nội dung sau khi đóng trình soạn thảo.")
        }
        draft.text = updatedText
        return true
    }
}
