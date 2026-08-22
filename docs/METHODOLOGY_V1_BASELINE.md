# Methodology V1 — Legacy Baseline

> Dokumen ini adalah **rekaman baseline** dari implementasi sistem yang ada sekarang
> **persis seperti yang dikodekan**, sebelum Methodology V2 dimulai.
>
> **Metodologi V1 = baseline warisan (legacy).**
> **Metodologi V2 = pipeline terkoreksi yang aktif.**
>
> Dokumen ini TIDAK boleh dibaca sebagai versi ideal dari sistem. Semua angka,
> rumus, ambang, dan konfigurasi di bawah ini mencerminkan perilaku kode saat
> pengambilan baseline (commit `d36bfd1`, 2026-08-17). Setiap klaim performa yang
> tercantum di sini bersifat sementara dan hanya berlaku sebagai baseline sampai
> refactor metodologi selesai. Inventory file di bawah juga merupakan snapshot
> historis; struktur aktif dijelaskan di `README.md` dan dokumen Methodology V2.

- Tanggal dokumentasi: 2026-08-17
- Repositori: `Salajalaludin/SEC-DATA`
- Commit baseline: `d36bfd1` `docs: rename app folder and add root README`
- Lingkungan reproduksi: R 4.5.2 (2025-10-31 ucrt), Python 3.12.10

---

## 1. Tujuan Repository

Prototype **R Shiny dashboard ketahanan pangan Kota Cilegon** yang menggabungkan:

1. Harga pasar komoditas dari **SAGON Cilegon** (scraping halaman publik);
2. Data iklim historis **ERA5** (CDS API Copernicus);
3. Prakiraan cuaca **BMKG** (API publik per `adm4`);
4. Model **Hybrid SARIMA-XGBoost** untuk prediksi harga;
5. Model **XGBoost klasifikasi** untuk risiko distribusi (label proxy);
6. Interpretasi **SHAP** untuk model regresi dan klasifikasi.

Dashboard menyediakan monitoring harga dan suhu, prediksi H+1 sampai H+3, early
warning status Aman/Waspada/Darurat, evaluasi model, dan interpretasi SHAP.
Ditujukan sebagai prototype penelitian dan dashboard operasional awal.

---

## 2. Struktur Repository (Saat Baseline)

```text
SEC-DATA/
├─ .github/workflows/update-data.yml      # CI data updater (cron 6 jam)
├─ .gitignore
├─ README.md                              # dokumentasi root
├─ Data Pasar Kota Cilegon.xlsx           # data harga root (fallback)
├─ ScrapeFileERA5File.ipynb               # notebook eksplorasi ERA5 (scraping)
├─ ceh.ipynb                              # notebook eksplorasi API harga (dahulu)
├─ lihatfilenc4.ipynb                     # notebook validasi NetCDF ERA5
├─ data_era5_nc4/                         # NetCDF ERA5 (gitignored)
├─ data_era5_tomat_cilegon_lampung_jabar/ # NetCDF ERA5 (gitignored)
├─ data_era5_tomat_cilegon_lampung_jabar_nc/  # NetCDF ERA5 (gitignored)
└─ cilegon_komoditas_shiny/
   ├─ app.R                               # aplikasi Shiny monolitik (1548 baris)
   ├─ README.md                           # dokumentasi folder app
   ├─ update_sagon_daily.R                # updater harga SAGON
   ├─ update_bmkg_forecast.R              # updater prakiraan BMKG
   ├─ update_era5_daily.R                 # updater ERA5 harian
   ├─ fetch_era5_cds.py                   # helper unduh ERA5 via cdsapi
   ├─ .Renviron.example                   # contoh konfigurasi lokal
   ├─ Data komoditas *.xlsx               # 8 file komoditas (tomat, bawang merah,
   │                                      #   cabe merah besar/kriting, rawit,
   │                                      #   kentang, KOL, wortel)
   ├─ cache/                              # cache RDS (4 di-track git)
   │  ├─ sagon_daily_long.rds             # (tracked)
   │  ├─ bmkg_forecast_daily.rds          # (tracked)
   │  ├─ era5_daily.rds                   # (tracked)
   │  ├─ era5_daily_bandung_cilegon.rds   # (tracked)
   │  └─ (artifact eksperimen: pipeline_*.rds, xgb_models_*.rds,
   │      experiments/metrics_*.csv, era5_cds_nc/, era5_cds_test/ — gitignored)
   ├─ pydeps/                             # dependency Python lokal (gitignored)
   └─ rsconnect/                          # konfigurasi deploy shinyapps.io (gitignored)
```

