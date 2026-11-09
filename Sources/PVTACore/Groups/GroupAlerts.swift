import Foundation

extension GroupDocs {
    // MARK: Kiểm tra căn cứ

    /// Số hiệu của chính văn bản (dòng “Số: …” ở đầu) không phải căn cứ.
    private static func ownKey(_ text: String) -> String? {
        let head = String(text.prefix(800))
        guard let m = Docs.firstMatch(#"(?:^|\n)\s*Số\s*:?\s*([^\s,;]+)"#, head) else { return nil }
        return Legal.citations(m).first?.key
    }

    public static func citedBasis(_ text: String) -> [Citation] {
        let own = ownKey(text)
        return Legal.citations(text).filter { $0.key != own }
    }

    private func label(_ f: Finding) -> String { "\(f.type ?? "Văn bản") \(f.no)" }

    /// Kiểm tra căn cứ pháp lý của một văn bản: số hiệu được trích bằng quy tắc rồi tra trong kho đã tải.
    /// Hàm này chỉ đọc kho nội bộ, không gọi mạng và không gửi nội dung văn bản đi đâu.
    public func checkBasis(_ text: String, groups only: [String]? = nil) async throws -> BasisReport {
        let cites = Self.citedBasis(text)
        let all = try await store.docs(includeHidden: true)
        let rel = relationsPublic(all)
        var findings: [Finding] = []
        for c in cites {
            guard let rec = all.first(where: { $0.no.map(Legal.noKey) == c.key && (only == nil || only!.contains($0.group)) }) else {
                findings.append(Finding(no: c.no, type: c.type, state: "khong-co-trong-kho", title: nil, group: nil, replacedBy: nil, amendedBy: []))
                continue
            }
            let e = effectivePublic(rec, rel)
            findings.append(Finding(no: c.no, type: c.type, state: e.status.rawValue, title: rec.title, group: rec.group, replacedBy: e.replacedBy?.no ?? e.replacedBy?.title,
                                    amendedBy: e.amendedBy.compactMap(\.no)))
        }
        let changed = findings.filter { $0.state == DocStatus.hetHieuLuc.rawValue || $0.state == DocStatus.daSuaDoi.rawValue }
        let unknown = findings.filter { $0.state == "khong-co-trong-kho" }
        var message = ""
        if !changed.isEmpty {
            let lines = changed.map { f -> String in
                if f.state == DocStatus.hetHieuLuc.rawValue { return f.replacedBy.map { "\(label(f)) đã được thay thế bởi \($0)." } ?? "\(label(f)) đã hết hiệu lực." }
                return "\(label(f)) đã được sửa đổi" + (f.amendedBy.isEmpty ? "." : " bởi \(f.amendedBy.joined(separator: ", ")).")
            }
            message = "Văn bản này viện dẫn \(cites.count) văn bản. " + lines.joined(separator: " ")
        }
        return BasisReport(cited: cites.count, findings: findings, changed: changed, unknown: unknown, message: message, disclaimer: Self.disclaimerOriginal)
    }

    // MARK: Cảnh báo

    /// Mức 1: căn cứ đã đổi. Mức 2: văn bản mới cùng chủ đề trong các nhóm đang chọn. Mỗi cảnh báo nhắc tối đa một lần mỗi ngày; cảnh báo đã tắt không hiện lại.
    public func alerts(for text: String) async throws -> AlertsResult {
        let st = try await groups.state()
        let enabled = (st.enabled ?? []).filter { !st.alertsOff.contains($0) }
        let today = Self.day(now())
        var report = try await checkBasis(text, groups: nil)
        func fresh(_ f: Finding) -> Bool { !st.muted.contains(Legal.noKey(f.no)) && st.shown[Legal.noKey(f.no)] != today }
        let keep = report.changed.filter(fresh)
        report.changed = keep
        report.message = keep.isEmpty ? "" : report.message
        let toMark = keep.map { Legal.noKey($0.no) }
        // Văn bản mới cùng chủ đề (độ tin cậy thấp).
        let words = Set(Fold.text(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 })
        var related: [(Int, DocRecord)] = []
        for d in try await store.docs() where d.isNew && enabled.contains(d.group) && !st.muted.contains(d.no.map(Legal.noKey) ?? d.id) {
            let overlap = Set(Fold.text(d.title).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 }).intersection(words).count
            if overlap >= 2 { related.append((overlap, d)) }
        }
        let top = related.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
        if !toMark.isEmpty { try await groups.patch { for k in toMark { $0.shown[k] = today } } }
        return AlertsResult(basis: keep.isEmpty ? nil : report, related: top)
    }

    /// Tắt cảnh báo cho một văn bản (theo số hiệu).
    public func muteFinding(_ no: String) async throws {
        let k = Legal.noKey(no)
        guard !k.isEmpty else { throw PVTAError("Thiếu số hiệu văn bản.") }
        try await groups.patch { if !$0.muted.contains(k) { $0.muted.append(k) } }
    }

    public func unmuteAll() async throws { try await groups.patch { $0.muted = []; $0.shown = [:] } }

