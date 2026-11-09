import Foundation

public struct PackPreview: Codable, Sendable, Equatable {
    public var ok: Bool
    public var problems: [String]
    public var warnings: [String]
    public var manifest: GroupManifest?
    public var skills: [String]
    public var sourceCount: Int
    public var hasRules: Bool
    public var installedVersion: String?
}

/// Gói nhóm chia sẻ `.pvtagroup`: tệp nén gồm group.json, skills/, rules.md, sources.csv và checksums.json. Không kèm kho văn bản.
/// Mã băm chỉ bảo đảm tệp không hỏng, không chứng minh tác giả là ai: gói nhập về luôn ở mức “đồng nghiệp chia sẻ”
/// và chỉ có tác dụng sau khi thầy cô xem tác giả, phiên bản rồi tự chọn nhóm.
extension GroupService {
    static let packExtension = ".pvtagroup"
    static let packLimits = (files: 300, fileBytes: 200_000, totalBytes: 4_000_000)
    static let idRegex = "^[a-z0-9][a-z0-9-]{0,40}$"

    private static func checksums(_ files: [String: Data]) -> Data {
        let entries = files.keys.filter { $0 != "checksums.json" }.sorted().map { ($0, Fingerprint.of(files[$0]!.base64EncodedString())) }
        let pack = Fingerprint.of(entries.map { "\($0.0):\($0.1)" }.joined(separator: "\n"))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? enc.encode(["version": "1", "pack": pack, "files": entries.map { "\($0.0)=\($0.1)" }.joined(separator: ";")])) ?? Data()
    }

    /// Đóng gói một nhóm: các skill thuộc nhóm (và tệp chữ nhỏ đi kèm), rules.md, sources.csv nếu có.
    /// `asId`/`name` cho phép chia sẻ một nhóm có sẵn dưới mã mới (mã nhóm có sẵn không nhập lại được).
    public func exportPack(_ id: String, asId: String? = nil, name: String? = nil, author: String? = nil) async throws -> Data {
        guard var m = manifest(id) else { throw PVTAError("Không có nhóm “\(id)”.") }
        if let asId {
            guard asId.range(of: Self.idRegex, options: .regularExpression) != nil else { throw PVTAError("Mã nhóm mới không hợp lệ (chữ thường, số, gạch nối).") }
            m.id = asId
        }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { m.name = String(name.trimmingCharacters(in: .whitespaces).prefix(80)) }
        if let author, !author.trimmingCharacters(in: .whitespaces).isEmpty { m.author = String(author.trimmingCharacters(in: .whitespaces).prefix(80)) }
        var files: [String: Data] = [:]
        var names: [String] = []
        for s in await skills.list() where s.groups.contains(id) {
            for (rel, data) in await skills.files(of: s.name) { files["skills/\(s.name)/\(rel)"] = data }
            names.append(s.name)
        }
        let dir = groupsDir.appendingPathComponent(id, isDirectory: true)
        for f in ["rules.md", "sources.csv"] { if let d = try? Data(contentsOf: dir.appendingPathComponent(f)), d.count <= Self.packLimits.fileBytes { files[f] = d } }
        m.skills = names.sorted()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        files["group.json"] = try enc.encode(m)
        files["checksums.json"] = Self.checksums(files)
        var z = ZipWriter()
        for k in files.keys.sorted() { z.add(k, files[k]!) }
        return z.finish()
    }

    private func cleanManifest(_ d: Data, _ problems: inout [String]) -> GroupManifest? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { problems.append("group.json không hợp lệ."); return nil }
        func str(_ k: String, _ max: Int) -> String { String(((o[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }
        func list(_ k: String, _ max: Int, _ each: Int) -> [String] {
            Array(((o[k] as? [Any]) ?? []).compactMap { $0 as? String }.map { String($0.trimmingCharacters(in: .whitespaces).prefix(each)) }.filter { !$0.isEmpty }.prefix(max))
        }
        let id = str("id", 41), name = str("name", 80), version = str("version", 20), author = str("author", 80)
        if id.range(of: Self.idRegex, options: .regularExpression) == nil { problems.append("Mã nhóm không hợp lệ (chỉ chữ thường, số, dấu gạch).") }
        if name.isEmpty { problems.append("Thiếu tên nhóm.") }
        guard let kind = GroupKind(rawValue: str("kind", 20)) else { problems.append("Loại nhóm không hợp lệ."); return nil }
        if version.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) == nil { problems.append("Phiên bản phải có dạng 1.0 hoặc 1.0.0.") }
        if author.isEmpty { problems.append("Thiếu tên tác giả.") }
        let domains = list("domains", 30, 80).map { $0.lowercased() }
        for dmn in domains where dmn.range(of: #"^(?:[a-z0-9-]+\.)+[a-z]{2,}$"#, options: .regularExpression) == nil { problems.append("Tên miền không hợp lệ: \(dmn)") }
        let feeds = list("feeds", 10, 300)
        for f in feeds where !f.lowercased().hasPrefix("https://") { problems.append("Nguồn tin phải là https: \(f)") }
        guard problems.isEmpty else { return nil }
        return GroupManifest(id: id, name: name, kind: kind, version: version, author: author, tier: .dongNghiep, description: str("description", 400).isEmpty ? nil : str("description", 400),
                             skills: list("skills", 80, 64).filter { $0.range(of: SkillText.nameRegex, options: .regularExpression) != nil }, domains: domains,
                             feeds: feeds.isEmpty ? nil : feeds, keywords: list("keywords", 60, 40),
                             related: list("related", 20, 41).filter { $0.range(of: Self.idRegex, options: .regularExpression) != nil })
    }

    /// Kiểm tra gói, chưa ghi gì ra đĩa: đường dẫn, dung lượng, loại tệp, mã băm, cấu trúc và độ an toàn của từng skill.
    public func previewPack(_ data: Data) -> PackPreview {
        var res = PackPreview(ok: false, problems: [], warnings: [], manifest: nil, skills: [], sourceCount: 0, hasRules: false, installedVersion: nil)
        guard let (files, _) = unpack(data, &res.problems) else { return res }
        res.manifest = cleanManifest(files["group.json"] ?? Data(), &res.problems)
        res.hasRules = files["rules.md"] != nil
        res.sourceCount = max(0, (String(decoding: files["sources.csv"] ?? Data(), as: UTF8.self).split(separator: "\n").count) - 1)
        var seen = Set<String>()
        for (path, d) in files where path.hasPrefix("skills/") && path.hasSuffix("/SKILL.md") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[1].range(of: SkillText.nameRegex, options: .regularExpression) != nil else { res.problems.append("Thư mục skill không hợp lệ: \(path)"); continue }
            let issues = SkillText.check(String(decoding: d, as: UTF8.self), owner: "imported", full: false, directory: parts[1]).filter { $0.level == "error" }
            if !issues.isEmpty { res.problems.append("Skill “\(parts[1])” sai chuẩn: " + issues.map(\.message).joined(separator: " ")) }
            seen.insert(parts[1])
        }
        res.skills = seen.sorted()
        if let m = res.manifest {
            if GroupCatalog.builtin.contains(where: { $0.id == m.id }) { res.problems.append("Mã nhóm “\(m.id)” trùng một nhóm có sẵn; hãy đổi mã nhóm trong gói.") }
            if let have = catalog().first(where: { $0.id == m.id && $0.tier != .chinhThuc }) {
                res.installedVersion = have.version
                if Self.versionKey(m.version) <= Self.versionKey(have.version) { res.warnings.append("Máy đã có phiên bản \(have.version); gói này là \(m.version), không mới hơn.") }
            }
            let declared = Set(m.skills)
            if declared != seen { res.warnings.append("Danh sách skill khai trong group.json không khớp các thư mục skills/ trong gói; PVTA chỉ lấy thư mục có SKILL.md.") }
            res.warnings.append("Gói do “\(m.author)” viết, phiên bản \(m.version); PVTA coi là nhóm đồng nghiệp chia sẻ và không tự bật.")
        }
        res.ok = res.problems.isEmpty && res.manifest != nil
        return res
    }

    private static func versionKey(_ v: String) -> Int {
        let p = v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return p[0] * 1_000_000 + p[1] * 1_000 + p[2]
    }

    private func unpack(_ data: Data, _ problems: inout [String]) -> ([String: Data], Int)? {
        guard data.count <= Self.packLimits.totalBytes else { problems.append("Tệp gói quá lớn."); return nil }
        guard let zip = try? ZipArchive(data: data) else { problems.append("Không mở được gói: không phải tệp nén hợp lệ."); return nil }
        let names = zip.names.filter { !$0.hasSuffix("/") }
        if names.count > Self.packLimits.files { problems.append("Gói có quá nhiều tệp."); return nil }
        var files: [String: Data] = [:], total = 0
        for n in names {
            if n.hasPrefix("/") || n.contains("..") || n.contains("\\") || n.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil { problems.append("Đường dẫn không an toàn: \(n)"); continue }
            guard n.range(of: #"\.(md|json|csv|txt)$"#, options: [.regularExpression, .caseInsensitive]) != nil else { problems.append("Loại tệp không được phép trong gói: \(n)"); continue }
            guard n.range(of: #"^(group\.json|rules\.md|sources\.csv|checksums\.json|skills/.+)$"#, options: .regularExpression) != nil else { problems.append("Tệp nằm ngoài cấu trúc gói: \(n)"); continue }
            guard (zip.entries[n]?.size ?? Int.max) <= Self.packLimits.fileBytes, let d = try? zip.read(n) else { problems.append("Tệp quá lớn hoặc hỏng: \(n)"); continue }
            total += d.count
            files[n] = d
        }
        if total > Self.packLimits.totalBytes { problems.append("Gói giải nén quá lớn.") }
        if files["group.json"] == nil { problems.append("Thiếu group.json.") }
        if let sums = files["checksums.json"] {
            if sums != Self.checksums(files) { problems.append("Mã băm không khớp: gói bị hỏng hoặc đã bị sửa.") }
        } else { problems.append("Thiếu checksums.json.") }
        return problems.isEmpty ? (files, total) : ([:], total)
    }

    /// Cài gói đã xem trước. Ghi vào `groups/<mã>/`; không tự bật nhóm.
    @discardableResult
    public func installPack(_ data: Data, confirmed: Bool) async throws -> GroupManifest {
        guard confirmed else { throw PVTAError("Cần xác nhận sau khi xem tác giả và phiên bản của gói.") }
        let pv = previewPack(data)
        guard pv.ok, let m = pv.manifest else { throw PVTAError("Không cài được gói: " + pv.problems.joined(separator: " ")) }
        var problems: [String] = []
        guard let (files, _) = unpack(data, &problems) else { throw PVTAError("Không cài được gói: " + problems.joined(separator: " ")) }
        if let have = catalog().first(where: { $0.id == m.id && $0.tier != .chinhThuc }), Self.versionKey(m.version) <= Self.versionKey(have.version) {
            throw PVTAError("Máy đã có phiên bản \(have.version) của nhóm này; chỉ cài được phiên bản mới hơn.")
        }
        let dir = groupsDir.appendingPathComponent(m.id, isDirectory: true)
        let staging = groupsDir.appendingPathComponent(".cai-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var manifest = m
        manifest.skills = pv.skills
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(manifest).write(to: staging.appendingPathComponent("group.json"))
        for (path, d) in files where path != "group.json" && path != "checksums.json" {
            let target = staging.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: target)
        }
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.moveItem(at: staging, to: dir)
        return manifest
    }

    /// Gỡ nhóm đã cài từ gói (nhóm có sẵn không gỡ được).
    public func removePack(_ id: String) async throws {
        guard let m = manifest(id), m.tier != .chinhThuc else { throw PVTAError("Chỉ gỡ được nhóm cài từ gói.") }
        try FileManager.default.removeItem(at: groupsDir.appendingPathComponent(id, isDirectory: true))
        try await patch { $0.enabled = $0.enabled?.filter { $0 != id } }
    }
}
