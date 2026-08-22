# data_climate.R — ERA5 climate transformation pipeline (Methodology V2, Sprint 1)
#
# Centralised, reusable logic for reading ERA5 NetCDF, aligning hourly variables
# by exact valid_time, computing relative humidity, aggregating to daily climate
# features, and validating data quality.
#
# This module is shared by:
#   - cilegon_komoditas_shiny/update_era5_daily.R  (cache regeneration)
#   - cilegon_komoditas_shiny/app.R                (fallback NetCDF reading)
#   - tests/testthat/test-climate-processing.R     (unit tests)
#
# Spatial scope (Methodology V2): "Cilegon Local Climate".
# ERA5 variables are spatially averaged over the 2 x 2 grid cells (0.1 deg)
# nearest to Kota Cilegon (approx. 106.01 E, 6.00 S). This replaces the former
# large Bandung-Cilegon corridor extent, which was not a defensible local
# weather representation. The extent is configurable via era5_config().

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

#' ERA5 climate pipeline configuration.
#'
#' Returns a list of constants used across the pipeline:
#'   - extent:    spatial extent (SpatExtent) for Cilegon Local Climate.
#'   - tz_utc:    timezone of ERA5 valid_time timestamps (UTC).
#'   - tz_local:  operational local timezone (Asia/Jakarta).
#'   - expected_hours_per_day: nominal number of hourly observations per day.
#'   - min_hours_per_day: below this count a local day is flagged as suspicious.
#'   - spatial_label: human-readable spatial scope.
era5_config <- function() {
  list(
    extent = terra::ext(105.95, 106.15, -6.15, -5.95),
    tz_utc = "UTC",
    tz_local = "Asia/Jakarta",
    expected_hours_per_day = 24,
    min_hours_per_day = 20,
    spatial_label = "Cilegon Local Climate (2x2 ERA5 cells at 0.1 deg nearest Kota Cilegon)"
  )
}

# ---------------------------------------------------------------------------
# Timestamp handling
# ---------------------------------------------------------------------------

#' Parse valid_time from terra layer names (e.g. "t2m_valid_time=1577836800").
#'
#' @param layer_names character vector of layer names.
#' @return POSIXct in UTC.
parse_era5_valid_time <- function(layer_names) {
  matched <- grepl("valid_time=[0-9]+", layer_names)
  seconds <- rep(NA_real_, length(layer_names))
  seconds[matched] <- as.numeric(sub(".*valid_time=([0-9]+).*", "\\1", layer_names[matched]))
  as.POSIXct(seconds, origin = "1970-01-01", tz = era5_config()$tz_utc)
}

#' Convert a UTC POSIXct valid_time to the local (Asia/Jakarta) calendar date.
#'
#' ERA5 valid_time is UTC; the operational day is Asia/Jakarta (UTC+7, no DST).
#' @param valid_time POSIXct in UTC.
#' @return Date (Asia/Jakarta).
era5_local_tanggal <- function(valid_time) {
  as.Date(valid_time, tz = era5_config()$tz_local)
}

# ---------------------------------------------------------------------------
# Relative humidity
# ---------------------------------------------------------------------------

#' Relative humidity from temperature and dewpoint (Magnus formula), 0-100.
#'
#' Only valid where both temperature and dewpoint are present at the same
#' timestamp; otherwise NA.
#' @param temp_c numeric, temperature in Celsius.
#' @param dewpoint_c numeric, dewpoint in Celsius.
#' @return numeric vector in [0, 100], NA where inputs are NA.
relative_humidity <- function(temp_c, dewpoint_c) {
  valid <- !is.na(temp_c) & !is.na(dewpoint_c)
  out <- rep(NA_real_, length(temp_c))
  if (any(valid)) {
    actual <- exp((17.625 * dewpoint_c[valid]) / (243.04 + dewpoint_c[valid]))
    saturation <- exp((17.625 * temp_c[valid]) / (243.04 + temp_c[valid]))
    out[valid] <- pmin(100, pmax(0, 100 * actual / saturation))
  }
  out
}

