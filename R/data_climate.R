# data_climate.R — ERA5 climate transformation pipeline (Methodology V2, Sprint 1)
#
# Cache-safe climate transformations shared by the Shiny runtime and the local
# ERA5 updater. NetCDF I/O requiring terra lives in R/era5_netcdf.R so the
# hosted cache-only bundle does not need the native GDAL/terra toolchain.
#
# This module is shared by:
#   - cilegon_komoditas_shiny/update_era5_daily.R  (cache regeneration)
#   - cilegon_komoditas_shiny/app.R                (cache/runtime reading)
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
#'   - extent:    numeric xmin/xmax/ymin/ymax extent for Cilegon Local Climate.
#'   - tz_utc:    timezone of ERA5 valid_time timestamps (UTC).
#'   - tz_local:  operational local timezone (Asia/Jakarta).
#'   - expected_hours_per_day: nominal number of hourly observations per day.
#'   - min_hours_per_day: below this count a local day is flagged as suspicious.
#'   - spatial_label: human-readable spatial scope.
era5_config <- function() {
  list(
    extent = c(xmin = 105.95, xmax = 106.15, ymin = -6.15, ymax = -5.95),
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
# Timestamp alignment
# ---------------------------------------------------------------------------

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
