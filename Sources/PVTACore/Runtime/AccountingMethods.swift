import Foundation

extension Builtin {
    static func accountingMethods() -> [(String, Core.Handler)] {
        [
            ("accounting.run", { c in
                let p = c.params
                guard case .object(let o) = p, Set(o.keys).isSubset(of: ["chatId", "runId", "source", "reference", "tolerance", "unit"]) else { throw PVTAError("Tham số đối soát không hợp lệ (không nhận đường dẫn hay tệp xuất do người gọi chọn).") }
                try await c.core.permissions.requireWritable()
                let r = try await c.core.track(kind: "accounting.run", chatId: p["chatId"]?.string) {
                    try await c.core.accounting.run(chatId: p.requireString("chatId"), runId: p.requireString("runId"), source: AccountingService.side(p["source"]), reference: AccountingService.side(p["reference"]),
                                                    tolerance: p.requireString("tolerance"), unit: p.requireString("unit"))
                }
                return try JSONValue(encoding: r)
            }),
            ("accounting.cancel", { c in .bool(await c.core.accounting.cancel(chatId: try c.params.requireString("chatId"), runId: try c.params.requireString("runId"))) }),
        ]
    }
}
