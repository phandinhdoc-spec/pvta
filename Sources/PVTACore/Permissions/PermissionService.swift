import Foundation

public struct PermissionView: Codable, Sendable, Equatable {
    public var level: PermissionLevel
    public var label: String
    public var description: String
    public var grants: [Grant]
    public var protectedRoots: [String]
}

public extension PermissionLevel {
    var label: String {
        switch self {
        case .readOnly: "Chỉ đọc"
        case .askApproval: "Hỏi duyệt"
        case .autoEdit: "Tự sửa"
        }
    }

    var summary: String {
        switch self {
        case .readOnly:
            "Chỉ đọc: PVTA chỉ đọc tệp trong thư mục đã cấp, không ghi, không chạy lệnh, không truy cập mạng thay bạn."
        case .askApproval:
            "Hỏi duyệt (mặc định): mọi thao tác ghi, xóa, chạy lệnh hoặc truy cập mạng đều chờ bạn duyệt từng lần."
        case .autoEdit:
            "Tự sửa: PVTA tự ghi, sửa, di chuyển tệp trong thư mục đã cấp quyền ghi mà không hỏi từng lần. "
                + "Đây KHÔNG phải môi trường cô lập: lệnh hoặc mã bạn duyệt chạy với quyền của tài khoản bạn trên máy này. "
                + "Xóa nhiều tệp, ghi ngoài thư mục đã cấp, chạy lệnh và truy cập mạng vẫn cần bạn duyệt hoặc bị chặn."
        }
    }
}

/// Mức quyền, thư mục đã cấp và quyết định cho từng lời gọi công cụ.
public final class PermissionService: Sendable {
    static let bulkDeleteLimit = 5
    static let manyPathsLimit = 20
    static let previewLimit = 4_000

    let store: DataStore
    let config: ConfigStore
    public let queue: ActionQueue
    let dataHome: URL
    let home: URL
    let timeout: Duration
    private let publish: @Sendable (String, JSONValue) -> Void

    public init(store: DataStore, config: ConfigStore, dataHome: URL, queue: ActionQueue,
                home: URL = FileManager.default.homeDirectoryForCurrentUser, timeout: Duration = .seconds(300),
                publish: @escaping @Sendable (String, JSONValue) -> Void = { _, _ in }) {
        self.store = store
        self.config = config
        self.queue = queue
        self.dataHome = dataHome
        self.home = home
        self.timeout = timeout
        self.publish = publish
    }

    // MARK: Mức quyền

    public func level() -> PermissionLevel { (try? config.load().permission) ?? .askApproval }

    public func view() async throws -> PermissionView {
        let l = level()
        return PermissionView(level: l, label: l.label, description: l.summary, grants: try await store.grants(),
                              protectedRoots: PathGuard.protectedRoots(dataHome: dataHome, home: home))
    }

    /// Chỉ người dùng đổi được mức quyền (qua giao diện hoặc lệnh), không công cụ hay cờ nào tự nâng quyền.
    /// Chuyển sang "Tự sửa" phải xác nhận đã đọc thông báo.
    public func setLevel(_ new: PermissionLevel, acknowledge: Bool) async throws -> PermissionView {
        if new == .autoEdit, !acknowledge {
            throw PVTAError("Chuyển sang Tự sửa cần bạn xác nhận. " + new.summary)
        }
        try config.update { $0.permission = new }
        let v = try await view()
        publish("permission", try JSONValue(encoding: v))
        return v
    }

    // MARK: Thư mục được cấp

    public func addGrant(path: String, write: Bool) async throws -> Grant {
        guard path.hasPrefix("/") else { throw PVTAError("Cần đường dẫn thư mục tuyệt đối.") }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw PVTAError("“\(path)” không phải thư mục thật (không nhận liên kết tượng trưng hay tệp).")
        }
        guard let real = PathGuard.canonical(path) else { throw PVTAError("Không đọc được thư mục “\(path)”.") }
        let homePath = PathGuard.canonical(home.path) ?? home.path
        if real == "/" || real == "/Users" || real == homePath {
            throw PVTAError("Không thể cấp cả ổ đĩa hay cả thư mục cá nhân. Hãy chọn một thư mục cụ thể (ví dụ Documents/Giáo án).")
        }
        let blocked = PathGuard.protectedRoots(dataHome: dataHome, home: home)
        if let hit = blocked.first(where: { real == $0 || real.hasPrefix($0 + "/") || $0.hasPrefix(real + "/") }) {
            throw PVTAError("Thư mục này chứa hoặc thuộc vùng được bảo vệ (\(hit)) nên không thể cấp cho PVTA.")
        }
        let g = Grant(path: real, write: write, addedAt: Date())
        try await store.putGrant(g)
        publish("permission", try JSONValue(encoding: try await view()))
        return g
    }

    public func removeGrant(path: String) async throws {
        let key = PathGuard.canonical(path) ?? path
        guard try await store.deleteGrant(path: key) else { throw PVTAError("Thư mục này chưa được cấp.") }
        publish("permission", try JSONValue(encoding: try await view()))
    }

    /// Chế độ Chỉ đọc cấm mọi thay đổi, kể cả khi người dùng tự bấm lưu hay hoàn tác.
    public func requireWritable() async throws {
        if level() == .readOnly { throw PVTAError("Chế độ Chỉ đọc: PVTA không ghi hay sửa tệp. Hãy đổi mức quyền nếu bạn muốn lưu thay đổi.") }
    }

    /// Kiểm một đường dẫn cho công cụ tệp (nhiệm vụ 12 dùng ngay trước khi đọc/ghi).
    func check(_ path: String, _ access: PathAccess) async -> PathGuard.Verdict {
        PathGuard(grants: (try? await store.grants()) ?? [], protectedRoots: PathGuard.protectedRoots(dataHome: dataHome, home: home)).check(path, access)
    }

    /// Đường dẫn chuẩn nếu công cụ được phép đọc/ghi ở đó, ngược lại ném lỗi tiếng Việt.
    public func authorize(path: String, write: Bool) async throws -> String {
        let v = await check(path, write ? .write : .read)
        if let why = v.denied { throw PVTAError(why) }
        return v.path ?? path
    }
}

