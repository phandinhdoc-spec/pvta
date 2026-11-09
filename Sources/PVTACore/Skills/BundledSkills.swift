import Foundation

/// Skill nền đi kèm PVTA (chuyển từ skill nền của MySoft sang công cụ của PVTA). Cài vào thư mục skill của người dùng khi khởi động.
enum BundledSkills {
    static let all: [(name: String, text: String)] = [
        ("pvta-bao-cao", #"""
---
name: pvta-bao-cao
description: Tạo bộ báo cáo thống kê, tài chính (Nghị quyết 27), tổng kết năm học đồng bộ trên Word, Excel và PowerPoint.
load: demand
groups: to-truong, hieu-pho, hieu-truong, ke-toan, excel
---
# Thiết kế Báo cáo Thống kê & Tài chính Đồng bộ (Word · Excel · PowerPoint)

- Xác định rõ kỳ báo cáo, đơn vị ban hành, đơn vị tính (đồng, triệu đồng, học sinh, %) và nguồn số liệu.
- Kiểm tra chéo mọi phép cộng, trừ, tỷ lệ (như mức chi 0,8 quỹ lương, số dư từng quý và lũy kế cả năm) bằng công cụ `run_code (tính bằng Python) hoặc công thức Excel`.
- Khi lập PowerPoint báo cáo số liệu: mỗi bảng chuyên đề một slide, tiêu đề phân mục rõ ràng (ví dụ "I. Thông tin chung: Quỹ lương từng quý"); dòng tổng đặt tên "Tổng", "Cộng cả năm" hoặc "Số dư".
- Khi lập Excel: giữ nguyên số thực và gắn công thức SUM, AVERAGE.
- Khi xuất Word: trình bày đầy đủ Quốc hiệu, Tiêu ngữ, tên đơn vị, các mục La Mã (`I.`, `II.`), bảng biểu căn giữa và phần nhận xét, kiến nghị.
"""#),
        ("pvta-dap-an", #"""
---
name: pvta-dap-an
description: Giải đề, lập đáp án và hướng dẫn chấm theo từng mã đề/câu/ý; kiểm tính đúng, duy nhất, điểm thành phần và giữ cấu trúc nguồn.
load: demand
groups: giao-vien, to-truong
---
# Đáp án và hướng dẫn chấm

1. Đọc đầy đủ đề, hình/bảng và quy tắc chấm. Giữ mã đề, mã câu, mã ý và thứ tự; xác định thiếu trang, thiếu phương án hoặc dữ kiện trước khi giải. Chỉ yêu cầu đáp án thì chỉ làm đáp án, không sinh lại ma trận hay đổi cấu trúc đề.
2. Giải từng câu độc lập trước khi so với đáp án mẫu. Tính bằng run_code (tính bằng Python) hoặc công thức Excel, giữ đơn vị và điều kiện; có thể dùng kết quả công cụ đã xác nhận đúng dữ kiện trong hội thoại. Đáp án mẫu là dữ liệu để đối chiếu, không mặc định đúng.
3. Trắc nghiệm: xác định nội dung đúng rồi ánh xạ sang nhãn A/B/C/D theo đúng mã đề. Nếu không có hoặc có nhiều phương án đúng, báo câu lỗi và giữ trạng thái chưa chốt; không ép chọn một nhãn. Đúng/sai: giải từng ý và giữ đúng thứ tự, kèm lý do. Câu thiếu dữ kiện: ghi chưa xác định/null và lý do, không đoán đáp án.
4. Tự luận: trình bày lập luận, kết quả, đơn vị và điểm từng ý theo thang điểm nguồn; chấp nhận cách giải tương đương hợp lệ. Nếu chưa có điểm thành phần, ghi rõ thang điểm đề xuất cần duyệt. Không mặc định chia 0,25/0,5 hoặc tự đổi tổng điểm sang 10.
5. Đối chiếu tổng điểm các ý với điểm câu, tổng điểm câu với thang toàn đề bằng run_code (tính bằng Python) hoặc công thức Excel. Với đúng/sai, dùng đúng quy tắc chấm được cung cấp (tuyến tính hoặc theo số ý đúng); thiếu quy tắc thì hỏi, không suy ra từ dạng câu.
6. Kiểm đủ mỗi câu/ý một lần, nhãn khớp phương án, đáp án khớp lời giải; ghi riêng lỗi trong đề, lỗi đáp án mẫu và đề xuất sửa. Giữ nguyên đề gốc nếu người dùng chỉ yêu cầu giải.

Đầu ra gồm bảng đáp án, giải thích/hướng dẫn chấm theo phạm vi yêu cầu và danh sách vấn đề. Tách khỏi đề học sinh. Khi cần tệp, dùng word_create/excel_create với dữ liệu cấu trúc; chỉ báo đã tạo khi công cụ xác nhận. Khi được yêu cầu JSON, trả JSON và dùng null cho câu chưa đủ căn cứ. Hoàn thành khi mọi câu đã có kết quả hoặc trạng thái chưa giải được có lý do, mọi tổng điểm được kiểm hoặc nêu rõ thiếu quy tắc.
"""#),
        ("pvta-doc-dac-ta", #"""
---
name: pvta-doc-dac-ta
description: Đọc bản đặc tả kiểm tra, trích yêu cầu cần đạt và mức độ; phát hiện ô thiếu, mâu thuẫn và truy nguyên vị trí nguồn trước khi ra đề.
load: demand
groups: giao-vien, to-truong
---
# Đọc bản đặc tả

## Quy tắc đọc bảng

- Xác định cột bằng tiêu đề Yêu cầu cần đạt, Mức độ, Nội dung, Mã hóa, Dạng thức, Số câu hỏi, Câu số; đọc hết từng hàng, kể cả YCCĐ không bắt đầu bằng động từ quen thuộc.
- Bảng năng lực đứng trước bảng đặc tả là bảng riêng. Khởi tạo lại ánh xạ cột và ngữ cảnh khi sang bảng khác; không cộng lại số liệu của cùng câu ở hai bảng.
- Với ô trống lặp lại nội dung/mức độ, phân biệt gộp ô thật với quy ước trình bày. Nếu chỉ dựa vào hàng trước thì đánh dấu suy luận và đề nghị xác nhận quy ước; không đổi mức độ theo động từ trong YCCĐ.
- Giữ nguyên mã hóa như 1.1, danh sách dạng I / II và mã câu 19a. Mã năng lực không phải số câu; 19a là ý a, không phải cả câu 19. Một YCCĐ có thể gắn nhiều dạng hoặc nhiều mã câu.
- Đọc nguồn chưa phải phân bổ đề: các số 0 trong biểu mẫu chọn câu chỉ là trạng thái chưa phân bổ. Lưu số liệu nguồn riêng, ô thiếu là chưa xác định. Không thay dữ liệu không đọc được bằng đặc tả mẫu hoặc tự cân bằng về 10 điểm.
- Đối chiếu tên dạng phần III giữa hai tệp: trả lời ngắn và tự luận là hai dạng khác nhau. Báo rõ vị trí khác biệt trước khi dùng hai tệp chung một đề.

1. Xác định tài liệu nguồn, môn, phạm vi kiến thức, thời lượng và thang điểm nếu có. Dùng fs_read để đọc đủ các trang/đoạn bảng liên quan; fs_find chỉ giúp tìm vị trí, không thay cho đọc toàn bộ bảng. Với ảnh/PDF scan, xác nhận chữ và cấu trúc nhìn được; ô không đọc rõ ghi `chưa xác định`.
2. Lập danh sách từng yêu cầu: mã ổn định, chủ đề, đơn vị kiến thức, nguyên văn yêu cầu cần đạt, mức độ ghi ở nguồn, dạng câu và số câu/điểm nếu nguồn nêu, vị trí nguồn. Giữ nhãn NB/TH/VD hoặc các nhãn khác đúng tài liệu; phân biệt yêu cầu cần đạt với hoạt động dạy học.
3. Đọc tiêu đề nhiều tầng và ô gộp theo tọa độ bảng. Chỉ kế thừa tiêu đề khi có bằng chứng ô gộp; ô trống khác với số 0. Nếu văn bản trích xuất làm mất hàng/cột, báo hạn chế và yêu cầu nguồn rõ hơn, không tự đoán quan hệ giữa các ô.
4. Giữ riêng dữ kiện nguồn và đề xuất. Không tự thêm số câu, điểm hoặc đổi mức độ theo động từ đơn lẻ. Một yêu cầu có nhiều mức độ phải giữ các nhánh tương ứng.
5. Nếu có ma trận, gọi skill_read với name `pvta-doc-ma-tran` để đối chiếu. Ghi từng bất đồng kèm hai vị trí nguồn; chưa chốt cấu trúc đề khi xung đột chưa được giải quyết.

Hoàn thành khi mọi yêu cầu trong phạm vi đã có dòng truy nguyên hoặc được ghi rõ là thiếu/không đọc được. Đầu ra là bảng trích xuất và danh sách vấn đề; chỉ sinh đề hay tạo tệp khi người dùng yêu cầu bước đó. Khi người dùng yêu cầu JSON, giữ cùng nội dung bằng JSON hợp lệ, dùng null cho dữ liệu chưa biết.
"""#),
        ("pvta-doc-ma-tran", #"""
---
name: pvta-doc-ma-tran
description: Đọc ma trận đề kiểm tra từ bảng Word, Excel, PDF; giữ hàng cột và ô gộp, kiểm số câu, điểm, tỉ lệ và mâu thuẫn với đặc tả.
load: demand
groups: giao-vien, to-truong
---
# Đọc ma trận kiểm tra

## Quy tắc đọc bảng nhiều tầng

- Dựng đường dẫn tiêu đề cho mỗi cột: thành phần năng lực → mức độ → mã năng lực. Các mã TN1.1, TN2.3 là nhãn; không diễn giải chữ số trong mã thành số câu hay điểm.
- Đọc dạng I, II, III theo từng hàng; chủ đề gộp dọc chỉ lấy từ ô gốc. Mã tọa độ phải kèm số bảng để tránh nhầm R1C1 giữa hai bảng.
- Giữ riêng bảng ô chi tiết và các dòng tổng. Cộng theo cùng chủ đề, dạng, mức độ, đơn vị rồi đối chiếu tổng nguồn; không cộng các ô tổng gộp dọc nhiều lần.
- Trắc nghiệm đúng/sai có thể phân bổ từng ý sang các mức độ khác nhau. Giữ số câu và số ý riêng; chỉ quy đổi khi nguồn nêu số ý mỗi câu và cách chấm. Nếu biểu mẫu phần mềm chỉ nhận câu nguyên, báo giới hạn biểu mẫu, không kết luận nguồn sai.
- Phần III có thể là trả lời ngắn hoặc tự luận. Số câu không tự chuyển thành điểm. Giữ các ô trống chưa xác định; chỉ kết luận tổng sai khi các ô và quy ước đếm đủ rõ.
- Khi phần mở đầu, tổng bảng và bảng chi tiết khác nhau, nêu từng vị trí cùng số liệu nguyên văn. Không tự chọn bên đúng hoặc chỉnh nguồn cho khớp mẫu 16–2–4.

1. Đọc toàn bộ bảng và chú thích bằng fs_read, tìm nguồn bằng fs_find khi cần. Ghi tên tệp và vị trí bảng/trang. Lấy môn, thời lượng, thang điểm, hình thức và quy tắc chấm từ tài liệu hoặc yêu cầu cụ thể, không áp cấu trúc đề mẫu.
2. Chuẩn hóa từng ô dữ liệu thành: chủ đề, yêu cầu/mã nếu có, mức độ, dạng câu, số câu, số ý/lệnh hỏi, điểm, vị trí ô. Phân biệt số câu với số ý đúng/sai; giữ số thập phân và đơn vị. Tiêu đề gộp kế thừa theo vùng ô thực; ô trống là chưa xác định, không mặc nhiên bằng 0.
3. Tính bằng run_code (tính bằng Python) hoặc công thức Excel: tổng số câu, tổng số ý, tổng điểm theo hàng, cột, dạng câu và mức độ; tỉ lệ = điểm nhóm / tổng điểm × 100. Dùng giá trị chưa làm tròn để đối chiếu; nếu chỉ có phần trăm đã làm tròn, ghi rõ độ chính xác thay vì sửa số gốc. Đếm mỗi câu/ý một lần; không cộng lại dòng tổng vào dữ liệu.
4. Đối chiếu các tổng tính được với tổng ghi trong nguồn. Liệt kê bất đồng, vị trí và chênh lệch. Nếu thiếu quy tắc điểm đúng/sai, điểm từng câu hoặc tổng điểm, giữ null/chưa xác định; không áp thang 10 hay tự chia đều điểm.
5. So khớp với bản đặc tả nếu có: chủ đề, yêu cầu cần đạt, mức độ, dạng câu, số câu/điểm. Khi thiếu căn cứ hoặc có mâu thuẫn, báo trạng thái `cần làm rõ` và câu hỏi cụ thể; vẫn trả phần đã đọc được.

Hoàn thành khi các ô có thể đọc đều được truy nguyên và mọi tổng kiểm tra có kết quả hoặc lý do chưa thể tính. Chỉ chuyển sang sinh đề khi ràng buộc đủ và nhất quán; đọc ma trận không đồng nghĩa với xin tạo đề hoặc tệp. Dùng JSON nếu người dùng yêu cầu.
"""#),
        ("pvta-giao-an", #"""
---
name: pvta-giao-an
description: Soạn và làm đẹp giáo án Word, kế hoạch bài dạy THCS THPT theo khung 5512, tích hợp năng lực số và AI có minh chứng; kiểm tra mục tiêu, hoạt động, đánh giá, thời lượng.
load: demand
groups: giao-vien, to-truong, hieu-pho
---
# Giáo án Word có cấu trúc và minh chứng

## Phạm vi và căn cứ
Dùng Phụ lục IV Công văn 5512/BGDĐT-GDTrH ngày 18/12/2020 làm khung tham chiếu bài dạy trung học; không mặc nhiên áp cho tiểu học. Đọc mẫu trường, hướng dẫn năm học và yêu cầu cần đạt được cung cấp. Phân biệt quy định, khung tham khảo và thiết kế PVTA; không nói 5512 bắt buộc font, màu hay bảng hai cột.
Quy tắc đã bổ sung từ ba giáo án người dùng: Bài 18 tính chất kim loại, Bài 19 dãy hoạt động, Bài 20 tách kim loại và hợp kim. Đây là mẫu cùng chủ đề, không đại diện mọi môn và chưa phải 50 mẫu thẩm định.
Mã năng lực số phải đối chiếu Thông tư 02/2025/TT-BGDĐT và hướng dẫn tương ứng bằng bản nguồn, đúng cấp độ, trang/mục. Mã trong giáo án mẫu chưa tự chứng minh tính đúng. Thiếu nguồn thì mô tả biểu hiện và ghi mã chưa xác minh; không bịa mã hoặc đổi mã giữa khung năng lực số và khung AI riêng.

## Chuẩn bị và bảo toàn
Xác định môn, lớp, bộ sách, bài, số tiết/phút, thiết bị, mạng và nhu cầu hỗ trợ HS. Hỏi gộp phần thiếu ảnh hưởng nội dung; có thể dựng dàn ý có chỗ trống rõ nghĩa. Không tự gán trường, tác giả, ngày dạy, chữ ký, trang SGK hay yêu cầu cần đạt.
Nếu chỉ làm đẹp, đọc hết nguồn, lập bản đồ đề mục và giữ nội dung; tách đề nghị sửa kiến thức/thêm AI khỏi định dạng. Không thêm kết quả thí nghiệm hay nhận xét sau giờ dạy chưa diễn ra.

## Cấu trúc và liên kết sư phạm
Đầu bài: trường/tổ/GV nếu có; tên bài, môn/lớp, thời lượng.
Title cho tên bài. Heading 1: I. Mục tiêu; II. Thiết bị dạy học và học liệu; III. Tiến trình dạy học. Mục tiêu gồm kiến thức, năng lực, phẩm chất thể hiện bằng hành vi/sản phẩm quan sát được.
Heading 2 cho nhóm hoạt động: mở đầu, hình thành kiến thức, luyện tập, vận dụng; Heading 3 cho hoạt động con hoặc mục tiêu thành phần. Nhãn a–d trong mỗi hoạt động: mục tiêu, nội dung, sản phẩm, tổ chức thực hiện. Không gán heading cho mọi câu hỏi/ô bảng, không nhảy cấp chỉ để đổi cỡ chữ.
Lập đối chiếu mục tiêu → nhiệm vụ → sản phẩm → tiêu chí đánh giá → minh chứng năng lực số/AI nếu có. Mỗi mục tiêu có hoạt động đáp ứng; sản phẩm phải do chính nhiệm vụ tạo ra. Không đặt bài trình chiếu tổng kết vào sản phẩm khởi động nếu chỉ giao trò chơi gợi nhớ.
Mỗi hoạt động ghi phút, cá nhân/nhóm, nhiệm vụ cụ thể, sản phẩm dự kiến và tiêu chí đạt. Cộng thời gian trong lớp đúng ngân sách tiết; bài về nhà ghi riêng hạn nộp và cách phản hồi. Nêu hỗ trợ HS gặp khó khăn và nhiệm vụ mở rộng khi phù hợp.
Tổ chức thực hiện có bốn bước: giao nhiệm vụ; thực hiện và hỗ trợ; báo cáo/thảo luận; kết luận/đánh giá. Có thể dùng bảng GV | HS: cột GV ghi điều phối/hỗ trợ, cột HS ghi thao tác và kết quả cụ thể tương ứng. Không chỉ lặp “nhận nhiệm vụ”, không đặt việc của GV vào cột HS. Không nhét toàn bộ giáo án vào bảng.

## Phiếu, kiến thức và đáp án
Đánh số hoạt động, nhiệm vụ, phiếu và câu hỏi nhất quán; mỗi tham chiếu phải trỏ đúng nội dung. Tách phiếu trống phát HS khỏi đáp án/hướng dẫn GV, tránh lặp toàn bộ phiếu trong nhiều mục. Tiêu đề cột phải đúng thí nghiệm hoặc phép so sánh, không giữ nhãn của bài cũ.
Phiếu thực nghiệm ghi quan sát, giải thích và phương trình khi phù hợp. Phân biệt HS thực hành, GV biểu diễn và xem mô phỏng/video; chỉ tổ chức thí nghiệm theo điều kiện, quy trình an toàn được trường chấp thuận. Không chuyển thí nghiệm nguy hiểm thành bài tự làm ở nhà.
Kiểm tra số câu thực có so với luật chơi; nhãn lựa chọn không trùng; đáp án khớp phương án và lời giải; phép tính, đơn vị, cân bằng phương trình, điều kiện phản ứng chính xác. Không coi đáp án mẫu luôn đúng. Đối chiếu công thức trong Word/bản kết xuất trước khi kết luận lỗi từ văn bản trích xuất. Xóa nội dung lạc bài/câu dang dở chỉ khi được phép sửa nội dung; nếu chỉ làm đẹp, báo riêng.

## Năng lực số và AI
Mỗi tích hợp ghi thao tác HS, công cụ/học liệu, sản phẩm lưu được, tiêu chí kiểm chứng và phương án không mạng. Ví dụ: bảng so sánh có nguồn; sơ đồ có giải thích quan hệ; báo cáo mô phỏng có quan sát và kết luận. Đánh giá độ đúng, bằng chứng, cách giải thích và phần HS tự làm; không chỉ chấm hình thức.
Phân biệt GV dùng AI chuẩn bị bài với HS thực hành AI. Video, Canva, trò chơi trực tuyến hay tên trò chơi có chữ “Ai” không tự chứng minh hoạt động AI. Chỉ thêm AI khi phục vụ mục tiêu môn học.
Nếu dùng AI: HS nhận nhiệm vụ rõ, lưu câu hỏi/phản hồi liên quan, kiểm chứng bằng SGK/tài liệu hoặc phép tính, chỉ ra lỗi và sửa có giải thích; ghi công cụ, mục đích và phần AI hỗ trợ. Chuẩn bị phản hồi AI in sẵn đã được GV kiểm tra khi thiếu thiết bị. Không đưa dữ liệu cá nhân HS vào dịch vụ công cộng hoặc buộc tạo tài khoản không phù hợp tuổi.

## Thiết kế và bàn giao
AI đề xuất ba phương án phù hợp nội dung, khác nhau về phân cấp, khoảng cách và bảng; cho người dùng chọn, không lấy theme/preset Office hay khóa vào danh mục mẫu cố định.
Điểm xuất phát suy ra từ mẫu: Times New Roman 13 pt; A4 và khoảng cách dễ đọc là đề xuất thiết kế, không phải yêu cầu 5512. Hạn chế màu, đọc rõ khi in đen trắng; không dùng màu đỏ cho toàn bộ nội dung tích hợp. Tùy chỉnh Title/Heading thật, không chỉ in đậm.
Bảng nằm trong vùng in, cột HS đủ chỗ cho thao tác; lặp hàng tiêu đề, không cố định chiều cao. Giữ đề mục/nhãn sản phẩm với nội dung sau; tránh hàng ngắn bị xé trang, cho phép hàng quá dài tách hợp lý. Đề nghị mục lục cho tập nhiều bài, danh mục bảng/viết tắt khi hữu ích; tạo sau khi người dùng chọn.
Tệp Word hiện có: đọc cấu trúc bằng word_read rồi sửa trên bản sao bằng word_edit; không sửa tệp gốc. Công thức dùng Equation sửa được nếu công cụ hỗ trợ. DOCX là nguồn chỉnh sửa, PDF để xem/in. Lưu theo thư mục nguồn đã ghi nhớ; chưa có thì dùng thư mục tạm và «Lưu như…».
Chỉ dùng khả năng công cụ thực có. Trước bàn giao kiểm tra nội dung, đối chiếu mục tiêu–nhiệm vụ–đánh giá, thời lượng, mã có nguồn, phiếu/đáp án, bảng, công thức, tiếng Việt và ngắt trang. Chỉ nói đã kiểm tra trực quan khi thực sự xem bản kết xuất, ghi rõ phạm vi đã xem; không tự công bố giáo án được duyệt.
"""#),
        ("pvta-hanh-chinh", #"""
---
name: pvta-hanh-chinh
description: Soạn, rà soát và trình bày Word cho công văn, thông báo, báo cáo, kế hoạch, tờ trình, biên bản, quyết định hành chính; kiểm tra thể thức theo nguồn xác minh.
load: demand
groups: van-thu, hieu-truong, hieu-pho, to-truong
---
# Văn bản hành chính Word

## Chọn đúng loại
Xác định loại văn bản, cơ quan ban hành, người nhận, người ký, mục đích và thời điểm áp dụng. Phân biệt quyết định hành chính cá biệt với văn bản quy phạm pháp luật; trường hợp quy phạm đọc skill pvta-phap-ly. Không dùng mẫu hành chính cho mọi hợp đồng, đơn dân sự hoặc văn bản tố tụng.
Đối chiếu bản gốc Nghị định 30/2020/NĐ-CP, Phụ lục I và mẫu tương ứng, cùng quy định chuyên ngành/sửa đổi áp dụng tại ngày soạn. Bản đã kiểm tra là nguồn tham chiếu ngày 17/10/2026, không phải bảo đảm hiệu lực vô thời hạn. Nếu chưa có nguồn mới, báo giới hạn xác minh.

## Dữ kiện và nội dung
Đọc bản nháp, xác định những chỗ còn thiếu. Dùng chỗ trống rõ nghĩa cho số văn bản, ngày ký, chức danh, địa danh; không tự tạo số đăng ký, căn cứ pháp lý, con dấu, chữ ký hoặc thẩm quyền. Khi chỉ làm đẹp, giữ nguyên quyền, nghĩa vụ, thời hạn, số tiền và chủ thể. Đề nghị sửa nội dung riêng, không nhập lẫn vào định dạng.
Công văn: trích yếu công việc, kính gửi, vấn đề/yêu cầu, người thực hiện, thời hạn, nơi nhận. Không mặc nhiên thêm tiêu đề loại “CÔNG VĂN” như báo cáo.
Thông báo: việc cần thông tin, đối tượng, thời gian, cách thực hiện, đầu mối.
Kế hoạch: mục đích/yêu cầu, nội dung, lịch, phân công, nguồn lực, tổ chức thực hiện. Bảng phân công chỉ chứa nhiệm vụ, đơn vị, thời hạn, sản phẩm.
Báo cáo: phạm vi/kỳ báo cáo, kết quả có chứng cứ, hạn chế/nguyên nhân, nhiệm vụ/kiến nghị; không tự tạo số liệu thành tích.
Tờ trình: vấn đề cần quyết định, căn cứ đã xác minh, phương án, nguồn lực, nội dung đề nghị phê duyệt.
Biên bản: thời gian/địa điểm, thành phần thực tế, diễn biến, ý kiến, kết quả, người xác nhận; không suy diễn đồng thuận hoặc kết quả biểu quyết.
Quyết định: đúng thẩm quyền, căn cứ, điều khoản quyết định, trách nhiệm thực hiện, hiệu lực theo dữ liệu được duyệt.

## Thể thức và thiết kế
Thông số tham chiếu từ Phụ lục I Nghị định 30: A4; thông thường trang đứng; trên/dưới 20–25 mm, trái 30–35 mm, phải 15–20 mm; Times New Roman Unicode, chữ đen. Cỡ chữ xác định theo từng thành phần, không áp một cỡ cho toàn văn. Số trang 13–14 pt, ở giữa lề trên, không hiện trang đầu. Khi phải dùng trang ngang cho bảng, kiểm tra điều kiện của mẫu và toàn bộ phân trang.
Bố trí đúng vùng cơ quan ban hành, quốc hiệu/tiêu ngữ, số/ký hiệu, địa danh/ngày tháng, tên loại/trích yếu, nội dung, chữ ký và nơi nhận. Tra mẫu để xác định chính xác cỡ chữ, đường kẻ và kiểu chữ từng vùng; không dùng một danh sách chung thay cho kiểm tra mẫu.
AI chỉ đề xuất các phương án trong phạm vi thể thức: ngắt dòng, khoảng cách, bảng/phụ lục, phân cấp và tính dễ đọc. Không thêm màu trang trí, bìa quảng cáo, icon hoặc preset Office. Quốc hiệu, tên cơ quan và vùng ký không được biến thành Heading 1 của nội dung. Dùng heading cho mục nội dung thật, không làm sai ký hiệu điều/khoản/điểm.

## Kiểm tra và thực thi
Giữ khối ký với chức danh/họ tên, tránh nơi nhận nằm riêng trang; kiểm tra dòng ngắn mồ côi, bảng tràn lề, dấu tiếng Việt, số liệu và phụ lục được dẫn chiếu. Không tự thêm mục lục cho văn bản ngắn; chỉ đề nghị khi tài liệu dài và phù hợp loại văn bản.
Tệp Word sẵn có: đọc bằng word_read, sửa trên bản sao bằng word_edit. Chỉ áp dụng định dạng mà công cụ hỗ trợ, không tuyên bố hoàn thiện thể thức khi còn thiếu khả năng đặt lề/đánh số trang. Lưu bản mới theo nơi lưu đã chọn; không ghi đè nguồn nếu chưa được yêu cầu. Xem bản kết xuất trước khi xác nhận đạt chất lượng in; báo rõ nếu chưa kiểm tra trực quan.
Tách kết quả kiểm tra thành: lỗi thể thức, lỗi dữ kiện/căn cứ và điểm cần người có thẩm quyền quyết định. Đầu ra là dự thảo, không phải văn bản đã ban hành.
"""#),
        ("pvta-ho-so-kiem-tra", #"""
---
name: pvta-ho-so-kiem-tra
description: Phối hợp toàn bộ hồ sơ kiểm tra gồm đọc đặc tả, đọc ma trận, sinh đề và đáp án; dùng khi yêu cầu nhiều bước hoặc đối chiếu cả bộ.
load: demand
groups: giao-vien, to-truong
---
# Hồ sơ kiểm tra có đối chiếu

Thực hiện đúng các sản phẩm người dùng yêu cầu. Nếu chỉ đọc một tài liệu hoặc chỉ giải đề thì dùng skill tương ứng, không bắt buộc tạo cả bộ.

1. Đọc `pvta-doc-dac-ta` bằng skill_read khi có bản đặc tả: chuẩn hóa yêu cầu cần đạt, mức độ và vị trí nguồn.
2. Đọc `pvta-doc-ma-tran` khi có ma trận: chuẩn hóa bảng, kiểm số câu/ý, điểm và các tổng. Đối chiếu với đặc tả; liệt kê xung đột hoặc phần chưa đọc rõ. Nếu thiếu ràng buộc thiết yếu, hỏi cụ thể trước khi sinh đề; không thay nguồn bằng cấu trúc mẫu.
3. Đọc `pvta-sinh-de` khi cần đề mới: lập bảng phân bổ có truy nguyên, viết câu theo ràng buộc, giải kiểm độc lập và đối chiếu bao phủ.
4. Đọc `pvta-dap-an` khi cần đáp án: giải từng câu, kiểm nhãn, lời giải và điểm thành phần. Tách bản học sinh khỏi bản giáo viên.
5. Trước khi xuất, báo kiểm tra: yêu cầu nào được bao phủ bởi câu nào; số câu/ý và điểm từng dạng/mức độ; thiếu dữ liệu, lỗi hoặc phần chưa xác minh. Dùng run_code (tính bằng Python) hoặc công thức Excel cho tổng và tỉ lệ. Không tuyên bố đạt chỉ vì tổng điểm đúng.
6. Chỉ xuất các tệp đã được yêu cầu, giữ mã đề và bảng đối chiếu đồng nhất. Chế độ Chỉ đọc chỉ trả nội dung; Hỏi duyệt tạo đề xuất; Tự sửa áp dụng qua công cụ. Chỉ thông báo đường dẫn tệp sau kết quả công cụ thành công.

Kết thúc khi các bước thuộc phạm vi đều có đầu ra kiểm chứng được hoặc vấn đề còn mở được nêu cụ thể. Người dùng quyết định phê duyệt nội dung chuyên môn.
"""#),
        ("pvta-phap-ly", #"""
---
name: pvta-phap-ly
description: Trình bày và rà soát cấu trúc văn bản pháp lý Word, hợp đồng, đơn, văn bản quy phạm pháp luật; giữ nguyên điều khoản và kiểm chứng căn cứ, hiệu lực, thẩm quyền.
load: demand
groups: van-thu, hieu-truong, hieu-pho
---
# Văn bản pháp lý có nguồn và kiểm soát thay đổi

## Phân loại trước khi thiết kế
Xác định đây là văn bản quy phạm pháp luật, quyết định cá biệt, hợp đồng, đơn/biểu mẫu tố tụng hay báo cáo phân tích pháp luật. Xác định quốc gia, lĩnh vực, thời điểm áp dụng và mục đích sử dụng. Không áp Nghị định 30 cho tất cả loại tài liệu; văn bản hành chính đọc thêm pvta-hanh-chinh.
Với văn bản quy phạm, hồ sơ tham chiếu đã xác nhận có Nghị định 78/2025/NĐ-CP và văn bản sửa đổi 187/2025/NĐ-CP. Phải đọc bản hiện hành/hợp nhất và phụ lục đúng loại trước khi khẳng định thể thức. Không dùng bản 78 chưa đối chiếu sửa đổi làm chuẩn cố định. Kiểm tra thêm thay đổi sau mốc nghiên cứu 17/10/2026 khi sử dụng về sau. Nếu công cụ không truy cập được nguồn thì yêu cầu người dùng cung cấp hoặc báo chưa xác minh.

## Bảo toàn ý nghĩa pháp lý
Lập danh sách chủ thể, định nghĩa, quyền, nghĩa vụ, điều kiện, ngoại lệ, thời hạn, số tiền và viện dẫn. Khi chỉ làm đẹp, giữ nguyên từng nội dung đó. Không thay “phải” bằng “có thể”, không lược ngoại lệ hoặc điều kiện vì muốn văn bản ngắn.
Mọi đề nghị sửa câu chữ có thể đổi nghĩa phải trình bày riêng: nguyên văn, đề xuất, tác động cần kiểm tra. Không tự áp dụng. Không tự tạo điều luật, số văn bản, án lệ, chữ ký, con dấu hay tư cách đại diện.
Đối với nguồn trích dẫn, ghi số/ký hiệu, cơ quan, ngày ban hành, điều/khoản/điểm, phạm vi hiệu lực và ngày đối chiếu. Phân biệt dự thảo, văn bản đã ban hành, văn bản hết hiệu lực, sửa đổi một phần và văn bản hợp nhất. Không tuyên bố “đúng pháp luật hiện hành” chỉ từ hình thức đẹp hoặc tên mẫu trên mạng.

## Cấu trúc Word
Giữ thứ bậc phần/chương/mục/điều/khoản/điểm của nguồn. Ánh xạ các cấp hiện có vào heading phù hợp; không tự tạo các cấp rỗng, không biến mọi khoản và điểm thành heading. Không đánh lại số điều khi người dùng chỉ yêu cầu định dạng. Kiểm tra tham chiếu chéo sau mọi thay đổi được duyệt.
Hợp đồng: thông tin các bên, đối tượng/phạm vi, nghĩa vụ, thanh toán, thời hạn, vi phạm, chấm dứt, giải quyết tranh chấp và phụ lục chỉ theo giao dịch thực tế; không coi checklist này là bộ điều khoản bắt buộc cho mọi hợp đồng.
Đơn hoặc biểu mẫu chuyên ngành: dùng mẫu đúng thủ tục/cơ quan, giữ thứ tự trường; chưa rõ thủ tục thì hỏi trước khi điền.
Báo cáo phân tích: tách dữ kiện, vấn đề, căn cứ, phân tích và lựa chọn; ghi rõ giả định và điểm chưa xác minh.
Thiết kế bằng hệ chữ, khoảng cách và phân cấp do AI đề xuất, trong giới hạn thể thức của loại văn bản. Không dùng preset Office, màu trang trí hoặc chữ nhỏ để ép trang. Bảng chỉ dùng cho dữ liệu hoặc đối chiếu ngắn; để điều khoản dài ở văn xuôi. Không đưa chữ ký hoặc xác nhận giả vào mẫu.

## Kiểm tra bàn giao
Đối chiếu nội dung trước/sau: số tiền, ngày, chủ thể, viện dẫn, ngoại lệ, thuật ngữ định nghĩa, tổng số điều và phụ lục. Giữ khối ký cùng nhau; kiểm tra ngắt trang, bảng, đánh số và mục lục nếu được yêu cầu. Chỉ xác nhận kiểm tra trực quan sau khi đã xem kết xuất.
Sửa Word hiện có bằng word_read rồi word_edit trên bản sao; đọc cấu trúc trước khi ghi. Nếu công cụ không hỗ trợ theo dõi thay đổi thì giao bản sao và danh sách đề xuất, không giả lập Track Changes. DOCX là nguồn sửa; PDF là bản xem/in. Không khẳng định giá trị pháp lý của bản xuất, chữ ký hoặc tư vấn chỉ vì đã dùng skill.
"""#),
        ("pvta-ra-soat", #"""
---
name: pvta-ra-soat
description: Rà soát đối chiếu số liệu, lỗi chính tả và tính nhất quán giữa Word, Excel, PowerPoint, PDF.
load: demand
groups: giao-vien, to-truong, hieu-pho, van-thu, ke-toan
---
Lập danh sách phát hiện theo vị trí nguồn, nội dung đang có, đề xuất và lý do. Tính lại số bằng run_code (tính bằng Python) hoặc công thức Excel. Phân biệt lỗi chắc chắn và chỗ cần người dùng xác nhận. Với tài liệu đang mở, đọc dữ liệu hiện thời trước khi sửa. Chỉ đề xuất sửa những vị trí đã kiểm chứng.
"""#),
        ("pvta-sinh-de", #"""
---
name: pvta-sinh-de
description: Sinh đề kiểm tra bám ma trận và bản đặc tả đã đối chiếu; phân bổ từng câu, giữ thang điểm nguồn, tách đề học sinh khỏi đáp án.
load: demand
groups: giao-vien, to-truong
---
# Sinh đề kiểm tra theo nguồn

1. Đọc skill `pvta-doc-ma-tran` và `pvta-doc-dac-ta` qua skill_read khi nguồn tương ứng chưa được chuẩn hóa. Lấy cấu trúc từ ma trận/đặc tả và yêu cầu người dùng; khi không có nguồn, hỏi các ràng buộc thiết yếu hoặc trình cấu trúc đề xuất để người dùng quyết định. Không áp sẵn số câu, tỉ lệ, thang 10 hoặc coi một mẫu là quy định chung.
2. Lập bảng phân bổ trước khi viết: mã câu/ý → mã yêu cầu cần đạt → chủ đề → mức độ → dạng câu → điểm → vị trí nguồn. Mỗi yêu cầu bắt buộc phải có câu bao phủ, mỗi câu phải có căn cứ. Giải quyết mâu thuẫn trước khi chốt đề, không âm thầm chọn một nguồn thắng.
3. Viết đúng số câu và ý theo bảng. Câu nhiều lựa chọn có một đáp án đúng, các phương án khác nhau và cùng loại/đơn vị; phương án nhiễu phản ánh sai lầm có thể giải thích. Câu đúng/sai có từng mệnh đề độc lập đủ dữ kiện, tách số câu và số ý. Câu tự luận có yêu cầu rõ, dữ kiện đủ và điểm phù hợp. Mức độ dựa vào thao tác tư duy thực, không chỉ động từ.
4. Giải độc lập từng câu, dùng run_code (tính bằng Python) hoặc công thức Excel cho phép tính, đối chiếu đơn vị, điều kiện và đáp án duy nhất. Nếu phép tính đã được công cụ xác nhận trong hội thoại, dùng lại kết quả đúng ngữ cảnh. Với lỗi/mơ hồ, sửa câu rồi giải lại; không giữ câu lỗi chỉ để đủ số lượng.
5. Kiểm toàn đề với bảng phân bổ: không trùng/mất mã, không vượt phạm vi, tổng số câu/ý và điểm theo hàng/cột khớp nguồn. Kiểm ngữ liệu, hình/bảng tham chiếu có thực và đủ để trả lời. Chưa kiểm được phần nào phải nêu rõ.
6. Đề học sinh tách đáp án và dấu hiệu chỉ đáp án. Nếu người dùng yêu cầu đáp án, dùng `pvta-dap-an`. Nếu yêu cầu tệp, xuất word_create (hoặc định dạng được hỗ trợ đã chọn), gồm đề và đáp án tách tệp hoặc ngắt trang theo yêu cầu; chỉ báo tạo thành công khi công cụ xác nhận. Nếu yêu cầu JSON thì trả dữ liệu, không tạo tệp ngoài yêu cầu.

Hoàn thành khi từng câu đã được giải, kiểm bao phủ và kiểm điểm; báo rõ mọi phần còn cần duyệt, không tự công bố đề đã được phê duyệt.
"""#),
        ("pvta-word", #"""
---
name: pvta-word
description: Tạo và sửa tài liệu Word (.docx) bằng word_read, word_create, word_edit: tiêu đề, đoạn, bảng, ảnh, công thức Toán/Hóa. Dùng khi thầy cô nhờ soạn, sửa hoặc trình bày tệp Word.
load: demand
groups: word, giao-vien, to-truong, hieu-pho, hieu-truong, van-thu, ke-toan, thu-vien, thiet-bi
---
# Làm việc với tệp Word (.docx)

## Khi nào dùng
- Soạn tài liệu Word mới (giáo án, đề, công văn, báo cáo) hoặc sửa tệp .docx có sẵn.

## Quy định
- Sửa luôn trên bản sao; tệp gốc không bị ghi đè và mọi thay đổi cần thầy cô duyệt. (Nguồn: quy tắc an toàn của PVTA)
- Quy định thể thức (lề, phông, cỡ chữ) phải lấy từ văn bản quy định hoặc mẫu của trường, ghi rõ tên văn bản; không tự bịa. (Nguồn: Nghị định 30/2020/NĐ-CP, Phụ lục I, cho văn bản hành chính)

## Quy trình
1. Tệp có sẵn: gọi word_read để xem từng khối có số thứ tự, rồi lập danh sách thao tác. Số khối luôn là số của tài liệu gốc.
2. Tạo mới: word_create với tiêu đề, heading (cấp 1–3), paragraph, list, table (hàng đầu là tiêu đề cột), equation, image, page_break. Chữ thuần, không dùng ký hiệu Markdown.
3. Sửa: word_edit với replace, setText, insertParagraph, insertTable, insertEquation, insertImage, delete, format. Chữ cần thay xuất hiện nhiều lần thì dùng setText cho đúng đoạn.
4. Công thức viết LaTeX trong dấu đô la, ví dụ $x^2+1$; hóa học viết \ce{2H2 + O2 -> 2H2O}.
5. Đọc lại bằng word_read sau khi sửa để đối chiếu nội dung.

## Danh sách kiểm tra
- [ ] Không đổi chữ, số liệu, công thức ngoài phần được yêu cầu.
- [ ] Số khối, thứ tự và đề mục đúng.
- [ ] Đã đọc lại bản sao sau khi sửa.

## Tài liệu tham chiếu
- Nghị định 30/2020/NĐ-CP về công tác văn thư (cho văn bản hành chính).
"""#),
        ("pvta-excel", #"""
---
name: pvta-excel
description: Tạo và sửa bảng tính Excel (.xlsx) bằng excel_read, excel_create, excel_edit: sổ điểm, báo cáo, công thức, tô màu, lọc, biểu đồ. Dùng khi thầy cô nhờ lập hoặc sửa tệp Excel.
load: demand
groups: excel, giao-vien, to-truong, hieu-pho, hieu-truong, ke-toan, thiet-bi
---
# Làm việc với tệp Excel (.xlsx)

## Khi nào dùng
- Lập sổ điểm, bảng thống kê, báo cáo số liệu hoặc sửa tệp .xlsx có sẵn.

## Quy định
- Sửa luôn trên bản sao; tệp gốc không bị ghi đè và mọi thay đổi cần thầy cô duyệt. (Nguồn: quy tắc an toàn của PVTA)
- Công thức tính điểm, xếp loại phải theo quy chế đánh giá của nhà trường hoặc thông tư hiện hành mà thầy cô cung cấp; không tự đặt hệ số. (Nguồn: quy chế đánh giá học sinh do thầy cô cung cấp)

## Quy trình
1. Tệp có sẵn: gọi excel_read để thấy giá trị và công thức {=...} của từng ô.
2. Tạo mới: excel_create với rows (hàng đầu là tiêu đề), điểm và tiền là số thật (8.5), chuỗi bắt đầu bằng = là công thức. PVTA tính sẵn giá trị và báo lỗi công thức.
3. Sửa: excel_edit với set, setRows, style (màu nền, chữ đậm, định dạng số, căn lề, viền), filter, freeze, merge, width, addSheet, chart.
4. Đối chiếu giá trị công thức trong báo cáo với phép tính tay ở vài dòng mẫu.

## Danh sách kiểm tra
- [ ] Số liệu là số, không phải chuỗi có dấu chấm ngăn cách.
- [ ] Công thức không báo lỗi trong báo cáo.
- [ ] Tổng, trung bình đã đối chiếu.

## Tài liệu tham chiếu
- Quy chế đánh giá xếp loại của nhà trường (do thầy cô cung cấp).
"""#),
        ("pvta-powerpoint", #"""
---
name: pvta-powerpoint
description: Tạo và sửa bài trình chiếu PowerPoint (.pptx) bằng powerpoint_read, powerpoint_create, powerpoint_edit: bố cục có sẵn, chủ đề màu theo môn, sửa chữ, phông, màu, vị trí.
load: demand
groups: powerpoint, giao-vien, to-truong, hieu-truong, doan-doi
---
# Làm việc với tệp PowerPoint (.pptx)

## Khi nào dùng
- Dựng bài giảng, báo cáo trình chiếu hoặc sửa chữ, phông, màu, vị trí hình trong tệp .pptx.

## Quy định
- Sửa luôn trên bản sao; tệp gốc không bị ghi đè và mọi thay đổi cần thầy cô duyệt. (Nguồn: quy tắc an toàn của PVTA)
- Cỡ chữ tối thiểu cho học sinh cuối lớp đọc được: tiêu đề 32–40 pt, nội dung 24–28 pt. (Nguồn: khuyến nghị thiết kế của PVTA)

## Quy trình
1. Tệp có sẵn: gọi powerpoint_read để xem từng slide và mã hình.
2. Tạo mới: powerpoint_create với subject (môn học để chọn màu, phông) và slides có bố cục title, content hoặc twoColumns; mỗi slide một thông điệp, tối đa khoảng 6–7 dòng.
3. Sửa: powerpoint_edit với text, style (phông, màu), move (x, y tính bằng cm).
4. Lời dẫn của giáo viên viết trong phần ghi chú của người nói nếu tệp có; không dồn lên slide.

## Danh sách kiểm tra
- [ ] Tiêu đề các slide cùng vị trí và cỡ.
- [ ] Không chữ tràn khung; slide quá dày thì đề nghị tách.
- [ ] Không xóa hay thay hình, bảng của thầy cô.

## Tài liệu tham chiếu
- Khuyến nghị thiết kế trình chiếu của PVTA.
"""#),
    ]
}
