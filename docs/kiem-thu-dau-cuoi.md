# Kiểm thử đầu-cuối — nhiệm vụ 46

Bộ kiểm thử ở `Tests/PVTACoreTests/EndToEnd46Tests.swift` chạy tiến trình `pvta call` thật, truyền tham số bằng `--file`, đọc JSON từ stdout, sự kiện từ stderr và kiểm tra mã thoát. Tiến trình CLI nối qua Unix socket tới PVTANode/ChatLoop thật trong tiến trình test. Chỉ AI được thay bằng HTTPTransport giả và KeyStore trong bộ nhớ; không thay handler nghiệp vụ hoặc ghi trực tiếp dữ liệu để giả kết quả.

Mỗi test dùng thư mục dữ liệu, thư mục cấp quyền và hội thoại riêng trong vùng tạm. Các fixture được sao chép từ `Tests/Fixtures`; không sửa mẫu nguồn hoặc dữ liệu người dùng. Kết quả và log của tiến trình con được dọn sau test. Các lời gọi con có giới hạn chờ 30 giây, tránh giữ CI vô hạn.

## Sáu luồng

| Luồng | Gọi qua CLI | Kiểm chứng |
|---|---|---|
| Sửa Word | `chat.send` → AI giả yêu cầu `word_edit`; `action.list/approve` | Chưa duyệt chưa có bản sao; nguồn không đổi một byte; giải nén XML kết quả bằng unzip xác nhận tiêu đề Toán 8 → Toán 9, còn bảng Khởi động; có sự kiện công cụ |
| Đọc Excel | `chat.send` → `excel_read` | Nhật ký công cụ thật có Học sinh mẫu A, 9.5, Giỏi; nguồn không đổi; không sinh yêu cầu ghi |
| Tách PDF | `pdf.read/split`, `action.approve`, `pdf.read` | Một trang đúng nội dung nguồn tiếng Việt; PDFKit mở lại được; nguồn không đổi |
| Tạo slide | `powerpoint.create/read`, `action.decline/approve` | Từ chối không tạo tệp; duyệt tạo đủ ba slide; nội dung đọc lại đúng; unzip kiểm tra gói không hỏng |
| Plan | `plan.suggest/save/run/get` | Lập và sửa chưa thực thi; thiếu duyệt bị chặn; duyệt bước đầu trả waiting, chưa chạy bước sau; duyệt bước sau hoàn tất và đọc lại được |
| Đa nhánh | `workflow.save/promptPreview/run/get` | Thiếu bản xem trước bị chặn; viết lại chưa thực thi; hai nhánh đều tới AI đang bị giữ, bước hợp nhất chưa chạy; chỉ thả cổng khi cả hai cùng chạy; hợp nhất nhận đủ hai kết quả |

Fixture dùng lại: `giao-an.docx`, `bang-diem.xlsx`, `pdf-tieng-viet.pdf`. Slide mới được tạo trong thư mục tạm. Đây là dữ liệu mẫu tổng hợp, không phải hồ sơ học sinh thật.

## Chạy trên máy

```sh
swift build
swift test --filter e2e46
swift test
```

Build trước khi test để `.build/debug/pvta` là binary mới. Có thể chỉ rõ binary bằng `PVTA_TEST_BINARY` khi kiểm thử E2E ở đường dẫn build khác. Máy cần macOS Apple Silicon, Xcode/Swift 6, Python 3 (cho bộ CLI hiện có) và Typst (cho bộ test dàn trang hiện có).

## GitHub Actions

`.github/workflows/kiem-thu.yml` chạy khi push vào `main` hoặc push tag; không có trigger pull request, lịch định kỳ hoặc chạy tay. Một job trên `macos-15` kiểm tra `uname -m` phải là arm64, cài Typst nếu thiếu, chạy `swift build` rồi toàn bộ `swift test` (đã gồm sáu test E2E). Một ref chỉ giữ lượt mới nhất; timeout 30 phút; chỉ giữ log kiểm thử trong 7 ngày, không tải mã nguồn hoặc gói ứng dụng làm artifact.

Giả định nhánh chính tên `main`; cần đổi bộ lọc nếu kho đích dùng tên khác. Không cần secret hoặc khóa API cho bộ test.

Nhãn runner và bộ lọc push được đối chiếu với [danh sách runner GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) và [cú pháp workflow](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax). Phiên bản action theo [checkout](https://github.com/actions/checkout) và [upload-artifact](https://github.com/actions/upload-artifact).

## Trạng thái kiểm chứng ngày 10/11/2026

- `swift build`: đạt.
- `swift test --filter e2e46`: 6/6 đạt.
- Kiểm tra YAML và bộ lọc chỉ main/tag: đạt bằng Ruby YAML; đây không phải một lượt chạy GitHub Actions.
- `swift test`: **533/533 đạt** (492 PVTACoreTests + 8 NhapDuLieuTests + 33 CLITests), gồm 6 test E2E mới. Bộ CLI qua PTY hoàn tất sau khoảng 82 giây.
- CI: đã nối remote `https://github.com/phandinhdoc-spec/pvta.git` theo chỉ định người dùng. Đang đưa mã nguồn và workflow lên main để kiểm tra CI; nhiệm vụ 46 giữ `[ ]` cho tới khi có bằng chứng CI xanh.
- Chưa kiểm chứng AI thật, thao tác mở/hiển thị bằng Microsoft Office thật trong lượt này, hoặc mọi biến thể tệp Office/PDF bên ngoài. Backend AI giả chỉ xác nhận luồng tích hợp, không đánh giá chất lượng trả lời của model thật.
