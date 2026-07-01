# SEC-DATA: Dashboard Komoditas Pangan Cilegon

Repositori ini berisi dashboard R Shiny untuk monitoring harga komoditas pangan Kota Cilegon, prediksi harga 3 hari ke depan, dan early warning risiko distribusi berbasis suhu. Sistem menggabungkan harga pasar SAGON, data iklim historis ERA5, prakiraan cuaca BMKG, model Hybrid SARIMA-XGBoost, dan interpretasi SHAP.

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
```

Data ERA5 awalnya berbentuk jam-jaman. Agregasi harian yang dipakai:

- `suhu_puncak`: maksimum suhu harian
- `kelembaban`: rata-rata kelembaban harian
- `hujan`: total curah hujan harian

Cache harian disimpan ke:

```text
cilegon_komoditas_shiny/cache/era5_daily_bandung_cilegon.rds
cilegon_komoditas_shiny/cache/era5_daily.rds
```

ERA5 biasanya tertinggal beberapa hari dari tanggal hari ini. Karena itu updater memakai `ERA5_CDS_LAG_DAYS=5` agar tidak memaksa mengambil tanggal yang belum tersedia.

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
6. Split evaluasi memakai 80 persen training dan 20 persen test.
7. Test dilakukan dengan rolling forecast satu langkah ke depan.
8. Model utama Hybrid SARIMA-XGBoost dipakai untuk prediksi H+1 sampai H+3.
9. XGBoost klasifikasi dipakai untuk status risiko.
10. SHAP dipakai untuk interpretasi model regresi dan klasifikasi.

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

Ada dua regresi XGBoost:

- XGBoost residual untuk memodelkan `e_t`
- XGBoost harga langsung untuk menangkap level harga aktual

Model utama adalah Hybrid SARIMA-XGBoost. Naive, MA7, SARIMA-only, dan XGBoost harga langsung hanya dipakai sebagai pembanding evaluasi.

Parameter XGBoost dibuat tetap agar alur tetap sederhana:

```text
max_depth = 3
eta = 0.05
nrounds = 120
subsample = 0.9
colsample_bytree = 0.9
```

Tidak ada data validasi terpisah, tidak ada cross-validation, dan tidak ada early stopping.

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
- Train-test split memakai 80:20 berdasarkan urutan waktu.
- Tidak ada data validasi terpisah.
- Rolling forecast pada test dilakukan satu langkah ke depan.
- Prediksi operasional H+1 sampai H+3 memakai prakiraan BMKG.
- Residual SARIMA menjadi target XGBoost residual.
- SHAP summary memakai banyak fitur, sedangkan dependence plot memakai satu fitur utama untuk membaca ambang efek.

## Status

Repositori ini dirancang sebagai prototype penelitian dan dashboard operasional awal untuk sistem peringatan dini harga komoditas pangan Kota Cilegon.
