#!/usr/bin/env bash
# Isi template situs dari build/release/latest.json ke web/public (disajikan GitHub Pages).
#   scripts/publish-web.sh         → hanya render web/public/index.html & 404.html
#   scripts/publish-web.sh --push  → render, commit, push (GitHub Actions men-deploy Pages)
# LAPANGKE_SITE = URL situs (bawaan GitHub Pages; ganti saat domain sendiri dipasang).
set -euo pipefail
cd "$(dirname "$0")/.."
SITE="${LAPANGKE_SITE:-https://thomasalfa12.github.io/lapangke}"

/usr/bin/python3 -I - build/release/latest.json "$SITE" <<'RENDER'
import datetime, json, sys
manifest, site = sys.argv[1:3]
m = json.load(open(manifest))
months = ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"]
# Tanggal rilis ditulis dalam WIB.
released = datetime.datetime.fromisoformat(m["releasedAt"].replace("Z", "+00:00")).astimezone(datetime.timezone(datetime.timedelta(hours=7)))
values = {
    "SITE": site.rstrip("/"),
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
print(f"✓ web/public · {values['VERSION']} · {values['SIZE']} · {values['SITE']}")
RENDER

[ "${1:-}" = "--push" ] || exit 0
git add web/public
if ! git diff --cached --quiet; then
  git commit -q -m "Website: Lapangke $(plutil -extract version raw build/release/latest.json)"
fi
git push -q origin HEAD
echo "✓ Di-push; GitHub Pages men-deploy dalam ±1 menit: $SITE"
