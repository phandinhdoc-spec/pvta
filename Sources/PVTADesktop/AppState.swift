import Foundation
import Combine
import PVTACore

/// Trạng thái trình bày của một cửa sổ; không lưu ô soạn vào cài đặt dùng chung.
@MainActor
final class ChatWindowState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selectedChat: String?
    @Published var draft = ""
    @Published var messages: [Message] = []
    @Published var streamedText = ""
    @Published var showFinalStream = false
    @Published var notice = ""
    @Published var error: String?
    @Published var isSending = false
    @Published var isStopping = false
    @Published var proposals: [ActionProposal] = []
    @Published var common: [String: JSONValue] = [:]
    fileprivate var request: UUID?
    fileprivate var runningChat: String?
    fileprivate var secretary = false
    fileprivate var selectionVersion = 0
    fileprivate var messageRead = 0
    fileprivate var appliedRead = 0
    init(chat: String? = nil) { selectedChat = chat }
}

/// Một nút lõi, một nơi nhận sự kiện chung. Chỉ cập nhật giao diện trên main actor;
/// khởi động lõi và thực thi lời gọi chạy ở executor nền.
@MainActor
final class AppState: ObservableObject {
    let paths: DataPaths
    @Published private(set) var status = "Đang kết nối lõi…"
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var ready = false
    private(set) var windows: [UUID: ChatWindowState] = [:]
    private var node: PVTANode?
    private var connecting: Task<PVTANode, Error>?
    private var events: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false
    private var closed = false
    private var common: [String: JSONValue] = [:]
    private var proposals: [ActionProposal] = []
    private var actionVersion = 0
    private let open: @Sendable () async throws -> PVTANode

    init(paths: DataPaths = .resolve(), open: (@Sendable () async throws -> PVTANode)? = nil) {
        self.paths = paths
        self.open = open ?? { try await PVTANode.open(paths: paths) }
    }

    func start() async {
        guard !closed, node == nil else { return }
        if connecting == nil { let open = self.open; connecting = Task.detached { try await open() } }
        do {
            let connected = try await connecting!.value
            guard !closed else { await connected.shutdown(); return }
            guard node == nil else { return }
            node = connected; connecting = nil; ready = true; status = "Đã kết nối lõi"
            events = Task { [weak self, connected] in
                for await event in connected.events {
                    guard !Task.isCancelled else { break }
                    self?.receiveCommon(event)
                }
            }
            if let permission = try? await connected.call("permission.get") { receiveCommon(Event(name: "permission", data: permission)) }
            await refresh()
        } catch { connecting = nil; status = UserMessage.text(for: error) }
    }

    func attach(_ window: ChatWindowState) async {
        guard !closed else { return }
        windows[window.id] = window; window.common = common
        await start()
        await select(window, chat: window.selectedChat)
    }

    func select(_ window: ChatWindowState, chat: String?) async {
        guard windows[window.id] != nil, !window.isSending else { return }
        window.selectedChat = chat; window.selectionVersion += 1
        window.messages = []; window.streamedText = ""; window.showFinalStream = false; window.notice = ""; window.error = nil
        updateProposals(window)
        await loadMessages(window)
    }

    private func loadMessages(_ window: ChatWindowState) async {
        guard let node, let chat = window.selectedChat else { return }
        window.messageRead += 1
        let read = window.messageRead, version = window.selectionVersion
        do {
            let value = try await node.call("chat.messages", ["id": .string(chat)]).decode([Message].self)
            guard windows[window.id] != nil, window.selectedChat == chat, window.selectionVersion == version, read >= window.appliedRead else { return }
            window.appliedRead = read; window.messages = value
        } catch { if window.selectionVersion == version { window.error = UserMessage.text(for: error) } }
    }

    func createChat(_ window: ChatWindowState) async {
        guard let node, !window.isSending else { return }
        do {
            let value = try await node.call("chat.create")
            await refresh()
            await select(window, chat: value["id"]?.string)
        } catch { window.error = UserMessage.text(for: error) }
    }

    private func receiveCommon(_ event: Event) {
        // Sự kiện có mã yêu cầu không bao giờ được quảng bá, kể cả yêu cầu đã kết thúc.
        guard event.requestId == nil, !closed else { return }
        common[event.name] = event.data
        if event.name == "actions", let value = try? event.data.decode([ActionProposal].self) { actionVersion += 1; proposals = value }
        for window in windows.values { window.common[event.name] = event.data; updateProposals(window) }
        if event.name == "data.changed" { Task { await self.refresh() } }
    }

