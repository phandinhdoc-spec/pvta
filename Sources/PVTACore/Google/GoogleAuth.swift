import Foundation
import CryptoKit
import Security

struct GoogleCredentials: Codable, Sendable {
    var access: String
    var refresh: String
    var expires: Double
    var subject: String
    var email: String
}
struct GoogleHTTPError: Error, Sendable { var status: Int }
struct GoogleReply: Sendable { var json: JSONValue; var headers: [String: String]; var bytes: Data }

actor GoogleAuth {
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/drive.file"
    let store: DataStore
    let keys: KeyStore
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    let open: @Sendable (URL) -> Void
    let notify: @Sendable () -> Void
    var generation = 0
    var listener: GoogleLoopback?
    var login: (state: String, verifier: String, redirect: String, expires: Date)?
    var refreshing: Task<GoogleCredentials, Error>?
    var lastError: String?
    init(store: DataStore, keys: KeyStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }, open: @escaping @Sendable (URL) -> Void, notify: @escaping @Sendable () -> Void = {}) {
        self.store = store; self.keys = keys; self.transport = transport; self.now = now; self.open = open; self.notify = notify
    }
    deinit { listener?.stop(); refreshing?.cancel() }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PVTAError("Không tạo được mã bảo vệ đăng nhập.") }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func form(_ fields: [String: String]) -> Data {
        var q = URLComponents(); q.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((q.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    func credentials() throws -> GoogleCredentials? {
        guard let raw = try keys.read(provider: "google-oauth") else { return nil }
        guard let c = try? JSONDecoder().decode(GoogleCredentials.self, from: Data(raw.utf8)) else { throw PVTAError("Thông tin đăng nhập Google không đọc được; hãy đăng nhập lại.") }; return c
    }
    func status() async throws -> JSONValue {
        let c = try credentials()
        return ["configured": .bool(try await store.setting("google.clientId") != nil), "connected": .bool(c != nil), "accountId": c.map { .string($0.subject) } ?? .null, "email": c.map { .string($0.email) } ?? .null, "loginPending": .bool(login.map { $0.expires > now() } ?? false), "error": lastError.map(JSONValue.string) ?? .null]
    }
    func configure(clientId: String, secret: String?) async throws {
        guard clientId.hasSuffix(".apps.googleusercontent.com"), clientId.count <= 300, !clientId.contains(where: \.isWhitespace) else { throw PVTAError("Cần OAuth client ID loại Desktop của Google.") }
        guard try credentials() == nil, listener == nil else { throw PVTAError("Hãy đăng xuất hoặc hủy đăng nhập trước khi đổi OAuth client.") }
        if let secret { guard !secret.isEmpty, secret.count <= 1000 else { throw PVTAError("Client secret không hợp lệ.") }; try keys.save(secret, provider: "google-client-secret") }
        else { try keys.delete(provider: "google-client-secret") }
        try await store.setSetting("google.clientId", clientId)
    }
    func begin(confirmed: Bool) async throws -> JSONValue {
        guard confirmed else { throw PVTAError("Cần xác nhận mở đăng nhập Google.") }
        guard let client = try await store.setting("google.clientId") else { throw PVTAError("Chưa cấu hình OAuth client Desktop của Google.") }
        guard try credentials() == nil else { throw PVTAError("Đã đăng nhập; hãy đăng xuất trước khi đổi tài khoản.") }
        cancelLogin(); generation += 1
        let state = try Self.random(), verifier = try Self.random()
        let receiver = try GoogleLoopback { [weak self] url in await self?.callback(url) ?? false }
        listener = receiver; login = (state, verifier, receiver.redirect, now().addingTimeInterval(600)); lastError = nil
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client, "redirect_uri": receiver.redirect, "response_type": "code", "scope": Self.scopes, "state": state, "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
        open(url.url!)
        // URL chỉ có state/challenge, không chứa code, verifier hoặc token.
        return ["authorizationURL": .string(url.url!.absoluteString), "expiresIn": 600]
    }
    func cancelLogin() { listener?.stop(); listener = nil; login = nil; generation += 1 }
    func callback(_ raw: String) async -> Bool {
        guard let pending = login, pending.expires > now(), let u = URLComponents(string: raw), let expected = URLComponents(string: pending.redirect),
              u.scheme == expected.scheme, u.host == expected.host, u.port == expected.port, u.path == expected.path else { return false }
        let items = u.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == pending.state else { return false }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 4096 else { cancelLogin(); lastError = "Google chưa cấp quyền đăng nhập."; notify(); return false }
        login = nil
        let epoch = generation
        do {
            guard let client = try await store.setting("google.clientId") else { throw PVTAError("Chưa cấu hình Google.") }
            var fields = ["client_id": client, "code": code, "code_verifier": pending.verifier, "redirect_uri": pending.redirect, "grant_type": "authorization_code"]
            if let secret = try keys.read(provider: "google-client-secret") { fields["client_secret"] = secret }
            let token = try await tokenRequest(fields)
            guard let access = token["access_token"]?.string, !access.isEmpty, let refresh = token["refresh_token"]?.string, !refresh.isEmpty,
                  let ttl = token["expires_in"]?.number, ttl > 0, ttl <= 86400,
                  let scope = token["scope"]?.string, Set(Self.scopes.split(separator: " ")).subtracting(["openid", "email"]).isSubset(of: Set(scope.split(separator: " "))) else { throw PVTAError("Chưa cấp đủ quyền Google hoặc thiếu refresh token; hãy đăng nhập lại.") }
            var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!); req.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            let reply = try await transport.download(req, limit: 100000)
            guard reply.status == 200, let user = try? JSONDecoder().decode(JSONValue.self, from: reply.body), let subject = user["sub"]?.string, !subject.isEmpty else { throw PVTAError("Không xác minh được tài khoản Google.") }
            guard epoch == generation else { return false }
            let c = GoogleCredentials(access: access, refresh: refresh, expires: now().timeIntervalSince1970 + ttl, subject: subject, email: user["email"]?.string ?? "")
            try keys.save(String(decoding: JSONEncoder().encode(c), as: UTF8.self), provider: "google-oauth")
            try await store.setSetting("google.activeOwner", subject)
            guard epoch == generation else { return false }
            lastError = nil; listener?.stop(); listener = nil; notify(); return true
        } catch { guard epoch == generation else { return false }; lastError = "Không hoàn tất đăng nhập Google. Kiểm tra cấu hình, quyền và kết nối rồi thử lại."; listener?.stop(); listener = nil; notify(); return false }
    }
    func tokenRequest(_ fields: [String: String]) async throws -> JSONValue {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); req.httpMethod = "POST"; req.httpBody = Self.form(fields)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let r: (status: Int, headers: [String: String], body: Data)
        do { r = try await transport.download(req, limit: 100000) }
        catch { throw PVTAError("Không kết nối được dịch vụ đăng nhập Google.") }
        guard r.status == 200, let json = try? JSONDecoder().decode(JSONValue.self, from: r.body) else { throw PVTAError("Google từ chối cấp hoặc làm mới phiên; hãy đăng nhập lại.") }; return json
    }
    func token(owner: String, force: Bool = false) async throws -> String {
        guard let old = try credentials(), old.subject == owner else { throw PVTAError("Tài khoản Google đã đổi hoặc đã đăng xuất.") }
        if !force && old.expires > now().timeIntervalSince1970 + 60 { return old.access }
        let epoch = generation
        if refreshing == nil {
            refreshing = Task {
                guard let client = try await self.store.setting("google.clientId") else { throw PVTAError("Chưa cấu hình Google.") }
                var fields = ["client_id": client, "refresh_token": old.refresh, "grant_type": "refresh_token"]
                if let secret = try self.keys.read(provider: "google-client-secret") { fields["client_secret"] = secret }
                let v = try await self.tokenRequest(fields)
                guard let access = v["access_token"]?.string, !access.isEmpty, let ttl = v["expires_in"]?.number, ttl > 0, ttl <= 86400 else { throw PVTAError("Google trả phiên không hợp lệ.") }
                return GoogleCredentials(access: access, refresh: v["refresh_token"]?.string ?? old.refresh, expires: self.now().timeIntervalSince1970 + ttl, subject: old.subject, email: old.email)
            }
        }
        defer { if epoch == generation { refreshing = nil } }
        let value = try await refreshing!.value
        guard epoch == generation, try credentials()?.subject == owner else { throw PVTAError("Phiên đăng nhập đã đổi.") }
        try keys.save(String(decoding: JSONEncoder().encode(value), as: UTF8.self), provider: "google-oauth")
        return value.access
    }
    func request(owner: String, url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json", etag: String? = nil) async throws -> GoogleReply {
        guard url.scheme == "https", ["www.googleapis.com", "tasks.googleapis.com"].contains(url.host ?? "") else { throw PVTAError("Địa chỉ Google API không được phép.") }
        let epoch = generation
        for attempt in 0..<2 {
            let access = try await token(owner: owner, force: attempt == 1)
            guard epoch == generation else { throw PVTAError("Phiên Google đã đổi.") }
            var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body
            req.setValue("Bearer " + access, forHTTPHeaderField: "Authorization"); req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if let etag { req.setValue(etag, forHTTPHeaderField: "If-Match") }
            let response: (status: Int, headers: [String: String], body: Data)
            do { response = try await transport.download(req, limit: 4 * 1024 * 1024) }
            catch { throw PVTAError("Không kết nối được Google; thay đổi cục bộ vẫn được giữ.") }
            try Task.checkCancellation()
            guard epoch == generation, try credentials()?.subject == owner else { throw PVTAError("Tài khoản Google đã đổi; bỏ kết quả từ phiên cũ.") }
            if response.status == 401 && attempt == 0 { continue }
            guard (200..<300).contains(response.status) else { throw GoogleHTTPError(status: response.status) }
            return GoogleReply(json: (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? .null, headers: response.headers, bytes: response.body)
        }
        throw PVTAError("Phiên Google hết hạn; hãy đăng nhập lại.")
    }
    func logout() async throws {
        cancelLogin(); refreshing?.cancel(); refreshing = nil
        try keys.delete(provider: "google-oauth")
        try await store.setSetting("google.activeOwner", "")
        lastError = nil; notify()
    }
}
