import Foundation

/// Đường gửi tin tới model có tính hạn mức và bàn giao nhà cung cấp.
public final class ModelGateway: Sendable {
    let ai: AIClient
    let router: ModelRouter
    let usage: UsageMonitor
    let handoffs: HandoffManager
    let urgency: Urgency
    static let maxHandovers = 5

    init(ai: AIClient, router: ModelRouter, usage: UsageMonitor, handoffs: HandoffManager, urgency: Urgency) {
        self.ai = ai
        self.router = router
        self.usage = usage
        self.handoffs = handoffs
        self.urgency = urgency
    }

    /// Gửi tin tới model có tính hạn mức và bàn giao. `model` là mã đầy đủ hoặc `auto` (chọn theo loại việc).
    /// Trước khi gửi, nếu nguồn đã dùng từ 90% hạn mức; hoặc khi nguồn từ chối vì hạn mức: dừng, lưu ngữ cảnh
    /// và chờ người dùng chọn nguồn khác (`handoff.choose`), rồi tiếp tục với bản bàn giao. Sự kiện `.model` báo model đang trả lời.
    public func stream(model requested: String, kind: TaskKind, chatId: String? = nil,
                       _ request: ChatRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let images = request.messages.last?.images ?? []
                    let needsImages = !images.isEmpty
                    var current = requested == "auto" ? try await router.choose(kind: kind, needsImages: needsImages).model : requested
                    if needsImages, ModelRouter.acceptsImages(providerKey(model: current)) == false {
                        throw ProviderError(.other, "Model đã chọn chưa nhận ảnh trong PVTA. Hãy chọn Tự động, OpenAI Codex, OpenCode hoặc một model API có đọc ảnh, hoặc gỡ ảnh đính kèm.")
                    }
                    var req = request
                    var partial = ""
                    var failed = Set<String>()
                    var announced = ""
                    for round in 0...ModelGateway.maxHandovers {
                        let key = providerKey(model: current)
                        var reason = await usage.warning(key)
                        if reason == nil {
                            if announced != current { continuation.yield(.model(current)); announced = current }
                            do {
                                for try await event in ai.stream(model: current, req) {
                                    if case .text(let t) = event { partial += t }
                                    continuation.yield(event)
                                }
                                continuation.finish()
                                return
                            } catch let error as ProviderError where error.kind == .rateLimited {
                                await urgency.rateLimited()
                                await usage.markLimited(key, retryAfter: error.retryAfter)
                                reason = error.message
                            }
                        }
                        failed.insert(key)
                        await router.invalidate()
                        guard round < ModelGateway.maxHandovers else { break }
                        let choices = await router.alternatives(kind: kind, excluding: failed, needsImages: needsImages)
                        let context = HandoffContext(
                            task: request.messages.last { $0.role == .user }?.content ?? "",
                            prompt: cliPrompt(request.messages, resume: false), system: request.system,
                            partial: partial.isEmpty ? nil : partial)
                        let (choice, prompt) = try await handoffs.wait(from: current, reason: reason ?? "", choices: choices,
                                                                       context: context, chatId: chatId)
                        current = choice.model
                        req = ChatRequest(system: request.system, messages: [ChatMessage(role: .user, content: prompt, images: images)], maxTokens: request.maxTokens)
                    }
                    throw ProviderError(.rateLimited, "Các nhà cung cấp AI đều đã chạm hạn mức. Hãy chờ hạn mức làm mới rồi thử lại.")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}
