# Bộ cài PKG tại laptop

Theo chỉ đạo ngày 10/11/2026: GitHub chỉ lưu mã nguồn; không chạy GitHub Actions và không tải bộ cài lên GitHub.

Tạo lại bằng `scripts/dong-goi-pkg.sh` trên macOS Apple Silicon. Script build Release rồi tạo `dist/PVTA-0.1.0-arm64.pkg` và tệp SHA-256. Thư mục dist được bỏ qua trong Git.

Bộ cài dùng macOS Installer, yêu cầu macOS 14+ và ARM64, cài:

- `/Applications/PVTA.app`, gồm Desktop và binary CLI.
- `/usr/local/bin/pvta`, liên kết tới CLI trong ứng dụng.

Mở PKG để cài bằng Installer. Sau cài, mở PVTA trong Applications hoặc chạy `pvta --version`. Nếu shell không có `/usr/local/bin` trong PATH, có thể chạy trực tiếp `/usr/local/bin/pvta`.

Không có script cài đặt ghi/xóa dữ liệu người dùng. Payload chỉ có ứng dụng và liên kết CLI; bundle không di chuyển sang nơi khác, cập nhật thay bundle cùng identifier `vn.pvta.desktop`. Đóng ứng dụng trước khi cài cập nhật.

Máy không có chứng chỉ Developer ID hợp lệ: ứng dụng được ký ad-hoc để kiểm tra tính toàn vẹn, PKG chưa có chữ ký Installer và chưa notarize. Không tuyên bố đây là bản phát hành đã được Apple công chứng.

Bộ cài không chứa model AI, token, Python hoặc Typst. Các tính năng cần công cụ ngoài vẫn cần cài/đăng nhập công cụ đó; laptop hiện có Typst. Không đóng gói tiện ích Office/add-in.

## Kiểm chứng 10/11/2026

- Build Release thành công trên laptop ARM64.
- `pkgbuild` và `productbuild` tạo gói 8,1 MB.
- Giải nén bằng `pkgutil --expand-full`: Info.plist hợp lệ; cả hai executable là Mach-O ARM64; `codesign --verify --deep --strict` đạt; CLI lấy từ chính payload trả `pvta 0.1.0`.
- PackageInfo xác nhận `relocatable=false`, đích `/`, bundle upgrade đúng identifier; liên kết CLI đúng `/Applications/PVTA.app/Contents/MacOS/pvta`.
- SHA-256 kiểm tra đạt. Desktop chỉ liên kết framework/thư viện hệ thống.
- Toàn bộ 533 test cục bộ đạt trước đóng gói.
- Chưa cài vào hệ thống thật, chưa thử trên Mac sạch, chưa kiểm chứng cập nhật bản cài thật và giữ dữ liệu qua lần cài đó. Nhiệm vụ 47 giữ chưa đánh dấu vì các tiêu chí cài đặt này chưa được thử.
