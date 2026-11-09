# Cầu nối Desktop với lõi — nhiệm vụ 45

Ứng dụng SwiftUI có một `AppState` dùng chung và một `ChatWindowState` cho mỗi cửa sổ. AppState mở PVTANode một lần kể cả khi nhiều cửa sổ mở đồng thời. Lõi vẫn giữ toàn bộ nghiệp vụ, dữ liệu, khóa lượt theo hội thoại và quyết định quyền; Desktop chỉ gọi RPC và trình bày kết quả.

## Sử dụng

Chọn hội thoại có sẵn hoặc bấm **Hội thoại mới**, nhập nội dung rồi **Gửi** (Command–Return). **Cửa sổ mới** mở một cửa sổ chat độc lập. Các cửa sổ có hội thoại được chọn và ô soạn riêng; có thể tiếp tục viết nháp trong khi AI đang trả lời. Trong lúc gửi, cửa sổ giữ nguyên hội thoại để tránh nhầm đích của nút Dừng.

**Dừng** gọi `chat.cancel` cho hội thoại của lượt gửi, kể cả khi vừa bấm Gửi; không hủy mọi lượt trên lõi. Lệnh `/sign` dùng `secretary.cancel` vì lõi chuyển lệnh này sang hội thoại Thư ký riêng. Đóng cửa sổ cũng dừng lượt do cửa sổ đó gửi, giữ kết nối cho cửa sổ còn lại. Hai cửa sổ không gửi đồng thời vào cùng một hội thoại; lõi vẫn có khóa riêng để bảo vệ khi CLI cùng dùng dữ liệu.

Đề xuất quyền xuất hiện trong hộp thoại của hội thoại tương ứng, có nội dung xem trước, đường dẫn và cảnh báo. **Duyệt/Từ chối** gọi `action.approve/decline`; thao tác nguy hiểm cần đánh dấu xác nhận rồi chọn **Vẫn làm**. Có thể **Dừng lượt** ngay trong hộp thoại. Desktop không tự nâng quyền và không tự thực thi thay lõi. Khi một cửa sổ hoặc CLI quyết định, trạng thái hàng đợi cập nhật các cửa sổ khác.

## Định tuyến và vòng đời

- PVTANode thêm callback tùy chọn `onEvent` trong `call`. Sự kiện riêng mang requestId đi qua callback của đúng lời gọi; lời gọi không truyền callback giữ cách nhận qua `node.events` của nhiệm vụ 4.
- Khi là client, ClientLink gắn callback với mã yêu cầu trên socket, xóa khi có kết quả hoặc mất kết nối. Sự kiện riêng không còn yêu cầu đang chờ bị bỏ, không biến thành sự kiện chung.
- AppState là nơi duy nhất đọc `node.events`, chỉ nhận sự kiện không có requestId. Trạng thái chung được chia sẻ với mọi cửa sổ; `data.changed` làm mới danh sách và lịch sử, `actions` cập nhật hộp duyệt, `permission` cập nhật mức quyền.
- Mỗi lượt gửi có một AsyncStream riêng, giữ thứ tự delta trước kết quả. Cửa sổ đã đóng hoặc lượt không còn chủ không nhận thêm dữ liệu. Kết quả tải lịch sử cũ không ghi đè kết quả mới hoặc hội thoại vừa được chọn.
- AppState và trạng thái cửa sổ dùng MainActor. Khởi động nút, gửi tới lõi và chờ AI chạy ngoài main actor; cập nhật giao diện quay về main actor. Không chờ semaphore trên luồng giao diện.
- Khi thoát ứng dụng, NSApplicationDelegate trả `terminateLater`, chờ hủy lượt và `shutdown` bất đồng bộ rồi cho thoát. Đóng một cửa sổ không shutdown nút chung.

Tham khảo MySoft: phần `deliver` trong `chatbox/src-tauri/src/lib.rs`, `chatbox/src/chat-window.ts`, `docs/kiem-ke-rpc-su-kien.md`; triển khai Swift không cần sidecar Tauri.

## Kiểm chứng

`swift test --filter desktop45` chạy AppState thật với PVTANode, ChatLoop và HTTPTransport AI giả, dữ liệu nằm trong thư mục tạm. Kiểm tra cả nút host và client/socket: hai hội thoại chạy đồng thời; chữ chỉ tới cửa sổ gửi; nháp độc lập; hủy một lượt không ảnh hưởng lượt kia; đóng riêng cửa sổ; trạng thái chung; sự kiện riêng không chủ; duyệt/từ chối/xác nhận nguy hiểm qua hàng đợi thật; dừng ngay sau gửi; khóa cùng hội thoại; mở nhiều cửa sổ chỉ tạo một kết nối; `/sign` hủy đúng Thư ký.

Giao diện SwiftUI đã được biên dịch; chưa kiểm chứng bằng thao tác thủ công trên hai cửa sổ ứng dụng thật. Không gọi AI trả phí trong bộ kiểm thử.
