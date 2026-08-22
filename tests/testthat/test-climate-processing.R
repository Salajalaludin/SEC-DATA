# Tests for R/data_climate.R — ERA5 climate transformation pipeline (Sprint 1)

# Locate the module by walking up from the working directory.
find_repo_root <- function() {
  d <- normalizePath(getwd(), winslash = "/")
  repeat {
    if (file.exists(file.path(d, "R", "data_climate.R"))) return(d)
    nd <- dirname(d)
    if (identical(nd, d)) stop("R/data_climate.R tidak ditemukan dari ", getwd())
    d <- nd
  }
}
source(file.path(find_repo_root(), "R", "data_climate.R"), local = FALSE)
source(file.path(find_repo_root(), "R", "era5_netcdf.R"), local = FALSE)

# ---------------------------------------------------------------------------
# Timestamp parsing
# ---------------------------------------------------------------------------

test_that("parse_era5_valid_time parses epoch seconds into UTC POSIXct", {
  vt <- parse_era5_valid_time(c("t2m_valid_time=1577836800", "d2m_valid_time=1577840400"))
  expect_s3_class(vt, "POSIXct")
  expect_equal(vt[1], as.POSIXct("2020-01-01 00:00:00", tz = "UTC"))
  expect_equal(vt[2], as.POSIXct("2020-01-01 01:00:00", tz = "UTC"))
  expect_equal(attr(vt, "tzone"), "UTC")
})

test_that("parse_era5_valid_time returns NA without coercion warnings for unsupported names", {
  expect_no_warning(vt <- parse_era5_valid_time(c("t2m_1", "d2m_2")))
  expect_true(all(is.na(vt)))
})

# ---------------------------------------------------------------------------
# Timezone conversion
# ---------------------------------------------------------------------------

test_that("era5_local_tanggal converts UTC to Asia/Jakarta local date", {
  # 17:00 UTC on 2020-01-01 == 00:00 Asia/Jakarta on 2020-01-02 (UTC+7, no DST)
  vt <- as.POSIXct("2020-01-01 17:00:00", tz = "UTC")
  expect_equal(era5_local_tanggal(vt), as.Date("2020-01-02"))
  # 16:59 UTC still falls on the same local day
  vt2 <- as.POSIXct("2020-01-01 16:59:00", tz = "UTC")
  expect_equal(era5_local_tanggal(vt2), as.Date("2020-01-01"))
  # Morning UTC stays on the same local date
  vt3 <- as.POSIXct("2020-01-01 00:00:00", tz = "UTC")
  expect_equal(era5_local_tanggal(vt3), as.Date("2020-01-01"))
})

# ---------------------------------------------------------------------------
# Relative humidity
# ---------------------------------------------------------------------------

test_that("relative_humidity respects 0-100 bounds and handles NA", {
  rh <- relative_humidity(c(25, 30, NA, 10), c(20, 29, 20, NA))
  expect_true(all(rh >= 0, na.rm = TRUE))
  expect_true(all(rh <= 100, na.rm = TRUE))
  expect_true(is.na(rh[3]))
  expect_true(is.na(rh[4]))
})

test_that("relative_humidity rises when dewpoint approaches temperature", {
  rh1 <- relative_humidity(25, 20)
  rh2 <- relative_humidity(25, 24)
  expect_true(rh2 > rh1)
  expect_true(rh1 > 0 && rh1 < 100)
})

test_that("relative_humidity is 100 when dewpoint equals temperature", {
  expect_equal(relative_humidity(25, 25), 100)
})

# ---------------------------------------------------------------------------
# Exact-time alignment (no calendar-date joins)
# ---------------------------------------------------------------------------

test_that("align_era5_variables joins by exact valid_time, not calendar date", {
  t2m <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC"),
    value = c(25, 26)
  )
  # dewpoint delivered in reverse order on purpose
  d2m <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 01:00:00", "2020-01-01 00:00:00"), tz = "UTC"),
    value = c(24, 23)
  )
  # precipitation missing the 01:00 timestamp
  tp <- data.frame(
    valid_time = as.POSIXct("2020-01-01 00:00:00", tz = "UTC"),
    value = 0.5
  )
  aligned <- align_era5_variables(list(suhu = t2m, dewpoint = d2m, hujan = tp))
  expect_equal(nrow(aligned), 2)
  expect_equal(aligned$valid_time, as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC"))
  # exact-time pairing: 26 C must pair with 24 C dewpoint, not 23 C
  expect_equal(aligned$suhu[2], 26)
  expect_equal(aligned$dewpoint[2], 24)
  expect_equal(aligned$suhu[1], 25)
  expect_equal(aligned$dewpoint[1], 23)
  # missing precipitation at 01:00 is NA
  expect_true(is.na(aligned$hujan[2]))
  expect_equal(aligned$hujan[1], 0.5)
})

test_that("align_era5_variables preserves one row per timestamp (no many-to-many)", {
  t2m <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC"),
    value = c(25, 26)
  )
  d2m <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC"),
    value = c(23, 24)
  )
  tp <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC"),
    value = c(0.5, 0.1)
  )
  aligned <- align_era5_variables(list(suhu = t2m, dewpoint = d2m, hujan = tp))
  expect_equal(nrow(aligned), 2)
  expect_false(any(duplicated(aligned$valid_time)))
})

