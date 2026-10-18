<p align="center"><img src="web/public/icon.png" width="128" height="128" alt="Ikon Lapangke"></p>

<h1 align="center">Lapangke</h1>

<p align="center"><b>Bikin storage Mac lapang lagi, tanpa takut salah hapus.</b><br>
<a href="https://thomasalfa12.github.io/lapangke">Unduh</a> · macOS 14 Sonoma atau lebih baru · Apple Silicon &amp; Intel · Gratis &amp; open source (MIT)</p>

> **English:** Lapangke is a free, open-source macOS storage cleaner (SwiftUI, no dependencies). It explains what is safe to delete (caches, rarely used apps with their leftovers, forgotten large files) versus what matters, and adds extra smarts for iOS & Android developers (Xcode DerivedData, simulators, unused Gradle/NDK versions, git-ignored build artifacts). Releases are signed with Developer ID and notarized by Apple. The UI and docs are in Indonesian.

Lapangke adalah pembersih storage macOS untuk semua pengguna Mac, dengan kecerdasan tambahan untuk developer iOS & Android. Native SwiftUI, tanpa dependency, ±3 MB (universal).

## Unduh

Versi terbaru ada di **[thomasalfa12.github.io/lapangke](https://thomasalfa12.github.io/lapangke)** atau di halaman [Releases](https://github.com/thomasalfa12/lapangke/releases). DMG ditandatangani Developer ID dan dinotarisasi Apple, jadi macOS membukanya tanpa peringatan.

Setelah dipasang: System Settings › Privacy & Security › **Full Disk Access** › tambahkan Lapangke. Tanpa izin ini, Tong Sampah, Containers, dan media WhatsApp/Telegram tidak terlihat.

## Fitur

Untuk semua pengguna:
- **App jarang dipakai**: kapan terakhir dibuka (Spotlight) + kapan datanya terakhir berubah + apakah sedang berjalan. App disarankan dihapus beserta sisa datanya (Application Support, Caches, Containers, Group Containers, Saved State, data web, log), dan setiap lokasi bisa dicentang satu per satu.
- **File besar** (≥300 MB) per file: video, image disk, arsip, VM, RAW, file desain, di semua folder pribadi.
- **Cache & sisa sistem**: cache browser/app, log, installer di Unduhan, Tong Sampah, sisa app yang sudah dihapus.
- **Peta storage** berupa treemap interaktif: arahkan kursor untuk detail (ukuran, % folder & disk, folder terkunci), klik untuk masuk.
- **Pulau Lapangke**: kapsul ala Dynamic Island di tengah atas layar yang muncul hanya saat penting (ruang menipis, ruang turun drastis beserta penyebabnya, SSD dicolok, progres pembersihan live) — plus **notifikasi pintar** dengan tombol aksi dan ikon menu bar berupa cincin pengukur.
- **Penghapusan dengan progres nyata** per byte (bukan per item), bisa dihentikan setelah item berjalan.
- **Panduan izin** dengan deteksi langsung: seret ikon ke daftar Full Disk Access, izin notifikasi, buka saat login.
- **SSD eksternal** (pindah + verifikasi + kembalikan).

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

## Build dari source

Butuh Swift 6 (Xcode 16 ke atas); dibangun & diuji dengan Xcode 27.

```bash
git clone https://github.com/thomasalfa12/lapangke.git
cd lapangke
swift test                       # 30 test: pengaman, klasifikasi, app & sisa data, file besar, penghapusan berprogres, treemap, offload
scripts/build-app.sh --install   # build universal, sign (Apple Development bila ada, selain itu ad-hoc), salin ke /Applications
```

Bila `xcode-select` menunjuk CommandLineTools, skrip memakai `/Applications/Xcode.app` lewat `DEVELOPER_DIR`.
Untuk memeriksa UI tanpa izin Screen Recording: `LAPANGKE_SNAPSHOT_LIGHT=1 LAPANGKE_SNAPSHOT_DIR=/tmp/shots .build/debug/Lapangke` merender tiap halaman ke PNG (hanya build debug).

## Rilis (maintainer)

Situs: **https://thomasalfa12.github.io/lapangke** (GitHub Pages, sumber `web/`, di-deploy `.github/workflows/pages.yml`). File: DMG di [GitHub Releases](https://github.com/thomasalfa12/lapangke/releases); workflow Pages juga menyalin DMG itu ke situs (dicek SHA-256) supaya tombol unduh memakai host yang sama dengan halaman, dengan GitHub Releases sebagai cadangan. Lapangke berdiri sendiri: tidak memakai domain, bucket, atau layanan proyek lain.

```bash
# naikkan CFBundleShortVersionString + CFBundleVersion di Resources/Info.plist dulu
scripts/release.sh --publish       # Developer ID lewat Xcode → notarisasi Apple → DMG → cek Gatekeeper → rilis GitHub → situs
scripts/release.sh --publish-only  # terbitkan DMG yang sudah ada di build/release tanpa notarisasi ulang
scripts/publish-web.sh --push      # hanya render + push situs dari build/release/latest.json
```

Syarat: Xcode › Settings › Accounts login sebagai Account Holder tim Apple Developer, dan `gh` sudah login. Env: `LAPANGKE_TEAM_ID`, `LAPANGKE_REPO`, `LAPANGKE_SITE` (isi dengan domain sendiri saat dipasang). Notarisasi biasanya 5–10 menit.

## Terminal (read-only)

```bash
/Applications/Lapangke.app/Contents/MacOS/Lapangke --report        # rekomendasi
/Applications/Lapangke.app/Contents/MacOS/Lapangke --report --all  # semua item + path
/Applications/Lapangke.app/Contents/MacOS/Lapangke --volumes       # SSD eksternal & saran
/Applications/Lapangke.app/Contents/MacOS/Lapangke --map           # peta per folder
```

Mode terminal tidak pernah menghapus apa pun.

## Kontribusi

Issue dan pull request dipersilakan. Aturan utamanya: setiap jenis data baru wajib punya label keamanan yang jujur, dan apa pun yang dihapus harus lolos `SafetyGuard`. Tambahkan test untuk aturan baru (`swift test`).

## Lisensi

Kode: [MIT](LICENSE) © 2026 Thomas Edison. Font Outfit di `web/public/fonts`: [SIL Open Font License 1.1](web/public/fonts/OFL.txt), © The Outfit Project Authors.
