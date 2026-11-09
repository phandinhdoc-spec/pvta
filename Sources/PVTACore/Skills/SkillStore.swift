import Foundation

public struct SkillBackup: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
}

public struct SkillBackupPreview: Codable, Sendable, Equatable {
    public var revision: String
    public var backupRevision: String
    public var changedLines: Int
    public var backupText: String
}

public struct SkillCandidate: Codable, Sendable, Equatable {
    public var key: String           // đường dẫn tương đối trong nguồn
    public var name: String
    public var description: String
    public var issues: [SkillIssue]
    public var installable: Bool
}

/// Thư mục skill của người dùng: mỗi skill là một thư mục có SKILL.md. Dùng chung cho mọi model.
/// Bật/tắt nằm ở `.state.json`, nguồn cài ở `.registry.json`, bản sao lưu ở `.edit-backups/<tên>/`.
public actor SkillStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    static let backupLimit = 20
    static let fileLimit = 200_000, filesPerSkill = 30, candidateLimit = 100

    let dir: URL
    let packs: URL

    /// Thư mục chứa skill của người dùng (dùng bởi MySoftImporter).
    public var skillsDirectory: URL { dir }
    let fetch: Fetch?
    private let fm = FileManager.default
    private var bundledPending: Bool

    /// `bundled`: tự cài skill đi kèm PVTA ở lần dùng đầu tiên.
    public init(home: URL, fetch: Fetch? = nil, bundled: Bool = true) {
        bundledPending = bundled
        dir = home.appendingPathComponent("skills", isDirectory: true)
        packs = home.appendingPathComponent("groups", isDirectory: true)
        self.fetch = fetch
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Trạng thái nhỏ trong thư mục skill

    private func readJSON<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func writeJSON<T: Encodable>(_ name: String, _ value: T) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileService.atomicWrite(try enc.encode(value), to: dir.appendingPathComponent(name).path)
    }

    private struct State: Codable { var disabled: [String] = [] }
    struct RegistryEntry: Codable, Equatable { var source: String; var hash: String; var installedAt: Date }

    private func registry() -> [String: RegistryEntry] { readJSON(".registry.json", [String: RegistryEntry].self) ?? [:] }
    private func bundledRecord() -> [String: String] { readJSON(".bundled.json", [String: String].self) ?? [:] }

    // MARK: Liệt kê

    private func tier(_ name: String, pack: Bool) -> (SkillTier, String?) {
        if pack { return (.pack, nil) }
        if bundledRecord()[name] != nil { return (.system, nil) }
        if let r = registry()[name] { return (r.source.hasPrefix("https://github.com/") ? .github : .imported, r.source) }
        return (name.hasPrefix("learned-") ? .learned : .own, nil)
    }

    private func load(dir skillDir: URL, name: String, pack groupId: String?, disabled: Set<String>) -> Skill? {
        guard let md = try? String(contentsOf: skillDir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        let p = SkillText.parse(md)
        guard name.range(of: SkillText.nameRegex, options: .regularExpression) != nil else { return nil }
        let (t, source) = tier(name, pack: groupId != nil)
        var mode = p.meta["load"].flatMap(LoadMode.init) ?? .demand
        if groupId != nil && mode == .always { mode = .demand }   // gói chia sẻ không được tự chen vào mọi lượt
        return Skill(name: name, description: p.meta["description"] ?? "", load: mode,
                     groups: groupId.map { [$0] } ?? SkillText.groups(p.meta["groups"]), body: p.body, tier: t, source: source,
                     enabled: !disabled.contains(name) && p.meta["load"] != "off", revision: SkillText.revision(md))
    }

    /// Mọi skill: của người dùng và của gói nhóm. Tên trùng thì skill của người dùng thắng.
    public func list() -> [Skill] {
        if bundledPending { bundledPending = false; _ = try? installBundled() }
        let disabled = Set(readJSON(".state.json", State.self)?.disabled ?? [])
        var out: [Skill] = []
        for u in subdirectories(dir) {
            if let s = load(dir: u, name: u.lastPathComponent, pack: nil, disabled: disabled) { out.append(s) }
        }
        let own = Set(out.map(\.name))
        for g in subdirectories(packs) {
            for u in subdirectories(g.appendingPathComponent("skills", isDirectory: true)) {
                guard !own.contains(u.lastPathComponent), let s = load(dir: u, name: u.lastPathComponent, pack: g.lastPathComponent, disabled: disabled) else { continue }
                out.append(s)
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private func subdirectories(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    public func skill(_ name: String) -> Skill? { list().first { $0.name == name } }

    // MARK: Bật, tắt

    public func setEnabled(_ name: String, _ on: Bool) throws {
        guard skill(name) != nil else { throw PVTAError("Không tìm thấy skill “\(name)”.") }
        var s = readJSON(".state.json", State.self) ?? State()
        s.disabled.removeAll { $0 == name }
        if !on { s.disabled.append(name) }
        try writeJSON(".state.json", s)
    }

    // MARK: Skill đi kèm

    /// Cài skill đi kèm. Bản mới hơn thay bản đã cài nếu thầy cô CHƯA sửa (so mã băm đã ghi); đã sửa thì giữ nguyên. Bản cũ được sao lưu.
    @discardableResult
    public func installBundled(_ custom: [(name: String, text: String)]? = nil) throws -> [String] {
        let items = custom ?? BundledSkills.all
        var record = bundledRecord(), installed: [String] = []
        for (name, text) in items {
            let target = dir.appendingPathComponent(name, isDirectory: true), file = target.appendingPathComponent("SKILL.md")
            let hash = SkillText.revision(text + "\n")
            if let current = try? String(contentsOfFile: file.path, encoding: .utf8) {
                let cur = SkillText.revision(current)
                if cur == hash { record[name] = hash; continue }
                if record[name] != cur { continue }   // thầy cô đã sửa: không ghi đè
                _ = try snapshot(name, current)
            }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try FileService.atomicWrite(Data((text + "\n").utf8), to: file.path)
            record[name] = hash
            installed.append(name)
        }
        try writeJSON(".bundled.json", record)
        return installed
    }

    // MARK: Chính sách theo nguồn

    private func requireManage(_ s: Skill, _ action: String, internalCall: Bool) throws {
        if s.tier == .pack { throw PVTAError("Skill thuộc gói nhóm; hãy quản lý ở phần Nhóm.") }
        if s.tier == .learned && !internalCall { throw PVTAError("Skill PVTA tự học chỉ được \(action) trong “Những điều đã học”, nơi thầy cô xem nguồn và duyệt.") }
    }

    // MARK: Tạo, sửa, xóa

    private func fileURL(_ name: String) -> URL { dir.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md") }

    /// Tạo skill mới từ nội dung SKILL.md. Sai chuẩn thì từ chối kèm lý do.
    @discardableResult
    public func create(_ md: String, owner: String = "user") throws -> Skill {
        let issues = SkillText.check(md, owner: owner, full: true)
        let errors = issues.filter { $0.level == "error" }
        if !errors.isEmpty { throw PVTAError("Skill chưa đạt chuẩn: " + errors.map(\.message).joined(separator: " ")) }
        let name = SkillText.parse(md).meta["name"]!
        guard !fm.fileExists(atPath: dir.appendingPathComponent(name).path), skill(name) == nil else { throw PVTAError("Đã có skill tên “\(name)”.") }
        try fm.createDirectory(at: dir.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        try FileService.atomicWrite(Data(md.utf8), to: fileURL(name).path, exclusive: true)
        return skill(name)!
    }

    /// Mở để sửa: trả nội dung và mã bản hiện tại.
    public func beginEdit(_ name: String) throws -> (text: String, revision: String) {
        guard let s = skill(name) else { throw PVTAError("Không tìm thấy skill “\(name)”.") }
        try requireManage(s, "sửa", internalCall: false)
        let text = try String(contentsOf: fileURL(name), encoding: .utf8)
        return (text, SkillText.revision(text))
    }

    /// Lưu bản sửa. Phải kèm mã bản đã mở; skill đã đổi bởi nơi khác thì từ chối. Bản cũ được sao lưu trước khi ghi.
    @discardableResult
    public func saveEdit(_ name: String, text: String, revision: String, internalCall: Bool = false) throws -> Skill {
        guard let s = skill(name) else { throw PVTAError("Không tìm thấy skill “\(name)”.") }
        try requireManage(s, "sửa", internalCall: internalCall)
        let owner = s.tier == .system || s.tier == .learned || s.tier == .github || s.tier == .imported ? "system" : "user"
        let issues = SkillText.check(text, owner: owner, full: s.tier == .own || s.tier == .learned, directory: name)
        let errors = issues.filter { $0.level == "error" }
        if !errors.isEmpty { throw PVTAError("Skill chưa đạt chuẩn: " + errors.map(\.message).joined(separator: " ")) }
        let current = try String(contentsOf: fileURL(name), encoding: .utf8)
        guard SkillText.revision(current) == revision else { throw PVTAError("Skill đã thay đổi ở nơi khác. Hãy mở lại để sửa.") }
        if current != text { _ = try snapshot(name, current) }
        try FileService.atomicWrite(Data(text.utf8), to: fileURL(name).path)
        return skill(name)!
    }

    /// Xóa skill: bản cuối được sao lưu để khôi phục được. Skill đi kèm PVTA không xóa (hãy tắt đi).
    public func delete(_ name: String, internalCall: Bool = false) throws {
        guard let s = skill(name) else { throw PVTAError("Không tìm thấy skill “\(name)”.") }
        try requireManage(s, "xóa", internalCall: internalCall)
        if s.tier == .system { throw PVTAError("Skill đi kèm PVTA không xóa được; hãy tắt nếu không dùng.") }
        let text = try String(contentsOf: fileURL(name), encoding: .utf8)
        _ = try snapshot(name, text)
        try fm.removeItem(at: dir.appendingPathComponent(name, isDirectory: true))
        var reg = registry(); reg[name] = nil
        try writeJSON(".registry.json", reg)
        var st = readJSON(".state.json", State.self) ?? State(); st.disabled.removeAll { $0 == name }
        try writeJSON(".state.json", st)
    }

    // MARK: Sao lưu và khôi phục

    private func backupDir(_ name: String) -> URL { dir.appendingPathComponent(".edit-backups", isDirectory: true).appendingPathComponent(name, isDirectory: true) }

    private func snapshot(_ name: String, _ text: String) throws -> String {
        guard name.range(of: SkillText.nameRegex, options: .regularExpression) != nil else { throw PVTAError("Tên skill không hợp lệ.") }
        let d = backupDir(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = String(Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.prefix(8).lowercased()
        try Data(text.utf8).write(to: d.appendingPathComponent(id + ".md"), options: .withoutOverwriting)
        let old = ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted().dropLast(Self.backupLimit)
        for f in old { try? fm.removeItem(at: d.appendingPathComponent(f)) }
        return id
    }

    public func backups(_ name: String) -> [SkillBackup] {
        guard name.range(of: SkillText.nameRegex, options: .regularExpression) != nil else { return [] }
        return ((try? fm.contentsOfDirectory(atPath: backupDir(name).path)) ?? []).filter { $0.hasSuffix(".md") }.sorted(by: >).map { f in
            let id = String(f.dropLast(3))
            return SkillBackup(id: id, createdAt: Date(timeIntervalSince1970: (Double(id.split(separator: "-").first ?? "0") ?? 0) / 1000))
        }
    }

    private func backupText(_ name: String, _ id: String) throws -> String {
        guard id.range(of: #"^\d+-[0-9a-f]{8}$"#, options: .regularExpression) != nil,
              let t = try? String(contentsOf: backupDir(name).appendingPathComponent(id + ".md"), encoding: .utf8) else { throw PVTAError("Không tìm thấy bản sao lưu này.") }
        return t
    }

    public func previewBackup(_ name: String, id: String) throws -> SkillBackupPreview {
        let old = try backupText(name, id)
        let cur = skill(name) != nil ? try String(contentsOf: fileURL(name), encoding: .utf8) : ""
        let a = cur.components(separatedBy: "\n"), b = old.components(separatedBy: "\n")
        let changed = (0..<max(a.count, b.count)).filter { ($0 < a.count ? a[$0] : nil) != ($0 < b.count ? b[$0] : nil) }.count
        return SkillBackupPreview(revision: skill(name) == nil ? "" : SkillText.revision(cur), backupRevision: SkillText.revision(old), changedLines: changed, backupText: old)
    }

    /// Khôi phục một bản sao lưu (kể cả skill đã xóa). Phải kèm mã bản hiện tại và mã bản sao lưu lúc xem trước.
    @discardableResult
    public func restoreBackup(_ name: String, id: String, revision: String, backupRevision: String) throws -> Skill {
        let old = try backupText(name, id)
        guard SkillText.revision(old) == backupRevision else { throw PVTAError("Bản sao lưu đã thay đổi; hãy xem trước lại.") }
        if let s = skill(name) {
            try requireManage(s, "khôi phục", internalCall: false)
            let cur = try String(contentsOf: fileURL(name), encoding: .utf8)
            guard SkillText.revision(cur) == revision else { throw PVTAError("Skill đã thay đổi; hãy xem trước lại.") }
            _ = try snapshot(name, cur)
            try FileService.atomicWrite(Data(old.utf8), to: fileURL(name).path)
        } else {
            guard revision.isEmpty else { throw PVTAError("Skill đã thay đổi; hãy xem trước lại.") }
            try fm.createDirectory(at: dir.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
            try FileService.atomicWrite(Data(old.utf8), to: fileURL(name).path, exclusive: true)
        }
        return skill(name)!
    }

    // MARK: Quét và cài từ thư mục hoặc GitHub

    /// Đường dẫn tương đối (so với `root`) của các thư mục có SKILL.md; "" là chính `root`.
    private func findSkillDirs(_ root: URL, rel: String = "", depth: Int = 0) -> [String] {
        let here = rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
        var out: [String] = []
        if fm.fileExists(atPath: here.appendingPathComponent("SKILL.md").path) { out.append(rel) }
        guard depth < 4 else { return out }
        for u in subdirectories(here) where out.count < Self.candidateLimit {
            out += findSkillDirs(root, rel: rel.isEmpty ? u.lastPathComponent : rel + "/" + u.lastPathComponent, depth: depth + 1)
        }
        return out
    }

    /// Quét thư mục: các thư mục con có SKILL.md, kèm kết quả kiểm chuẩn. Chưa ghi gì.
    public func scan(directory: URL) throws -> [SkillCandidate] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { throw PVTAError("Không tìm thấy thư mục cần quét.") }
        return findSkillDirs(directory).compactMap { rel -> SkillCandidate? in
            let u = rel.isEmpty ? directory : directory.appendingPathComponent(rel, isDirectory: true)
            guard let md = try? String(contentsOf: u.appendingPathComponent("SKILL.md"), encoding: .utf8), md.utf8.count <= Self.fileLimit else { return nil }
            let p = SkillText.parse(md)
            let issues = SkillText.check(md, owner: "imported", full: false)
            return SkillCandidate(key: rel, name: p.meta["name"] ?? u.lastPathComponent, description: p.meta["description"] ?? "", issues: issues,
                                  installable: !issues.contains { $0.level == "error" })
        }.sorted { $0.key < $1.key }
    }

    private func importedName(_ raw: String) -> String {
        let n = Fold.text(raw).replacingOccurrences(of: "claude|anthropic", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var name = String(n.prefix(SkillText.maxName)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "skill-moi" }
        if SkillText.reserved.contains(where: { name.hasPrefix($0) }) { name = "ext-" + name }
        return name
    }

    /// Cài các skill được chọn (theo `key` của lần quét). Skill nhập vào luôn ở chế độ manual và bị bỏ dòng groups,
    /// nên không tự chen vào ngữ cảnh. Tên trùng bị từ chối. Chỉ chép SKILL.md và tệp chữ nhỏ đi kèm.
    @discardableResult
    public func install(from directory: URL, keys: [String], source: String) throws -> [Skill] {
        let root = directory
        let candidates = try scan(directory: root)
        var installed: [String] = []
        var reg = registry()
        for key in keys {
            guard let c = candidates.first(where: { $0.key == key }) else { throw PVTAError("Không có skill “\(key)” trong nguồn đã quét.") }
            guard c.installable else { throw PVTAError("Không cài “\(c.name)”: " + c.issues.filter { $0.level == "error" }.map(\.message).joined(separator: " ")) }
            let src = key.isEmpty ? root : root.appendingPathComponent(key, isDirectory: true)
            let name = importedName(c.name)
            guard skill(name) == nil, !fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { throw PVTAError("Đã có skill tên “\(name)”. Hãy xóa hoặc đổi tên trước.") }
            let md = try String(contentsOf: src.appendingPathComponent("SKILL.md"), encoding: .utf8)
            let p = SkillText.parse(md)
            let text = SkillText.compose(name: name, description: SkillText.fitDescription(p.meta["description"] ?? ""), load: .manual, groups: [], body: p.body)
            let target = dir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try FileService.atomicWrite(Data(text.utf8), to: target.appendingPathComponent("SKILL.md").path, exclusive: true)
            var count = 0
            for f in ((try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []) {
                let ext = f.pathExtension.lowercased()
                guard f.lastPathComponent != "SKILL.md", ["md", "txt", "json", "csv"].contains(ext), count < Self.filesPerSkill,
                      let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true, (v.fileSize ?? 0) <= Self.fileLimit else { continue }
                try fm.copyItem(at: f, to: target.appendingPathComponent(f.lastPathComponent))
                count += 1
            }
            reg[name] = RegistryEntry(source: source, hash: SkillText.revision(text), installedAt: Date())
            installed.append(name)
        }
        try writeJSON(".registry.json", reg)
        return installed.compactMap { skill($0) }
    }

    // MARK: GitHub

    static func githubURL(repo: String, ref: String?) throws -> URL {
        guard repo.range(of: #"^[A-Za-z0-9_.-]{1,39}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil, !repo.contains("..") else {
            throw PVTAError("Kho GitHub cần có dạng chủ-kho/tên-kho, ví dụ phandinhdoc-spec/skills.")
        }
        if let ref, ref.range(of: #"^[A-Za-z0-9_./-]{1,100}$"#, options: .regularExpression) == nil || ref.contains("..") { throw PVTAError("Tên nhánh không hợp lệ.") }
        return URL(string: "https://codeload.github.com/\(repo)/zip/" + (ref.map { "refs/heads/\($0)" } ?? "HEAD"))!
    }

    /// Tải kho về thư mục tạm riêng và quét. Cần mạng; chỉ chạy khi thầy cô yêu cầu.
    public func scanGitHub(repo: String, ref: String?) async throws -> (directory: URL, candidates: [SkillCandidate]) {
        guard let fetch else { throw PVTAError("Chưa có kết nối mạng cho việc tải từ GitHub.") }
        let data: Data
        do { data = try await fetch(try Self.githubURL(repo: repo, ref: ref)) } catch let e as PVTAError { throw e } catch {
            throw PVTAError("Không tải được kho GitHub “\(repo)”. Hãy kiểm tra mạng và tên kho.")
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("pvta-skill-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try Self.extract(data, to: tmp)
            return (tmp, try scan(directory: tmp))
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Giải nén an toàn: không đường dẫn tuyệt đối hay “..”, chỉ tệp chữ, giới hạn số tệp và dung lượng.
    static func extract(_ data: Data, to dest: URL) throws {
        let zip = try ZipArchive(data: data)
        guard zip.names.count <= 5000 else { throw PVTAError("Kho có quá nhiều tệp.") }
        var total = 0
        for name in zip.names where !name.hasSuffix("/") {
            let parts = name.split(separator: "/").map(String.init)
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["md", "txt", "json", "csv"].contains(ext), let content = try zip.read(name), content.count <= fileLimit else { continue }
            total += content.count
            guard total <= 30 * 1024 * 1024 else { throw PVTAError("Kho quá lớn.") }
            // Bỏ thư mục gốc kiểu “ten-kho-main/”.
            let rel = parts.dropFirst().joined(separator: "/")
            guard !rel.isEmpty else { continue }
            let target = dest.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, options: .withoutOverwriting)
        }
    }

    /// SKILL.md và tệp chữ nhỏ đi kèm (đường dẫn tương đối → nội dung), dùng khi đóng gói nhóm.
    func files(of name: String) -> [String: Data] {
        guard let s = skill(name) else { return [:] }
        let d = s.tier == .pack ? (subdirectories(packs).map { $0.appendingPathComponent("skills/\(name)") }.first { fm.fileExists(atPath: $0.path) } ?? dir) : dir.appendingPathComponent(name)
        var out: [String: Data] = [:]
        for f in ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []) where out.count < Self.filesPerSkill {
            guard ["md", "txt", "json", "csv"].contains(f.pathExtension.lowercased()), let data = try? Data(contentsOf: f), data.count <= Self.fileLimit else { continue }
            out[f.lastPathComponent] = data
        }
        return out
    }

    public func discardTemporary(_ url: URL) { if url.path.contains("/pvta-skill-") { try? fm.removeItem(at: url) } }

    // MARK: Cho phần tự học

    /// Ghi (tạo mới hoặc thay) skill tự học đã được duyệt. Chỉ phần tự học gọi.
    func writeLearned(name: String, md: String) throws {
        guard name.hasPrefix("learned-") else { throw PVTAError("Skill tự học phải có tên bắt đầu bằng learned-.") }
        let errors = SkillText.check(md, owner: "system", full: false, directory: name).filter { $0.level == "error" }
        if !errors.isEmpty { throw PVTAError("Skill tự học chưa đạt chuẩn: " + errors.map(\.message).joined(separator: " ")) }
        if let cur = try? String(contentsOf: fileURL(name), encoding: .utf8) { if cur != md { _ = try snapshot(name, cur) } }
        try fm.createDirectory(at: dir.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        try FileService.atomicWrite(Data(md.utf8), to: fileURL(name).path)
    }
}
