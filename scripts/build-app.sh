#!/usr/bin/env bash
# Build Lapangke.app (release, universal arm64 + x86_64), sign, dan opsional pasang ke /Applications.
#   scripts/build-app.sh            → build/Lapangke.app (tanda tangan Apple Development, untuk Mac ini)
#   scripts/build-app.sh --install  → juga salin ke /Applications/Lapangke.app
# Untuk dibagikan ke orang lain pakai scripts/release.sh (Developer ID + notarisasi Apple).
set -euo pipefail
cd "$(dirname "$0")/.."

# xcode-select di Mac ini bisa menunjuk CommandLineTools; pakai Xcode.app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Lapangke"

APP=build/Lapangke.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lapangke"
strip -x "$APP/Contents/MacOS/Lapangke"
# SwiftPM menulis versi SDK = target minimum (14.0). macOS 26+ memakai angka ini untuk memilih tampilan
# native terbaru, jadi dicatat ulang dengan SDK sebenarnya; minimum tetap dari Info.plist.
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
SDK_OS="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_OS" -replace -output "$APP/Contents/MacOS/Lapangke" "$APP/Contents/MacOS/Lapangke"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift "$PWD"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sertifikat Apple Development membuat izin Full Disk Access tetap berlaku setelah rebuild.
# Tanpa sertifikat, dipakai ad-hoc (izin perlu diberikan ulang tiap build).
IDENTITY="${LAPANGKE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/Lapangke"), macOS $MIN_OS+, SDK $SDK_OS) · signed: ${IDENTITY:-ad-hoc}"

if [ "${1:-}" = "--install" ]; then
  if pgrep -x Lapangke >/dev/null; then osascript -e 'quit app "Lapangke"' || true; sleep 1; fi
  rm -rf /Applications/Lapangke.app
  ditto "$APP" /Applications/Lapangke.app
  echo "✓ Terpasang di /Applications/Lapangke.app"
fi
