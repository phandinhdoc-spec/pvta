import Foundation

public struct UsageTotal: Codable, Sendable, Equatable {
    public var model: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
}

/// Cộng dồn mức dùng theo model từ lúc tiến trình giữ dữ liệu khởi động.
public actor UsageMeter {
    private var totals: [String: UsageTotal] = [:]

    public init() {}

    func record(model: String, _ usage: TokenUsage?) {
        var t = totals[model] ?? UsageTotal(model: model, requests: 0, inputTokens: 0, outputTokens: 0)
        t.requests += 1
        if let usage {
            t.inputTokens += usage.inputTokens
            t.outputTokens += usage.outputTokens
        }
        totals[model] = t
    }

    public func snapshot() -> [UsageTotal] { totals.values.sorted { $0.model < $1.model } }
}

public struct ProviderStatus: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var configured: Bool
    public var needsKey: Bool
    public var fixedURL: Bool
    public var baseUrl: String
    public var model: String
    public var keyHint: String
}

/// Điểm vào duy nhất để gọi AI qua API: mã model dạng `<nhà-cung-cấp>/<model>`.
/// Địa chỉ và model lấy từ cấu hình, khóa lấy từ Keychain; khóa chỉ được gửi tới đúng địa chỉ đã lưu.
public final class AIClient: Sendable {
    private let config: ConfigStore
    private let keys: KeyStore
    private let transport: HTTPTransport
    private let retry: RetryPolicy
    public let meter = UsageMeter()
    /// Môi trường tìm và chạy các công cụ dòng lệnh AI (claude, codex, agy, opencode).
    public let cli: CLIEnvironment
    let transportForTools: HTTPTransport
    var keysForUsage: KeyStore { keys }
    var dataHome: URL { config.paths.home }
    var configStore: ConfigStore { config }
    let opener: @Sendable (URL) -> Void

    public init(config: ConfigStore, keys: KeyStore = KeychainKeyStore(), transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = .standard, cli: CLIEnvironment? = nil,
                opener: @escaping @Sendable (URL) -> Void = ToolSetup.systemOpener) {
        self.config = config
        self.keys = keys
        self.transport = transport
        self.transportForTools = transport
        self.retry = retry
        self.cli = cli ?? CLIEnvironment(workDirectory: config.paths.home.appendingPathComponent("workspace/cli", isDirectory: true))
        self.opener = opener
    }

    func makeSetup(emit: @escaping @Sendable (SetupEvent) -> Void) -> ToolSetup {
        ToolSetup(env: cli, home: config.paths.home, transport: transportForTools, opener: opener, emit: emit)
    }

    private func baseURL(_ info: ProviderInfo, _ settings: ProviderSettings?) -> String {
        info.fixedURL ? info.baseURL : (settings?.baseUrl?.isEmpty == false ? settings!.baseUrl! : info.baseURL)
    }

    public func provider(_ id: String) throws -> any AIProvider {
        guard let info = ProviderInfo.find(id) else { throw ProviderError(.other, "Nhà cung cấp AI \"\(id)\" không có trong PVTA.") }
        let settings = try config.load().providers[id]
        let base = baseURL(info, settings)
        guard !base.isEmpty else {
            throw ProviderError(.missingKey, "Chưa có địa chỉ máy chủ cho \(info.label). Mở Cài đặt → API để nhập địa chỉ, ví dụ http://localhost:1234/v1.")
        }
        let url = try ProviderInfo.validateBaseURL(base)
        let key = try keys.read(provider: id)
        if info.needsKey && key == nil {
            throw ProviderError(.missingKey, "Chưa nhập khóa API cho \(info.label). Mở Cài đặt → API để thêm.")
        }
        switch info.apiProtocol {
        case .anthropic:
            return AnthropicProvider(info: info, base: url, key: key ?? "", transport: transport, retry: retry)
        case .openai:
            return OpenAICompatibleProvider(info: info, base: url, key: key, transport: transport, retry: retry)
        }
    }

    /// Tách mã model của công cụ dòng lệnh: `claude/default`, `codex/gpt-5.5`, `opencode/anthropic/claude-sonnet-5-5`.
    private func splitCLI(_ full: String) -> (CLIBackendID, String)? {
        guard let slash = full.firstIndex(of: "/"), let id = CLIBackendID(rawValue: String(full[..<slash])) else { return nil }
        let model = String(full[full.index(after: slash)...])
        return model.isEmpty ? nil : (id, model)
    }