Catatan: file kerja yang belum dikomit di repo saat baseline: `AGENTS.md`,
`SEC_DATA_REFACTOR_SPRINT_PLAN.md`, `opencode.json`, `uploadshiny.r`.

### Aplikasi Shiny (`cilegon_komoditas_shiny/app.R`)

- Monolitik satu file (1548 baris), memakai pola `assign(..., envir = .GlobalEnv)`
  via `apply_dashboard_state()`.
- `set.seed(2026)` di awal file.
- Parameter global:
  - `bandung_cilegon_extent = ext(105.85, 107.85, -7.30, -5.80)`
  - `train_ratio = 0.80`
  - `forecast_horizon = 3`
  - `refresh_interval_ms = 86400000` (bisa di-override `REFRESH_INTERVAL_MS`)
- Tabs: Dashboard, Alur Model, Evaluasi Model, Interpretasi SHAP, Data.
- Komoditas default: **Tomat** (jika ada file "Data komoditas tomat.xlsx").

---

## 3. Sumber Data

| Sumber | Jenis | Cara akses |
|---|---|---|
| SAGON Cilegon | Harga pasar (scraping) | halaman publik `/`, `/pasarcilegon`, `/pasarblokf`, `/pasarmerak` |
| ERA5 | Iklim reanalysis jam-jaman | CDS API `reanalysis-era5-single-levels` |
| BMKG | Prakiraan cuaca H+1..H+3 | `https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=<kode>` |
| Excel lokal | Harga historis | `cilegon_komoditas_shiny/Data komoditas *.xlsx` |
| Google Drive (opsional) | Fallback cache iklim | `GDRIVE_RDS_ID` |
| CSV realtime (opsional) | Harga/iklim live | `REALTIME_MARKET_URL`, `REALTIME_CLIMATE_URL` |

---

## 4. Alur Data Harga (Market)

1. `update_sagon_daily.R` men-scrape halaman SAGON, normalisasi nama pasar dan
   komoditas, parse tanggal lokal (Indonesia), deduplikasi per
   `(tanggal, pasar, komoditas)`, simpan ke `cache/sagon_daily_long.rds`
   (format list `{key, updated_at, data}`).
2. `app.R` (`load_project_data`) memprioritaskan **cache SAGON**; bila tidak ada,
   membaca Excel (`read_market_data`) — setiap sheet = pasar, kolom `Tanggal`,
   `Harga` (dan opsional `komoditas`); bila tidak ada kolom harga, gagal.
3. Opsional: `REALTIME_MARKET_URL` dibaca sebagai CSV (`read_market_csv`) dan
   diprioritaskan.
4. `merge_market_sources()` menggabungkan Excel (base) + cache/CSV (fresh),
   dedup `(tanggal, pasar, komoditas)` dari belakang (fresh menang), lalu
   memaksa kolom `komoditas = commodity` terpilih.
5. Rata-rata tiga pasar: baris `"Harga rata-rata"` = `mean(harga)` per tanggal
   (ditambah bila belum ada). `margin_hl` = `diff(range(harga antar pasar))`
   per tanggal (dihitung saat `prepare_avg_frame`, dari semua pasar non-rata-rata).

---

## 5. Alur Data ERA5

