# SEC-DATA — Refactor & Methodology Sprint Plan

Repository: `Salajalaludin/SEC-DATA`  
Target system: Dashboard komoditas pangan Cilegon berbasis SAGON + ERA5 + BMKG + SARIMA + XGBoost + SHAP.

## 1. Tujuan Dokumen

Dokumen ini memecah perbaikan SEC-DATA menjadi beberapa sprint agar perubahan tidak dilakukan sekaligus dan setiap tahap dapat divalidasi sebelum lanjut.

Prinsip urutan pengerjaan:

1. Betulkan validitas data dan metodologi terlebih dahulu.
2. Hitung ulang evaluasi setelah leakage dan contamination hilang.
3. Baru tentukan champion model.
4. Setelah pipeline statistik stabil, refactor aplikasi dan deployment.
5. Terakhir lakukan cleanup, testing, dokumentasi, dan polish.

> **Catatan penting:** seluruh MAE, RMSE, MAPE, SHAP, risk score, dan klaim performa model lama harus dianggap sementara sampai Sprint 1–3 selesai.

---

# Sprint Overview

| Sprint | Fokus | Prioritas |
|---|---|---|
| Sprint 0 | Baseline, guardrail, dan audit reproducibility | P0 |
| Sprint 1 | Perbaikan ERA5 dan data climate pipeline | P0 |
| Sprint 2 | Eliminasi target leakage dan train/serve skew | P0 |
| Sprint 3 | Redesign evaluasi time-series | P0 |
| Sprint 4 | Redesign Hybrid SARIMA-XGBoost | P0–P1 |
| Sprint 5 | Redesign risk model dan SHAP | P1 |
| Sprint 6 | Refactor arsitektur R Shiny | P1 |
| Sprint 7 | Reproducibility, CI, testing, dan repository cleanup | P2 |
| Sprint 8 | Documentation, UX, dan final validation | P2–P3 |

---

# Sprint 0 — Baseline & Guardrails

## Objective

Membekukan kondisi awal repository sebelum perubahan metodologis besar dilakukan.

## Scope

- Rekam struktur repository saat ini.
- Rekam output model saat ini sebagai baseline pembanding.
- Pisahkan hasil lama dari hasil setelah metodologi diperbaiki.
- Tambahkan aturan agar tidak terjadi perubahan besar tanpa validation artifact.

## Tasks

- [ ] Buat branch kerja khusus, misalnya `refactor/methodology-v2`.
- [ ] Simpan baseline metrik lama:
  - MAE
  - RMSE
  - MAPE
  - selected model
  - konfigurasi SARIMA
  - konfigurasi XGBoost
  - threshold risk
- [ ] Simpan screenshot/dashboard output lama bila dibutuhkan untuk perbandingan.
- [ ] Catat rentang tanggal dataset untuk setiap komoditas.
- [ ] Catat versi R, Python, dan package utama.
- [ ] Tambahkan file `docs/METHODOLOGY_V1_BASELINE.md`.
- [ ] Tambahkan warning pada README bahwa metodologi sedang direvisi.

## Deliverables

```text
docs/
└── METHODOLOGY_V1_BASELINE.md
```

## Acceptance Criteria

- Kondisi model sebelum refactor dapat direproduksi.
- Metrik lama tidak tertukar dengan hasil metodologi baru.
- Tidak ada perubahan formula/model pada sprint ini.

---

# Sprint 1 — Fix ERA5 Climate Pipeline

## Objective

Memastikan data iklim benar secara temporal dan spasial sebelum dipakai kembali untuk training.

## Problems Addressed

### 1. Timestamp hourly dibuang terlalu dini

Pipeline saat ini mengubah timestamp ERA5 langsung menjadi tanggal harian sebelum temperature, dewpoint, dan precipitation diselaraskan.

Risiko:

- pairing temperature–dewpoint salah;
- many-to-many merge berdasarkan tanggal;
- relative humidity salah;
- agregasi harian bias.

### 2. Extent terlalu luas

ERA5 saat ini menggunakan area besar Bandung–Cilegon lalu dirata-ratakan secara spasial.

