# SEC-DATA

SEC-DATA is a research prototype and data-science portfolio project for
monitoring food-commodity prices in Kota Cilegon, forecasting prices for H+1 to
H+3, and surfacing a model-derived distribution-stress signal.

## Project Overview

The dashboard combines market observations, ERA5 historical climate, and BMKG
forecast weather in one reproducible R Shiny application. It is intended for
research communication and operational exploration, not as a production
probability-of-failure system.

## Problem / Objective

Price changes and local heat conditions can complicate short-horizon market
monitoring. SEC-DATA provides a transparent workflow that can be inspected,
re-run, and challenged: data refresh, feature construction, time-ordered
evaluation, live forecast, proxy risk score, and SHAP explanations are kept
separate.

## Key Outputs

- three-market price monitoring with local climate context;
- a dynamic H+1/H+2/H+3 price forecast per commodity;
- final-test and rolling-origin candidate-model comparisons;
- `Skor Risiko Tekanan Distribusi` / `Distribution Stress Score` on a 0–100
  display scale;
- SHAP contribution plots for the forecast and proxy-score models.

## Data Sources

| Source | Role | Repository path / updater |
|---|---|---|
| SAGON Cilegon | Market prices and market-level spread | `cilegon_komoditas_shiny/update_sagon_daily.R` |
| Local Excel | Bootstrap historical prices per commodity | `cilegon_komoditas_shiny/Data komoditas *.xlsx` |
| ERA5 | Historical hourly climate, aggregated daily | `cilegon_komoditas_shiny/update_era5_daily.R`, `R/data_climate.R` |
| BMKG | H+1 to H+3 forecast climate | `cilegon_komoditas_shiny/update_bmkg_forecast.R` |

