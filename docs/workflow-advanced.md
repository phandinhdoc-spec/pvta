# Quy trình nâng cao — nhiệm vụ 26

Toàn bộ chức năng nằm trong PVTACore và dùng chung RPC cho CLI/Desktop. Không chạy AI hoặc tác vụ chỉ vì lưu, chèn mẫu hay thiết kế bản nháp.

## Duyệt bản viết lại

Với quy trình thông thường:

1. Gọi `workflow.promptPreview` với `id`, `revision`. Lõi kiểm tra nguồn trước khi gọi AI và trả `id` của bản duyệt, bốn mô tả cùng prompt YAML theo từng mã bước.
2. Hiển thị `prompts` cho người dùng. YAML giữ `original` nguyên văn; bốn mục sửa được là `input`, `task`, `output`, `check`.
3. Gọi `workflow.run` với `id`, `revision`, `approved: true`, `draftId`. Có thể gửi `edits` dạng `{mã-bước: {input, task, output, check}}` và `retry: true` để chạy lại phần lỗi.

Thiếu bản duyệt thì RPC không chạy. Bản duyệt gắn với định nghĩa, quy trình con, đầu vào và tài nguyên: đổi một trong các phần đó phải xem lại. Lỗi viết lại không tự chuyển sang chạy. `workflow.promptCancel` nhận mã quy trình để hủy cả lượt đang viết lại và bản duyệt đã có. Bản duyệt tạm không lưu qua lần khởi động lõi.

`workflow.promptSave` nhận `draftId`, tùy chọn `edits`, chỉ ghi vào bước có `copied: true`; lưu tăng phiên bản và không thực thi. Lượt xem trước tiếp theo dùng bản đã lưu, không nhờ AI viết lại lần nữa. Khi sửa nội dung prompt, bản viết lại lưu kèm hết hiệu lực.

Quy trình có chỉ thị biến/hàm dùng nguyên chỉ thị, bỏ qua viết lại; vẫn cần `approved: true` và đúng phiên bản để chạy.

## Biến, hàm và điều khiển

Chỉ thị ở đầu dòng, ngoài khối mã Markdown. Biểu thức do Swift phân tích và tính; không chạy JavaScript, shell hay Python. Hỗ trợ số, chuỗi JSON, true/false/null, mảng, đối tượng; `$ten`, truy cập trường/chỉ số hằng; `+ - * / %`, so sánh, `&& || !` và ngoặc.

```text
!bien so-lan = 0
!gan so-lan = $so-lan + 1
!in $so-lan
!dau-ra = {lan: $so-lan}
```

`!bien` khởi tạo một lần trong lượt chạy, kể cả khi quay lại nút. `!in` ghi nhật ký bước, không làm đầu ra. Mỗi nút có tối đa một `!dau-ra`, giá trị được giữ đúng kiểu trong `StepRecord.value`. Không có `!dau-ra` thì chuyển kết quả AI như trước.

`!dau-vao de-bai = "/đường/dẫn/đề.md"` đọc tệp trong phạm vi được cấp quyền; đường dẫn hoặc liên kết Markdown phải có nháy kép. Ảnh được gắn vào lượt AI, biến giữ thông tin tên ảnh. `!dau-vao ket-qua = @truoc` nhận đầu ra có kiểu từ bước trước. Nhiều nguồn tạo đối tượng theo mã bước, mỗi mục có `name`, `value`.

Hàm khai báo bằng mô tả và các trường đầu ra:

```text
!ham tinh-tong(a, b)
[
  Cộng hai số.
]
{
  tong: tổng hai số
}
!goi ket-qua = tinh-tong(2, 3)
!dau-ra = $ket-qua.tong
```

Gọi `workflow.functionDraft` với `id`, `revision`, `stepId`, `name` để sinh biểu thức thuần, ví dụ `{tong: $a + $b}`. Hiển thị khai báo và `expression`, sau đó gọi `workflow.functionApprove` với `draftId`, `approved: true`. Phê duyệt tăng phiên bản quy trình. Hàm chỉ đọc tham số, không truy cập biến ngoài, tệp/mạng hoặc gọi hàm khác. Kết quả phải đúng tập trường khai báo. Hàm không đầu ra trả `null` và gọi không gán biến. Đổi khai báo hoặc nhân bản/nhập mẫu không mang phê duyệt cũ sang.

Ví dụ đếm đến 3 gồm bốn nút: `start` khai báo `!bien so-lan = 0`; `left`, `right` chờ `start` và làm công việc AI; `check` chờ cả hai rồi chạy:

```text
!gan so-lan = $so-lan + 1
!in $so-lan
!dau-ra = $so-lan
!lap-lai "start" neu $so-lan < 3
!dung neu $so-lan == 3
```

Nhật ký `check` là 1, 2, 3. Các nút trên đường từ `start` đến `check` được chạy lại, biến giữ nguyên. Nhánh thoát trước nút kiểm tra bị từ chối. `!dung` không mở bước mới. Chỉ thị chạy trước phần prompt AI; điều khiển đúng kết thúc các chỉ thị còn lại và bỏ phần AI tại nút đó.