    private func updateProposals(_ window: ChatWindowState) {
        window.proposals = proposals.filter { $0.state == .pending && $0.chatId == (window.runningChat ?? window.selectedChat) }
    }

    func refresh() async {
        guard let node, !closed else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                chats = try await node.call("chat.list").decode([Chat].self)
                let version = actionVersion
                let actions = try await node.call("action.list").decode([ActionProposal].self)
                if actionVersion == version { proposals = actions.filter { $0.state == .pending } }
                for window in Array(windows.values) { updateProposals(window); await loadMessages(window) }
            } catch { status = UserMessage.text(for: error) }
        } while refreshAgain && !closed
    }

    private enum Delivery: Sendable { case event(Event), result(JSONValue), failure(String) }

    func send(_ window: ChatWindowState, model: String? = nil) async {
        guard let node, windows[window.id] != nil, !window.isSending,
              let chat = window.selectedChat, !window.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !windows.values.contains(where: { $0.runningChat == chat }) else {
            window.error = "Hội thoại này đang chạy ở cửa sổ khác."; return
        }
        let secretary = SecretaryService.parseSign(window.draft) != nil
        if secretary, windows.values.contains(where: { $0.isSending && $0.secretary }) {
            window.error = "Thư ký đang trả lời ở cửa sổ khác."; return
        }
        window.secretary = secretary
        let request = UUID(), text = window.draft
        window.request = request; window.runningChat = chat; window.isSending = true
        window.isStopping = false; window.streamedText = ""; window.showFinalStream = false; window.error = nil; window.notice = ""; window.draft = ""
        var params: JSONValue = ["chatId": .string(chat), "text": .string(text)]
        if let model { params = ["chatId": .string(chat), "text": .string(text), "model": .string(model)] }
        let arguments = params
        let (stream, sink) = AsyncStream.makeStream(of: Delivery.self)
        // Một hàng đợi giữ thứ tự: mọi delta trước kết quả, kể cả khi main actor đang bận vẽ.
        let work = Task.detached {
            do {
                let value = try await node.call("chat.send", arguments, onEvent: { sink.yield(.event($0)) })
                sink.yield(.result(value))
            } catch { sink.yield(.failure(UserMessage.text(for: error))) }
            sink.finish()
        }
        for await delivery in stream {
            guard windows[window.id] != nil, window.request == request else { continue }
            switch delivery {
            case .event(let event):
                guard event.requestId != nil else { continue }
                if window.secretary, let target = event.data["chatId"]?.string { window.runningChat = target; updateProposals(window) }
                if event.name == "chat.delta" { window.streamedText += event.data["text"]?.string ?? "" }
                if event.name == "chat.notice" { window.notice = event.data["text"]?.string ?? "" }
            case .result(let value):
                window.error = value["message"]?["error"]?.string
                if value["sign"]?.bool == true { window.showFinalStream = true; window.streamedText = value["message"]?["text"]?.string ?? window.streamedText }
            case .failure(let message): window.error = message
            }
        }
        await work.value
        if window.request == request {
            window.request = nil; window.runningChat = nil; window.isSending = false; window.isStopping = false
            await loadMessages(window); updateProposals(window)
        }
    }

    func stop(_ window: ChatWindowState) async {
        guard let node, let chat = window.runningChat, let request = window.request, !window.isStopping else { return }
        window.isStopping = true
        // Dừng ngay sau Gửi cũng phải tới lượt chưa kịp đăng ký trong lõi.
        while window.request == request {
            do {
                if try await node.call(window.secretary ? "secretary.cancel" : "chat.cancel", ["chatId": .string(chat)]).bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            } catch { window.error = UserMessage.text(for: error); window.isStopping = false; return }
        }
    }

    func decide(_ window: ChatWindowState, proposal: ActionProposal, approve: Bool, force: Bool = false) async {
        guard let node, window.proposals.contains(where: { $0.id == proposal.id && $0.state == .pending }) else { return }
        do {
            _ = try await node.call(approve ? "action.approve" : "action.decline", ["id": .string(proposal.id), "force": .bool(force)])
            await refresh()
        } catch { window.error = UserMessage.text(for: error) }
    }

    func detach(_ window: ChatWindowState) async {
        windows[window.id] = nil
        await stop(window)
    }

    func shutdown() async {
        guard !closed else { return }; closed = true; ready = false
        for window in Array(windows.values) { await stop(window) }
        windows = [:]; events?.cancel(); events = nil
        if let node { await node.shutdown() }
        else if let connecting, let node = try? await connecting.value { await node.shutdown() }
        node = nil; connecting = nil
    }
}
