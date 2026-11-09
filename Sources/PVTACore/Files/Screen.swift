import CoreGraphics
import Foundation

public enum ScreenMode: String, Codable, Sendable {
    /// Cả màn hình chính, chụp ngay.
    case screen
    /// Chọn một cửa sổ.
    case window
    /// Kéo chọn một vùng.
    case selection
}

/// Chụp màn hình qua hệ điều hành. Bản thật dùng `screencapture`; kiểm thử dùng bản giả.
public protocol ScreenCapturing: Sendable {
    func hasPermission() -> Bool
    func requestPermission()
    /// Chụp vào `url`. Trả về false nếu người dùng hủy.
    func capture(mode: ScreenMode, to url: URL) async throws -> Bool
}

public struct SystemScreenCapturer: ScreenCapturing {
    public init() {}

    public func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    public func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public func capture(mode: ScreenMode, to url: URL) async throws -> Bool {
        let args: [String]
        switch mode {
        case .screen: args = ["-x", "-m", url.path]
        case .window: args = ["-i", "-w", url.path]
        case .selection: args = ["-i", url.path]
        }
        _ = try await CLIProcess.run(binary: "/usr/sbin/screencapture", args: args, environment: [:], directory: url.deletingLastPathComponent(),
                                     stdin: .none, timeout: .seconds(120)) { _, _ in }
        return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}

public struct CaptureResult: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var bytes: Int
    public var cancelled: Bool
}

public struct ScreenshotFile: Codable, Sendable, Equatable {
    public var path: String
    public var name: String
    public var modified: Date
}

/// Chụp màn hình, nhận ảnh dán, chọn nơi nhận ảnh (hội thoại hoặc thư mục) và tìm ảnh chụp mới.
public final class ScreenService: Sendable {
    let capturer: ScreenCapturing
    let attachments: AttachmentService
    let directory: URL
    let home: URL

    public init(capturer: ScreenCapturing, attachments: AttachmentService, directory: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.capturer = capturer
        self.attachments = attachments
        self.directory = directory
        self.home = home
    }

