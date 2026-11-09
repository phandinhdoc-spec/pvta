import Darwin
import Foundation

/// Kiểm tra đường dẫn thật (kể cả giải liên kết tượng trưng) cho các lệnh tệp trực tiếp của CLI tương tác (`/code`, `/edit`, `/open`, `/attach`, `/diff`).
/// Mọi đường dẫn phải nằm gọn trong thư mục làm việc hiện tại (`cwd`).
public enum WorkspaceGuard {
    public static let maxCodeFileBytes = 512 * 1024
    public static let maxMarkdownFileBytes = 1024 * 1024

    /// Chuẩn hóa thư mục làm việc hiện tại (giải symlink).
    public static func canonicalCwd(_ cwd: String) throws -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
        var st = stat()
        guard stat(abs, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              let real = PathGuard.canonical(abs) else {
            throw PVTAError("Thư mục làm việc không tồn tại hoặc không hợp lệ: \(cwd)")
        }
        return real
    }

    /// Giải đường dẫn mục tiêu bên trong `cwd`, kiểm tra cả liên kết tượng trưng (symlink) và chặn thoát ra ngoài `cwd`.
    public static func resolveInWorkspace(cwd: String, inputPath: String, mustExist: Bool = true) throws -> String {
        let trimmed = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PVTAError("Đường dẫn tệp không được để trống.")
        }
        let realCwd = try canonicalCwd(cwd)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: String
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded).standardizedFileURL.path
        } else {
            candidate = URL(fileURLWithPath: realCwd).appendingPathComponent(expanded).standardizedFileURL.path
        }

        // Kiểm tra tồn tại trên đĩa (theo stat giải symlink).
        var st = stat()
        let exists = stat(candidate, &st) == 0
        if mustExist && !exists {
            var lst = stat()
            if lstat(candidate, &lst) == 0 && (lst.st_mode & S_IFMT) == S_IFLNK {
                throw PVTAError("Liên kết tượng trưng trỏ tới tệp không tồn tại hoặc nằm ngoài thư mục làm việc: \(trimmed)")
            }
            throw PVTAError("Không tìm thấy tệp trong thư mục làm việc: \(trimmed)")
        }

        let realTarget: String
        if exists {
            guard let resolved = PathGuard.canonical(candidate) else {
                throw PVTAError("Không thể xác thực đường dẫn: \(trimmed)")
            }
            realTarget = resolved
        } else {
            // Với đường dẫn chưa tồn tại, giải symlink trên thư mục cha gần nhất đang tồn tại.
            let (resolved, problem) = PathGuard.resolve(candidate)
            guard let path = resolved else {
                throw PVTAError(problem ?? "Đường dẫn nằm ngoài thư mục làm việc: \(trimmed)")
            }
            realTarget = path
        }

        guard isInsideWorkspace(realCwd: realCwd, realTarget: realTarget) else {
            throw PVTAError("Đường dẫn nằm ngoài thư mục làm việc: \(trimmed)")
        }
        return realTarget
    }

    public static func isInsideWorkspace(realCwd: String, realTarget: String) -> Bool {
        if realTarget == realCwd { return true }
        let prefix = realCwd == "/" ? "/" : realCwd + "/"
        return realTarget.hasPrefix(prefix)
    }

    /// Đọc tệp mã nguồn trong thư mục làm việc và đánh số dòng từ 1.
    public static func readCodeFile(cwd: String, inputPath: String) throws -> (path: String, numbered: String) {
        let full = try resolveInWorkspace(cwd: cwd, inputPath: inputPath, mustExist: true)
        var st = stat()
        guard stat(full, &st) == 0 else {
            throw PVTAError("Không tìm thấy tệp: \(inputPath)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw PVTAError("Đường dẫn không phải là tệp văn bản: \(inputPath)")
        }
        guard Int(st.st_size) <= maxCodeFileBytes else {
            throw PVTAError("Tệp quá lớn để in trong terminal (> 512 KB): \(inputPath)")
        }
        guard let data = FileManager.default.contents(atPath: full),
              let content = String(data: data, encoding: .utf8) else {
            throw PVTAError("Tệp không phải văn bản UTF-8 hợp lệ: \(inputPath)")
        }
        let lines = content.components(separatedBy: "\n")
        let numbered = lines.enumerated().map { idx, line in
            let num = String(idx + 1).leftPadding(toLength: 4, withPad: " ")
            return "\(num) | \(line)"
        }.joined(separator: "\n")
        return (full, numbered)
    }
}

extension String {
    func leftPadding(toLength length: Int, withPad pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: pad, count: length - count) + self
    }
}
