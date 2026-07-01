# Dashboard Komoditas Cilegon - SARIMA XGBoost SHAP

Folder ini berisi prototype R Shiny untuk alur:

1. Pengumpulan data harga komoditas Cilegon dan iklim ERA5.
2. Cleaning dan merge berdasarkan tanggal.
3. Uji stasioneritas ADF/KPSS dan differencing bila perlu.
4. SARIMA untuk pola autokorelasi dan musiman.
5. Rekayasa fitur suhu, harga, dan kalender.
6. XGBoost regresi residual dan XGBoost klasifikasi risiko.
7. Interpretasi SHAP untuk dua model, masing-masing summary dan dependence plot.
8. Dashboard monitoring, prediksi 3 hari, early warning, dan rekomendasi kebijakan.

App membaca data asli dari file komoditas di folder `cilegon_komoditas_shiny/`, misalnya:

- `Data komoditas tomat.xlsx`
- `Data komoditas bawang merah.xlsx`
- `Data komoditas wortel.xlsx`

Setiap file komoditas berisi tiga sheet pasar: Pasar Baru Cilegon, Pasar Blok F, dan Pasar Baru Merak. ERA5 dibaca dari cache harian `cache/era5_daily_bandung_cilegon.rds`. Komoditas dipilih dari dropdown di dashboard, lalu pipeline model dibangun ulang sesuai komoditas terpilih.

Harga pasar juga bisa dibaca dari cache scraper SAGON:

- `cache/sagon_daily_long.rds`

Kalau file cache SAGON ini ada, `app.R` akan memprioritaskannya dibanding file Excel lokal.

Untuk evaluasi, data diurutkan berdasarkan tanggal lalu dibagi menjadi 80 persen training dan 20 persen test. Tidak ada data validasi terpisah. Pada bagian test, evaluasi dilakukan sebagai rolling forecast satu hari ke depan: setelah aktual hari test tersedia, nilai aktual tersebut masuk ke histori untuk membentuk lag prediksi hari berikutnya. Prediksi operasional tetap dibuat untuk H+1 sampai H+3 dengan memakai prakiraan cuaca BMKG sebagai input iklim masa depan.

Model yang dijalankan di app:

- SARIMA/ARIMA aktual dengan `forecast::auto.arima()` pada harga rata-rata tiga pasar.
- XGBoost regresi untuk memodelkan residual SARIMA.
- Prediksi utama: Hybrid SARIMA-XGBoost. Naive, MA7, SARIMA-only, dan XGBoost harga langsung hanya dipakai sebagai pembanding evaluasi.
- XGBoost klasifikasi untuk status risiko. Karena data pasar tidak punya label kejadian gagal distribusi asli, label dibuat sebagai proxy dari lonjakan harga 3 hari ke depan atau kombinasi margin antar pasar tinggi dan suhu tinggi.
- SHAP aktual dari XGBoost memakai `predict(model, predcontrib = TRUE)`.

Package R yang dipakai: `shiny`, `ggplot2`, `readxl`, `terra`, `forecast`, dan `xgboost`.

Ringkasan metodologi untuk penjelasan:

- Data SAGON diperoleh dengan scraping halaman publik SAGON Cilegon melalui `update_sagon_daily.R`, bukan API resmi. Hasilnya disimpan sebagai cache `cache/sagon_daily_long.rds`.
- ERA5 diambil melalui CDS API sebagai data jam-jaman, lalu diagregasi harian: suhu puncak memakai maksimum harian, kelembaban memakai rata-rata harian, dan curah hujan memakai total harian.
- Preprocessing meliputi merge berdasarkan tanggal, deduplikasi tanggal-pasar-komoditas, penghapusan baris harga/iklim yang tidak lengkap, serta pembentukan fitur lag, moving average 7 hari, volatilitas 7 hari, margin antar pasar, hari, dan bulan.
- Persamaan residual SARIMA: `e_t = Y_t - SARIMA_t`. Residual ini menjadi target XGBoost residual. Prediksi hybrid memakai XGBoost harga langsung sebagai level utama, koreksi kecil dari komponen `SARIMA + XGBoost residual`, dan kalibrasi bias berbasis MAPE pada rolling test.
- Orde SARIMA dipilih dengan `forecast::auto.arima()` setelah pengecekan kebutuhan differencing ADF/KPSS dan seasonal differencing.
- XGBoost memakai parameter tetap: `max_depth = 3`, `eta = 0.05`, `nrounds = 120`, `subsample = 0.9`, dan `colsample_bytree = 0.9`. Tidak ada cross-validation dan tidak ada early stopping agar alur tetap training-test-prediksi.
- SHAP summary plot memakai banyak fitur untuk ranking importance. SHAP dependence plot memakai satu fitur suhu utama agar ambang efek suhu mudah dibaca.

