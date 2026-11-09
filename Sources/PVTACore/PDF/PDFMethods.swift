import Foundation

extension Builtin {
    static func pdfMethods() -> [(String, Core.Handler)] {
        @Sendable func chat(_ c: CallContext) throws -> String { try c.params.requireString("chatId") }
        return [
            ("pdf.read", { c in try await c.core.pdf.read(path: c.params.requireString("path"), chat: c.params["chatId"]?.string) }),
            ("pdf.region", { c in
                let a = c.params
                func coordinate(_ key: String) throws -> Double {
                    guard let v = a[key]?.number, v.isFinite else { throw PVTAError("Thiếu tọa độ " + key) }
                    return v
                }
                return try await c.core.pdf.region(path: a.requireString("path"), chat: a["chatId"]?.string,
                    page: PDFService.integer(a["page"], "page", max: 2000),
                    rect: CGRect(x: coordinate("x"), y: coordinate("y"), width: coordinate("width"), height: coordinate("height")))
            }),
            ("pdf.font", { _ in try PDFService.font() }),
            ("pdf.split", { c in
                guard case .array(let list)? = c.params["pages"] else { throw PVTAError("Thiếu danh sách trang cần tách.") }
                let pages = try list.map { try PDFService.integer($0, "pages", max: 2000) }
                return try await c.core.track(kind: "pdf.split", chatId: chat(c)) {
                    try await c.core.pdf.combine(paths: [c.params.requireString("path")], pages: pages, output: c.params.requireString("output"), chat: chat(c))
                }
            }),
            ("pdf.merge", { c in
                guard case .array(let list)? = c.params["paths"], list.allSatisfy({ $0.string != nil }) else { throw PVTAError("Thiếu danh sách PDF cần gộp.") }
                return try await c.core.track(kind: "pdf.merge", chatId: chat(c)) {
                    try await c.core.pdf.combine(paths: list.compactMap(\.string), pages: nil, output: c.params.requireString("output"), chat: chat(c))
                }
            }),
            ("pdf.writeBegin", { c in .string(try await c.core.pdf.begin(path: c.params.requireString("path"), chat: chat(c), size: PDFService.integer(c.params["size"], "size", max: PDFService.maxBytes))) }),
            ("pdf.writeChunk", { c in .number(Double(try await c.core.pdf.chunk(id: c.params.requireString("id"), chat: chat(c), offset: PDFService.integer(c.params["offset"], "offset", max: PDFService.maxBytes), base64: c.params.requireString("data")))) }),
            ("pdf.writeFinish", { c in
                try await c.core.track(kind: "pdf.writeFinish", chatId: chat(c)) {
                    try await c.core.pdf.finish(id: c.params.requireString("id"), chat: chat(c))
                }
            }),
            ("pdf.writeAbort", { c in try await c.core.pdf.abort(id: c.params.requireString("id"), chat: chat(c)); return .null })
        ]
    }
}
