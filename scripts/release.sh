#!/usr/bin/env bash
# Rilis publik Lapangke: tanda tangan Developer ID lewat Xcode, notarisasi Apple, DMG, cek Gatekeeper.
#   scripts/release.sh            → build/release/Lapangke-<versi>.dmg + latest.json
#   scripts/release.sh --upload        → juga unggah ke R2 (downloads.ourbooth.app/lapangke/…) + deploy website
#   scripts/release.sh --upload-only   → unggah DMG yang sudah ada di build/release (tanpa notarisasi ulang)
#
# Tanpa sertifikat Developer ID di keychain: tim 4KSYSZU72C memakai sertifikat cloud-managed, jadi
# .app dibungkus .xcarchive lalu diekspor `xcodebuild -exportArchive` (method developer-id,
# destination upload = langsung ke notary Apple) dan diambil kembali dengan `-exportNotarizedApp`.
# Syarat: Xcode › Settings › Accounts login sebagai Account Holder tim.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TEAM="4KSYSZU72C"
BUCKET="ourbooth-printer-studio"
PREFIX="lapangke"
PUBLIC="https://downloads.ourbooth.app/$PREFIX"
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

upload() {
  say "Unggah ke R2 ($BUCKET/$PREFIX)"
  npx --yes wrangler@4 r2 object put "$BUCKET/$PREFIX/$DMG" --remote --file "$OUT/$DMG" \
    --content-type application/x-apple-diskimage \
    --content-disposition "attachment; filename=\"$DMG\"" \
    --cache-control "public, max-age=31536000, immutable"
  npx --yes wrangler@4 r2 object put "$BUCKET/$PREFIX/latest.json" --remote --file "$OUT/latest.json" \
    --content-type application/json --cache-control "public, max-age=300"
  curl -fsSI "$PUBLIC/$DMG" | grep -iE '^(HTTP|content-length|content-type)' || fail "$PUBLIC/$DMG belum bisa diunduh"
  say "Perbarui & deploy website"
  scripts/publish-web.sh
}

if [ "${1:-}" = "--upload-only" ]; then
  [ -f "$OUT/$DMG" ] || fail "$OUT/$DMG belum ada; jalankan scripts/release.sh dulu"
  upload
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
  "url": "$PUBLIC/$DMG",
  "sizeBytes": $size,
  "sha256": "$sha"
}
JSON
say "Siap: $OUT/$DMG ($size byte, sha256 $sha)"

if [ "${1:-}" = "--upload" ]; then upload; fi
