#!/bin/bash
# Đóng gói Macly thành file DMG: mở ra, kéo Macly vào Applications là xong.
set -e
cd "$(dirname "$0")"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
MACLY_UNIVERSAL=1 MACLY_NO_INSTALL=1 bash build.sh

echo "▶︎ Đóng gói DMG…"
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R Macly.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Bản phát hành dùng chữ ký ad-hoc (chứng chỉ nội bộ chỉ có trên máy này)
codesign --force --deep -s - "$STAGE/Macly.app" >/dev/null 2>&1 || true
cp -f "Packaging/Mở lần đầu.txt" "$STAGE/" 2>/dev/null || true
OUT="dist/Macly-$VER.dmg"
rm -f "$OUT"
hdiutil create -volname "Macly $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
rm -rf "$STAGE"
cp -f "$OUT" dist/Macly.dmg   # tên cố định để link "tải bản mới nhất" trên GitHub luôn đúng
echo "✅ Xong: $OUT ($(du -h "$OUT" | cut -f1))"
open -R "$OUT"
