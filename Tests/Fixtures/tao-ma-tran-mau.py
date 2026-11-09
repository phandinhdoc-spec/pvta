# Tạo ma-tran-mau.docx và dac-ta-mau.docx (dữ liệu giả, có ô gộp ngang và gộp dọc) cho test nhiệm vụ 36.
import zipfile
def esc(s): return s.replace("&","&amp;").replace("<","&lt;")
def cell(text, span=1, vm=None):
    pr = ""
    if span > 1: pr += f'<w:gridSpan w:val="{span}"/>'
    if vm == "restart": pr += '<w:vMerge w:val="restart"/>'
    elif vm == "continue": pr += '<w:vMerge/>'
    return f'<w:tc><w:tcPr>{pr}</w:tcPr><w:p><w:r><w:t>{esc(text)}</w:t></w:r></w:p></w:tc>'
def table(rows): return "<w:tbl>" + "".join("<w:tr>" + "".join(r) + "</w:tr>" for r in rows) + "</w:tbl>"
def save(name, body):
    doc = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
           + body + '</w:body></w:document>')
    with zipfile.ZipFile(name, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr("word/document.xml", doc)
M = [
 [cell("Chủ đề", vm="restart"), cell("Dạng", vm="restart"), cell("Mức độ", span=3), cell("Tổng số", vm="restart")],
 [cell("", vm="continue"), cell("", vm="continue"), cell("Biết"), cell("Hiểu"), cell("Vận dụng"), cell("", vm="continue")],
 [cell("Chủ đề 1. Từ trường", vm="restart"), cell("I"), cell("3"), cell("2"), cell("0"), cell("5")],
 [cell("", vm="continue"), cell("II"), cell("1"), cell("2"), cell("1"), cell("4")],
 [cell("Chủ đề 2. Điện", vm="restart"), cell("I"), cell("2"), cell("1"), cell(""), cell("3")],
 [cell("", vm="continue"), cell("III"), cell(""), cell("1"), cell("1,5"), cell("2,5")],
 [cell("Số câu TN / số ý"), cell("I"), cell("5"), cell("3"), cell("0"), cell("8")],
]
save("ma-tran-mau.docx", "<w:p><w:r><w:t>MA TRẬN ĐỀ KIỂM TRA (DỮ LIỆU GIẢ)</w:t></w:r></w:p>" + table(M))
S = [
 [cell("Chủ đề"), cell("Nội dung"), cell("Mức độ"), cell("Yêu cầu cần đạt")],
 [cell("Chủ đề 1. Từ trường", vm="restart"), cell("Từ trường", vm="restart"), cell("Biết"), cell("Nêu được đường sức từ bên ngoài nam châm thẳng đi từ cực Bắc sang cực Nam.")],
 [cell("", vm="continue"), cell("", vm="continue"), cell("Hiểu"), cell("Giải thích được vì sao kim nam châm chỉ hướng Bắc – Nam.")],
 [cell("Chủ đề 2. Điện"), cell("Dòng điện"), cell("Vận dụng"), cell("Tính được điện trở tương đương của hai điện trở mắc nối tiếp.")],
]
save("dac-ta-mau.docx", table(S))
