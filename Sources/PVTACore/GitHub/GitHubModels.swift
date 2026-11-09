import Foundation

struct GitHubLink: Codable, Sendable, Equatable {
    var projectId: String
    var folder: String
    var repository: String
    var branch: String
}
struct GitHubFile: Codable, Sendable, Equatable {
    var path: String
    var sha: String
    var size: Int
    var mode: String
}
struct GitHubPreview: Codable, Sendable {
    var id: String
    var operation: String
    var link: GitHubLink
    var head: String
    var tree: String
    var files: [GitHubFile]
    var sources: [String]
    var destination: String?
    var message: String
    var newBranch: String?
    var expiresAt: Double
    var confirmation: String
}
struct GitHubJournal: Codable, Sendable {
    var id: String
    var requestId: String
    var previewId: String
    var projectId: String
    var operation: String
    var repository: String
    var branch: String
    var state = "running"
    var effects = "none"
    var steps: [String] = []
    var files: [String] = []
    var commit: String?
    var message: String?
    var startedAt: Double
    var finishedAt: Double?
}
struct GitHubState: Codable, Sendable {
    var links: [String: GitHubLink] = [:]
    var journal: [GitHubJournal] = []
}
extension DataStore {
    func githubState() throws -> GitHubState {
        guard let raw = try setting("github.v1") else { return GitHubState() }
        guard let state = try? JSONDecoder().decode(GitHubState.self, from: Data(raw.utf8)) else { throw PVTAError("Không đọc được kho GitHub; không chạy thao tác mới.") }; return state
    }
    func githubSave(_ state: GitHubState) throws { try setSetting("github.v1", String(decoding: JSONEncoder().encode(state), as: UTF8.self)) }
    func githubLink(_ link: GitHubLink) throws {
        guard try projects().contains(where: { $0.id == link.projectId }) else { throw PVTAError("Dự án không tồn tại.") }
        var state = try githubState(); state.links[link.projectId] = link; try githubSave(state)
    }
    func githubRecord(_ row: GitHubJournal) throws {
        var state = try githubState()
        if let i = state.journal.firstIndex(where: { $0.id == row.id }) { state.journal[i] = row }
        else { state.journal.append(row) }
        try githubSave(state)
    }
}

enum GitHubInput {
    static func repository(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
              ![".", ".."].contains(String(value.split(separator: "/").last!)), !value.contains("ghp_"), !value.contains("github_pat_") else { throw PVTAError("Kho GitHub phải có dạng chủ/tên-kho, không kèm URL hoặc token.") }; return value
    }
    static func branch(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 200, value != "@", !value.hasPrefix("-"), !value.contains(".."), !value.contains("@{"),
              !value.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true || "~^:?*[\\".contains($0) }),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock") }) else { throw PVTAError("Tên nhánh GitHub không hợp lệ.") }; return value
    }
    static func path(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 4096, !value.hasPrefix("/"), !value.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } == true || "\\:".contains($0) }),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw PVTAError("Đường dẫn phải tương đối trong kho; không nhận .git, dấu .. hoặc liên kết.") }; return value
    }
    static func sha(_ value: JSONValue?) throws -> String {
        guard let s = value?.string, s.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw PVTAError("GitHub chưa trả mã phiên bản hợp lệ.") }; return s
    }
    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
