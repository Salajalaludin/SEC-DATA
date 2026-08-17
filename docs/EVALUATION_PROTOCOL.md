# EVALUATION PROTOCOL — Methodology V2 (Sprint 3)

Status: **applicable as of Sprint 3**. Supersedes the legacy "80/20 test + MAPE bias grid"
evaluation recorded in `docs/METHODOLOGY_V1_BASELINE.md`.

## 1. Purpose

Provide a statistically valid, time-ordered forecast evaluation that does not leak
information from the future and does not tune anything on the final test. The legacy
pipeline (a) fit models once on an 80% training block and called the 20% tail
"rolling" without refitting, (b) fed constant baselines to Naive/MA7 while the hybrid
received newly observed history, and (c) searched a bias grid directly on the final
test. All three behaviours are removed.

## 2. Split design

Configuration lives in `eval_config()` in `R/evaluation.R` (not in UI code).

```text
development period  ->  rolling-origin validation  ->  untouched final test
(earliest)                                          (most recent block)
```

- Data are sorted chronologically; rows are never randomized.
- `final_test_size` = fraction of rows reserved as the final test (floor
  `min_final_test_obs` days). The final test is the most recent block and is
  **never** used for fitting, hyperparameter tuning, bias calibration, threshold
  tuning, model selection, feature selection, or weight choice.
- The development period is the earlier part used for rolling-origin validation.

## 3. Rolling-origin (expanding-window) validation

Implemented by `rolling_origin_folds()`:

- Minimum training observations: `min_train_obs` (default 60).
- Validation horizon per fold: `validation_horizon` = H days (default 7).
- Step between origins: `validation_step` (default 14 for the app, 7 for the full
  protocol). Windows are disjoint when `validation_step >= validation_horizon`.
- Number of origins capped by `max_folds` (keeps the most recent origins, bounding
  cost).

```text
Fold 1   train: 1 ..... o        validate: o+1 .. o+H
Fold 2   train: 1 ......... o'   validate: o'+1 .. o'+H     (o' = o + step)
```

Each fold's training window is a prefix of the previous fold's window plus more data
(expanding window); no fold uses any observation from its validation window during
training (no future leakage). Tests assert this.

## 4. Rolling one-step evaluation with refit

`rolling_one_step_eval()` implements the one-step-ahead protocol for each target day:

```text
for each target day t:
  1. fit/refit the forecasting model on all history available up to t-1
     (auto.arima + XGBoost residual + XGBoost direct, see R/evaluation.R
      fit_forecast_models; identical to the live-pipeline fit);
  2. predict day t from that fit (features built by the shared builder
     R/features.R, information no later than t-1);
  3. reveal the actual value of day t;
  4. append the actual to history; continue.
```

SARIMA is therefore **refit at every forecast origin** — it genuinely uses the newly
observed history. The old `predict_test_rolling()` (one static fit on the initial
block) is removed.

## 5. Information available at each origin

For a one-step prediction of `Y[t]`:

- price features: `Y[t-1]`, `Y[t-2]`, `Y[t-3]`, `Y[t-7]`, rolling `[t-7..t-1]`,
  `margin_hl[t-1]` (see `R/features.R`, Sprint 2);
- climate: BMKG forecast for day t at inference; observed ERA5 used as a historical
  pseudo-forecast in training (documented limitation — historical BMKG forecasts are
  not archived);
- calendar: day-of-week and month of day t.

## 6. Fair baselines

Every baseline is computed **at each origin from the same observed history** and
therefore receives the identical information set as the advanced models:

- Naive: `Naive[t] = Actual[t-1]`
- Seasonal Naive 7: `SeasonalNaive7[t] = Actual[t-7]`
- MA7: `MA7[t] = mean(Actual[t-7 .. t-1])`
- SARIMA-only: refit `auto.arima`, one-step mean forecast
- XGBoost Direct: refit XGBoost on price level, one-step forecast
- Hybrid (current candidate): `max(0, 0.001*(SARIMA + XGBoost-residual) + 0.999*XGBoost-direct + bias)`,
  with the in-sample bias recomputed from training history at each origin.

Baselines are not held constant across the evaluation period.

## 7. Metrics

`eval_metrics()` computes, for each model:

- MAE = mean(|e|)
- RMSE = sqrt(mean(e²))
- WAPE = Σ|e| / Σ max(|actual|, 1)
- MAPE = mean(|e| / max(|actual|, 1))

Metrics are reported for rolling-origin validation and for the untouched final test
separately. One-step-ahead is the evaluated horizon; per-horizon H+2/H+3 metrics are
not produced in this protocol (no actuals for those horizons under one-step
evaluation).

## 8. Calibration rules

- The test-set bias grid (`hybrid_bias_grid` over the final test) is **removed**.
- The only bias in the current hybrid is the in-sample bias recomputed from training
  history at each origin (median of the last 14 in-sample residuals + 30). It is part
  of the frozen legacy hybrid formula and is not fit from any test data. Hybrid-weight
  redesign is Sprint 4.

## 9. Untouched-test rule

- The final test is evaluated exactly once, after all decisions are frozen.
- Nothing is tuned, selected, or calibrated using final-test actuals.
- The one-step protocol reveals final-test actuals sequentially for the purpose of
  computing next-step features/baselines; this is standard backtesting and does not
  train models on future observations.

## 10. Configuration values (defaults in `eval_config()`)

| Parameter | Default (app) | Full protocol |
|---|---|---|
| min_train_obs | 60 | 60 |
| validation_horizon | 7 | 7 |
| validation_step | 7 | 7 |
| max_folds | 2 | 12 |
| final_test_size | 0.02 | 0.12 |
| min_final_test_obs | 14 | 42 |
| forecast_horizon | 3 | 3 |

The app uses bounded defaults so it stays responsive (each one-step refit costs
~1-3 s). The authoritative, larger protocol is run via:

```bash
Rscript --vanilla scripts/run_evaluation.R Tomat --full
```

## 11. Artifacts

`scripts/run_evaluation.R` writes per-commodity:

- `cilegon_komoditas_shiny/cache/evaluation/final_test_metrics_<commodity>.csv`
- `cilegon_komoditas_shiny/cache/evaluation/validation_metrics_<commodity>.csv`
- `cilegon_komoditas_shiny/cache/evaluation/evaluation_<commodity>.rds`

## 12. Tests

`tests/testthat/test-evaluation.R` covers chronological folds, no overlap/future
leakage, expanding training windows, rolling baseline updates, final-test isolation,
and metric calculations.
