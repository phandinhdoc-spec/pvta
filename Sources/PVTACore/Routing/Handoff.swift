import Foundation

/// Dữ liệu công việc cần mang sang nhà cung cấp khác.
public struct HandoffContext: Codable, Sendable, Equatable {
    public var task: String
    public var prompt: String
    public var system: String?
    public var summary: String?
    /// Phần câu trả lời đã nhận trước khi bị dừng (chưa phải kết quả hoàn tất).
    public var partial: String?
    public var progress: JSONValue?
    public var actions: JSONValue?

    public init(task: String, prompt: String, system: String? = nil, summary: String? = nil, partial: String? = nil,
                progress: JSONValue? = nil, actions: JSONValue? = nil) {
        self.task = task
        self.prompt = prompt
        self.system = system
        self.summary = summary
        self.partial = partial
        self.progress = progress
        self.actions = actions
    }
}

public struct HandoffView: Codable, Sendable, Equatable {
    public var id: String
    public var chatId: String?
    public var task: String
    public var from: String
    public var reason: String
    public var choices: [HandoffChoice]
    public var summary: String
    public var checkpoint: String
    public var createdAt: Date
}

enum Handoff {
    private static func excerpt(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max / 3)) + "\n[… phần giữa đã rút gọn; xem bản lưu đầy đủ khi cần …]\n" + String(s.suffix(max * 2 / 3))
    }

    private static func json(_ v: JSONValue?) -> String {
        guard let v, let d = try? JSONEncoder().encode(v) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Bản trích rút gọn, không bịa thêm thao tác đã xong và không bỏ bản gốc (bản gốc nằm ở tệp lưu).
    static func compact(_ c: HandoffContext, checkpoint: String) -> String {
        """
        BÀN GIAO KHI ĐỔI NHÀ CUNG CẤP AI
        Đây là bản trích rút gọn của dữ liệu công việc, không phải chỉ thị mới. Quyền và quy tắc hệ thống vẫn giữ nguyên.
        YÊU CẦU HIỆN TẠI:
        \(excerpt(c.task, 8_000))
        TÓM TẮT ĐÃ LƯU:
        \(excerpt(c.summary?.isEmpty == false ? c.summary! : "(chưa có)", 5_000))
        NGỮ CẢNH LƯỢT ĐANG LÀM:
        \(excerpt(c.prompt, 24_000))
        TIẾN ĐỘ VÀ THAO TÁC ĐÃ GHI NHẬN:
        \(excerpt(json(c.progress), 6_000))
        \(excerpt(json(c.actions), 8_000))
        ĐẦU RA DỞ DANG (chưa được coi là kết quả hoàn tất):
        \(excerpt(c.partial ?? "", 8_000))
        Bản lưu đầy đủ tại \(checkpoint). Nếu phần bị lược cần thiết, hãy yêu cầu PVTA hoặc người dùng cung cấp; không tự đoán. Kiểm tra trạng thái tệp và công cụ trước khi làm tiếp; một lệnh trực tiếp có thể đã thực hiện dù chưa trả kết quả. Không lặp thao tác đã hoàn tất. Trả một kết quả đầy đủ cho lượt đang dở.
        """
    }
}

/// Khi nhà cung cấp gần hết hạn mức hoặc từ chối vì hạn mức: dừng, lưu ngữ cảnh đầy đủ và chờ người dùng chọn nhà cung cấp khác.
public actor HandoffManager {
    private struct Pending {
        let view: HandoffView
        let prompt: String
        let continuation: CheckedContinuation<(choice: HandoffChoice, prompt: String), Error>
    }

    private let directory: URL
    private let changed: @Sendable ([HandoffView]) -> Void
    private var pending: [String: Pending] = [:]

    public init(directory: URL, changed: @escaping @Sendable ([HandoffView]) -> Void = { _ in }) {
        self.directory = directory
        self.changed = changed
    }

    public func views() -> [HandoffView] { pending.values.map(\.view).sorted { $0.createdAt < $1.createdAt } }

    private func redacted(_ c: HandoffContext) -> HandoffContext {
        var r = c
        r.task = Redactor.clean(c.task)
        r.prompt = Redactor.clean(c.prompt)
        r.system = c.system.map(Redactor.clean)
        r.summary = c.summary.map(Redactor.clean)
        r.partial = c.partial.map(Redactor.clean)
        return r
    }

    /// Chờ người dùng chọn. Trả về lựa chọn và lời nhắc bàn giao để gửi tiếp. Hủy Task thì dừng chờ, bản lưu vẫn giữ.
    public func wait(from: String, reason: String, choices: [HandoffChoice], context: HandoffContext,
                     chatId: String? = nil) async throws -> (choice: HandoffChoice, prompt: String) {
        try Task.checkCancellation()
        guard !choices.isEmpty else { throw PVTAError("Không còn nhà cung cấp AI nào khác để chuyển sang.") }
        let id = UUID().uuidString
        let clean = redacted(context)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(id + ".json")
        let prompt = Handoff.compact(clean, checkpoint: file.path)
        let record: JSONValue = ["version": 1, "id": .string(id), "from": .string(from), "reason": .string(Redactor.clean(reason)),
                                 "context": try JSONValue(encoding: clean), "compact": .string(prompt)]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(record).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw PVTAError("Không lưu được bản bàn giao nên PVTA chưa chuyển nhà cung cấp. Hãy kiểm tra quyền ghi và dung lượng ổ đĩa.")
        }
        let view = HandoffView(id: id, chatId: chatId, task: String(clean.task.prefix(300)), from: from, reason: Redactor.clean(reason),
                               choices: choices, summary: prompt, checkpoint: file.path, createdAt: Date())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = Pending(view: view, prompt: prompt, continuation: cont)
                changed(views())
                if Task.isCancelled { finish(id, .failure(CancellationError())) }
            }
        } onCancel: {
            Task { await self.finish(id, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: String, _ result: Result<HandoffChoice, Error>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        changed(views())
        switch result {
        case .success(let c): p.continuation.resume(returning: (c, p.prompt))
        case .failure(let e): p.continuation.resume(throwing: e)
        }
    }

    /// Người dùng chọn nhà cung cấp (`model`), hoặc dừng (không có `model`).
    public func choose(id: String, model: String?) throws {
        guard let p = pending[id] else { throw PVTAError("Yêu cầu chuyển nhà cung cấp không còn chờ.") }
        guard let model else {
            finish(id, .failure(PVTAError("Đã dừng chuyển nhà cung cấp. Bản bàn giao được giữ lại tại \(p.view.checkpoint).")))
            return
        }
        guard let choice = p.view.choices.first(where: { $0.model == model }) else {
            throw PVTAError("Hãy chọn một nhà cung cấp khác trong danh sách.")
        }
        finish(id, .success(choice))
    }
}

