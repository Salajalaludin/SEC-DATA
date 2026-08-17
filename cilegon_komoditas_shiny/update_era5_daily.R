suppressPackageStartupMessages({
  library(terra)
})

app_file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- if (file.exists("cilegon_komoditas_shiny/update_era5_daily.R")) "cilegon_komoditas_shiny/update_era5_daily.R" else "update_era5_daily.R"
app_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

## Load centralised ERA5 transformation module (R/data_climate.R).
source_climate_module <- function(start_dir) {
  candidates <- unique(c(
    file.path(start_dir, "R", "data_climate.R"),
    file.path(dirname(start_dir), "R", "data_climate.R"),
    file.path(getwd(), "R", "data_climate.R")
  ))
  hit <- candidates[file.exists(candidates)]
  if (length(hit) == 0) stop("Modul R/data_climate.R tidak ditemukan.", call. = FALSE)
  source(hit[[1]], local = FALSE)
}
source_climate_module(app_dir)

era5_extent <- era5_config()$extent

read_cache_data <- function(path) {
  if (!file.exists(path)) return(NULL)
  obj <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(obj)) return(NULL)
  if (is.list(obj) && !is.null(obj$data)) obj$data else obj
}

valid_climate_frame <- function(x) {
  is.data.frame(x) &&
    nrow(x) > 0 &&
    all(c("tanggal", "suhu_puncak", "kelembaban", "hujan") %in% names(x)) &&
    any(complete.cases(x[, c("tanggal", "suhu_puncak", "kelembaban", "hujan")]))
}

find_cdsapirc <- function(app_dir) {
  candidates <- c(
    Sys.getenv("CDSAPIRC_PATH", ""),
    file.path(app_dir, ".cdsapirc"),
    ".cdsapirc",
    file.path(Sys.getenv("USERPROFILE", "~"), ".cdsapirc")
  )
  candidates <- candidates[nzchar(candidates)]
  hit <- candidates[file.exists(candidates)]
  if (length(hit) == 0) return(NULL)
  normalizePath(hit[[1]], winslash = "/", mustWork = FALSE)
}

refresh_era5_from_cds <- function(start_date, end_date, app_dir) {
  cdsapirc <- find_cdsapirc(app_dir)
  if (is.null(cdsapirc)) stop("File .cdsapirc tidak ditemukan.", call. = FALSE)

  helper <- normalizePath(file.path(app_dir, "fetch_era5_cds.py"), winslash = "/", mustWork = FALSE)
  if (!file.exists(helper)) stop("Helper fetch_era5_cds.py tidak ditemukan.", call. = FALSE)

  out_dir <- normalizePath(file.path(app_dir, "cache", "era5_cds_nc"), winslash = "/", mustWork = FALSE)
  py <- Sys.getenv("PYTHON_EXE", "python")
  cdsapi_check <- system2(py, c("-c", shQuote("import cdsapi")), stdout = TRUE, stderr = TRUE)
  cdsapi_code <- attr(cdsapi_check, "status")
  if (!is.null(cdsapi_code) && cdsapi_code != 0) {
    message("Python package cdsapi belum terbaca oleh ", py, ". Mencoba install ulang di interpreter yang sama.")
    install_out <- system2(py, c("-m", "pip", "install", "cdsapi"), stdout = TRUE, stderr = TRUE)
    install_code <- attr(install_out, "status")
    if (!is.null(install_code) && install_code != 0) {
      stop(paste("Install cdsapi gagal:", paste(install_out, collapse = " ")), call. = FALSE)
    }
  }
  force <- identical(Sys.getenv("ERA5_CDS_FORCE", "0"), "1")
  args <- c(
    helper,
    "--cdsapirc", cdsapirc,
    "--out-dir", out_dir,
    "--start-date", as.character(start_date),
    "--end-date", as.character(end_date)
  )
  if (force) args <- c(args, "--force")

  status <- system2(py, shQuote(args), stdout = TRUE, stderr = TRUE)
  code <- attr(status, "status")
  if (!is.null(code) && code != 0) {
    stop(paste("Download ERA5 via CDS gagal:", paste(status, collapse = " ")), call. = FALSE)
  }

  out_dir
}

## Read ERA5 NetCDF files into aligned daily climate using the centralised module.
## Hourly variables are aligned by exact valid_time; daily aggregation runs only
## after alignment. Validation findings are reported as messages.
read_era5_daily <- function(dir_path, start_date, end_date) {
  hourly <- read_era5_hourly_range(dir_path, start_date, end_date, era5_extent)
  if (!is.data.frame(hourly) || nrow(hourly) == 0) {
    return(data.frame(tanggal = as.Date(character()), suhu_puncak = numeric(), kelembaban = numeric(), hujan = numeric()))
  }
  hv <- validate_era5_hourly(hourly)
  message("ERA5 hourly validation: obs=", hv$n, ", duplikat_timestamp=", hv$duplicate_timestamps,
          ", RH di luar [0,100]=", hv$rh_out_of_bounds,
          ", hujan negatif=", hv$negative_precipitation,
          ", NA RH=", hv$na_rh_after_alignment,
          ", hari dengan <", era5_config()$min_hours_per_day, " obs=", hv$days_below_min_count,
          ", hari dengan >", era5_config()$expected_hours_per_day, " obs=", hv$days_above_expected_count)
  climate <- aggregate_era5_daily(hourly)
  climate <- climate[climate$tanggal >= start_date & climate$tanggal <= end_date, , drop = FALSE]
  climate
}

