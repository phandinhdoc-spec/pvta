import Foundation

/// Chạy một tác vụ và ghi nhật ký: bắt đầu, kết quả (xong, lỗi, bị dừng). Lỗi ghi nhật ký không làm hỏng tác vụ.
func trackActivity<T: Sendable>(store: DataStore, kind: String, chatId: String? = nil, projectId: String? = nil,
                                model: String? = nil, _ body: @Sendable () async throws -> T) async throws -> T {
    let id = try? await store.startActivity(kind: kind, chatId: chatId, projectId: projectId, model: model)
    Log.core.info("Bắt đầu \(kind, privacy: .public)")
    func finish(_ state: ActivityState, _ detail: String?) async {
        if let id { try? await store.finishActivity(id: id, state: state, detail: detail) }
        Log.core.info("\(kind, privacy: .public) kết thúc: \(state.rawValue, privacy: .public) \(Redactor.clean(detail ?? ""), privacy: .public)")
    }
    do {
        let result = try await body()
        await finish(.done, nil)
        return result
    } catch is CancellationError {
        await finish(.interrupted, "Đã dừng theo yêu cầu.")
        throw CancellationError()
    } catch {
        await finish(.error, UserMessage.text(for: error))
        throw error
    }
}
