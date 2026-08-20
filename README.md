# SEC-DATA: Dashboard Komoditas Pangan Cilegon

Repositori ini berisi dashboard R Shiny untuk monitoring harga komoditas pangan Kota Cilegon, prediksi harga 3 hari ke depan, dan early warning risiko distribusi berbasis suhu. Sistem menggabungkan harga pasar SAGON, data iklim historis ERA5, prakiraan cuaca BMKG, kandidat SARIMA/XGBoost, dan interpretasi SHAP.

## Status Metodologi

Repositori sedang menjalani validasi **Methodology V2** (pipeline terkoreksi). Seluruh angka performa model warisan (MAE, RMSE, MAPE, SHAP, risk score) hanya berlaku sebagai **baseline** dari Methodology V1 sampai refactor metodologi selesai. Rekaman baseline saat ini tersedia di:

```text
docs/METHODOLOGY_V1_BASELINE.md
```

Metodologi V1 = baseline warisan; Metodologi V2 = pipeline terkoreksi yang sedang dikembangkan.

Folder utama aplikasi:

```text
cilegon_komoditas_shiny/
```

## Isi Repositori

```text
.
├─ .github/workflows/update-data.yml
├─ cilegon_komoditas_shiny/
│  ├─ app.R
│  ├─ README.md
│  ├─ update_sagon_daily.R
│  ├─ update_bmkg_forecast.R
│  ├─ update_era5_daily.R
│  ├─ fetch_era5_cds.py
│  ├─ Data komoditas *.xlsx
│  └─ cache/*.rds
├─ Data Pasar Kota Cilegon.xlsx
└─ README.md
```

## Sumber Data

### 1. Harga SAGON

Harga pasar diperoleh dari scraping halaman publik SAGON Cilegon melalui:

```text
cilegon_komoditas_shiny/update_sagon_daily.R
```

Script ini mengambil data dari halaman publik SAGON, termasuk halaman pasar:

- `/`
- `/pasarcilegon`
- `/pasarblokf`
- `/pasarmerak`

Output scraper disimpan ke:

```text
cilegon_komoditas_shiny/cache/sagon_daily_long.rds
```

Jika cache SAGON tersedia, `app.R` memprioritaskan cache ini dibanding Excel lokal.

### 2. ERA5 Reanalysis

Data iklim historis diambil dari CDS API Copernicus ERA5 melalui:

```text
cilegon_komoditas_shiny/update_era5_daily.R
cilegon_komoditas_shiny/fetch_era5_cds.py
R/data_climate.R          # modul transformasi iklim (Methodology V2)
scripts/rebuild_era5_cache.R  # rebuild cache dari file NetCDF lokal
```

**Spatial scope (Methodology V2): Cilegon Local Climate.** Variabel ERA5
dirata-ratakan secara spasial pada 2x2 sel grid ERA5 (0.1 derajat) terdekat ke
Kota Cilegon (±106.01 E, 6.00 S). Extent dikonfigurasi di `era5_config()` pada
`R/data_climate.R` dan disinkronkan dengan `ERA5_AREA` pada
`fetch_era5_cds.py`. Interpretasi sebelumnya (koridor luas Bandung–Cilegon)
tidak lagi dipakai sebagai "cuaca lokal Cilegon".

**Timezone (Methodology V2): eksplisit.** `valid_time` ERA5 disimpan sebagai
POSIXct **UTC** dan dipertahankan sampai semua variabel (t2m, d2m, tp)
diselaraskan per timestamp yang sama. Tanggal lokal (`tanggal`) diturunkan
dengan timezone **Asia/Jakarta** setelah alignment.

**Alur pemrosesan (Methodology V2):**

1. `fetch_era5_cds.py` mengunduh `reanalysis-era5-single-levels` jam-jaman
   (t2m, d2m, tp) untuk area Cilegon lokal.
2. `R/data_climate.R` membaca tiap file NetCDF, **menjaga `valid_time` eksak**,
   menggabungkan t2m + d2m + tp berdasarkan `valid_time` (bukan hanya tanggal
   kalender), menghitung kelembaban relatif dari suhu dan dewpoint pada
   timestamp yang sama, lalu baru mengagregasi harian.
3. Definisi harian:

   - `suhu_puncak`: maksimum suhu per jam
   - `kelembaban`: rata-rata RH per jam
   - `hujan`: total curah hujan per hari

