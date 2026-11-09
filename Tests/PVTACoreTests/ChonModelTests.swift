import Foundation
import Testing
@testable import PVTACore

// MARK: Dụng cụ

private actor Lay {
    private(set) var ten: [String] = []
    func them(_ n: String) { ten.append(n) }
}

private final class Dong: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func tien(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private final class ApLuc: @unchecked Sendable {
    private let lock = NSLock()
    private var p = MemoryPressure.normal
    private var n = 0
    var doc: MemoryPressure { lock.lock(); defer { lock.unlock() }; n += 1; return p }
    var soLanDoc: Int { lock.lock(); defer { lock.unlock() }; return n }
    func dat(_ v: MemoryPressure) { lock.lock(); p = v; lock.unlock() }
}

private func thuMuc() -> DataPaths {
    DataPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
}

private func urgency(_ dong: Dong = Dong(), cpus: Int = 10, ram: UInt64 = 32 << 30, ap: ApLuc = ApLuc()) -> Urgency {
    Urgency(now: { dong.now }, machine: { MachineInfo(cpus: cpus, totalMemory: ram) }, pressure: { ap.doc }, changed: { _ in })
}

private func cho(_ timeout: Double = 5, _ ok: () async -> Bool) async -> Bool {
    let han = Date().addingTimeInterval(timeout)
    while Date() < han {
        if await ok() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

// MARK: Phân loại việc và chọn model

@Test func phanLoaiViecTatDinh() {
    func k(_ text: String, attachments: [String] = [], _ edit: (inout TaskHints) -> Void = { _ in }) -> TaskKind {
        var h = TaskHints(text: text, attachmentNames: attachments)
        edit(&h)
        return TaskClassifier.classify(h)
    }
    #expect(k("Đặt tên cho hội thoại này") == .simple)
    #expect(k("x") { $0.background = true } == .background)
    #expect(k("Lập ma trận đề kiểm tra giữa kỳ môn Toán 8") == .exam)
    #expect(k("Soạn giáo án bài 5 lớp 7 theo công văn 5512, có hoạt động khởi động và luyện tập, ghi chi tiết từng bước") == .office)
    #expect(k("Xem file này", attachments: ["bang-diem.xlsx"]) == .office)
    #expect(k("Viết hàm Python tính điểm trung bình") == .coding)
    #expect(k("Tạo quy trình tự động chấm bài") == .workflow)
    #expect(k("Lên kế hoạch ôn tập") { $0.planning = true } == .planning)
    #expect(k("Lên kế hoạch ôn tập") { $0.proPlanning = true } == .pro)
    #expect(k("Hãy chứng minh và phân tích chuyên sâu tác động của chương trình mới đối với việc dạy học ở trường") == .pro)
    #expect(k(String(repeating: "Nội dung dài. ", count: 150)) == .pro)
    #expect(k("Hãy giải thích cho học sinh lớp 6 vì sao có mùa trong năm, giọng văn gần gũi.\nThêm một ví dụ so sánh với quả cam để các em dễ hình dung hơn nhé.") == .standard)
    #expect(TaskKind.exam.tier == .strong && TaskKind.simple.tier == .fast && TaskKind.office.tier == .standard)
}

@Test func tuDongChonTheoLoaiViecVaBoQuaNguonHetHanMuc() async throws {
    let g = Gia()
    claude(g)
    let paths = thuMuc()
    let keys = MemoryKeyStore()
    try keys.save("k", provider: "anthropic")
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: g.moi())
    let dong = Dong()
    let usage = UsageMonitor(now: { dong.now }, read: { _ in throw PVTAError("không đọc") })
    let router = ModelRouter(ai: ai, usage: usage, now: { dong.now })

    // Công cụ đã đăng nhập đứng trước API; model theo bậc của loại việc.
    #expect(try await router.choose(kind: .simple).model == "claude/haiku")
    #expect(try await router.choose(kind: .office).model == "claude/sonnet")
    let exam = try await router.choose(kind: .exam)
    #expect(exam.model == "claude/opus" && exam.provider == "claude")
    #expect(exam.reason.contains("ra đề") && exam.reason.contains("Claude Code"))

    // Claude vừa bị từ chối vì hạn mức: nhảy sang API, nói rõ lý do.
    await usage.markLimited("claude", retryAfter: 600)
    let api = try await router.choose(kind: .exam)
    #expect(api.model == "anthropic/claude-opus-5-5" && api.reason.contains("vừa chạm hạn mức"))
    // Hết thời gian nghỉ thì dùng lại.
    dong.tien(601)
    #expect(try await router.choose(kind: .simple).provider == "claude")

    // Đã dùng từ 90% thì bị bỏ qua.
    let used = UsageWindow(usedPercent: 93, resetsAt: nil, status: nil, updatedAt: dong.now)
    await usage.inject("claude", ProviderUsage(fiveHour: used, week: nil, updatedAt: dong.now))
    let skip = try await router.choose(kind: .simple)
    #expect(skip.provider == "api:anthropic" && skip.reason.contains("93%"))
    // Danh sách nguồn có thể nhận bàn giao không có nguồn đang bị loại.
    #expect(await router.alternatives(kind: .simple, excluding: []).map(\.provider) == ["api:anthropic"])

    // Mọi nguồn đều bị loại: báo rõ, không chọn bừa.
    await usage.markLimited("api:anthropic", retryAfter: 600)
    await #expect(throws: PVTAError.self) { _ = try await router.choose(kind: .simple) }
}

@Test func khongCoNguonNaoThiHuongDanThayVaChiDungNguonDaDatModel() async throws {
    let g = Gia()
    let paths = thuMuc()
    let keys = MemoryKeyStore()
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: FakeTransport([]), retry: .none, cli: g.moi())
    let router = ModelRouter(ai: ai, usage: UsageMonitor(read: { _ in throw PVTAError("x") }))
    do { _ = try await router.choose(kind: .simple); Issue.record("phải lỗi") } catch let e as PVTAError {
        #expect(e.message.contains("Công cụ AI") && e.message.contains("tools.status"))
    }
    // Ollama chạy được nhưng chưa đặt model thì chưa được chọn; đặt rồi thì dùng cho mọi bậc.
    await router.invalidate()
    await #expect(throws: PVTAError.self) { _ = try await router.choose(kind: .simple) }
    try ai.save(provider: "ollama", baseUrl: nil, model: "llama3")
    await router.invalidate()
    let pick = try await router.choose(kind: .exam)
    #expect(pick.model == "ollama/llama3")
}

// MARK: Hạn mức

@Test func docSoLieuHanMucTuDauRaThatCuaTungNguon() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    let claude = UsageParser.claude(try json(#"{"rate_limits":{"five_hour":{"utilization":23,"resets_at":"2026-11-09T04:50:00.218442+00:00"},"seven_day":{"utilization":6,"resets_at":"2026-11-15T16:00:00.218485+00:00"},"seven_day_opus":null}}"#), now: now)
    #expect(claude?.fiveHour?.usedPercent == 23 && claude?.week?.usedPercent == 6)
    #expect(claude?.fiveHour?.resetsAt != nil)
    #expect(UsageParser.claude(try json(#"{"rate_limits_available":false}"#), now: now) == nil)

    let codex = UsageParser.codex(try json(#"{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1794620603},"secondary":null}}"#), now: now)
    #expect(codex?.week?.usedPercent == 30 && codex?.fiveHour == nil)
    #expect(codex?.week?.resetsAt == Date(timeIntervalSince1970: 1794620603))

    let agyJSON = #"{"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.85,"reset_time":"2026-11-13T23:42:45Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.96,"reset_time":"2026-11-09T03:28:37Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.31},{"id":"3p-5h","window":"5h","remaining_fraction":0}]}]}}}"#
    let gem = UsageParser.agy(try json(agyJSON), model: "gemini-4-argon-high", now: now)
    #expect(Int(gem?.week?.usedPercent?.rounded() ?? 0) == 15 && Int(gem?.fiveHour?.usedPercent?.rounded() ?? 0) == 4)
    let third = UsageParser.agy(try json(agyJSON), model: "claude-sonnet-4-6", now: now)
    #expect(Int(third?.week?.usedPercent?.rounded() ?? 0) == 69)
    #expect(third?.fiveHour?.status == "rejected")

    let cc = try UsageParser.commandCode(try json(#"{"windowLimits":{"limited":true,"fiveHour":{"used":50,"cap":200,"resetAt":1900003600000},"weekly":{"used":9,"cap":10,"resetAt":"2030-01-01T00:00:00Z"}}}"#), now: now)
    #expect(cc.fiveHour?.usedPercent == 25 && cc.week?.usedPercent == 90)
    #expect(try UsageParser.commandCode(try json(#"{"windowLimits":{"limited":false}}"#), now: now).unlimited)
    #expect(throws: PVTAError.self) { _ = try UsageParser.commandCode(try json("{}"), now: now) }
}

@Test func canhBaoTuNguongChinChucPhanTram() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func usage(five: Double? = nil, week: Double? = nil, age: TimeInterval = 0, reset: TimeInterval? = nil, status: String? = nil) -> ProviderUsage {
        let at = now.addingTimeInterval(-age)
        func w(_ p: Double?) -> UsageWindow? {
            p == nil && status == nil ? nil : UsageWindow(usedPercent: p, resetsAt: reset.map { now.addingTimeInterval($0) }, status: status, updatedAt: at)
        }
        return ProviderUsage(fiveHour: w(five), week: w(week), updatedAt: at)
    }
    #expect(Quota.warning(usage(five: 89.9), now: now) == nil)
    #expect(Quota.warning(usage(five: 90), now: now) == "Hạn mức 5 giờ: 90% đã dùng.")
    #expect(Quota.warning(usage(five: 10, week: 95), now: now)?.contains("tuần") == true)
    #expect(Quota.warning(usage(five: 99, age: 200), now: now) == nil)                 // số liệu cũ không được tin
    #expect(Quota.warning(usage(five: 99, reset: -5), now: now) == nil)                // cửa sổ đã làm mới
    #expect(Quota.warning(usage(status: "rejected"), now: now)?.contains("đã hết") == true)
    #expect(Quota.warning(usage(status: "warning"), now: now)?.contains("sắp hết") == true)
    var free = usage(five: 99); free.unlimited = true
    #expect(Quota.warning(free, now: now) == nil)
    #expect(Quota.warning(nil, now: now) == nil)
}

@Test func docHanMucThatQuaCongCuGiaVaQuaApiCommandCode() async throws {
    let g = Gia()
    claude(g, claudeFiveHour: 42)
    g.viet("codex", """
    case "$1" in
      --version) echo "codex-cli 1"; exit 0;;
      app-server)
        while IFS= read -r line; do case "$line" in
          *'"id":1'*) echo '{"id":1,"result":{}}';;
          *rateLimits*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":93,"windowDurationMins":300,"resetsAt":4102444800},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":4102444800}}}}';;
        esac; done;;
    esac
    """)
    g.viet("agy", """
    case "$1" in --version) echo 1; exit 0;; --print) echo '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.5}]}]}}}'; exit 0;; esac
    """)
    g.viet("opencode", "echo 1")
    let keys = MemoryKeyStore()
    try keys.save("cc-secret-key", provider: "commandcode")
    let mang = FakeTransport([
        .init(body: #"{"org":{"id":42}}"#),
        .init(body: #"{"windowLimits":{"limited":true,"fiveHour":{"used":1,"cap":4,"resetAt":4102444800000}}}"#),
    ])
    let ai = AIClient(config: ConfigStore(paths: thuMuc()), keys: keys, transport: mang, retry: .none, cli: g.moi())

    let c = try await ai.readUsage(key: "claude")
    #expect(c.fiveHour?.usedPercent == 42 && c.week?.usedPercent == 6)
    let x = try await ai.readUsage(key: "codex")
    #expect(x.fiveHour?.usedPercent == 93 && x.week?.usedPercent == 30)
    #expect(Quota.warning(x) != nil)
    #expect(try await ai.readUsage(key: "agy").fiveHour?.usedPercent == 50)

    let cc = try await ai.readUsage(key: "api:commandcode")
    #expect(cc.fiveHour?.usedPercent == 25)
    let urls = mang.requests.map { $0.url!.absoluteString }
    #expect(urls == ["https://api.commandcode.ai/alpha/whoami?limits=1", "https://api.commandcode.ai/alpha/billing/credits?orgId=42"])
    #expect(mang.requests.allSatisfy { $0.value(forHTTPHeaderField: "authorization") == "Bearer cc-secret-key" })

    await #expect(throws: PVTAError.self) { _ = try await ai.readUsage(key: "api:openai") }
    await #expect(throws: PVTAError.self) { _ = try await ai.readUsage(key: "opencode") }
    let khongCai = AIClient(config: ConfigStore(paths: thuMuc()), keys: MemoryKeyStore(), transport: mang, retry: .none, cli: Gia().moi())
    await #expect(throws: PVTAError.self) { _ = try await khongCai.readUsage(key: "claude") }
    await #expect(throws: PVTAError.self) { _ = try await khongCai.readUsage(key: "api:commandcode") }   // chưa có khóa
}

// MARK: Bàn giao

private struct Cap {
    let paths = thuMuc()
    let keys = MemoryKeyStore()
    let mang: FakeTransport
    let core: Core
    init(_ replies: [FakeTransport.Reply]) async throws {
        mang = FakeTransport(replies)
        try keys.save("k1", provider: "anthropic")
        try keys.save("k2", provider: "openai")
        let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
        try paths.prepare()
        core = Core(store: try DataStore(file: paths.database), ai: ai)
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
}

private func doc(_ s: AsyncThrowingStream<AIEvent, Error>) async throws -> (text: String, models: [String]) {
    var text = "", models: [String] = []
    for try await e in s {
        switch e {
        case .text(let t): text += t
        case .model(let m): models.append(m)
        default: break
        }
    }
    return (text, models)
}

private let tinh429 = FakeTransport.Reply(status: 429, headers: ["retry-after": "30"], lines: [#"{"error":{"message":"rate limit"}}"#])

@Test func bi429ThiDungLuuNguCanhChoChonNguonKhacRoiTiepTuc() async throws {
    let c = try await Cap([tinh429, .init(lines: openaiOK)]); defer { c.don() }
    let cau = "Soạn giáo án Toán 8 bài 3 về hằng đẳng thức, có hoạt động khởi động"
    let request = ChatRequest(system: "Bạn là trợ lý của giáo viên.", messages: [.init(role: .user, content: cau)])
    let ket = Task { try await doc(c.core.chatStream(model: "auto", kind: .office, chatId: "c1", request)) }

    #expect(await cho { await c.core.handoffs.views().count == 1 })
    let v = try #require(await c.core.handoffs.views().first)
    #expect(v.from == "anthropic/claude-sonnet-5-5" && v.chatId == "c1")
    #expect(v.reason.contains("hạn mức") && v.reason.contains("30 giây"))
    #expect(v.choices.map(\.model) == ["openai/gpt-5.4-mini"])             // không gợi ý lại nguồn vừa từ chối
    #expect(v.summary.contains(cau))
    // Bản lưu đầy đủ nằm trên đĩa với quyền chỉ chủ sở hữu.
    let file = URL(fileURLWithPath: v.checkpoint)
    let luu = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(luu["context"]?["task"]?.string == cau && luu["context"]?["system"]?.string == "Bạn là trợ lý của giáo viên.")
    #expect(((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int) == 0o600)
    // Trong lúc chờ, Tự động không chọn lại nguồn vừa từ chối.
    #expect(try await c.core.router.choose(kind: .office).provider == "api:openai")

    try await c.core.handoffs.choose(id: v.id, model: "openai/gpt-5.4-mini")
    let r = try await ket.value
    #expect(r.text == "Xin chào" && r.models == ["anthropic/claude-sonnet-5-5", "openai/gpt-5.4-mini"])
    #expect(await c.core.handoffs.views().isEmpty)

    // Nguồn mới nhận đúng ngữ cảnh đã bàn giao.
    let gui = c.mang.requests[1]
    #expect(gui.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    let noiDung = String(decoding: gui.httpBody ?? Data(), as: UTF8.self)
    #expect(noiDung.contains("BÀN GIAO KHI ĐỔI NHÀ CUNG CẤP AI") && noiDung.contains(cau))
    #expect(noiDung.contains("Bạn là trợ lý của giáo viên."))
    #expect(!noiDung.contains("k1"))                                       // khóa của nguồn cũ không đi theo
}

@Test func chuaXongThiPhanDoDangDuocMangSangNguonMoi() async throws {
    let dau = ["event: message_start", #"data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}"#,
               #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Phần đầu "}}"#,
               #"data: {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#]
    let c = try await Cap([.init(lines: dau), .init(lines: openaiOK)]); defer { c.don() }
    let request = ChatRequest(messages: [.init(role: .user, content: "Viết lời nhận xét học bạ cho học sinh A")])
    let ket = Task { try await doc(c.core.chatStream(model: "anthropic/claude-haiku-5-5", kind: .simple, request)) }
    #expect(await cho { await c.core.handoffs.views().count == 1 })
    let v = try #require(await c.core.handoffs.views().first)
    #expect(v.summary.contains("ĐẦU RA DỞ DANG") && v.summary.contains("Phần đầu"))
    try await c.core.handoffs.choose(id: v.id, model: v.choices[0].model)
    let r = try await ket.value
    #expect(r.text == "Phần đầu Xin chào")                                  // phần đã nhận được giữ lại, phần sau nối tiếp
    #expect(String(decoding: c.mang.requests[1].httpBody ?? Data(), as: UTF8.self).contains("Phần đầu"))
}

@Test func gannHetHanMucThiHoiTruocKhiGui() async throws {
    let c = try await Cap([.init(lines: openaiOK)]); defer { c.don() }
    let now = Date()
    let nhieu = UsageWindow(usedPercent: 94, resetsAt: nil, status: nil, updatedAt: now)
    await c.core.usage.inject("api:anthropic", ProviderUsage(fiveHour: nhieu, week: nil, updatedAt: now))
    let request = ChatRequest(messages: [.init(role: .user, content: "Chào")])
    let ket = Task { try await doc(c.core.chatStream(model: "anthropic/claude-sonnet-5-5", kind: .standard, request)) }
    #expect(await cho { await c.core.handoffs.views().count == 1 })
    #expect(c.mang.requests.isEmpty)                                         // chưa gửi gì cho nguồn gần hết hạn mức
    let v = try #require(await c.core.handoffs.views().first)
    #expect(v.reason == "Hạn mức 5 giờ: 94% đã dùng.")
    try await c.core.handoffs.choose(id: v.id, model: "openai/gpt-5.4-mini")
    #expect(try await ket.value.text == "Xin chào")
}

@Test func dungHoacChonSaiThiXuLyDungVaGiuBanLuu() async throws {
    let c = try await Cap([tinh429, tinh429]); defer { c.don() }
    let request = ChatRequest(messages: [.init(role: .user, content: "Chào")])

    // Chọn sai: chỉ nhận nguồn trong danh sách.
    let a = Task { try await doc(c.core.chatStream(model: "anthropic/claude-sonnet-5-5", kind: .standard, request)) }
    #expect(await cho { await c.core.handoffs.views().count == 1 })
    let v = try #require(await c.core.handoffs.views().first)
    await #expect(throws: PVTAError.self) { try await c.core.handoffs.choose(id: v.id, model: "anthropic/claude-haiku-5-5") }
    await #expect(throws: PVTAError.self) { try await c.core.handoffs.choose(id: "khong-co", model: nil) }
    // Người dùng chọn Dừng.
    try await c.core.handoffs.choose(id: v.id, model: nil)
    do { _ = try await a.value; Issue.record("phải lỗi") } catch let e as PVTAError { #expect(e.message.contains("Đã dừng chuyển")) }
    #expect(FileManager.default.fileExists(atPath: v.checkpoint))             // bản bàn giao vẫn còn

    // Hủy lượt khi đang chờ chọn: không treo, bản lưu còn.
    let b = Task { try await doc(c.core.chatStream(model: "anthropic/claude-haiku-5-5", kind: .standard, request)) }
    #expect(await cho { await c.core.handoffs.views().count == 1 })
    let v2 = try #require(await c.core.handoffs.views().first)
    b.cancel()
    _ = await b.result
    #expect(await cho { await c.core.handoffs.views().isEmpty })
    #expect(FileManager.default.fileExists(atPath: v2.checkpoint))
}

@Test func khongConNguonKhacThiBaoLoiKhongChoDoi() async throws {
    let c = try await Cap([tinh429]); defer { c.don() }
    try c.keys.delete(provider: "openai")
    await c.core.router.invalidate()
    let request = ChatRequest(messages: [.init(role: .user, content: "Chào")])
    do { _ = try await doc(c.core.chatStream(model: "anthropic/claude-sonnet-5-5", kind: .standard, request)); Issue.record("phải lỗi") }
    catch let e as PVTAError { #expect(e.message.contains("Không còn nhà cung cấp")) }
}

// MARK: Cờ việc gấp và phanh RAM

@Test func coXanhGiuDungSoBuocDaDat() async {
    let u = urgency()
    #expect(await u.limit(requested: 2) == 2)
    #expect(await u.limit(requested: 9) == 4)      // tối đa 4
    #expect(await u.limit(requested: 0) == 1)
    let v = await u.view()
    #expect(v.urgent == false && v.note.contains("Cờ xanh"))
}

@Test func coDoTangSoBuocSongSongTheoMayVaTuVeXanhSau30Phut() async {
    let dong = Dong()
    let u = urgency(dong)
    #expect(await u.limit(requested: 2) == 2)
    await u.set(true)
    #expect(await u.limit(requested: 2) == 8)      // 10 nhân, 32 GB → tối đa 8
    let bon = urgency(dong, cpus: 4)
    await bon.set(true)
    #expect(await bon.limit(requested: 1) == 3)                    // máy 4 nhân: nhân − 1
    let it = urgency(dong, cpus: 16, ram: 4 << 30)                // RAM ít: 4 GB × 0,3 / 600 MB = 2
    await it.set(true)
    #expect(await it.limit(requested: 1) == 2)

    dong.tien(29 * 60)
    #expect(await u.isUrgent)
    #expect(await u.limit(requested: 2) == 8)
    dong.tien(61)                                                  // quá 30 phút
    #expect(await u.isUrgent == false)
    #expect(await u.limit(requested: 2) == 2)
    #expect(await u.view().urgent == false)
}

@Test func coDoVeXanhKhiXongViecDaDung() async {
    let u = urgency()
    await u.set(true)
    await u.idle()                                                 // chưa dùng thì chưa tự tắt
    #expect(await u.isUrgent)
    _ = await u.limit(requested: 2)                                // đã dùng
    await u.idle()
    #expect(await u.isUrgent == false)
}

@Test func gap429ThiGiamMotNuaTrong5PhutRoiTroLai() async {
    let dong = Dong()
    let u = urgency(dong)
    await u.set(true)
    #expect(await u.limit(requested: 2) == 8)
    await u.rateLimited()
    #expect(await u.limit(requested: 2) == 4)                      // giảm một nửa
    #expect(await u.view().note.contains("giảm nhịp"))
    dong.tien(2 * 60)
    await u.rateLimited()                                          // gặp thêm: giảm tiếp, gia hạn 5 phút
    #expect(await u.limit(requested: 2) == 2)
    dong.tien(4 * 60)
    #expect(await u.limit(requested: 2) == 2)                      // chưa hết 5 phút kể từ lần 429 gần nhất
    dong.tien(61)
    #expect(await u.limit(requested: 2) == 8)                      // hết 5 phút: trở lại bình thường
    await u.rateLimited(); await u.rateLimited(); await u.rateLimited(); await u.rateLimited()
    #expect(await u.limit(requested: 2) == 1)                      // giảm tối đa 3 lần, không xuống dưới 1
}

@Test func apLucBoNhoTuMucVangTroLenThiChiChay1Buoc() async {
    let ap = ApLuc()
    let dong = Dong()
    let u = urgency(dong, ap: ap)
    for flag in [false, true] {
        await u.set(flag)
        ap.dat(.normal); dong.tien(10)
        #expect(await u.limit(requested: 4) == (flag ? 8 : 4))
        ap.dat(.warn); dong.tien(10)
        #expect(await u.limit(requested: 4) == 1)
        #expect(await u.view().note.contains("vàng"))
        ap.dat(.critical); dong.tien(10)
        #expect(await u.limit(requested: 4) == 1)
        #expect(await u.view().note.contains("đỏ"))
        ap.dat(.normal); dong.tien(10)
        #expect(await u.limit(requested: 4) == (flag ? 8 : 4))     // hết căng thì mở lại
    }
    // Chỉ đọc áp lực mỗi 3 giây, không đọc mỗi lần mở bước.
    let dem = ApLuc()
    let v = urgency(dong, ap: dem)
    _ = await v.limit(requested: 1); _ = await v.limit(requested: 1); _ = await v.limit(requested: 1)
    #expect(dem.soLanDoc == 1)
    dong.tien(4)
    _ = await v.limit(requested: 1)
    #expect(dem.soLanDoc == 2)
}

@Test func docApLucBoNhoThatCuaMacOS() {
    #expect(MemoryPressure.readSystem() != .unknown)
    let m = MachineInfo.current()
    #expect(m.cpus >= 1 && m.totalMemory > 0)
}

// MARK: Qua giao diện gọi chung

@Test func goiQuaLoiChonModelCoVaBanGiaoGiuaHaiNut() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let keys = MemoryKeyStore()
    try keys.save("k1", provider: "anthropic"); try keys.save("k2", provider: "openai")
    let mang = FakeTransport([tinh429, .init(lines: openaiOK)])
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none, cli: Gia().moi())
    let host = try await PVTANode.open(paths: paths, ai: ai)
    let cua1 = try await PVTANode.open(paths: paths), cua2 = try await PVTANode.open(paths: paths)

    // Chọn model Tự động theo loại việc.
    let chon = try await cua1.call("model.resolve", ["text": "Lập ma trận đề kiểm tra học kỳ"])
    #expect(chon["kind"]?.string == "exam" && chon["model"]?.string == "anthropic/claude-opus-5-5")

    // Cờ việc gấp: một cửa sổ đổi, mọi cửa sổ thấy; không đụng tới quyền.
    let truoc = try await cua1.call("urgency.get").decode(UrgencyView.self)
    #expect(truoc.urgent == false)
    let thay = Lay()
    let sk = cua2.events
    let doi = Task { for await e in sk where e.name == "urgency" || e.name == "handoff" { await thay.them(e.name) } }
    _ = try await cua1.call("urgency.set", ["on": true])
    #expect(await cho { await thay.ten.contains("urgency") })
    #expect(try await cua2.call("urgency.get").decode(UrgencyView.self).urgent)
    #expect(try await cua2.call("urgency.limit", ["requested": 2]).number ?? 0 >= 2)
    #expect(try ConfigStore(paths: paths).load().permission == .askApproval)
    await #expect(throws: PVTAError.self) { try await cua1.call("urgency.set", [:]) }

    // Bàn giao: lượt hỏi từ nút này, người dùng chọn từ nút khác.
    let hoi = Task { try await cua1.call("ai.ask", ["prompt": "Soạn đề cương ôn tập môn Văn lớp 9"]) }
    var id = ""
    for _ in 0..<200 where id.isEmpty {
        id = (try await cua2.call("handoff.list").decode([HandoffView].self).first?.id) ?? ""
        if id.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    }
    #expect(!id.isEmpty)
    _ = try await cua2.call("handoff.choose", ["id": .string(id), "model": "openai/gpt-5.4-mini"])
    let ra = try await hoi.value
    #expect(ra["text"]?.string == "Xin chào" && ra["model"]?.string == "openai/gpt-5.4-mini")
    #expect(try await cua2.call("handoff.list").decode([HandoffView].self).isEmpty)
    #expect(await cho { await thay.ten.filter { $0 == "handoff" }.count >= 2 })      // hiện rồi biến mất
    doi.cancel()
    await cua1.shutdown(); await cua2.shutdown(); await host.shutdown()
}
