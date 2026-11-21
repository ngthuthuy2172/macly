#!/bin/bash
# Đẩy thay đổi của Macly lên GitHub (và tuỳ chọn phát hành phiên bản mới)
cd "$(dirname "$0")"
REPO="https://github.com/ngthuthuy2172/macly.git"

# 1. Cần GitHub CLI để đăng nhập (chỉ cài 1 lần)
if ! command -v gh >/dev/null; then
  echo "▶︎ Cài GitHub CLI (gh)…"
  if command -v brew >/dev/null; then brew install gh; else
    echo "⚠️  Chưa có Homebrew. Cài tại https://brew.sh rồi chạy lại."; read -p "Enter để đóng"; exit 1; fi
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "▶︎ Đăng nhập GitHub (trình duyệt sẽ mở ra)…"
  gh auth login --hostname github.com --git-protocol https --web || exit 1
fi
gh auth setup-git >/dev/null 2>&1

# 2. Lần đầu: nối thư mục này với repo trên GitHub (giữ nguyên file của bạn)
if [ ! -d .git ]; then
  echo "▶︎ Kết nối thư mục với GitHub…"
  git init -q -b main
  git remote add origin "$REPO"
  git fetch -q origin main && git reset -q --mixed origin/main
fi
git pull -q --rebase --autostash origin main 2>/dev/null

# 3. Phiên bản mới (tuỳ chọn)
OLD=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
echo ""
echo "Phiên bản hiện tại: $OLD"
read -p "Nhập phiên bản mới để phát hành (vd 1.1), hoặc Enter để chỉ đẩy code: " NEW
if [ -n "$NEW" ]; then
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" Info.plist
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILD+1))" Info.plist
  sed -i '' "s/v$OLD/v$NEW/g; s/(11\/2026)/($(date +%m\/%Y))/" README.md
  bash make-dmg.sh || { echo "⚠️  Tạo DMG lỗi."; read -p "Enter để đóng"; exit 1; }
fi

# 4. Lưu và đẩy lên
git add -A
if git diff --cached --quiet; then
  echo "Không có thay đổi nào để đẩy."
else
  echo ""
  git status --short | head -30
  read -p "Mô tả ngắn thay đổi (vd: Sửa lỗi dọn trình duyệt): " MSG
  [ -z "$MSG" ] && MSG="Cập nhật Macly${NEW:+ v$NEW}"
  git commit -q -m "$MSG" && git push -q origin main && echo "✅ Đã đẩy code lên GitHub."
fi

# 5. Tạo bản phát hành kèm file DMG
if [ -n "$NEW" ]; then
  read -p "Ghi chú cho bản v$NEW (có gì mới): " NOTES
  gh release create "v$NEW" dist/Macly.dmg --repo ngthuthuy2172/macly --title "Macly v$NEW" \
    --notes "${NOTES:-Macly v$NEW}" && echo "✅ Đã phát hành v$NEW – link tải trong README tự trỏ tới bản này."
fi
echo ""
read -p "Xong. Enter để đóng"