Hal ini harus dibuat eksplisit sebagai salah satu dari dua desain:

- **Local Cilegon climate**, atau
- **distribution corridor climate exposure**.

Jangan mencampurkan kedua interpretasi.

## Tasks

### Timestamp

- [ ] Pertahankan `valid_time` dalam format POSIXct.
- [ ] Merge `t2m`, `d2m`, dan `tp` berdasarkan `valid_time`.
- [ ] Hitung RH pada level hourly.
- [ ] Setelah semua variabel align, agregasi menjadi daily.
- [ ] Gunakan timezone `Asia/Jakarta` secara konsisten.

### Daily aggregation

Gunakan definisi:

```text
suhu_puncak = max(T hourly)
kelembaban = mean(RH hourly)
hujan = total precipitation harian
```

- [ ] Tambahkan validation untuk jumlah observasi hourly per hari.
- [ ] Flag hari yang tidak lengkap.
- [ ] Pastikan tidak ada duplicate timestamp.

### Spatial scope

Pilih salah satu desain:

#### Opsi A — Cilegon Local Climate

Gunakan grid ERA5 yang merepresentasikan Kota Cilegon.

#### Opsi B — Distribution Corridor

Gunakan beberapa titik/grid yang mewakili:

```text
origin → corridor → destination
```

dan bentuk exposure metric yang jelas.

Untuk versi awal, **Opsi A lebih direkomendasikan** karena lebih sederhana dan defensible.

### Tests

- [ ] Test satu file NetCDF kecil.
- [ ] Verifikasi 24 timestamp/hari atau jumlah valid yang masuk akal.
- [ ] Pastikan RH berada pada 0–100%.
- [ ] Pastikan precipitation tidak negatif.
- [ ] Bandingkan beberapa tanggal dengan sumber eksternal/manual spot check.

## Deliverables

```text
R/
└── data_climate.R

tests/
└── testthat/
    └── test-climate-processing.R
```

## Acceptance Criteria

- Tidak ada merge berdasarkan `tanggal` sebelum hourly variables aligned.
- `valid_time` dipertahankan sampai tahap agregasi harian.
- Climate scope dijelaskan eksplisit.
- Dataset climate final diregenerate.
- Pipeline lama tidak lagi dipakai.

---

# Sprint 2 — Remove Target Leakage & Train/Serve Skew

## Objective

Memastikan semua fitur pada waktu `t` hanya menggunakan informasi yang benar-benar tersedia sebelum prediksi `t`.

## Problems Addressed

Fitur seperti:

```text
ma7
vol7
min7
max7
margin_hl
```

saat ini dapat mengandung informasi dari target hari yang sama.

## Correct Feature Rule

Untuk prediksi:

```text
Y[t]
```

fitur harga hanya boleh memakai:

```text
Y[t-1], Y[t-2], ..., Y[t-k]
```

## Tasks

### Lag features

- [ ] Pastikan:
  - `harga_kemarin = harga[t-1]`
  - `lag2 = harga[t-2]`
  - `lag3 = harga[t-3]`
  - `lag7 = harga[t-7]`

### Rolling features

Ubah menjadi:

```text
ma7[t]  = mean(y[t-7:t-1])
vol7[t] = sd(y[t-7:t-1])
min7[t] = min(y[t-7:t-1])
max7[t] = max(y[t-7:t-1])
```

- [ ] Jangan gunakan `harga[t]` dalam rolling feature untuk target `harga[t]`.

### Market margin

Ubah:

```text
margin_hl[t]
```

menjadi minimal:

```text
margin_hl_lag1[t]
```

kecuali benar-benar tersedia sebelum forecasting dilakukan.

### Climate features

Pisahkan:

```text
observed climate
forecast climate
```

agar training dan serving memiliki information set yang konsisten.

### Shared feature builder

- [ ] Buat satu fungsi feature engineering yang digunakan baik saat:
  - training;
  - test;
  - live inference.

Contoh target:

```r
build_features(history, forecast_context)
```

Tujuannya menghindari dua implementasi berbeda antara training dan prediction.

