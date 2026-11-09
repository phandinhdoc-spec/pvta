import Foundation

public enum ToolState: String, Codable, Sendable {
    case notInstalled = "chua-cai"
    case notLoggedIn = "chua-dang-nhap"
    case ready = "san-sang"
}

public struct ToolStatus: Codable, Sendable, Equatable {
    public var id: CLIBackendID
    public var name: String
    public var installed: Bool
    public var path: String?
    public var version: String?
    public var state: ToolState
    /// Câu giải thích ngắn bằng tiếng Việt.
    public var detail: String
    /// Hướng dẫn từng bước khi chưa dùng được.
    public var steps: [String]
    public var docs: String
    public var requirement: String
    public var installable: Bool
}

enum ToolHealth {
    static func steps(_ id: CLIBackendID, state: ToolState) -> [String] {
        let loginStep: String
        switch id {
        case .agy:
            loginStep = "Đăng nhập: PVTA mở một cửa sổ Terminal cho riêng bước đăng nhập agy. Đăng nhập tài khoản Google ở đó, PVTA tự nhận khi xong."
        case .opencode:
            loginStep = "Đăng nhập (nếu dùng model cần tài khoản): chạy lệnh opencode auth login trong Terminal. Các model miễn phí không cần đăng nhập."
        default:
            loginStep = "Đăng nhập: bấm Đăng nhập… (hoặc chạy pvta call tools.login '{\"backend\":\"\(id.rawValue)\"}'). PVTA mở trang đăng nhập của nhà cung cấp trên trình duyệt; nếu công cụ hỏi mã, dán mã vào ô hiện ra."
        }
        switch state {
        case .ready: return []
        case .notLoggedIn: return [loginStep, "Sau khi đăng nhập, bấm Kiểm tra lại công cụ AI.", id.requirement]
        case .notInstalled:
            if id.installable {
                return ["Cài đặt: bấm Cài \(id.name) trong Cài đặt → Công cụ AI (hoặc chạy pvta call tools.install '{\"backend\":\"\(id.rawValue)\"}'). PVTA tải bộ cài chính thức và chạy ở nền, không mở Terminal.",
                        loginStep,
                        "Bấm Kiểm tra lại công cụ AI.",
                        id.requirement,
                        "Nếu cài không thành công, xem hướng dẫn của nhà cung cấp: \(id.docs)"]
            }
            return ["Cài \(id.name) theo hướng dẫn của nhà cung cấp: \(id.docs). PVTA không tự cài công cụ này.",
                    "Cài xong, bấm Kiểm tra lại công cụ AI.", id.requirement]
        }
    }

    static func check(_ id: CLIBackendID, in env: CLIEnvironment) async -> ToolStatus {
        func status(_ state: ToolState, installed: Bool, path: String? = nil, version: String? = nil, detail: String) -> ToolStatus {
            ToolStatus(id: id, name: id.name, installed: installed, path: path, version: version, state: state, detail: detail,
                       steps: steps(id, state: state), docs: id.docs, requirement: id.requirement, installable: id.installable)
        }
        guard let bin = env.find(id) else {
            return status(.notInstalled, installed: false, detail: "Máy chưa có \(id.name).")
        }
        async let versionRun = env.capture(bin, ["--version"], id: id)
        async let loginRun = loginCheck(id, bin: bin, env: env)
        let (v, login) = await (versionRun, loginRun)
        let version = v.output.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) }
        if v.exit?.code != 0 {
            return status(.notInstalled, installed: false, path: bin, detail: "Đã thấy \(id.name) nhưng không chạy được. Hãy cài lại theo hướng dẫn.")
        }
        switch login {
        case .yes: return status(.ready, installed: true, path: bin, version: version, detail: "\(id.name) đã cài và sẵn sàng.")
        case .no(let why): return status(.notLoggedIn, installed: true, path: bin, version: version, detail: why)
        }
    }

    private enum Login { case yes, no(String) }

    private static func loginCheck(_ id: CLIBackendID, bin: String, env: CLIEnvironment) async -> Login {
        let notYet = "\(id.name) đã cài nhưng chưa đăng nhập."
        let unknown = "Chưa xác nhận được \(id.name) đã đăng nhập (công cụ không trả lời kịp). Bấm Kiểm tra lại."
        switch id {
        case .claude:
            let r = await env.capture(bin, ["auth", "status"], id: id)
            if r.exit?.timedOut != false { return .no(unknown) }
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(r.output.utf8))
            return json?["loggedIn"]?.bool == true ? .yes : .no(notYet)
        case .codex:
            let r = await env.capture(bin, ["login", "status"], id: id)
            if r.exit?.timedOut != false { return .no(unknown) }
            return r.exit?.code == 0 ? .yes : .no(notYet)
        case .agy:
            // agy không có lệnh hỏi trạng thái đăng nhập; liệt kê model chỉ chạy được khi đã đăng nhập.
            let r = await env.capture(bin, ["models"], id: id)
            if r.exit?.timedOut != false { return .no(unknown) }
            return r.exit?.code == 0 && !r.output.isEmpty ? .yes : .no(notYet)
        case .opencode:
            return .yes
        }
    }
}
