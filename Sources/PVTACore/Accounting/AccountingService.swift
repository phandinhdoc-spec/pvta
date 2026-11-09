import CryptoKit
import Darwin
import Foundation

/// Tác vụ kế toán: đối soát chỉ đọc hai vùng bảng tính .xlsx bằng số thập phân chính xác, không dùng AI.
/// Nguồn chỉ nhận mã tệp đính kèm của đúng hội thoại; báo cáo ghi vào thư mục kết quả của PVTA (không do người gọi chọn).
public actor AccountingService {
    static let maxSource = 20 * 1024 * 1024

    let store: DataStore
    let home: URL
    let now: @Sendable () -> Date
    /// Điểm dừng giữa các giai đoạn (dùng cho test hủy); mặc định không làm gì.
    let phase: @Sendable (String) async -> Void
    private var jobs: [String: Task<ReconcileReport, Error>] = [:]

    public init(store: DataStore, home: URL, now: @escaping @Sendable () -> Date = { Date() }, phase: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.store = store; self.home = home; self.now = now; self.phase = phase
    }

    struct Snapshot { var data: Data; var name: String; var path: String; var sha: String }

    /// Tệp đính kèm hợp lệ của hội thoại: là tệp .xlsx thật, không liên kết, tối đa 20 MB. Đọc một bản chụp byte.
    func snapshot(chatId: String, id: String) async throws -> Snapshot {
        guard let a = try await store.attachment(id: id), a.chatId == chatId, a.kind == "file", let path = a.path else { throw PVTAError("Không có quyền đọc tệp đính kèm này trong hội thoại này.") }
        guard path.lowercased().hasSuffix(".xlsx") else { throw PVTAError("Chỉ thực thi .xlsx; không nhận tệp có macro (.xlsm).") }
        var link = stat()
        guard lstat(path, &link) == 0, (link.st_mode & S_IFMT) == S_IFREG, let real = PathGuard.canonical(path) else { throw PVTAError("Không đọc nguồn qua liên kết tượng trưng.") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PVTAError("Không mở được tệp “\(a.name)” (không đọc qua liên kết tượng trưng).") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxSource else { throw PVTAError("Nguồn phải là tệp, tối đa 20 MB.") }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard data.count <= Self.maxSource else { throw PVTAError("Nguồn quá lớn.") }
        return Snapshot(data: data, name: a.name, path: real, sha: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func key(_ chatId: String, _ runId: String) -> String { "\(chatId)\u{1F}\(runId)" }

    /// Hủy đúng cặp hội thoại/lần chạy. Trả false nếu không có lần chạy nào như vậy.
    @discardableResult
    public func cancel(chatId: String, runId: String) -> Bool {
        guard let t = jobs[Self.key(chatId, runId)] else { return false }
        t.cancel()
        return true
    }

    public func cancelAll() { for t in jobs.values { t.cancel() }; jobs = [:] }

    public func running() -> Int { jobs.count }

    public func run(chatId: String, runId: String, source: ReconcileSide, reference: ReconcileSide, tolerance: String, unit: String) async throws -> ReconcileReport {
        guard !runId.isEmpty, runId.count <= 200, !chatId.isEmpty else { throw PVTAError("Thiếu mã hội thoại hoặc mã lần chạy.") }
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, u.count <= 80, Reconciler.tolerance(tolerance) != nil else { throw PVTAError("Sai số phải là số thập phân không âm; cần đơn vị chung.") }
        _ = try Reconciler.parse(source); _ = try Reconciler.parse(reference)
        guard try await store.chat(id: chatId) != nil else { throw PVTAError("Không tìm thấy hội thoại.") }
        let key = Self.key(chatId, runId)
        guard jobs[key] == nil else { throw PVTAError("Đối soát này đang chạy.") }
        let task = Task { try await self.execute(chatId: chatId, source: source, reference: reference, tolerance: tolerance, unit: u) }
        jobs[key] = task
        defer { jobs[key] = nil }
        do { return try await task.value }
        catch is CancellationError { throw PVTAError("Đã hủy đối soát.") }
        catch { if task.isCancelled { throw PVTAError("Đã hủy đối soát.") }; throw error }
    }

    private func execute(chatId: String, source: ReconcileSide, reference: ReconcileSide, tolerance: String, unit: String) async throws -> ReconcileReport {
        if source.sourceId == reference.sourceId, source.sheet == reference.sheet, source.range == reference.range { throw PVTAError("Hai vùng phải khác nhau.") }
        await phase("start"); try Task.checkCancellation()
        let a = try await snapshot(chatId: chatId, id: source.sourceId), b = try await snapshot(chatId: chatId, id: reference.sourceId)
        await phase("snapshot"); try Task.checkCancellation()
        var report = try Reconciler.reconcile(source: (a.data, a.name), reference: (b.data, b.name), job: (source, reference, tolerance, unit), now: now())
        await phase("computed"); try Task.checkCancellation()
        // Quyền và nguồn phải còn nguyên trước khi ghi báo cáo.
        let a2 = try await snapshot(chatId: chatId, id: source.sourceId), b2 = try await snapshot(chatId: chatId, id: reference.sourceId)
        guard a2.path == a.path, b2.path == b.path else { throw PVTAError("Quyền đọc nguồn đã thay đổi.") }
        guard a2.sha == a.sha, b2.sha == b.sha, report.sources[0].sha256 == a.sha, report.sources[1].sha256 == b.sha else { throw PVTAError("Nguồn đã thay đổi trong khi đối soát; chạy lại.") }
        try Task.checkCancellation()
        report.exports = try await export(report)
        return report
    }

    /// Ghi `reconciliation.json` và `.csv` vào thư mục run mới, đọc lại kiểm băm. Lỗi hoặc bị hủy thì xóa cả thư mục run (không đụng tệp nguồn).
    private func export(_ report: ReconcileReport) async throws -> [ReconcileExport] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("accounting-results", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var rs = stat()
        guard lstat(root.path, &rs) == 0, (rs.st_mode & S_IFMT) == S_IFDIR else { throw PVTAError("Thư mục kết quả không được là liên kết.") }
        let dir = root.appendingPathComponent("run-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var json = report; json.exports = []
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var out: [ReconcileExport] = []
            for (format, data) in [("json", try enc.encode(json) + Data("\n".utf8)), ("csv", Data(Reconciler.csv(report).utf8))] {
                try Task.checkCancellation()
                let url = dir.appendingPathComponent("reconciliation.\(format)")
                try FileService.atomicWrite(data, to: url.path, exclusive: true)
                let back = try Data(contentsOf: url)
                guard back == data else { throw PVTAError("Kiểm tra tệp xuất thất bại.") }
                out.append(ReconcileExport(format: format, path: url.path, sha256: SHA256.hash(data: back).map { String(format: "%02x", $0) }.joined(), bytes: back.count))
            }
            return out
        } catch { try? fm.removeItem(at: dir); throw error }
    }

    // MARK: Công cụ cho model (ghi báo cáo → phải duyệt)

    nonisolated var toolSpecs: [ToolSpec] {
        [ToolSpec(name: "accounting_reconcile",
                  summary: "Đối soát chỉ đọc hai cột số (khóa + giá trị) giữa hai vùng .xlsx đã đính kèm trong hội thoại, bằng số thập phân chính xác. Không sửa tệp nguồn; ghi báo cáo JSON/CSV vào thư mục kết quả của PVTA nên cần thầy cô duyệt.",
                  parameters: #"{"source": {"sourceId": "mã tệp đính kèm", "sheet": "tên trang", "range": "A2:C100 (không gồm tiêu đề)", "keyColumn": "A", "valueColumn": "C"}, "reference": {…như source…}, "tolerance": "0 hoặc 0.01", "unit": "VND"}"#,
                  access: .write,
                  plan: { a in
                      let s = try Self.side(a["source"]), r = try Self.side(a["reference"])
                      return ActionPlan(kind: .run, summary: "Kế toán: đối soát “\(s.sheet)!\(s.range)” với “\(r.sheet)!\(r.range)”",
                                        preview: "Nguồn \(s.sourceId): cột khóa \(s.keyColumn), giá trị \(s.valueColumn)\nĐối chiếu \(r.sourceId): cột khóa \(r.keyColumn), giá trị \(r.valueColumn)\nSai số: \(a["tolerance"]?.string ?? "?") \(a["unit"]?.string ?? "")\nChỉ đọc hai tệp nguồn; tạo 2 tệp báo cáo (JSON, CSV) trong thư mục kết quả của PVTA. Công thức luôn ghi là chưa kiểm chứng.", paths: [])
                  }) { [self] a in
            guard let chatId = a["chatId"]?.string else { throw PVTAError("Thiếu hội thoại.") }
            let r = try await run(chatId: chatId, runId: UUID().uuidString, source: try Self.side(a["source"]), reference: try Self.side(a["reference"]),
                                  tolerance: a["tolerance"]?.string ?? "", unit: a["unit"]?.string ?? "")
            let bad = r.rows.filter { $0.kind != "matched" }
            return "Đã đối soát \(r.summary.sourceRows) dòng nguồn và \(r.summary.referenceRows) dòng đối chiếu: khớp \(r.summary.matched), cần xem \(r.summary.issues).\n" +
                bad.prefix(30).map { "- \($0.key): \($0.kind)" + ($0.delta.map { " (chênh \($0))" } ?? "") }.joined(separator: "\n") +
                "\nBáo cáo: " + r.exports.map(\.path).joined(separator: ", ")
        }]
    }

    static func side(_ v: JSONValue?) throws -> ReconcileSide {
        guard case .object(let o)? = v, Set(o.keys).isSubset(of: ["sourceId", "sheet", "range", "keyColumn", "valueColumn"]),
              let id = o["sourceId"]?.string, let sh = o["sheet"]?.string, let rg = o["range"]?.string, let k = o["keyColumn"]?.string, let val = o["valueColumn"]?.string,
              [id, sh, rg, k, val].allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("\0") }) else { throw PVTAError("Tham số đối soát không hợp lệ.") }
        let s = ReconcileSide(sourceId: id, sheet: sh, range: rg, keyColumn: k, valueColumn: val)
        _ = try Reconciler.parse(s)
        return s
    }
}
