# Methodology V2

Status: **active methodology** for the current repository.

Sprint 8 changes documentation, source-status communication, and a runnable
evaluation-script path. It does not change the statistical design below.

## 1. Spatial and temporal climate processing

The climate scope is **Cilegon Local Climate**, represented by the nearest 2×2
ERA5 grid cells to Kota Cilegon. The active pipeline keeps hourly
`valid_time` in UTC, aligns `t2m`, `d2m`, and `tp` at the same timestamp, derives
relative humidity, and only then aggregates to local calendar days in
`Asia/Jakarta`.

Daily definitions are maximum temperature, mean relative humidity, and total
precipitation. Live future climate uses BMKG where available. A bridge or
carry-forward is explicitly labeled when a source gap exists.

## 2. Market preparation and features

SAGON or Excel market rows are normalized by date, market, commodity, and
price. The three markets are summarized as `Harga rata-rata`; market spread is
`margin_hl`.

For target price `Y[t]`, price-derived predictors stop at `t-1`:

```text
harga_kemarin = Y[t-1]
lag2/lag3/lag7 = Y[t-2], Y[t-3], Y[t-7]
ma7/vol7/min7/max7 = summary(Y[t-7 .. t-1])
margin_hl_lag1 = margin_hl[t-1]
```

Climate and calendar features are built through the same functions for
training, evaluation, and live inference. Historical ERA5 is used as a
pseudo-forecast because historical BMKG forecasts are not stored; live
forecasting uses BMKG when it is present.

## 3. Candidate forecast models

The candidate set is:

1. Naive;
2. Seasonal Naive 7;
3. MA7;
4. SARIMA selected by `forecast::auto.arima()`;
5. XGBoost Direct for price level;
6. SARIMA + XGBoost Residual, where `e[t] = Y[t] - SARIMA[t]` and the final
   candidate is `max(0, SARIMA + predicted residual)`.

XGBoost parameters are fixed (`max_depth=3`, `eta=0.05`, `nrounds=120`,
`subsample=0.9`, `colsample_bytree=0.9`, `nthread=1`). They are configuration,
not a claim of global optimality.

## 4. Champion selection

The champion is selected separately for each commodity using the lowest finite
rolling-validation WAPE. Selection is frozen before final-test evaluation. The
same selected key is passed to the live forecast path; the dashboard does not
hard-code a model name.

## 5. Risk output

The risk classifier uses `risk_proxy_v1`. Its label is a historical proxy based
on a future price jump or the documented heat-plus-margin condition. The output
is a **Distribution Stress Score**, displayed as 0–100, not a calibrated
probability of an observed distribution failure. Status bands are derived from
development-score quantiles only. See
[`RISK_PROXY_DEFINITION.md`](RISK_PROXY_DEFINITION.md).

## 6. SHAP

SHAP is calculated after the fitted model paths are established. Regression
SHAP describes contribution to forecast/model prediction. Classifier SHAP
describes contribution to the Distribution Stress Score. Both are
associational and non-causal.

## 7. Verified Tomat result

The full protocol run verified on 22 August 2026 used 12 validation folds and a
125-row final test. The selected champion was **Naive** with validation WAPE
3.8168%; its final-test WAPE was 4.7903%, MAE 621.33 Rp, RMSE 889.94 Rp, and
MAPE 4.7888%. These values are for the stated local cache snapshot and are not
automatically transferable to another commodity or refresh.

## 8. Historical record

[`METHODOLOGY_V1_BASELINE.md`](METHODOLOGY_V1_BASELINE.md) records the legacy
pipeline and its old metrics. It is intentionally preserved as historical
context and must not be read as the active methodology.