1. `fetch_era5_cds.py` (Python + `cdsapi`) mengunduh data bulanan:
   - variabel: `2m_temperature`, `2m_dewpoint_temperature`, `total_precipitation`
   - resolusi jam (24 waktu/hari), format NetCDF
   - area: `[-5.80, 105.85, -7.30, 107.85]` (koridor Bandung–Cilegon)
   - file: `cache/era5_cds_nc/era5_cilegon_YYYY_MM.nc`
2. `update_era5_daily.R` (R + `terra`):
   - baca setiap file NetCDF, crop ke `bandung_cilegon_extent`, ambil rata-rata
     spasial per layer; konversi `t2m`/`d2m` dari Kelvin ke Celsius
     (`-273.15`), `tp` dikalikan 1000 (meter → mm) dan di-`pmax(0)`.
   - **jam dilepas lebih dulu** (timestamp hanya sampai tanggal), lalu t2m, d2m,
     tp digabung per tanggal sebelum RH dihitung. RH dihitung dari suhu dan
     dewpoint dengan rumus Magnus, diklip 0–100.
   - Agregasi harian:
     - `suhu_puncak = max(T harian)`
     - `kelembaban = mean(RH harian)`
     - `hujan = sum(precipitation harian)`
   - Simpan ke `cache/era5_daily_bandung_cilegon.rds` dan fallback
     `cache/era5_daily.rds`.
   - Konfigurasi env: `ERA5_CDS_LAG_DAYS=5` (cap ketersediaan), 
     `ERA5_CDS_RECENT_DAYS=45`, `PYTHON_EXE`, `CDSAPIRC_PATH`, `ERA5_CDS_FORCE=1`.
3. `app.R` membawa jalur baca lokal NetCDF sendiri (`read_era5_daily`) bila cache
   harian tidak ada, dengan cache keyed di `cache_path`, memakai direktori
   `cache/era5_cds_nc/`, `data_era5_tomat_cilegon_lampung_jabar_nc/`, dst.
   Fallback terakhir: frame iklim NA agar UI tetap bisa tampil.

---

## 6. Alur Data BMKG

1. `update_bmkg_forecast.R` (R + `jsonlite`):
   - URL: `https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=<BMKG_ADM4>`
     (default `36.72.07.1001`).
   - Flatten data jam-jaman `cuaca`; ambil `tanggal`, `suhu` (`t`),
     `kelembaban` (`hu`), `hujan` (`tp`), `weather_desc`.
   - Filter window `[hari ini, hari ini + BMKG_FORECAST_DAYS]` (default 4).
   - Agregasi harian: `suhu_puncak=max`, `kelembaban=mean`, `hujan=sum`,
     `weather_desc=mode`.
   - Simpan ke `cache/bmkg_forecast_daily.rds` (dengan `lokasi`, `adm4`).
2. `app.R` (`blend_climate_sources`) menggabungkan iklim untuk tanggal pasar:
   - ERA5 historis + BMKG forecast + **Bridge** (carry-forward nilai iklim
     terakhir dari ERA5 untuk mengisi tanggal kosong antara akhir ERA5 dan awal
     BMKG).
   - Hanya tanggal yang ada di `market_dates` yang dipertahankan.

---

## 7. Daftar Fitur

Dibentuk di `prepare_avg_frame()` dari baris `"Harga rata-rata"` yang lengkap,
lalu `model.matrix` pada formula (tanpa intercept) menghasilkan **33 kolom**:

Fitur kontinu (15):

| Fitur | Definisi |
|---|---|
| `harga` (target/level) | harga rata-rata tiga pasar per hari |
| `harga_kemarin` | `lag(harga, 1)` |
| `lag2`, `lag3`, `lag7` | `lag(harga, 2/3/7)` |
| `ma7` | rata-rata bergerak 7 hari (`filter` sides=1; NA diisi harga hari itu) |
| `vol7` | rolling standar deviasi 7 hari |
| `min7`, `max7` | rolling min/max 7 hari |
| `margin_hl` | selisih harga tertinggi–terendah antar pasar per tanggal |
| `suhu_puncak`, `kelembaban`, `hujan` | iklim gabungan (ERA5/BMKG/Bridge) |
| `suhu_puncak_lag1` | `lag(suhu_puncak, 1)` |
| `delta_suhu` | `diff(suhu_puncak)` (hari pertama diisi 0) |
| `hei` | `pmax(suhu_puncak_lag1 - 32, 0) * pmax(82 - kelembaban, 0)` |

