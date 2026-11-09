import Foundation

enum Fold {
    /// Bỏ dấu và hoa thường để tìm "quy tac" ra "Quy tắc".
    static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi"))
    }
}