4. Validasi data-quality dijalankan: duplikat timestamp, jumlah observasi per
   hari lokal, RH di luar 0-100, presipitasi negatif, hari all-NA.

Cache harian disimpan ke:

```text
cilegon_komoditas_shiny/cache/era5_daily_bandung_cilegon.rds
cilegon_komoditas_shiny/cache/era5_daily.rds
```

> Catatan: nama file cache masih memakai istilah lama `era5_daily_bandung_cilegon.rds`
> karena sudah direferensikan app/CI; isinya sekarang adalah **Cilegon Local
> Climate**. Rename file cache dijadwalkan pada refactor Sprint 6.

ERA5 biasanya tertinggal beberapa hari dari tanggal hari ini. Karena itu updater memakai `ERA5_CDS_LAG_DAYS=5` agar tidak memaksa mengambil tanggal yang belum tersedia.

**Temuan data (Sprint 1):** nilai `tp` pada file NetCDF lokal tampak berupa
variabel **akumulasi** (merambat naik dan me-reset sekitar 01:00 UTC), bukan
curah hujan per jam. DefinisI `hujan = sum(tp) per hari` saat ini menghasilkan
rata-rata ~84 mm/hari (2023-01 s.d. 2026-06), lebih tinggi dari klimatologi
Cilegon. Interpretasi akumulasi ini belum diubah pada Sprint 1 dan perlu
dikonfirmasi (kemungkinan: total per siklus = nilai akhir akumulasi) sebelum
fitur `hujan` dianggap valid untuk model.

### 3. BMKG Forecast

Prakiraan cuaca H+1 sampai H+3 diambil dari API publik BMKG:

```text
https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=<kode>
```

Updater:

```text
cilegon_komoditas_shiny/update_bmkg_forecast.R
```

Output:

```text
cilegon_komoditas_shiny/cache/bmkg_forecast_daily.rds
```

BMKG dipakai untuk mengisi kebutuhan prediksi 3 hari ke depan ketika ERA5 historis belum tersedia sampai tanggal terbaru.

## Alur Data

1. Harga SAGON dan data iklim ERA5/BMKG dikumpulkan.
2. Data dibersihkan, dideduplikasi, dan digabung berdasarkan tanggal.
3. Harga tiga pasar diringkas menjadi harga rata-rata.
4. Fitur harga, suhu, kelembaban, hujan, margin pasar, lag, moving average, volatilitas, hari, dan bulan dibentuk.
5. Data diurutkan berdasarkan tanggal.
6. Evaluasi memakai protokol time-series (Methodology V2, Sprint 3): development -> rolling-origin validation -> final test untouched. Lihat `docs/EVALUATION_PROTOCOL.md`.
7. Kandidat dengan WAPE rolling-validation terendah dibekukan dan dipakai untuk prediksi H+1 sampai H+3.
8. XGBoost klasifikasi dipakai untuk status risiko.
9. SHAP dipakai untuk interpretasi model regresi dan klasifikasi.

## Evaluasi Model (Methodology V2, Sprint 4)

Evaluasi di `R/evaluation.R`:

- **Split kronologis**: `development period -> rolling-origin validation -> untouched final test`.
- **Rolling-origin (expanding-window)**: fold ke-`o` melatih di `1..o` dan memvalidasi
  `o+1..o+H`; origin maju setiap `validation_step`; hanya `max_folds` origin terakhir.
- **Refit tiap origin**: SARIMA (`auto.arima`) dan XGBoost di-fit ulang pada histori
  sampai `t-1` untuk tiap prediksi satu langkah — tidak ada "fit sekali lalu disebut
  rolling".
- **Kandidat fair**: Naive (`actual[t-1]`), Seasonal Naive 7 (`actual[t-7]`), MA7
  (`mean(actual[t-7..t-1])`), SARIMA, XGBoost Direct, SARIMA + XGBoost Residual — semuanya memakai
  informasi yang sama per origin.
- **Metrik**: MAE, RMSE, WAPE, MAPE, dilaporkan untuk validasi dan final test.
- **Seleksi champion**: WAPE validasi terendah menang; nilai non-finite diabaikan,
  pilihan dibekukan sebelum final test, dan final test hanya untuk konfirmasi.
- **Pseudo-hybrid dihapus**: kandidat residual adalah
  `max(0, SARIMA + XGBoost predicted residual)`. XGBoost Direct tetap terpisah;
  tidak ada weighted blend, `hybrid_bias`, atau koreksi manual.
