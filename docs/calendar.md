# Lịch và thời khóa biểu cục bộ

Nhiệm vụ 31 bổ sung `calendar.*` trong PVTACore. CLI và Desktop gọi cùng phương thức qua Core. Dữ liệu lịch nằm trong SQLite chung, khóa `calendar.v1`; bản sao đính kèm ở `calendar-attachments/` trong thư mục dữ liệu. Phần này không đăng nhập hoặc đồng bộ Google; đó là nhiệm vụ 32.

## Lưu và đối chiếu phiên bản

`calendar.saveEvent` nhận `data`, tùy chọn `localId`, `baseRev`. Mục mới không có mã dùng `baseRev: 0`; sửa mục cũ phải gửi đúng phiên bản đã đọc. Ví dụ:

```json
{
  "data": {
    "summary": "KHTN 8A — Áp suất",
    "start": "2026-11-09T07:30:00+07:00",
    "end": "2026-11-09T08:15:00+07:00",
    "location": "Phòng 8A",
    "description": "Mang dụng cụ thí nghiệm"
  }
}
```

Sự kiện có `summary`, `start`, `end`, tùy chọn `allDay`, `timeZone` (mặc định `Asia/Ho_Chi_Minh`), `location`, `description`, `calendarId`, `colorId`, `recurrence`, `remindersMinutes`. Giờ phải theo ISO-8601; giờ không có độ lệch được hiểu theo `timeZone`. Sự kiện cả ngày dùng `YYYY-MM-DD`, ngày kết thúc không tính vào sự kiện.

`calendar.saveTask` nhận cùng cách định danh/phiên bản, `data` gồm `title`, tùy chọn `notes`, `due` dạng `YYYY-MM-DD`, `done`, `tasklistId`. Đổi `done` để hoàn thành hoặc mở lại việc.

`calendar.writeRev` là đường ghi chung với `kind: "calendar" | "tasks"`, `localId`, `baseRev`, `data`. Nội dung gửi là bản đầy đủ, không phải patch. `calendar.getRecord` nhận `kind`, `localId`; `calendar.listLocal` trả `revision`, `events`, `tasks`, mặc định bỏ mục đã xóa. Có thể gửi `includeDeleted: true` để xem cả bản đánh dấu xóa.

Kết quả ghi có `ok`, phiên bản kho `revision`, danh sách `records`. Khi hai cửa sổ cùng sửa, lượt ghi sau nhận `ok: false`, `reason: "conflict"`, `current` là nội dung mới nhất; không ghi đè. `not-found` và `deleted` phân biệt mục mất hoặc đã xóa.

`calendar.resolveConflict` nhận `kind`, `localId`, `baseRev` vừa xem, `choice`:

- `keep-current`: lấy bản hiện tại, không ghi.
- `use-mine`: gửi thêm `data` đã đối chiếu. Nếu có người sửa tiếp, phiên bản lại xung đột; không có tùy chọn bỏ qua kiểm tra phiên bản.

`calendar.deleteRecord` cần `kind`, `localId`, `baseRev`, `confirmed: true`. Lõi đánh dấu xóa và tăng phiên bản, giữ dữ liệu để không làm sống lại mục khi cửa sổ cũ gửi yêu cầu. Mỗi lần ghi thành công phát `calendar.changed`. Kho lỗi không bị tự thay bằng kho trống.

## Đính kèm

`calendar.addAttachment` nhận `kind`, `localId`, `baseRev`, `sourcePath`, tùy chọn `chatId`. Nguồn phải là tệp trong phạm vi đã cấp. Lõi chép vào kho riêng, tính SHA-256 và tăng phiên bản mục; không sửa tệp gốc. Nếu mục đổi trong lúc chép, bản sao chưa gắn được dọn và trả xung đột.

`calendar.openAttachment` nhận `kind`, `localId`, `attachmentId`, trả đường dẫn bản sao đã kiểm tra nằm trong kho để vỏ ứng dụng mở. `calendar.detachAttachment` nhận thêm `baseRev`, chỉ gỡ liên kết; giữ bản sao và tệp gốc.

Metadata lịch được đưa vào xuất/nhập DataStore hiện có. Tệp nhị phân đính kèm nằm riêng; khi sao lưu toàn bộ tài liệu lịch cần giữ cả thư mục `calendar-attachments/`.

## Giờ trống và lịch trùng

`calendar.findFreeSlots` nhận `start`, `end`, tùy chọn `minutes` (mặc định 45), `timeZone`. Trả các khoảng trống liên tục đủ thời lượng, trong đúng khoảng được yêu cầu; muốn tìm trong buổi sáng thì truyền giờ đầu/cuối buổi. Công việc có hạn ngày không tự chiếm giờ của sự kiện.

`calendar.conflicts` nhận `start`, `end`, tùy chọn `timeZone`, trả các cặp sự kiện trùng cùng khoảng thời gian giao nhau. Hai sự kiện chỉ tiếp giáp không tính là trùng.

Lõi tính cả sự kiện cả ngày và lặp. Hỗ trợ một RRULE `FREQ=DAILY` hoặc `FREQ=WEEKLY`, `INTERVAL` 1–52, tùy chọn `COUNT` 1–1000 hoặc `UNTIL` dạng UTC `yyyyMMddTHHmmssZ`. Quy tắc khác bị từ chối rõ ràng. Khoảng truy vấn tối đa 366 ngày, tối đa 10.000 lần xuất hiện và 1.000 cặp trùng; vượt giới hạn yêu cầu chia nhỏ, không cắt kết quả.

