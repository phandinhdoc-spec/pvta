import Foundation

/// Phương thức `call` cho skill và nhóm. Các thao tác này đổi dữ liệu riêng của PVTA do thầy cô chủ động bấm,
/// còn model chỉ có công cụ đọc `skill_read` (chỉ skill của nhóm đã chọn).
extension Builtin {
    static func skillMethods() -> [(String, Core.Handler)] {
        @Sendable func strings(_ v: JSONValue?) -> [String] { if case .array(let a)? = v { return a.compactMap(\.string) }; return [] }
        @Sendable func changed(_ c: CallContext, _ name: String) { c.core.broadcast("data.changed", ["method": .string(name)]) }
        @Sendable func packData(_ p: JSONValue) throws -> Data {
            if let b = p["data"]?.string, let d = Data(base64Encoded: b) { return d }
            guard let path = p["path"]?.string else { throw PVTAError("Thiếu gói nhóm (data hoặc path).") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= GroupService.packLimits.totalBytes, let d = try? Data(contentsOf: url) else {
                throw PVTAError("Không đọc được tệp gói (hoặc gói lớn hơn 4 MB).")
            }
            return d
        }
        return [
            ("skill.list", { c in try JSONValue(encoding: await c.core.skills.store.list().map { s -> Skill in var t = s; t.body = ""; return t }) }),
            ("skill.detail", { c in
                let n = try c.params.requireString("name")
                guard let s = await c.core.skills.store.skill(n) else { throw PVTAError("Không tìm thấy skill “\(n)”.") }
                let md = SkillText.compose(name: s.name, description: s.description, load: s.load, groups: s.groups, body: s.body)
                return ["skill": try JSONValue(encoding: s), "issues": try JSONValue(encoding: SkillText.check(md, owner: "system", full: false))]
            }),
            ("skill.toggle", { c in
                try await c.core.skills.store.setEnabled(c.params.requireString("name"), c.params["enabled"]?.bool ?? true); changed(c, "skill.toggle"); return .null
            }),
            ("skill.check", { c in
                try JSONValue(encoding: SkillText.check(c.params.requireString("text"), owner: c.params["owner"]?.string ?? "user", full: c.params["full"]?.bool ?? true))
            }),
            ("skill.create", { c in
                let s = try await c.core.skills.store.create(c.params.requireString("text")); changed(c, "skill.create")
                return try JSONValue(encoding: s)
            }),
            ("skill.beginEdit", { c in
                let r = try await c.core.skills.store.beginEdit(c.params.requireString("name"))
                return ["text": .string(r.text), "revision": .string(r.revision)]
            }),
            ("skill.saveEdit", { c in
                let s = try await c.core.skills.store.saveEdit(c.params.requireString("name"), text: c.params.requireString("text"), revision: c.params.requireString("revision"))
                changed(c, "skill.saveEdit")
                return try JSONValue(encoding: s)
            }),
            ("skill.delete", { c in try await c.core.skills.store.delete(c.params.requireString("name")); changed(c, "skill.delete"); return .null }),
            ("skill.backups", { c in try JSONValue(encoding: await c.core.skills.store.backups(c.params.requireString("name"))) }),
            ("skill.previewBackup", { c in
                try JSONValue(encoding: await c.core.skills.store.previewBackup(c.params.requireString("name"), id: c.params.requireString("id")))
            }),
            ("skill.restoreBackup", { c in
                let p = c.params
                let s = try await c.core.skills.store.restoreBackup(p.requireString("name"), id: p.requireString("id"), revision: p["revision"]?.string ?? "", backupRevision: p.requireString("backupRevision"))
                changed(c, "skill.restoreBackup")
                return try JSONValue(encoding: s)
            }),
            ("skill.scan", { c in
                let r = try await c.core.skills.scanDirectory(c.params.requireString("path"))
                return ["scanId": .string(r.scanId), "candidates": try JSONValue(encoding: r.candidates)]
            }),
            ("skill.scanGitHub", { c in
                let r = try await c.core.track(kind: "skill.scanGitHub") { try await c.core.skills.scanGitHub(repo: c.params.requireString("repo"), ref: c.params["ref"]?.string) }
                return ["scanId": .string(r.scanId), "candidates": try JSONValue(encoding: r.candidates)]
            }),
            ("skill.install", { c in
                // Dùng mã quét cũ nếu còn; không có (ví dụ gọi từ dòng lệnh, mỗi lần một tiến trình) thì quét lại nguồn rồi cài ngay.
                var scanId = c.params["scanId"]?.string
                if scanId == nil, let repo = c.params["repo"]?.string { scanId = try await c.core.track(kind: "skill.scanGitHub") { try await c.core.skills.scanGitHub(repo: repo, ref: c.params["ref"]?.string) }.scanId }
                if scanId == nil, let path = c.params["path"]?.string { scanId = try await c.core.skills.scanDirectory(path).scanId }
                guard let scanId else { throw PVTAError("Thiếu nguồn cần cài (scanId, path hoặc repo).") }
                let r = try await c.core.skills.install(scanId: scanId, keys: strings(c.params["keys"])); changed(c, "skill.install")
                return try JSONValue(encoding: r.map { s -> Skill in var t = s; t.body = ""; return t })
            }),
            ("skill.guide", { _ in .string(SkillGuide.text) }),

            ("groups.view", { c in try JSONValue(encoding: await c.core.groups.view()) }),
            ("groups.setEnabled", { c in
                let r = try await c.core.groups.setEnabled(strings(c.params["ids"])); changed(c, "groups.setEnabled")
                return .array(r.map { .string($0) })
            }),
            ("groups.toggle", { c in
                let r = try await c.core.groups.toggle(c.params.requireString("id"), c.params["enabled"]?.bool); changed(c, "groups.toggle")
                return .array(r.map { .string($0) })
            }),
            ("groups.quickPacks", { c in try JSONValue(encoding: await c.core.groups.quickPacks()) }),
            ("groups.applyQuickPack", { c in
                let r = try await c.core.groups.applyQuickPack(c.params.requireString("id")); changed(c, "groups.applyQuickPack")
                return .array(r.map { .string($0) })
            }),
            ("groups.profiles.list", { c in
                ["profiles": try JSONValue(encoding: await c.core.groups.profiles()), "canUndo": .bool(try await c.core.groups.canUndoProfile())]
            }),
            ("groups.profiles.create", { c in
                let p = try await c.core.groups.createProfile(c.params.requireString("name")); changed(c, "groups.profiles.create")
                return try JSONValue(encoding: p)
            }),
            ("groups.profiles.delete", { c in try await c.core.groups.deleteProfile(c.params.requireString("id")); changed(c, "groups.profiles.delete"); return .null }),
            ("groups.profiles.preview", { c in try JSONValue(encoding: await c.core.groups.previewProfile(c.params.requireString("id"))) }),
            ("groups.profiles.apply", { c in
                try await c.core.groups.applyProfile(token: c.params.requireString("token"), confirmed: c.params["confirmed"]?.bool ?? false); changed(c, "groups.profiles.apply")
                return .null
            }),
            ("groups.exportPack", { c in
                let p = c.params
                let d = try await c.core.groups.exportPack(p.requireString("id"), asId: p["asId"]?.string, name: p["name"]?.string, author: p["author"]?.string)
                if let out = p["output"]?.string {
                    let dest = (out as NSString).expandingTildeInPath
                    guard dest.lowercased().hasSuffix(GroupService.packExtension) else { throw PVTAError("Tệp gói cần có đuôi \(GroupService.packExtension).") }
                    try FileService.atomicWrite(d, to: dest, exclusive: true)
                    return ["path": .string(dest), "bytes": .number(Double(d.count))]
                }
                return ["data": .string(d.base64EncodedString()), "bytes": .number(Double(d.count))]
            }),
            ("groups.previewPack", { c in try JSONValue(encoding: await c.core.groups.previewPack(packData(c.params))) }),
            ("groups.installPack", { c in
                let m = try await c.core.groups.installPack(packData(c.params), confirmed: c.params["confirmed"]?.bool ?? false); changed(c, "groups.installPack")
                return try JSONValue(encoding: m)
            }),
            ("groups.removePack", { c in try await c.core.groups.removePack(c.params.requireString("id")); changed(c, "groups.removePack"); return .null }),
        ]
    }
}

/// Quy định viết skill của PVTA (skill nhân, không hiện trong danh sách): các dòng này cũng là điều bộ kiểm chuẩn kiểm.
enum SkillGuide {
    static let text = """
        QUY ĐỊNH VIẾT SKILL CỦA PVTA
        - Skill là thư mục có SKILL.md; phần đầu gồm name, description, load (always, demand, manual) và tùy chọn groups.
        - Tên chữ thường không dấu, số, gạch nối, tối đa 40 ký tự; không chứa claude, anthropic; skill tự viết không dùng tiền tố pvta-, learned-, cd-.
        - Mô tả một dòng, dưới 220 ký tự, nêu làm gì và khi nào dùng.
        - Thân dưới 20.000 ký tự, tự chứa trong một tệp.
        - Khuôn thân gồm 7 mục theo thứ tự: \(SkillText.template.joined(separator: "; ")).
        - Mỗi dòng ở mục Quy định phải kết thúc bằng “(Nguồn: tên văn bản hoặc tài liệu)”; không có nguồn thì không viết quy định.
        - Không có khối pvta-tool, lệnh hệ thống, khóa bí mật, đường dẫn web ngoài phần Nguồn, hay câu bảo bỏ qua chỉ dẫn.
        - Skill dùng chung cho mọi model: không gắn với tên một hãng hay một công cụ riêng.
        """
}