- Konfigurasi ada di `eval_config()` (default aplikasi) dan `eval_config_full()`
  (protokol penuh). Jalankan protokol penuh:

  ```bash
  Rscript --vanilla scripts/run_evaluation.R Tomat --full
  ```

## Fitur dan Aturan Timestamp (Methodology V2, Sprint 2)

**Aturan inti:** untuk target prediksi `Y[t]`, fitur turunan dari harga pasar hanya
memakai informasi yang tersedia paling lambat `t-1`.

- Fitur lag: `harga_kemarin = harga[t-1]`, `lag2 = harga[t-2]`,
  `lag3 = harga[t-3]`, `lag7 = harga[t-7]`.
- Fitur rolling: `ma7`, `vol7`, `min7`, `max7` dihitung dari
  `harga[t-7 .. t-1]` — **tidak** menyertakan `harga[t]`. Baris dengan riwayat
  kurang dari 7 hari di-buang (drop insufficient-history).
- Margin pasar: fitur forecasting memakai `margin_hl_lag1[t] = margin_hl[t-1]`
  (margin hari yang sama = `margin_hl` hanya dipakai untuk label proxy risiko /
  nowcasting, bukan sebagai prediktor forecasting).
- Fitur iklim hari `t` (`suhu_puncak`, `kelembaban`, `hujan`, `delta_suhu`, `hei`)
  pada inference memakai **prakiraan BMKG**; pada training memakai ERA5 observasi
  sebagai *historical pseudo-forecast* (karena prakiraan BMKG historis tidak
  disimpan). Ini adalah limitasi yang didokumentasikan, bukan leakage tersembunyi.
- `suhu_puncak_lag1` memakai iklim `t-1`.

**Satu feature builder** di `R/features.R` dipakai untuk training, test, dan live
inference (`build_training_features()` dan `build_future_feature_row()`),
sehingga definisi fitur training = inference. Test otomatis untuk memastikan
tidak ada target leakage berada di `tests/testthat/test-lag-features.R` dan
`tests/testthat/test-no-target-leakage.R`.

## Model

### SARIMA

SARIMA digunakan untuk menangkap pola waktu, autokorelasi, dan musiman mingguan. Orde dipilih dengan:

```r
forecast::auto.arima()
```

Kebutuhan differencing dibaca dengan ADF/KPSS dan seasonal differencing.

### Residual SARIMA

Residual didefinisikan sebagai:

```text
e_t = Y_t - SARIMA_t
```

Residual ini menjadi target XGBoost residual.

### XGBoost Regresi

Ada dua regresi XGBoost dengan konfigurasi tetap:

- XGBoost residual untuk memodelkan `e_t`
- XGBoost harga langsung untuk memprediksi level harga sebagai kandidat terpisah

Kandidat residual menghitung `max(0, SARIMA + XGBoost residual)`. Champion operasional
adalah kandidat dengan WAPE rolling-validation terendah, bukan model yang di-hardcode.

Parameter XGBoost dibuat tetap agar alur tetap sederhana:

```text
max_depth = 3
eta = 0.05
nrounds = 120
subsample = 0.9
colsample_bytree = 0.9
```

Tidak ada pencarian hyperparameter atau early stopping. Konfigurasi tetap ini tidak
disebut "best" atau "optimal"; rolling-validation hanya memilih kandidat model.

### XGBoost Klasifikasi

Model klasifikasi menghasilkan probabilitas risiko gagal distribusi. Karena data asli tidak memiliki label kejadian gagal distribusi, label dibuat sebagai proxy dari lonjakan harga ke depan atau kombinasi margin pasar tinggi dan suhu tinggi.

### SHAP

SHAP dipisahkan menjadi dua jalur:

- SHAP regresi: menjelaskan kontribusi fitur terhadap prediksi harga
- SHAP klasifikasi: menjelaskan kontribusi fitur terhadap risiko gagal distribusi

Summary plot memakai banyak fitur untuk ranking importance. Dependence plot sengaja memakai satu fitur suhu utama agar ambang pengaruh suhu mudah dibaca.

## Dashboard

Dashboard terdiri dari:

- Panel monitoring: tren harga pasar dan suhu harian
- Panel prediksi: forecast harga H+1 sampai H+3
- Panel early warning: status Aman, Waspada, atau Darurat
- Alur model: penjelasan pipeline SARIMA-XGBoost-SHAP
- Evaluasi model: training, test 20 persen, dan pembanding model
- Interpretasi SHAP
- Data preview

