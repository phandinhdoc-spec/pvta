import Foundation

public struct FilePreview: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var segments: [ExtractedSegment]
    /// Ảnh, âm thanh hoặc video dạng data URL để giao diện hiển thị.
    public var data: String?
    public var note: String?
}

/// Duyệt thư mục nguồn để chọn tệp (`$`) hoặc thư mục (`$$`), và xem nhanh tệp trong phạm vi đã cấp.
extension AttachmentService {
    private func folders(_ chatId: String) async throws -> [String] {
        try await store.attachments(chatId: chatId).filter { $0.kind == "folder" }.compactMap(\.path)
    }

    /// Liệt kê tệp và thư mục con (không theo liên kết tượng trưng, bỏ mục ẩn), có giới hạn độ sâu và số mục.
    static func walk(_ root: String) -> (files: [String], dirs: [String], truncated: Bool) {
        var files: [String] = [], dirs: [String] = []
        guard let it = FileManager.default.enumerator(atPath: root) else { return ([], [], false) }
        var count = 0
        while let rel = it.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            let type = it.fileAttributes?[.type] as? FileAttributeType
            if name.hasPrefix(".") || type == .typeSymbolicLink || rel.split(separator: "/").count > limits.treeDepth {
                it.skipDescendants()
                continue
            }
            if type == .typeDirectory { dirs.append(rel) } else if type == .typeRegular { files.append(rel) }
            count += 1
            if count >= limits.treeEntries { return (files, dirs, true) }
        }
        return (files, dirs, false)
    }

    public func sourceTree(chatId: String) async throws -> [JSONValue] {
        try await folders(chatId).map { root in
            let w = Self.walk(root)
            return ["root": .string(root), "files": .array(w.files.map { .string($0) }), "dirs": .array(w.dirs.map { .string($0) }), "truncated": .bool(w.truncated)]
        }
    }

    private static func rank(_ name: String, _ rel: String, _ words: [String]) -> Int? {
        if words.isEmpty { return 3 }
        let n = Fold.text(name), r = Fold.text(rel)
        guard words.allSatisfy({ r.contains($0) }) else { return nil }
        return n.hasPrefix(words[0]) ? 0 : n.contains(words[0]) ? 1 : 2
    }

    /// Gợi ý khi gõ `$` (kind = "file") hoặc `$$` (kind = "dir"). Tìm không phân biệt dấu. `folder` giới hạn trong một thư mục đã chọn.
    public func sourceSearch(chatId: String, kind: String, query: String, folder: String? = nil, limit: Int = 50) async throws -> [SourceHit] {
        let words = Fold.text(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let all = try await store.attachments(chatId: chatId)
        let attachedPaths = Set(all.compactMap(\.path).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var scored: [(Int, SourceHit)] = []
        let limitTo = folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        if kind == "file" {
            for a in all where a.kind != "folder" {
                if let f = limitTo, !(a.path ?? "").hasPrefix(f + "/") { continue }
                if let r = Self.rank(a.name, a.name, words) { scored.append((r, SourceHit(name: a.name, path: a.path ?? "", kind: "file", source: "attachment", root: nil, inContext: true))) }
            }
        }
        for root in try await folders(chatId) {
            if let f = limitTo, !(root == f || root.hasPrefix(f + "/") || f.hasPrefix(root + "/")) { continue }
            let w = Self.walk(root)
            for rel in kind == "file" ? w.files : w.dirs {
                let full = root + "/" + rel
                if let f = limitTo, !(full.hasPrefix(f + "/")) { continue }
                let name = (rel as NSString).lastPathComponent
                guard let r = Self.rank(name, rel, words) else { continue }
                let real = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
                scored.append((r + 1, SourceHit(name: name, path: full, kind: kind, source: "folder", root: root, inContext: kind == "file" && attachedPaths.contains(real))))
            }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name < $1.1.name }
        return Array(scored.prefix(max(1, min(200, limit))).map(\.1))
    }

    /// Phân loại đường dẫn tuyệt đối: thư mục hay tệp (bỏ qua liên kết tượng trưng và đường dẫn không tồn tại).
    public static func pathKinds(_ paths: [String]) -> (dirs: [String], files: [String]) {
        var dirs: [String] = [], files: [String] = []
        for p in paths.prefix(60) where p.hasPrefix("/") {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: dirs.append(p)
            case S_IFREG: files.append(p)
            default: break
            }
        }
        return (dirs, files)
    }

    // MARK: Xem nhanh

    static func dataURL(_ mime: String, _ data: Data) -> String { "data:\(mime);base64,\(data.base64EncodedString())" }

    /// Xem nhanh một tệp trong phạm vi đã cấp: vài đoạn đầu của chữ, hoặc chính ảnh.
    public func quickPreview(chatId: String, ref: String) async throws -> FilePreview {
        let (url, _) = try await resolve(chatId: chatId, ref: ref)
        let name = url.lastPathComponent
        if TextExtractor.imageExtensions.contains(url.pathExtension.lowercased()) {
            let data = try Data(contentsOf: url)
            guard let kind = ImageKind.detect(data) else { throw PVTAError("“\(name)” không phải ảnh hợp lệ.") }
            guard data.count <= 15 * 1024 * 1024 else { return FilePreview(name: name, kind: "image", segments: [], data: nil, note: "Ảnh lớn hơn 15 MB, hãy mở bằng ứng dụng xem ảnh.") }
            return FilePreview(name: name, kind: "image", segments: [], data: Self.dataURL(kind.mime, data), note: nil)
        }
        let ex = try TextExtractor.extract(url)
        let segs = ex.segments.isEmpty ? [ExtractedSegment(label: name, text: ex.text)] : ex.segments
        return FilePreview(name: name, kind: ex.kind, segments: segs.prefix(6).map { ExtractedSegment(label: $0.label, text: String($0.text.prefix(1600))) },
                           data: nil, note: segs.count > 6 ? "Chỉ hiện 6 phần đầu." : nil)
    }

    /// Ảnh được nhắc tên: trả về data URL để giao diện mở trong khung xem ảnh.
    public func previewRef(chatId: String, ref: String) async throws -> FilePreview {
        let (url, _) = try await resolve(chatId: chatId, ref: ref)
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp", "gif"].contains(ext) else { throw PVTAError("Chỉ xem trước được ảnh png, jpg, jpeg, webp hoặc gif.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 15 * 1024 * 1024 else { throw PVTAError("Ảnh lớn hơn 15 MB, hãy mở bằng ứng dụng xem ảnh.") }
        guard let kind = ImageKind.detect(data) else { throw PVTAError("“\(url.lastPathComponent)” không phải ảnh hợp lệ.") }
        return FilePreview(name: url.lastPathComponent, kind: "image", segments: [], data: Self.dataURL(kind.mime, data), note: nil)
    }

    public func mediaPreview(chatId: String, ref: String) async throws -> FilePreview {
        let (url, _) = try await resolve(chatId: chatId, ref: ref)
        let mime = ["mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "ogg": "audio/ogg", "aac": "audio/aac", "flac": "audio/flac",
                    "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime"][url.pathExtension.lowercased()]
        guard let mime else { throw PVTAError("Định dạng âm thanh/video chưa được hỗ trợ.") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 25 * 1024 * 1024 else { throw PVTAError("Tệp lớn hơn 25 MB, hãy mở bằng ứng dụng nghe/xem.") }
        return FilePreview(name: url.lastPathComponent, kind: mime.hasPrefix("audio") ? "audio" : "video", segments: [],
                           data: Self.dataURL(mime, try Data(contentsOf: url)), note: nil)
    }
}