### Leakage tests

- [ ] Tambahkan automated test yang memastikan perubahan `harga[t]` tidak mengubah feature vector untuk prediksi `t`.
- [ ] Tambahkan test untuk setiap rolling feature.
- [ ] Tambahkan test untuk margin lag.

## Deliverables

```text
R/
└── features.R

tests/testthat/
├── test-lag-features.R
└── test-no-target-leakage.R
```

## Acceptance Criteria

- Semua predictor untuk target `t` berasal dari data maksimal `t-1` atau forecast external yang memang tersedia.
- Feature engineering training = feature engineering inference.
- Tidak ada rolling feature yang membaca target hari yang sama.
- Semua model lama diretrain setelah perubahan.

---

# Sprint 3 — Rebuild Time-Series Evaluation

## Objective

Membuat evaluation protocol yang benar-benar out-of-sample dan tidak menggunakan test set untuk tuning.

## Problems Addressed

- Test set digunakan untuk mencari bias terbaik.
- Rolling SARIMA tidak benar-benar di-update.
- Baseline mendapat information set berbeda dari model utama.
- Tidak ada validation set / rolling validation.

## Evaluation Design

Gunakan:

```text
Development period
│
├── rolling-origin validation
│   ├── Fold 1
│   ├── Fold 2
│   ├── Fold 3
│   └── ...
│
└── untouched final test
```

## Tasks

### Split

- [ ] Definisikan final test sebagai blok waktu terbaru.
- [ ] Jangan sentuh final test untuk:
  - hyperparameter selection;
  - bias calibration;
  - model selection;
  - threshold tuning.

### Rolling-origin CV

- [ ] Implement expanding window.

Contoh:

```text
Fold 1
Train: 1 ───── 100
Valid:           101─107

Fold 2
Train: 1 ───────── 107
Valid:              108─114
```

### SARIMA rolling

Pilih salah satu:

#### Option A — Refit each forecast origin

Paling mudah dijelaskan.

#### Option B — Update state tanpa full refit

Boleh jika implementasinya benar dan terdokumentasi.

Untuk prototype penelitian, gunakan **Option A** terlebih dahulu.

### Fair baseline

Tambahkan:

- [ ] Naive
- [ ] Seasonal Naive 7
- [ ] MA7
- [ ] SARIMA
- [ ] XGBoost Direct
- [ ] Hybrid candidate

Semua harus mendapatkan information set yang sama.

### Metrics

Gunakan:

- MAE
- RMSE
- WAPE
- MAPE, bila target tidak dekat nol

Tambahkan per-horizon bila H+1, H+2, H+3 dievaluasi terpisah.

### Calibration

- [ ] Hapus tuning bias pada final test.
- [ ] Bila calibration dibutuhkan, pelajari hanya pada validation folds.

## Deliverables

```text
R/
└── evaluation.R

docs/
└── EVALUATION_PROTOCOL.md
```

## Acceptance Criteria

- Final test hanya dievaluasi satu kali setelah model dan hyperparameter dibekukan.
- Tidak ada parameter yang dipilih berdasarkan final test.
- Naive dan model utama memakai information set yang sama.
- SARIMA rolling benar-benar memakai histori terbaru.
- Tabel evaluasi baru menggantikan metrik lama.

---

# Sprint 4 — Redesign Hybrid SARIMA-XGBoost

## Objective

Membuat definisi hybrid model yang secara statistik konsisten dan dapat dipertanggungjawabkan.

## Problem

Model saat ini secara praktis:

```text
0.1% SARIMA-residual
+
99.9% XGBoost direct
+
manual bias
```

sehingga label “Hybrid SARIMA-XGBoost” tidak merepresentasikan struktur model yang sebenarnya.

## Candidate Models

### Candidate A — Residual Hybrid

Direkomendasikan sebagai desain utama:

```text
SARIMA:
ŷ_sarima[t]

Residual:
e[t] = y[t] - ŷ_sarima[t]

XGBoost:
ê[t] = f(X[t])

Final:
ŷ[t] = ŷ_sarima[t] + ê[t]
```

