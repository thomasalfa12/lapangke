#!/usr/bin/env bash
# Isi web/index.template.html dari build/release/latest.json, lalu deploy ke https://lapangke.ourbooth.app
#   scripts/publish-web.sh                → render + deploy
#   scripts/publish-web.sh --render-only  → hanya tulis web/public/index.html
set -euo pipefail
cd "$(dirname "$0")/.."
SITE="${LAPANGKE_SITE:-https://lapangke.ourbooth.app}"

/usr/bin/python3 -I - web/index.template.html build/release/latest.json web/public/index.html <<'PY'
import datetime, json, sys
template, manifest, output = sys.argv[1:4]
m = json.load(open(manifest))
months = ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"]
# Tanggal rilis ditulis dalam WIB.
released = datetime.datetime.fromisoformat(m["releasedAt"].replace("Z", "+00:00")).astimezone(datetime.timezone(datetime.timedelta(hours=7)))
values = {
    "URL": m["url"],
    "VERSION": m["version"],
    "SIZE": f"{m['sizeBytes'] / 1e6:.1f} MB".replace(".", ","),
    "SHA256": m["sha256"],
    "DATE": f"{released.day} {months[released.month - 1]} {released.year}",
}
html = open(template).read()
for key, value in values.items():
    html = html.replace("{{%s}}" % key, value)
assert "{{" not in html, "placeholder tersisa di template"
open(output, "w").write(html)
print(f"✓ web/public/index.html · {values['VERSION']} · {values['SIZE']}")
PY

[ "${1:-}" = "--render-only" ] && exit 0
cd web && npx --yes wrangler@4 deploy
code="$(curl -s -o /dev/null -w "%{http_code}" "$SITE/" || true)"
if [ "$code" = "200" ]; then echo "✓ $SITE → HTTP 200"; else echo "Domain baru: tunggu 1–2 menit untuk DNS & sertifikat, lalu cek lagi (HTTP $code)."; fi
