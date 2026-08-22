# `risk_proxy_v1`: Skor Risiko Tekanan Distribusi

## Tujuan dan batasan

Dashboard belum memiliki ground truth untuk kejadian distribusi yang benar-benar
teramati. Karena itu, output risk diberi nama **Skor Risiko Tekanan Distribusi**
(technical label: **Distribution Stress Score**). Nilai ini adalah sinyal
model-derived berbasis proxy pada skala 0–1, yang ditampilkan UI sebagai 0–100.
Nilai tersebut bukan probabilitas terkalibrasi dari kejadian distribusi nyata.

Versi proxy yang aktif adalah `risk_proxy_v1`. Label teknis
`gagal_distribusi` tetap disimpan pada data historis untuk audit, tetapi berarti
kelas proxy, bukan laporan kejadian aktual.

## Label proxy

Untuk baris historis target hari `t`, dengan frame yang sudah diurutkan tanggalnya:

```text
future_jump(t) = max(harga[t+1 .. t+3]) / harga[t] - 1
heat_flag(t)   = suhu_puncak_lag1(t) >= quantile(..., 0.75)
margin_flag(t) = margin_hl(t) >= quantile(..., 0.80)

gagal_distribusi(t) =
    (future_jump(t) >= 0.10) OR (heat_flag(t) AND margin_flag(t))
```

Kuantil heat dan margin dihitung dari frame yang dipakai untuk membangun label.
Future jump yang tidak tersedia diperlakukan non-positive bila kombinasi flag
lainnya juga tidak positif; fallback kuantil future jump hanya dipakai bila
aturan utama menghasilkan satu kelas. Formula dan fallback tercatat di
`build_risk_proxy_v1()`.

## Predictor dan leakage audit

Classifier dilatih dari matriks predictor yang sama dengan feature builder
forecasting. Predictor aktifnya adalah:

```text
suhu_puncak, suhu_puncak_lag1, delta_suhu, hei, hujan, kelembaban,
harga_kemarin, lag2, lag3, lag7, ma7, vol7, min7, max7,
margin_hl_lag1, day_of_week, month
```

Matrix tersebut tidak boleh memuat `harga` hari `t`, `margin_hl` hari `t`,
`future_jump`, `heat_flag`, `margin_flag`, `gagal_distribusi`,
`distribution_stress_score`, atau `status`. `margin_hl` hari yang sama hanya
dipakai untuk membentuk label proxy; feature builder Sprint 2 tetap memakai
`margin_hl_lag1` untuk predictor forecasting.

Audit ini dijalankan oleh `assert_risk_predictors_safe()` sebelum classifier
dilatih. `future_jump` dan field label lainnya hanya muncul sebagai kolom audit
historis, bukan input classifier.

## Score dan status

XGBoost binary-logistic menghasilkan model score 0–1. Score dipanggil
`distribution_stress_score`, bukan probabilitas observed event. Status dipetakan
secara deterministik:

```text
Aman     : score < threshold_waspada
Waspada  : threshold_waspada <= score < threshold_darurat
Darurat  : score >= threshold_darurat
```

Threshold memakai **development-score quantiles**: kuantil 1/3 dan 2/3 dari
score classifier pada data development/training saja. Nilai yang sudah dihitung
disimpan sebagai `stress_thresholds` di pipeline dan dipakai ulang tanpa
re-estimasi untuk final/live score. Jika dua kuantil sama karena ties, kode
menambahkan epsilon deterministik dan mencatat metode yang sama; ini bukan
threshold suhu atau threshold kejadian nyata.

Panel early warning menampilkan band score dan memberi panduan monitoring,
verifikasi stok/pasokan, cek lapangan, serta eskalasi. Status tidak berarti
distribusi telah dipastikan gagal.

## SHAP

SHAP dihitung setelah model yang digunakan ditetapkan dan memakai model yang
sesuai:

- regresi: `core$models$xgb_reg`, dengan interpretasi **contribution to
  forecast/model prediction**;
- risk: `risk_fit$model`, dengan interpretasi **contribution to Distribution
  Stress Score**.

Keduanya menjelaskan kontribusi asosiasional pada output model. SHAP tidak
membuktikan hubungan kausal, perubahan rupiah, atau perubahan probabilitas
kejadian nyata.

Garis anotasi suhu legacy 32.2°C dan 33.0°C dihapus karena tidak berasal dari
analisis threshold yang terdokumentasi. Angka 32°C yang masih dipakai dalam
formula `hei` adalah referensi feature-engineering heuristic dan bukan ambang
risk, bukan ambang kausal, serta bukan hasil penemuan dari plot SHAP.

## Limitasi dan kebutuhan data berikutnya

- Tidak ada outcome distribusi terverifikasi, sehingga sensitivity, specificity,
  calibration, dan klaim performa terhadap real failure tidak boleh dilaporkan.
- Future price jump adalah outcome historis untuk pembentukan label; ia tidak
  masuk predictor matrix dan tidak tersedia saat memberi score live.
- Iklim historis memakai ERA5 sebagai pseudo-forecast, sedangkan live memakai
  BMKG forecast; perbedaan ini tetap menjadi batasan metodologis.
- Model berikutnya memerlukan timestamp dan outcome terverifikasi untuk gangguan
  pasokan, stok distributor, keterlambatan distribusi, operasi pasar, serta
  laporan supply disruption. Outcome perlu dikaitkan ke lokasi/komoditas dan
  jendela waktu yang jelas sebelum digunakan sebagai target aktual.