Dummy kategorikal (18):

- `day_of_week` → 7 dummy (Monday..Sunday)
- `month` → 11 dummy (month02..month12; month01 sebagai referensi)

Total kolom matriks fitur = 33. Baris lengkap setelah complete-cases = **1039**
(dataset Tomat baseline).

---

## 8. Train/Test Split

- Data diurutkan berdasarkan tanggal.
- `train_ratio = 0.80`; `train_n = floor(n * 0.8)`, dijepit ke `[10, n-1]`.
- **Training = 80% terawal, test = 20% terakhir. Tidak ada data validasi
  terpisah.**
- Evaluasi test memakai **rolling forecast satu langkah ke depan**
  (`predict_test_rolling`): untuk setiap hari test, prediksi `h=1` memakai
  histori saat itu (termasuk aktual hari-hari test sebelumnya yang sudah lewat),
  lalu aktual hari itu dimasukkan ke histori.
- `selected_model` di-hardcode = `"Hybrid"`.

---

## 9. Konfigurasi SARIMA

`fit_pipeline_models()`:

- `price_ts = ts(harga, frequency = 7)`
- Uji differencing: `ndiffs(price_ts, test="adf")`, `ndiffs(price_ts, test="kpss")`,
  `nsdiffs(price_ts)` (dilaporkan sebagai `stationarity_label`).
- `auto.arima(seasonal = TRUE, stepwise = TRUE, approximation = FALSE,
  allowdrift = TRUE, allowmean = TRUE)`.
- Hasil reproduksi baseline (data Tomat): **SARIMA (0,1,1)(0,0,0)[7]**
  (ADF d=0, KPSS d=1, seasonal D=0), koefisien `ma1 = -0.6355`.
- Residual `e_t = Y_t - SARIMA_t` menjadi target XGBoost residual.

---

## 10. Konfigurasi XGBoost Regresi

Parameter tetap (di-hardcode, tidak ada tuning/CV/early stopping/validasi):

```text
objective     = "reg:squarederror"
max_depth     = 3
eta           = 0.05
nrounds       = 120
subsample     = 0.9
colsample_bytree = 0.9
nthread       = 1
```

Dua model regresi:

1. `xgb_reg` — target **residual SARIMA** (`e_t`), fitur matriks 33 kolom.
2. `xgb_price` — target **harga level aktual** (`Y_t`).

Matriks fitur dibangun dengan `xgb.DMatrix` dari `model.matrix` formula fitur
(33 kolom). RNG dipengaruhi `set.seed(2026)` di awal app, tetapi urutan pemanggilan
`xgb.train` mengonsumsi aliran RNG yang sama (karena `subsample`), sehingga output
sedikit bergantung pada urutan fit.

---

## 11. Konfigurasi XGBoost Klasifikasi

```text
objective     = "binary:logistic"
eval_metric   = "logloss"
max_depth     = 3
eta           = 0.05
nrounds       = 120
subsample     = 0.9
colsample_bytree = 0.9
nthread       = 1
```

- Target: label proxy `gagal_distribusi` (lihat Bagian 14).
- Output `risk_prob` = probabilitas proxy, dipakai untuk status risiko.

---

## 12. Formula Hybrid Saat Ini

Persis seperti di kode `fit_pipeline_models()` dan `predict_future_path()`:

```text
residual_hybrid = sarima_fit + xgb_residual
hybrid_raw      = 0.001 * residual_hybrid + 0.999 * xgb_price
hybrid_bias     = median(tail(harga - hybrid_raw, min(14, n))) + 30
hybrid          = pmax(0, hybrid_raw + hybrid_bias)
```

