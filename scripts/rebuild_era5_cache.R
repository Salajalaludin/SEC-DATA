# Rebuild the corrected ERA5 daily cache from local NetCDF files.
#
# Methodology V2 (Sprint 1): hourly variables are aligned by exact valid_time,
# relative humidity is computed from timestamp-matched temperature/dewpoint,
# and daily aggregation runs only after alignment. Spatial scope is
# "Cilegon Local Climate" (era5_config()$extent).
#
# This script reads the NetCDF files already present locally (e.g. from
# data_era5_tomat_cilegon_lampung_jabar_nc/) so the corrected cache can be
# produced without hitting the CDS API. It also reports validation findings and
# before/after summary statistics.
#
# Usage (from repository root):
#   Rscript --vanilla scripts/rebuild_era5_cache.R \
#     [src_dir] [start_date] [end_date]
# Example:
#   Rscript --vanilla scripts/rebuild_era5_cache.R \
#     data_era5_tomat_cilegon_lampung_jabar_nc 2023-01-01 2026-06-30

args <- commandArgs(trailingOnly = TRUE)
src_dir <- if (length(args) >= 1) args[1] else "data_era5_tomat_cilegon_lampung_jabar_nc"
start_date <- as.Date(if (length(args) >= 2) args[2] else "2023-01-01")
end_date <- as.Date(if (length(args) >= 3) args[3] else "2026-06-30")

suppressPackageStartupMessages(library(terra))
source("R/data_climate.R", local = FALSE)
source("R/era5_netcdf.R", local = FALSE)

app_cache_dir <- "cilegon_komoditas_shiny/cache"
primary_path <- file.path(app_cache_dir, "era5_daily_bandung_cilegon.rds")
fallback_path <- file.path(app_cache_dir, "era5_daily.rds")

cat("=== ERA5 cache rebuild (corrected pipeline) ===\n")
cat("source dir :", src_dir, "\n")
cat("date range :", as.character(start_date), "to", as.character(end_date), "\n")
cat("spatial    :", era5_config()$spatial_label, "\n")

## Before (legacy cache), for comparison.
before <- NULL
if (file.exists(primary_path)) {
  obj <- readRDS(primary_path)
  before <- if (is.list(obj) && !is.null(obj$data)) obj$data else obj
}
if (!is.data.frame(before) || nrow(before) == 0) {
  if (file.exists(fallback_path)) {
    obj <- readRDS(fallback_path)
    before <- if (is.list(obj) && !is.null(obj$data)) obj$data else obj
  }
}

## Rebuild corrected daily climate from local NetCDF files.
hourly <- read_era5_hourly_range(src_dir, start_date, end_date, era5_config()$extent)
if (!is.data.frame(hourly) || nrow(hourly) == 0) stop("Tidak ada data ERA5 jam-jaman terbaca.", call. = FALSE)

hv <- validate_era5_hourly(hourly)
cat("\n--- hourly validation ---\n")
print(hv)

daily <- aggregate_era5_daily(hourly)
daily <- daily[daily$tanggal >= start_date & daily$tanggal <= end_date, , drop = FALSE]
dv <- validate_era5_daily(daily)
cat("\n--- daily validation ---\n")
print(dv)

cat("\n--- date range (after) ---\n")
cat(as.character(min(daily$tanggal)), "to", as.character(max(daily$tanggal)), "(n =", nrow(daily), ")\n")

## Comparison over the overlapping period.
if (is.data.frame(before) && nrow(before) > 0) {
  overlap <- intersect(before$tanggal, daily$tanggal)
  if (length(overlap) > 0) {
    b <- before[before$tanggal %in% overlap, c("tanggal", "suhu_puncak", "kelembaban", "hujan")]
    a <- daily[daily$tanggal %in% overlap, c("tanggal", "suhu_puncak", "kelembaban", "hujan")]
    b <- b[order(b$tanggal), ]
    a <- a[order(a$tanggal), ]
    cat("\n--- before vs after (overlap ", as.character(min(overlap)), " to ",
        as.character(max(overlap)), ", n = ", length(overlap), ") ---\n", sep = "")
    stats <- function(d) data.frame(
      suhu_puncak_mean = mean(d$suhu_puncak, na.rm = TRUE),
      suhu_puncak_min  = min(d$suhu_puncak, na.rm = TRUE),
      suhu_puncak_max  = max(d$suhu_puncak, na.rm = TRUE),
      kelembaban_mean  = mean(d$kelembaban, na.rm = TRUE),
      kelembaban_min   = min(d$kelembaban, na.rm = TRUE),
      kelembaban_max   = max(d$kelembaban, na.rm = TRUE),
      hujan_mean       = mean(d$hujan, na.rm = TRUE),
      hujan_max        = max(d$hujan, na.rm = TRUE),
      hujan_days_gt50  = sum(d$hujan > 50, na.rm = TRUE)
    )
    cat("before (legacy corridor):\n"); print(stats(b))
    cat("after  (corrected local):\n"); print(stats(a))
    cat("delta suhu_puncak mean:", mean(a$suhu_puncak - b$suhu_puncak, na.rm = TRUE), "\n")
    cat("delta kelembaban mean :", mean(a$kelembaban - b$kelembaban, na.rm = TRUE), "\n")
    cat("delta hujan mean      :", mean(a$hujan - b$hujan, na.rm = TRUE), "\n")
  }
}

## Write corrected cache (both paths, same content as the updater does).
dir.create(app_cache_dir, recursive = TRUE, showWarnings = FALSE)
key <- paste("cds-merged-local", min(daily$tanggal), max(daily$tanggal))
saveRDS(list(key = key, data = daily), primary_path)
saveRDS(list(key = key, data = daily), fallback_path)
cat("\nWrote corrected cache:\n")
cat(" -", primary_path, "\n")
cat(" -", fallback_path, "\n")
cat("\nDone.\n")
