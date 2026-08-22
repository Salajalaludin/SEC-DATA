# Architecture

SEC-DATA is a small R Shiny application with reusable R modules, local/cache
data sources, and session-local dashboard state.

## Runtime flow

```text
Excel + SAGON cache ─┐
ERA5 cache/NetCDF ───┼─> load_project_data()
BMKG cache ──────────┘          │
                                ├─> prepare_avg_frame()
                                ├─> build_training_features()
                                ├─> evaluate_pipeline()
                                ├─> fit_pipeline_models()
                                └─> build_dashboard_state()
                                         │
                                  reactiveVal per session
                                         │
               monitoring / forecast / risk / evaluation / SHAP modules
```

## Module ownership

- `R/data_market.R`: market discovery, Excel/cache merge, source metadata;
- `R/data_climate.R`: ERA5 timestamp alignment, daily aggregation, validation,
  source blending;
- `R/features.R`: shared training and future feature construction;
- `R/evaluation.R`: chronological splits, rolling-origin refits, metrics, and
  champion selection;
- `R/model_risk.R`: versioned proxy label, classifier, score bands, and leakage
  guard;
- `R/explainability.R`: regression and proxy-score SHAP artifacts;
- `R/pipeline.R`: orchestration and live forecast path;
- `cilegon_komoditas_shiny/modules/`: UI/server modules;
- `cilegon_komoditas_shiny/app.R`: bootstrap, UI composition, and session wiring.

## State and session isolation

`bootstrap_snapshot` is an immutable startup artifact. Each Shiny session places
its own snapshot in a `reactiveVal`; commodity switching and refresh replace
that session's state only. Processed features and model artifacts remain in
session memory. No session-selected commodity is assigned into `.GlobalEnv`.

## Refresh and fallback behavior

Refresh uses cache-first data loading with local-file/NetCDF fallbacks. Errors
from configured realtime market or climate endpoints fall back to the last
usable local/cache source, and the visible source label reports the successful
fallback. A failed manual refresh leaves the last valid state in place and
reports the error. A missing BMKG forecast does not become a silent fresh
forecast: live climate rows are labeled as carry-forward and the source date
remains visible. A missing primary ERA5 RDS can use the legacy-compatible alias
or local NetCDF rebuild.

## Cache and deployment boundaries

The app and updater intentionally retain these paths:

```text
cilegon_komoditas_shiny/cache/sagon_daily_long.rds
cilegon_komoditas_shiny/cache/bmkg_forecast_daily.rds
cilegon_komoditas_shiny/cache/era5_daily.rds
cilegon_komoditas_shiny/cache/era5_daily_bandung_cilegon.rds
```

The last filename is legacy naming, not an active Bandung–Cilegon spatial
interpretation. Deployment credentials and host-specific configuration stay
outside Git.