Nilai `hybrid_bias` terukur pada baseline (fit data penuh, Tomat):
**≈ 467.54** (Rp).

Secara efektif model utama ≈ 0.1% komponen SARIMA-residual + 99.9% XGBoost harga
langsung + bias manual. Label "Hybrid SARIMA-XGBoost" tidak sepenuhnya
merepresentasikan struktur ini (akan dikoreksi di Methodology V2).

---

## 13. Perilaku Kalibrasi Bias Saat Ini

Ada dua lapis bias:

1. **In-sample:** `hybrid_bias = median(14 error terakhir) + 30` (ditambahkan ke
   semua prediksi hybrid, termasuk forecast live).
2. **Test-set calibration (untuk angka evaluasi saja):** grid `seq(-500, 500, 1)`,
   pilih bias yang meminimalkan MAPE pada **test set**, lalu terapkan ke forecast
   hybrid test dan metrik Hybrid dihitung ulang.

Catatan baseline: kalibrasi memakai test set (tidak benar-benar out-of-sample);
ini perilaku legacy yang dicatat apa adanya dan akan diubah di Methodology V2.

---

## 14. Definisi Label Proxy Risiko

Tidak ada ground-truth kejadian gagal distribusi. Label `gagal_distribusi`
dibentuk di `fit_pipeline_models()` sebagai proxy:

```text
future_jump(t) = max(harga[t+1 .. t+3]) / harga[t] - 1
heat_flag(t)   = suhu_puncak_lag1(t) >= quantile(suhu_puncak_lag1, 0.75)
margin_flag(t) = margin_hl(t) >= quantile(margin_hl, 0.80)

gagal_distribusi(t) = (future_jump(t) >= 0.10) | (margin_flag(t) & heat_flag(t))
```

- NA pada label diisi 0.
- Bila hasil hanya satu kelas, fallback: `gagal_distribusi = (future_jump >= quantile(future_jump, 0.80))`.
- Kuantil dihitung **dalam data training** (per fit).
- Positive rate baseline (data penuh Tomat): **≈ 24.16%**.

---

## 15. Ambang Risiko Saat Ini

```text
cut(risk_prob, breaks = c(-Inf, 0.45, 0.70, Inf),
    labels = c("Aman", "Waspada", "Darurat"))
```

| Status | Interval probabilitas proxy |
|---|---|
| Aman | `risk_prob < 0.45` |
| Waspada | `0.45 <= risk_prob < 0.70` |
| Darurat | `risk_prob >= 0.70` |

Distribusi status baseline (fit data penuh Tomat): Aman **926**, Waspada **102**,
Darurat **11** (dari 1039 baris; angka sedikit bervariasi tergantung urutan
pemanggilan model karena aliran RNG `xgb.train`).

Ambang 0.45 / 0.70 adalah konstanta hardcode tanpa kalibrasi dari distribusi
historis — dicatat apa adanya.

---

## 16. Penggunaan SHAP Saat Ini

- `predict(model, x_reg, predcontrib = TRUE)` untuk `xgb_reg` dan `xgb_cls`.
- Kolom `BIAS` / `(Intercept)` dibuang.
- `shap_reg_summary` / `shap_cls_summary`: `colMeans(abs(contrib))` per fitur,
  diambil **top 8**.
- Dependence plot: satu fitur utama `suhu_puncak_lag1`:
  - regresi: `dep_reg` = (suhu, SHAP, harga), garis vertikal annotasi 32.2 °C (tampilan UI).
  - klasifikasi: `dep_cls` = (suhu, SHAP, risk_prob), garis vertikal annotasi 33.0 °C (tampilan UI).
- Top-8 SHAP baseline (fit data penuh Tomat):
  - Regresi: `vol7`, `lag7`, `lag3`, `hujan`, `harga_kemarin`, `max7`, `min7`, `ma7`.
  - Klasifikasi: `hujan`, `suhu_puncak_lag1`, `margin_hl`, `month03`, `ma7`, `suhu_puncak`, `vol7`, `lag2`.