## Lệnh tiếng Việt và quét thời khóa biểu

`calendar.aiCommand` nhận `prompt`, tùy chọn `cursorDate`, `timeZone`, `model`, `chatId`, `paths`, `rawText`. Ví dụ: “Dời tiết KHTN 8A sáng thứ hai sang 9 giờ 30, tạo việc chuẩn bị dụng cụ hạn chủ nhật”. Lõi gửi ngày tham chiếu, bảng ngày trong tuần và lịch hiện tại; không gửi hội thoại khác. AI chỉ sinh JSON, không có công cụ để tự ghi lịch.

`calendar.aiScanTimetable` nhận các trường tương tự, dùng `paths` cho ảnh/tệp hoặc `rawText`, `weekStartDate` để chọn tuần, `repeatWeekly` mặc định `true`. Nếu chọn `false`, lõi buộc không lặp dù AI trả quy tắc lặp. Giờ tiết mẫu theo tài liệu MySoft được nêu trong ngữ cảnh và hiện trong đề xuất; cần kiểm tra/sửa nếu trường dùng giờ khác. Nguồn mờ hoặc thiếu dữ kiện được yêu cầu hỏi lại, không đoán.

Giới hạn nguồn: 10 tệp, mỗi ảnh 5 MB, tổng ảnh 20 MB; văn bản 20.000 ký tự/tệp và 60.000 ký tự tổng. Tệp thiếu, chưa cấp quyền hoặc quá giới hạn báo lỗi trước khi gọi AI. Không cắt nguồn âm thầm.

Kết quả là **đề xuất**, gồm `id`, `revision`, `reply`, `operations`, `conflicts`, `expiresAt`. Các thao tác chuẩn hóa chứa toàn bộ dữ liệu sẽ ghi và phiên bản mục; đính kèm chứa đường dẫn và dấu vân tay tệp. Chưa thay đổi lịch hay chép tệp chỉ vì AI đề xuất.

1. Hiển thị đề xuất và lịch trùng để người dùng xem.
2. Gọi `calendar.aiApplyOps` với `proposalId`, `approved: true`, tùy chọn `chatId`. Không nhận danh sách thao tác mới tại bước áp dụng.
3. Nếu có trùng giờ, phải sửa đề xuất hoặc gửi `allowConflicts: true` sau khi người dùng xác nhận giữ các lịch trùng đã xem.

`calendar.aiRevise` nhận `proposalId`, `operations` đã sửa, tùy chọn `timeZone`, `chatId`; tạo đề xuất mới với kiểm tra xung đột mới và hủy mã cũ. Danh sách sửa dùng `op`: `create_event`, `update_event`, `move_event`, `delete_event`, `create_task`, `update_task`, `complete_task`, `delete_task`, `attach_file`. Sửa/xóa cần đúng `eventId` hoặc `taskId`; không đoán mục theo tên. `attach_file` cần `filePath` và một mục đã tồn tại. Mỗi đề xuất tối đa 100 thao tác, một thay đổi cho mỗi mục.

`calendar.aiGetProposal` đọc lại bằng `proposalId`; `calendar.aiCancel` hủy đề xuất chưa áp dụng. Đề xuất tồn tại tối đa 30 phút trong phiên lõi. Phiên bản lịch thay đổi sau khi xem hoặc tệp đính kèm đổi thì bị chặn, phải xem/duyệt bản mới. Toàn bộ nhóm ghi cùng một giao dịch; lỗi không để lại một phần lịch. Áp dụng thành công tiêu thụ mã đề xuất, không áp dụng lặp lại.

Đề xuất có sự kiện lặp được kiểm tra trùng trong 366 ngày tính từ sự kiện được đề xuất đầu tiên. Không suy diễn rằng các năm sau cũng không trùng. Văn bản AI đang sinh phát qua `calendar.ai.delta`.

## Đối chiếu MySoft và kiểm chứng

Các tên `calendar.saveEvent`, `saveTask`, `getRecord`, `writeRev`, `deleteRecord`, `listLocal` giữ nguyên nhóm `calendar`. Luồng AI trước đây đặt dưới `google.aiCommand`, `google.aiScanTimetable`, `google.aiApplyOps` được tách thành `calendar.aiCommand`, `calendar.aiScanTimetable`, `calendar.aiApplyOps` cho lõi cục bộ. Xung đột phiên bản cục bộ dùng `calendar.resolveConflict`; xử lý xung đột đồng bộ Google thuộc nhiệm vụ 32.

17 test trong `Tests/PVTACoreTests/CalendarTests.swift` dùng AI giả, tệp mẫu và thư mục tạm. Đã kiểm tra CRUD, hai lượt ghi cùng phiên bản, giao dịch không ghi một phần, ngày/giờ, lịch lặp và múi giờ, giờ trống, đính kèm, đề xuất chưa duyệt/cũ/đã hủy, trùng lịch, quét ảnh/tệp và nguồn không hợp lệ. Chưa kiểm chứng chất lượng nhận dạng thời khóa biểu bằng AI thật hoặc giao diện Desktop.