# ---------------------------------------------------------------------------
# Reading and aligning hourly variables
# ---------------------------------------------------------------------------

#' Read one ERA5 variable from a NetCDF file and return a value per layer.
#'
#' @param path character, path to NetCDF file.
#' @param subds character, subdataset name ("t2m", "d2m", "tp").
#' @param extent SpatExtent to crop to.
#' @param fun character, spatial aggregation function (default "mean").
#' @return data.frame with columns valid_time (POSIXct UTC) and value.
read_era5_variable <- function(path, subds, extent, fun = "mean") {
  r <- terra::crop(terra::rast(path, subds = subds), extent)
  raster_time <- if (isTRUE(terra::has.time(r))) terra::time(r) else NULL
  vt <- if (length(raster_time) == terra::nlyr(r) &&
            (inherits(raster_time, "POSIXt") || inherits(raster_time, "Date"))) {
    as.POSIXct(raster_time, tz = era5_config()$tz_utc)
  } else {
    parse_era5_valid_time(names(r))
  }
  if (length(vt) != terra::nlyr(r) || anyNA(vt) || anyDuplicated(vt)) {
    stop("Metadata valid_time ERA5 tidak lengkap atau duplikat: ", path, call. = FALSE)
  }
  vals <- as.numeric(terra::global(r, fun, na.rm = TRUE)[, 1])
  data.frame(valid_time = vt, value = vals)
}

#' Align hourly ERA5 variables by exact valid_time.
#'
#' Temperature (t2m), dewpoint (d2m) and precipitation (tp) are joined by the
#' exact POSIXct valid_time. Calendar-date-only joins are never used here.
#' If the same timestamp appears twice for a variable the duplicate is kept and
#' reported by validate_era5_hourly(); a one-to-one pairing is expected.
#'
#' @param parts named list of data.frames, each with valid_time and value.
#' @return data.frame with valid_time, suhu, dewpoint, hujan (NA where missing).
align_era5_variables <- function(parts) {
  need <- c("suhu", "dewpoint", "hujan")
  if (!is.list(parts) || length(parts) == 0) {
    stop("align_era5_variables: tidak ada variabel untuk diselaraskan.", call. = FALSE)
  }
  out <- data.frame(valid_time = parts$suhu$valid_time, suhu = parts$suhu$value)
  for (nm in c("dewpoint", "hujan")) {
    d <- parts[[nm]]
    out <- merge(out, data.frame(valid_time = d$valid_time, value = d$value),
                 by = "valid_time", all = TRUE, suffixes = c("", ""))
    names(out)[ncol(out)] <- nm
  }
  out <- out[order(out$valid_time), , drop = FALSE]
  out
}

#' Read one ERA5 NetCDF file into timestamp-aligned hourly observations.
#'
#' t2m/d2m/tp are aligned by exact valid_time, relative humidity is computed
#' from timestamp-matched temperature and dewpoint, and the local calendar date
#' is derived only after alignment. No daily aggregation is performed here.
#'
#' @param path character, path to NetCDF file.
#' @param extent SpatExtent to crop to (default era5_config()$extent).
#' @return data.frame: valid_time (POSIXct UTC), tanggal (Date Asia/Jakarta),
#'   suhu (C), dewpoint (C), kelembaban (RH %), hujan (mm).
read_era5_hourly_from_nc <- function(path, extent = era5_config()$extent) {
  subdatasets <- tryCatch(names(terra::sds(path)), error = function(e) character())
  has_var <- function(var) var %in% subdatasets

  parts <- list()
  if (has_var("t2m")) {
    parts$suhu <- read_era5_variable(path, "t2m", extent)
    parts$suhu$value <- parts$suhu$value - 273.15
  }
  if (has_var("d2m")) {
    parts$dewpoint <- read_era5_variable(path, "d2m", extent)
    parts$dewpoint$value <- parts$dewpoint$value - 273.15
  }
  if (has_var("tp")) {
    parts$hujan <- read_era5_variable(path, "tp", extent)
    parts$hujan$value <- pmax(0, parts$hujan$value * 1000)
  }
  if (length(parts) == 0) {
    stop("Tidak ada variabel ERA5 yang dikenali di ", path, call. = FALSE)
  }

  hourly <- align_era5_variables(parts)
  hourly$kelembaban <- relative_humidity(hourly$suhu, hourly$dewpoint)
  hourly$tanggal <- era5_local_tanggal(hourly$valid_time)
  hourly
}

