# Lapangke

Pembersih storage macOS untuk semua pengguna Mac, dengan kecerdasan tambahan untuk developer iOS & Android. Native SwiftUI, tanpa dependency, ±3 MB (universal).

Untuk semua pengguna:
- **App jarang dipakai**: kapan terakhir dibuka (Spotlight) + kapan datanya terakhir berubah + apakah sedang berjalan. App disarankan dihapus beserta sisa datanya (Application Support, Caches, Containers, Group Containers, Saved State, data web, log), dan setiap lokasi bisa dicentang satu per satu.
- **File besar** (≥300 MB) per file: video, image disk, arsip, VM, RAW, file desain, di semua folder pribadi.
- **Cache & sisa sistem**: cache browser/app, log, installer di Unduhan, Tong Sampah, sisa app yang sudah dihapus.
- **Peta storage** per folder, dan **SSD eksternal** (pindah + verifikasi + kembalikan).

Untuk developer (otomatis muncul bila tool-nya ada): DerivedData, simulator via `simctl`, DeviceSupport, Gradle/NDK/SDK versi tak terpakai, artefak proyek dari `git ls-files --ignored`, toolchain, ekstensi editor lama, riwayat sesi AI.

Setiap data dinilai dulu:

| Label | Arti | Aksi |
|---|---|---|
| **Aman** | Dibuat ulang otomatis (cache, log, build lama, versi tool tak terpakai) | Hapus permanen; bisa direkomendasikan |
| **Aman · unduh ulang** | Aman, tapi perlu unduh/build ulang | Hapus permanen; dipilih manual |
| **Periksa dulu** | Bisa bernilai (app, file besar, arsip, unduhan, riwayat) | Ke Tong Sampah, atau **pindah ke SSD** |
| **Penting** | Sedang dipakai | Tidak bisa dihapus |
| **Dikelola sistem** | Swap, Preboot, runtime simulator, aset macOS | Hanya panduan cara resmi |

## Pengaman

Setiap aksi divalidasi ulang oleh `SafetyGuard` tepat sebelum dieksekusi:

- Hanya di dalam home (dan bundle `.app` pihak ketiga di Applications).
- Tidak pernah menyentuh: repo git, `.ssh`, Keychain, iCloud Drive, Mail/Messages, `~/.claude`, file `*.jks`/`*.keystore`/`*.p12`/`.env*`, folder wadah seperti `~/Library/Caches` itu sendiri.
- Tidak masuk ke volume lain yang ter-mount (mis. `CoreDevice/DeviceFS` = isi iPad yang tersambung).
- Artefak proyek diambil dari `git ls-files --ignored`, jadi kode sumber tidak bisa muncul sebagai kandidat. Folder yang di-ignore tapi berisi kode (`src/`, proyek lain) dilewati.
- Build Gradle yang berisi AAB/APK rilis atau mapping R8 diberi peringatan.
- Simulator dibersihkan lewat `simctl erase/delete`, bukan menghapus folder mentah.
- Semua aksi tercatat di `~/Library/Application Support/Lapangke/activity.jsonl`.

## SSD eksternal

- Deteksi otomatis saat dicolok: format, koneksi (USB/Thunderbolt), ownership, enkripsi, SMART, dan uji kecepatan baca/tulis.
- **Pindah ke SSD**: salin dengan `ditto`, verifikasi jumlah & ukuran file, baru hapus asalnya. Lokasi lama bisa diganti symlink. Ada manifest di SSD (`Lapangke Offload/manifest.json`), dan bisa dikembalikan.
- **Cache dev langsung ke SSD**: DerivedData (pengaturan Xcode), `GRADLE_USER_HOME` dan cache npm (blok terkelola di `~/.zshenv` yang hanya aktif bila SSD terpasang). Folder memakai akhiran `.noindex` dan dikecualikan dari Time Machine.

## Build & pasang (Mac ini)

```bash
cd ~/builder/lapangke
scripts/build-app.sh --install   # build universal, sign Apple Development, salin ke /Applications
swift test                       # 26 test: pengaman, klasifikasi, app & sisa data, file besar, offload, ~/.zshenv
```

## Rilis publik

Halaman unduh: **https://lapangke.ourbooth.app** (Cloudflare Workers static assets, sumber `web/`).
File: `https://downloads.ourbooth.app/lapangke/Lapangke-<versi>.dmg` (R2 `ourbooth-printer-studio`, prefix `lapangke/`).
Keduanya di domain `ourbooth.app`; `r2.dev`, `workers.dev`, dan banyak `pages.dev` diblokir sebagian ISP Indonesia (TrustPositif).

```bash
# naikkan CFBundleShortVersionString + CFBundleVersion di Resources/Info.plist dulu
scripts/release.sh --upload      # Developer ID (Xcode, cloud-managed) → notarisasi Apple → DMG → cek Gatekeeper → R2 → website
scripts/publish-web.sh           # hanya render + deploy website dari build/release/latest.json
```

Syarat: Xcode › Settings › Accounts login sebagai Account Holder tim 4KSYSZU72C. Notarisasi biasanya 5–10 menit.

Setelah dipasang: System Settings › Privacy & Security › **Full Disk Access** › tambahkan Lapangke. Tanpa izin ini, Tong Sampah, Containers, dan media WhatsApp/Telegram tidak terlihat.

## Terminal (read-only)

```bash
/Applications/Lapangke.app/Contents/MacOS/Lapangke --report        # rekomendasi
/Applications/Lapangke.app/Contents/MacOS/Lapangke --report --all  # semua item + path
/Applications/Lapangke.app/Contents/MacOS/Lapangke --volumes       # SSD eksternal & saran
/Applications/Lapangke.app/Contents/MacOS/Lapangke --map           # peta per folder
```

Mode terminal tidak pernah menghapus apa pun.
