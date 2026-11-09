# Plan và quy trình trong lõi

CLI và Desktop gọi cùng RPC qua `Core.call`. Dữ liệu bản nháp, phiên bản và tiến độ lưu trong DataStore (`automation.v1`). Đọc lại dữ liệu không tự chạy công việc.

## Lưu và chạy

`plan.save` và `workflow.save` nhận `name`, `chatId`, `steps`, `input`. Khi sửa, gửi thêm `id` và `revision` vừa đọc; lưu lại tăng phiên bản và xóa kết quả cũ. Plan Pro dùng `plan.save` với `pro: true`.

Ví dụ tham số `workflow.save`:

```json
{
  "name": "Soạn và kiểm tra",
  "chatId": "mã-hội-thoại",
  "parallel": false,
  "concurrency": 2,
  "input": {"kind": "text", "value": "Soạn bài về sự bay hơi"},
  "steps": [
    {"id": "soan", "prompt": "Soạn theo yêu cầu: {{input}}", "model": "auto"},
    {"id": "kiem", "prompt": "Kiểm tra nội dung: {{prev}}", "needs": ["soan"]}
  ]
}
```

Mỗi bước có `id`, `name`, `prompt`, `model`, `needs`, `resources`, `criteria`, `stopOnError`; mặc định chỉ đọc. Bước sửa cần `write: true` và `directory` tuyệt đối đã cấp quyền. `outputs` khai báo đường dẫn kết quả để đối chiếu trước/sau. Quyền sửa của bước vẫn chịu chính sách duyệt công cụ của lõi.

`workflow.run` nhận `id`, `revision`, `approved: true`; `retry: true` chạy lại phần lỗi. Từ nhiệm vụ 26, quy trình thông thường cần thêm `draftId` từ `workflow.promptPreview`; xem [quy trình nâng cao](workflow-advanced.md) về duyệt YAML, biến/hàm và mẫu. `plan.run` cần thêm `stepId`, chỉ chạy đúng bước đó rồi dừng. Lời gọi chờ đến khi chạy xong; có thể gọi `.cancel` từ lời gọi khác. Sự kiện `automation.delta` phát nội dung đang sinh, `automation.changed` phát tiến độ; `plan.get`/`workflow.get` đọc bản lưu.

`parallel: false` thêm phụ thuộc bước trước. `parallel: true` chạy theo `needs`, đồng thời 1–4 bước (mặc định 2). Bước sửa chạy độc quyền trong bộ chạy, kể cả giữa các quy trình. Nhánh lỗi không hủy nhánh độc lập trừ `stopOnError`; bước chờ nhánh lỗi được bỏ qua kèm lý do. Chạy lại chỉ giữ kết quả có toàn bộ chuỗi phụ thuộc thành công và dấu vân tay cấu hình, đầu vào, tài nguyên không đổi.

## Khảo sát và khôi phục Plan

`plan.suggest` nhận `chatId`, `request`, tùy chọn `model`, `pro`, `input`, `resources`. Lõi khảo sát chỉ đọc; thiếu `input` thì dùng lịch sử hội thoại. Câu hỏi còn thiếu nằm trong `definition.questions` và chặn chạy. Người dùng bổ sung, sửa và lưu bản mới trước khi duyệt. Plan Pro có lượt phản biện riêng cho bản nháp và kết quả bước.

`plan.skipStep` bỏ qua bước; bước phụ thuộc vẫn bị chặn do thiếu kết quả. `plan.replaceInput` nhận `id`, `stepId`, `text` để cung cấp kết quả thay thế. Bước sửa lỗi hoặc gián đoạn phải đối chiếu trước.

`plan.inspectRecovery` nhận `id`, `stepId`, trả dấu vân tay hiện tại và dữ liệu trước/sau. Sau khi đối chiếu, `plan.resolveRecovery` nhận `revision`, `observed` là dấu vân tay vừa xem, `confirmed: true`, `decision: "retry"` hoặc `"complete"` (cần `output`). Tệp thay đổi sau lần xem hoặc tác động chưa rõ vẫn bị chặn. Khôi phục không tự thực thi; phải duyệt chạy lại. Bước sửa cần khai báo `outputs` để có thể khôi phục.

## Đầu vào và tài nguyên

`input.kind` hỗ trợ `text`, `file`, `directory`, `chat`, `prompt`; `value` là nội dung, đường dẫn, mã chat hoặc lời nhắc tương ứng. Chat lấy tin nhắn người dùng; chat và lời nhắc mẫu được chụp nội dung khi lưu RPC. Đầu vào tối đa 60.000 ký tự, vượt thì báo lỗi.

`resources` mỗi bước nhận đường dẫn tệp/thư mục, ảnh, `/skill` và `#quy-tắc`. Văn bản tối đa 20.000 ký tự/tệp và 60.000 ký tự/bước; thư mục lấy tối đa 40 tệp hỗ trợ, không ẩn, ở cấp trực tiếp. Ảnh tối đa 10, mỗi ảnh 5 MB, tổng 20 MB. Vượt giới hạn hoặc thiếu tệp đều báo lỗi, không cắt âm thầm. Skill và quy tắc được chọn rõ ràng; tài nguyên đưa vào ngữ cảnh với vai trò dữ liệu.

## Đối chiếu phương thức MySoft

| Tên cũ | RPC Swift |
| --- | --- |
| suggestPlan | plan.suggest |
| savePlan, editPlan | plan.save |
| runPlan | plan.run |
| replacePlanInput | plan.replaceInput |
| skipPlanStep | plan.skipStep |
| inspectPlanRecovery, resolvePlanRecovery | plan.inspectRecovery, plan.resolveRecovery |
| workflowRun, workflowCancel | workflow.run, workflow.cancel |
| workflowSave, workflowDelete | workflow.save, workflow.delete |
| workflowPin, workflowOpenChat | workflow.pin, workflow.openChat |
| chatWorkflow | chat.workflow |

Hai nhóm còn có `.list`, `.get`, `.pin`, `.openChat`, `.delete`. Kiểm chứng tự động dùng AI giả và thư mục tạm; không gọi AI thật. Khôi phục khi tiến trình chết được kiểm tra bằng bản lưu có trạng thái đang chạy rồi tạo lại bộ chạy.
