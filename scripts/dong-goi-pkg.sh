#!/bin/bash
# Tạo bộ cài tại máy macOS ARM64; không tải lên GitHub, không sửa dữ liệu người dùng.
set -euo pipefail
cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64 || { echo 'Cần máy Mac Apple Silicon.' >&2; exit 1; }
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
version="$("$binary_dir/pvta" --version | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
test -n "$version" || { echo 'Không đọc được phiên bản.' >&2; exit 1; }
package_dir="$PWD/dist"
mkdir -p "$package_dir"
staging="$(mktemp -d "${TMPDIR:-/tmp}/pvta-pkg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
payload="$staging/root"
app="$payload/Applications/PVTA.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$payload/usr/local/bin"
cp "$binary_dir/PVTADesktop" "$app/Contents/MacOS/PVTADesktop"
cp "$binary_dir/pvta" "$app/Contents/MacOS/pvta"
cp tai-nguyen/hinh-anh/app-icons/icon.icns "$app/Contents/Resources/PVTA.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>vn.pvta.desktop</string>
<key>CFBundleName</key><string>PVTA</string>
<key>CFBundleDisplayName</key><string>PVTA</string>
<key>CFBundleExecutable</key><string>PVTADesktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleIconFile</key><string>PVTA.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Chữ ký ad-hoc để kiểm tra tính toàn vẹn tại máy; không phải Developer ID/notarization.
codesign --force --sign - "$app/Contents/MacOS/pvta"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ln -s /Applications/PVTA.app/Contents/MacOS/pvta "$payload/usr/local/bin/pvta"
pkgbuild --analyze --root "$payload" "$staging/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$staging/components.plist"
pkgbuild --root "$payload" --component-plist "$staging/components.plist" \
  --identifier vn.pvta.installer --version "$version" --install-location / \
  --ownership recommended "$staging/payload.pkg"
cat > "$staging/distribution.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
<title>PVTA $version</title>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
<choices-outline><line choice="pvta"/></choices-outline>
<choice id="pvta" visible="false" title="PVTA"><pkg-ref id="vn.pvta.installer"/></choice>
<pkg-ref id="vn.pvta.installer" version="$version" onConclusion="none">payload.pkg</pkg-ref>
</installer-gui-script>
XML
output="$package_dir/PVTA-$version-arm64.pkg"
productbuild --distribution "$staging/distribution.xml" --package-path "$staging" "$output"
shasum -a 256 "$output" > "$output.sha256"
echo "Đã tạo: $output"
