import Darwin
import Foundation

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warn, critical, unknown

    var strained: Bool { self == .warn || self == .critical }

    /// Chỉ số áp lực bộ nhớ của macOS (cùng chỉ số Activity Monitor): 1 xanh, 2 vàng, 4 đỏ.
    public static func readSystem() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        switch level {
        case 1: return .normal
        case 2: return .warn
        case 4: return .critical
        default: return .unknown
        }
    }
}

public struct MachineInfo: Sendable {
    public var cpus: Int
    public var totalMemory: UInt64
    public static func current() -> MachineInfo {
        MachineInfo(cpus: ProcessInfo.processInfo.activeProcessorCount, totalMemory: ProcessInfo.processInfo.physicalMemory)
    }
    public init(cpus: Int, totalMemory: UInt64) {
        self.cpus = cpus
        self.totalMemory = totalMemory
    }
}

public struct UrgencyView: Codable, Sendable, Equatable {
    /// true = cờ đỏ.
    public var urgent: Bool
    public var until: Date?
    public var pressure: MemoryPressure
    /// Số bước song song tối đa hiện tại; 0 = theo cấu hình từng quy trình (cờ xanh, RAM ổn).
    public var limit: Int
    public var note: String
}

/// Cờ việc gấp (xanh/đỏ) và phanh RAM. Cờ không lưu qua lần mở lại và dùng chung cho mọi cửa sổ và CLI.
/// Cờ chỉ đổi số bước song song; không đổi quyền ghi tệp hay chạy lệnh (việc đó do mức quyền quyết định).
public actor Urgency {
    public static let maxSteps = 8
    static let stepBytes: UInt64 = 600 * 1024 * 1024
    static let redFlagLife: TimeInterval = 30 * 60
    static let backoffLife: TimeInterval = 5 * 60
    static let sampleLife: TimeInterval = 3

    private let now: @Sendable () -> Date
    private let machine: @Sendable () -> MachineInfo
    private let sample: @Sendable () -> MemoryPressure
    private let changed: @Sendable (UrgencyView) -> Void
    private var urgent = false
    private var until: Date?
    private var used = false
    private var backoff = 0
    private var backoffUntil = Date.distantPast
    private var pressure = MemoryPressure.unknown
    private var sampledAt = Date.distantPast
    private var lastLimit = 1

    public init(now: @escaping @Sendable () -> Date = { Date() }, machine: @escaping @Sendable () -> MachineInfo = { .current() },
                pressure: @escaping @Sendable () -> MemoryPressure = { MemoryPressure.readSystem() },
                changed: @escaping @Sendable (UrgencyView) -> Void = { _ in }) {
        self.now = now
        self.machine = machine
        self.sample = pressure
        self.changed = changed
    }

    /// Số bước song song khi cờ đỏ: theo nhân CPU và RAM, tối đa 8; RAM căng thì 1; mỗi lần bị giảm nhịp thì giảm một nửa.
    static func urgentLimit(_ m: MachineInfo, _ pressure: MemoryPressure, backoff: Int) -> Int {
        if pressure.strained { return 1 }
        let cpuCap = max(1, m.cpus - 1)
        // Trên Mac "RAM trống" luôn thấp do bộ đệm nên tính theo tổng RAM; áp lực bộ nhớ mới là phanh chính.
        let ramCap = max(1, Int(UInt64(Double(m.totalMemory) * 0.3) / stepBytes))
        var n = max(1, min(maxSteps, cpuCap, ramCap))
        for _ in 0..<backoff { n = max(1, n / 2) }
        return n
    }

    /// Cờ xanh: đúng số bước đã đặt (1–4), trừ khi RAM căng.
    static func normalLimit(_ requested: Int, _ pressure: MemoryPressure) -> Int {
        pressure.strained ? 1 : max(1, min(4, requested))
    }

    private func expire() {
        if urgent, let until, now() >= until { urgent = false; self.until = nil; used = false; backoff = 0 }
        if backoff > 0, now() >= backoffUntil { backoff = 0 }
    }

    public var isUrgent: Bool { expire(); return urgent }

    @discardableResult
    public func set(_ on: Bool) -> UrgencyView {
        urgent = on
        until = on ? now().addingTimeInterval(Self.redFlagLife) : nil   // cờ đỏ tự về xanh sau 30 phút
        used = false
        backoff = 0
        let v = view()
        changed(v)
        return v
    }

    private func samplePressure() -> MemoryPressure {
        if now().timeIntervalSince(sampledAt) >= Self.sampleLife || pressure == .unknown {
            pressure = sample()
            sampledAt = now()
        }
        return pressure
    }

    /// Gọi trước mỗi lần mở một bước mới: số bước được chạy đồng thời lúc này.
    public func limit(requested: Int) -> Int {
        expire()
        let p = samplePressure()
        let n = urgent ? Self.urgentLimit(machine(), p, backoff: backoff) : Self.normalLimit(requested, p)
        if urgent { used = true }
        if n != lastLimit { lastLimit = n; changed(view()) }
        return n
    }

    /// Nhà cung cấp báo quá nhiều yêu cầu (429): giảm một nửa số bước trong 5 phút.
    public func rateLimited() {
        expire()
        backoff = min(3, backoff + 1)
        backoffUntil = now().addingTimeInterval(Self.backoffLife)
        changed(view())
    }

    /// Hết việc đang chạy: cờ đỏ đã dùng thì tự về xanh.
    public func idle() {
        expire()
        if urgent, used { set(false) }
    }

    /// Đọc áp lực bộ nhớ mới nhất rồi trả trạng thái (dùng khi hiển thị).
    public func current() -> UrgencyView {
        _ = samplePressure()
        return view()
    }

    public func view() -> UrgencyView {
        expire()
        let p = pressure
        let limit = urgent ? Self.urgentLimit(machine(), p, backoff: backoff) : (p.strained ? 1 : 0)
        let brake = p.strained ? " Áp lực RAM đang ở mức \(p == .warn ? "vàng" : "đỏ"): không mở thêm bước song song." : ""
        let slow = backoff > 0 ? " Đang giảm nhịp vì nhà cung cấp báo quá nhiều yêu cầu." : ""
        let note = urgent
            ? "Cờ đỏ: tăng số bước song song theo nhân CPU và RAM (tối đa \(Self.maxSteps)), tự về cờ xanh khi xong việc hoặc sau 30 phút.\(slow)\(brake)"
            : "Cờ xanh: chạy đúng số bước đã đặt cho từng quy trình.\(brake)"
        return UrgencyView(urgent: urgent, until: until, pressure: p, limit: limit, note: note)
    }
}
