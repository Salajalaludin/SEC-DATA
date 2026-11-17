# Limitations

SEC-DATA is a defensible prototype, not a validated production decision system.

## Data limitations

- SAGON data come from public-page scraping, not an official market API.
- Local Excel and RDS caches can be delayed, incomplete, or stale.
- ERA5 historical climate is a pseudo-forecast during training because archived
  BMKG forecasts are not available.
- A bridge/carry-forward value preserves continuity but is not a new climate
  observation and must not be described as fresh.
- The semantics of `tp` precipitation accumulation in some local NetCDF files
  still require source-level confirmation before rainfall should be treated as
  a fully validated predictor.

## Model limitations

- The live operational horizon is H+1 to H+3, while the formal evaluation is
  one-step-ahead; separate H+2/H+3 error metrics are not produced.
- XGBoost parameters are fixed and are not globally tuned.
- Verified metrics in the active documentation are for the Tomat full run and
  the stated cache snapshot. They do not establish performance for every
  commodity or future refresh.
- No live-forecast error is reported until future actuals exist.

## Risk and explainability limitations

- There is no observed distribution-failure ground truth in the current data.
- `risk_proxy_v1` is derived from historical price/heat/margin patterns, so its
  score is a Distribution Stress Score, not an event probability.
- `Aman`, `Waspada`, and `Darurat` are score bands for monitoring, not proof of
  supply failure or a calibrated intervention threshold.
- SHAP contributions are model associations and are not causal effects.

## Operational limitations

- SAGON, BMKG, ERA5, and cache availability can differ between machines.
- The hosted startup optimization depends on a generated, date-matched
  evaluation artifact; without it, rolling evaluation can be slow on a small
  worker. A mismatched artifact is rejected rather than presented as current.
- A clean checkout needs dependency restore and appropriate non-secret runtime
  configuration before the app can start.
- The current refresh workflow commits selected cache files to Git; object
  storage or a dedicated data release has not been introduced.
- No deployment target is configured in this repository.