### Candidate B — Direct XGBoost

```text
ŷ[t] = XGB(X[t])
```

Tetap dipertahankan sebagai competitor.

### Candidate C — Stacking

Hanya jika dibutuhkan:

```text
ŷ =
w1 × SARIMA
+
w2 × Residual Hybrid
+
w3 × XGBoost Direct
```

Bobot harus dipelajari dari validation folds.

## Tasks

- [ ] Hapus hardcoded `0.001 / 0.999`.
- [ ] Hapus arbitrary `+30`.
- [ ] Implement Residual Hybrid murni.
- [ ] Evaluasi vs XGBoost Direct.
- [ ] Gunakan validation result untuk menentukan champion.
- [ ] Jangan memaksakan Hybrid sebagai champion jika baseline/model lain lebih baik.

## Champion Selection

Model utama dipilih berdasarkan kombinasi:

1. out-of-sample error;
2. stability antar fold;
3. robustness;
4. interpretability;
5. operational complexity.

## Deliverables

```text
R/
├── model_sarima.R
└── model_xgboost.R
```

## Acceptance Criteria

- Tidak ada bobot manual tanpa validation evidence.
- Tidak ada arbitrary bias correction.
- Champion dipilih berdasarkan rolling validation + untouched test.
- Nama model di dashboard sesuai dengan model yang benar-benar digunakan.

---

# Sprint 5 — Risk Model & SHAP Redesign

## Objective

Membuat output risiko tidak overclaiming dan memisahkan secara jelas proxy risk dari observed event probability.

## Current Problem

Dataset tidak memiliki ground-truth kejadian gagal distribusi.

Label dibuat dari:

```text
future price jump
OR
high market margin + high heat
```

Maka model saat ini sebenarnya mempelajari **proxy**.

## New Naming

Gunakan istilah:

```text
Distribution Stress Score
```

atau:

```text
Skor Risiko Tekanan Distribusi
```

Jangan gunakan:

```text
Probabilitas gagal distribusi
```

sampai ada outcome aktual.

## Tasks

### Proxy target

- [ ] Dokumentasikan definisi proxy secara formal.
- [ ] Beri version identifier:

```text
risk_proxy_v1
```

- [ ] Pisahkan proxy target dari real-world event target.

### Threshold

Threshold:

```text
Aman
Waspada
Darurat
```

tidak boleh arbitrer tanpa justifikasi.

- [ ] Kalibrasi threshold dari historical distribution atau validation.
- [ ] Tampilkan bahwa status adalah proxy-based alert.

### SHAP

- [ ] Hitung SHAP hanya setelah final model ditentukan.
- [ ] Jangan interpretasikan SHAP sebagai causal effect.
- [ ] Jelaskan:
  - SHAP regression = contribution to prediction;
  - SHAP proxy classifier = contribution to proxy score.

### Future direction

Tambahkan roadmap untuk ground-truth data seperti:

- gangguan pasokan;
- stok distributor;
- keterlambatan distribusi;
- operasi pasar;
- laporan supply disruption.

## Deliverables

```text
R/
├── model_risk.R
└── explainability.R

docs/
└── RISK_PROXY_DEFINITION.md
```

## Acceptance Criteria

- Dashboard tidak lagi menyebut proxy sebagai probabilitas kejadian nyata.
- Threshold terdokumentasi.
- SHAP tidak diklaim sebagai hubungan kausal.
- Risk model memiliki definisi target yang versioned.

---

# Sprint 6 — Refactor R Shiny Architecture

## Objective

Memisahkan data, modeling, evaluation, dan UI agar aplikasi dapat diuji dan dipelihara.

## Target Structure

```text
SEC-DATA/
├── R/
│   ├── config.R
│   ├── utils.R
│   ├── data_market.R
│   ├── data_climate.R
│   ├── features.R
│   ├── model_sarima.R
│   ├── model_xgboost.R
│   ├── model_risk.R
│   ├── evaluation.R
│   └── explainability.R
│
├── app/
│   ├── app.R
│   └── modules/
│       ├── mod_monitoring.R
│       ├── mod_forecast.R
│       ├── mod_risk.R
│       ├── mod_evaluation.R
│       └── mod_shap.R
```

