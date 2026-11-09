import Foundation

public struct GroupView: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var kindLabel: String
    public var tier: String
    public var enabled: Bool
    public var skills: [String]
    public var version: String
    public var builtin: Bool
}

public struct GroupProfilePreview: Codable, Sendable, Equatable {
    public var token: String
    public var name: String
    public var before: GroupConfiguration
    public var after: GroupConfiguration
    public var added: [String]
    public var removed: [String]
    public var missing: [String]
}

/// Nhóm theo vai trò và chuyên môn. Chỉ skill của nhóm đã chọn được nạp; AI không tự tìm skill ngoài nhóm.
public actor GroupService {
    static let key = "groups.state"
    let store: DataStore
    let skills: SkillStore
    let home: URL
    private var pendingProfile: (preview: GroupProfilePreview, expected: String, undo: Bool)?

    public init(store: DataStore, skills: SkillStore, home: URL) {
        self.store = store
        self.skills = skills
        self.home = home
    }

    // MARK: Trạng thái

    func state() async throws -> GroupsState {
        guard let raw = try await store.setting(Self.key), let s = try? JSONDecoder().decode(GroupsState.self, from: Data(raw.utf8)) else { return GroupsState() }
        return s
    }

    func patch(_ change: (inout GroupsState) -> Void) async throws {
        var s = try await state()
        change(&s)
        try await store.setSetting(Self.key, String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
    }

    // MARK: Danh mục

    var groupsDir: URL { home.appendingPathComponent("groups", isDirectory: true) }

    /// Nhóm có sẵn và nhóm đã cài từ gói.
    public func catalog() -> [GroupManifest] {
        var out = GroupCatalog.builtin
        let ids = Set(out.map(\.id))
        for u in ((try? FileManager.default.contentsOfDirectory(at: groupsDir, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
            guard let d = try? Data(contentsOf: u.appendingPathComponent("group.json")), let m = try? JSONDecoder().decode(GroupManifest.self, from: d),
                  m.id == u.lastPathComponent, !ids.contains(m.id) else { continue }
            out.append(m)
        }
        return out
    }

    public func manifest(_ id: String) -> GroupManifest? { catalog().first { $0.id == id } }

    public func enabledSet() async -> Set<String> { Set(((try? await state())?.enabled) ?? []) }

    /// Skill được phép nạp: đang bật, và hoặc không thuộc nhóm nào (skill riêng của thầy cô) hoặc thuộc ít nhất một nhóm đã chọn.
    public func visibleSkills() async -> [Skill] {
        let on = await enabledSet()
        return await skills.list().filter { $0.enabled && ($0.groups.isEmpty || !on.isDisjoint(with: $0.groups)) }
    }

    public func view() async throws -> [GroupView] {
        let on = Set(try await state().enabled ?? [])
        let all = await skills.list()
        return catalog().map { g in
            GroupView(id: g.id, name: g.name, kind: g.kind.rawValue, kindLabel: g.kind.label, tier: g.tier.rawValue, enabled: on.contains(g.id),
                      skills: all.filter { $0.groups.contains(g.id) }.map(\.name), version: g.version, builtin: g.tier == .chinhThuc)
        }
    }

    // MARK: Chọn nhóm

    @discardableResult
    public func setEnabled(_ ids: [String]) async throws -> [String] {
        let known = Set(catalog().map(\.id))
        if let bad = ids.first(where: { !known.contains($0) }) { throw PVTAError("Không có nhóm “\(bad)”.") }
        var seen = Set<String>(), clean: [String] = []
        for i in ids where seen.insert(i).inserted { clean.append(i) }
        try await patch { $0.enabled = clean; $0.pack = nil }
        return clean
    }

    @discardableResult
    public func toggle(_ id: String, _ on: Bool? = nil) async throws -> [String] {
        guard manifest(id) != nil else { throw PVTAError("Không có nhóm “\(id)”.") }
        var cur = try await state().enabled ?? []
        let want = on ?? !cur.contains(id)
        cur.removeAll { $0 == id }
        if want { cur.append(id) }
        try await patch { $0.enabled = cur; $0.pack = nil }
        return cur
    }

    public func quickPacks() -> [QuickPack] { GroupCatalog.quickPacks }

    @discardableResult
    public func applyQuickPack(_ id: String) async throws -> [String] {
        guard let p = GroupCatalog.quickPacks.first(where: { $0.id == id }) else { throw PVTAError("Không có gói chọn nhanh “\(id)”.") }
        let known = Set(catalog().map(\.id))
        let ids = p.groups.filter(known.contains)
        try await patch { $0.enabled = ids; $0.pack = id }
        return ids
    }

    // MARK: Hồ sơ học kỳ / tổ

    public func profiles() async throws -> [NamedGroupProfile] { try await state().profiles }
    public func canUndoProfile() async throws -> Bool {
        let s = try await state()
        guard let u = s.undo else { return false }
        return u.applied == Fingerprint.of(s.configuration)
    }

    /// Lưu cấu hình hiện tại (nhóm đã chọn, ngoại tuyến, tắt cảnh báo, bản tin) thành hồ sơ có tên. Không lưu văn bản, hồ sơ nguồn hay khóa.
    public func createProfile(_ name: String) async throws -> NamedGroupProfile {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 100 else { throw PVTAError("Tên hồ sơ cần từ 1 đến 100 ký tự.") }
        let s = try await state()
        guard !s.profiles.contains(where: { $0.name == n }) else { throw PVTAError("Đã có hồ sơ tên “\(n)”.") }
        guard s.profiles.count < 30 else { throw PVTAError("Tối đa 30 hồ sơ.") }
        let p = NamedGroupProfile(id: UUID().uuidString, name: n, config: s.configuration)
        try await patch { $0.profiles.append(p) }
        return p
    }

    public func deleteProfile(_ id: String) async throws {
        let s = try await state()
        guard s.profiles.contains(where: { $0.id == id }) else { throw PVTAError("Không có hồ sơ này.") }
        try await patch { $0.profiles.removeAll { $0.id == id } }
    }

    private func revision() async throws -> String { Fingerprint.of([Fingerprint.of(try await state()), Fingerprint.of(catalog())]) }

    /// Xem trước việc áp dụng hồ sơ (hoặc hoàn tác lần áp dụng gần nhất, id = "undo"). Chưa đổi gì.
    public func previewProfile(_ id: String) async throws -> GroupProfilePreview {
        let s = try await state()
        let before = s.configuration
        let after: GroupConfiguration, name: String
        if id == "undo" {
            guard let u = s.undo, u.applied == Fingerprint.of(before) else { throw PVTAError("Cấu hình đã thay đổi; không thể hoàn tác an toàn.") }
            after = u.config; name = "Hoàn tác hồ sơ"
        } else {
            guard let p = s.profiles.first(where: { $0.id == id }) else { throw PVTAError("Không có hồ sơ này.") }
            after = p.config; name = p.name
        }
        let known = Set(catalog().map(\.id))
        let missing = Array(Set((after.enabled ?? []) + after.alertsOff).filter { !known.contains($0) }).sorted()
        let pv = GroupProfilePreview(token: UUID().uuidString, name: name, before: before, after: after,
                                     added: (after.enabled ?? []).filter { !(before.enabled ?? []).contains($0) },
                                     removed: (before.enabled ?? []).filter { !(after.enabled ?? []).contains($0) }, missing: missing)
        pendingProfile = (pv, try await revision(), id == "undo")
        return pv
    }

    /// Áp dụng hồ sơ đã xem trước (cần mã xem trước và xác nhận). Dữ liệu đổi sau lúc xem thì từ chối.
    public func applyProfile(token: String, confirmed: Bool) async throws {
        guard confirmed else { throw PVTAError("Cần xác nhận áp dụng hồ sơ.") }
        guard let pending = pendingProfile, pending.preview.token == token else { throw PVTAError("Hãy xem trước hồ sơ lần nữa.") }
        pendingProfile = nil
        guard pending.expected == (try await revision()) else { throw PVTAError("Dữ liệu đã thay đổi; hãy xem trước lại.") }
        guard pending.preview.missing.isEmpty else { throw PVTAError("Hồ sơ nhắc tới nhóm không còn tồn tại: " + pending.preview.missing.joined(separator: ", ") + ".") }
        let before = pending.preview.before, after = pending.preview.after
        try await patch {
            $0.enabled = after.enabled; $0.pack = after.pack; $0.offline = after.offline; $0.alertsOff = after.alertsOff; $0.briefingEnabled = after.briefing
            $0.undo = pending.undo ? nil : GroupsState.UndoSlot(config: before, applied: Fingerprint.of(after))
        }
    }
}
