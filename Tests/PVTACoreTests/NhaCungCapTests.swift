import Foundation
import Testing
@testable import PVTACore

private func thuMuc() -> DataPaths {
    DataPaths(home: FileManager.default.temporaryDirectory
        .appendingPathComponent("p-\(UUID().uuidString.prefix(8))", isDirectory: true))
}

private struct Moi {
    let paths = thuMuc()
    let keys = MemoryKeyStore()
    let mang: FakeTransport
    let ai: AIClient
    init(_ replies: [FakeTransport.Reply], retry: RetryPolicy = .none) {
        mang = FakeTransport(replies)
        ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: retry)
    }
    func don() { try? FileManager.default.removeItem(at: paths.home) }
}

private func hoi(_ model: String, in ai: AIClient) async throws -> (text: String, usage: TokenUsage?) {
    var text = ""
    var usage: TokenUsage?
    let req = ChatRequest(system: "Bạn là trợ lý của giáo viên.", messages: [.init(role: .user, content: "Chào")])
    for try await e in ai.stream(model: model, req) {
        switch e {
        case .text(let t): text += t
        case .usage(let u): usage = u
        case .session, .model: break
        }
    }
    return (text, usage)
}

private func body(_ r: URLRequest) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data())) ?? .null
}

@Test func anthropicStreamChuVaMucDungVaYeuCauDung() async throws {
    let m = Moi([.init(lines: anthropicOK)]); defer { m.don() }
    try m.keys.save("sk-ant-KHOA-THU", provider: "anthropic")
    let (text, usage) = try await hoi("anthropic/claude-sonnet-5-5", in: m.ai)
    #expect(text == "Xin chào")
    #expect(usage == TokenUsage(inputTokens: 12, outputTokens: 34))

    let r = m.mang.requests[0]
    #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant-KHOA-THU")
    #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let b = body(r)
    #expect(b["model"]?.string == "claude-sonnet-5-5")
    #expect(b["stream"]?.bool == true)
    #expect(b["system"] != nil && String(decoding: r.httpBody!, as: UTF8.self).contains("cache_control"))
    #expect(String(decoding: r.httpBody!, as: UTF8.self).contains("sk-ant-KHOA-THU") == false)   // khóa chỉ ở header
}

@Test func openAIGeminiCommandCodeVaOllamaCungMotDuongChay() async throws {
    let m = Moi([.init(lines: openaiOK), .init(lines: openaiOK), .init(lines: openaiOK), .init(lines: openaiOK)]); defer { m.don() }
    try m.keys.save("sk-openai", provider: "openai")
    try m.keys.save("AIza-gemini", provider: "gemini")
    try m.keys.save("cc-key", provider: "commandcode")

    let a = try await hoi("openai/gpt-5.4-mini", in: m.ai)
    #expect(a.text == "Xin chào")
    #expect(a.usage == TokenUsage(inputTokens: 5, outputTokens: 7))
    _ = try await hoi("gemini/gemini-flash-latest", in: m.ai)
    _ = try await hoi("commandcode/deepseek/deepseek-v4-flash", in: m.ai)
    _ = try await hoi("ollama/llama3", in: m.ai)

    let rs = m.mang.requests
    #expect(rs[0].url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(rs[0].value(forHTTPHeaderField: "authorization") == "Bearer sk-openai")
    #expect(body(rs[0])["stream_options"] != nil)
    #expect(body(rs[0])["messages"] != nil && String(decoding: rs[0].httpBody!, as: UTF8.self).contains(#""role":"system""#))
    #expect(rs[1].url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    #expect(body(rs[1])["stream_options"] == nil)
    #expect(rs[2].url?.absoluteString == "https://api.commandcode.ai/provider/v1/chat/completions")
    #expect(body(rs[2])["model"]?.string == "deepseek/deepseek-v4-flash")     // model có dấu "/"
    #expect(rs[3].url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
    #expect(rs[3].value(forHTTPHeaderField: "authorization") == nil)          // Ollama không cần khóa
}

@Test func doiNhaCungCapKhongDoiMaGoi() async throws {
    let m = Moi([.init(lines: anthropicOK), .init(lines: openaiOK)]); defer { m.don() }
    try m.keys.save("k1", provider: "anthropic")
    try m.keys.save("k2", provider: "openai")
    for model in ["anthropic/claude-haiku-5-5", "openai/gpt-5.5"] {
        #expect(try await hoi(model, in: m.ai).text == "Xin chào")      // cùng một hàm gọi
    }
}