#' Read a range of ERA5 NetCDF files into a single aligned hourly frame.
#'
#' @param dir_path character, directory (searched recursively) holding .nc files.
#' @param start_date Date, first month included.
#' @param end_date Date, last month included.
#' @param extent SpatExtent to crop to (default era5_config()$extent).
#' @return data.frame of aligned hourly observations, or an empty frame.
read_era5_hourly_range <- function(dir_path, start_date, end_date,
                                   extent = era5_config()$extent) {
  files <- list.files(dir_path, pattern = "\\.nc$", recursive = TRUE, full.names = TRUE)
  ym_text <- sub(".*_(20[0-9]{2})_([0-9]{2})(_[0-9]{2})?\\.nc$", "\\1-\\2-01", basename(files))
  file_month <- as.Date(ym_text)
  start_month <- as.Date(format(start_date, "%Y-%m-01"))
  end_month <- as.Date(format(end_date, "%Y-%m-01"))
  files <- sort(files[!is.na(file_month) & file_month >= start_month & file_month <= end_month])

  chunks <- list()
  for (f in files) {
    ok <- tryCatch({
      df <- read_era5_hourly_from_nc(f, extent)
      if (is.data.frame(df) && nrow(df) > 0) chunks[[length(chunks) + 1]] <- df
      TRUE
    }, error = function(e) {
      warning("Gagal membaca file ERA5: ", f, " -> ", conditionMessage(e))
      FALSE
    })
    invisible(ok)
  }
  if (length(chunks) == 0) {
    return(data.frame(valid_time = as.POSIXct(numeric(), origin = "1970-01-01", tz = era5_config()$tz_utc),
                      tanggal = as.Date(character()),
                      suhu = numeric(), dewpoint = numeric(),
                      kelembaban = numeric(), hujan = numeric()))
  }
  do.call(rbind, chunks)
}

# ---------------------------------------------------------------------------
# Daily aggregation
# ---------------------------------------------------------------------------