SHAP dipakai untuk interpretasi, bukan klaim kausal.

---

## 17. Horizon Prediksi

- `forecast_horizon = 3` → **H+1, H+2, H+3**.
- `build_live_future_climate()`: ambil tanggal BMKG setelah tanggal terakhir data
  (`head(..., horizon)`); sisanya diisi carry-forward baris BMKG terakhir; bila
  tidak ada BMKG, carry-forward nilai iklim historis terakhir.
- `predict_future_path()`: iteratif per hari — forecast SARIMA `h=3` (mean),
  fitur harga dibentuk dari histori + `prediksi_hybrid` hari-hari sebelumnya
  (proxy), hitung `sarima`, `xgb_residual`, `xgb_price`, `prediksi_hybrid`,
  `risk_prob`, dan `status` per hari.
- Forecast live baseline (data per 2026-06-28): H+1 Rp14.397,53; H+2 Rp14.958,50;
  H+3 Rp14.896,06; risk_prob ≈ 0,19–0,20; status **Aman**.
- Panel early warning memakai `max(risk_prob)` H+1..H+3.

---

## 18. Metrik Baseline (Direproduksi)

Metrik berhasil direproduksi di lingkungan lokal pada **2026-08-17** dengan
menjalankan pipeline `app.R` apa adanya (bukan angka yang dibuat-buat).

**Reproduksi:**
```r
# dari root repositori, R 4.5.2
Rscript --vanilla -e "source('cilegon_komoditas_shiny/app.R', local=FALSE)"
# lalu objek global: test_metrics, rolling_test_metrics, sarima_label,
# stationarity_label, best_tune, pipeline_data, test_data, forecast_data
```

**Konteks data:**
- Komoditas: **Tomat** (default).
- Sumber: `Cache harga SAGON + ERA5 historis + BMKG forecast`.
- Rentang data model: **2023-01-11 s.d. 2026-06-28** (1039 baris).
- Rentang test (20%): **2025-11-18 s.d. 2026-06-28** (210 baris).
- State cache saat baseline: SAGON diperbarui 2026-06-28 (rentang cache
  2026-06-24..2026-06-28); ERA5 `cds-merged 2023-01-02..2026-06-22`; BMKG
  forecast 2026-06-28..2026-06-30 (adm4 `36.72.07.1001`). Artinya "forecast live"
  mengarah ke tanggal 2026-06-29..2026-07-01 yang sudah lewat saat baseline
  direproduksi (staleness cache).

**Test metrics — rolling 1-step, 20% terakhir:**

| Model | MAE (Rp) | RMSE (Rp) | MAPE |
|---|---|---|---|
| **Hybrid** (selected) | **660.01** | **872.86** | **5.40%** |
| XGBoost harga | 661.10 | 874.53 | 5.40% |
| SARIMA-only | 1359.83 | 1596.17 | 11.42% |
| MA7 | 1371.43 | 1607.84 | 11.70% |
| Naive | 1387.30 | 1664.75 | 11.21% |

**Rolling test metrics — 60 titik training terakhir:**

| Model | MAE (Rp) | RMSE (Rp) | MAPE |
|---|---|---|---|
| Hybrid | 360.49 | 473.19 | 3.48% |
| Naive | 372.22 | 648.36 | 3.51% |
| MA7 | 453.97 | 653.67 | 4.21% |
| SARIMA-only | 469.94 | 679.70 | 4.40% |

**Parameter terpilih/reproduksi:**
- Selected model: **Hybrid** (hardcode).
- Orde SARIMA: **(0,1,1)(0,0,0)[7]**; `ma1 = -0.6355`.
- XGBoost: `max_depth=3`, `eta=0.05`, `nrounds=120` (regresi & klasifikasi),
  `subsample=0.9`, `colsample_bytree=0.9`.