    static let denied = """
        PVTA chưa được cấp quyền Ghi màn hình nên không chụp được (ảnh sẽ trống hoặc thiếu cửa sổ). \
        Hãy mở Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, bật cho PVTA (nếu chạy từ dòng lệnh thì bật cho ứng dụng Terminal đang dùng), rồi mở lại PVTA và thử lại. \
        Bạn vẫn có thể tự chụp bằng phím tắt hệ thống (⇧⌘4) rồi đính kèm tệp ảnh hoặc dán vào hội thoại.
        """

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func newFile(_ prefix: String, _ ext: String) -> URL {
        directory.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased()).\(ext)")
    }

    private func result(_ url: URL, cancelled: Bool = false) -> CaptureResult {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CaptureResult(id: url.deletingPathExtension().lastPathComponent, name: url.lastPathComponent, bytes: size, cancelled: cancelled)
    }

    /// Chụp màn hình. Chưa có quyền Ghi màn hình thì báo rõ cách cấp, không chụp ra ảnh trống.
    public func capture(mode: ScreenMode, requestPermission: Bool = false) async throws -> CaptureResult {
        guard capturer.hasPermission() else {
            if requestPermission { capturer.requestPermission() }
            throw PVTAError(Self.denied)
        }
        try prepare()
        let url = newFile("chup-man-hinh", "png")
        guard try await capturer.capture(mode: mode, to: url), FileManager.default.fileExists(atPath: url.path) else {
            return CaptureResult(id: "", name: "", bytes: 0, cancelled: true)
        }
        guard let data = try? Data(contentsOf: url), ImageKind.detect(data) != nil else {
            try? FileManager.default.removeItem(at: url)
            throw PVTAError("Không tạo được ảnh chụp màn hình hợp lệ. Hãy thử lại.")
        }
        return result(url)
    }

    /// Ảnh dán hoặc kéo thả (data URL) được lưu thành ảnh chụp.
    public func paste(dataURL: String) throws -> CaptureResult {
        guard let m = dataURL.range(of: #"^data:image/(png|jpe?g|webp|gif);base64,"#, options: .regularExpression),
              let data = Data(base64Encoded: String(dataURL[m.upperBound...])) else {
            throw PVTAError("Định dạng ảnh dán không hợp lệ (chỉ hỗ trợ PNG, JPEG, WebP, GIF).")
        }
        guard data.count >= 32, data.count <= 20 * 1024 * 1024 else { throw PVTAError("Kích thước ảnh không hợp lệ (tối đa 20 MB).") }
        guard let kind = ImageKind.detect(data) else { throw PVTAError("Nội dung không phải ảnh hợp lệ.") }
        try prepare()
        let url = newFile("anh-dan", kind.ext)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result(url)
    }

    private func file(_ id: String) throws -> URL {
        guard id.range(of: #"^[A-Za-z0-9-]{8,80}$"#, options: .regularExpression) != nil,
              let name = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.first(where: { $0.hasPrefix(id + ".") })
        else { throw PVTAError("Không tìm thấy ảnh chụp này. Có thể nó đã được dọn; hãy chụp lại.") }
        return directory.appendingPathComponent(name)
    }

    /// Chọn nơi nhận ảnh: đính kèm vào một hội thoại, hoặc lưu thành tệp vào một thư mục (không ghi đè tệp có sẵn).
    public func deliver(captureId: String, chatId: String? = nil, folder: String? = nil) async throws -> JSONValue {
        let src = try file(captureId)
        if let chatId {
            let a = try await attachments.addImageData(chatId: chatId, name: src.lastPathComponent, data: Data(contentsOf: src))
            return ["to": "chat", "attachmentId": .string(a.id), "name": .string(a.name)]
        }
        guard let folder else { throw PVTAError("Hãy chọn nơi nhận ảnh: một hội thoại hoặc một thư mục.") }
        guard folder.hasPrefix("/") else { throw PVTAError("Cần đường dẫn thư mục tuyệt đối.") }
        var st = stat()
        guard lstat(folder, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw PVTAError("Thư mục nhận ảnh không tồn tại hoặc không phải thư mục thật (không nhận liên kết tượng trưng).")
        }
        let dest = URL(fileURLWithPath: folder).appendingPathComponent(src.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw PVTAError("Đã có tệp “\(dest.lastPathComponent)” trong thư mục này; PVTA không ghi đè.") }
        do { try FileManager.default.copyItem(at: src, to: dest) } catch {
            throw PVTAError("Không lưu được ảnh vào thư mục đã chọn. Hãy kiểm tra quyền ghi.")
        }
        return ["to": "folder", "path": .string(dest.path)]
    }

    /// Tìm ảnh chụp màn hình mới (từ phím tắt hệ thống hoặc phần mềm chụp khác) kể từ `since`.
    /// Thư mục bị hệ điều hành chặn đọc được báo lại trong `denied` thay vì bỏ qua im lặng.
    public func scan(since: Date, seen: Set<String> = []) -> (files: [ScreenshotFile], denied: [String]) {
        var dirs: [URL] = []
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), loc.hasPrefix("/") || loc.hasPrefix("~") {
            dirs.append(URL(fileURLWithPath: (loc as NSString).expandingTildeInPath))
        }
        dirs += [home.appendingPathComponent("Desktop"), home.appendingPathComponent("Pictures/Screenshots"), directory]
        let looksShot = try! NSRegularExpression(pattern: #"screen\s*shot|screen\s*cap|screenshot|snip|capture|chup|chụp|ảnh\s*chụp\s*màn\s*hình|cleanshot|shottr|lightshot"#, options: .caseInsensitive)
        var found: [ScreenshotFile] = [], denied: [String] = [], visited = Set<String>()
        for dir in dirs where visited.insert(dir.path).inserted {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
                let code = (error as NSError).code
                if code == NSFileReadNoPermissionError || (error as NSError).domain == NSPOSIXErrorDomain, FileManager.default.fileExists(atPath: dir.path) { denied.append(dir.path) }
                continue
            }
            for raw in names where !raw.hasPrefix(".") {
                let n = raw.precomposedStringWithCanonicalMapping   // tên tệp có thể ở dạng tổ hợp khác nhau
                let url = dir.appendingPathComponent(raw)
                guard ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()),
                      looksShot.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil || dir == directory,
                      !seen.contains(url.path),
                      let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true, let m = v.contentModificationDate, m > since else { continue }
                found.append(ScreenshotFile(path: url.path, name: n, modified: m))
            }
        }
        return (found.sorted { $0.modified > $1.modified }.prefix(50).map { $0 }, denied)
    }
}