#' Aggregate aligned hourly observations to daily climate features.
#'
#' Daily definitions (Methodology V2):
#'   suhu_puncak = maximum hourly temperature (local day)
#'   kelembaban  = mean hourly relative humidity (local day)
#'   hujan       = daily precipitation total (local day)
#' Aggregation happens only after hourly variables are aligned by valid_time.
#'
#' @param hourly data.frame from read_era5_hourly_from_nc (or range).
#' @return data.frame with tanggal, suhu_puncak, kelembaban, hujan.
aggregate_era5_daily <- function(hourly) {
  if (!is.data.frame(hourly) || nrow(hourly) == 0) {
    return(data.frame(tanggal = as.Date(character()), suhu_puncak = numeric(),
                      kelembaban = numeric(), hujan = numeric()))
  }
  if (!"tanggal" %in% names(hourly)) hourly$tanggal <- era5_local_tanggal(hourly$valid_time)
  dates <- sort(unique(hourly$tanggal[!is.na(hourly$tanggal)]))
  if (length(dates) == 0) {
    return(data.frame(tanggal = as.Date(character()), suhu_puncak = numeric(),
                      kelembaban = numeric(), hujan = numeric()))
  }
  suhu_puncak <- as.numeric(tapply(hourly$suhu, hourly$tanggal, max, na.rm = TRUE)[as.character(dates)])
  kelembaban  <- as.numeric(tapply(hourly$kelembaban, hourly$tanggal, mean, na.rm = TRUE)[as.character(dates)])
  hujan       <- as.numeric(tapply(hourly$hujan, hourly$tanggal, sum, na.rm = TRUE)[as.character(dates)])
  data.frame(tanggal = dates, suhu_puncak = suhu_puncak, kelembaban = kelembaban, hujan = hujan)
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

#' Validate aligned hourly ERA5 observations.
#'
#' Checks: duplicate timestamps, hourly observation count per local day
#' (suspicious counts below min_hours_per_day or above expected_hours_per_day),
#' RH bounds (0-100), negative precipitation, and NA RH after alignment.
#'
#' @param hourly data.frame from read_era5_hourly_from_nc.
#' @param config list from era5_config().
#' @return list of findings.
validate_era5_hourly <- function(hourly, config = era5_config()) {
  findings <- list()
  if (!is.data.frame(hourly) || nrow(hourly) == 0) {
    return(list(ok = FALSE, n = 0L, message = "hourly frame kosong"))
  }
  vt <- hourly$valid_time
  dup <- duplicated(vt)
  counts <- as.numeric(tapply(hourly$tanggal, hourly$tanggal, length))
  findings$ok <- TRUE
  findings$n <- nrow(hourly)
  findings$duplicate_timestamps <- sum(dup)
  findings$rh_out_of_bounds <- sum(hourly$kelembaban < 0 | hourly$kelembaban > 100, na.rm = TRUE)
  findings$negative_precipitation <- sum(hourly$hujan < 0, na.rm = TRUE)
  findings$na_rh_after_alignment <- sum(is.na(hourly$kelembaban))
  findings$min_obs_per_day <- if (length(counts)) min(counts) else 0L
  findings$max_obs_per_day <- if (length(counts)) max(counts) else 0L
  findings$days_below_min_count <- sum(counts < config$min_hours_per_day, na.rm = TRUE)
  findings$days_above_expected_count <- sum(counts > config$expected_hours_per_day, na.rm = TRUE)
  findings
}

#' Validate aggregated daily climate data.
#'
#' @param daily data.frame from aggregate_era5_daily().
#' @return list of findings.
validate_era5_daily <- function(daily) {
  findings <- list()
  if (!is.data.frame(daily) || nrow(daily) == 0) {
    return(list(ok = FALSE, n_days = 0L, message = "daily frame kosong"))
  }
  vars <- c("suhu_puncak", "kelembaban", "hujan")
  all_na <- apply(is.na(daily[, vars, drop = FALSE]), 1, all)
  findings$ok <- TRUE
  findings$n_days <- nrow(daily)
  findings$all_na_days <- sum(all_na)
  findings$date_range <- range(daily$tanggal)
  findings$mean_suhu <- mean(daily$suhu_puncak, na.rm = TRUE)
  findings$mean_kelembaban <- mean(daily$kelembaban, na.rm = TRUE)
  findings$mean_hujan <- mean(daily$hujan, na.rm = TRUE)
  findings
}

valid_climate_frame <- function(x) {
  is.data.frame(x) &&
    nrow(x) > 0 &&
    all(c("tanggal", "suhu_puncak", "kelembaban", "hujan") %in% names(x)) &&
    any(complete.cases(x[, c("tanggal", "suhu_puncak", "kelembaban", "hujan")]))
}

read_climate_cache <- function(path) {
  if (!file.exists(path)) return(NULL)
  obj <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(obj)) return(NULL)
  data <- if (is.list(obj) && !is.null(obj$data)) obj$data else obj
  if (valid_climate_frame(data)) data else NULL
}

