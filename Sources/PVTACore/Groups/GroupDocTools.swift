import Foundation

extension GroupDocs {
    /// Công cụ chỉ đọc cho model: tra cứu trong kho văn bản đã tải và kiểm tra căn cứ. Không có đường nào gọi mạng hay gửi văn bản ra ngoài.
    nonisolated var toolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "group_search", summary: "Tìm trong các văn bản pháp quy đã tải về kho (không phân biệt dấu); hiểu câu kiểu “Điều 12 khoản 3 Nghị định 115/2020/NĐ-CP”. Luôn nêu số hiệu và Điều khi trích.",
                     parameters: #"{"query": "từ khóa hoặc số hiệu, Điều, khoản"}"#) { [self] a in
                guard let q = a["query"]?.string, !q.isEmpty else { throw PVTAError("Thiếu tham số \"query\".") }
                let enabled = await groups.enabledSet()
                let hits = try await search(q, groups: enabled.isEmpty ? nil : Array(enabled), limit: 8)
                if hits.isEmpty { return "Không thấy trong kho văn bản đã tải. Có thể văn bản chưa được tải về; không suy đoán nội dung." }
                return hits.map { "[\($0.no ?? $0.title)] \($0.dieu)\($0.khoan.isEmpty ? "" : ", " + $0.khoan) (\(DocStatus(rawValue: $0.status)?.label ?? $0.status)): \($0.snippet)" }.joined(separator: "\n---\n")
            },
            ToolSpec(name: "check_basis", summary: "Kiểm tra căn cứ pháp lý của một đoạn văn bản: trích số hiệu rồi tra trong kho đã tải xem còn hiệu lực, đã sửa đổi hay hết hiệu lực. Số hiệu chưa có trong kho ghi là chưa xác định.",
                     parameters: #"{"text": "nội dung văn bản cần kiểm tra"}"#) { [self] a in
                guard let t = a["text"]?.string, !t.isEmpty else { throw PVTAError("Thiếu tham số \"text\".") }
                let r = try await checkBasis(t)
                if r.cited == 0 { return "Không thấy số hiệu văn bản nào để kiểm tra." }
                let rows = r.findings.map { f -> String in
                    let st = f.state == "khong-co-trong-kho" ? "chưa có trong kho (chưa xác định)" : (DocStatus(rawValue: f.state)?.label ?? f.state)
                    return "- \(f.type ?? "Văn bản") \(f.no): \(st)" + (f.replacedBy.map { ", thay thế bởi \($0)" } ?? "") + (f.amendedBy.isEmpty ? "" : ", sửa đổi bởi " + f.amendedBy.joined(separator: ", "))
                }
                return (r.message.isEmpty ? "" : r.message + "\n") + rows.joined(separator: "\n") + "\n" + r.disclaimer
            },
        ]
    }
}
