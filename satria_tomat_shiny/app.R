suppressPackageStartupMessages({
  library(shiny)
  library(ggplot2)
  library(readxl)
  library(terra)
  library(forecast)
  library(xgboost)
})

set.seed(2026)

app_file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- if (file.exists("satria_tomat_shiny/app.R")) "satria_tomat_shiny/app.R" else "app.R"
app_start_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_start_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

bandung_cilegon_extent <- terra::ext(105.85, 107.85, -7.30, -5.80)
validation_days <- 3
## Default auto-refresh interval: once per day (24 hours = 86,400,000 ms).
## Can be overridden via environment var `REFRESH_INTERVAL_MS` (milliseconds).
refresh_interval_ms <- as.integer(Sys.getenv("REFRESH_INTERVAL_MS", "86400000"))

rupiah <- function(x) {
  paste0("Rp", format(round(x, 0), big.mark = ".", decimal.mark = ","))
}

format_tanggal <- function(x) {
  bulan <- c("Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des")
  x <- as.Date(x, origin = "1970-01-01")
  paste(format(x, "%d"), bulan[as.integer(format(x, "%m"))], format(x, "%Y"))
}

lag_vec <- function(x, k = 1) {
  c(rep(NA, k), head(x, -k))
}

roll_stat <- function(x, k, fun) {
  stats::filter(x, rep(1 / k, k), sides = 1) |>
    as.numeric()
}

roll_sd <- function(x, k) {
  vapply(seq_along(x), function(i) {
    if (i < k) return(NA_real_)
    stats::sd(x[(i - k + 1):i], na.rm = TRUE)
  }, numeric(1))
}

roll_apply <- function(x, k, fun) {
  vapply(seq_along(x), function(i) {
    if (i < k) return(NA_real_)
    fun(x[(i - k + 1):i], na.rm = TRUE)
  }, numeric(1))
}