Methodology V2 uses **Cilegon Local Climate**: the nearest 2×2 ERA5 cells to
Kota Cilegon. `valid_time` remains UTC until the hourly variables are aligned;
the local calendar date is then derived in `Asia/Jakarta`. See
[`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md).

## Architecture

```text
SAGON / Excel ─┐
ERA5 ──────────┼─> data loading + source blending ─> shared feature builder
BMKG ──────────┘                                      │
                                                     ├─> candidate forecasts
                                                     ├─> proxy risk classifier
                                                     └─> SHAP + Shiny state
```

Core data and model functions live in `R/`; the session-local Shiny modules
live in `cilegon_komoditas_shiny/modules/`. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Methodology V2

The active methodology is documented in
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). Its key rules are:

- hourly ERA5 variables are aligned by exact timestamp before daily aggregation;
- price lags and rolling features for `Y[t]` use information no later than
  `t-1`;
- training and live inference use the same feature builder;
- model selection uses the lowest finite rolling-validation WAPE;
- final test is an untouched chronological block evaluated after selection;
- residual hybrid, XGBoost Direct, SARIMA, and simple baselines remain distinct
  candidates; no manual blend or final-test bias correction is active.

The historical V1 record remains at
[`docs/METHODOLOGY_V1_BASELINE.md`](docs/METHODOLOGY_V1_BASELINE.md) and is not
an active performance claim.

## Leakage Safeguards

`R/features.R`, `R/evaluation.R`, and the test suite enforce lagged price
features, lagged market margin, shared train/serve construction, chronological
folds, refitting at each origin, and validation-only champion selection.

## Evaluation Protocol

The protocol is development period → expanding-window rolling validation →
untouched final test. Evaluation is one-step-ahead; H+2/H+3 are operational
forecast horizons, not separate scored horizons in this protocol. Full details
are in [`docs/EVALUATION_PROTOCOL.md`](docs/EVALUATION_PROTOCOL.md).

The dashboard uses bounded defaults for startup responsiveness and labels those
numbers as an in-app preview. The verified metrics below come from the full
protocol command, not from the bounded preview.

## Candidate Models

- Naive;
- Seasonal Naive 7;
- MA7;
- SARIMA;
- XGBoost Direct;
- SARIMA + XGBoost Residual.

## Champion Model

For the latest verified full-protocol **Tomat** run, `Naive` is the champion
because it has the lowest validation WAPE. The dashboard chooses the champion
dynamically for the selected commodity; the name is not hard-coded in the live
forecast path.

## Verified Metrics

Verified with the corrected Methodology V2 pipeline on 22 August 2026 using
Tomat data from 2023-01-02 to 2026-06-28: 12 validation folds (84 rows) and a
125-row untouched final test from 2026-02-13 to 2026-06-28. Values below are
from that run only; MAE and RMSE are in the source price unit (Rp), while WAPE
and MAPE are percentages.

| Candidate | Validation WAPE | Final-test WAPE | Final-test MAE | Final-test RMSE | Final-test MAPE |
|---|---:|---:|---:|---:|---:|
| **Naive (champion)** | **3.8168%** | **4.7903%** | **621.33** | **889.94** | **4.7888%** |
| Seasonal Naive 7 | 8.9059% | 9.8684% | 1,280.00 | 1,654.08 | 9.9717% |
| MA7 | 5.7382% | 6.7287% | 872.76 | 1,107.73 | 6.8193% |
| SARIMA | 4.4793% | 5.5566% | 720.73 | 916.01 | 5.6233% |
| XGBoost Direct | 3.9974% | 5.6689% | 735.30 | 924.71 | 5.7278% |
| SARIMA + XGBoost Residual | 4.2417% | 5.6116% | 727.86 | 930.67 | 5.6733% |

No live-forecast error is reported because future actuals are not yet available.

## Distribution Stress Proxy

`risk_proxy_v1` predicts a historical proxy label based on future price jump or
the documented heat-plus-margin rule. The dashboard output is a
**Distribution Stress Score**, not an observed-event probability. Status bands
(`Aman`, `Waspada`, `Darurat`) are derived from development-score quantiles.
See [`docs/RISK_PROXY_DEFINITION.md`](docs/RISK_PROXY_DEFINITION.md).

## SHAP / Explainability

SHAP regression describes contribution to model forecast output. SHAP for the
classifier describes contribution to the Distribution Stress Score. Both are
associational explanations; neither establishes causality, a price change in
Rupiah, or a real distribution-failure probability.

## Limitations

Important limits include public-page scraping, stale or unavailable caches,
ERA5 historical pseudo-forecast versus BMKG live climate, unresolved
precipitation-accumulation semantics in source NetCDF, no observed distribution
failure label, fixed XGBoost parameters, and metrics verified here only for the
Tomat full run. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## Repository Structure

```text
R/                             reusable data, feature, model, evaluation code
cilegon_komoditas_shiny/      Shiny app, modules, updaters, Excel inputs, caches
docs/                          active methodology and reproducibility documents
notebooks/                     retained ERA5 download and NetCDF inspection notebooks
scripts/                       evaluation and ERA5 rebuild commands
tests/testthat/                automated R tests
```

Generated NetCDF and cache directories retain their existing updater paths and
are ignored or treated as refresh artifacts. The duplicate root Excel snapshot
was removed; the app-folder commodity files are canonical bootstrap inputs.
The two identical ERA5 RDS paths remain as a compatibility alias pair because
the app and refresh workflow still reference both names.

## Local Setup

Requirements: R 4.5.2, Python 3.12 for the ERA5 downloader, and the locked R
and Python dependencies.

```powershell
Rscript -e "renv::restore(prompt = FALSE)"
python -m venv .venv
.venv\Scripts\python -m pip install --requirement requirements.txt
```

Start the dashboard:

```powershell
Rscript -e "shiny::runApp('cilegon_komoditas_shiny', host='127.0.0.1', port=3838)"
```

## Tests

```powershell
Rscript -e "testthat::test_dir('tests/testthat', reporter = 'summary')"
```

## Evaluation

```powershell
Rscript --vanilla scripts/run_evaluation.R Tomat --full
Rscript --vanilla scripts/run_evaluation.R --all --full
```

The second command is optional and may be substantially slower. It writes
per-commodity evaluation artifacts under the ignored
`cilegon_komoditas_shiny/cache/evaluation/` directory.

## Data Refresh

The refresh workflow runs the SAGON, BMKG, and ERA5 updaters every six hours
when GitHub Actions secrets are configured. The local equivalents are:

```powershell
Rscript cilegon_komoditas_shiny/update_sagon_daily.R
Rscript cilegon_komoditas_shiny/update_bmkg_forecast.R
Rscript cilegon_komoditas_shiny/update_era5_daily.R
```

Refresh output is cache data, not a new validated model result. The dashboard
shows source dates and session load time separately so a delayed cache is not
presented as fresh.

## Deployment

The deployable application is `cilegon_komoditas_shiny/`. Deployment targets
and production credentials are intentionally not committed. Configure the
approved hosting target and secrets outside the repository, then run the same
test and smoke checks before publishing.

## License

This project is licensed under the GNU Affero General Public License v3.0.
See [LICENSE](LICENSE) for the complete terms.
