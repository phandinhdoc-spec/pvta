# Google Workspace — nhiệm vụ 32

Lõi Swift dùng OAuth của ứng dụng Desktop, Calendar API, Tasks API và Drive API. CLI/Desktop gọi cùng các phương thức `google.*`. Ghi chú là tệp Markdown do PVTA quản lý trên Drive, gắn `appProperties.pvtaKind=note`, theo đường Drive của MySoft; không phải Google Keep. Đính kèm lịch vẫn ở máy.

## Cấu hình và đăng nhập

1. Người quản trị tạo OAuth client loại **Desktop app**, bật Google Calendar API, Tasks API và Drive API trong dự án Google, cấu hình màn hình cấp quyền và người dùng thử nghiệm nếu dự án còn ở chế độ thử nghiệm.
2. Gọi `google.configure` với `clientId` và `clientSecret` nếu Google cấp. Chỉ đổi cấu hình khi đã đăng xuất và không có lượt đăng nhập đang chờ. Client ID lưu trong SQLite; client secret lưu riêng trong Keychain. Không đưa secret vào tham số dòng lệnh hoặc tệp cấu hình. Với CLI, gọi configure chỉ với client ID trước, rồi dùng `pvta key set google-client-secret` đọc secret từ stdin và lưu thẳng Keychain. Gọi configure lần nữa mà không có clientSecret sẽ xóa secret cấu hình trước.
3. Gọi `google.login` với `confirmed: true`. PVTA mở trình duyệt hệ thống, dùng PKCE S256, state ngẫu nhiên và cổng IPv4 loopback tạm thời trên `127.0.0.1`. Đăng nhập hết hạn sau 10 phút. `google.cancelLogin` hủy lượt đang chờ.
4. `google.status` cho biết đã cấu hình/đăng nhập hay chưa, tài khoản và lỗi. Access token, refresh token không nằm trong kết quả RPC, sự kiện, SQLite hoặc nhật ký. Khi cần, PVTA làm mới token trong Keychain; API trả 401 được thử lại một lần sau làm mới.
5. Gọi `google.catalogs` để đọc các lịch có quyền ghi và các danh sách việc. `google.select` nhận `calendarId`, `tasklistId` (có thể null), `notes`, `enabled`, `confirmed: true`. Đây là xác nhận bật gửi và nhận dữ liệu ở các đích đã chọn. Mục chưa gắn tài khoản được gắn với tài khoản đang đăng nhập khi bật; mục của tài khoản khác được giữ nguyên.

Để đăng nhập và chạy đồng bộ nền qua CLI, giữ `pvta serve` chạy ở một terminal (hoặc mở Desktop đang giữ lõi), rồi gọi lệnh từ terminal khác. Nếu lõi thoát thì cổng callback và đồng bộ nền cũng dừng. Ví dụ sau khi đã cấu hình OAuth:

```sh
pvta call google.login '{"confirmed":true}'
pvta call google.catalogs '{}'
pvta call google.select '{"calendarId":"ID_LICH","tasklistId":"ID_DANH_SACH","notes":true,"enabled":true,"confirmed":true}'
pvta call google.syncNow '{"confirmed":true}'
pvta call google.status '{}'
```

Các quyền xin cấp: nhận diện tài khoản (`openid email`), đọc danh sách lịch, sửa sự kiện lịch, công việc và các tệp Drive do ứng dụng sử dụng (`drive.file`). PVTA kiểm tra đủ quyền trước khi lưu phiên. Không có OAuth client thật được nhúng sẵn trong mã nguồn.

## Dữ liệu và đồng bộ

Lịch/việc dùng `calendar.saveEvent`, `calendar.saveTask`, `calendar.writeRev`, `calendar.deleteRecord` của nhiệm vụ 31. Ghi chú dùng `google.saveNote` với `data: {title, content}`, tùy chọn `localId` và `baseRev`; `google.deleteNote` cần `localId`, `baseRev`, `confirmed: true`. Đọc bằng `google.listNotes` hoặc `calendar.listLocal` (có `events`, `tasks`, `notes`). Nội dung ghi chú tối đa 60.000 ký tự, giữ nguyên xuống dòng.

- Khi tiến trình giữ dữ liệu đang chạy, lượt nền kiểm tra mỗi giây; gom sửa cục bộ trong 30 giây, tối đa 120 giây khi liên tục sửa. Đọc thay đổi từ Google mỗi 5 phút. `google.syncNow` cần `confirmed: true` và đã bật đồng bộ.
- Calendar đọc đủ các trang trước khi ghi cursor cuối. Cursor hết hạn (410) thì đọc lại toàn bộ và đối chiếu với ánh xạ cũ. Tasks và ghi chú đọc toàn bộ có phân trang, kể cả mục đã xóa; mục đã biết nhưng không còn trong danh sách đầy đủ được coi là đã xóa từ xa. Phản hồi lỗi hoặc không phải JSON không được coi là danh sách trống.
- Mỗi mục giữ mã cục bộ, tài khoản, đích, mã Google, nội dung ở lần đồng bộ trước và ETag. Chỉ một lượt đồng bộ chạy tại một thời điểm. Đổi lựa chọn trong lúc đang đồng bộ bị chặn. Đổi lịch/danh sách không tự chuyển các mục đã gắn với đích cũ.
- Sửa/xóa gửi `If-Match`; nếu Google đổi trong lúc gửi (412), giữ thay đổi ở máy và tạo xung đột. Drive xóa bằng chuyển tệp vào thùng rác. Calendar/Tasks dùng thao tác xóa tài nguyên của API tương ứng.
- Tạo Calendar dùng mã ổn định; Drive xin mã trước rồi lưu mã trước khi tải lên. Tasks không nhận mã do máy cấp nên PVTA gắn dấu `[PVTA-ID:…]` cuối phần ghi chú trên Google. Khi mất phản hồi, tìm lại dấu này trước khi thử tiếp. Nếu chưa xác định được kết quả, trạng thái là `uncertain`; chỉ `google.retryPendingCreate` với `localId`, `confirmed: true` mới cho phép thử tạo lại sau khi người dùng kiểm tra Google. Không xóa dấu này trong lúc đang đối chiếu lượt tạo.
- Lỗi được thử lại sau 30, 60, 120, 300 rồi 900 giây. Phiên đăng nhập hết hạn hoặc bị thu hồi có thể cần đăng xuất/đăng nhập lại. Thay đổi cục bộ trong lúc đang gửi vẫn còn trạng thái chờ cho lượt tiếp theo.

