#!/usr/bin/env python3
"""Sinh các tệp mẫu nhỏ cho kiểm thử (không chứa thông tin học sinh hay cá nhân). Chạy lại: python3 tao-tep-mau.py"""
import zipfile, zlib, struct, os

here = os.path.dirname(os.path.abspath(__file__))
def path(n): return os.path.join(here, n)

def write_zip(name, files):
    with zipfile.ZipFile(path(name), "w", zipfile.ZIP_DEFLATED) as z:
        for n, c in files.items(): z.writestr(n, c)

W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
write_zip("giao-an.docx", {
    "[Content_Types].xml": '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
    "word/document.xml": f'<?xml version="1.0" encoding="UTF-8"?><w:document {W}><w:body>'
        '<w:p><w:r><w:t>Giáo án Toán 8</w:t></w:r></w:p>'
        '<w:p><w:r><w:t xml:space="preserve">Quy tắc nhân đơn thức &amp; đa thức</w:t></w:r><w:r><w:tab/><w:t>(tiết 12)</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Bước</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Nội dung</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Khởi động</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '</w:body></w:document>',
})

S = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
write_zip("bang-diem.xlsx", {
    "[Content_Types].xml": '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
    "xl/workbook.xml": f'<?xml version="1.0"?><workbook {S}><sheets><sheet name="Điểm lớp 8A" sheetId="1"/><sheet name="Tổng kết" sheetId="2"/></sheets></workbook>',
    "xl/sharedStrings.xml": f'<?xml version="1.0"?><sst {S}><si><t>Họ tên</t></si><si><t>Học sinh mẫu A</t></si><si><t>Giỏi</t></si><si><t>Tổng</t></si></sst>',
    "xl/worksheets/sheet1.xml": f'<?xml version="1.0"?><worksheet {S}><sheetData>'
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>Xếp loại</t></is></c></row>'
        '<row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>9.5</v></c><c r="C2" t="s"><v>2</v></c></row>'
        '</sheetData></worksheet>',
    "xl/worksheets/sheet2.xml": f'<?xml version="1.0"?><worksheet {S}><sheetData><row r="1"><c r="A1" t="s"><v>3</v></c><c r="B1"><f>SUM(1,2)</f><v>3</v></c></row></sheetData></worksheet>',
})

A = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
write_zip("bai-giang.pptx", {
    "[Content_Types].xml": '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
    "ppt/slides/slide1.xml": f'<?xml version="1.0"?><p:sld {A} xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Hằng đẳng thức</a:t></a:r></a:p><a:p><a:r><a:t>Bình phương một tổng</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
    "ppt/slides/slide2.xml": f'<?xml version="1.0"?><p:sld {A} xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Luyện tập</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
})

def pdf(name, pages):
    """PDF tối giản; chữ ASCII trong phông Helvetica. pages: danh sách chuỗi (rỗng = trang trống, không có chữ)."""
    objs = []
    n = len(pages)
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(n))
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(f"<< /Type /Pages /Kids [{kids}] /Count {n} >>")
    for i, t in enumerate(pages):
        content = f"BT /F1 18 Tf 72 720 Td ({t}) Tj ET" if t else ""
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {4 + 2 * i} 0 R >>")
        objs.append(f"<< /Length {len(content)} >>\nstream\n{content}\nendstream")
    out = b"%PDF-1.4\n"
    offsets = []
    for i, o in enumerate(objs):
        offsets.append(len(out))
        out += f"{i + 1} 0 obj\n{o}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets: out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    open(path(name), "wb").write(out)

pdf("de-cuong.pdf", ["Trang mot: Hang dang thuc dang nho", "Trang hai: Phan tich da thuc thanh nhan tu"])
pdf("trang-trong.pdf", [""])

def png(name, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path(name), "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
png("anh-do.png", 4, 4, (255, 0, 0))
png("anh-xanh.png", 4, 4, (0, 0, 255))
open(path("anh-gia.jpg"), "wb").write(b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"x" * 40 + b"\xff\xd9")
open(path("anh-gia.gif"), "wb").write(b"GIF89a" + b"\x01\x00\x01\x00\x00\x00\x00;")
open(path("anh-gia.webp"), "wb").write(b"RIFF\x1a\x00\x00\x00WEBPVP8 " + b"\x00" * 20)

open(path("quy-che.md"), "w", encoding="utf-8").write("# Quy chế mẫu\n\nĐiều 1. Quy tắc làm tròn điểm trung bình đến một chữ số thập phân.\nĐiều 2. Học sinh vắng không phép bị trừ điểm chuyên cần.\n")
open(path("diem.csv"), "w", encoding="utf-8").write("Họ tên,Toán,Văn\nHọc sinh mẫu A,9,8\nHọc sinh mẫu B,7,6.5\n")
open(path("trang-web.html"), "w", encoding="utf-8").write("<html><head><style>p{}</style><script>var x=1;</script></head><body><h1>Thông báo</h1><p>Họp tổ &amp; chuyên môn</p></body></html>")
print("Đã tạo tệp mẫu trong", here)
