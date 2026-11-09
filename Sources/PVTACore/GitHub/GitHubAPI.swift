import Foundation

struct GitHubCredential: Codable, Sendable { var token: String; var account: String; var userId: Int }
struct GitHubAPI: Sendable {
    let transport: HTTPTransport
    let token: String
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, query: [String: String] = [:]) async throws -> JSONValue {
        guard path.hasPrefix("/"), !path.contains("?") else { throw PVTAError("Địa chỉ GitHub không hợp lệ.") }
        var u = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { u.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: u.url!); r.httpMethod = method; r.timeoutInterval = 60
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("PVTA", forHTTPHeaderField: "User-Agent")
        r.httpBody = try body.map { try JSONEncoder().encode($0) }
        let response: (status: Int, headers: [String: String], body: Data)
        do { response = try await transport.download(r, limit: 32 * 1024 * 1024) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PVTAError("Không nhận được kết quả GitHub. Nếu đang ghi, cần kiểm tra kho trước khi thử lại.") }
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else { throw PVTAError("GitHub trả mã \(response.status). Kiểm tra phiên đăng nhập, quyền kho và nhánh trước khi thử lại.") }
        if response.status == 204 { return .null }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw PVTAError("Phản hồi GitHub không đọc được.") }; return value
    }
    func head(_ link: GitHubLink) async throws -> (String, String) {
        let base = "/repos/" + link.repository
        let ref = try await request(base + "/git/ref/heads/" + GitHubInput.segment(link.branch))
        let head = try GitHubInput.sha(ref["object"]?["sha"])
        let commit = try await request(base + "/git/commits/" + head)
        return (head, try GitHubInput.sha(commit["tree"]?["sha"]))
    }
    func tree(_ link: GitHubLink, sha: String) async throws -> [GitHubFile] {
        let result = try await request("/repos/" + link.repository + "/git/trees/" + sha, query: ["recursive": "1"])
        guard result["truncated"]?.bool == false, case .array(let entries)? = result["tree"], entries.count <= 100000 else { throw PVTAError("Cây kho GitHub bị cắt ngắn hoặc không hợp lệ; chưa chuyển tệp.") }
        return try entries.filter { $0["type"]?.string != "tree" }.map { e in
            let p = try GitHubInput.path(e.requireString("path"))
            return GitHubFile(path: p, sha: try GitHubInput.sha(e["sha"]), size: try CalendarValidation.integer(e["size"] ?? 0, name: "Kích thước tệp", maximum: Int(Int32.max)), mode: e["mode"]?.string ?? "")
        }
    }
}
