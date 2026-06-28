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

App membaca data asli dari file komoditas di folder `satria_tomat_shiny/`, misalnya:

- `Data komoditas tomat.xlsx`
- `Data komoditas bawang merah.xlsx`
- `Data komoditas wortel.xlsx`

Setiap file komoditas berisi tiga sheet pasar: Pasar Baru Cilegon, Pasar Blok F, dan Pasar Baru Merak. ERA5 dibaca dari cache harian `cache/era5_daily_bandung_cilegon.rds`. Komoditas dipilih dari dropdown di dashboard, lalu pipeline model dibangun ulang sesuai komoditas terpilih.

Harga pasar juga bisa dibaca dari cache scraper SAGON:

- `cache/sagon_daily_long.rds`

Kalau file cache SAGON ini ada, `app.R` akan memprioritaskannya dibanding file Excel lokal.

Untuk test, tiga tanggal terbaru pada data lengkap harga+ERA5 tidak dimasukkan ke training. Model dilatih pada data sebelum tiga tanggal tersebut, lalu forecast H+1 sampai H+3 dibandingkan dengan harga aktual pada window test.

Model yang dijalankan di app:

- SARIMA/ARIMA aktual dengan `forecast::auto.arima()` pada harga rata-rata tiga pasar.
- XGBoost regresi untuk memodelkan residual SARIMA.
- Prediksi hybrid: `Yhat = SARIMA(t) + XGBoost(epsilon)`.
- XGBoost klasifikasi untuk status risiko. Karena data pasar tidak punya label kejadian gagal distribusi asli, label dibuat sebagai proxy dari lonjakan harga 3 hari ke depan atau kombinasi margin antar pasar tinggi dan suhu tinggi.
- SHAP aktual dari XGBoost memakai `predict(model, predcontrib = TRUE)`.

Package R yang dipakai: `shiny`, `ggplot2`, `readxl`, `terra`, `forecast`, dan `xgboost`.

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
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny\update_sagon_daily.R"
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
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny\update_era5_daily.R"
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
"C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny\update_era5_daily.R"
```

Start in:

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny
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
"C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny\update_sagon_daily.R"
```

Start in:

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny
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
5. `app.R` memakai cache ini untuk panel prediksi live H+1 sampai H+3, terpisah dari test historis 3 hari.
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
Rscript "C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026\satria_tomat_shiny\update_bmkg_forecast.R"
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

- `satria_tomat_shiny/.Renviron.example`

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
shiny::runApp("satria_tomat_shiny")
```

Atau dari terminal:

```bash
Rscript -e "shiny::runApp('satria_tomat_shiny', host='127.0.0.1', port=3838)"
```