market_candidates <- c(file.path(app_dir, "Data komoditas tomat.xlsx"), file.path(dirname(app_dir), "Data komoditas tomat.xlsx"))
market_path <- market_candidates[file.exists(market_candidates)][1]
if (is.na(market_path) || !nzchar(market_path)) stop("File komoditas referensi untuk menentukan tanggal tidak ditemukan.", call. = FALSE)

market_sheets <- readxl::excel_sheets(market_path)
market_dates <- do.call(c, lapply(market_sheets, function(sheet) as.Date(readxl::read_excel(market_path, sheet = sheet)[["Tanggal"]])))
market_dates <- market_dates[!is.na(market_dates)]
sagon_cache <- read_cache_data(file.path(app_dir, "cache", "sagon_daily_long.rds"))
if (is.data.frame(sagon_cache) && "tanggal" %in% names(sagon_cache)) {
  market_dates <- c(market_dates, as.Date(sagon_cache$tanggal))
  market_dates <- market_dates[!is.na(market_dates)]
}
if (length(market_dates) == 0) stop("Tidak ada tanggal valid pada file komoditas.", call. = FALSE)

## Cache filenames are kept from the legacy pipeline to avoid breaking
## consumers/CI. NOTE (Methodology V2, Sprint 1): the content of
## era5_daily_bandung_cilegon.rds is now "Cilegon Local Climate"
## (see era5_config()$spatial_label), not the former Bandung-Cilegon corridor.
cache_path <- file.path(app_dir, "cache", "era5_daily_bandung_cilegon.rds")
fallback_path <- file.path(app_dir, "cache", "era5_daily.rds")
existing <- read_cache_data(cache_path)
if (!valid_climate_frame(existing)) existing <- read_cache_data(fallback_path)

era5_lag_days <- suppressWarnings(as.integer(Sys.getenv("ERA5_CDS_LAG_DAYS", "5")))
if (is.na(era5_lag_days) || era5_lag_days < 0) era5_lag_days <- 5
available_cap <- Sys.Date() - era5_lag_days
end_date <- min(max(market_dates, na.rm = TRUE), available_cap)
if (end_date < min(market_dates, na.rm = TRUE)) {
  message("Target ERA5 masih terlalu baru untuk CDS. Cap ketersediaan: ", as.character(available_cap), ".")
  quit(save = "no")
}
recent_days <- suppressWarnings(as.integer(Sys.getenv("ERA5_CDS_RECENT_DAYS", "45")))
if (is.na(recent_days) || recent_days < 7) recent_days <- 45
recent_start <- max(min(market_dates, na.rm = TRUE), end_date - recent_days + 1)
start_date <- if (valid_climate_frame(existing)) {
  max(min(max(existing$tanggal, na.rm = TRUE) + 1, end_date), recent_start)
} else {
  recent_start
}

if (start_date > end_date) {
  message("ERA5 cache sudah up to date sampai ", as.character(end_date), ".")
  quit(save = "no")
}

out_dir <- refresh_era5_from_cds(start_date, end_date, app_dir)
recent <- read_era5_daily(out_dir, start_date, end_date)
if (!valid_climate_frame(recent)) {
  probe_start <- max(as.Date(start_date) - 7, as.Date("2020-01-01"))
  probe <- read_era5_daily(out_dir, probe_start, end_date)
  if (valid_climate_frame(probe)) {
    latest_available <- max(probe$tanggal, na.rm = TRUE)
    message("Belum ada ERA5 baru untuk window ", as.character(start_date), " sampai ", as.character(end_date), ".")
    message("Data CDS terbaru yang tersedia saat ini sampai ", as.character(latest_available), ".")
    quit(save = "no")
  }
  stop("Hasil ERA5 terbaru kosong atau tidak valid.", call. = FALSE)
}

merged <- if (valid_climate_frame(existing)) {
  rbind(existing[!existing$tanggal %in% recent$tanggal, ], recent)
} else {
  recent
}
merged <- merged[order(merged$tanggal), ]

saveRDS(list(key = paste("scheduled-update", min(merged$tanggal), max(merged$tanggal)), data = merged), cache_path)
saveRDS(list(key = paste("scheduled-update", min(merged$tanggal), max(merged$tanggal)), data = merged), fallback_path)

message("ERA5 updated: ", as.character(min(recent$tanggal)), " sampai ", as.character(max(recent$tanggal)))

