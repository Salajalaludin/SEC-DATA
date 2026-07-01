suppressPackageStartupMessages({
  library(terra)
})

app_file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- if (file.exists("cilegon_komoditas_shiny/update_era5_daily.R")) "cilegon_komoditas_shiny/update_era5_daily.R" else "update_era5_daily.R"
app_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

bandung_cilegon_extent <- terra::ext(105.85, 107.85, -7.30, -5.80)

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

parse_valid_time <- function(layer_names) {
  seconds <- as.numeric(sub(".*valid_time=([0-9]+).*", "\\1", layer_names))
  as.POSIXct(seconds, origin = "1970-01-01", tz = "UTC")
}

relative_humidity <- function(temp_c, dewpoint_c) {
  actual <- exp((17.625 * dewpoint_c) / (243.04 + dewpoint_c))
  saturation <- exp((17.625 * temp_c) / (243.04 + temp_c))
  pmin(100, pmax(0, 100 * actual / saturation))
}

read_one_era5_file <- function(path) {
  subdatasets <- tryCatch(names(terra::sds(path)), error = function(e) character())
  has_var <- function(var) var %in% subdatasets

  hourly_parts <- list()
  if (has_var("t2m")) {
    t2m <- terra::crop(rast(path, subds = "t2m"), bandung_cilegon_extent)
    hourly_parts$t2m <- data.frame(
      tanggal = as.Date(parse_valid_time(names(t2m)), tz = "Asia/Bangkok"),
      suhu = terra::global(t2m, "mean", na.rm = TRUE)[, 1] - 273.15
    )
  }
  if (has_var("d2m")) {
    d2m <- terra::crop(rast(path, subds = "d2m"), bandung_cilegon_extent)
    hourly_parts$d2m <- data.frame(
      tanggal = as.Date(parse_valid_time(names(d2m)), tz = "Asia/Bangkok"),
      dewpoint = terra::global(d2m, "mean", na.rm = TRUE)[, 1] - 273.15
    )
  }
  if (has_var("tp")) {
    tp <- terra::crop(rast(path, subds = "tp"), bandung_cilegon_extent)
    hourly_parts$tp <- data.frame(
      tanggal = as.Date(parse_valid_time(names(tp)), tz = "Asia/Bangkok"),
      hujan = pmax(0, terra::global(tp, "mean", na.rm = TRUE)[, 1] * 1000)
    )
  }
  if (length(hourly_parts) == 0) stop("Tidak ada variabel ERA5 yang dikenali di ", path, call. = FALSE)

  hourly <- Reduce(function(x, y) merge(x, y, by = "tanggal", all = TRUE), hourly_parts)
  daily_parts <- list()
  if ("suhu" %in% names(hourly)) {
    temp_daily <- aggregate(suhu ~ tanggal, hourly, max, na.rm = TRUE)
    names(temp_daily)[2] <- "suhu_puncak"
    daily_parts$temp <- temp_daily
  }
  if (all(c("suhu", "dewpoint") %in% names(hourly))) {
    hourly$kelembaban <- relative_humidity(hourly$suhu, hourly$dewpoint)
    daily_parts$hum <- aggregate(kelembaban ~ tanggal, hourly, mean, na.rm = TRUE)
  }
  if ("hujan" %in% names(hourly)) {
    daily_parts$rain <- aggregate(hujan ~ tanggal, hourly, sum, na.rm = TRUE)
  }

  Reduce(function(x, y) merge(x, y, by = "tanggal", all = TRUE), daily_parts)
}

read_era5_daily <- function(dir_path, start_date, end_date) {
  files <- list.files(dir_path, pattern = "\\.nc$", recursive = TRUE, full.names = TRUE)
  ym_text <- sub(".*_(20[0-9]{2})_([0-9]{2})(_[0-9]{2})?\\.nc$", "\\1-\\2-01", basename(files))
  file_month <- as.Date(ym_text)
  start_month <- as.Date(format(start_date, "%Y-%m-01"))
  end_month <- as.Date(format(end_date, "%Y-%m-01"))
  files <- sort(files[!is.na(file_month) & file_month >= start_month & file_month <= end_month])

  chunks <- list()
  for (f in files) {
    df <- tryCatch(read_one_era5_file(f), error = function(e) NULL)
    if (is.data.frame(df) && nrow(df) > 0) chunks[[length(chunks) + 1]] <- df
  }
  if (length(chunks) == 0) return(data.frame(tanggal = as.Date(character()), suhu_puncak = numeric(), kelembaban = numeric(), hujan = numeric()))

  all_names <- unique(unlist(lapply(chunks, names)))
  chunks <- lapply(chunks, function(x) {
    missing <- setdiff(all_names, names(x))
    for (nm in missing) x[[nm]] <- NA_real_
    x[, all_names, drop = FALSE]
  })
  climate <- do.call(rbind, chunks)
  for (nm in c("suhu_puncak", "kelembaban", "hujan")) {
    if (!nm %in% names(climate)) climate[[nm]] <- NA_real_
  }
  dates <- sort(unique(climate$tanggal))
  climate <- data.frame(
    tanggal = dates,
    suhu_puncak = as.numeric(tapply(climate$suhu_puncak, climate$tanggal, mean, na.rm = TRUE)[as.character(dates)]),
    kelembaban = as.numeric(tapply(climate$kelembaban, climate$tanggal, mean, na.rm = TRUE)[as.character(dates)]),
    hujan = as.numeric(tapply(climate$hujan, climate$tanggal, mean, na.rm = TRUE)[as.character(dates)])
  )
  climate[is.nan(as.matrix(climate[, c("suhu_puncak", "kelembaban", "hujan")])), c("suhu_puncak", "kelembaban", "hujan")] <- NA_real_
  climate[climate$tanggal >= start_date & climate$tanggal <= end_date, ]
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

