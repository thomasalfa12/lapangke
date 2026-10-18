#!/usr/bin/env bash
# Rilis publik Lapangke: tanda tangan Developer ID lewat Xcode, notarisasi Apple, DMG, cek Gatekeeper.
#   scripts/release.sh                → build/release/Lapangke-<versi>.dmg + latest.json
#   scripts/release.sh --publish      → juga rilis GitHub (DMG) + perbarui situs (GitHub Pages)
#   scripts/release.sh --publish-only → terbitkan DMG yang sudah ada di build/release (tanpa notarisasi ulang)
#
# Tanpa sertifikat Developer ID di keychain: tim dengan sertifikat cloud-managed bisa dipakai, karena
# .app dibungkus .xcarchive lalu diekspor `xcodebuild -exportArchive` (method developer-id,
# destination upload = langsung ke notary Apple) dan diambil kembali dengan `-exportNotarizedApp`.
# Syarat: Xcode › Settings › Accounts login sebagai Account Holder tim (LAPANGKE_TEAM_ID); `gh` login.
#
# Variabel:
#   LAPANGKE_TEAM_ID   Team ID Apple Developer
#   LAPANGKE_REPO      repo GitHub tempat rilis (bawaan thomasalfa12/lapangke)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TEAM="${LAPANGKE_TEAM_ID:-4KSYSZU72C}"
REPO="${LAPANGKE_REPO:-thomasalfa12/lapangke}"
APP_NAME="Lapangke.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
DMG="Lapangke-$VERSION.dmg"
OUT="build/release"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lapangke-release.XXXXXX")"
MNT="$WORK/mnt"
cleanup() {
  local status=$?
  hdiutil detach -quiet "$MNT" 2>/dev/null || true
  if [ "$status" -eq 0 ]; then rm -rf "$WORK"; else printf 'Folder kerja disimpan untuk diperiksa: %s\n' "$WORK" >&2; fi
}
trap cleanup EXIT

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mgagal:\033[0m %s\n' "$*" >&2; exit 1; }
gatekeeper() { spctl -a -vv -t exec "$1" 2>&1 | grep -E 'accepted|rejected|source=' | tr '\n' ' '; }

publish() {
  say "Rilis GitHub v$VERSION ($REPO)"
  git push -q origin HEAD
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$OUT/$DMG" --repo "$REPO" --clobber
  else
    minimum="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
    checksum="$(shasum -a 256 "$OUT/$DMG" | awk '{print $1}')"
    gh release create "v$VERSION" "$OUT/$DMG" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Lapangke $VERSION" \
      --notes "Unduh $DMG di bawah. Butuh macOS $minimum atau lebih baru. Ditandatangani Developer ID & dinotarisasi Apple. SHA-256: $checksum"
  fi
  curl -fsSIL "$(plutil -extract url raw "$OUT/latest.json")" | grep -iE '^HTTP/[0-9.]+ 200' >/dev/null || fail "DMG di GitHub belum bisa diunduh"
  say "Perbarui situs"
  scripts/publish-web.sh --push
}

if [ "${1:-}" = "--publish-only" ]; then
  [ -f "$OUT/$DMG" ] || fail "$OUT/$DMG belum ada; jalankan scripts/release.sh dulu"
  publish
  exit 0
fi

# Output disimpan dulu: `grep -q` + pipefail bisa gagal palsu karena SIGPIPE.
accounts="$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null || true)"
grep -q identifier <<<"$accounts" \
  || fail "Xcode belum login. Buka Xcode › Settings › Accounts, login sebagai Account Holder tim $TEAM."

say "Build universal $VERSION"
scripts/build-app.sh > "$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; fail "build"; }

say "Bungkus ke .xcarchive"
archive="$WORK/Lapangke.xcarchive"
mkdir -p "$archive/Products/Applications"
ditto "build/$APP_NAME" "$archive/Products/Applications/$APP_NAME"
cat > "$archive/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key><string>Applications/$APP_NAME</string>
		<key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
		<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
		<key>CFBundleShortVersionString</key><string>$VERSION</string>
		<key>CFBundleVersion</key><string>$(plutil -extract CFBundleVersion raw Resources/Info.plist)</string>
		<key>SigningIdentity</key><string>-</string>
		<key>Team</key><string>$TEAM</string>
	</dict>
	<key>ArchiveVersion</key><integer>2</integer>
	<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key><string>Lapangke</string>
	<key>SchemeName</key><string>Lapangke</string>
</dict>
</plist>
PLIST
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

say "Tanda tangan Developer ID + kirim ke notary Apple"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$WORK/upload" \
  -exportOptionsPlist "$WORK/export.plist" -allowProvisioningUpdates > "$WORK/upload.log" 2>&1 \
  || { tail -30 "$WORK/upload.log"; fail "export untuk notarisasi"; }

say "Menunggu Apple (cek tiap menit, maks. 2 jam)"
notarized=""
for _ in $(seq 1 120); do
  rm -rf "$WORK/notarized"
  if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$WORK/notarized" > "$WORK/notarized.log" 2>&1; then
    notarized="$WORK/notarized/$APP_NAME"
    break
  fi
  grep -qE 'processing and not ready|NSURLErrorDomain|Code=-10(0[0-9]|1[0-9])|appears to be offline|Unable to log in|No Accounts|Failed to load credentials' \
    "$WORK/notarized.log" || { tail -30 "$WORK/notarized.log"; fail "notarisasi ditolak"; }
  sleep 60
done
[ -n "$notarized" ] || fail "Apple masih memproses setelah 2 jam; jalankan ulang nanti"
xcrun stapler validate -q "$notarized" || fail "tiket notarisasi tidak ter-staple"
signature="$(codesign -dvv "$notarized" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$signature" || { echo "$signature"; fail "bukan tanda tangan Developer ID"; }
say "$(grep -m1 'Authority=Developer ID Application' <<<"$signature")"

say "Rakit $DMG"
stage="$WORK/stage"
mkdir -p "$stage" "$OUT"
rm -rf "${OUT:?}/$APP_NAME"
ditto "$notarized" "$OUT/$APP_NAME"   # salinan app ter-notarisasi, untuk dicek ulang
ditto "$notarized" "$stage/$APP_NAME"
ln -s /Applications "$stage/Applications"
rm -f "$OUT/$DMG"
hdiutil create -quiet -volname "Lapangke" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT/$DMG"

say "Cek seperti unduhan browser (karantina + Gatekeeper)"
cp "$OUT/$DMG" "$WORK/check.dmg"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$WORK/check.dmg"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$WORK/check.dmg"
verdict="$(gatekeeper "$MNT/$APP_NAME")"
hdiutil detach -quiet "$MNT"
grep -q 'source=Notarized Developer ID' <<<"$verdict" || fail "Gatekeeper: $verdict"
say "$verdict"

size="$(stat -f %z "$OUT/$DMG")"
sha="$(shasum -a 256 "$OUT/$DMG" | awk '{print $1}')"
cat > "$OUT/latest.json" <<JSON
{
  "version": "$VERSION",
  "releasedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "minimumMacOS": "$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)",
  "url": "https://github.com/$REPO/releases/download/v$VERSION/$DMG",
  "sizeBytes": $size,
  "sha256": "$sha"
}
JSON
say "Siap: $OUT/$DMG ($size byte, sha256 $sha)"

if [ "${1:-}" = "--publish" ]; then publish; fi
