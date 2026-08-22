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

Untuk evaluasi (Methodology V2, Sprint 4), data diurutkan kronologis lalu dibagi menjadi `development period -> rolling-origin validation -> untouched final test`. Protokol ada di `R/evaluation.R` dan `docs/EVALUATION_PROTOCOL.md`. Model (SARIMA + XGBoost) **di-refit di setiap forecast origin** memakai histori sampai `t-1`; baseline Naive, Seasonal Naive 7, dan MA7 memakai informasi yang sama per origin. Champion adalah kandidat dengan WAPE validasi terendah, dibekukan sebelum final test, lalu dipakai untuk prediksi H+1 sampai H+3 dengan prakiraan cuaca BMKG.

Model yang dijalankan di app:

- SARIMA/ARIMA aktual dengan `forecast::auto.arima()` pada harga rata-rata tiga pasar.
- XGBoost regresi untuk memodelkan residual SARIMA.
- Kandidat harga: SARIMA, XGBoost Direct, dan SARIMA + XGBoost Residual, bersama Naive, Seasonal Naive 7, dan MA7. Dashboard memakai champion validasi sebenarnya.
- XGBoost klasifikasi `risk_proxy_v1` untuk **Skor Risiko Tekanan Distribusi**. Karena data pasar tidak punya label kejadian distribusi teramati, label dibuat sebagai proxy dari lonjakan harga 3 hari ke depan atau kombinasi margin antar pasar tinggi dan suhu tinggi.
- SHAP aktual dari XGBoost memakai `predict(model, predcontrib = TRUE)`.

Full protocol Tomat yang selesai pada 22 Agustus 2026 memilih **Naive** berdasarkan
validation WAPE 3.816794%; final-test WAPE 4.790277% hanya konfirmasi. App tidak
meng-hardcode hasil ini dan tetap menampilkan kandidat yang dipilih evaluasi aktif.
Runtime app memakai konfigurasi evaluasi bounded agar startup tetap responsif;
angka pada panel preview app bukan pengganti metrik full protocol di atas.

Package R runtime app yang dipakai: `shiny`, `ggplot2`, `readxl`, `forecast`,
dan `xgboost`. Package `terra` hanya diperlukan oleh updater/rebuild ERA5
lokal (`R/era5_netcdf.R`), bukan oleh bundle Shiny cache-only.

Ringkasan metodologi untuk penjelasan:

- Data SAGON diperoleh dengan scraping halaman publik SAGON Cilegon melalui `update_sagon_daily.R`, bukan API resmi. Hasilnya disimpan sebagai cache `cache/sagon_daily_long.rds`.
- ERA5 diambil melalui CDS API sebagai data jam-jaman. **Methodology V2 (Sprint 1):** variabel t2m/d2m/tp diselaraskan per `valid_time` eksak (POSIXct UTC) sebelum agregasi harian, kelembaban relatif dihitung dari suhu dan dewpoint pada timestamp yang sama, dan scope spasial adalah **Cilegon Local Climate** (2x2 sel ERA5 0.1 derajat terdekat Kota Cilegon, lihat `era5_config()` di `R/data_climate.R`). Agregasi harian: suhu puncak = maksimum per jam, kelembaban = rata-rata RH per jam, hujan = total per hari.
- Preprocessing meliputi merge berdasarkan tanggal, deduplikasi tanggal-pasar-komoditas, penghapusan baris harga/iklim yang tidak lengkap, serta pembentukan fitur lag, moving average 7 hari, volatilitas 7 hari, margin antar pasar, hari, dan bulan.
- **Fitur (Methodology V2, Sprint 2):** seluruh feature engineering dipusatkan di **`R/features.R`** dan dipakai identik untuk training, test, dan live inference (`build_training_features()` / `build_future_feature_row()`). Tidak ada fitur harga untuk target `t` yang membaca `harga[t]`; `ma7/vol7/min7/max7` memakai `harga[t-7..t-1]` (baris riwayat < 7 hari di-buang); fitur margin forecasting memakai `margin_hl_lag1[t] = margin_hl[t-1]`. `margin_hl` (hari yang sama) hanya dipakai untuk label proxy risiko, bukan prediktor. Test anti-leakage: `tests/testthat/test-lag-features.R`, `tests/testthat/test-no-target-leakage.R`.
- Persamaan residual SARIMA: `e_t = Y_t - SARIMA_t`. Residual ini menjadi target XGBoost residual. Kandidat residual menghitung `max(0, SARIMA + XGBoost predicted residual)`. XGBoost Direct tetap terpisah; weighted blend, `hybrid_bias`, dan koreksi manual warisan sudah dihapus.
- Orde SARIMA dipilih dengan `forecast::auto.arima()` setelah pengecekan kebutuhan differencing ADF/KPSS dan seasonal differencing.
- XGBoost memakai konfigurasi tetap: `max_depth = 3`, `eta = 0.05`, `nrounds = 120`, `subsample = 0.9`, dan `colsample_bytree = 0.9`. Tidak ada pencarian hyperparameter atau early stopping; konfigurasi ini tidak disebut best/optimal.
- SHAP summary plot memakai banyak fitur untuk ranking importance. SHAP regresi dibaca sebagai contribution to forecast/model prediction, sedangkan SHAP risk sebagai contribution to Distribution Stress Score; keduanya associational, bukan causal. Dependence plot suhu tidak menetapkan threshold suhu.

