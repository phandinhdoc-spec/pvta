# PVTA (Swift)

Yêu cầu: macOS 14 trở lên, chip Apple Silicon (arm64). Cần Xcode hoặc Command Line Tools.

Cấu trúc:

- `Sources/PVTACore/` — lõi xử lý, không có giao diện
- `Sources/PVTACLI/` — lệnh `pvta`
- `Sources/PVTADesktop/` — ứng dụng SwiftUI
- `Tests/` — kiểm thử tự động

Chạy thử:

    swift build
    swift test
    swift run pvta --version
    swift run PVTADesktop
