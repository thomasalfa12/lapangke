#!/usr/bin/env bash
# Isi template situs dari build/release/latest.json ke web/public (disajikan GitHub Pages).
#   scripts/publish-web.sh         → hanya render web/public/index.html, 404.html & latest.json
#   scripts/publish-web.sh --push  → render, commit, push, lalu tunggu situs menyajikan DMG-nya
# DMG tidak di-commit: workflow Pages mengambilnya dari GitHub Release dan mencocokkan SHA-256,
# jadi tombol utama mengunduh dari host yang sama dengan halaman dan GitHub Releases jadi cadangan.
# LAPANGKE_SITE = URL situs (bawaan GitHub Pages; ganti saat domain sendiri dipasang).
set -euo pipefail
cd "$(dirname "$0")/.."
SITE="${LAPANGKE_SITE:-https://thomasalfa12.github.io/lapangke}"
SITE="${SITE%/}"

/usr/bin/python3 -I - build/release/latest.json "$SITE" <<'RENDER'
import datetime, json, sys
manifest, site = sys.argv[1:3]
m = json.load(open(manifest))
file = m["url"].rsplit("/", 1)[1]
months = ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"]
# Tanggal rilis ditulis dalam WIB.
released = datetime.datetime.fromisoformat(m["releasedAt"].replace("Z", "+00:00")).astimezone(datetime.timezone(datetime.timedelta(hours=7)))
values = {
    "SITE": site,
    "FILE": file,
    "URL": m["url"],
    "VERSION": m["version"],
    "SIZE": f"{m['sizeBytes'] / 1e6:.1f} MB".replace(".", ","),
    "SHA256": m["sha256"],
    "DATE": f"{released.day} {months[released.month - 1]} {released.year}",
}
for template, output in [("web/index.template.html", "web/public/index.html"), ("web/404.template.html", "web/public/404.html")]:
    html = open(template).read()
    for key, value in values.items():
        html = html.replace("{{%s}}" % key, value)
    assert "{{" not in html, f"placeholder tersisa di {template}"
    open(output, "w").write(html)
# Manifes publik: dibaca workflow Pages untuk mengambil & memverifikasi DMG.
public = {
    "version": m["version"],
    "releasedAt": m["releasedAt"],
    "minimumMacOS": m["minimumMacOS"],
    "file": file,
    "sizeBytes": m["sizeBytes"],
    "sha256": m["sha256"],
    "url": f"{site}/{file}",
    "mirrors": [m["url"]],
}
with open("web/public/latest.json", "w") as f:
    json.dump(public, f, indent=2)
    f.write("\n")
print(f"✓ web/public · {values['VERSION']} · {values['SIZE']} · {site}/{file}")
RENDER

[ "${1:-}" = "--push" ] || exit 0
version="$(plutil -extract version raw build/release/latest.json)"
size="$(plutil -extract sizeBytes raw build/release/latest.json)"
file="$(plutil -extract file raw web/public/latest.json)"
git add web/public
if ! git diff --cached --quiet; then
  git commit -q -m "Website: Lapangke $version"
fi
git push -q origin HEAD
echo "Menunggu GitHub Pages menyajikan $file …"
for _ in $(seq 1 40); do
  got="$(curl -fsSI "$SITE/$file?v=$(date +%s)" 2>/dev/null | awk 'tolower($1)=="content-length:"{print $2+0}' | tail -1 || true)"
  if [ "${got:-0}" = "$size" ]; then
    echo "✓ Live: $SITE/ (unduhan $SITE/$file)"
    exit 0
  fi
  sleep 10
done
echo "✗ Setelah ±7 menit $SITE/$file belum tersaji. Cek: gh run list --workflow pages.yml" >&2
exit 1