    public func setAlerts(group: String, on: Bool) async throws {
        guard await groups.manifest(group) != nil else { throw PVTAError("Không có nhóm “\(group)”.") }
        try await groups.patch { s in s.alertsOff.removeAll { $0 == group }; if !on { s.alertsOff.append(group) } }
    }

    // MARK: Ngoại tuyến

    /// Bật chế độ không dùng mạng: tắt mọi tìm kiếm và tải trên mạng; văn bản đã tải vẫn tra cứu, tóm tắt (nếu đã có) và kiểm tra căn cứ bình thường.
    public func setOffline(_ on: Bool) async throws { try await groups.patch { $0.offline = on } }
    public func isOffline() async throws -> Bool { try await groups.state().offline }

    // MARK: Bản tin

    /// Bản tin khởi động: chỉ tổng hợp dữ liệu đã có, không gọi mạng. Mục nào không có thì ẩn.
    public func briefing(name: String? = nil, proposals: Int = 0) async throws -> Briefing {
        let st = try await groups.state()
        let today = Self.day(now())
        var items: [BriefItem] = []
        var byGroup: [(String, String, Int)] = []
        for id in st.enabled ?? [] {
            guard let m = await groups.manifest(id), m.kind != .congCu else { continue }
            let n = try await store.docs(group: id).filter(\.isNew).count
            if n > 0 { byGroup.append((id, m.name, n)) }
        }
        let total = byGroup.reduce(0) { $0 + $1.2 }
        if total > 0 {
            let names = byGroup.map(\.1)
            items.append(BriefItem(id: "docs", text: "\(total) văn bản mới cho nhóm \(names.prefix(3).joined(separator: ", "))" + (names.count > 3 ? "…" : ""), target: "documents", group: byGroup[0].0))
        }
        let changed = try await store.docs().filter { $0.status == .hetHieuLuc || $0.status == .daSuaDoi }.count
        if changed > 0 && total == 0 { items.append(BriefItem(id: "basis", text: "\(changed) văn bản trong kho đã hết hiệu lực hoặc được sửa đổi", target: "basis", group: nil)) }
        if proposals > 0 { items.append(BriefItem(id: "proposals", text: "\(proposals) điều PVTA học được đang chờ thầy cô duyệt", target: "proposals", group: nil)) }
        let show = st.briefingEnabled && !items.isEmpty && st.briefingShownDay != today && st.briefingDismissedDay != today
        return Briefing(show: show, greeting: "Chào \(name ?? "thầy cô"). Hôm nay có:", items: items)
    }

    public func markBriefingShown() async throws { let d = Self.day(now()); try await groups.patch { $0.briefingShownDay = d } }
    public func dismissBriefing() async throws { let d = Self.day(now()); try await groups.patch { $0.briefingDismissedDay = d; $0.briefingShownDay = d } }
    public func setBriefingEnabled(_ on: Bool) async throws { try await groups.patch { $0.briefingEnabled = on } }

    // MARK: Nguồn theo dõi và hồ sơ nơi dạy

    public func sources() async throws -> [DiscoverySource] { try await groups.state().sources }

    public func addSource(name: String, url: String, kind: String = "page", groups ids: [String] = []) async throws -> DiscoverySource {
        let u = try Self.sourceURL(url)
        guard ["page", "feed"].contains(kind) else { throw PVTAError("Loại nguồn là page hoặc feed.") }
        for g in ids where await groups.manifest(g) == nil { throw PVTAError("Không có nhóm “\(g)”.") }
        let s = try await groups.state()
        guard s.sources.count < 30 else { throw PVTAError("Tối đa 30 nguồn theo dõi.") }
        guard !s.sources.contains(where: { $0.url == u.absoluteString }) else { throw PVTAError("Nguồn này đã có.") }
        let src = DiscoverySource(id: UUID().uuidString, name: String(name.trimmingCharacters(in: .whitespaces).prefix(80)).isEmpty ? (u.host ?? "Nguồn") : String(name.trimmingCharacters(in: .whitespaces).prefix(80)),
                                  url: u.absoluteString, enabled: true, groups: ids, kind: kind, lastChecked: nil, lastError: nil, found: nil)
        try await groups.patch { $0.sources.append(src) }
        return src
    }

    public func removeSource(_ id: String) async throws {
        guard try await groups.state().sources.contains(where: { $0.id == id }) else { throw PVTAError("Không có nguồn này.") }
        try await groups.patch { $0.sources.removeAll { $0.id == id } }
    }

    public func setProfile(_ p: DiscoveryProfile) async throws {
        func c(_ s: String, _ n: Int = 160) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }
        let clean = DiscoveryProfile(province: c(p.province), locality: c(p.locality), school: c(p.school), level: c(p.level), subjects: c(p.subjects), keywords: c(p.keywords, 300))
        try await groups.patch { $0.profile = clean }
    }

    public func profile() async throws -> DiscoveryProfile { try await groups.state().profile }

    public func reports() async throws -> [DiscoveryReport] { try await groups.state().reports }
}