## Arsitektur update ERA5

Arsitektur yang dipakai sekarang:

1. `update_era5_daily.R` dijalankan terpisah, idealnya sekali sehari dari Windows Task Scheduler.
2. Script itu memanggil `fetch_era5_cds.py` untuk mengambil ERA5 terbaru dari CDS API.
3. Hasil API disimpan sebagai NetCDF di `cache/era5_cds_nc/`, lalu diringkas ke cache harian:
   `cache/era5_daily_bandung_cilegon.rds`
4. `app.R` hanya membaca cache terbaru. App tidak lagi mengunduh ERA5 dari CDS saat user membuka dashboard.

Keuntungan model ini:

- dashboard lebih cepat
- app lebih stabil saat deploy
- update cuaca tetap bisa berjalan otomatis tiap hari walau tidak ada user yang membuka app

## Arsitektur update SAGON

Arsitektur harga realtime yang dipakai sekarang:

1. `update_sagon_daily.R` dijalankan terpisah, idealnya beberapa kali sehari dari Windows Task Scheduler.
2. Script itu scrape halaman publik SAGON:
   - `/`
   - `/pasarcilegon`
   - `/pasarblokf`
   - `/pasarmerak`
3. Hasil scrape disimpan ke:
   `cache/sagon_daily_long.rds`
4. `app.R` membaca cache SAGON terbaru. Kalau cache belum ada, app fallback ke file Excel komoditas lokal.

Dependency scraper SAGON:

```r
install.packages(c("xml2", "rvest"))
```

Jalankan updater manual:

```powershell
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny\update_sagon_daily.R"
```

## Konfigurasi updater

- `CDSAPIRC_PATH`: path file `.cdsapirc`
- `PYTHON_EXE`: interpreter Python yang punya dependency updater
- `ERA5_CDS_FORCE=1`: opsional, untuk memaksa unduh ulang file ERA5

Format `.cdsapirc`:

```yaml
url: https://cds.climate.copernicus.eu/api
key: <token CDS API>
```

Install dependency Python updater:

```bash
pip install cdsapi
```

Jalankan updater manual:

```powershell
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny\update_era5_daily.R"
```

## Task Scheduler Windows

Untuk membuat update ERA5 benar-benar otomatis harian di Windows:

1. Buka `Task Scheduler`
2. Pilih `Create Task`
3. Isi tab `General`:
   Jalankan dengan akun yang punya akses ke folder project dan internet
4. Isi tab `Triggers`:
   `New...` -> `Daily` -> pilih jam update, misalnya `06:00`
5. Isi tab `Actions`:
   `New...` -> `Start a program`

Program/script:

```text
C:\Program Files\R\R-4.5.2\bin\x64\Rscript.exe
```

Add arguments:

```text
"C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny\update_era5_daily.R"
```

Start in:

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny
```

6. Simpan task, lalu tes dengan `Run`

Kalau task berhasil, cache berikut akan diperbarui:

- `cache/era5_daily_bandung_cilegon.rds`
- `cache/era5_daily.rds`

Task terpisah untuk SAGON:

Program/script:

```text
C:\Program Files\R\R-4.5.2\bin\x64\Rscript.exe
```

Add arguments:

```text
"C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny\update_sagon_daily.R"
```

Start in:

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny
```