Jalankan lokal:

```r
shiny::runApp("cilegon_komoditas_shiny")
```

Atau:

```powershell
Rscript -e "shiny::runApp('cilegon_komoditas_shiny', host='127.0.0.1', port=3838)"
```

## GitHub Actions

Workflow otomatis berada di:

```text
.github/workflows/update-data.yml
```

Workflow menjalankan:

1. `update_sagon_daily.R`
2. `update_bmkg_forecast.R`
3. `update_era5_daily.R`
4. Commit balik cache `.rds` penting ke repository

Cache yang dipersist:

```text
cilegon_komoditas_shiny/cache/sagon_daily_long.rds
cilegon_komoditas_shiny/cache/bmkg_forecast_daily.rds
cilegon_komoditas_shiny/cache/era5_daily.rds
cilegon_komoditas_shiny/cache/era5_daily_bandung_cilegon.rds
```

File NetCDF ERA5 tidak dikomit karena besar.

## Repository Secrets

Secrets yang diperlukan:

```text
CDSAPI_URL
CDSAPI_KEY
BMKG_ADM4
BMKG_FORECAST_DAYS
GDRIVE_RDS_ID
```

Contoh nilai:

```text
BMKG_ADM4=36.72.07.1001
BMKG_FORECAST_DAYS=4
ERA5_CDS_RECENT_DAYS=45
ERA5_CDS_LAG_DAYS=5
```

`CDSAPI_URL` dan `CDSAPI_KEY` berasal dari akun Copernicus CDS.

## File Rahasia

Jangan commit file berikut:

```text
.Renviron
.cdsapirc
```

Gunakan:

```text
cilegon_komoditas_shiny/.Renviron.example
```

sebagai contoh konfigurasi lokal.

## Catatan Metodologis

Poin yang biasanya ditanyakan saat presentasi:

- Data SAGON diperoleh dengan scraping halaman publik, bukan API resmi.
- ERA5 berupa data jam-jaman yang diagregasi harian.
- Suhu puncak memakai maksimum harian.
- Kelembaban memakai rata-rata harian.
- Curah hujan memakai total harian.
- **ERA5 (Methodology V2, Sprint 1):** variabel t2m/d2m/tp diselaraskan per
  `valid_time` eksak (POSIXct UTC) sebelum agregasi harian; RH dihitung dari
  suhu dan dewpoint pada timestamp yang sama; tanggal lokal memakai
  Asia/Jakarta; scope spasial adalah **Cilegon Local Climate** (2x2 sel terdekat
  Kota Cilegon). Lihat `R/data_climate.R`.
- **Fitur (Methodology V2, Sprint 2):** tidak ada fitur harga untuk target `t`
  yang membaca `harga[t]`; `ma7/vol7/min7/max7` memakai `harga[t-7..t-1]`;
  fitur margin forecasting memakai `margin_hl_lag1`; definisi fitur training =
  inference lewat `R/features.R`. Lihat bagian "Fitur dan Aturan Timestamp".
- **Evaluasi (Methodology V2, Sprint 3):** data kronologis dibagi development ->
  rolling-origin validation -> final test untouched; SARIMA/XGBoost di-refit di tiap
  origin; baseline Naive/SeasonalNaive7/MA7 memakai informasi yang sama; metrik
  MAE/RMSE/WAPE/MAPE; tidak ada tuning bias pada final test. Lihat
  `docs/EVALUATION_PROTOCOL.md`.
- Rolling one-step pada validasi/final test: prediksi satu hari ke depan, aktual
  diungkap, lalu masuk ke histori untuk langkah berikutnya.
- Prediksi operasional H+1 sampai H+3 memakai prakiraan BMKG.
- Residual SARIMA menjadi target XGBoost residual.
- SHAP summary memakai banyak fitur, sedangkan dependence plot memakai satu fitur utama untuk membaca ambang efek.

## Status

Repositori ini dirancang sebagai prototype penelitian dan dashboard operasional awal untuk sistem peringatan dini harga komoditas pangan Kota Cilegon.

Saat ini repo sedang dalam proses validasi **Methodology V2**. Metrik model pada implementasi sekarang adalah baseline **Methodology V1** dan tidak boleh dianggap final sampai refactor metodologi selesai. Lihat `docs/METHODOLOGY_V1_BASELINE.md` untuk rekaman baseline.
