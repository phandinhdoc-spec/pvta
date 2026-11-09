import Foundation

enum DiffText {
    /// Khác biệt theo dòng: "- " dòng bị bỏ, "+ " dòng thêm, hai dòng ngữ cảnh quanh chỗ đổi. Rỗng nếu giống nhau.
    static func unified(old: String, new: String, context: Int = 2) -> String {
        guard old != new else { return "" }
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a.count + b.count <= 40_000 else { return "(thay đổi quá lớn để hiển thị: \(a.count) → \(b.count) dòng)" }
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in b.difference(from: a) {
            switch c {
            case .remove(let off, _, _): removed.insert(off)
            case .insert(let off, _, _): inserted.insert(off)
            }
        }
        var lines: [(String, Bool)] = []     // (chữ, có thay đổi)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { lines.append(("- " + a[i], true)); i += 1 }
            else if j < b.count, inserted.contains(j) { lines.append(("+ " + b[j], true)); j += 1 }
            else { lines.append(("  " + (i < a.count ? a[i] : b[j]), false)); i += 1; j += 1 }
        }
        var keep = [Bool](repeating: false, count: lines.count)
        for (k, l) in lines.enumerated() where l.1 { for d in -context...context where lines.indices.contains(k + d) { keep[k + d] = true } }
        var out: [String] = [], skipped = false
        for (k, l) in lines.enumerated() {
            if keep[k] { out.append(l.0); skipped = false } else if !skipped { out.append("  …"); skipped = true }
        }
        return out.joined(separator: "\n")
    }
}