Kalau task SAGON berhasil, cache berikut akan diperbarui:

- `cache/sagon_daily_long.rds`

## Arsitektur update BMKG forecast

Untuk forecast cuaca maju H+1 sampai H+3:

1. `update_bmkg_forecast.R` dijalankan terpisah, idealnya beberapa kali sehari.
2. Script ini memanggil API publik resmi BMKG:
   `https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=<kode>`
3. Data jam-jaman BMKG diringkas per hari menjadi:
   - `suhu_puncak`
   - `kelembaban`
   - `hujan`
4. Hasilnya disimpan ke:
   `cache/bmkg_forecast_daily.rds`
5. `app.R` memakai cache ini untuk panel prediksi live H+1 sampai H+3, terpisah dari test historis 20 persen.
6. Kalau ERA5 historis tertinggal beberapa hari, `app.R` menjembatani tanggal kosong terdekat dengan carry-forward singkat dari observasi iklim terakhir, lalu menyambung ke BMKG forecast.

Konfigurasi `.Renviron`:

```text
BMKG_ADM4=36.72.07.1001
BMKG_FORECAST_DAYS=4
```

Dependency updater BMKG:

```r
install.packages("jsonlite")
```

Jalankan updater manual:

```powershell
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\cilegon_komoditas_shiny\update_bmkg_forecast.R"
```

## GitHub Actions

Kalau update tidak mau bergantung ke laptop sendiri, pakai workflow:

- `.github/workflows/update-data.yml`

Workflow ini menjalankan:

1. `update_sagon_daily.R`
2. `update_bmkg_forecast.R`
3. `update_era5_daily.R`

lalu commit balik cache `.rds` ke repo.

Secrets yang perlu dibuat di GitHub repository:

- `CDSAPI_URL`
- `CDSAPI_KEY`
- `BMKG_ADM4`
- `BMKG_FORECAST_DAYS`
- `GDRIVE_RDS_ID` (opsional)

Untuk konfigurasi lokal, pakai file contoh:

- `cilegon_komoditas_shiny/.Renviron.example`

Lalu isi nilai sebenarnya di `.Renviron` lokal atau di GitHub Secrets. Jangan commit `.cdsapirc` dan `.Renviron` asli ke repo.

Nilai contoh:

```text
CDSAPI_URL=https://cds.climate.copernicus.eu/api
BMKG_ADM4=36.72.07.1001
BMKG_FORECAST_DAYS=4
```

Catatan:

- schedule GitHub Actions tidak presisi per menit; bisa telat beberapa menit
- repo harus sudah ada di GitHub
- workflow memakai `GITHUB_TOKEN` untuk commit cache hasil update
- cache NetCDF ERA5 bisa ikut berubah; kalau repo ingin tetap ringan, bisa ubah workflow agar hanya commit file `.rds`

## Mode realtime harga

App masih bisa membaca harga realtime dari URL CSV kalau dibutuhkan:

- `REALTIME_MARKET_URL`: CSV harga dengan kolom minimal `tanggal` dan `harga`
- `REALTIME_CLIMATE_URL`: CSV iklim dengan kolom minimal `tanggal` dan `suhu_puncak`
- `REFRESH_INTERVAL_MS`: interval refresh UI untuk membaca ulang cache/data

Contoh struktur CSV harga:

```csv
tanggal,pasar,harga
2026-06-23,Pasar Baru Cilegon,18000
2026-06-23,Pasar Blok F,18500
2026-06-23,Pasar Baru Merak,17800
```

Contoh struktur CSV iklim:

```csv
tanggal,suhu_puncak,kelembaban,hujan
2026-06-23,33.1,78,4.2
```

## Cara menjalankan

```r
shiny::runApp("cilegon_komoditas_shiny")
```

Atau dari terminal:

```bash
Rscript -e "shiny::runApp('cilegon_komoditas_shiny', host='127.0.0.1', port=3838)"
```