read_bmkg_cache <- function(path) {
  if (!file.exists(path)) return(NULL)
  obj <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(obj)) return(NULL)
  data <- if (is.list(obj) && !is.null(obj$data)) obj$data else obj
  need <- c("tanggal", "suhu_puncak", "kelembaban", "hujan")
  if (!is.data.frame(data) || !all(need %in% names(data))) return(NULL)
  data$tanggal <- as.Date(data$tanggal)
  data$suhu_puncak <- as.numeric(data$suhu_puncak)
  data$kelembaban <- as.numeric(data$kelembaban)
  data$hujan <- as.numeric(data$hujan)
  data <- data[!is.na(data$tanggal) & !is.na(data$suhu_puncak), , drop = FALSE]
  if (nrow(data) == 0) return(NULL)
  data[order(data$tanggal), ]
}

blend_climate_sources <- function(climate_hist, bmkg_forecast, market_dates) {
  market_dates <- sort(unique(as.Date(market_dates)))
  if (length(market_dates) == 0) return(climate_hist)

  hist <- climate_hist
  hist$sumber_iklim <- "ERA5"
  combined <- hist

  if (is.data.frame(bmkg_forecast) && nrow(bmkg_forecast) > 0) {
    bmkg <- bmkg_forecast[, c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE]
    bmkg$sumber_iklim <- "BMKG"
    combined <- rbind(combined, bmkg)
  }

  combined <- combined[order(combined$tanggal), ]
  combined <- combined[!duplicated(combined$tanggal, fromLast = TRUE), ]

  latest_hist <- if (is.data.frame(hist) && nrow(hist) > 0) max(hist$tanggal, na.rm = TRUE) else as.Date(NA)
  first_bmkg <- if (is.data.frame(bmkg_forecast) && nrow(bmkg_forecast) > 0) min(bmkg_forecast$tanggal, na.rm = TRUE) else as.Date(NA)
  bridge_end <- min(
    max(market_dates, na.rm = TRUE),
    if (is.na(first_bmkg)) max(market_dates, na.rm = TRUE) else first_bmkg - 1
  )

  if (!is.na(latest_hist) && latest_hist < bridge_end) {
    bridge_dates <- seq.Date(latest_hist + 1, bridge_end, by = "day")
    if (length(bridge_dates) > 0) {
      last_row <- hist[hist$tanggal == latest_hist, c("suhu_puncak", "kelembaban", "hujan"), drop = FALSE][1, ]
      bridge <- data.frame(
        tanggal = bridge_dates,
        suhu_puncak = rep(last_row$suhu_puncak, length(bridge_dates)),
        kelembaban = rep(last_row$kelembaban, length(bridge_dates)),
        hujan = rep(last_row$hujan, length(bridge_dates)),
        sumber_iklim = "Bridge",
        stringsAsFactors = FALSE
      )
      combined <- rbind(combined, bridge)
      combined <- combined[order(combined$tanggal), ]
      combined <- combined[!duplicated(combined$tanggal, fromLast = TRUE), ]
    }
  }

  needed_dates <- market_dates[market_dates %in% combined$tanggal]
  combined <- combined[combined$tanggal %in% needed_dates, , drop = FALSE]
  combined[order(combined$tanggal), ]
}

read_era5_daily <- function(dir_path, start_date, end_date, cache_path,
                            extent = era5_config()$extent) {
  cache_key <- paste(
    start_date,
    end_date,
    normalizePath(dir_path, winslash = "/", mustWork = FALSE),
    as.vector(extent)
  )
  if (file.exists(cache_path)) {
    cache <- readRDS(cache_path)
    if (identical(cache$key, cache_key) && valid_climate_frame(cache$data)) return(cache$data)
  }

  hourly <- read_era5_hourly_range(dir_path, start_date, end_date, extent)
  if (!is.data.frame(hourly) || nrow(hourly) == 0) {
    climate <- data.frame(
      tanggal = as.Date(character()),
      suhu_puncak = numeric(),
      kelembaban = numeric(),
      hujan = numeric()
    )
  } else {
    climate <- aggregate_era5_daily(hourly)
    climate <- climate[climate$tanggal >= start_date & climate$tanggal <= end_date, , drop = FALSE]
  }

  if (valid_climate_frame(climate)) {
    dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
    saveRDS(list(key = cache_key, data = climate), cache_path)
  }
  climate
}
