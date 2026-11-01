<p align="center">
  <img src="ui/assets/kasirku.svg" alt="Logo KasirKu" width="88" height="88">
</p>

<h1 align="center">KasirKu</h1>

<p align="center">
  <strong>Aplikasi kasir offline-first untuk usaha kecil dan menengah Indonesia.</strong><br>
  Aplikasi desktop Windows native untuk penjualan yang andal, kontrol kas, pencetakan struk, dan laporan usaha lokal.
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>Bahasa Indonesia</strong>
</p>

---

**Versi:** 0.1.0 · **Platform:** Windows x64 · **Penyimpanan:** SQLite lokal · **Internet saat digunakan:** Tidak diperlukan

> **Status proyek:** Dalam pengembangan aktif. Alur inti kasir telah diimplementasikan dan dilindungi automated tests. KasirKu belum diklaim sebagai paket bisnis yang lengkap atau rilis produksi siap pakai; lihat [Batasan saat ini](#batasan-saat-ini) dan [Roadmap engineering](#roadmap-engineering).

## Mengapa KasirKu

Sistem kasir mengelola uang, persediaan, dan catatan usaha. Tanggung jawab tersebut menuntut lebih dari sekadar tampilan checkout yang menarik.

KasirKu dibangun di atas prinsip sederhana: **penjualan harus tetap benar ketika koneksi terputus, produk berubah saat checkout, permintaan dikirim ulang, printer gagal, atau aplikasi ditingkatkan.** Karena itu, proyek ini berinvestasi pada batas transaksi, snapshot penjualan yang tidak berubah, perhitungan uang deterministik, status pemulihan yang eksplisit, dan integrasi native—bukan hanya pada antarmuka.

Aplikasi ini dirancang untuk UMKM Indonesia yang membutuhkan alat kasir praktis tanpa menjadikan operasional harian bergantung pada server, langganan, atau koneksi internet.

## Daftar isi

- [Kemampuan produk](#kemampuan-produk)
- [Alur satu hari kerja](#alur-satu-hari-kerja)
- [Arsitektur](#arsitektur)
- [Keputusan engineering](#keputusan-engineering)
- [Teknologi](#teknologi)
- [Memulai](#memulai)
- [Build dan menjalankan aplikasi](#build-dan-menjalankan-aplikasi)
- [Verifikasi dan pengujian](#verifikasi-dan-pengujian)
- [Data lokal dan durabilitas](#data-lokal-dan-durabilitas)
- [Pertukaran data CSV](#pertukaran-data-csv)
- [Definisi laporan](#definisi-laporan)
- [Keamanan dan privasi](#keamanan-dan-privasi)
- [Batasan saat ini](#batasan-saat-ini)
- [Roadmap engineering](#roadmap-engineering)
- [Struktur proyek](#struktur-proyek)
- [Kontribusi](#kontribusi)
- [Lisensi](#lisensi)

## Kemampuan produk

| Area | Kemampuan yang telah diimplementasikan |
| --- | --- |
| **Pengaturan usaha** | Profil usaha lokal dengan nama, alamat, serta mode retail, makanan, atau jasa. |
| **Katalog produk** | Membuat, mengubah, mencari, membuka halaman, dan mengarsipkan produk; SKU, barcode, kategori, satuan, harga, biaya, stok, dan stok minimum; stok terlacak atau layanan tanpa pelacakan stok. |
| **Kasir** | Katalog dengan pencarian, scanner barcode yang kompatibel dengan keyboard, kuantitas desimal, catatan item, diskon per baris dan transaksi, pembulatan tunai, validasi stok, serta keranjang yang dihitung ulang oleh backend. |
| **Pembayaran tunai** | Uang diterima, pilihan nominal cepat, pilihan uang pas, perhitungan kembalian, penolakan pembayaran kurang, dan checkout yang aman untuk dicoba ulang. |
| **Riwayat penjualan** | Riwayat lokal berhalaman dan struk terperinci berdasarkan nama, harga, biaya, diskon, serta identitas usaha yang disimpan ketika transaksi terjadi. |
| **Kontrol shift** | Satu shift aktif, kas awal, catatan kas masuk/keluar yang idempoten, kas seharusnya, uang terhitung, selisih, catatan penutupan, dan laporan shift. Setiap penjualan terhubung ke shift yang sedang dibuka. |
| **Printer thermal** | Struk dan laporan ESC/POS pada kertas 58 mm atau 80 mm; Windows RAW spooler, output file, atau TCP port 9100; jumlah salinan, feed, cut, dan pulsa laci kas yang dapat diatur. |
| **Desain struk** | Pratinjau teks langsung, logo monokrom, teks pembuka dan penutup, serta opsi SKU, barcode, dan payload QR. Cetak ulang ditandai secara eksplisit sebagai salinan. |
| **Laporan** | Dashboard harian, penjualan per jam, produk terlaris, peringatan stok menipis, penjualan per hari/produk/kategori, laba dan kategori biaya, nilai stok, stok menipis, serta dead stock. |
| **Pertukaran data** | Ekspor CSV melalui dialog simpan native untuk produk dan dataset laporan lengkap; impor CSV produk create-only dengan pratinjau, validasi seluruh file, dan apply atomik. |
| **Ringkasan akhir hari** | Ringkasan harian thermal berisi jumlah transaksi, penjualan, rata-rata transaksi, revenue, COGS, laba kotor, biaya, laba bersih, produk terlaris, dan peringatan stok. |

## Alur satu hari kerja

1. **Atur profil usaha sekali.** Isi profil lokal dan, bila diperlukan, konfigurasikan printer serta desain struk.
2. **Siapkan katalog.** Masukkan produk secara manual atau impor CSV yang telah divalidasi.
3. **Buka shift.** Catat kas awal yang sebenarnya sebelum menerima pembayaran.
4. **Jual dan cetak.** Susun keranjang, konfirmasi perhitungan terbaru, terima uang tunai, dan tangani hasil cetak tanpa menggandakan penjualan.
5. **Rekonsiliasi laci kas.** Catat pergerakan kas, tutup shift, bandingkan kas seharusnya dengan uang terhitung, lalu cetak laporan shift.
6. **Evaluasi usaha.** Periksa dashboard, laporan penjualan, laba, dan stok; ekspor data yang mendasarinya atau cetak ringkasan harian.

## Arsitektur

KasirKu menggabungkan inti native yang ringkas dengan antarmuka web lokal yang mudah dirawat. Aplikasi tidak memerlukan Electron, application server terpisah, atau proses instalasi package JavaScript.

```text
┌───────────────────────────────────────────────────────────┐
                    Proses Windows native

  ┌──────────────────────┐          ┌──────────────────────┐
  │ UI HTML / CSS / JS   │          │ Inti aplikasi Zig    │
  │ Frontend WebView2    │   JSON   │ POS, shift, laporan  │
  │ presentasi + state   ├─────────▶│ validasi + alur kerja│
  └──────────────────────┘ messages └───────────┬──────────┘
             ▲                                  │
             │                 ┌────────────────┼──────────────┐
             │                 │                │              │
             │          ┌──────▼──────┐  ┌──────▼──────┐ ┌─────▼──────┐
             │          │ SQLite      │  │ I/O printer │ │ Dialog file│
             │          │ WAL + FULL  │  │ ESC/POS     │ │ native     │
             │          └─────────────┘  └─────────────┘ └────────────┘
             │
  ┌──────────┴──────────┐
  │ Host WebView2 C++17 │
  │ UI STA + satu worker│
  └─────────────────────┘
```

Antarmuka berjalan di WebView2, tetapi keputusan bisnis yang otoritatif tetap berada di inti Zig. Browser tidak menentukan total akhir, mutasi stok, keunikan checkout, rekonsiliasi shift, atau nilai laporan.

### Lapisan repository

- **`src/domain/`** — aturan deterministik untuk uang, keranjang, inventori, dan struk.
- **`src/app/`** — use case produk, checkout, shift, laporan, perangkat, dan CSV.
- **`src/infra/db/`** — akses SQLite, constraint, migrasi skema, dan salinan pemulihan migrasi.
- **`src/infra/printer.zig`** — backend printer spooler, file, dan jaringan.
- **`src/infra/webview/host.cpp`** — jendela native, lifecycle WebView2, antrean pesan, worker thread, dan dialog simpan native.
- **`src/bridge/`** — dispatch perintah JSON bertipe dan envelope error yang stabil.
- **`ui/`** — lapisan presentasi HTML, CSS, dan JavaScript tanpa dependensi framework.

## Keputusan engineering

### Aritmetika uang dan kuantitas yang benar

- Nilai rupiah disimpan dan dihitung sebagai integer, bukan floating-point.
- Kuantitas menggunakan integer seperseribu (`quantity_milli`) sehingga kuantitas retail desimal tidak mengalami drift floating-point biner.
- Aritmetika domain memvalidasi underflow, overflow, batas diskon, kuantitas, dan increment pembulatan.
- Nilai yang melewati JSON bridge tetap berada dalam batas integer aman JavaScript.

### Penjualan transaksional dan aman untuk retry

- Checkout menghitung ulang produk aktif di dalam write transaction, bukan mempercayai total dari browser.
- `checkout_id` unik dan input hash membuat retry mengembalikan hasil awal atau menolak payload yang berbeda—bukan membuat penjualan kedua.
- Penjualan, item, pembayaran, mutasi stok, dan pergerakan stok dicommit bersama.
- Revisi produk mendeteksi keranjang kedaluwarsa dan perubahan yang berbenturan.
- Penjualan menyimpan snapshot usaha dan item sehingga perubahan produk atau profil di kemudian hari tidak menulis ulang riwayat.
- UI membedakan penolakan yang pasti dari hasil yang belum diketahui dan mempertahankan percobaan yang sama ketika pemulihan memerlukan retry.

### Penyimpanan lokal yang durable

- Tabel SQLite `STRICT` dan foreign key menegakkan invariant penting pada batas penyimpanan.
- WAL journaling, `synchronous=FULL`, dan busy timeout dikonfigurasi secara eksplisit.
- Migrasi berversi berjalan secara transaksional dan memvalidasi riwayat migrasi.
- Sebelum skema lama ditingkatkan, aplikasi membuat salinan pemulihan dengan SQLite backup API.
- Skema yang lebih baru, tidak dikenal, atau tidak konsisten ditolak, bukan ditimpa secara diam-diam.

### Batas native yang sempit

- Perintah menggunakan envelope ketat `{id, command, payload}` dengan batas request/response 64 KiB.
- Field payload dan tipe skalar divalidasi; eksekusi SQL arbitrer tidak diekspos.
- Satu worker native menjalankan pekerjaan database dan perangkat secara serial, bukan membuka akses konkuren tanpa kendali dari UI.
- Output file native menghindari keterbatasan download browser untuk ekspor CSV yang berpotensi besar.
- Hasil printer dilaporkan secara jujur: berhasil dikirim, kegagalan yang pasti, dan hasil fisik yang belum diketahui adalah status yang berbeda.

### Struk yang dapat diuji dan data yang portabel

- Layout struk dan byte ESC/POS memiliki referensi golden di `testdata/receipt/`.
- Output CSV menggunakan UTF-8 BOM, record CRLF, quoting, dan dukungan newline di dalam field.
- Formula injection spreadsheet dimitigasi untuk teks hasil ekspor yang diawali `=`, `+`, `-`, atau `@`.
- Ekspor laporan membaca dataset lengkap dalam read transaction yang konsisten, bukan hanya baris yang terlihat di layar.

## Teknologi

| Komponen | Pilihan | Alasan |
| --- | --- | --- |
| Target desktop | Windows x64 | Sesuai target awal perangkat kasir dan printer Windows. |
| Bahasa inti | Zig 0.15.2 | Deployment native yang ringkas, kontrol eksplisit, dan interoperabilitas C langsung. |
| Host native | C++17 + Win32 | Kepemilikan WebView2, windowing, antrean worker, dan dialog file native. |
| Runtime UI | Microsoft Edge WebView2 SDK 1.0.3537.50 | Teknologi UI web yang dikenal dalam shell native offline. |
| Frontend | HTML, CSS, modul vanilla JavaScript | Tanpa framework frontend atau dependensi package saat runtime. |
| Database | SQLite 3.54.1 amalgamation | Penyimpanan lokal transaksional dengan footprint operasional kecil. |
| Protokol printer | ESC/POS | Dukungan langsung untuk kemampuan umum printer thermal. |
| Tooling test | Zig tests + script Node.js + Chrome DevTools Protocol | Cakupan domain, bridge, UI, dan integrasi desktop nyata. |

Versi dependensi dipin oleh `tools/setup.ps1`, dan arsip yang diunduh diperiksa terhadap hash SHA-256 yang diharapkan.

## Memulai

### Prasyarat

- Windows x64.
- Microsoft Edge WebView2 Evergreen Runtime.
- PowerShell untuk setup dependensi dan wrapper Zig.
- Akses internet **hanya untuk setup dependensi awal** atau ketika dependensi diperbarui.
- Node.js 24 atau lebih baru direkomendasikan untuk seluruh suite JavaScript dan desktop. Suite desktop menggunakan modul bawaan Node `node:sqlite`.
- Chrome atau Edge untuk suite UI berbasis browser.

Tidak diperlukan `npm install`, database server, atau akun cloud.

### Instal dependensi development

Dari root repository di PowerShell:

```powershell
.\tools\setup.ps1
```

Script tersebut menyiapkan:

- toolchain Zig yang dipin di `.tools/zig/`;
- SQLite amalgamation di `vendor/sqlite/`;
- header, loader, dan notice WebView2 di `vendor/webview2/`.

Direktori tool dan vendor hasil generate tersebut memang dikecualikan dari version control.

## Build dan menjalankan aplikasi

```powershell
# Kompilasi aplikasi dan runtime asset-nya
.\tools\zig.ps1 build

# Build lalu jalankan KasirKu
.\tools\zig.ps1 build run
```

Executable ditulis ke:

```text
zig-out/bin/KasirKu.exe
```

Hasil build juga mencakup `WebView2Loader.dll`, aset lokal `ui/`, dan notice lisensi pihak ketiga. Simpan file-file tersebut bersama-sama ketika menyalin build ke direktori atau komputer lain.

Pada peluncuran pertama, lengkapi profil usaha. Sebelum menerima penjualan, buka shift kasir. Pengaturan printer bersifat opsional; penjualan tetap dapat dicatat tanpa printer yang dikonfigurasi.

### Preview khusus UI saat development

```powershell
node tools/preview.mjs
```

Buka `http://127.0.0.1:4173`. Server ini hanya untuk preview presentasi: **tidak ada native bridge atau koneksi database** dan bukan pengganti aplikasi desktop.

## Verifikasi dan pengujian

Jalankan pemeriksaan dari root repository.

### Test domain, database, bridge, CSV, dan struk

```powershell
.\tools\zig.ps1 build test
```

Suite ini menguji batas aritmetika, perilaku transaksional, migrasi, idempotensi checkout, inventori, shift, laporan, validasi bridge, atomicity CSV, format printer, dan byte golden ESC/POS.

### Smoke test WebView2 native

```powershell
.\tools\zig.ps1 build smoke
```

Perintah ini menjalankan host native sesungguhnya dengan profil sementara yang terisolasi dan memverifikasi round trip WebView2 → Zig → SQLite.

### Suite regresi UI browser

```powershell
node tools/test-ui.mjs
```

Suite menggunakan native bridge tiruan dan Edge secara default. Untuk memilih Chrome secara eksplisit:

```powershell
$env:KASIRKU_BROWSER = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
node tools/test-ui.mjs
```

Cakupannya meliputi setup, katalog dan alur impor, pemulihan checkout, status cetak, shift, laporan, ekspor CSV, layout desktop responsif, dan escaped text. Total keuangan pada suite ini berupa mock; suite native memverifikasi perhitungan dan persistensi sesungguhnya.

### Suite integrasi desktop nyata

```powershell
.\tools\zig.ps1 build
node tools/test-desktop.mjs
```

Suite menjalankan aplikasi WebView2/Zig/SQLite sesungguhnya dengan data terisolasi di `.cache/`, mengendalikannya melalui Chrome DevTools Protocol, dan memverifikasi persistensi setelah restart. Jendela test ditutup otomatis ketika selesai.

Untuk menguji executable lain yang sudah di-build:

```powershell
$env:KASIRKU_EXE = 'C:\path\to\KasirKu.exe'
node tools/test-desktop.mjs
```

### Pemeriksaan sintaks JavaScript

```powershell
Get-ChildItem ui\*.js, tools\*.mjs | ForEach-Object {
  node --check $_.FullName
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

### Regenerate file golden struk

Regenerate referensi hanya jika perubahan ESC/POS memang disengaja:

```powershell
.\tools\zig.ps1 build golden
```

Tinjau perbedaan pada level byte. Regenerasi golden bukan cara untuk membuat regresi yang tidak dipahami menjadi lulus.

## Data lokal dan durabilitas

Database aplikasi normal berada di:

```text
%LOCALAPPDATA%\KasirKu\kasirku.db
```

SQLite juga dapat mempertahankan `kasirku.db-wal` dan `kasirku.db-shm` di sampingnya. WebView2 menggunakan direktori data aplikasi yang sama untuk profil lokalnya.

Peningkatan skema dapat membuat file yang menyerupai:

```text
kasirku.db.pre-migration-v4.<random-suffix>.bak
```

Salinan pemulihan tersebut melindungi proses upgrade; **bukan strategi backup yang lengkap**. Alur backup/restore yang dikelola pengguna belum diimplementasikan. Selama belum tersedia, tutup KasirKu sebelum membuat salinan manual dan simpan file database terkait secara bersama-sama. Jangan hanya menyalin file `.db` utama ketika aplikasi masih berjalan.

## Pertukaran data CSV

### Ekspor

Produk serta dashboard, laporan penjualan, laba, atau stok yang aktif dapat disimpan melalui dialog simpan native Windows. Ekspor laporan mengikuti tanggal, pengelompokan, dan filter stok yang dipilih serta mencakup dataset lengkap, bukan hanya halaman UI saat ini.

### Kontrak impor produk

Gunakan hasil ekspor produk KasirKu sebagai template kanonik. Header yang diwajibkan adalah:

```csv
name,sku,barcode,category,unit,price,cost,stock_milli,min_stock_milli
```

Perilaku impor sengaja dibuat konservatif:

- ukuran file maksimal: **8 MiB**;
- jumlah produk maksimal per impor: **20.000**;
- CSV UTF-8 dengan header persis seperti di atas;
- `price`, `cost`, `stock_milli`, dan `min_stock_milli` adalah integer dalam unit penyimpanan masing-masing;
- field stok kosong berarti stok tidak dilacak, cocok untuk jasa;
- create-only: produk yang sudah ada tidak diperbarui atau digabung;
- SKU atau barcode non-kosong yang duplikat—di dalam file atau terhadap produk aktif—ditolak;
- setiap baris divalidasi sebelum ada data yang dimasukkan;
- satu baris tidak valid membuat apply tidak dapat dilakukan;
- apply berjalan atomik sehingga error tidak dapat meninggalkan katalog yang terimpor sebagian;
- pratinjau menampilkan sampel terbatas, sedangkan validasi tetap mencakup seluruh file.

CSV adalah format pertukaran data, bukan backup database: CSV tidak memuat penjualan, shift, pengaturan, catatan audit, atau keseluruhan state historis.

## Definisi laporan

KasirKu menjaga terminologi laporan tetap eksplisit agar total dapat direkonsiliasi:

- **Total penjualan** = jumlah nilai `sale.total` final, termasuk pembulatan dan biaya yang berlaku.
- **Revenue** = jumlah `sale.net_subtotal` setelah diskon baris dan transaksi.
- **COGS** = harga pokok penjualan dari snapshot `unit_cost` yang disimpan pada setiap item terjual.
- **Laba kotor** = revenue − COGS.
- **Biaya** = catatan kas keluar shift berdasarkan kategori; kas masuk tidak dianggap sebagai pendapatan dalam perhitungan laba.
- **Laba bersih** = laba kotor − biaya.

Struk, ekspor CSV, dan layar laporan menggunakan catatan persisten yang sama, bukan memelihara total khusus browser yang terpisah.

## Keamanan dan privasi

- Data usaha tetap berada di komputer lokal selama penggunaan normal. KasirKu tidak memiliki akun cloud, layanan telemetri, atau runtime API yang wajib dihubungi.
- Setup awal mengunduh dependensi development yang dipin; printer TCP opsional memang menggunakan tujuan lokal/jaringan yang dikonfigurasi operator.
- Permission WebView2, jendela baru, dan download browser ditolak oleh host native. Aset UI lokal disajikan melalui virtual host mapping.
- Bridge mengekspos perintah spesifik, bukan SQL arbitrer.
- Aplikasi saat ini **tidak memiliki autentikasi pengguna, role-based access control, atau enkripsi data at rest**. Pemisahan akun Windows, kontrol akses perangkat, dan permission filesystem tetap menjadi bagian dari batas keamanan deployment.
- Perlakukan file CSV hasil ekspor dan salinan database manual sebagai catatan usaha yang sensitif.

## Batasan saat ini

Batasan berikut dinyatakan secara sengaja agar cakupan yang telah diimplementasikan tidak dilebih-lebihkan:

| Batasan | Kondisi saat ini |
| --- | --- |
| Pembayaran | Hanya tunai. Belum ada settlement QRIS, terminal kartu, wallet, atau mixed tender. |
| Topologi | Satu komputer Windows dan satu database lokal; belum ada mode multi-terminal tersinkronisasi. |
| Identitas | Belum ada login, PIN, peran pengguna, atau akuntabilitas per kasir. |
| Backup | Salinan pemulihan pra-migrasi sudah ada, tetapi penjadwalan backup umum, preview restore, dan manajemen retensi belum tersedia. |
| Pencetakan | Generator ESC/POS dan backend telah diimplementasikan serta diuji, tetapi hasil fisik tetap bergantung pada model printer dan konfigurasinya. Matriks validasi perangkat nyata belum dipublikasikan. |
| Distribusi | Build menghasilkan file aplikasi, bukan signed installer, kanal auto-update, atau layanan rilis berversi. |
| Operasional | Belum ada modul supplier/purchase order, integrasi akuntansi, atau sinkronisasi cloud. |

## Roadmap engineering

Milestone berikutnya yang direncanakan adalah alur backup dan restore yang dirancang secara saksama:

- tujuan backup yang dipilih pengguna;
- backup otomatis harian dan saat shift ditutup;
- retensi hingga 30 salinan;
- preview restore sebelum data yang ada diganti;
- verifikasi bahwa file backup lengkap dan dapat digunakan.

Penguatan rilis berikutnya mencakup continuous integration, validasi printer fisik yang lebih luas, serta otomatisasi packaging dan rilis. Daftar ini adalah pernyataan roadmap, bukan klaim bahwa fiturnya sudah tersedia.

## Struktur proyek

```text
kasirku/
├── build.zig                 # Step build, test, run, smoke, dan golden native
├── build.zig.zon             # Metadata package dan kebutuhan versi Zig
├── src/
│   ├── app/                  # POS, shift, laporan, perangkat, CSV
│   ├── bridge/               # Batas perintah JSON yang ketat
│   ├── domain/               # Aturan uang, keranjang, inventori, struk
│   ├── infra/                # SQLite, migrasi, printer, host WebView2
│   ├── main.zig              # Entry point native dan fungsi bridge yang diekspor
│   └── tests.zig             # Registry test native
├── testdata/receipt/         # Referensi golden ESC/POS
├── tools/
│   ├── setup.ps1             # Setup dependensi terverifikasi dan dipin
│   ├── zig.ps1               # Wrapper Zig lokal repository
│   ├── preview.mjs           # Preview lokal khusus UI
│   ├── test-ui.mjs           # Suite regresi UI browser
│   └── test-desktop.mjs      # Suite integrasi desktop nyata
├── ui/                       # HTML, CSS, JavaScript, dan aset lokal
└── vendor/                   # Dependensi SQLite dan WebView2 hasil generate
```

Cache hasil generate, database lokal, `.tools/`, `zig-out/`, dan konten vendor hasil unduhan dikecualikan dari version control.

## Kontribusi

Kontribusi harus mempertahankan batas correctness proyek, bukan melewatinya demi jalan pintas.

1. Jaga perubahan tetap terfokus dan jelaskan masalah operasional atau correctness yang diselesaikan.
2. Pertahankan total otoritatif, perubahan stok, dan aturan transaksi di lapisan domain/aplikasi native.
3. Tambahkan atau perbarui automated tests untuk perubahan perilaku, termasuk jalur kegagalan dan retry bila relevan.
4. Jalankan Zig tests, build, smoke test, pemeriksaan JavaScript, suite UI, dan suite integrasi desktop yang relevan dengan perubahan.
5. Jangan commit database lokal, cache, toolchain hasil generate, atau konten vendor hasil unduhan.
6. Regenerate file golden struk hanya untuk perubahan protokol atau layout yang disengaja dan tinjau diff-nya.
7. Ketika mengubah perilaku yang terdokumentasi, perbarui `README.md` dan `README.id.md`.

## Lisensi

Belum ada file `LICENSE` untuk keseluruhan proyek. Sampai lisensi dipilih secara eksplisit, jangan mengasumsikan adanya hak penggunaan atau redistribusi open-source untuk KasirKu.

Notice pihak ketiga disimpan secara terpisah. Build menyalin lisensi dan notice WebView2 ke `zig-out/bin/licenses/`.

---

<p align="center">
  <strong>KasirKu</strong> — engineering yang saksama untuk realitas harian di meja kasir usaha kecil.
</p>