// MARK: Quyết định cho công cụ

public struct PermissionPolicy: ToolPolicy {
    let service: PermissionService

    public init(_ service: PermissionService) { self.service = service }

    private static func redactedPreview(_ s: String) -> String {
        let t = Redactor.clean(s)
        return t.count > PermissionService.previewLimit ? String(t.prefix(PermissionService.previewLimit)) + "\n[… đã rút gọn …]" : t
    }

    public func decide(_ tool: ToolSpec, args: JSONValue, chatId: String) async -> ToolDecision {
        if tool.access == .read { return .allow }
        let s = service
        let level = s.level()
        if level == .readOnly {
            return .deny("Chế độ Chỉ đọc: PVTA không được phép ghi, xóa, chạy lệnh hay truy cập mạng. Hãy nhờ người dùng đổi mức quyền nếu thật sự cần.")
        }
        // Tác động của lời gọi: do công cụ khai báo. Không khai báo thì không biết gì về nó nên luôn phải hỏi.
        var plan: ActionPlan?
        if let planner = tool.plan {
            do { plan = try await planner(args) } catch {
                return .deny("PVTA không hiểu thao tác này nên không chạy: " + UserMessage.text(for: error))
            }
        }
        var reasons: [String] = []
        let label = ["high": "Cao", "medium": "Trung bình", "low": "Thấp"]
        var danger = false
        for w in plan?.warnings ?? [] {
            reasons.append("[\(label[w.level] ?? "Trung bình")] \(w.text)")
            if w.level == "high" { danger = true }
        }
        let fileKinds: [ActionKind] = [.write, .delete, .move]
        if let plan, fileKinds.contains(plan.kind) {
            guard !plan.paths.isEmpty else { return .deny("Thao tác ghi không nêu tệp nào bị tác động nên PVTA không chạy.") }
            for p in plan.paths {
                let v = await s.check(p, .write)
                if let why = v.denied { return .deny("Bị chặn: " + why) }       // ngoài phạm vi hoặc vùng bảo vệ: không có đường duyệt
            }
            if plan.kind == .delete {
                var dir = false
                for p in plan.paths { var st = stat(); if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { dir = true } }
                if dir { reasons.append("xóa cả thư mục"); danger = true }
                if plan.paths.count > PermissionService.bulkDeleteLimit { reasons.append("xóa \(plan.paths.count) mục cùng lúc"); danger = true }
            }
            if plan.paths.count > PermissionService.manyPathsLimit && plan.kind != .delete { reasons.append("ảnh hưởng \(plan.paths.count) tệp"); danger = true }
        }
        let auto = level == .autoEdit && reasons.isEmpty && plan.map { fileKinds.contains($0.kind) } == true
        if auto {
            _ = try? await s.store.startActivity(kind: "action.auto.\(plan!.kind.rawValue)", chatId: chatId)
            return .allow
        }

        let id = UUID().uuidString
        let proposal = ActionProposal(
            id: id, chatId: chatId, tool: tool.name, kind: plan?.kind ?? (tool.access == .network ? .network : tool.access == .run ? .run : .write),
            summary: plan?.summary ?? "Công cụ “\(tool.name)” muốn thực hiện một thao tác chưa nêu rõ tác động.",
            preview: Self.redactedPreview(plan?.preview ?? Self.describe(args)),
            paths: plan?.paths ?? [], risk: danger ? "high" : "normal", riskReasons: reasons, state: .pending, createdAt: Date())
        let record = try? await s.store.startActivity(kind: "action.\(proposal.kind.rawValue)", chatId: chatId)
        let outcome = await s.queue.request(proposal, timeout: s.timeout)
        switch outcome {
        case .approved:
            // Kiểm lại ngay trước khi chạy: thư mục có thể đã bị đổi (liên kết tượng trưng, gỡ cấp quyền) trong lúc chờ.
            if s.level() != .readOnly, let plan, fileKinds.contains(plan.kind) {
                for p in plan.paths {
                    if let why = await s.check(p, .write).denied { return .deny("Bị chặn khi kiểm lại trước lúc chạy: " + why) }
                }
            }
            if let record { try? await s.store.finishActivity(id: record, state: .done, detail: "Đã duyệt: " + proposal.summary) }
            return .allow
        case .declined:
            if let record { try? await s.store.finishActivity(id: record, state: .interrupted, detail: "Người dùng từ chối: " + proposal.summary) }
            return .deny("Người dùng đã từ chối thay đổi này.")
        case .timedOut:
            if let record { try? await s.store.finishActivity(id: record, state: .interrupted, detail: "Hết thời gian chờ duyệt: " + proposal.summary) }
            return .deny("Hết thời gian chờ người dùng đồng ý, đã bỏ qua thay đổi này.")
        case .cancelled:
            if let record { try? await s.store.finishActivity(id: record, state: .interrupted, detail: "Bị dừng khi chờ duyệt: " + proposal.summary) }
            return .deny("Đã dừng yêu cầu.")
        }
    }

    /// Tham số lời gọi dạng chữ (bỏ mã hội thoại do hệ thống gán) để người dùng xem khi công cụ không tự mô tả.
    private static func describe(_ args: JSONValue) -> String {
        guard case .object(var o) = args else { return "" }
        o["chatId"] = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? enc.encode(JSONValue.object(o))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