# ---------------------------------------------------------------------------
# Daily aggregation after alignment
# ---------------------------------------------------------------------------

test_that("aggregate_era5_daily computes max/mean/sum per local day", {
  hourly <- data.frame(
    valid_time = as.POSIXct(c(
      "2020-01-01 00:00:00", "2020-01-01 01:00:00",
      "2020-01-02 00:00:00", "2020-01-02 01:00:00"
    ), tz = "UTC"),
    tanggal = as.Date(c("2020-01-01", "2020-01-01", "2020-01-02", "2020-01-02")),
    suhu = c(25, 30, 28, 20),
    dewpoint = c(20, 21, 22, 18),
    kelembaban = c(60, 70, 80, 50),
    hujan = c(1, 2, 3, 0.5),
    stringsAsFactors = FALSE
  )
  daily <- aggregate_era5_daily(hourly)
  expect_equal(daily$tanggal, as.Date(c("2020-01-01", "2020-01-02")))
  expect_equal(daily$suhu_puncak, c(30, 28))
  expect_equal(daily$kelembaban, c(65, 65))
  expect_equal(daily$hujan, c(3, 3.5))
})

test_that("aggregate_era5_daily uses local day boundaries", {
  # 17:00 UTC 2020-01-01 == 00:00 Jakarta 2020-01-02; temperature belongs to Jan 2
  hourly <- data.frame(
    valid_time = as.POSIXct(c("2020-01-01 16:00:00", "2020-01-01 17:00:00"), tz = "UTC"),
    suhu = c(25, 40),
    dewpoint = c(20, 20),
    kelembaban = c(60, 60),
    hujan = c(1, 2)
  )
  daily <- aggregate_era5_daily(hourly)
  expect_equal(daily$tanggal, as.Date(c("2020-01-01", "2020-01-02")))
  expect_equal(daily$suhu_puncak, c(25, 40))
})

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

test_that("validate_era5_hourly flags duplicate timestamps", {
  vt <- as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 00:00:00", "2020-01-01 01:00:00"), tz = "UTC")
  hr <- data.frame(
    valid_time = vt,
    tanggal = era5_local_tanggal(vt),
    kelembaban = c(50, 50, 60),
    hujan = c(1, 1, 0)
  )
  v <- validate_era5_hourly(hr)
  expect_equal(v$duplicate_timestamps, 1)
})

test_that("validate_era5_hourly flags RH out of bounds and negative precipitation", {
  vt <- as.POSIXct(c("2020-01-01 00:00:00", "2020-01-01 01:00:00", "2020-01-01 02:00:00"), tz = "UTC")
  hr <- data.frame(
    valid_time = vt,
    tanggal = era5_local_tanggal(vt),
    kelembaban = c(-5, 105, 60),
    hujan = c(1, -1, 0.5)
  )
  v <- validate_era5_hourly(hr)
  expect_equal(v$rh_out_of_bounds, 2)
  expect_equal(v$negative_precipitation, 1)
})

test_that("validate_era5_hourly flags suspicious per-day observation counts", {
  # one complete day (24h), one incomplete day (2h); tanggal supplied explicitly
  hr <- data.frame(
    valid_time = as.POSIXct("2020-01-01 00:00:00", tz = "UTC") + 0:25 * 3600,
    tanggal = as.Date(c(rep("2020-01-01", 24), rep("2020-01-02", 2))),
    kelembaban = rep(60, 26),
    hujan = rep(0.1, 26)
  )
  v <- validate_era5_hourly(hr)
  expect_equal(v$max_obs_per_day, 24)
  expect_equal(v$min_obs_per_day, 2)
  expect_equal(v$days_below_min_count, 1)
  expect_equal(v$days_above_expected_count, 0)
})

test_that("validate_era5_daily flags all-NA days", {
  d <- data.frame(
    tanggal = as.Date(c("2020-01-01", "2020-01-02")),
    suhu_puncak = c(30, NA_real_),
    kelembaban = c(65, NA_real_),
    hujan = c(3, NA_real_)
  )
  v <- validate_era5_daily(d)
  expect_equal(v$all_na_days, 1)
  expect_equal(v$n_days, 2)
})

# ---------------------------------------------------------------------------
# RH is computed from timestamp-matched temperature/dewpoint (integration)
# ---------------------------------------------------------------------------

test_that("read_era5_hourly_from_nc returns aligned, in-bounds RH (real file when present)", {
  root <- find_repo_root()
  local_files <- list.files(file.path(root, "data_era5_tomat_cilegon_lampung_jabar_nc"),
                            pattern = "2020.*01\\.nc$", full.names = TRUE, recursive = TRUE)
  if (length(local_files) == 0) skip("ERA5 NetCDF fixture tidak tersedia")
  hr <- read_era5_hourly_from_nc(local_files[1], era5_config()$extent)
  expect_true(nrow(hr) > 0)
  expect_true(all(names(hr) %in% c("valid_time", "tanggal", "suhu", "dewpoint", "kelembaban", "hujan")))
  expect_true(all(hr$kelembaban >= 0 & hr$kelembaban <= 100, na.rm = TRUE))
  expect_true(all(hr$hujan >= 0, na.rm = TRUE))
  expect_false(any(duplicated(hr$valid_time)))
  # RH computed from same-timestamp pair; verify non-trivial variation across a day
  expect_true(length(unique(as.Date(hr$tanggal))) >= 2)
})
