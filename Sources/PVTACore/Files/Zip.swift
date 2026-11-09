import Compression
import Foundation

/// Đọc tệp ZIP (docx, xlsx, pptx) trong bộ nhớ, không giải nén ra đĩa. Có giới hạn kích thước để chống tệp nén bom.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    static let maxEntryBytes = 64 * 1024 * 1024

    private let data: Data
    let entries: [String: Entry]
    /// Tên các mục theo thứ tự trong tệp.
    var names: [String] { entries.values.sorted { $0.localOffset < $1.localOffset }.map(\.name) }

    init(data: Data) throws {
        self.data = data
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let bad = PVTAError("Tệp này không phải tài liệu Office hợp lệ hoặc đã bị hỏng.")
        guard data.count >= 22 else { throw bad }
        // Tìm bản ghi kết thúc danh mục (EOCD) ở cuối tệp.
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while i >= lowest {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw bad }
        let count = u16(eocd + 10), dirSize = u32(eocd + 12), dirOffset = u32(eocd + 16)
        guard dirOffset + dirSize <= data.count, count < 100_000 else { throw bad }
        var out: [String: Entry] = [:]
        var p = dirOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x02014b50 else { throw bad }
            let method = UInt16(u16(p + 10)), csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= data.count else { throw bad }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            out[name] = Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = out
    }

    /// Nội dung một mục trong ZIP, hoặc nil nếu không có.
    func read(_ name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        let bad = PVTAError("Tệp Office bị hỏng nên PVTA không đọc được.")
        guard e.size <= Self.maxEntryBytes else { throw PVTAError("Một phần của tệp quá lớn (hơn 64 MB sau khi giải nén) nên PVTA không đọc.") }
        let o = e.localOffset
        guard o + 30 <= data.count else { throw bad }
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        guard start + e.compressedSize <= data.count else { throw bad }
        let raw = data[start..<(start + e.compressedSize)]
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let n = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == e.size else { throw bad }
            return out
        default:
            throw bad
        }
    }
}

/// Ghi tệp ZIP (docx) trong bộ nhớ: nén deflate, mục giữ đúng thứ tự thêm vào.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: data.count + 1024)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < data.count else { return nil }
        return out.prefix(n)
    }

    private static func le(_ v: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    mutating func add(_ name: String, _ data: Data) {
        let nameData = Data(name.utf8)
        let packed = Self.deflate(data)
        let method = packed == nil ? 0 : 8
        let payload = packed ?? data
        let crc = Int(Self.crc32(data))
        let offset = body.count
        // Giờ 00:00 ngày 01/01/1980: tệp không phụ thuộc thời điểm tạo.
        var local = Data()
        local += Self.le(0x04034b50, 4) + Self.le(20, 2) + Self.le(0x0800, 2) + Self.le(method, 2) + Self.le(0, 2) + Self.le(0x21, 2)
        local += Self.le(crc, 4) + Self.le(payload.count, 4) + Self.le(data.count, 4) + Self.le(nameData.count, 2) + Self.le(0, 2) + nameData
        body += local + payload
        directory += Self.le(0x02014b50, 4) + Self.le(20, 2) + Self.le(20, 2) + Self.le(0x0800, 2) + Self.le(method, 2) + Self.le(0, 2) + Self.le(0x21, 2)
        directory += Self.le(crc, 4) + Self.le(payload.count, 4) + Self.le(data.count, 4) + Self.le(nameData.count, 2)
        directory += Self.le(0, 2) + Self.le(0, 2) + Self.le(0, 2) + Self.le(0, 2) + Self.le(0, 4) + Self.le(offset, 4) + nameData
        count += 1
    }

    func finish() -> Data {
        var out = body + directory
        out += Self.le(0x06054b50, 4) + Self.le(0, 2) + Self.le(0, 2) + Self.le(count, 2) + Self.le(count, 2)
        out += Self.le(directory.count, 4) + Self.le(body.count, 4) + Self.le(0, 2)
        return out
    }
}
