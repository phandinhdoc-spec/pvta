import Foundation

public enum ActionKind: String, Codable, Sendable {
    /// Tạo hoặc ghi đè tệp, sửa một phần tệp.
    case write
    /// Xóa (chuyển vào Thùng rác).
    case delete
    /// Di chuyển hoặc đổi tên.
    case move
    /// Chạy lệnh hoặc mã.
    case run
    /// Truy cập mạng hoặc gửi dữ liệu ra ngoài.
    case network
}

/// Công cụ khai báo trước tác động của một lời gọi để người dùng thấy rõ trước khi duyệt.
public struct ActionPlan: Sendable {
    public struct Warning: Sendable, Equatable {
        /// "high" (chặn mặc định, phải chọn "Vẫn làm"), "medium", "low".
        public var level: String
        public var text: String
        public init(level: String, text: String) {
            self.level = level
            self.text = text
        }
    }

    public var kind: ActionKind
    public var summary: String
    /// Nội dung sẽ ghi hoặc phần khác biệt (hiển thị cho người dùng, đã rút gọn).
    public var preview: String
    /// Đường dẫn tuyệt đối sẽ bị tác động.
    public var paths: [String]
    /// Cảnh báo công cụ tự phát hiện (ví dụ kết quả quét mã); hiện trên thẻ duyệt, mức cao thì thao tác bị coi là nguy hiểm.
    public var warnings: [Warning]

    public init(kind: ActionKind, summary: String, preview: String = "", paths: [String] = [], warnings: [Warning] = []) {
        self.kind = kind
        self.summary = summary
        self.preview = preview
        self.paths = paths
        self.warnings = warnings
    }
}

public struct ActionProposal: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, approved, declined, expired }
    public var id: String
    public var chatId: String
    public var tool: String
    public var kind: ActionKind
    public var summary: String
    public var preview: String
    public var paths: [String]
    /// "normal" hoặc "high" (thao tác nguy hiểm: phải xác nhận thêm).
    public var risk: String
    public var riskReasons: [String]
    public var state: State
    public var createdAt: Date
    public var decidedAt: Date?
    public var note: String?
}

enum ActionOutcome: Equatable {
    case approved
    case declined
    case timedOut
    case cancelled
}

/// Hàng đợi đề xuất chờ duyệt. Công cụ ghi/chạy lệnh dừng ở đây cho tới khi người dùng quyết định; không ai tự duyệt thay.
public actor ActionQueue {
    private struct Waiter {
        var continuation: CheckedContinuation<ActionOutcome, Never>
        var timeout: Task<Void, Never>
    }

    private var proposals: [String: ActionProposal] = [:]
    private var order: [String] = []
    private var waiters: [String: Waiter] = [:]
    private let changed: @Sendable ([ActionProposal]) -> Void
    private let keepHistory = 50

    public init(changed: @escaping @Sendable ([ActionProposal]) -> Void = { _ in }) { self.changed = changed }

    public func list(chatId: String? = nil) -> [ActionProposal] {
        order.compactMap { proposals[$0] }.filter { chatId == nil || $0.chatId == chatId }
    }

    var pending: [ActionProposal] { list().filter { $0.state == .pending } }

    private func publish() { changed(pending) }

    /// Đưa đề xuất vào hàng đợi và chờ quyết định. Hủy Task hoặc hết `timeout` thì coi như không được duyệt.
    func request(_ p: ActionProposal, timeout: Duration) async -> ActionOutcome {
        proposals[p.id] = p
        order.append(p.id)
        publish()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ActionOutcome, Never>) in
                let id = p.id
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.resolve(id, .timedOut)
                }
                waiters[id] = Waiter(continuation: cont, timeout: timer)
                if Task.isCancelled { resolve(id, .cancelled) }
            }
        } onCancel: {
            Task { await self.resolve(p.id, .cancelled) }
        }
    }

    private func resolve(_ id: String, _ outcome: ActionOutcome) {
        guard var p = proposals[id], p.state == .pending, let w = waiters.removeValue(forKey: id) else { return }
        w.timeout.cancel()
        p.decidedAt = Date()
        switch outcome {
        case .approved: p.state = .approved
        case .declined: p.state = .declined
        case .timedOut: p.state = .expired; p.note = "Hết thời gian chờ bạn duyệt."
        case .cancelled: p.state = .expired; p.note = "Lượt làm việc đã bị dừng."
        }
        proposals[id] = p
        trim()
        publish()
        w.continuation.resume(returning: outcome)
    }

    private func trim() {
        let done = order.filter { proposals[$0]?.state != .pending }
        if done.count > keepHistory {
            for id in done.prefix(done.count - keepHistory) { proposals[id] = nil }
            order.removeAll { proposals[$0] == nil }
        }
    }

    /// Duyệt. Thao tác nguy hiểm phải có `force` (người dùng chọn "Vẫn làm").
    public func approve(id: String, force: Bool = false) throws {
        guard let p = proposals[id], p.state == .pending else { throw PVTAError("Đề xuất này đã được xử lý hoặc không còn chờ duyệt.") }
        if p.risk == "high", !force {
            throw PVTAError("Đây là thao tác nguy hiểm (\(p.riskReasons.joined(separator: "; "))). Hãy xem kỹ rồi chọn “Vẫn làm” nếu bạn chắc chắn.")
        }
        resolve(id, .approved)
    }

    public func decline(id: String) throws {
        guard let p = proposals[id], p.state == .pending else { throw PVTAError("Đề xuất này đã được xử lý hoặc không còn chờ duyệt.") }
        _ = p
        resolve(id, .declined)
    }

    /// Hủy mọi đề xuất đang chờ của một hội thoại (khi người dùng bấm Dừng).
    public func cancel(chatId: String) {
        for p in pending where p.chatId == chatId { resolve(p.id, .cancelled) }
    }
}