Kho `calendar.v1` và `google.sync.v1` nằm trong SQLite chung, có trong xuất dữ liệu. Token không xuất cùng kho. Sao lưu tệp đính kèm riêng theo hướng dẫn lịch.

## Trạng thái và đối chiếu

`google.status` và `google.syncStatus` trả `state` (`disconnected`, `syncing`, `conflict`, `error`, `waiting`, `idle`), các đích đã chọn, `enabled`, `pending`, `lastSynced`, `nextAttempt`, `errors` và `conflicts`. `google.authChanged` báo thay đổi đăng nhập; `google.syncChanged` báo kết quả đồng bộ.

Xung đột xảy ra khi máy và Google cùng sửa, hoặc một phía xóa trong khi phía kia sửa. Đọc `local`, `remote` và `remoteStamp`, sau đó gọi:

```json
{
  "localId": "MA_CUC_BO",
  "baseRev": 2,
  "remoteStamp": "DAU_PHIEN_BAN_VUA_XEM",
  "choice": "keep-local",
  "confirmed": true
}
```

Phương thức là `google.resolveConflict`; `choice` nhận `keep-local` hoặc `keep-remote`. Nếu bản máy đổi, từ chối phiên bản cũ. Nếu Google đã đổi tiếp, trả `resolved: false` cùng bản đối chiếu mới; phải đọc lại trước khi quyết định. Giữ bản máy đánh dấu chờ gửi, không gửi ngay trong lệnh đối chiếu. Giữ bản máy sau khi Google xóa sẽ tạo tài nguyên mới ở lượt đồng bộ kế tiếp.

## AI và đăng xuất

`google.aiCommand`, `google.aiScanTimetable`, `google.aiGetProposal`, `google.aiRevise`, `google.aiApplyOps`, `google.aiCancel` dùng chính handler lịch của nhiệm vụ 31. AI chỉ lập đề xuất; `aiApplyOps` cần mã đề xuất đã xem và `approved: true`, kiểm phiên bản như cũ. Sau khi người dùng áp dụng vào lịch cục bộ, đồng bộ đã bật mới gửi sang Google. Luồng chữ AI vẫn phát `calendar.ai.delta`.

`google.logout` xóa access token và refresh token khỏi Keychain, hủy đăng nhập/làm mới đang chờ; kết quả mạng thuộc phiên cũ không được ghi lại. Dữ liệu lịch và ánh xạ cũ được giữ để nối lại đúng tài khoản. Client ID/client secret là cấu hình ứng dụng nên vẫn giữ; lệnh configure có thể thay hoặc xóa client secret sau khi đăng xuất. Đăng xuất này không thu hồi quyền của ứng dụng trên tài khoản Google; việc đó thực hiện ở trang quản lý tài khoản Google.

## Phạm vi đã kiểm tra

Kiểm thử dùng máy chủ REST giả có dữ liệu, phân trang, ETag, 401/410/412, lỗi và mất phản hồi; đăng nhập đi qua cổng loopback thật trên máy nhưng token/userinfo đều giả. Không dùng tài khoản Google, Keychain hay dữ liệu thật của người dùng.

Lõi lịch hiện hỗ trợ lặp DAILY/WEEKLY như nhiệm vụ 31. Lịch có quy tắc lặp khác hoặc một lần lặp sửa/xóa riêng bị dừng đồng bộ, giữ cursor và dữ liệu cũ; không bỏ qua âm thầm. Chưa hỗ trợ chỉnh người tham dự, cuộc họp trực tuyến, thứ tự/cấp con của Tasks hoặc đồng bộ tệp đính kèm. Các trường ngoài mô hình không được nhập vào PVTA; cập nhật tài nguyên dùng PATCH cho các trường được hỗ trợ. Cần thử nghiệm OAuth thật, quyền Google Workspace do quản trị viên quản lý, ETag của Drive và giao diện Desktop trước khi phát hành cho người dùng.

Nguồn API chính thức đã đối chiếu: [OAuth cho ứng dụng Desktop](https://developers.google.com/identity/protocols/oauth2/native-app), [Calendar incremental sync](https://developers.google.com/workspace/calendar/api/guides/sync), [Calendar ETag](https://developers.google.com/workspace/calendar/api/guides/version-resources), [Tasks list](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list), [Drive multipart upload và mã cấp trước](https://developers.google.com/workspace/drive/api/guides/manage-uploads).
