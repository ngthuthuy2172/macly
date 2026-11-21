#!/bin/bash
# Build Macly (Mác-li) – Dọn dẹp máy Mac
set -e
cd "$(dirname "$0")"
APP="Macly.app"
BIN_OUT="$APP/Contents/MacOS/Macly"
# MACLY_UNIVERSAL=1  → build cả Apple Silicon + Intel
# MACLY_NO_INSTALL=1 → chỉ tạo Macly.app, không cài/mở (dùng khi đóng gói DMG)

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "⚠️  Cần cài Xcode Command Line Tools. Đang mở trình cài đặt…"
  xcode-select --install || true
  exit 1
fi

rm -rf build "$APP" CCMM.app
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶︎ Đang biên dịch (Swift Package Manager)…"
UNI_OK=0
if [ "${MACLY_UNIVERSAL:-0}" = "1" ]; then
  if swift build -c release --triple arm64-apple-macosx13.0 2>&1 | tee build/log.txt && [ "${PIPESTATUS[0]}" -eq 0 ] \
     && swift build -c release --triple x86_64-apple-macosx13.0 2>&1 | tee -a build/log.txt && [ "${PIPESTATUS[0]}" -eq 0 ]; then
    lipo -create "$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/Macly" \
                 "$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/Macly" -output "$BIN_OUT" && UNI_OK=1
    [ "$UNI_OK" = "1" ] && echo "  Bản universal (Apple Silicon + Intel)."
  fi
  [ "$UNI_OK" = "1" ] || echo "  Không build được bản Intel, dùng bản Apple Silicon."
fi
if [ "$UNI_OK" = "1" ]; then
  :
elif swift build -c release 2>&1 | tee build/log.txt; [ "${PIPESTATUS[0]}" -eq 0 ]; then
  cp "$(swift build -c release --show-bin-path)/Macly" "$BIN_OUT"
else
  echo "▶︎ Thử cách biên dịch dự phòng (swiftc + plugin macro)…"
  SDK="$(xcrun --show-sdk-path)"
  TC="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
  PLUG=()
  for d in "$SDK/usr/lib/swift/host/plugins" "$TC/lib/swift/host/plugins" \
           "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins" \
           "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
    [ -d "$d" ] && PLUG+=(-plugin-path "$d")
  done
  while IFS= read -r f; do PLUG+=(-plugin-path "$(dirname "$f")"); done < <(find "$SDK" "$TC" -name "libSwiftUIMacros.dylib" 2>/dev/null | sort -u)
  xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    "${PLUG[@]}" Sources/*.swift -o "$BIN_OUT"
fi
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Icons"
for f in Icons/*.png; do case "$(basename "$f")" in AppIcon-1024.png|appicon.png|*-full.png) ;; *) cp "$f" "$APP/Contents/Resources/Icons/";; esac; done
cp Localization/strings.json "$APP/Contents/Resources/strings.json" 2>/dev/null || true

echo "▶︎ Tạo biểu tượng…"
if cp Icons/appicon-imac-full.png build/icon.png 2>/dev/null || xcrun swift Tools/MakeIcon.swift build/icon.png >/dev/null 2>&1; then
  ICONSET=build/AppIcon.iconset; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶︎ Ký ứng dụng…"
# Chữ ký cố định để macOS nhớ quyền (Truy cập toàn bộ ổ đĩa…) qua các lần build
IDENT="CCMM Local Signing"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENT"; then
  echo "  Tạo chứng chỉ ký nội bộ (chỉ làm 1 lần)…"
  cat > build/cert.cnf <<'EOC'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=CCMM Local Signing
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOC
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout build/ccmm.key -out build/ccmm.crt \
    -days 3650 -config build/cert.cnf >/dev/null 2>&1 \
  && { /usr/bin/openssl pkcs12 -export -legacy -inkey build/ccmm.key -in build/ccmm.crt -out build/ccmm.p12 \
         -passout pass:ccmm -name "$IDENT" >/dev/null 2>&1 \
      || /usr/bin/openssl pkcs12 -export -inkey build/ccmm.key -in build/ccmm.crt -out build/ccmm.p12 \
         -passout pass:ccmm -name "$IDENT" >/dev/null 2>&1; } \
  && security import build/ccmm.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P ccmm \
    -T /usr/bin/codesign >/dev/null 2>&1 || echo "  (Không tạo được chứng chỉ, dùng chữ ký tạm)"
  rm -f build/ccmm.key build/ccmm.p12
fi
if codesign --force --deep -s "$IDENT" "$APP" 2>build/sign.txt; then
  echo "  Đã ký bằng chứng chỉ cố định."
else
  echo "  Dùng chữ ký tạm (quyền có thể phải cấp lại sau mỗi lần build)."
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi

if [ "${MACLY_NO_INSTALL:-0}" = "1" ]; then
  echo "✅ Đã tạo $APP"
  exit 0
fi

echo "▶︎ Cài vào ~/Applications…"
pkill -x Macly 2>/dev/null || true
pkill -x CCMM 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP" "$HOME/Applications/CCMM.app"
cp -R "$APP" "$HOME/Applications/"
touch "$HOME/Applications/$APP"
# Làm mới icon trong Spotlight / Launchpad / Dock
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/$APP" >/dev/null 2>&1 || true
[ -d "/Applications/$APP" ] && [ "/Applications/$APP" -ot "$HOME/Applications/$APP" ] && echo "  ⚠️  Có bản Macly cũ trong /Applications – hãy xoá bản đó."
killall Dock 2>/dev/null || true
echo "✅ Xong! Đang mở Macly…"
open "$HOME/Applications/$APP"
