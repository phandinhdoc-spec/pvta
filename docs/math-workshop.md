# Xưởng Toán — kho công thức Toán Lý Hóa

Phạm vi nhiệm vụ 37 đã được người giao chốt: soạn, lưu, liệt kê công thức LaTeX và xuất Equation Word. Không chuyển phần đồ thị, hình học, máy tính hoặc biến thể bài tập của MySoft.

## Soạn và lưu

Gọi `math.save` với `title`, `subject` (`math`, `physics`, `chemistry`), `latex`. Tạo mới bỏ `id`, `baseRevision` mặc định 0. Khi sửa, gửi `id` và `baseRevision` của bản vừa đọc. Lõi từ chối bản cũ, không ghi đè sửa đổi của cửa sổ khác. Trả về `id`, `revision`, `title`, `subject`, `latex`, `updatedAt`; phát `math.changed` sau khi lưu.

```sh
pvta call math.save '{"title":"Động năng","subject":"physics","latex":"E_k=\\frac{1}{2}mv^2"}'
pvta call math.save '{"title":"Phản ứng tạo nước","subject":"chemistry","latex":"\\ce{2H2 + O2 -> 2H2O}"}'
pvta call math.list '{}'
pvta call math.list '{"subject":"chemistry"}'
```

`math.list` trả các mục mới sửa trước, có thể lọc theo môn. LaTeX là nội dung công thức, không bọc trong `$...$`, `$$...$$` hoặc một tài liệu TeX. Hỗ trợ tập con đã có ở nhiệm vụ 15: phân số, căn, chỉ số, tổng/tích phân, hàm lượng giác, ký tự Hy Lạp, ma trận/hệ và `\ce{...}` cho phương trình hóa học. Lệnh ngoài tập hỗ trợ bị từ chối; không gọi chương trình TeX hay thực thi lệnh trong công thức.

Tên tối đa 200 ký tự, LaTeX tối đa 8.000 ký tự, kho tối đa 1.000 công thức. Kho dùng SQLite chung (`math.workshop.v1`), có trong xuất/nhập DataStore; dữ liệu hỏng không tự bị thay bằng kho trống. Chế độ Chỉ đọc không cho lưu. Đây là chức năng soạn trực tiếp qua RPC, không đăng ký công cụ cho AI tự ghi kho.

## Xuất Word

`math.export` nhận `path` tới tệp `.docx` mới, `chatId` để gắn yêu cầu duyệt, tùy chọn `title`, và `items` là danh sách `{id, revision}` lấy từ `math.list`. Chọn 1–100 mục, thứ tự chọn là thứ tự xuất. Không nhận đường dẫn xuất định dạng khác hay mã công thức không tồn tại.

```json
{
  "path": "/thu-muc-da-cap-quyen/cong-thuc.docx",
  "chatId": "MA_HOI_THOAI",
  "title": "Công thức ôn tập",
  "items": [{"id": "MA_CONG_THUC", "revision": 1}]
}
```

Lõi chuẩn bị tài liệu và kiểm cú pháp trước khi hỏi duyệt. Chế độ Hỏi duyệt tạo một yêu cầu `math_export` trong hàng đợi thao tác, gồm đường dẫn, tên và nội dung công thức. Khi dùng CLI, giữ `pvta serve` hoặc Desktop chạy để xem/duyệt yêu cầu từ kết nối khác. Chế độ Tự sửa cho phép xuất trong thư mục đã cấp quyền ghi; Chỉ đọc luôn chặn. Cờ `approved` tự gửi trong tham số không thay thế hàng đợi duyệt.

Từ chối, hủy, hết thời gian duyệt, công thức bị sửa trong lúc chờ hoặc mất quyền thư mục đều không xuất tệp. Tệp có sẵn không bị ghi đè. Mỗi công thức trở thành đối tượng OMML chuẩn có thể sửa bằng Equation của Word, không phải ảnh. Kết quả trả `path`, `count`, `format: "docx-omml"`, `changeId` để hoàn tác bằng cơ chế tệp chung.

Công thức Hóa chỉ được định dạng, không tự cân bằng phản ứng, kiểm tra bảo toàn hay kết luận phản ứng xảy ra. Người soạn chịu trách nhiệm nội dung và điều kiện phản ứng. Việc gán môn không phải kiểm chứng tính đúng của công thức.

## Kiểm thử

`swift test --filter math37` dùng kho, thư mục và backend AI giả. Mẫu `Tests/Fixtures/math-workshop.json` gồm phân số/căn, tổng, động năng, định luật Ohm, phản ứng tạo nước, ion sulfate và cân bằng ammonia. Kiểm tra XML của tất cả thành phần DOCX, số đối tượng Equation, đọc lại bằng bộ đọc Word của PVTA, lưu/sửa/xung đột, mở lại SQLite, từ chối công thức sai, cổng duyệt và phạm vi xuất.

Kiểm tra máy thật ngày 09/11/2026: Word for Mac mở tệp do `math.export` tạo ở chế độ chỉ đọc, không sửa chữa, nhận đúng 7 math objects và 15 đoạn; sau đó đóng không lưu. Chưa thử Word Windows hoặc rà trực quan mọi dạng công thức phức tạp.
