import Foundation
import Testing
@testable import PVTACore

// MARK: Dựng công cụ giả bằng script bash (không gọi AI thật, không cài gì thật)

final class Gia: @unchecked Sendable {
    let dir: URL
    let work: URL
    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true)
        work = dir.appendingPathComponent("work")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func viet(_ name: String, _ body: String, in sub: String = "bin") {
        let url = dir.appendingPathComponent(sub).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(("#!/bin/bash\n" + body).utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func doc(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    func moi(path: [String]? = nil, extra: [String: String] = [:]) -> CLIEnvironment {
        var env = ["PATH": (path ?? [dir.appendingPathComponent("bin").path]).joined(separator: ":") + ":/usr/bin:/bin",
                   "FAKE_DIR": dir.path, "HOME": dir.path]
        env.merge(extra) { _, new in new }
        return CLIEnvironment(environment: env, workDirectory: work, extraDirs: [])
    }

    func ai(_ env: CLIEnvironment, transport: FakeTransport = FakeTransport([])) -> AIClient {
        AIClient(config: ConfigStore(paths: DataPaths(home: dir.appendingPathComponent("data"))), keys: MemoryKeyStore(),
                 transport: transport, retry: .none, cli: env)
    }
}

let claudeChat = """
printf '%s\\n' "$@" > "$FAKE_DIR/claude.args"
cat > "$FAKE_DIR/claude.stdin"
pwd > "$FAKE_DIR/claude.cwd"
env | grep -c '^ANTHROPIC_API_KEY=' > "$FAKE_DIR/claude.apikey"
echo '{"type":"system","subtype":"init","session_id":"sess-1"}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Xin "}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"chào"}}}'
echo '{"type":"result","subtype":"success","result":"Xin chào","session_id":"sess-1"}'
"""

func claude(_ g: Gia, chat: String = claudeChat, claudeFiveHour: Int = 5) {
    g.viet("claude", """
    case "$1" in
      --version) echo "2.1.0 (Claude Code giả)"; exit 0;;
      auth) if [ "$2" = "status" ]; then
              if [ -f "$FAKE_DIR/loggedout" ]; then echo '{"loggedIn": false}'; exit 1; fi
              echo '{"loggedIn": true}'; exit 0; fi
            if [ "$2" = "login" ]; then
              echo "Opening browser to sign in: https://claude.ai/oauth/authorize?code=true&x=1"
              echo "Visit https://evil.example/steal for help"
              printf 'Paste code here if prompted > '
              read code
              if [ "$code" = "GOODCODE123" ]; then rm -f "$FAKE_DIR/loggedout"; echo; echo "Logged in"; exit 0; fi
              echo "bad code" >&2; exit 1
            fi;;
    esac
    case "$*" in *--input-format*)
      while IFS= read -r line; do
        case "$line" in
          *usage-init*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage-init","response":{}}}';;
          *usage-read*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage-read","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":\(claudeFiveHour),"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":6,"resets_at":"2099-01-02T00:00:00+00:00"}}}}}';;
        esac
      done; exit 0;;
    esac
    \(chat)
    """)
}

private func hoi(_ ai: AIClient, _ model: String, system: String? = nil, session: String? = nil,
                 messages: [ChatMessage] = [.init(role: .user, content: "Chào thầy")]) async throws -> (text: String, session: String?) {
    var text = "", sid: String?
    for try await e in ai.stream(model: model, ChatRequest(system: system, messages: messages, conversationId: session)) {
        switch e {
        case .text(let t): text += t
        case .session(let s): sid = s
        case .usage, .model: break
        }
    }
    return (text, sid)
}

private func loi(_ ai: AIClient, _ model: String) async -> ProviderError? {
    do { _ = try await hoi(ai, model); return nil } catch { return error as? ProviderError }
}

// MARK: Phát hiện và kiểm tra tình trạng

@Test func mayChuaCaiThiBaoDungVaHuongDanTungBuoc() async throws {
    let g = Gia()
    let env = g.moi()                                  // thư mục bin trống
    for id in CLIBackendID.allCases {
        let s = await ToolHealth.check(id, in: env)
        #expect(s.state == .notInstalled && !s.installed)
        #expect(s.steps.count >= 3)
        #expect(s.steps.joined().contains(id.docs))
    }
    let claudeStatus = await ToolHealth.check(.claude, in: env)
    #expect(claudeStatus.steps[0].contains("tools.install"))
    #expect(claudeStatus.steps.joined().contains("Pro, Max, Team"))
    let open = await ToolHealth.check(.opencode, in: env)
    #expect(open.steps[0].contains("không tự cài"))

    // Dùng thử khi chưa cài: lỗi có phân loại và có hướng dẫn.
    let e = await loi(g.ai(env), "claude/default")
    #expect(e?.kind == .notInstalled)
    #expect(e?.message.contains("Máy chưa có Claude Code") == true)
    #expect(e?.message.contains("Cài đặt") == true)
}

@Test func nhanRaCongCuDaCaiVaTinhTrangDangNhap() async throws {
    let g = Gia()
    claude(g)
    g.viet("codex", """
    case "$1" in --version) echo "codex-cli 0.9.9"; exit 0;; login) [ -f "$FAKE_DIR/codex-out" ] && exit 1; echo "Logged in using ChatGPT"; exit 0;; esac
    """)
    g.viet("agy", """
    case "$1" in --version) echo "1.5.3"; exit 0;; models) echo "gemini-x	Gemini X"; exit 0;; esac
    """)
    g.viet("opencode", "case \"$1\" in --version) echo 1.19.5; exit 0;; esac")
    let env = g.moi()

    let all = await withTaskGroup(of: ToolStatus.self) { group in
        for id in CLIBackendID.allCases { group.addTask { await ToolHealth.check(id, in: env) } }
        var out: [ToolStatus] = []
        for await s in group { out.append(s) }
        return out
    }
    #expect(all.count == 4 && all.allSatisfy { $0.state == .ready && $0.installed && $0.steps.isEmpty })
    #expect(all.first { $0.id == .claude }?.version == "2.1.0 (Claude Code giả)")
    #expect(all.first { $0.id == .claude }?.path == g.dir.appendingPathComponent("bin/claude").path)

    // Đã cài nhưng chưa đăng nhập.
    try Data().write(to: g.dir.appendingPathComponent("loggedout"))
    try Data().write(to: g.dir.appendingPathComponent("codex-out"))
    for id in [CLIBackendID.claude, .codex] {
        let s = await ToolHealth.check(id, in: env)
        #expect(s.installed && s.state == .notLoggedIn)
        #expect(s.steps.joined().contains("Đăng nhập"))
    }
    let e = await loi(g.ai(env), "claude/default")
    // Chưa đăng nhập thì kiểm tra tình trạng báo rõ; gọi thẳng vẫn do công cụ tự báo lỗi (xem test lỗi bên dưới).
    #expect(e == nil || e?.kind == .auth)
}

@Test func bienMoiTruongGhiDeDuongDanCongCu() async throws {
    let g = Gia()
    claude(g)
    g.viet("claude-khac", "echo khac", in: "tuy-chon")
    let env = g.moi(path: [], extra: ["PVTA_CLAUDE_BIN": g.dir.appendingPathComponent("tuy-chon/claude-khac").path])
    #expect(env.find(.claude) == g.dir.appendingPathComponent("tuy-chon/claude-khac").path)
    let sai = g.moi(path: [g.dir.appendingPathComponent("bin").path], extra: ["PVTA_CLAUDE_BIN": "/khong/co/claude"])
    #expect(sai.find(.claude) == g.dir.appendingPathComponent("bin/claude").path)   // biến sai thì quay về tìm trong PATH
}

// MARK: Dùng công cụ để trả lời

@Test func claudeTraLoiBangChuStreamVaChayOCheDoChiDoc() async throws {
    let g = Gia()
    claude(g)
    let env = g.moi(extra: ["ANTHROPIC_API_KEY": "sk-ant-KHONG-DUOC-DI-THEO", "OPENAI_API_KEY": "sk-x"])
    let ai = g.ai(env)
    let r = try await hoi(ai, "claude/sonnet", system: "Bạn là trợ lý của giáo viên.", session: "sess-0")
    #expect(r.text == "Xin chào")
    #expect(r.session == "sess-1")

    let args = g.doc("claude.args").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for flag in ["-p", "--strict-mcp-config", "--disable-slash-commands", "--safe-mode", "--include-partial-messages"] { #expect(args.contains(flag)) }
    #expect(args.contains("--tools"))
    let toolsIndex = args.firstIndex(of: "--tools")!
    #expect(args[toolsIndex + 1] == "")                          // không công cụ gốc nào
    #expect(args[args.firstIndex(of: "--model")! + 1] == "sonnet")
    #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "Bạn là trợ lý của giáo viên.")
    #expect(args[args.firstIndex(of: "--resume")! + 1] == "sess-0")
    #expect(g.doc("claude.stdin") == "Chào thầy")                // prompt đi qua stdin
    #expect(g.doc("claude.apikey").trimmingCharacters(in: .whitespacesAndNewlines) == "0")   // khóa API không theo vào
    #expect(g.doc("claude.cwd").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/work"))   // thư mục riêng, không phải thư mục người dùng
    #expect(await ai.meter.snapshot().first?.requests == 1)
}

@Test func codexAgyVaOpenCodeCungMotDuongGoi() async throws {
    let g = Gia()
    g.viet("codex", """
    printf '%s\\n' "$@" > "$FAKE_DIR/codex.args"; cat > "$FAKE_DIR/codex.stdin"
    echo '{"type":"thread.started","thread_id":"th-1"}'
    echo '{"type":"error","message":"Reconnecting... 1/5"}'
    echo '{"type":"item.updated","item":{"id":"i1","type":"agent_message","text":"Xin"}}'
    echo '{"type":"item.updated","item":{"id":"i1","type":"agent_message","text":"Xin chào"}}'
    echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Xin chào"}}'
    echo '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Đoạn hai"}}'
    echo '{"type":"turn.completed"}'
    """)
    g.viet("agy", """
    printf '%s\\n' "$@" > "$FAKE_DIR/agy.args"; cat > "$FAKE_DIR/agy.stdin"
    echo '{"event":"step_update","step_update":{"step_type":"tool_call","text_delta":"BO QUA","conversation_id":"c-9"}}'
    echo '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Xin "}}'
    echo '{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"chào"}}'
    echo '{"event":"result","result":{"status":"DONE","response":"Xin chào"}}'
    """)
    g.viet("opencode", """
    printf '%s\\n' "$@" > "$FAKE_DIR/opencode.args"; cat > "$FAKE_DIR/opencode.stdin"
    echo '{"type":"text","sessionID":"s-7","part":{"id":"p1","text":"Xin"}}'
    echo '{"type":"text","sessionID":"s-7","part":{"id":"p1","text":"Xin chào"}}'
    """)
    let ai = g.ai(g.moi())

    let c = try await hoi(ai, "codex/gpt-5.5", system: "Quy tắc")
    #expect(c.text == "Xin chào\n\nĐoạn hai" && c.session == "th-1")
    let ca = g.doc("codex.args").split(separator: "\n").map(String.init)
    #expect(Array(ca.prefix(2)) == ["exec", "--json"] && ca.contains("read-only") && ca.last == "-")
    #expect(g.doc("codex.stdin").hasPrefix("Quy tắc\n\nChào thầy"))

    let a = try await hoi(ai, "agy/gemini-3.8-flash-high")
    #expect(a.text == "Xin chào" && a.session == "c-9")
    let aa = g.doc("agy.args")
    #expect(aa.contains("plan") && aa.contains("--sandbox") && aa.contains("write_file(*)") && aa.contains("command(*)"))
    #expect(!aa.contains("dangerously-skip-permissions"))
    #expect(g.doc("agy.stdin").contains(#""event":"user""#) && g.doc("agy.stdin").contains("Chào thầy"))

    let o = try await hoi(ai, "opencode/anthropic/claude-sonnet-5-5")
    #expect(o.text == "Xin chào" && o.session == "s-7")
    let oa = g.doc("opencode.args").split(separator: "\n").map(String.init)
    #expect(oa.contains("plan") && oa.contains("--auto") && !oa.contains("--standalone"))
    #expect(oa[oa.firstIndex(of: "--model")! + 1] == "anthropic/claude-sonnet-5-5")   // model có dấu "/"
}

@Test func nhieuTinNhanDuocGhepRoiRutGonKhiCoPhienCu() {
    let msgs: [ChatMessage] = [.init(role: .user, content: "A"), .init(role: .assistant, content: "B"), .init(role: .user, content: "C")]
    #expect(cliPrompt(msgs, resume: true) == "C")
    #expect(cliPrompt(msgs, resume: false) == "[Người dùng]\nA\n\n[Trợ lý]\nB\n\n[Người dùng]\nC")
}

@Test func loiCuaCongCuDuocPhanLoaiBangTiengViet() async throws {
    let g = Gia()
    func chay(_ ketQua: String) async -> ProviderError? {
        g.viet("claude", ketQua)
        return await loi(g.ai(g.moi()), "claude/default")
    }
    let auth = await chay(#"echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login"}'"#)
    #expect(auth?.kind == .auth && auth?.message.contains("đăng nhập") == true)
    let han = await chay("echo 'Claude usage limit reached. Your limit will reset at 5pm' >&2; exit 1")
    #expect(han?.kind == .rateLimited)
    let flag = await chay("echo \"error: unknown option '--safe-mode'\" >&2; exit 2")
    #expect(flag?.message.contains("cập nhật") == true)
    let model = await chay(#"echo '{"type":"result","is_error":true,"result":"There is an issue with the selected model (x)"}'"#)
    #expect(model?.kind == .model)
    let lung = await chay("echo 'boom sk-ant-LO-BI-MAT-12345678' >&2; exit 3")
    #expect(lung?.kind == .other)
    #expect(lung?.message.contains("LO-BI-MAT") == false)         // chữ kỹ thuật không ra màn hình
    let rong = await chay("exit 0")
    #expect(rong?.kind == .incomplete)
    // Không có từng đoạn nhưng có kết quả cuối: vẫn trả lời được.
    g.viet("claude", #"echo '{"type":"result","subtype":"success","result":"Chỉ có kết quả cuối"}'"#)
    #expect(try await hoi(g.ai(g.moi()), "claude/default").text == "Chỉ có kết quả cuối")
}

@Test func huyGiuaChungDungCaCayTienTrinh() async throws {
    let g = Gia()
    claude(g, chat: """
    sleep 300 &
    echo $! > "$FAKE_DIR/child.pid"
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Một"}}}'
    wait
    """)
    let ai = g.ai(g.moi())
    let nhan = Task { () -> String in
        for try await e in ai.stream(model: "claude/default", ChatRequest(messages: [.init(role: .user, content: "x")])) {
            if case .text(let t) = e { return t }
        }
        return ""
    }
    #expect(try await nhan.value == "Một")                       // thoát vòng lặp → luồng bị hủy
    let pid = Int32(g.doc("child.pid").trimmingCharacters(in: .whitespacesAndNewlines))!
    var chet = false
    for _ in 0..<150 where !chet {
        chet = kill(pid, 0) != 0                                  // tiến trình con của công cụ cũng phải chết
        if !chet { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(chet)
}

@Test func hetGioThiDungTienTrinh() async throws {
    let g = Gia()
    let exit = try await CLIProcess.run(binary: "/bin/sleep", args: ["30"], environment: ["PATH": "/bin"], directory: g.dir,
                                        stdin: .none, timeout: .milliseconds(300)) { _, _ in }
    #expect(exit.timedOut && exit.code == nil)
}

// MARK: Cài đặt (giả lập mạng, không chạy bộ cài thật)

private func boCaiTao(_ g: Gia) -> String {
    // Bộ cài giả: chỉ tạo công cụ giả trong thư mục tạm.
    """
    #!/bin/bash
    mkdir -p "$FAKE_DIR/bin"
    cat > "$FAKE_DIR/bin/claude" <<'EOS'
    #!/bin/bash
    case "$1" in --version) echo "2.1.0 (vừa cài)"; exit 0;; auth) echo '{"loggedIn": true}'; exit 0;; esac
    EOS
    chmod +x "$FAKE_DIR/bin/claude"
    echo "Đã cài xong"
    """.replacingOccurrences(of: "\n    ", with: "\n")
}

private final class Thu: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SetupEvent] = []
    func them(_ e: SetupEvent) { lock.lock(); items.append(e); lock.unlock() }
    var events: [SetupEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

private func setup(_ g: Gia, _ mang: FakeTransport, thu: Thu = Thu(), opener: @escaping @Sendable (URL) -> Void = { _ in },
                   installTimeout: Duration = .seconds(30)) -> ToolSetup {
    ToolSetup(env: g.moi(), home: g.dir.appendingPathComponent("data"), transport: mang, opener: opener,
              emit: { thu.them($0) }, installTimeout: installTimeout, pollInterval: .milliseconds(50))
}

@Test func caiThanhCongChiKhiCongCuChayDuocVaDuongTaiDungNguon() async throws {
    let g = Gia()
    let mang = FakeTransport([
        .init(status: 302, headers: ["location": "https://downloads.claude.com/install.sh"]),
        .init(headers: ["content-type": "text/x-shellscript"], body: boCaiTao(g)),
    ])
    let thu = Thu()
    let status = try await setup(g, mang, thu: thu).install(.claude)
    #expect(status.installed && status.state == .ready && status.version == "2.1.0 (vừa cài)")
    #expect(mang.requests.map { $0.url!.absoluteString } == ["https://claude.ai/install.sh", "https://downloads.claude.com/install.sh"])
    #expect(thu.events.first?.phase == .running && thu.events.last?.phase == .done)
    #expect(thu.events.contains { $0.lines.contains("Đã cài xong") })

    let installers = g.dir.appendingPathComponent("data/installers")
    let sub = try FileManager.default.contentsOfDirectory(at: installers, includingPropertiesForKeys: nil)
    #expect(sub.count == 1)
    let source = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: sub[0].appendingPathComponent("source.json")))
    #expect(source["sha256"]?.string?.count == 64)
    #expect(source["finalUrl"]?.string == "https://downloads.claude.com/install.sh")
}

@Test func nguonKhongTinCayHtmlQuaLonKhongBaoGioDuocChay() async throws {
    let g = Gia()
    let danhDau = g.dir.appendingPathComponent("da-chay")
    let doc = "#!/bin/bash\ntouch '\(danhDau.path)'\n"
    let truongHop: [(FakeTransport.Reply, String)] = [
        (.init(status: 302, headers: ["location": "https://evil.example/install.sh"]), "không thuộc nhà cung cấp"),
        (.init(status: 302, headers: ["location": "http://claude.ai/install.sh"]), "không thuộc nhà cung cấp"),
        (.init(status: 302, headers: ["location": "https://claude.ai:8443/install.sh"]), "không thuộc nhà cung cấp"),
        (.init(headers: ["content-type": "text/html; charset=utf-8"], body: doc), "trang web"),
        (.init(body: "<!DOCTYPE html><html>Đăng nhập</html>"), "không hợp lệ"),
        (.init(body: String(repeating: "x", count: ToolInstaller.sizeLimit + 1)), "quá lớn"),
        (.init(status: 404, body: "x"), "mã 404"),
        (.init(openError: URLError(.notConnectedToInternet)), "kết nối mạng"),
    ]
    for (reply, expected) in truongHop {
        let mang = FakeTransport([reply])
        do { _ = try await setup(g, mang).install(.claude); Issue.record("phải lỗi: \(expected)") } catch let e as PVTAError {
            #expect(e.message.contains(expected), "\(e.message) ⊅ \(expected)")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: danhDau.path))                      // không bộ cài nào được chạy
    let sau = (try? FileManager.default.contentsOfDirectory(atPath: g.dir.appendingPathComponent("data/installers").path)) ?? []
    #expect(sau.isEmpty)                                                                  // không để lại tệp
    #expect(throws: PVTAError.self) { _ = try ToolInstaller.info(.opencode) }             // opencode PVTA không tự cài
}

@Test func moTrinhCaiKhongPhaiLaCaiThanhCong() async throws {
    let g = Gia()
    // Bộ cài chạy xong (mã 0) nhưng không để lại công cụ nào.
    let khongCoGi = FakeTransport([.init(body: "#!/bin/bash\necho xong\n")])
    let thu = Thu()
    await #expect(throws: PVTAError.self) { _ = try await setup(g, khongCoGi, thu: thu).install(.claude) }
    #expect(thu.events.last?.phase == .failed)
    #expect(thu.events.last?.message?.contains("chưa thành công") == true)
    // Bộ cài lỗi (mã 1).
    let loi = FakeTransport([.init(body: "#!/bin/bash\nexit 1\n")])
    await #expect(throws: PVTAError.self) { _ = try await setup(g, loi).install(.codex) }
    // Bộ cài chạy quá lâu thì bị dừng.
    let treo = FakeTransport([.init(body: "#!/bin/bash\nsleep 60\n")])
    do { _ = try await setup(g, treo, installTimeout: .milliseconds(300)).install(.claude); Issue.record("phải lỗi") } catch let e as PVTAError {
        #expect(e.message.contains("quá thời gian"))
    }
}

@Test func motCongCuChiMotLuotCaiHoacDangNhapMotLuc() async throws {
    let g = Gia()
    let s = setup(g, FakeTransport([.init(body: "#!/bin/bash\nsleep 60\n")]))
    let dau = Task { try await s.install(.claude) }
    try await Task.sleep(for: .milliseconds(300))
    await #expect(throws: PVTAError.self) { _ = try await s.install(.claude) }
    await s.cancel(.claude)
    await #expect(throws: PVTAError.self) { _ = try await dau.value }                    // Dừng được
    #expect(throws: PVTAError.self) { try ToolInstaller.info(.opencode) }
}

// MARK: Đăng nhập

@Test func dangNhapClaudeMoDungTrangDanMaVaKhongGiuToken() async throws {
    let g = Gia()
    claude(g)
    try Data().write(to: g.dir.appendingPathComponent("loggedout"))
    let mo = Thu2()
    let thu = Thu()
    let s = setup(g, FakeTransport([]), thu: thu, opener: { mo.them($0) })
    #expect(await ToolHealth.check(.claude, in: g.moi()).state == .notLoggedIn)

    let dangNhap = Task { try await s.login(.claude) }
    var thayMa = false
    for _ in 0..<200 where !thayMa {
        thayMa = thu.events.contains { $0.phase == .code }
        if !thayMa { try await Task.sleep(for: .milliseconds(25)) }
    }
    #expect(thayMa)
    #expect(mo.urls == ["https://claude.ai/oauth/authorize?code=true&x=1"])               // chỉ mở trang của nhà cung cấp
    #expect(thu.events.allSatisfy { $0.lines.joined().contains("evil.example") == false })  // địa chỉ web không lọt ra dòng hiển thị

    await #expect(throws: PVTAError.self) { try await s.sendCode(.claude, "có dấu cách") }   // mã sai định dạng bị chặn
    try await s.sendCode(.claude, "  GOODCODE123 \n")
    let status = try await dangNhap.value
    #expect(status.state == .ready)
    #expect(thu.events.last?.phase == .done)
    await #expect(throws: PVTAError.self) { try await s.sendCode(.claude, "GOODCODE123") }  // hết phiên thì không nhận mã nữa

    // Không ghi gì vào thư mục dữ liệu của PVTA ngoài tệp cài đặt: không mật khẩu, không token.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: g.dir.appendingPathComponent("data").path)) ?? []
    #expect(files.isEmpty)
}

private final class Thu2: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func them(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.absoluteString) }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func dangNhapAgyMoTerminalRoiTuNhanKhiXong() async throws {
    let g = Gia()
    g.viet("agy", """
    case "$1" in --version) echo 1.5.3; exit 0;; models) [ -f "$FAKE_DIR/agy-ok" ] && { echo "m	M"; exit 0; }; echo "unauthenticated" >&2; exit 1;; esac
    """)
    let mo = Thu2()
    let dir = g.dir
    let s = setup(g, FakeTransport([]), opener: { url in
        mo.them(url)
        try? Data().write(to: dir.appendingPathComponent("agy-ok"))    // người dùng đăng nhập xong trong Terminal
    })
    let before = await ToolHealth.check(.agy, in: g.moi())
    #expect(before.state == .notLoggedIn)
    let status = try await s.login(.agy)
    #expect(status.state == .ready)
    let file = try #require(mo.all.first)
    #expect(file.pathExtension == "command")
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o700)
    #expect(try String(contentsOf: file, encoding: .utf8).contains(g.dir.appendingPathComponent("bin/agy").path))

    // Chưa cài thì không mở gì cả.
    let rong = Gia()
    let mo2 = Thu2()
    await #expect(throws: PVTAError.self) { _ = try await setup(rong, FakeTransport([]), opener: { mo2.them($0) }).login(.claude) }
    #expect(mo2.all.isEmpty)
}

@Test func cacHamPhatHienDuongDanVaMaDangNhap() {
    #expect(SetupText.extractLoginURL(.claude, "Visit https://evil.example/x then https://claude.ai/oauth?a=1).")?.absoluteString == "https://claude.ai/oauth?a=1")
    #expect(SetupText.extractLoginURL(.claude, "http://claude.ai/x") == nil)
    #expect(SetupText.extractLoginURL(.codex, "https://user:pw@chatgpt.com/x") == nil)
    #expect(SetupText.extractLoginURL(.codex, "\u{1B}[32mhttps://auth.openai.com/device\u{1B}[0m")?.host == "auth.openai.com")
    #expect(SetupText.extractLoginURL(.claude, "https://notclaude.ai/x") == nil)
    #expect(SetupText.asksForCode("Paste code here if prompted >"))
    #expect(SetupText.asksForCode("Enter the authorization code:"))
    #expect(!SetupText.asksForCode("Opening browser"))
    #expect(SetupText.validCode("ABC123-xyz_.~") && !SetupText.validCode("ab") && !SetupText.validCode("a b c d e f") && !SetupText.validCode("abc\ndef123"))
}

// MARK: Qua giao diện gọi chung

@Test func goiQuaLoiCuaNutKhacTrangThaiCaiDatVaTraLoi() async throws {
    let g = Gia()
    claude(g)
    let paths = DataPaths(home: g.dir.appendingPathComponent("data"))
    let ai = AIClient(config: ConfigStore(paths: paths), keys: MemoryKeyStore(), transport: FakeTransport([]), retry: .none, cli: g.moi())
    let host = try await PVTANode.open(paths: paths, ai: ai)
    let client = try await PVTANode.open(paths: paths)

    let ds = try await client.call("tools.status").decode([ToolStatus].self)
    #expect(ds.map(\.id) == [.claude, .codex, .agy, .opencode])
    #expect(ds[0].state == .ready && ds[1].state == .notInstalled && ds[1].steps.count >= 3)
    #expect(try await client.call("tools.status", ["backend": "codex"]).decode([ToolStatus].self).count == 1)
    #expect(try await client.call("tools.installers").decode([InstallerInfo].self).map(\.backend) == [.claude, .codex, .agy])

    await #expect(throws: PVTAError.self) { try await client.call("tools.status", ["backend": "khong-co"]) }
    await #expect(throws: PVTAError.self) { try await client.call("tools.sendCode", ["backend": "claude", "code": "GOODCODE123"]) }

    let ra = try await client.call("ai.ask", ["model": "claude/default", "prompt": "Chào"])
    #expect(ra["text"]?.string == "Xin chào" && ra["session"]?.string == "sess-1")
    let nhatKy = try await client.call("activity.list").decode([Activity].self)
    #expect(nhatKy.contains { $0.kind == "ai.ask" && $0.state == .done && $0.model == "claude/default" })
    await client.shutdown(); await host.shutdown()
}