Quy trình có trạng thái chạy tuần tự theo phụ thuộc, các nút sẵn sàng theo thứ tự danh sách. Lỗi chỉ thị dừng toàn lượt. Giới hạn 100 vòng và 30 phút toàn lượt (kiểm tra trước khi mở bước mới, không cắt lượt AI đang chạy). Giới hạn biểu thức 20.000 ký tự, giá trị biến 60.000 ký tự, kết quả bước 20.000 ký tự, nhật ký mỗi bước 60.000 ký tự. Chạy lại phần lỗi của quy trình có trạng thái bị từ chối: phải chạy trọn lượt mới.

## Khung và quy trình con

`workflow.save` nhận thêm `frames`, mỗi khung có `id`, `name`, `steps` là mã nút và `decl` tùy chọn chứa khai báo `!bien`/`!ham`. Khung lồng tối đa ba tầng; chồng một phần, cùng tập nút hoặc tham chiếu nút không tồn tại đều bị từ chối.

Tên ngoài khung thuộc toàn quy trình. Khung con thấy và cập nhật biến cha; cấm che tên cha và khai báo trùng trong cùng phạm vi. Hai khung rời nhau có thể có tên giống nhau.

Một bước có `subWorkflowId` tham chiếu quy trình con. Lõi chặn vòng, tham chiếu thiếu và quá ba tầng tính cả quy trình gốc. Khi chạy, các bước con nhận mã có tiền tố, gốc con chờ phụ thuộc của nút cha, bước sau chờ kết quả cuối của con; tài nguyên của nút cha được truyền cho các bước con. Khung con được giữ và khung bọc nút cha bao cả phần con. Không xóa quy trình còn được tham chiếu. Giới hạn sau trải phẳng là 100 bước. Chỉ thị trạng thái chưa áp dụng cho Plan hoặc quy trình con trải phẳng, giống phạm vi MySoft tham khảo.

## Mẫu, nhân bản và thiết kế

- `template.fromWorkflow`: `id`, `name`; lưu cấu trúc thành mẫu. Quy trình con được trải phẳng thành bản sao độc lập.
- `template.export`: `id`; trả đối tượng JSON mẫu. `template.import`: `json` (chuỗi JSON), `chatId`; tạo quy trình mới.
- `template.list`, `template.save` (`template`), `template.delete` (`id`) quản lý mẫu trong DataStore.
- `template.insert`: `templateId`, `id` quy trình/Plan đích, `revision`; chèn các bước có mã mới, giữ phụ thuộc nội bộ, không sửa mẫu gốc. Chuyển các phụ thuộc cũ thành tường minh để không vô tình chạy theo liên kết mới.
- `workflow.linkResolve`: `id`, `revision`, `from`, `to`, `accept`; nhận/bỏ gợi ý liên kết. Gợi ý chưa được nhận không có hiệu lực khi chạy.
- `workflow.duplicate`: `id`, `chatId`; tạo bản sao mới, không mang lịch sử/phê duyệt. Ghim dùng `workflow.pin` đã có.

Mẫu và bản sao dùng model `auto`, quyền Chỉ đọc; bỏ thư mục, nguồn tệp/ảnh, đầu ra tệp, đầu vào chung, lịch sử và phê duyệt hàm. Khai báo `!dau-vao` trỏ tệp chuyển thành `@truoc` để người dùng chọn lại nguồn. Văn xuôi trong prompt vẫn có thể chứa thông tin riêng: nội dung này được giữ theo yêu cầu gốc, không suy đoán để xóa.

`workflow.designStart` nhận `chatId`, tùy chọn `model`, trả phiên thiết kế. Gửi `workflow.designContinue` với `id` phiên và `text`; AI chỉ dùng trao đổi của phiên đó, trả bản nháp và câu hỏi còn thiếu. `workflow.designApply` với `id`, `approved: true` lưu bản đã xem, không chạy. `workflow.markdownDraft` nhận `chatId`, `text`, tùy chọn `model` để bắt đầu từ bản mô tả Markdown. `workflow.suggest` nhận `id` quy trình, `stepId`, `request`, chỉ trả gợi ý prompt và phiên bản để người dùng sửa/lưu qua `workflow.save`.

## Đối chiếu và kiểm chứng

| MySoft | RPC Swift |
| --- | --- |
| workflowPromptSave / workflowPromptCancel | workflow.promptSave / workflow.promptCancel |
| workflowLinkResolve | workflow.linkResolve |
| workflowMarkdownDraft | workflow.markdownDraft |
| workflowDesignStart | workflow.designStart |
| workflowSuggest | workflow.suggest |
| templateSave / templateInsert / templateDelete | template.save / template.insert / template.delete |
| templateFromWorkflow | template.fromWorkflow |

Test nằm trong `Tests/PVTACoreTests/AutomationTests.swift`, dùng backend giả và thư mục tạm. Chưa kiểm chứng chất lượng sinh biểu thức/thiết kế bằng AI thật hoặc giao diện Desktop.