    /// Gửi tin và nhận luồng chữ. Hủy Task đang đọc luồng thì kết nối mạng (hoặc tiến trình công cụ) cũng bị dừng.
    /// Mã model là `<nhà-cung-cấp>/<model>` (API) hoặc `<công-cụ>/<model>` (claude, codex, agy, opencode đã đăng nhập).
    public func stream(model full: String, _ request: ChatRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source: AsyncThrowingStream<AIEvent, Error>
                    if let (tool, model) = splitCLI(full) {
                        source = CLIRunner.stream(tool, model: model, request, in: cli)
                    } else if let (info, model) = ProviderInfo.split(full) {
                        source = try provider(info.id).stream(model: model, request)
                    } else {
                        throw ProviderError(.model, "Mã model phải có dạng <nhà cung cấp>/<model>, ví dụ anthropic/claude-sonnet-5-5 hoặc claude/default.")
                    }
                    var usage: TokenUsage?
                    for try await event in source {
                        if case .usage(let u) = event { usage = u }
                        continuation.yield(event)
                    }
                    await meter.record(model: full, usage)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(provider id: String) async throws -> [ModelInfo] {
        guard let info = ProviderInfo.find(id) else { throw ProviderError(.other, "Nhà cung cấp AI \"\(id)\" không có trong PVTA.") }
        if info.needsKey && !info.publicModels, try keys.read(provider: id) == nil {
            throw ProviderError(.missingKey, "Chưa nhập khóa API cho \(info.label). Hãy lưu khóa rồi bấm lại.")
        }
        // Nhà cung cấp xem model công khai mà chưa có khóa thì vẫn gọi được.
        let p: any AIProvider
        do { p = try provider(id) } catch let e as ProviderError where e.kind == .missingKey && info.publicModels && info.needsKey {
            p = OpenAICompatibleProvider(info: info, base: try ProviderInfo.validateBaseURL(info.baseURL), key: nil,
                                         transport: transport, retry: retry)
        }
        return try await p.listModels()
    }

    public func status() throws -> [ProviderStatus] {
        let providers = try config.load().providers
        return try ProviderInfo.all.map { info in
            let settings = providers[info.id]
            let base = baseURL(info, settings)
            let hasKey = try keys.read(provider: info.id) != nil
            return ProviderStatus(
                id: info.id, label: info.label, configured: (!info.needsKey || hasKey) && !base.isEmpty,
                needsKey: info.needsKey, fixedURL: info.fixedURL, baseUrl: base,
                model: settings?.model ?? info.defaultModel, keyHint: info.keyHint)
        }
    }

    /// Lưu địa chỉ và model của nhà cung cấp. Đổi địa chỉ thì khóa cũ bị xóa để không gửi tới máy chủ mới.
    public func save(provider id: String, baseUrl: String?, model: String?) throws {
        guard let info = ProviderInfo.find(id) else { throw PVTAError("Nhà cung cấp AI \"\(id)\" không có trong PVTA.") }
        let old = try config.load().providers[id]
        var newBase = old?.baseUrl
        if let baseUrl, !info.fixedURL {
            newBase = baseUrl.isEmpty ? nil : try ProviderInfo.validateBaseURL(baseUrl).absoluteString
        }
        let oldEffective = baseURL(info, old), newEffective = baseURL(info, ProviderSettings(baseUrl: newBase))
        // Khóa đã gắn với một địa chỉ thì không được theo sang địa chỉ khác (lần đầu đặt địa chỉ thì giữ khóa).
        if !oldEffective.isEmpty, oldEffective.lowercased() != newEffective.lowercased() { try keys.delete(provider: id) }
        try config.update {
            var s = $0.providers[id] ?? ProviderSettings()
            s.baseUrl = newBase
            if let model { s.model = model.isEmpty ? nil : model }
            $0.providers[id] = s
        }
    }

    /// Model người dùng đã đặt cho nhà cung cấp (nếu có).
    func configuredModel(provider id: String) throws -> String? { try config.load().providers[id]?.model }

    public func saveKey(provider id: String, _ key: String) throws {
        guard ProviderInfo.find(id) != nil else { throw PVTAError("Nhà cung cấp AI \"\(id)\" không có trong PVTA.") }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PVTAError("Khóa API không được để trống.") }
        try keys.save(trimmed, provider: id)
    }

    public func deleteKey(provider id: String) throws {
        guard ProviderInfo.find(id) != nil else { throw PVTAError("Nhà cung cấp AI \"\(id)\" không có trong PVTA.") }
        try keys.delete(provider: id)
    }
}
