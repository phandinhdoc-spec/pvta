import Foundation

/// Gửi một lượt tới công cụ dòng lệnh AI đã đăng nhập và nhận luồng chữ.
enum CLIRunner {
    static let timeout: Duration = .seconds(20 * 60)

    static func classify(_ id: CLIBackendID, _ text: String) -> ProviderError {
        let t = text.lowercased()
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if has(#"rate.?limit|usage limit|limit reached|quota|too many requests|\b429\b|out of (credits|usage)"#) {
            return ProviderError(.rateLimited, "\(id.name) báo đã hết hạn mức dùng hoặc bị giới hạn lượt. Hãy chờ hạn mức làm mới hoặc chọn nhà cung cấp khác.")
        }
        if has(#"not logged in|please (run )?.*log ?in|authenticat|unauthori[sz]ed|\b401\b|invalid api key|credentials|sign in"#) {
            return ProviderError(.auth, "\(id.name) chưa đăng nhập hoặc phiên đăng nhập đã hết hạn. Hãy đăng nhập lại trong Cài đặt → Công cụ AI.")
        }
        if has(#"unknown (option|flag|argument)|unrecognized (option|argument|flag)|invalid option|unexpected argument|flag provided but not defined"#) {
            return ProviderError(.other, "Phiên bản \(id.name) trên máy không khớp với PVTA (công cụ không nhận một tùy chọn). Hãy cập nhật \(id.name) lên bản mới nhất rồi thử lại.")
        }
        if has(#"(session|conversation)[^\n]{0,60}(not found|expired|invalid|no such|does not exist|could not be)|no (session|conversation) found"#) {
            return ProviderError(.other, "Phiên trò chuyện cũ của \(id.name) không còn. Hãy bắt đầu hội thoại mới.")
        }
        if has(#"issue with the selected model|available models|(unknown|invalid|unsupported|unavailable)[^\n]{0,20}model|model[^\n]{0,60}(not found|unavailable|not supported|does not exist|invalid)"#) {
            return ProviderError(.model, "\(id.name) không dùng được model đã chọn. Hãy chọn model khác.")
        }
        return ProviderError(.other, "\(id.name) báo lỗi khi trả lời. Hãy thử lại; nếu lỗi lặp lại, hãy xuất nhật ký để báo lỗi.")
    }

    static func stream(_ id: CLIBackendID, model: String, _ request: ChatRequest, in env: CLIEnvironment) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let bin = env.find(id) else {
                        throw ProviderError(.notInstalled,
                            "Máy chưa có \(id.name). " + ToolHealth.steps(id, state: .notInstalled).joined(separator: " "))
                    }
                    try env.prepareWorkDirectory()
                    // Ảnh đi kèm tin cuối: chỉ ghi ra thư mục tạm riêng của lượt này và xóa ngay sau khi xong.
                    let images = request.messages.last?.images ?? []
                    if !images.isEmpty, !id.acceptsImages {
                        throw ProviderError(.other, "\(id.name) chưa nhận ảnh trong PVTA. Hãy chọn Tự động, OpenAI Codex, OpenCode hoặc một model API có đọc ảnh.")
                    }
                    let scratch = env.workDirectory.appendingPathComponent(".anh-\(UUID().uuidString.prefix(8))", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    var imagePaths: [String] = []
                    if !images.isEmpty {
                        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        for (i, img) in images.enumerated() {
                            let file = scratch.appendingPathComponent("\(i).\(ImageKind.extensionFor(mime: img.mime) ?? "png")")
                            try img.data.write(to: file, options: .withoutOverwriting)
                            imagePaths.append(file.path)
                        }
                    }
                    let inv = id.invocation(model: model, system: request.system,
                                            prompt: cliPrompt(request.messages, resume: request.conversationId != nil),
                                            conversationId: request.conversationId, images: imagePaths)
                    let state = ParseBox()
                    let exit = try await CLIProcess.run(
                        binary: bin, args: inv.args, environment: env.childEnvironment(for: id), directory: env.workDirectory,
                        stdin: .text(inv.stdin), timeout: timeout) { isError, chunk in
                        if isError { return }
                        for event in state.feed(id, chunk) { continuation.yield(event) }
                    }
                    for event in state.flush(id) { continuation.yield(event) }
                    try Task.checkCancellation()
                    if exit.timedOut {
                        throw ProviderError(.other, "\(id.name) trả lời quá lâu (hơn 20 phút) nên PVTA đã dừng lượt này.")
                    }
                    let snapshot = state.snapshot
                    if snapshot.error != nil || exit.code != 0 {
                        throw classify(id, [snapshot.error ?? "", exit.stderrTail].joined(separator: "\n"))
                    }
                    if snapshot.text.isEmpty {
                        guard let fallback = snapshot.resultText, !fallback.isEmpty else {
                            throw ProviderError(.incomplete, "\(id.name) kết thúc mà không trả về câu trả lời. Hãy thử lại.")
                        }
                        continuation.yield(.text(fallback))
                    }
                    if let session = snapshot.conversationId { continuation.yield(.session(session)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Giữ trạng thái phân tích giữa các đoạn dữ liệu đến từ luồng đọc.
final class ParseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = CLIProcess.LineSplitter()
    private var state = CLIParseState()

    func feed(_ id: CLIBackendID, _ chunk: Data) -> [AIEvent] {
        lock.lock(); defer { lock.unlock() }
        return splitter.feed(chunk).compactMap { line in
            line.isEmpty ? nil : id.parse(line, &state).map { AIEvent.text($0) }
        }
    }

    func flush(_ id: CLIBackendID) -> [AIEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let rest = splitter.flush(), !rest.isEmpty, let t = id.parse(rest, &state) else { return [] }
        return [.text(t)]
    }

    var snapshot: CLIParseState { lock.lock(); defer { lock.unlock() }; return state }
}
