# Công cụ GitHub — nhiệm vụ 39

Lõi Swift gọi GitHub REST API qua HTTPTransport. CLI và Desktop dùng cùng các RPC dưới đây. Không cần cài `gh`. Token cá nhân (PAT) được kiểm tra qua `GET /user`, lưu trong Keychain bằng KeyStore (`github-session`), không lưu trong SQLite. Token cần quyền đọc kho; tải lên và tạo nhánh cần quyền ghi Contents của kho đã chọn. Không truyền token trong tham số dòng lệnh lưu vào lịch sử shell; dùng đầu vào JSON của phiên RPC.

## Luồng sử dụng

1. `github.login {token, confirmed:true}` → tài khoản đã xác minh. `github.status {}` đọc trạng thái trên máy. `github.logout {}` xóa token, vô hiệu bản xem trước và hủy lượt đang chạy.
2. Cấp thư mục qua `grant.add`, rồi `github.setProjectFolder {projectId, folder, repository:"owner/repo", branch:"main", confirmed:true}`. Dự án phải tồn tại; thư mục phải có sẵn và nằm trong phạm vi đã cấp. Đây là liên kết thư mục nguồn với kho từ xa, không đòi thư mục có `.git`.
3. `github.catalog {}` trả danh mục. `github.preview {projectId, operation, confirmed:true, ...}` đọc GitHub và nguồn trên máy sau khi người dùng xác nhận. Bản xem trước không ghi tệp, tạo Git object, đổi nhánh hay ghi nhật ký. Kết quả chứa `id`, nhánh/commit gốc, danh sách tệp, đích, chữ xác nhận và hạn 5 phút.
4. `github.run {previewId, requestId:"UUID", chatId, confirmation}` trả `runId`. Lõi giữ nguyên nội dung đã xem trước; không nhận dữ liệu thay thế ở bước chạy. Mỗi lượt đều chờ hàng đợi duyệt, kể cả chế độ Tự sửa. Dùng cơ chế `action.*` chung để duyệt/từ chối. Chế độ Chỉ đọc chặn thao tác.
5. `github.runStatus {runId}` trả trạng thái và kết quả; sự kiện nhóm `github` mang `runId`, `kind`, `sequence`, bước tiến độ hoặc kết quả cuối. `github.cancel {runId}` yêu cầu dừng. Hủy không hoàn tác các bước đã gửi/ghi thành công.
6. `github.journal {projectId?}` và `github.uploadHistory {projectId?}` trả tối đa 100 mục mới nhất, có cờ `truncated`. Lịch sử tải lên là nhật ký lọc `uploadSelected`, gồm cả lượt lỗi/hủy.

## Thao tác và tham số xem trước

| `operation` | Tham số bổ sung | Kết quả |
|---|---|---|
| `repository` | Không | Thông tin kho, commit gốc |
| `branches` | Không | Tối đa 100 nhánh, cờ còn dữ liệu |
| `history` | Không | Tối đa 100 commit từ nhánh đã chọn, cờ còn dữ liệu |
| `browseFiles` | Không | Cây tệp từ commit đã xem |
| `downloadSelected` | `paths:["folder/file.txt" hoặc "folder"]`, `destination` tuyệt đối | Tải vào thư mục mới, không ghi đè |
| `uploadSelected` | `paths`, `message` | Một commit cập nhật các tệp đã chọn, chữ xác nhận `CẬP NHẬT` |
| `createBranch` | `newBranch` | Tạo nhánh từ commit đã xem, chữ xác nhận `TẠO NHÁNH` |

Tối đa 500 tệp, 20 MB/tệp, 100 MB/lượt. Đường dẫn phải tương đối, không có `..`, `.git` hoặc liên kết tượng trưng; tải xuống không nhận submodule. Cây GitHub bị cắt ngắn bị từ chối. Nguồn được đọc bằng descriptor không theo symlink. Dấu vân tay bao gồm nội dung, đường dẫn và chế độ tệp; thêm/bớt tệp trong thư mục sau xem trước cũng phải xem lại.

Tải lên dùng blobs → tree với `base_tree` → commit với parent đã xem → cập nhật ref `force:false`, giữ các tệp không chọn. Kiểm tra lại tài khoản, quyền thư mục/kho, liên kết, nguồn và đầu nhánh trước khi ghi. Không force-push. Tải xuống kiểm tra kích thước và SHA-1 Git blob trước khi tạo tệp, không thực thi tệp tải về.

## Nhật ký và thử lại

SQLite chung giữ liên kết và nhật ký metadata: mã lượt/yêu cầu/bản xem trước, dự án, thao tác, kho/nhánh, tên tệp, bước đã xong, commit, thời điểm, trạng thái và tác động. Không giữ nội dung tệp, nội dung commit, token hay phản hồi HTTP thô. Kết quả đọc chi tiết chỉ giữ trong bộ nhớ, tối đa 100 lượt; nhật ký vẫn còn sau khởi động lại.

Trạng thái: `running`, `success`, `error`, `cancelled`, `partial`, `unknown`; tác động: `none`, `applied`, `unknown`. Mất phản hồi sau khi gửi ghi có thể là `partial/unknown`; phải kiểm tra kho trước khi thử lại. Lượt còn `running` sau khởi động lại được chuyển thành `unknown`, không tự gửi lại. Gửi lại cùng `requestId` và `previewId` trả đúng mã lượt cũ; muốn chạy mới phải xem trước và dùng UUID mới. Mỗi kho/thư mục chỉ có một lượt đang chạy trong một lõi.

## Đối chiếu và phạm vi

MySoft `githubLogin/Status/Catalog/Preview/Run/Cancel/Journal/UploadHistory` → `github.login/status/catalog/preview/run/cancel/journal/uploadHistory`; `setProjectGithubFolder` → `github.setProjectFolder`. Điểm vào `github` được thay bằng nhóm RPC cụ thể, bổ sung `logout` và `runStatus`.

Nhiệm vụ này có bảy thao tác REST trong danh mục trên và đăng nhập PAT. Không triển khai toàn bộ danh mục 50 thao tác Git/gh của MySoft, đăng nhập trình duyệt, clone/pull/push kho Git cục bộ, issue/PR hay GitHub Enterprise. Đây là phần backend; giao diện gọi cùng RPC. Chưa thử với tài khoản hoặc kho GitHub thật.

## Kiểm chứng

`swift test --filter github39` dùng máy chủ API giả qua HTTPTransport và thư mục tạm; không gửi lên GitHub thật. Kiểm tra xem trước không ghi, duyệt/từ chối/hủy, một commit giữ cây cũ, chống trùng, nguồn/nhánh/quyền đổi, tải xuống không ghi đè và sai blob, Keychain giả, nhật ký bền vững và khôi phục sau gián đoạn.

Nguồn chính thức: [Git trees](https://docs.github.com/en/rest/git/trees), [Git references](https://docs.github.com/en/rest/git/refs), [Git blobs](https://docs.github.com/en/rest/git/blobs), [Xác minh người dùng](https://docs.github.com/en/rest/users/users#get-the-authenticated-user). Đối chiếu với tài liệu và sáu tệp GitHub của MySoft được chỉ định trong nhiệm vụ 39; không sửa MySoft.