## Arsitektur Shiny (Sprint 6)

`app.R` hanya melakukan bootstrap/source, menyusun UI, menyusun server, dan memanggil `shinyApp()`. Logic data/model yang dapat dipanggil tanpa Shiny berada di `R/`: konfigurasi (`config.R`), utility (`utils.R`), market/cache (`data_market.R`), climate (`data_climate.R`), feature/model/evaluation yang sudah ada, SHAP (`explainability.R`), serta orchestration dan state builder (`pipeline.R`).

Lima section besar memakai module di `cilegon_komoditas_shiny/modules/`: monitoring, forecast, risk, evaluation, dan SHAP. Setiap browser session memiliki satu `reactiveVal` berisi state dashboard lengkap. Refresh commodity/manual/otomatis membangun satu state baru, lalu mengganti state session hanya setelah build sukses; session lain dan state valid sebelumnya tidak ditimpa.

Boundary cache tetap ringan:

- raw market, ERA5 harian, dan BMKG forecast dibaca dari cache RDS yang sudah ada;
- processed features hidup di memory state session;
- fitted model, evaluation, risk, dan SHAP artifacts hidup di memory state session;
- metadata state mencatat `generated_at`, commodity, date range, Methodology V2, model identifier, dan timestamp cache bila tersedia.

Tidak ada database, background job, atau perubahan formula/statistical selection pada Sprint 6.

## Arsitektur update ERA5

Arsitektur yang dipakai sekarang:

1. `update_era5_daily.R` dijalankan terpisah, idealnya sekali sehari dari Windows Task Scheduler.
2. Script itu memanggil `fetch_era5_cds.py` untuk mengambil ERA5 terbaru dari CDS API.
3. Hasil API disimpan sebagai NetCDF di `cache/era5_cds_nc/`, lalu diringkas ke cache harian:
   `cache/era5_daily_bandung_cilegon.rds`
4. `app.R` hanya membaca cache terbaru. App tidak lagi mengunduh ERA5 dari CDS saat user membuka dashboard.

Transformasi NetCDF -> harian dipusatkan di **`R/data_climate.R`** dan
**`R/era5_netcdf.R`** (Methodology V2). `update_era5_daily.R` dan
`scripts/rebuild_era5_cache.R` memuat kedua modul; `app.R` hanya memuat modul
cache/runtime sehingga deployment tidak membutuhkan native GDAL/terra:

- `valid_time` dipertahankan sebagai POSIXct UTC sampai t2m/d2m/tp diselaraskan
  per timestamp eksak;
- RH dihitung dari suhu + dewpoint pada timestamp yang sama;
- tanggal lokal diturunkan dengan timezone `Asia/Jakarta`;
- agregasi harian baru berjalan setelah alignment;
- validasi dijalankan (duplikat timestamp, jumlah observasi/hari, RH 0-100,
  presipitasi negatif, hari all-NA).

Scope spasial = **Cilegon Local Climate** (`era5_config()$extent`,
2x2 sel ERA5 0.1 derajat terdekat Kota Cilegon), disinkronkan dengan
`ERA5_AREA` di `fetch_era5_cds.py`.

Untuk membangun ulang cache harian dari file NetCDF lokal:

```bash
Rscript --vanilla scripts/rebuild_era5_cache.R
```

> Nama file cache `era5_daily_bandung_cilegon.rds` masih dipertahankan karena
> direferensikan app/CI; isinya sekarang adalah Cilegon Local Climate.

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

Dependency scraper SAGON (locked in `renv.lock`):

```powershell
Rscript -e "renv::restore(prompt = FALSE)"
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

Install dependency Python updater dari root repository:

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install --requirement requirements.txt
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

Start in (root repository, supaya `.Rprofile` mengaktifkan renv):

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026
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

Start in (root repository, supaya `.Rprofile` mengaktifkan renv):

```text
C:\2025 coding\Mini Project\Agriculture\NEC SATRIA DATA 2026
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
5. `app.R` memakai cache ini untuk panel prediksi live H+1 sampai H+3, terpisah dari final test kronologis.
6. Kalau ERA5 historis tertinggal beberapa hari, `app.R` menjembatani tanggal kosong terdekat dengan carry-forward singkat dari observasi iklim terakhir, lalu menyambung ke BMKG forecast.

Konfigurasi `.Renviron`:

```text
BMKG_ADM4=36.72.07.1001
BMKG_FORECAST_DAYS=4
```

Dependency updater BMKG (sudah termasuk di `renv.lock`):

```powershell
Rscript -e "renv::restore(prompt = FALSE)"
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

