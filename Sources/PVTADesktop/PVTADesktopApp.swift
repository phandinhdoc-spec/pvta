import SwiftUI
import PVTACore

@MainActor
final class DesktopDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task { await state.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct PVTADesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("PVTA \(PVTAInfo.version)", id: "chat") {
            ChatWindowView(app: state)
                .task { delegate.state = state }
        }
    }
}

struct ChatWindowView: View {
    @ObservedObject var app: AppState
    @StateObject private var window = ChatWindowState()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Hội thoại", selection: Binding(get: { window.selectedChat ?? "" }, set: { value in
                    Task { await app.select(window, chat: value.isEmpty ? nil : value) }
                })) {
                    Text("Chọn hội thoại").tag("")
                    ForEach(app.chats, id: \.id) { Text($0.title).tag($0.id) }
                }.disabled(window.isSending || !app.ready)
                Button("Hội thoại mới") { Task { await app.createChat(window) } }.disabled(window.isSending || !app.ready)
                Button("Cửa sổ mới") { openWindow(id: "chat") }
            }
            Text(app.status).font(.caption).foregroundStyle(.secondary)
            if let label = window.common["permission"]?["label"]?.string { Text("Quyền: " + label).font(.caption) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(window.messages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading) {
                            Text(message.role == .user ? "Thầy cô" : "PVTA").font(.headline)
                            Text(message.text).textSelection(.enabled)
                            if let error = message.error { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if window.isSending || window.showFinalStream {
                        Text(window.streamedText.isEmpty ? "PVTA đang xử lý…" : window.streamedText).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !window.notice.isEmpty { Text(window.notice).foregroundStyle(.secondary) }
            if let error = window.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            TextEditor(text: $window.draft).frame(minHeight: 75, maxHeight: 130)
                .border(.secondary.opacity(0.3)).accessibilityLabel("Nội dung gửi PVTA")
            HStack {
                Text(window.isStopping ? "Đang dừng…" : window.isSending ? "Đang trả lời" : "Sẵn sàng").font(.caption)
                Spacer()
                Button("Dừng") { Task { await app.stop(window) } }.disabled(!window.isSending || window.isStopping)
                Button("Gửi") { Task { await app.send(window) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.ready || window.isSending || window.selectedChat == nil || window.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding().frame(minWidth: 800, minHeight: 500)
        .task { await app.attach(window) }
        .onDisappear { Task { await app.detach(window) } }
        .sheet(isPresented: Binding(get: { !window.proposals.isEmpty }, set: { _ in })) {
            if let proposal = window.proposals.first {
                ApprovalView(app: app, window: window, proposal: proposal).id(proposal.id)
            }
        }
    }
}

private struct ApprovalView: View {
    @ObservedObject var app: AppState
    @ObservedObject var window: ChatWindowState
    let proposal: ActionProposal
    @State private var force = false
    @State private var deciding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PVTA xin phép thực hiện").font(.title2)
            Text(proposal.summary).font(.headline)
            ScrollView {
                Text(proposal.preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(proposal.paths, id: \.self) { Text($0).font(.caption) }
                ForEach(proposal.riskReasons, id: \.self) { Text($0).foregroundStyle(.red) }
            }
            if proposal.risk == "high" { Toggle("Tôi đã đọc cảnh báo và vẫn muốn thực hiện", isOn: $force) }
            if let error = window.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Từ chối") { decide(false) }
                if window.isSending { Button("Dừng lượt") { Task { await app.stop(window) } }.disabled(window.isStopping) }
                Spacer()
                Button(proposal.risk == "high" ? "Vẫn làm" : "Duyệt") { decide(true) }
                    .disabled(proposal.risk == "high" && !force)
            }.disabled(deciding)
        }.padding(24).frame(width: 600, height: 420).interactiveDismissDisabled()
    }
    private func decide(_ approve: Bool) {
        deciding = true
        Task { await app.decide(window, proposal: proposal, approve: approve, force: force); deciding = false }
    }
}