@Test func loi429CoPhanLoaiVaKhongTuThuLai() async throws {
    let m = Moi([.init(status: 429, headers: ["retry-after": "7"], lines: [#"{"error":{"message":"rate limit"}}"#])],
                retry: RetryPolicy(delays: [.zero, .zero])); defer { m.don() }
    try m.keys.save("k", provider: "openai")
    do { _ = try await hoi("openai/gpt-5.5", in: m.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .rateLimited)
        #expect(e.retryAfter == 7)
        #expect(e.message.contains("7 giây"))
        #expect(e.message.contains("hạn mức"))
    }
    #expect(m.mang.requests.count == 1)
}

@Test func loiKhoaVaModelBaoTiengVietKhongLoKhoa() async throws {
    let m = Moi([
        .init(status: 401, lines: [#"{"error":{"message":"Incorrect API key provided: sk-LO-BI-MAT-999999"}}"#]),
        .init(status: 404, lines: [#"{"error":{"message":"model 'abc' not found"}}"#]),
        .init(status: 302, headers: ["location": "https://ke-xau.test"]),
    ]); defer { m.don() }
    try m.keys.save("sk-LO-BI-MAT-999999", provider: "openai")
    var kinds: [ProviderError.Kind] = []
    var messages: [String] = []
    for _ in 0..<3 {
        do { _ = try await hoi("openai/gpt-5.5", in: m.ai) } catch let e as ProviderError { kinds.append(e.kind); messages.append(e.message) }
    }
    #expect(kinds == [.auth, .model, .other])
    #expect(messages[0].contains("Khóa API"))
    #expect(messages[1].contains("not found"))        // chi tiết ngắn của máy chủ
    #expect(messages[2].contains("chuyển hướng"))
    #expect(messages.allSatisfy { !$0.contains("LO-BI-MAT") })
}

@Test func may5xxVaLoiMangTamThoiDuocThuLai() async throws {
    let retry = RetryPolicy(delays: [.zero, .zero])
    let ok = Moi([.init(status: 503, lines: ["{}"]), .init(openError: URLError(.timedOut)), .init(lines: openaiOK)], retry: retry); defer { ok.don() }
    try ok.keys.save("k", provider: "openai")
    #expect(try await hoi("openai/gpt-5.5", in: ok.ai).text == "Xin chào")
    #expect(ok.mang.requests.count == 3)

    let hong = Moi([.init(status: 502), .init(status: 502), .init(status: 502)], retry: retry); defer { hong.don() }
    try hong.keys.save("k", provider: "openai")
    do { _ = try await hoi("openai/gpt-5.5", in: hong.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .server)
    }
    #expect(hong.mang.requests.count == 3)       // 1 lần đầu + 2 lần thử lại

    // Mất mạng hẳn: không thử lại, báo tiếng Việt.
    let off = Moi([.init(openError: URLError(.notConnectedToInternet))], retry: retry); defer { off.don() }
    try off.keys.save("k", provider: "openai")
    do { _ = try await hoi("openai/gpt-5.5", in: off.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .network && e.message.contains("kết nối mạng"))
    }
    #expect(off.mang.requests.count == 1)
}

@Test func dutGiuaChungHoacThieuTinHieuKetThucBaoChuaHoanTat() async throws {
    let cut = Moi([.init(lines: Array(openaiOK.prefix(1)), midStreamError: URLError(.networkConnectionLost))],
                  retry: RetryPolicy(delays: [.zero])); defer { cut.don() }
    try cut.keys.save("k", provider: "openai")
    var got = ""
    do {
        for try await e in cut.ai.stream(model: "openai/gpt-5.5", ChatRequest(messages: [.init(role: .user, content: "x")])) {
            if case .text(let t) = e { got += t }
        }
        Issue.record("phải lỗi")
    } catch let e as ProviderError { #expect(e.kind == .network) }
    #expect(got == "Xin ")
    #expect(cut.mang.requests.count == 1)        // đã có chữ ra ngoài nên không thử lại (tránh lặp chữ)

    let open = Moi([.init(lines: Array(anthropicOK.prefix(5)))]); defer { open.don() }   // thiếu message_stop
    try open.keys.save("k", provider: "anthropic")
    do { _ = try await hoi("anthropic/claude-haiku-5-5", in: open.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .incomplete)
    }

    let hetToken = Moi([.init(lines: sse([#"{"choices":[{"delta":{"content":"Dở"},"finish_reason":"length"}]}"#]))]); defer { hetToken.don() }
    try hetToken.keys.save("k", provider: "openai")
    do { _ = try await hoi("openai/gpt-5.5", in: hetToken.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .incomplete && e.message.contains("giới hạn token"))
    }
}

@Test func huyGiuaChungThiNgatKetNoiMang() async throws {
    let m = Moi([.init(lines: sse([#"{"choices":[{"delta":{"content":"Một"}}]}"#]), hang: true)]); defer { m.don() }
    try m.keys.save("k", provider: "openai")
    let nhan = Task { () -> String in
        var text = ""
        for try await e in m.ai.stream(model: "openai/gpt-5.5", ChatRequest(messages: [.init(role: .user, content: "x")])) {
            if case .text(let t) = e { text += t; return text }
        }
        return text
    }
    #expect(try await nhan.value == "Một")
    // Task đọc đã thoát vòng lặp (hủy luồng) nên kết nối phải được đóng.
    var daNgat = false
    for _ in 0..<100 where !daNgat {
        daNgat = m.mang.cancelledStreams >= 1
        if !daNgat { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(daNgat)

    let cho = Moi([.init(lines: sse([#"{"choices":[{"delta":{"content":"a"}}]}"#]), hang: true)]); defer { cho.don() }
    try cho.keys.save("k", provider: "openai")
    let task = Task { try await hoi("openai/gpt-5.5", in: cho.ai) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = await task.result
    var ngat = false
    for _ in 0..<100 where !ngat {
        ngat = cho.mang.cancelledStreams >= 1
        if !ngat { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(ngat)
}

@Test func thieuKhoaThiBaoNgayKhongGuiYeuCau() async throws {
    let m = Moi([]); defer { m.don() }
    do { _ = try await hoi("anthropic/claude-haiku-5-5", in: m.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.kind == .missingKey && e.message.contains("Cài đặt"))
    }
    do { _ = try await hoi("khong-co/x", in: m.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.message.contains("<nhà cung cấp>/<model>"))
    }
    do { _ = try await hoi("compatible/x", in: m.ai); Issue.record("phải lỗi") } catch let e as ProviderError {
        #expect(e.message.contains("địa chỉ máy chủ"))
    }
    #expect(m.mang.requests.isEmpty)
}

@Test func lietKeModelCuaTungNhaCungCap() async throws {
    let trang1 = #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-sonnet-5-5"}],"has_more":true,"last_id":"claude-sonnet-5-5"}"#
    let trang2 = #"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":false}"#
    let openai = #"{"data":[{"id":"text-embedding-3-small"},{"id":"gpt-5.4-mini"},{"id":"gpt-5.5"},{"id":"whisper-1"},{"id":"gpt-5.5"}]}"#
    let gemini = #"{"models":[{"name":"models/gemini-pro-latest"},{"name":"models/gemini-flash-latest"},{"name":"models/imagen-3"}]}"#
    let ollama = #"{"data":[{"id":"llama3:8b"},{"id":"nomic-embed-text"}]}"#
    let m = Moi([.init(body: trang1), .init(body: trang2), .init(body: openai), .init(body: gemini), .init(body: ollama),
                 .init(body: #"{"data":[]}"#), .init(status: 401, body: "{}")]); defer { m.don() }
    try m.keys.save("k", provider: "anthropic")
    try m.keys.save("k", provider: "openai")
    try m.keys.save("k", provider: "gemini")

    let a = try await m.ai.listModels(provider: "anthropic")
    #expect(a.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
    #expect(a[0].label == "Claude Opus 5.5")
    #expect(m.mang.requests[1].url?.absoluteString.contains("after_id=claude-sonnet-5-5") == true)
    #expect(m.mang.requests[0].value(forHTTPHeaderField: "x-api-key") == "k")

    #expect(try await m.ai.listModels(provider: "openai").map(\.id) == ["gpt-5.5", "gpt-5.4-mini"])
    #expect(try await m.ai.listModels(provider: "gemini").map(\.id) == ["gemini-pro-latest", "gemini-flash-latest"])
    #expect(try await m.ai.listModels(provider: "ollama").map(\.id) == ["llama3:8b"])

    // Máy chủ không có model nào dùng được, và khóa bị từ chối.
    await #expect(throws: ProviderError.self) { try await m.ai.listModels(provider: "ollama") }
    await #expect(throws: ProviderError.self) { try await m.ai.listModels(provider: "openai") }
}

@Test func luuCaiDatKhoaKhongVaoTepCauHinhVaDoiDiaChiXoaKhoa() async throws {
    let m = Moi([]); defer { m.don() }
    try m.ai.saveKey(provider: "compatible", "khoa-may-chu-rieng-777")
    try m.ai.save(provider: "compatible", baseUrl: "http://localhost:1234/v1/", model: "qwen")
    #expect(try m.keys.read(provider: "compatible") != nil)             // lần đầu đặt địa chỉ: giữ khóa vừa nhập
    // Lưu lại cùng địa chỉ: khóa giữ nguyên.
    try m.ai.save(provider: "compatible", baseUrl: "http://localhost:1234/v1", model: "qwen2")
    #expect(try m.keys.read(provider: "compatible") != nil)
    let st = try m.ai.status().first { $0.id == "compatible" }!
    #expect(st.configured && st.baseUrl == "http://localhost:1234/v1" && st.model == "qwen2")

    // Đổi sang máy chủ khác: khóa cũ không được gửi theo.
    try m.ai.save(provider: "compatible", baseUrl: "https://may-chu-moi.test/v1", model: nil)
    #expect(try m.keys.read(provider: "compatible") == nil)

    // Địa chỉ HTTP ra ngoài, có tên đăng nhập, hoặc đổi địa chỉ cố định đều bị từ chối/bỏ qua.
    #expect(throws: PVTAError.self) { try m.ai.save(provider: "compatible", baseUrl: "http://may-chu-ngoai.test/v1", model: nil) }
    #expect(throws: PVTAError.self) { try m.ai.save(provider: "compatible", baseUrl: "https://u:p@x.test/v1", model: nil) }
    try m.ai.save(provider: "commandcode", baseUrl: "https://ke-gian.test/v1", model: nil)
    #expect(try m.ai.status().first { $0.id == "commandcode" }!.baseUrl == "https://api.commandcode.ai/provider/v1")
    #expect(throws: PVTAError.self) { try m.ai.save(provider: "khong-co", baseUrl: nil, model: nil) }

    let config = try String(contentsOf: m.paths.config, encoding: .utf8)
    #expect(!config.contains("khoa-may-chu-rieng-777"))
}

@Test func goiQuaLoiLoiCuaNutKhacCoSuKienMucDungVaNhatKy() async throws {
    let paths = thuMuc(); defer { try? FileManager.default.removeItem(at: paths.home) }
    let keys = MemoryKeyStore()
    let mang = FakeTransport([.init(lines: anthropicOK)])
    let ai = AIClient(config: ConfigStore(paths: paths), keys: keys, transport: mang, retry: .none)
    let host = try await PVTANode.open(paths: paths, ai: ai)
    let client = try await PVTANode.open(paths: paths)
    let khoa = "sk-ant-LO-BI-MAT-\(UUID().uuidString)"

    // Chưa có khóa: trạng thái chưa cấu hình, hỏi thì báo lỗi.
    #expect(try await client.call("api.status").decode([ProviderStatus].self).first { $0.id == "anthropic" }?.configured == false)
    await #expect(throws: PVTAError.self) { try await client.call("ai.ask", ["model": "anthropic/claude-haiku-5-5", "prompt": "x"]) }

    try await client.call("api.saveKey", ["provider": "anthropic", "key": .string(khoa)])
    #expect(try await client.call("api.status").decode([ProviderStatus].self).first { $0.id == "anthropic" }?.configured == true)
    let ra = try await client.call("ai.ask", ["model": "anthropic/claude-haiku-5-5", "prompt": "Chào"])
    #expect(ra["text"]?.string == "Xin chào")
    #expect(ra["usage"]?["outputTokens"]?.number == 34)

    let tong = try await client.call("api.usage").decode([UsageTotal].self)
    #expect(tong.first?.model == "anthropic/claude-haiku-5-5")
    #expect(tong.first?.requests == 1 && tong.first?.inputTokens == 12)

    let nhatKy = try await client.call("activity.list").decode([Activity].self)
    #expect(nhatKy.contains { $0.kind == "ai.ask" && $0.state == .done && $0.model == "anthropic/claude-haiku-5-5" })
    #expect(nhatKy.contains { $0.kind == "ai.ask" && $0.state == .error })       // lần chưa có khóa

    // Khóa chỉ ở "Keychain" (kho giả): không có trong bất kỳ tệp nào của thư mục dữ liệu.
    let files = (try? FileManager.default.contentsOfDirectory(at: paths.home, includingPropertiesForKeys: nil)) ?? []
    for url in files {
        let data = (try? Data(contentsOf: url)) ?? Data()
        #expect(data.range(of: Data("LO-BI-MAT".utf8)) == nil)
    }
    await client.shutdown(); await host.shutdown()
}