- Ambang risiko: Aman < 0.45; Waspada 0.45–0.70; Darurat ≥ 0.70.
- `hybrid_bias` (in-sample): ≈ 467.54.

---

## 19. Metrik yang Tidak Tersedia

- **Tidak ada metrik yang terhambat** pada baseline ini: pipeline `app.R` dapat
  dijalankan lokal (R 4.5.2 + package `shiny`, `ggplot2`, `readxl`, `terra`,
  `forecast`, `xgboost` tersedia), sehingga MAE/RMSE/MAPE, orde SARIMA, parameter
  XGBoost, ambang risiko, rentang tanggal, dan komoditas berhasil dicatat.
- **Tidak ada metrik per-horizon (H+1/H+2/H+3)** di evaluasi test: `app.R` hanya
  mengevaluasi rolling 1-langkah pada test 20%. Bidang ini tetap **tidak
  tersedia** di baseline (perlu evaluasi terpisah).
- **Tidak ada metrik untuk komoditas selain Tomat** dalam reproduksi ini; app
  menyediakan evaluasi per komoditas, tetapi baseline hanya mengambil default
  (Tomat). Bidang ini tersedia bila dijalankan per komoditas.
- **Tidak ada metrik error forecast live** (belum ada aktual untuk H+1..H+3 saat
  baseline), dan cache yang ada sudah basi (terakhir 2026-06-28).

---

## 20. Keterbatasan Saat Ini (dicatat apa adanya)

1. **Harga SAGON dari scraping halaman publik**, bukan API resmi; cache dapat
   basi bila updater tidak berjalan.
2. **ERA5**: timestamp jam dibuang sebelum `t2m`, `d2m`, `tp` diselaraskan,
   sehingga pairing suhu–dewpoint dan RH berisiko salah; agregasi harian dapat
   bias. (Per Sprint Plan → diperbaiki di Methodology V2 Sprint 1.)
3. **ERA5 spasial**: satu extent luas Bandung–Cilegon dirata-ratakan, mencampur
   interpretasi "klima lokal Cilegon" dan "exposure koridor distribusi".
4. **Fitur rolling** (`ma7`, `vol7`, `min7`, `max7`, `margin_hl`) dapat memuat
   informasi target hari yang sama (potensi target leakage); `ma7` mengisi NA
   dengan harga hari itu.
5. **Test set dipakai untuk kalibrasi bias** (grid −500..+500 memilih MAPE
   minimum pada test) → evaluasi tidak murni out-of-sample.
6. **Formula hybrid** praktis 0.1% SARIMA-residual + 99.9% XGBoost langsung +
   bias manual.
7. **Label risiko adalah proxy**, bukan probabilitas kejadian nyata; ambang
   0.45/0.70 hardcode tanpa kalibrasi.
8. **Parameter XGBoost tetap**, tanpa cross-validation/early stopping/validation.
9. **MAPE** memakai `pmax(abs(actual), 1)` sebagai penyebut (perlindungan harga
   mendekati nol), bukan penyebut murni.
10. **State aplikasi global** (`.GlobalEnv`) memakai pola non-idiomatik yang
    rawan konflik antar sesi.
11. Artifact eksperimen di `cache/experiments/*.csv`, `cache/pipeline_*.rds`,
    `cache/models/xgb_models_*.rds` **bukan keluaran `app.R` saat ini** (berasal
    dari eksperimen tanggal 2026-06-22 dengan skala/ortho/varian fitur berbeda);
    jangan dianggap sebagai metrik baseline resmi.

---

## 21. Verifikasi Baseline

- Dokumen ini dibuat dengan membaca kode apa adanya tanpa mengubah formula,
  fitur, split, ERA5, ambang risiko, SHAP, output forecast, atau struktur app.
- Tidak ada perubahan perilaku statistik pada sprint ini (perubahan hanya
  dokumentasi).
- Tidak ada kredensial/secrets yang ditulis ke dokumen ini.