## Tasks

### Remove global state

Hapus pola:

```r
assign(..., envir = .GlobalEnv)
```

Gunakan session-local reactive state:

```r
state <- reactiveVal(...)
```

### Split responsibilities

- [ ] `app.R` hanya bootstrap.
- [ ] Data loading dipindahkan.
- [ ] Feature engineering dipindahkan.
- [ ] Training dipindahkan.
- [ ] Evaluation dipindahkan.
- [ ] SHAP dipindahkan.
- [ ] UI dipisah menjadi modules.

### Caching

- [ ] Bedakan:
  - raw data cache;
  - processed feature cache;
  - trained model cache.
- [ ] Cache harus punya metadata/version.

## Deliverables

Struktur modular baru.

## Acceptance Criteria

- `app.R` tidak lagi menjadi file monolitik.
- Tidak ada mutable application state di `.GlobalEnv`.
- Dua user dapat memilih komoditas berbeda tanpa state collision.
- Modeling functions dapat dipanggil tanpa menjalankan Shiny.

---

# Sprint 7 — Reproducibility, CI & Tests

## Objective

Membuat repository dapat dibangun ulang secara konsisten.

## Tasks

### R

- [ ] Tambahkan `renv`.
- [ ] Generate `renv.lock`.
- [ ] Pin package versions.

### Python

Gunakan salah satu:

```text
pyproject.toml
```

atau:

```text
requirements.txt
```

Lebih direkomendasikan:

```text
pyproject.toml + uv
```

### Remove runtime installation

Hapus pola:

```text
script berjalan
→ package tidak ada
→ install package sendiri
```

Dependency installation harus dilakukan pada setup/CI.

### Tests

Tambahkan:

```text
tests/testthat/
```

Minimal tests:

- climate timestamp alignment;
- daily aggregation;
- duplicate detection;
- lag feature correctness;
- leakage prevention;
- rolling evaluation;
- model matrix alignment;
- risk proxy generation.

### CI

Pisahkan workflow:

```text
ci.yml
update-data.yml
```

`ci.yml`:

- restore dependencies;
- run tests;
- static validation;
- smoke test app startup.

`update-data.yml`:

- hanya update data.

### Git cache strategy

Evaluasi ulang commit cache `.rds` setiap 6 jam ke `main`.

Alternatif:

- GitHub Release asset;
- object storage;
- artifact;
- dedicated data branch.

## Deliverables

```text
renv.lock
pyproject.toml

.github/workflows/
├── ci.yml
└── update-data.yml

tests/testthat/
```

## Acceptance Criteria

- Repository dapat direstore dari clean machine.
- Tests berjalan otomatis.
- Data update dan CI tidak bercampur.
- Dependency version tidak floating.
- Tidak ada `pip install` dari production script.

---

# Sprint 8 — Repository Cleanup, Docs & Final UX

## Objective

Menyelesaikan repository sebagai project penelitian/portfolio yang rapi dan defensible.

## Repository Cleanup

Pindahkan exploratory notebook:

```text
notebooks/
├── 01_era5_exploration.ipynb
└── 02_netcdf_validation.ipynb
```

Hapus scratch notebook yang tidak diperlukan.

Data:

```text
data/
├── raw/
├── interim/
└── processed/
```

Hapus file duplikat.

## Documentation

Final documentation:

```text
README.md
docs/
├── DATA_SOURCES.md
├── METHODOLOGY.md
├── EVALUATION_PROTOCOL.md
├── RISK_PROXY_DEFINITION.md
├── ARCHITECTURE.md
└── LIMITATIONS.md
```

README final minimal mencakup:

1. problem statement;
2. data sources;
3. architecture;
4. methodology;
5. evaluation;
6. champion model;
7. limitations;
8. run locally;
9. deployment;
10. data refresh.

## Dashboard UX

Setelah model stabil:

- [ ] tampilkan freshness timestamp;
- [ ] tampilkan source badge ERA5/BMKG;
- [ ] tampilkan champion model aktual;
- [ ] tampilkan uncertainty/limitations;
- [ ] jangan tampilkan proxy risk sebagai ground-truth probability;
- [ ] rapikan label SHAP;
- [ ] pastikan responsive UI.

## Final Validation

- [ ] Run seluruh pipeline dari clean environment.
- [ ] Update semua metrik.
- [ ] Update semua chart.
- [ ] Regenerate SHAP.
- [ ] Validasi H+1, H+2, H+3.
- [ ] Uji semua komoditas.
- [ ] Uji dua concurrent Shiny session.
- [ ] Uji fallback saat:
  - SAGON gagal;
  - BMKG gagal;
  - ERA5 terlambat;
  - cache kosong.

## Acceptance Criteria

- README konsisten dengan kode.
- Tidak ada klaim metodologis yang tidak didukung implementasi.
- Seluruh metrik berasal dari methodology v2.
- Repository siap dipresentasikan sebagai portfolio/research prototype.

---

# Dependency Map

```text
Sprint 0
   │
   ▼
Sprint 1 — Climate
   │
   ▼
Sprint 2 — Features
   │
   ▼
Sprint 3 — Evaluation
   │
   ▼
Sprint 4 — Forecast Model
   │
   ▼
Sprint 5 — Risk & SHAP
   │
   ▼
Sprint 6 — Shiny Refactor
   │
   ▼
Sprint 7 — CI & Reproducibility
   │
   ▼
Sprint 8 — Documentation & UX
```

Sprint 1–5 sebaiknya tidak dibalik karena output model pada sprint berikutnya bergantung pada validitas pipeline sebelumnya.

---

# Definition of Done Global

Project dianggap selesai ketika seluruh kondisi berikut terpenuhi:

- [ ] Tidak ada target leakage.
- [ ] Tidak ada train/serve skew.
- [ ] ERA5 hourly variables aligned berdasarkan timestamp.
- [ ] Final test tidak pernah digunakan untuk tuning.
- [ ] Rolling evaluation benar secara temporal.
- [ ] Baseline dibandingkan secara fair.
- [ ] Champion model ditentukan dari evidence, bukan hardcoded preference.
- [ ] Risk output disebut proxy score bila belum ada ground truth.
- [ ] SHAP tidak diklaim sebagai causal explanation.
- [ ] Shiny tidak memakai mutable global state untuk session data.
- [ ] Dependency versions terkunci.
- [ ] Unit/integration tests berjalan di CI.
- [ ] Dokumentasi sesuai dengan implementasi.
- [ ] Semua metrik lama setelah perubahan metodologi dihitung ulang.

---

# Recommended Execution Strategy

Gunakan satu branch utama untuk refactor:

```text
refactor/methodology-v2
```

dan satu branch kecil per sprint bila ingin PR terpisah:

```text
sprint/00-baseline
sprint/01-era5
sprint/02-feature-leakage
sprint/03-evaluation
sprint/04-hybrid-model
sprint/05-risk-shap
sprint/06-shiny-architecture
sprint/07-ci-reproducibility
sprint/08-docs-polish
```

Setiap sprint harus menghasilkan PR yang dapat direview secara independen.

Format commit yang disarankan:

```text
fix(data): align ERA5 variables by valid time
fix(features): remove target leakage from rolling features
refactor(eval): add rolling-origin validation
refactor(model): implement residual SARIMA-XGBoost hybrid
refactor(risk): rename failure probability to distribution stress proxy
refactor(shiny): remove global dashboard state
test(pipeline): add leakage and climate processing tests
docs(methodology): document methodology v2
```

---

# Priority Rule

Jika waktu terbatas, kerjakan minimal:

```text
Sprint 1
→ Sprint 2
→ Sprint 3
→ Sprint 4
```

Empat sprint tersebut menentukan apakah hasil forecasting SEC-DATA dapat dipercaya.

UI, styling, repository cleanup, dan deployment improvement **tidak boleh didahulukan** sebelum empat sprint inti tersebut selesai.
