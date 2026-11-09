import Foundation

public struct ModelChoiceResult: Codable, Sendable, Equatable {
    /// Mã model đầy đủ để gọi, ví dụ `claude/sonnet` hoặc `anthropic/claude-sonnet-5-5`.
    public var model: String
    public var provider: String
    public var label: String
    public var kind: TaskKind
    /// Vì sao chọn (tiếng Việt, hiển thị cho người dùng).
    public var reason: String
}

public struct HandoffChoice: Codable, Sendable, Equatable {
    public var model: String
    public var provider: String
    public var label: String
}

/// Chọn model "Tự động": theo loại việc, chỉ trong các nguồn đang dùng được trên máy này,
/// bỏ qua nguồn đang bị từ chối vì hạn mức hoặc đã dùng từ 90%.
public actor ModelRouter {
    struct Candidate: Sendable {
        let key: String
        let label: String
        let models: [Tier: String]
    }

    /// Thứ tự ưu tiên: công cụ đã đăng nhập (dùng gói đăng ký) trước, API tính tiền theo lượt sau.
    static let order: [String] = ["agy", "claude", "codex", "opencode", "api:anthropic", "api:openai", "api:gemini",
                                  "api:commandcode", "api:ollama", "api:compatible"]

    private static func tiers(_ fast: String, _ standard: String, _ strong: String) -> [Tier: String] {
        [.fast: fast, .standard: standard, .strong: strong]
    }

    /// Model mỗi bậc của từng nguồn. `default` là để công cụ dùng model người dùng đã cấu hình sẵn.
    private static func table(_ key: String) -> [Tier: String]? {
        switch key {
        case "agy": tiers("gemini-3.8-flash-low", "gemini-4-argon-medium", "gemini-4-argon-high")
        case "claude": tiers("haiku", "sonnet", "opus")
        case "codex", "opencode": tiers("default", "default", "default")
        case "api:anthropic": tiers("claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5")
        case "api:openai": tiers("gpt-5.4-mini", "gpt-5.4-mini", "gpt-5.5")
        case "api:gemini": tiers("gemini-flash-latest", "gemini-flash-latest", "gemini-pro-latest")
        case "api:commandcode": tiers("deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash")
        default: nil
        }
    }

    private let ai: AIClient
    private let usage: UsageMonitor
    private let now: @Sendable () -> Date
    private var cached: (at: Date, items: [Candidate])?

    public init(ai: AIClient, usage: UsageMonitor, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ai = ai
        self.usage = usage
        self.now = now
    }

    public func invalidate() { cached = nil }

    /// Các nguồn dùng được ngay: công cụ đã cài và đăng nhập, API đã có khóa (hoặc không cần khóa) và có model.
    func available() async -> [Candidate] {
        if let c = cached, now().timeIntervalSince(c.at) < 60 { return c.items }
        let env = ai.cli
        let tools = await withTaskGroup(of: ToolStatus.self) { group in
            for id in CLIBackendID.allCases { group.addTask { await ToolHealth.check(id, in: env) } }
            var out: [ToolStatus] = []
            for await s in group { out.append(s) }
            return out
        }
        let statuses = (try? ai.status()) ?? []
        var items: [Candidate] = []
        for key in Self.order {
            if let id = CLIBackendID(rawValue: key) {
                guard tools.first(where: { $0.id == id })?.state == .ready, let t = Self.table(key) else { continue }
                items.append(Candidate(key: key, label: id.name, models: t))
            } else if let st = statuses.first(where: { "api:" + $0.id == key }), st.configured {
                // Người dùng đã đặt model cho nhà cung cấp thì dùng model đó cho mọi bậc (Ollama, LM Studio bắt buộc phải đặt).
                let chosen = ((try? ai.configuredModel(provider: st.id)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
                if let chosen { items.append(Candidate(key: key, label: st.label, models: Self.tiers(chosen, chosen, chosen))) }
                else if let t = Self.table(key) { items.append(Candidate(key: key, label: st.label, models: t)) }
            }
        }
        cached = (now(), items)
        return items
    }

    private func fullModel(_ c: Candidate, _ tier: Tier) -> String {
        let model = c.models[tier] ?? "default"
        return (c.key.hasPrefix("api:") ? String(c.key.dropFirst(4)) : c.key) + "/" + model
    }

    /// Nguồn có nhận ảnh trong PVTA không: true, false, hoặc nil (chưa biết; chỉ dùng khi người dùng tự chọn).
    static func acceptsImages(_ key: String) -> Bool? {
        switch key {
        case "codex", "opencode", "api:anthropic", "api:openai", "api:gemini": true
        case "claude", "agy": false
        default: nil
        }
    }

    public func choose(kind: TaskKind, excluding: Set<String> = [], needsImages: Bool = false) async throws -> ModelChoiceResult {
        let items = await available()
        guard !items.isEmpty else {
            throw PVTAError("Chưa có công cụ AI hay khóa API nào dùng được. Mở Cài đặt → Công cụ AI để cài và đăng nhập, hoặc Cài đặt → API để nhập khóa (xem thêm: pvta call tools.status).")
        }
        var skipped: [String] = []
        for c in items where !excluding.contains(c.key) {
            if needsImages, Self.acceptsImages(c.key) != true { skipped.append("\(c.label) (chưa nhận ảnh)"); continue }
            if let until = await usage.limitedUntil(c.key) {
                skipped.append("\(c.label) (vừa chạm hạn mức, nghỉ tới \(Self.clock(until)))")
                continue
            }
            if let warn = Quota.warning(await usage.cached(c.key), now: now()) {
                skipped.append("\(c.label) (\(warn.dropLast()))")
                continue
            }
            let model = fullModel(c, kind.tier)
            var reason = "Loại việc: \(kind.label). Dùng \(c.label) (\(model))."
            if !skipped.isEmpty { reason += " Bỏ qua: " + skipped.joined(separator: "; ") + "." }
            return ModelChoiceResult(model: model, provider: c.key, label: c.label, kind: kind, reason: reason)
        }
        throw PVTAError("Mọi nguồn AI đang dùng được đều đã chạm hạn mức hoặc bị loại: " + (skipped.isEmpty ? "không còn nguồn nào khác" : skipped.joined(separator: "; ")) + ". Hãy chờ hạn mức làm mới hoặc thêm một nguồn AI khác.")
    }

    /// Các nguồn khác có thể nhận bàn giao.
    func alternatives(kind: TaskKind, excluding: Set<String>, needsImages: Bool = false) async -> [HandoffChoice] {
        var out: [HandoffChoice] = []
        for c in await available() where !excluding.contains(c.key) {
            if needsImages, Self.acceptsImages(c.key) != true { continue }
            if await usage.limitedUntil(c.key) != nil { continue }
            if Quota.warning(await usage.cached(c.key), now: now()) != nil { continue }
            let model = fullModel(c, kind.tier)
            out.append(HandoffChoice(model: model, provider: c.key, label: "\(c.label) · \(model)"))
        }
        return out
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
