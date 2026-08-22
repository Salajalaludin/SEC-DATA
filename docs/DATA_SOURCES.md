# Data sources and data layers

Status: active Methodology V2 documentation.

## Source inventory

| Source | Data | Access path | Fallback / freshness rule |
|---|---|---|---|
| SAGON Cilegon | Market prices by date and market | `update_sagon_daily.R` → `cache/sagon_daily_long.rds` | Local Excel remains the bootstrap base; cache rows win on duplicate keys. |
| Local Excel | Historical market bootstrap for each commodity | `cilegon_komoditas_shiny/Data komoditas *.xlsx` | Used when no live/cache row is available. |
| ERA5 | Hourly `t2m`, `d2m`, `tp`, aligned then aggregated daily | `update_era5_daily.R`, `R/data_climate.R` | Reads the primary daily RDS, then the legacy-compatible alias, then local NetCDF. |
| BMKG | Daily forecast climate for live H+1 to H+3 | `update_bmkg_forecast.R` → `cache/bmkg_forecast_daily.rds` | Missing BMKG is shown as a carry-forward climate source, not as a fresh forecast. |

## Canonical files

The canonical bootstrap price files are the eight commodity workbooks in
`cilegon_komoditas_shiny/`. `Data Pasar Kota Cilegon.xlsx` was an exact
SHA-256/content duplicate of the Tomat workbook and was removed in Sprint 8;
the app-folder Tomat workbook remains the file discovered by the app.

`era5_daily.rds` and `era5_daily_bandung_cilegon.rds` currently have identical
content. Both names are retained because the app, rebuild script, and refresh
workflow still reference the pair. The filename is legacy; the active spatial
meaning of the data is Cilegon Local Climate.

## Logical data layers

The repository keeps existing updater paths to avoid deployment and workflow
churn. The logical mapping is:

- **raw / bootstrap**: public SAGON responses, BMKG responses, local Excel, and
  source NetCDF files;
- **interim**: downloaded monthly NetCDF and hourly aligned climate frames;
- **processed**: daily climate RDS, SAGON cache RDS, evaluation CSV/RDS, and
  session-memory feature/model objects.

Generated NetCDF, cache, and evaluation directories remain in their existing
locations and are ignored or refreshed by workflow. They are not silently
promoted to validated results.

## Climate scope and units

ERA5 uses the nearest 2×2 grid cells to Cilegon. `valid_time` is kept as UTC
until `t2m`, `d2m`, and `tp` are joined on the exact timestamp. Daily features
are:

- `suhu_puncak`: maximum hourly temperature in °C;
- `kelembaban`: mean hourly relative humidity in %;
- `hujan`: daily precipitation total in mm.

Local dates are derived with `Asia/Jakarta`. The source pipeline validates
duplicate timestamps, hourly counts, RH bounds, negative precipitation, and
all-NA daily rows.

## Freshness and degraded sources

The dashboard reports source coverage dates separately from the session load
time. `ERA5`, `BMKG`, and `Bridge` are distinct source labels. `Bridge` means a
carry-forward value used to span a source gap; it is not an observation and is
not presented as fresh data. If a refresh fails, the previous valid session
state is retained and the UI shows the refresh error.

## Credentials and external access

CDS and BMKG configuration is supplied through environment variables or local
ignored files. No credentials belong in this repository. The refresh workflow
uses GitHub Actions secrets and removes temporary credential files at job end.