model_metrics <- function(actual, predicted) {
  error <- actual - predicted
  data.frame(
    MAE = mean(abs(error), na.rm = TRUE),
    RMSE = sqrt(mean(error^2, na.rm = TRUE)),
    MAPE = mean(abs(error) / pmax(abs(actual), 1), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

theme_dark_cilegon <- function(base_size = 12) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.background = element_rect(fill = "#20211f", color = NA),
      panel.background = element_rect(fill = "#20211f", color = NA),
      panel.grid.major = element_line(color = "#363833", linewidth = 0.35),
      panel.grid.minor = element_blank(),
      axis.text = element_text(color = "#b9b9b0"),
      axis.title = element_text(color = "#deded6"),
      plot.title = element_text(color = "#f5f2e8", face = "bold"),
      plot.subtitle = element_text(color = "#b9b9b0"),
      legend.position = "bottom",
      legend.text = element_text(color = "#deded6"),
      legend.title = element_blank()
    )
}

first_existing <- function(paths) {
  hit <- paths[file.exists(paths)]
  if (length(hit) == 0) {
    stop("File/folder tidak ditemukan: ", paste(paths, collapse = " atau "), call. = FALSE)
  }
  hit[[1]]
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

read_market_cache <- function(path) {
  if (!file.exists(path)) return(NULL)
  obj <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(obj)) return(NULL)
  data <- if (is.list(obj) && !is.null(obj$data)) obj$data else obj
  need <- c("tanggal", "pasar", "komoditas", "harga")
  if (!is.data.frame(data) || !all(need %in% names(data))) return(NULL)
  data$tanggal <- as.Date(data$tanggal)
  data$pasar <- as.character(data$pasar)
  data$komoditas <- as.character(data$komoditas)
  data$harga <- as.numeric(data$harga)
  data <- data[!is.na(data$tanggal) & !is.na(data$harga), need, drop = FALSE]
  if (nrow(data) == 0) return(NULL)
  data[order(data$tanggal, data$pasar, data$komoditas), ]
}

merge_market_sources <- function(base_market, fresh_market, commodity) {
  if (is.null(base_market) || !is.data.frame(base_market) || nrow(base_market) == 0) {
    out <- fresh_market
  } else if (is.null(fresh_market) || !is.data.frame(fresh_market) || nrow(fresh_market) == 0) {
    out <- base_market
  } else {
    base_market <- base_market[, c("tanggal", "pasar", "komoditas", "harga"), drop = FALSE]
    fresh_market <- fresh_market[, c("tanggal", "pasar", "komoditas", "harga"), drop = FALSE]
    out <- rbind(base_market, fresh_market)
    out <- out[!duplicated(out[, c("tanggal", "pasar", "komoditas")], fromLast = TRUE), ]
  }
  if (!is.null(out) && is.data.frame(out) && nrow(out) > 0) {
    out$komoditas <- commodity
    out <- out[order(out$tanggal, out$pasar), ]
  }
  out
}

commodity_label_from_file <- function(path) {
  name <- tools::file_path_sans_ext(basename(path))
  name <- sub("^Data komoditas\\s+", "", name, ignore.case = TRUE)
  name <- gsub("\\s+", " ", trimws(name))
  words <- strsplit(tolower(name), " ", fixed = TRUE)[[1]]
  paste(tools::toTitleCase(words), collapse = " ")
}

discover_commodity_files <- function(app_dir) {
  files <- list.files(app_dir, pattern = "^Data komoditas .*\\.xlsx$", full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) {
    fallback <- c(file.path(app_dir, "Data Pasar Kota Cilegon.xlsx"), file.path(dirname(app_dir), "Data Pasar Kota Cilegon.xlsx"))
    files <- fallback[file.exists(fallback)]
  }
  labels <- vapply(files, commodity_label_from_file, character(1))
  files <- files[order(labels)]
  labels <- labels[order(labels)]
  stats::setNames(normalizePath(files, winslash = "/", mustWork = FALSE), labels)
}

find_col <- function(dat, candidates) {
  nm <- names(dat)
  key <- tolower(gsub("[^a-z0-9]+", "_", nm))
  hit <- match(candidates, key)
  hit <- hit[!is.na(hit)]
  if (length(hit) == 0) return(NULL)
  nm[[hit[[1]]]]
}

read_url_csv <- function(url) {
  utils::read.csv(url, stringsAsFactors = FALSE, check.names = FALSE)
}

read_market_csv <- function(url) {
  dat <- read_url_csv(url)
  tanggal_col <- find_col(dat, c("tanggal", "date", "tgl"))
  pasar_col <- find_col(dat, c("pasar", "market", "nama_pasar"))
  harga_col <- find_col(dat, c("harga", "price", "harga_tomat"))
  commodity_col <- find_col(dat, c("komoditas", "commodity"))
  if (is.null(tanggal_col) || is.null(harga_col)) {
    stop("CSV harga realtime harus punya kolom tanggal/date dan harga/price.", call. = FALSE)
  }
  market <- data.frame(
    tanggal = as.Date(dat[[tanggal_col]]),
    pasar = if (is.null(pasar_col)) "Harga rata-rata" else as.character(dat[[pasar_col]]),
    komoditas = if (is.null(commodity_col)) NA_character_ else as.character(dat[[commodity_col]]),
    harga = as.numeric(dat[[harga_col]]),
    stringsAsFactors = FALSE
  )
  market <- market[!is.na(market$tanggal) & !is.na(market$harga), ]
  if (!"Harga rata-rata" %in% market$pasar) {
    avg <- aggregate(harga ~ tanggal, market, mean, na.rm = TRUE)
    avg$pasar <- "Harga rata-rata"
    avg$komoditas <- unique(market$komoditas[!is.na(market$komoditas) & nzchar(market$komoditas)])[1]
    market <- rbind(market[, c("tanggal", "pasar", "komoditas", "harga")], avg[, c("tanggal", "pasar", "komoditas", "harga")])
  }
  market[order(market$tanggal, market$pasar), ]
}

read_climate_csv <- function(url) {
  dat <- read_url_csv(url)
  tanggal_col <- find_col(dat, c("tanggal", "date", "tgl"))
  suhu_col <- find_col(dat, c("suhu_puncak", "suhu", "temp", "temperature", "t2m"))
  kelembaban_col <- find_col(dat, c("kelembaban", "humidity", "relative_humidity", "rh"))
  hujan_col <- find_col(dat, c("hujan", "rain", "rainfall", "precipitation", "tp"))
  if (is.null(tanggal_col) || is.null(suhu_col)) {
    stop("CSV iklim realtime harus punya kolom tanggal/date dan suhu_puncak/suhu.", call. = FALSE)
  }
  climate <- data.frame(
    tanggal = as.Date(dat[[tanggal_col]]),
    suhu_puncak = as.numeric(dat[[suhu_col]]),
    kelembaban = if (is.null(kelembaban_col)) NA_real_ else as.numeric(dat[[kelembaban_col]]),
    hujan = if (is.null(hujan_col)) NA_real_ else as.numeric(dat[[hujan_col]]),
    stringsAsFactors = FALSE
  )
  climate <- climate[!is.na(climate$tanggal) & !is.na(climate$suhu_puncak), ]
  aggregate(cbind(suhu_puncak, kelembaban, hujan) ~ tanggal, climate, mean, na.rm = TRUE)
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
  hit[[1]]
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

normalize_market_name <- function(sheet) {
  key <- tolower(gsub("\\s+", " ", trimws(sheet)))
  if (grepl("blok", key)) return("Pasar Blok F")
  if (grepl("merak", key)) return("Pasar Baru Merak")
  if (grepl("cilegon", key)) return("Pasar Baru Cilegon")
  sheet
}

read_market_data <- function(path, commodity_label = NULL) {
  sheet_names <- excel_sheets(path)

  market <- do.call(rbind, lapply(sheet_names, function(sheet) {
    dat <- read_excel(path, sheet = sheet)
    commodity_col <- find_col(dat, c("komoditas", "commodity"))
    komoditas <- if (!is.null(commodity_col)) as.character(dat[[commodity_col]]) else commodity_label
    if (is.null(komoditas) || all(is.na(komoditas) | !nzchar(komoditas))) komoditas <- commodity_label_from_file(path)
    data.frame(
      tanggal = as.Date(dat[["Tanggal"]]),
      pasar = normalize_market_name(sheet),
      komoditas = komoditas,
      harga = as.numeric(dat[["Harga"]]),
      stringsAsFactors = FALSE
    )
  }))
  market <- market[!is.na(market$tanggal) & !is.na(market$harga), ]
  market$komoditas[is.na(market$komoditas) | !nzchar(market$komoditas)] <- commodity_label_from_file(path)

  avg <- aggregate(harga ~ tanggal, market, mean, na.rm = TRUE)
  avg$pasar <- "Harga rata-rata"
  avg$komoditas <- unique(market$komoditas)[[1]]

  rbind(market[, c("tanggal", "pasar", "komoditas", "harga")], avg[, c("tanggal", "pasar", "komoditas", "harga")])
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

read_era5_daily <- function(dir_path, start_date, end_date, cache_path) {
  cache_key <- paste(start_date, end_date, normalizePath(dir_path, winslash = "/", mustWork = FALSE), as.vector(bandung_cilegon_extent))
  if (file.exists(cache_path)) {
    cache <- readRDS(cache_path)
    if (identical(cache$key, cache_key) && valid_climate_frame(cache$data)) return(cache$data)
  }

  files <- list.files(dir_path, pattern = "\\.nc$", recursive = TRUE, full.names = TRUE)
  ym_text <- sub(".*_(20[0-9]{2})_([0-9]{2})(_[0-9]{2})?\\.nc$", "\\1-\\2-01", basename(files))
  file_month <- as.Date(ym_text)
  start_month <- as.Date(format(start_date, "%Y-%m-01"))
  end_month <- as.Date(format(end_date, "%Y-%m-01"))
  files <- files[!is.na(file_month) & file_month >= start_month & file_month <= end_month]
  files <- sort(files)

  # Read each file but skip unreadable/corrupt files instead of failing the whole process
  chunks <- list()
  for (f in files) {
    ok <- tryCatch({
      df <- read_one_era5_file(f)
      if (is.data.frame(df) && nrow(df) > 0) chunks[[length(chunks) + 1]] <- df
      TRUE
    }, error = function(e) {
      warning("Gagal membaca file ERA5: ", f, " -> ", conditionMessage(e))
      FALSE
    })
    invisible(ok)
  }

  if (length(chunks) == 0) {
    # Return empty climate frame when no valid files
    climate <- data.frame(tanggal = as.Date(character()), suhu_puncak = numeric(), kelembaban = numeric(), hujan = numeric())
  } else {
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
    climate <- climate[climate$tanggal >= start_date & climate$tanggal <= end_date, ]
  }

  if (valid_climate_frame(climate)) {
    dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
    saveRDS(list(key = cache_key, data = climate), cache_path)
  }
  climate
}

load_project_data <- function(commodity = NULL) {
  market_url <- Sys.getenv("REALTIME_MARKET_URL", "")
  climate_url <- Sys.getenv("REALTIME_CLIMATE_URL", "")
  app_dir <- app_start_dir
  commodity_files <- discover_commodity_files(app_dir)
  if (is.null(commodity) || !commodity %in% names(commodity_files)) {
    tomato_idx <- grep("^Tomat$", names(commodity_files), ignore.case = TRUE)
    commodity <- if (length(tomato_idx) > 0) names(commodity_files)[tomato_idx[[1]]] else names(commodity_files)[[1]]
  }
  market_path <- if (nzchar(market_url)) NULL else commodity_files[[commodity]]
  market_cache_path <- file.path(app_dir, "cache", "sagon_daily_long.rds")
  cache_path <- file.path(app_dir, "cache", "era5_daily_bandung_cilegon.rds")
  fallback_cache_path <- file.path(app_dir, "cache", "era5_daily.rds")
  bmkg_cache_path <- file.path(app_dir, "cache", "bmkg_forecast_daily.rds")
  cds_nc_dir <- file.path(app_dir, "cache", "era5_cds_nc")
  era5_dir_candidates <- c(
    cds_nc_dir,
    file.path(dirname(app_dir), "data_era5_tomat_cilegon_lampung_jabar_nc"),
    "data_era5_tomat_cilegon_lampung_jabar_nc",
    "../data_era5_tomat_cilegon_lampung_jabar_nc"
  )
  cdsapirc <- find_cdsapirc(app_dir)

  market_base <- NULL
  if (!is.null(market_path) && file.exists(market_path)) {
    market_base <- read_market_data(market_path, commodity)
  }
  market_live <- NULL
  if (nzchar(market_url)) {
    market_live <- read_market_csv(market_url)
  }
  if (is.null(market_live)) {
    market_live <- read_market_cache(market_cache_path)
  }
  if ("komoditas" %in% names(market_live)) {
    keep <- tolower(trimws(market_live$komoditas)) == tolower(trimws(commodity)) | is.na(market_live$komoditas) | !nzchar(trimws(market_live$komoditas))
    market_live <- market_live[keep, , drop = FALSE]
  }
  market <- merge_market_sources(market_base, market_live, commodity)
  if (is.null(market) || !is.data.frame(market) || nrow(market) == 0) stop("Data harga komoditas tidak tersedia.", call. = FALSE)
  if (!"Harga rata-rata" %in% market$pasar) {
    avg <- aggregate(harga ~ tanggal, market, mean, na.rm = TRUE)
    avg$pasar <- "Harga rata-rata"
    avg$komoditas <- commodity
    market <- rbind(market[, c("tanggal", "pasar", "komoditas", "harga")], avg[, c("tanggal", "pasar", "komoditas", "harga")])
  }
  market$komoditas <- commodity
  market <- market[order(market$tanggal, market$pasar), ]
  start_date <- min(market$tanggal, na.rm = TRUE)
  end_date <- max(market$tanggal, na.rm = TRUE)

  # If cache already exists and valid, we'll use it
  climate <- NULL
  if (nzchar(climate_url)) {
    climate <- read_climate_csv(climate_url)
  }
  if (!valid_climate_frame(climate)) {
    climate <- read_climate_cache(cache_path)
  }
  if (!valid_climate_frame(climate)) {
    climate <- read_climate_cache(fallback_cache_path)
  }

  # Try downloading RDS from Google Drive if environment variable is provided
  gdrive_id <- Sys.getenv("GDRIVE_RDS_ID", "")
  if (!valid_climate_frame(climate)) {
    if (nzchar(gdrive_id) && !file.exists(cache_path)) {
      gd_url <- sprintf("https://drive.google.com/uc?export=download&id=%s", gdrive_id)
      dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
      tryCatch({
        utils::download.file(gd_url, cache_path, mode = "wb", quiet = TRUE)
        # validate
        cache_obj <- tryCatch(readRDS(cache_path), error = function(e) NULL)
        if (!is.null(cache_obj)) {
          if (is.list(cache_obj) && !is.null(cache_obj$data)) {
            if (valid_climate_frame(cache_obj$data)) climate <- cache_obj$data
          } else if (is.data.frame(cache_obj)) {
            if (valid_climate_frame(cache_obj)) climate <- cache_obj
          }
        }
      }, error = function(e) {
        warning("Gagal mengunduh atau membaca RDS dari Google Drive: ", conditionMessage(e))
        if (file.exists(cache_path)) try(unlink(cache_path), silent = TRUE)
      })
    }
  }

  # If still missing, try to read ERA5 files from local directories (but don't stop app if missing)
  if (!valid_climate_frame(climate)) {
    era5_dir <- NULL
    for (p in era5_dir_candidates) {
      if (dir.exists(p) || file.exists(p)) { era5_dir <- p; break }
    }
    if (!is.null(era5_dir)) {
      climate <- tryCatch(read_era5_daily(era5_dir, start_date, end_date, cache_path), error = function(e) {
        warning("Gagal baca ERA5 lokal: ", conditionMessage(e)); NULL
      })
    }
  }

  # Final fallback: create NA climate frame so UI loads
  if (!valid_climate_frame(climate)) {
    dates <- seq.Date(start_date, end_date, by = "day")
    climate <- data.frame(tanggal = dates, suhu_puncak = NA_real_, kelembaban = NA_real_, hujan = NA_real_)
  }
  bmkg_forecast <- read_bmkg_cache(bmkg_cache_path)
  climate_blended <- blend_climate_sources(climate, bmkg_forecast, market$tanggal)

  merged <- merge(market, climate_blended, by = "tanggal", all.x = TRUE)
  merged <- merged[order(merged$tanggal, merged$pasar), ]

  list(
    market = market,
    climate = climate,
    climate_blended = climate_blended,
    bmkg_forecast = bmkg_forecast,
    merged = merged,
    commodity = commodity,
    commodity_choices = names(commodity_files),
    source_label = if (nzchar(market_url) || nzchar(climate_url)) {
      "Realtime CSV/API"
    } else if (file.exists(market_cache_path) && file.exists(bmkg_cache_path)) {
      "Cache harga SAGON + ERA5 historis + BMKG forecast"
    } else if (file.exists(market_cache_path)) {
      "Cache harga SAGON + cache ERA5 harian"
    } else if (!is.null(cdsapirc)) {
      "Harga lokal + cache ERA5 harian"
    } else {
      "File lokal/cache"
    }
  )
}

prepare_avg_frame <- function(df) {
  avg <- df[df$pasar == "Harga rata-rata", ]
  avg <- avg[order(avg$tanggal), ]
  avg <- avg[complete.cases(avg[, c("tanggal", "harga", "suhu_puncak", "kelembaban", "hujan")]), ]
  market_only <- df[df$pasar != "Harga rata-rata", ]
  margin <- aggregate(harga ~ tanggal, market_only, function(x) diff(range(x, na.rm = TRUE)))
  names(margin)[2] <- "margin_hl"
  avg <- merge(avg, margin, by = "tanggal", all.x = TRUE)
  avg$margin_hl[is.na(avg$margin_hl)] <- 0
  avg <- avg[order(avg$tanggal), ]
  avg$harga_kemarin <- lag_vec(avg$harga, 1)
  avg$lag2 <- lag_vec(avg$harga, 2)
  avg$lag3 <- lag_vec(avg$harga, 3)
  avg$lag7 <- lag_vec(avg$harga, 7)
  avg$ma7 <- roll_stat(avg$harga, 7, mean)
  avg$ma7[is.na(avg$ma7)] <- avg$harga[is.na(avg$ma7)]
  avg$vol7 <- roll_sd(avg$harga, 7)
  avg$min7 <- roll_apply(avg$harga, 7, min)
  avg$max7 <- roll_apply(avg$harga, 7, max)
  avg$suhu_puncak_lag1 <- lag_vec(avg$suhu_puncak, 1)
  avg$delta_suhu <- c(0, diff(avg$suhu_puncak))
  avg$hei <- pmax(avg$suhu_puncak_lag1 - 32, 0) * pmax(82 - avg$kelembaban, 0)
  avg$day_of_week <- factor(weekdays(avg$tanggal), levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"))
  avg$month <- factor(format(avg$tanggal, "%m"))
  avg
}

fit_pipeline_models <- function(train_avg) {
  price_ts <- ts(train_avg$harga, frequency = 7)
  d_adf <- tryCatch(forecast::ndiffs(price_ts, test = "adf"), error = function(e) NA_integer_)
  d_kpss <- tryCatch(forecast::ndiffs(price_ts, test = "kpss"), error = function(e) NA_integer_)
  d_seasonal <- tryCatch(forecast::nsdiffs(price_ts), error = function(e) NA_integer_)
  sarima_model <- forecast::auto.arima(
    price_ts,
    seasonal = TRUE,
    stepwise = TRUE,
    approximation = FALSE,
    allowdrift = TRUE,
    allowmean = TRUE
  )
  sarima_fit <- as.numeric(stats::fitted(sarima_model))
  residual <- as.numeric(stats::residuals(sarima_model))

  model_frame <- train_avg
  model_frame$sarima <- sarima_fit
  model_frame$residual <- residual
  model_frame <- model_frame[complete.cases(model_frame[, c("harga_kemarin", "lag2", "lag3", "lag7", "suhu_puncak_lag1", "ma7", "vol7", "min7", "max7", "hei", "residual")]), ]

  feature_formula <- ~ suhu_puncak + suhu_puncak_lag1 + delta_suhu + hei + hujan + kelembaban + harga_kemarin + lag2 + lag3 + lag7 + ma7 + vol7 + min7 + max7 + margin_hl + day_of_week + month - 1
  x_reg <- model.matrix(feature_formula, model_frame)
  reg_matrix <- xgb.DMatrix(data = x_reg, label = model_frame$residual)

  tune_n <- min(120, nrow(x_reg))
  tune_train <- seq_len(nrow(x_reg) - min(21, floor(tune_n * 0.25)))
  tune_valid <- setdiff(seq_len(nrow(x_reg)), tune_train)
  tune_grid <- expand.grid(max_depth = c(2, 3), eta = c(0.03, 0.06), nrounds = c(80, 140))
  tune_scores <- lapply(seq_len(nrow(tune_grid)), function(i) {
    params <- tune_grid[i, ]
    fit <- xgb.train(
      params = list(objective = "reg:squarederror", max_depth = params$max_depth, eta = params$eta, subsample = 0.9, colsample_bytree = 0.9, nthread = 1),
      data = xgb.DMatrix(x_reg[tune_train, , drop = FALSE], label = model_frame$residual[tune_train]),
      nrounds = params$nrounds,
      verbose = 0
    )
    pred <- as.numeric(predict(fit, x_reg[tune_valid, , drop = FALSE]))
    data.frame(i = i, RMSE = sqrt(mean((model_frame$residual[tune_valid] - pred)^2, na.rm = TRUE)))
  })
  tune_scores <- do.call(rbind, tune_scores)
  best_tune <- tune_grid[tune_scores$i[which.min(tune_scores$RMSE)], ]
  xgb_reg_model <- xgb.train(
    params = list(objective = "reg:squarederror", max_depth = best_tune$max_depth, eta = best_tune$eta, subsample = 0.9, colsample_bytree = 0.9, nthread = 1),
    data = reg_matrix,
    nrounds = best_tune$nrounds,
    verbose = 0
  )
  xgb_residual_fit <- as.numeric(predict(xgb_reg_model, x_reg))
  model_frame$xgb_residual <- xgb_residual_fit
  model_frame$hybrid <- model_frame$sarima + model_frame$xgb_residual

  future_jump <- ave(model_frame$harga, rep(1, nrow(model_frame)), FUN = function(x) {
    sapply(seq_along(x), function(i) {
      future <- x[(i + 1):min(length(x), i + 3)]
      if (length(future) == 0 || all(is.na(future))) return(NA_real_)
      max(future, na.rm = TRUE) / x[i] - 1
    })
  })
  heat_flag <- model_frame$suhu_puncak_lag1 >= stats::quantile(model_frame$suhu_puncak_lag1, 0.75, na.rm = TRUE)
  margin_flag <- model_frame$margin_hl >= stats::quantile(model_frame$margin_hl, 0.80, na.rm = TRUE)
  model_frame$gagal_distribusi <- as.integer((future_jump >= 0.10) | (margin_flag & heat_flag))
  model_frame$gagal_distribusi[is.na(model_frame$gagal_distribusi)] <- 0
  if (length(unique(model_frame$gagal_distribusi)) < 2) {
    cutoff <- stats::quantile(future_jump, 0.80, na.rm = TRUE)
    model_frame$gagal_distribusi <- as.integer(future_jump >= cutoff)
    model_frame$gagal_distribusi[is.na(model_frame$gagal_distribusi)] <- 0
  }

  cls_matrix <- xgb.DMatrix(data = x_reg, label = model_frame$gagal_distribusi)
  xgb_cls_model <- xgb.train(
    params = list(objective = "binary:logistic", eval_metric = "logloss", max_depth = 3, eta = 0.05, subsample = 0.9, colsample_bytree = 0.9, nthread = 1),
    data = cls_matrix,
    nrounds = 120,
    verbose = 0
  )
  model_frame$risk_prob <- as.numeric(predict(xgb_cls_model, x_reg))
  model_frame$status <- cut(
    model_frame$risk_prob,
    breaks = c(-Inf, 0.45, 0.70, Inf),
    labels = c("Aman", "Waspada", "Darurat")
  )

  reg_contrib <- as.data.frame(predict(xgb_reg_model, x_reg, predcontrib = TRUE))
  cls_contrib <- as.data.frame(predict(xgb_cls_model, x_reg, predcontrib = TRUE))
  reg_contrib <- reg_contrib[, !names(reg_contrib) %in% c("BIAS", "(Intercept)"), drop = FALSE]
  cls_contrib <- cls_contrib[, !names(cls_contrib) %in% c("BIAS", "(Intercept)"), drop = FALSE]
  shap_reg_summary <- data.frame(
    fitur = names(reg_contrib),
    kontribusi = colMeans(abs(reg_contrib), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
  shap_cls_summary <- data.frame(
    fitur = names(cls_contrib),
    kontribusi = colMeans(abs(cls_contrib), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
  shap_reg_summary <- shap_reg_summary[order(shap_reg_summary$kontribusi, decreasing = TRUE), ][1:min(8, nrow(shap_reg_summary)), ]
  shap_cls_summary <- shap_cls_summary[order(shap_cls_summary$kontribusi, decreasing = TRUE), ][1:min(8, nrow(shap_cls_summary)), ]
  shap_reg_summary$fitur <- factor(shap_reg_summary$fitur, levels = rev(shap_reg_summary$fitur))
  shap_cls_summary$fitur <- factor(shap_cls_summary$fitur, levels = rev(shap_cls_summary$fitur))

  dep_reg <- data.frame(
    suhu = model_frame$suhu_puncak_lag1,
    shap = reg_contrib[["suhu_puncak_lag1"]],
    harga = model_frame$harga
  )
  dep_cls <- data.frame(
    suhu = model_frame$suhu_puncak_lag1,
    shap = cls_contrib[["suhu_puncak_lag1"]],
    risiko = model_frame$risk_prob
  )

  ord <- forecast::arimaorder(sarima_model)
  sarima_label <- if (all(c("P", "D", "Q", "Frequency") %in% names(ord))) {
    paste0("SARIMA (", paste(ord[c("p", "d", "q")], collapse = ","), ")(",
           paste(ord[c("P", "D", "Q")], collapse = ","), ")[", ord[["Frequency"]], "]")
  } else {
    paste0("SARIMA (", paste(ord[c("p", "d", "q")], collapse = ","), ")(0,0,0)[7]")
  }

  list(
    model_frame = model_frame,
    feature_formula = feature_formula,
    feature_cols = colnames(x_reg),
    best_tune = best_tune,
    shap_reg_summary = shap_reg_summary,
    shap_cls_summary = shap_cls_summary,
    dep_reg = dep_reg,
    dep_cls = dep_cls,
    stationarity_label = paste0("ADF d=", d_adf, ", KPSS d=", d_kpss, ", seasonal D=", d_seasonal),
    sarima_label = sarima_label,
    models = list(sarima = sarima_model, xgb_reg = xgb_reg_model, xgb_cls = xgb_cls_model)
  )
}

align_future_matrix <- function(mat, feature_cols) {
  missing <- setdiff(feature_cols, colnames(mat))
  if (length(missing) > 0) {
    filler <- matrix(0, nrow = nrow(mat), ncol = length(missing))
    colnames(filler) <- missing
    mat <- cbind(mat, filler)
  }
  mat[, feature_cols, drop = FALSE]
}

predict_future_path <- function(fit_obj, history_avg, future_climate) {
  future_features <- future_climate[order(future_climate$tanggal), c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE]
  h <- nrow(future_features)
  if (h == 0) return(data.frame())
  sarima_forecast <- as.numeric(forecast::forecast(fit_obj$models$sarima, h = h)$mean)
  proxy_prices <- c(history_avg$harga, sarima_forecast)
  proxy_n <- length(history_avg$harga)
  future_features$margin_hl <- tail(history_avg$margin_hl, 1)
  previous_suhu <- c(tail(history_avg$suhu_puncak, 1), head(future_features$suhu_puncak, -1))
  future_features$suhu_puncak_lag1 <- previous_suhu
  future_features$delta_suhu <- c(future_features$suhu_puncak[1] - tail(history_avg$suhu_puncak, 1), diff(future_features$suhu_puncak))
  future_features$hei <- pmax(future_features$suhu_puncak_lag1 - 32, 0) * pmax(82 - future_features$kelembaban, 0)
  for (i in seq_len(h)) {
    idx <- proxy_n + i
    hist <- proxy_prices[seq_len(idx - 1)]
    future_features$harga_kemarin[i] <- tail(hist, 1)
    future_features$lag2[i] <- if (length(hist) >= 2) hist[length(hist) - 1] else NA_real_
    future_features$lag3[i] <- if (length(hist) >= 3) hist[length(hist) - 2] else NA_real_
    future_features$lag7[i] <- if (length(hist) >= 7) hist[length(hist) - 6] else NA_real_
    future_features$ma7[i] <- mean(tail(hist, 7), na.rm = TRUE)
    future_features$vol7[i] <- stats::sd(tail(hist, 7), na.rm = TRUE)
    future_features$min7[i] <- min(tail(hist, 7), na.rm = TRUE)
    future_features$max7[i] <- max(tail(hist, 7), na.rm = TRUE)
  }
  future_features$day_of_week <- factor(weekdays(future_features$tanggal), levels = levels(fit_obj$model_frame$day_of_week))
  future_features$month <- factor(format(future_features$tanggal, "%m"), levels = levels(fit_obj$model_frame$month))
  x_future <- model.matrix(fit_obj$feature_formula, future_features)
  x_future <- align_future_matrix(x_future, fit_obj$feature_cols)
  future_residual <- as.numeric(predict(fit_obj$models$xgb_reg, x_future))
  future_hybrid <- sarima_forecast + future_residual
  future_risk <- as.numeric(predict(fit_obj$models$xgb_cls, x_future))
  data.frame(
    tanggal = as.Date(future_features$tanggal),
    sarima = sarima_forecast,
    xgb_residual = future_residual,
    prediksi_hybrid = future_hybrid,
    risk_prob = future_risk,
    status = as.character(cut(future_risk, breaks = c(-Inf, 0.45, 0.70, Inf), labels = c("Aman", "Waspada", "Darurat"))),
    stringsAsFactors = FALSE
  )
}

build_live_future_climate <- function(avg, bmkg_forecast, horizon = validation_days) {
  if (is.data.frame(bmkg_forecast) && nrow(bmkg_forecast) > 0) {
    future <- bmkg_forecast[bmkg_forecast$tanggal > max(avg$tanggal), c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE]
    future <- future[order(future$tanggal), ]
    future <- head(future, horizon)
    if (nrow(future) >= horizon) return(future)
    if (nrow(future) > 0) {
      extra_n <- horizon - nrow(future)
      tail_row <- future[nrow(future), c("suhu_puncak", "kelembaban", "hujan"), drop = FALSE]
      extra <- data.frame(
        tanggal = seq.Date(max(future$tanggal) + 1, by = "day", length.out = extra_n),
        suhu_puncak = rep(tail_row$suhu_puncak, extra_n),
        kelembaban = rep(tail_row$kelembaban, extra_n),
        hujan = rep(tail_row$hujan, extra_n)
      )
      return(rbind(future, extra))
    }
  }
  data.frame(
    tanggal = seq.Date(max(avg$tanggal) + 1, by = "day", length.out = horizon),
    suhu_puncak = rep(tail(avg$suhu_puncak, 1), horizon),
    kelembaban = rep(tail(avg$kelembaban, 1), horizon),
    hujan = rep(tail(avg$hujan, 1), horizon)
  )
}

build_pipeline <- function(df, bmkg_forecast = NULL) {
  avg <- prepare_avg_frame(df)
  if (nrow(avg) < 14) stop("Data hasil merge terlalu sedikit untuk dashboard.", call. = FALSE)

  validation_dates <- tail(sort(unique(avg$tanggal)), validation_days)
  train_avg <- avg[!avg$tanggal %in% validation_dates, ]
  validation_frame <- avg[avg$tanggal %in% validation_dates, ]
  train_avg <- train_avg[order(train_avg$tanggal), ]
  validation_frame <- validation_frame[order(validation_frame$tanggal), ]
  if (nrow(validation_frame) != validation_days) stop("Data validasi 3 hari terbaru tidak lengkap.", call. = FALSE)

  eval_fit <- fit_pipeline_models(train_avg)
  validation_core <- predict_future_path(eval_fit, train_avg, validation_frame)
  validation_result <- data.frame(
    tanggal = as.Date(validation_core$tanggal),
    harga_aktual = as.numeric(validation_frame$harga),
    sarima = validation_core$sarima,
    xgb_residual = validation_core$xgb_residual,
    prediksi_hybrid = validation_core$prediksi_hybrid,
    error = as.numeric(validation_frame$harga - validation_core$prediksi_hybrid),
    ape = abs(as.numeric(validation_frame$harga - validation_core$prediksi_hybrid)) / pmax(as.numeric(validation_frame$harga), 1),
    risk_prob = validation_core$risk_prob,
    status = validation_core$status,
    stringsAsFactors = FALSE
  )
  baseline_forecasts <- list(
    Naive = rep(tail(eval_fit$model_frame$harga, 1), validation_days),
    MA7 = rep(mean(tail(eval_fit$model_frame$harga, 7), na.rm = TRUE), validation_days),
    `SARIMA-only` = validation_core$sarima,
    Hybrid = validation_core$prediksi_hybrid
  )
  holdout_metrics <- do.call(rbind, lapply(names(baseline_forecasts), function(name) {
    out <- model_metrics(validation_result$harga_aktual, baseline_forecasts[[name]])
    out$model <- name
    out
  }))
  holdout_metrics <- holdout_metrics[, c("model", "MAE", "RMSE", "MAPE")]

  rolling_frame <- tail(eval_fit$model_frame, min(60, nrow(eval_fit$model_frame)))
  rolling_long <- rbind(
    data.frame(tanggal = rolling_frame$tanggal, model = "Naive", actual = rolling_frame$harga, predicted = rolling_frame$harga_kemarin),
    data.frame(tanggal = rolling_frame$tanggal, model = "MA7", actual = rolling_frame$harga, predicted = rolling_frame$ma7),
    data.frame(tanggal = rolling_frame$tanggal, model = "SARIMA-only", actual = rolling_frame$harga, predicted = rolling_frame$sarima),
    data.frame(tanggal = rolling_frame$tanggal, model = "Hybrid", actual = rolling_frame$harga, predicted = rolling_frame$hybrid)
  )
  rolling_long$error <- rolling_long$actual - rolling_long$predicted
  rolling_long$ape <- abs(rolling_long$error) / pmax(abs(rolling_long$actual), 1)
  rolling_metrics <- do.call(rbind, lapply(split(rolling_long, rolling_long$model), function(dat) {
    out <- model_metrics(dat$actual, dat$predicted)
    out$model <- unique(dat$model)
    out
  }))
  rolling_metrics <- rolling_metrics[, c("model", "MAE", "RMSE", "MAPE")]

  live_fit <- fit_pipeline_models(avg)
  live_input <- build_live_future_climate(avg, bmkg_forecast, validation_days)
  live_forecast <- predict_future_path(live_fit, avg, live_input)
  last_actual_risk <- tail(live_fit$model_frame$risk_prob, 1)
  forecast_data <- data.frame(
    horizon = factor(c("Aktual terakhir", paste0("H+", seq_len(nrow(live_forecast)))), levels = c("Aktual terakhir", paste0("H+", seq_len(nrow(live_forecast))))),
    harga = c(tail(avg$harga, 1), live_forecast$prediksi_hybrid),
    aktual = c(tail(avg$harga, 1), rep(NA_real_, nrow(live_forecast))),
    tanggal = c(tail(avg$tanggal, 1), live_forecast$tanggal),
    komponen = c("Observasi", rep("Forecast", nrow(live_forecast))),
    risk_prob = c(last_actual_risk, live_forecast$risk_prob),
    status = c(as.character(cut(last_actual_risk, breaks = c(-Inf, 0.45, 0.70, Inf), labels = c("Aman", "Waspada", "Darurat"))), live_forecast$status),
    stringsAsFactors = FALSE
  )

  list(
    data = data.frame(
      tanggal = as.Date(live_fit$model_frame$tanggal),
      pasar = as.character(live_fit$model_frame$pasar),
      sumber_iklim = as.character(live_fit$model_frame$sumber_iklim),
      harga = as.numeric(live_fit$model_frame$harga),
      suhu_puncak = as.numeric(live_fit$model_frame$suhu_puncak),
      kelembaban = as.numeric(live_fit$model_frame$kelembaban),
      hujan = as.numeric(live_fit$model_frame$hujan),
      harga_kemarin = as.numeric(live_fit$model_frame$harga_kemarin),
      lag2 = as.numeric(live_fit$model_frame$lag2),
      lag3 = as.numeric(live_fit$model_frame$lag3),
      lag7 = as.numeric(live_fit$model_frame$lag7),
      ma7 = as.numeric(live_fit$model_frame$ma7),
      vol7 = as.numeric(live_fit$model_frame$vol7),
      min7 = as.numeric(live_fit$model_frame$min7),
      max7 = as.numeric(live_fit$model_frame$max7),
      margin_hl = as.numeric(live_fit$model_frame$margin_hl),
      suhu_puncak_lag1 = as.numeric(live_fit$model_frame$suhu_puncak_lag1),
      delta_suhu = as.numeric(live_fit$model_frame$delta_suhu),
      hei = as.numeric(live_fit$model_frame$hei),
      sarima = as.numeric(live_fit$model_frame$sarima),
      residual = as.numeric(live_fit$model_frame$residual),
      xgb_residual = as.numeric(live_fit$model_frame$xgb_residual),
      hybrid = as.numeric(live_fit$model_frame$hybrid),
      risk_prob = as.numeric(live_fit$model_frame$risk_prob),
      gagal_distribusi = as.integer(live_fit$model_frame$gagal_distribusi),
      status = as.character(live_fit$model_frame$status),
      stringsAsFactors = FALSE
    ),
    forecast = forecast_data,
    live_forecast = live_forecast,
    validation = validation_result,
    holdout_metrics = holdout_metrics,
    rolling_metrics = rolling_metrics,
    rolling_long = rolling_long,
    best_tune = live_fit$best_tune,
    shap_reg_summary = live_fit$shap_reg_summary,
    shap_cls_summary = live_fit$shap_cls_summary,
    dep_reg = live_fit$dep_reg,
    dep_cls = live_fit$dep_cls,
    stationarity_label = live_fit$stationarity_label,
    sarima_label = live_fit$sarima_label,
    models = live_fit$models
  )
}

build_dashboard_state <- function(commodity = NULL) {
  project_data <- load_project_data(commodity)
  raw_data <- project_data$merged
  pipeline <- build_pipeline(raw_data, project_data$bmkg_forecast)
  pipeline_data <- pipeline$data
  list(
    raw_data = raw_data,
    pipeline_data = pipeline_data,
    forecast_data = pipeline$forecast,
    live_forecast_data = pipeline$live_forecast,
    validation_data = pipeline$validation,
    holdout_metrics = pipeline$holdout_metrics,
    rolling_metrics = pipeline$rolling_metrics,
    rolling_long = pipeline$rolling_long,
    best_tune = pipeline$best_tune,
    shap_reg_summary = pipeline$shap_reg_summary,
    shap_cls_summary = pipeline$shap_cls_summary,
    dep_reg = pipeline$dep_reg,
    dep_cls = pipeline$dep_cls,
    sarima_label = pipeline$sarima_label,
    stationarity_label = pipeline$stationarity_label,
    current = tail(pipeline_data, 1),
    previous = pipeline_data[nrow(pipeline_data) - 1, ],
    commodity = project_data$commodity,
    commodity_choices = project_data$commodity_choices,
    climate_latest = max(project_data$climate$tanggal, na.rm = TRUE),
    climate_blended_latest = if (is.data.frame(project_data$climate_blended) && nrow(project_data$climate_blended) > 0) max(project_data$climate_blended$tanggal, na.rm = TRUE) else as.Date(NA),
    bmkg_latest = if (is.data.frame(project_data$bmkg_forecast) && nrow(project_data$bmkg_forecast) > 0) max(project_data$bmkg_forecast$tanggal, na.rm = TRUE) else as.Date(NA),
    source_label = project_data$source_label,
    last_refresh_time = Sys.time()
  )
}

apply_dashboard_state <- function(state) {
  for (nm in names(state)) assign(nm, state[[nm]], envir = .GlobalEnv)
  invisible(state)
}

initial_choices <- discover_commodity_files(app_start_dir)
initial_tomato <- grep("^Tomat$", names(initial_choices), ignore.case = TRUE)
initial_commodity <- if (length(initial_tomato) > 0) names(initial_choices)[initial_tomato[[1]]] else names(initial_choices)[[1]]
apply_dashboard_state(build_dashboard_state(initial_commodity))

ui <- fluidPage(
  tags$head(
    tags$title("Dashboard Tomat Cilegon"),
    tags$style(HTML("
      body { background:#1f201e; color:#f5f2e8; font-family: Inter, 'Segoe UI', Arial, sans-serif; }
      .container-fluid { max-width: 1220px; padding: 24px 30px 34px; }
      .app-title { font-size: 24px; font-weight: 800; margin: 0; }
      .app-subtitle { color:#c8c7bc; margin: 3px 0 20px; font-size: 14px; }
      .tabbable > .nav > li > a { background:#292a27; color:#d7d5c9; border:1px solid #454741; border-radius:6px 6px 0 0; }
      .tabbable > .nav > li.active > a, .tabbable > .nav > li.active > a:focus { background:#343630; color:#fff5df; border-color:#686a61; }
      .card { background:#292a27; border:1px solid #4b4d46; border-radius:8px; padding:18px; margin-bottom:18px; box-shadow:none; }
      .metric { min-height: 118px; }
      .metric-label { color:#d7d5c9; font-size:13px; font-weight:700; }
      .metric-value { font-size:28px; font-weight:850; margin-top:6px; }
      .metric-note { color:#f0a54a; font-size:12px; font-weight:700; }
      .refresh-bar { display:flex; align-items:center; justify-content:space-between; gap:14px; }
      .refresh-info { color:#d7d5c9; font-size:13px; line-height:1.35; }
      .btn-refresh { background:#3a3c36; border:1px solid #686a61; color:#fff5df; border-radius:6px; font-weight:800; }
      .btn-refresh:hover, .btn-refresh:focus { background:#474a42; color:#fff5df; border-color:#85877d; }
      .status-pill { display:inline-block; padding:8px 12px; border-radius:6px; font-weight:800; }
      .Aman { background:#164b3f; color:#8ee0c6; }
      .Waspada { background:#5b4708; color:#ffd573; }
      .Darurat { background:#663023; color:#ffb29b; }
      .section-title { font-weight:850; font-size:16px; margin-bottom:0; }
      .section-subtitle { color:#c8c7bc; font-size:12px; margin-bottom:12px; }
      .note-grid { display:grid; grid-template-columns: repeat(3, 1fr); gap:12px; margin-top:4px; }
      .note-item { background:#20211f; border:1px solid #454741; border-radius:6px; padding:12px; color:#d7d5c9; font-size:13px; line-height:1.35; }
      .note-item b { color:#fff5df; }
      .explain-grid { display:grid; grid-template-columns: repeat(3, 1fr); gap:12px; margin-top:6px; }
      .explain-item { background:#20211f; border:1px solid #454741; border-radius:6px; padding:13px; color:#d7d5c9; font-size:13px; line-height:1.42; }
      .explain-item b { color:#fff5df; display:block; margin-bottom:5px; }
      .flow-narrative { color:#d7d5c9; font-size:13px; line-height:1.55; margin:0 0 12px; max-width:1040px; }
      .flow-grid { display:grid; grid-template-columns: repeat(4, 1fr); gap:12px; }
      .flow-box { border-radius:8px; padding:13px; min-height:84px; border:1px solid rgba(255,255,255,.12); }
      .flow-box strong { display:block; margin-bottom:5px; }
      .price { background:#d7f2ea; color:#12624f; }
      .climate { background:#dbeaf8; color:#245d8f; }
      .sarima { background:#e8e5ff; color:#5149a7; }
      .xgb { background:#ffeed2; color:#835411; }
      .shap { background:#ffe7df; color:#964a32; }
      .policy { background:#e5f3d8; color:#4a7b2e; }
      table, .table, .shiny-table { width:100%; color:#f4f1e8 !important; background:transparent !important; border-collapse:collapse; }
      table thead tr, .table thead tr, .shiny-table thead tr { background:#20211f !important; color:#fff5df !important; }
      table th, table td, .table th, .table td, .shiny-table th, .shiny-table td { background:transparent !important; color:#f4f1e8 !important; border-top:1px solid #454741 !important; padding:9px 12px !important; vertical-align:top; }
      table tbody tr, .table tbody tr, .shiny-table tbody tr { background:#292a27 !important; }
      table tbody tr:nth-child(even), .table tbody tr:nth-child(even), .shiny-table tbody tr:nth-child(even) { background:#232421 !important; }
      table tbody tr:hover, .table tbody tr:hover, .shiny-table tbody tr:hover { background:#33352f !important; }
      .dataTables_wrapper { color:#f4f1e8; }
      @media (max-width: 900px) { .flow-grid, .note-grid, .explain-grid { grid-template-columns: 1fr; } .container-fluid { padding:18px; } }
    "))
  ),
  h1("Dashboard ketahanan pangan Cilegon", class = "app-title"),
  div("Monitoring suhu dan harga komoditas pangan - koridor Bandung-Cilegon", class = "app-subtitle"),

  tabsetPanel(
    tabPanel(
      "Dashboard",
      div(class = "card refresh-bar",
        uiOutput("refreshStatus"),
        selectInput("commoditySelect", NULL, choices = commodity_choices, selected = commodity, width = "260px"),
        actionButton("refreshNow", "Refresh data", class = "btn-refresh")
      ),
      fluidRow(
        column(6, div(class = "card metric",
          uiOutput("priceMetric")
        )),
        column(6, div(class = "card metric",
          uiOutput("tempMetric")
        ))
      ),
      div(class = "card",
        div("Panel monitoring", class = "section-title"),
        div("Harga tiga pasar diringkas sebagai rentang, rata-rata, dan suhu puncak harian", class = "section-subtitle"),
        plotOutput("monitorPlot", height = 320)
      ),
      fluidRow(
        column(7, div(class = "card",
          div("Panel prediksi", class = "section-title"),
          div("Forecast live H+1 sampai H+3 memakai harga historis terbaru dan BMKG forecast", class = "section-subtitle"),
          plotOutput("forecastPlot", height = 265)
        )),
        column(5, div(class = "card",
          div("Panel early warning", class = "section-title"),
          div("Status risiko gagal distribusi", class = "section-subtitle"),
          uiOutput("warningBox"),
          tags$hr(),
          tableOutput("policyTable")
        ))
      )
    ),
    tabPanel(
      "Alur Model",
      div(class = "card",
        div("Pipeline SARIMA-XGBoost-SHAP", class = "section-title"),
        div("Tahap 1 sampai 8 sesuai alur penelitian dan dashboard kebijakan", class = "section-subtitle"),
        p(class = "flow-narrative",
          "Alur dimulai dari pengumpulan harga tomat harian SAGON Cilegon dan data iklim ERA5. ",
          "Keduanya dibersihkan lalu digabung berdasarkan tanggal agar setiap observasi memiliki pasangan harga, suhu, kelembaban, dan hujan pada hari yang sama. ",
          "Harga rata-rata kemudian diuji stasioneritasnya dengan ADF/KPSS; jika belum stasioner, komponen differencing dipilih melalui proses SARIMA. ",
          "SARIMA menangkap pola autokorelasi dan musiman, sedangkan residual epsilon yang tersisa dipakai sebagai target XGBoost regresi untuk menangkap pola non-linear."
        ),
        div(class = "flow-grid",
          div(class = "flow-box price", strong("Tahap 1 - SAGON Cilegon"), "Harga tomat harian dari tiga pasar."),
          div(class = "flow-box climate", strong("Tahap 1 - ERA5 Reanalysis"), "Suhu, kelembaban, dan hujan koridor Bandung-Cilegon."),
          div(class = "flow-box", strong("Tahap 2 - Pra-pemrosesan"), "Cleaning dan merge berdasarkan tanggal yang sama."),
          div(class = "flow-box sarima", strong("Tahap 3 - Uji stasioneritas"), paste("ADF/KPSS pada harga rata-rata:", stationarity_label)),
          div(class = "flow-box sarima", strong("Tahap 4 - SARIMA"), paste(sarima_label, "diagnostik residual, ekstraksi epsilon.")),
          div(class = "flow-box", strong("Tahap 5 - Rekayasa fitur"), "Suhu, harga, dan kalender digabung sebagai prediktor."),
          div(class = "flow-box xgb", strong("Tahap 6 - XGBoost regresi"), "Residual SARIMA dimodelkan untuk prediksi akhir hybrid."),
          div(class = "flow-box shap", strong("Tahap 6 - XGBoost klasifikasi"), "Model independen untuk normal vs gagal distribusi."),
          div(class = "flow-box shap", strong("Tahap 7 - SHAP regresi"), "Summary dan dependence plot untuk pengaruh harga."),
          div(class = "flow-box shap", strong("Tahap 7 - SHAP klasifikasi"), "Summary dan dependence plot untuk pemicu risiko."),
          div(class = "flow-box policy", strong("Tahap 8 - Dashboard"), "Monitoring, prediksi, dan early warning."),
          div(class = "flow-box policy", strong("Output"), "Rekomendasi kebijakan intervensi Pemkot Cilegon.")
        )
      ),
      div(class = "card",
        div("Keterkaitan teknis dashboard", class = "section-title"),
        div("Tiga panel memakai sumber data yang sama, tetapi menjawab kebutuhan keputusan yang berbeda", class = "section-subtitle"),
        div(class = "explain-grid",
          div(class = "explain-item",
            tags$b("Panel monitoring"),
            "Memakai data hasil cleaning dan merge untuk memperlihatkan tren harga tiga pasar bersama suhu puncak harian. Panel ini menjadi konteks operasional: apakah kenaikan harga bergerak bersamaan dengan kondisi panas."
          ),
          div(class = "explain-item",
            tags$b("Panel prediksi"),
            "Memakai output hybrid. SARIMA memberi baseline pola waktu, XGBoost residual menambahkan koreksi non-linear, lalu keduanya dijumlahkan sebagai forecast harga H+1 sampai H+3."
          ),
          div(class = "explain-item",
            tags$b("Panel early warning"),
            "Memakai XGBoost klasifikasi untuk mengubah fitur suhu, harga, dan kalender menjadi probabilitas risiko. Probabilitas itu diterjemahkan ke status aman, waspada, atau darurat untuk rekomendasi kebijakan."
          )
        )
      ),
      fluidRow(
        column(6, div(class = "card",
          div("Diagnostik residual SARIMA", class = "section-title"),
          div(paste("Residual epsilon dari", sarima_label, "sebagai target XGBoost regresi"), class = "section-subtitle"),
          plotOutput("residualPlot", height = 260)
        )),
        column(6, div(class = "card",
          div("Prediksi hybrid", class = "section-title"),
          div("Y topi = SARIMA(t) + XGBoost(epsilon), memakai model yang dilatih dari data", class = "section-subtitle"),
          plotOutput("hybridPlot", height = 260)
        ))
      )
    ),
    tabPanel(
      "Evaluasi Model",
      fluidRow(
        column(6, div(class = "card",
          div("Holdout 3 hari terbaru", class = "section-title"),
          div("Perbandingan model pada data yang tidak masuk training", class = "section-subtitle"),
          tableOutput("holdoutMetrics")
        )),
        column(6, div(class = "card",
          div("Rolling backtest", class = "section-title"),
          div("Ringkasan 60 titik latih terakhir untuk melihat stabilitas error", class = "section-subtitle"),
          tableOutput("rollingMetrics")
        ))
      ),
      div(class = "card",
        div("Error rolling validation", class = "section-title"),
        div("Absolute percentage error per tanggal untuk baseline dan model hybrid", class = "section-subtitle"),
        plotOutput("rollingPlot", height = 300)
      ),
      div(class = "card",
        div("Konfigurasi tuning XGBoost residual", class = "section-title"),
        div("Grid kecil dipakai agar app tetap ringan saat dibuka", class = "section-subtitle"),
        tableOutput("tuningTable")
      )
    ),
    tabPanel(
      "Interpretasi SHAP",
      div(class = "card",
        div("Kenapa SHAP dipisah?", class = "section-title"),
        div("Regresi dan klasifikasi punya target, satuan output, dan pertanyaan kebijakan yang berbeda", class = "section-subtitle"),
        div(class = "explain-grid",
          div(class = "explain-item",
            tags$b("SHAP regresi"),
            "Menjelaskan kontribusi fitur terhadap besar-kecilnya koreksi harga pada residual SARIMA. Nilai SHAP di jalur ini dibaca sebagai dorongan naik atau turun terhadap prediksi harga hybrid."
          ),
          div(class = "explain-item",
            tags$b("SHAP klasifikasi"),
            "Menjelaskan kontribusi fitur terhadap peluang masuk kelas risiko gagal distribusi. Nilai SHAP di jalur ini dibaca sebagai dorongan menuju status risiko, bukan sebagai perubahan rupiah."
          ),
          div(class = "explain-item",
            tags$b("Implikasi interpretasi"),
            "Karena maknanya berbeda, satu pasang summary dan dependence plot tidak cukup. Model regresi menjawab seberapa besar dampaknya ke harga, sedangkan model klasifikasi menjawab kapan kondisi mulai berbahaya."
          )
        )
      ),
      fluidRow(
        column(6, div(class = "card",
          div("Regresi - Summary plot", class = "section-title"),
          div("Ranking variabel suhu terhadap besaran harga", class = "section-subtitle"),
          plotOutput("shapRegSummary", height = 260)
        )),
        column(6, div(class = "card",
          div("Regresi - Dependence plot", class = "section-title"),
          div("Titik suhu ketika efek harga mulai melonjak", class = "section-subtitle"),
          plotOutput("shapRegDependence", height = 260)
        ))
      ),
      fluidRow(
        column(6, div(class = "card",
          div("Klasifikasi - Summary plot", class = "section-title"),
          div("Variabel pemicu risiko gagal distribusi", class = "section-subtitle"),
          plotOutput("shapClsSummary", height = 260)
        )),
        column(6, div(class = "card",
          div("Klasifikasi - Dependence plot", class = "section-title"),
          div("Ambang suhu terkait status risiko", class = "section-subtitle"),
          plotOutput("shapClsDependence", height = 260)
        ))
      ),
      div(class = "card",
        div("Keterangan variabel", class = "section-title"),
        div("Definisi fitur yang dipakai pada model regresi residual dan klasifikasi risiko", class = "section-subtitle"),
        div(class = "note-grid",
          div(class = "note-item", HTML("<b>suhu_puncak_lag1</b><br>Suhu puncak koridor distribusi pada hari sebelumnya. Dipakai untuk menangkap efek panas yang muncul terlambat pada harga atau distribusi.")),
          div(class = "note-item", HTML("<b>HEI</b><br>Heat Exposure Index, indeks paparan panas. Di app ini dihitung dari kelebihan suhu di atas 32 derajat C dikalikan kondisi kelembaban yang mendukung stres panas.")),
          div(class = "note-item", HTML("<b>delta_suhu</b><br>Perubahan suhu puncak dibanding hari sebelumnya. Nilai besar berarti terjadi lonjakan atau penurunan suhu mendadak.")),
          div(class = "note-item", HTML("<b>ma7</b><br>Rata-rata bergerak harga tomat 7 hari. Fitur ini mewakili level harga jangka pendek sebelum prediksi dibuat.")),
          div(class = "note-item", HTML("<b>margin_hl</b><br>Selisih harga tertinggi dan terendah dari tiga pasar pada tanggal yang sama. Makin besar berarti disparitas antar pasar makin kuat.")),
          div(class = "note-item", HTML("<b>hujan</b><br>Total curah hujan harian dari ERA5. Dipakai karena hujan dapat memengaruhi distribusi, pasokan, dan kualitas komoditas.")),
          div(class = "note-item", HTML("<b>day_of_week</b><br>Hari dalam minggu. Fitur kalender untuk menangkap pola pasar mingguan.")),
          div(class = "note-item", HTML("<b>month</b><br>Bulan kalender. Fitur ini membantu membaca pola musiman pasokan dan cuaca.")),
          div(class = "note-item", HTML("<b>Nilai SHAP</b><br>Kontribusi variabel terhadap output model. Pada regresi berarti dorongan ke harga, pada klasifikasi berarti dorongan ke risiko gagal distribusi.")),
          div(class = "note-item", HTML("<b>gagal_distribusi</b><br>Label proxy karena data tidak menyediakan status kejadian asli. Dibentuk dari lonjakan harga 3 hari ke depan atau kombinasi margin tinggi dan panas tinggi."))
        )
      )
    ),
    tabPanel(
      "Data",
      div(class = "card",
        div("Data hasil cleaning dan merge", class = "section-title"),
        div("Contoh struktur data akhir setelah harga dan iklim disatukan berdasarkan tanggal", class = "section-subtitle"),
        tableOutput("dataPreview")
      )
    )
  )
)

server <- function(input, output, session) {
  refresh_key <- reactiveVal(0)

  refresh_dashboard <- function(commodity_value = NULL) {
    tryCatch({
      if (is.null(commodity_value) || !nzchar(commodity_value)) commodity_value <- commodity
      apply_dashboard_state(build_dashboard_state(commodity_value))
      refresh_key(isolate(refresh_key()) + 1)
      showNotification("Data realtime berhasil diperbarui.", type = "message", duration = 3)
    }, error = function(e) {
      showNotification(paste("Refresh gagal:", conditionMessage(e)), type = "error", duration = 7)
    })
  }

  observeEvent(input$refreshNow, {
    refresh_dashboard(input$commoditySelect)
  }, ignoreInit = TRUE)

  observeEvent(input$commoditySelect, {
    refresh_dashboard(input$commoditySelect)
  }, ignoreInit = TRUE)

  observe({
    invalidateLater(refresh_interval_ms, session)
    if (isTRUE(session$userData$auto_refresh_started)) {
      refresh_dashboard(input$commoditySelect)
    } else {
      session$userData$auto_refresh_started <- TRUE
    }
  })

  output$refreshStatus <- renderUI({
    refresh_key()
    div(class = "refresh-info",
      div(strong("Komoditas: "), commodity),
      div(strong("Sumber data: "), source_label),
      div(strong("ERA5 terakhir: "), format_tanggal(climate_latest)),
      div(strong("Iklim gabungan sampai: "), if (is.na(climate_blended_latest)) "-" else format_tanggal(climate_blended_latest)),
      div(strong("BMKG forecast sampai: "), if (is.na(bmkg_latest)) "-" else format_tanggal(bmkg_latest)),
      div(
        "Update terakhir: ", format(last_refresh_time, "%d %b %Y %H:%M:%S"),
        " | Auto-refresh tiap ", round(refresh_interval_ms / 60000, 1), " menit"
      )
    )
  })

  output$priceMetric <- renderUI({
    refresh_key()
    div(
      div(paste("Harga", commodity, "data latih terakhir"), class = "metric-label"),
      div(rupiah(current$harga), class = "metric-value"),
      div(sprintf("%+.1f%% vs kemarin", 100 * (current$harga - previous$harga) / previous$harga), class = "metric-note")
    )
  })

  output$tempMetric <- renderUI({
    refresh_key()
    div(
      div("Suhu puncak koridor", class = "metric-label"),
      div(sprintf("%.1f derajat C", current$suhu_puncak), class = "metric-value"),
      div(paste0(ifelse(current$suhu_puncak >= 32, "Di atas ambang 32 derajat C", "Di bawah ambang 32 derajat C"), " | Sumber: ", current$sumber_iklim), class = "metric-note")
    )
  })

  output$monitorPlot <- renderPlot({
    refresh_key()
    last_date <- max(raw_data$tanggal, na.rm = TRUE)
    df <- raw_data[raw_data$tanggal >= last_date - 30, ]
    markets <- df[df$pasar != "Harga rata-rata", ]
    daily <- aggregate(harga ~ tanggal, markets, function(x) c(min = min(x, na.rm = TRUE), mean = mean(x, na.rm = TRUE), max = max(x, na.rm = TRUE)))
    daily <- data.frame(
      tanggal = daily$tanggal,
      harga_min = daily$harga[, "min"],
      harga_rata = daily$harga[, "mean"],
      harga_max = daily$harga[, "max"]
    )
    climate <- unique(df[, c("tanggal", "suhu_puncak", "sumber_iklim")])
    daily <- merge(daily, climate, by = "tanggal", all.x = TRUE)
    price_range <- range(c(daily$harga_min, daily$harga_max), na.rm = TRUE)
    temp_range <- range(daily$suhu_puncak, na.rm = TRUE)
    scale_factor <- diff(price_range) / max(diff(temp_range), 1)
    offset <- price_range[1] - temp_range[1] * scale_factor
    ggplot() +
      geom_ribbon(data = daily, aes(tanggal, ymin = harga_min, ymax = harga_max, fill = "Rentang 3 pasar"), alpha = 0.22) +
      geom_line(data = markets, aes(tanggal, harga, color = pasar), linewidth = 0.55, alpha = 0.45) +
      geom_line(data = daily, aes(tanggal, harga_rata, color = "Harga rata-rata"), linewidth = 1.25) +
      geom_point(data = daily, aes(tanggal, harga_rata), color = "#f5f2e8", size = 1.5) +
      geom_line(data = daily, aes(tanggal, suhu_puncak * scale_factor + offset, color = "Suhu puncak"), linewidth = 1.05, linetype = 2) +
      geom_point(data = daily, aes(tanggal, suhu_puncak * scale_factor + offset, shape = sumber_iklim), color = "#ffcf92", size = 2.2, stroke = 0.9) +
      scale_y_continuous(labels = rupiah, sec.axis = sec_axis(~ (. - offset) / scale_factor, name = "Suhu puncak (derajat C)")) +
      scale_color_manual(values = c("Pasar Baru Cilegon" = "#61c9a8", "Pasar Blok F" = "#ffae2a", "Pasar Baru Merak" = "#f36b3f", "Harga rata-rata" = "#f5f2e8", "Suhu puncak" = "#ff7043")) +
      scale_fill_manual(values = c("Rentang 3 pasar" = "#61c9a8")) +
      scale_shape_manual(values = c("ERA5" = 16, "Bridge" = 15, "BMKG" = 17), drop = FALSE) +
      labs(x = NULL, y = paste("Harga", commodity), color = NULL, fill = NULL, shape = "Sumber iklim") +
      theme_dark_cilegon() +
      theme(legend.position = "bottom")
  })

  output$forecastPlot <- renderPlot({
    refresh_key()
    ggplot(forecast_data, aes(horizon, harga, fill = komponen)) +
      geom_col(width = 0.66, color = NA) +
      geom_text(aes(label = rupiah(harga)), vjust = -0.45, color = "#f5f2e8", size = 4, fontface = "bold") +
      scale_fill_manual(values = c("Observasi" = "#61c9a8", "Forecast" = "#f5a623")) +
      scale_y_continuous(labels = rupiah, limits = c(0, max(forecast_data$harga, na.rm = TRUE) * 1.18)) +
      labs(x = NULL, y = NULL, fill = NULL) +
      theme_dark_cilegon() +
      theme(legend.position = "bottom")
  })

  output$warningBox <- renderUI({
    refresh_key()
    risk_3day <- max(live_forecast_data$risk_prob, na.rm = TRUE)
    status <- as.character(cut(risk_3day, breaks = c(-Inf, 0.45, 0.70, Inf), labels = c("Aman", "Waspada", "Darurat")))
    validation_mape <- mean(validation_data$ape, na.rm = TRUE)
    HTML(sprintf(
      "<div class='status-pill %s'>%s</div><p style='margin-top:12px;color:#f5f2e8;font-weight:700;'>Probabilitas gagal distribusi tertinggi %.0f%% pada forecast H+1 sampai H+3</p><p style='color:#c8c7bc;'>MAPE backtest 3 hari: <b>%.1f%%</b>. Variabel pemicu utama dibaca dari SHAP model klasifikasi.</p>",
      status, status, 100 * risk_3day, 100 * validation_mape
    ))
  })

  output$policyTable <- renderTable({
    refresh_key()
    data.frame(
      Status = c("Aman", "Waspada", "Darurat"),
      Tindakan = c(
        "Monitoring harian pasar dan cuaca",
        "Koordinasi pasokan dan inspeksi stok distributor",
        "Intervensi distribusi, operasi pasar, dan komunikasi publik"
      )
    )
  }, striped = FALSE, bordered = FALSE, spacing = "s")

  output$residualPlot <- renderPlot({
    refresh_key()
    ggplot(tail(pipeline_data, 45), aes(tanggal, residual)) +
      geom_hline(yintercept = 0, color = "#8a8c84") +
      geom_col(fill = "#b2a7ff", alpha = 0.82, width = 0.8) +
      labs(x = NULL, y = "epsilon") +
      theme_dark_cilegon()
  })

  output$hybridPlot <- renderPlot({
    refresh_key()
    df <- tail(pipeline_data, 45)
    val <- validation_data
    ggplot(df, aes(tanggal)) +
      geom_line(aes(y = harga, color = "Observasi"), linewidth = 1) +
      geom_line(aes(y = sarima, color = "SARIMA"), linewidth = 0.9) +
      geom_line(aes(y = hybrid, color = "Hybrid"), linewidth = 1.1) +
      geom_vline(xintercept = as.numeric(max(df$tanggal)), linetype = 2, color = "#8a8c84") +
      geom_line(data = val, aes(tanggal, prediksi_hybrid, color = "Forecast validasi"), linewidth = 1.1, inherit.aes = FALSE) +
      geom_point(data = val, aes(tanggal, harga_aktual, color = "Aktual validasi"), size = 2.8, inherit.aes = FALSE) +
      scale_color_manual(values = c("Observasi" = "#f5f2e8", "SARIMA" = "#b2a7ff", "Hybrid" = "#f5a623", "Forecast validasi" = "#f5a623", "Aktual validasi" = "#61c9a8")) +
      scale_y_continuous(labels = rupiah) +
      labs(x = NULL, y = "Harga") +
      theme_dark_cilegon()
  })

  output$holdoutMetrics <- renderTable({
    refresh_key()
    shown <- holdout_metrics
    shown$MAE <- rupiah(shown$MAE)
    shown$RMSE <- rupiah(shown$RMSE)
    shown$MAPE <- sprintf("%.2f%%", 100 * shown$MAPE)
    shown
  }, striped = FALSE, bordered = FALSE, spacing = "s")

  output$rollingMetrics <- renderTable({
    refresh_key()
    shown <- rolling_metrics
    shown$MAE <- rupiah(shown$MAE)
    shown$RMSE <- rupiah(shown$RMSE)
    shown$MAPE <- sprintf("%.2f%%", 100 * shown$MAPE)
    shown
  }, striped = FALSE, bordered = FALSE, spacing = "s")

  output$rollingPlot <- renderPlot({
    refresh_key()
    ggplot(rolling_long, aes(tanggal, 100 * ape, color = model)) +
      geom_line(linewidth = 0.8, alpha = 0.85) +
      geom_point(size = 1.2, alpha = 0.7) +
      scale_color_manual(values = c("Naive" = "#8a8c84", "MA7" = "#61c9a8", "SARIMA-only" = "#b2a7ff", "Hybrid" = "#f5a623")) +
      labs(x = NULL, y = "APE (%)") +
      theme_dark_cilegon()
  })

  output$tuningTable <- renderTable({
    refresh_key()
    data.frame(
      parameter = c("max_depth", "eta", "nrounds"),
      nilai = c(best_tune$max_depth, best_tune$eta, best_tune$nrounds)
    )
  }, striped = FALSE, bordered = FALSE, spacing = "s")

  output$shapRegSummary <- renderPlot({
    refresh_key()
    ggplot(shap_reg_summary, aes(kontribusi, fitur)) +
      geom_col(fill = "#ffb866", width = 0.7) +
      labs(x = "Mean |SHAP|", y = NULL) +
      theme_dark_cilegon()
  })

  output$shapRegDependence <- renderPlot({
    refresh_key()
    ggplot(dep_reg, aes(suhu, shap)) +
      geom_vline(xintercept = 32.2, linetype = 2, color = "#ffb866") +
      geom_point(aes(color = harga), alpha = 0.62, size = 1.7) +
      geom_smooth(color = "#ffb866", linewidth = 1.1, se = FALSE, method = "loess", formula = y ~ x) +
      scale_color_gradient(low = "#61c9a8", high = "#ffb866", labels = rupiah) +
      annotate("text", x = 32.35, y = min(dep_reg$shap, na.rm = TRUE), label = "ambang 32.2 derajat C", color = "#ffcf92", hjust = 0, vjust = -0.3) +
      labs(x = "Suhu puncak lag-1 (derajat C)", y = "Nilai SHAP harga") +
      theme_dark_cilegon()
  })

  output$shapClsSummary <- renderPlot({
    refresh_key()
    ggplot(shap_cls_summary, aes(kontribusi, fitur)) +
      geom_col(fill = "#ff9a7d", width = 0.7) +
      labs(x = "Mean |SHAP|", y = NULL) +
      theme_dark_cilegon()
  })

  output$shapClsDependence <- renderPlot({
    refresh_key()
    ggplot(dep_cls, aes(suhu, shap)) +
      geom_hline(yintercept = 0, color = "#8a8c84") +
      geom_vline(xintercept = 33.0, linetype = 2, color = "#ff9a7d") +
      geom_point(aes(color = risiko), alpha = 0.62, size = 1.7) +
      geom_smooth(color = "#ff9a7d", linewidth = 1.1, se = FALSE, method = "loess", formula = y ~ x) +
      scale_color_gradient(low = "#61c9a8", high = "#ff9a7d", labels = function(x) paste0(round(100 * x), "%")) +
      annotate("text", x = 33.15, y = max(dep_cls$shap, na.rm = TRUE) * 0.18, label = "risiko naik", color = "#ffc2b1", hjust = 0) +
      labs(x = "Suhu puncak lag-1 (derajat C)", y = "Nilai SHAP risiko") +
      theme_dark_cilegon()
  })

  output$dataPreview <- renderTable({
    refresh_key()
    train_shown <- tail(pipeline_data, 8)
    train_table <- data.frame(
      set = "training",
      tanggal = format_tanggal(train_shown$tanggal),
      sumber_iklim = train_shown$sumber_iklim,
      harga_aktual = rupiah(train_shown$harga),
      sarima = rupiah(train_shown$sarima),
      xgb_residual = rupiah(train_shown$xgb_residual),
      prediksi_hybrid = rupiah(train_shown$hybrid),
      error = "-",
      risiko = sprintf("%.0f%%", 100 * train_shown$risk_prob),
      status = train_shown$status,
      stringsAsFactors = FALSE
    )
    validation_table <- data.frame(
      set = "validasi 3 hari",
      tanggal = format_tanggal(validation_data$tanggal),
      sumber_iklim = "ERA5",
      harga_aktual = rupiah(validation_data$harga_aktual),
      sarima = rupiah(validation_data$sarima),
      xgb_residual = rupiah(validation_data$xgb_residual),
      prediksi_hybrid = rupiah(validation_data$prediksi_hybrid),
      error = rupiah(validation_data$error),
      risiko = sprintf("%.0f%%", 100 * validation_data$risk_prob),
      status = validation_data$status,
      stringsAsFactors = FALSE
    )
    rbind(train_table, validation_table)
  }, striped = FALSE, bordered = FALSE, spacing = "s")
}

shinyApp(ui, server)
