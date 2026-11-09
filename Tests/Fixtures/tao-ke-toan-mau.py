# Tạo ke-toan-nguon.xlsx và ke-toan-doi-chieu.xlsx (dữ liệu giả) cho test nhiệm vụ 38. Gồm khớp, lệch, công thức, trùng khóa, số sai, khóa trống.
import zipfile
def esc(s): return s.replace("&", "&amp;").replace("<", "&lt;")
def c(ref, v=None, text=None, f=None):
    if text is not None: return f'<c r="{ref}" t="inlineStr"><is><t>{esc(text)}</t></is></c>'
    if f is not None: return f'<c r="{ref}"><f>{f}</f><v>{v}</v></c>'
    return f'<c r="{ref}"><v>{v}</v></c>'
def save(name, sheet, rows):
    body = "".join(f'<row r="{i}">' + "".join(cells) + "</row>" for i, cells in rows)
    ws = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + body + "</sheetData></worksheet>"
    wb = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          f'<sheets><sheet name="{sheet}" sheetId="1" r:id="rId1"/></sheets></workbook>')
    with zipfile.ZipFile(name, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        z.writestr("xl/worksheets/sheet1.xml", ws)
head = [c("A1", text="Mã"), c("B1", text="Tên"), c("C1", text="Số tiền")]
src = [(1, head),
 (2, [c("A2", text="TK001"), c("B2", text="Tiền mặt"), c("C2", 1000000)]),
 (3, [c("A3", text="TK002"), c("B3", text="Ngân hàng"), c("C3", "2500000.5")]),
 (4, [c("A4", text="TK003"), c("B4", text="Phải thu"), c("C4", 300)]),
 (5, [c("A5", text="TK004"), c("B5", text="Tổng"), c("C5", "3500000.5", f="C2+C3")]),
 (6, [c("A6", text="TK005"), c("B6", text="Số sai"), c("C6", text="1.234.567")]),
 (7, [c("A7", text="TK006"), c("B7", text="Lẻ"), c("C7", "0.1")]),
 (8, [c("A8", text="TK007"), c("B8", text="Trùng 1"), c("C8", 1)]),
 (9, [c("A9", text="TK007"), c("B9", text="Trùng 2"), c("C9", 2)]),
 (10, [c("B10", text="Khóa trống"), c("C10", 5)]),
 (11, [c("A11", text="TK008"), c("B11", text="Chỉ ở nguồn"), c("C11", 100)])]
ref = [(1, head),
 (2, [c("A2", text="TK001"), c("C2", 1000000)]),
 (3, [c("A3", text="TK002"), c("C3", "2500000.49")]),
 (4, [c("A4", text="TK003"), c("C4", 301)]),
 (5, [c("A5", text="TK004"), c("C5", "3500000.5")]),
 (6, [c("A6", text="TK005"), c("C6", 100)]),
 (7, [c("A7", text="TK006"), c("C7", "0.2")]),
 (8, [c("A8", text="TK007"), c("C8", 3)]),
 (9, [c("A9", text="TK009"), c("C9", 7)])]
save("ke-toan-nguon.xlsx", "So", src)
save("ke-toan-doi-chieu.xlsx", "DoiChieu", ref)
