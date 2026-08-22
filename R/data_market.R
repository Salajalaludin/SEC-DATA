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
  files <- list.files(
    app_dir,
    pattern = "^Data komoditas .*\\.xlsx$",
    full.names = TRUE,
    ignore.case = TRUE
  )
  if (length(files) == 0) {
    fallback <- c(
      file.path(app_dir, "Data Pasar Kota Cilegon.xlsx"),
      file.path(dirname(app_dir), "Data Pasar Kota Cilegon.xlsx")
    )
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
    market <- rbind(
      market[, c("tanggal", "pasar", "komoditas", "harga")],
      avg[, c("tanggal", "pasar", "komoditas", "harga")]
    )
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

normalize_market_name <- function(sheet) {
  key <- tolower(gsub("\\s+", " ", trimws(sheet)))
  if (grepl("blok", key)) return("Pasar Blok F")
  if (grepl("merak", key)) return("Pasar Baru Merak")
  if (grepl("cilegon", key)) return("Pasar Baru Cilegon")
  sheet
}

read_market_data <- function(path, commodity_label = NULL) {
  sheet_names <- readxl::excel_sheets(path)
  market <- do.call(rbind, lapply(sheet_names, function(sheet) {
    dat <- readxl::read_excel(path, sheet = sheet)
    commodity_col <- find_col(dat, c("komoditas", "commodity"))
    komoditas <- if (!is.null(commodity_col)) as.character(dat[[commodity_col]]) else commodity_label
    if (is.null(komoditas) || all(is.na(komoditas) | !nzchar(komoditas))) {
      komoditas <- commodity_label_from_file(path)
    }
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
  rbind(
    market[, c("tanggal", "pasar", "komoditas", "harga")],
    avg[, c("tanggal", "pasar", "komoditas", "harga")]
  )
}

load_project_data <- function(commodity = NULL, app_dir, config = dashboard_config(app_dir)) {
  market_url <- Sys.getenv("REALTIME_MARKET_URL", "")
  climate_url <- Sys.getenv("REALTIME_CLIMATE_URL", "")
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
  if (nzchar(market_url)) market_live <- read_market_csv(market_url)
  if (is.null(market_live)) market_live <- read_market_cache(market_cache_path)
  if ("komoditas" %in% names(market_live)) {
    keep <- tolower(trimws(market_live$komoditas)) == tolower(trimws(commodity)) |
      is.na(market_live$komoditas) |
      !nzchar(trimws(market_live$komoditas))
    market_live <- market_live[keep, , drop = FALSE]
  }
  market <- merge_market_sources(market_base, market_live, commodity)
  if (is.null(market) || !is.data.frame(market) || nrow(market) == 0) {
    stop("Data harga komoditas tidak tersedia.", call. = FALSE)
  }
  if (!"Harga rata-rata" %in% market$pasar) {
    avg <- aggregate(harga ~ tanggal, market, mean, na.rm = TRUE)
    avg$pasar <- "Harga rata-rata"
    avg$komoditas <- commodity
    market <- rbind(
      market[, c("tanggal", "pasar", "komoditas", "harga")],
      avg[, c("tanggal", "pasar", "komoditas", "harga")]
    )
  }
  market$komoditas <- commodity
  market <- market[order(market$tanggal, market$pasar), ]
  start_date <- min(market$tanggal, na.rm = TRUE)
  end_date <- max(market$tanggal, na.rm = TRUE)

  climate <- if (nzchar(climate_url)) read_climate_csv(climate_url) else NULL
  if (!valid_climate_frame(climate)) climate <- read_climate_cache(cache_path)
  if (!valid_climate_frame(climate)) climate <- read_climate_cache(fallback_cache_path)

  gdrive_id <- Sys.getenv("GDRIVE_RDS_ID", "")
  if (!valid_climate_frame(climate) && nzchar(gdrive_id) && !file.exists(cache_path)) {
    gd_url <- sprintf("https://drive.google.com/uc?export=download&id=%s", gdrive_id)
    dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
    tryCatch({
      utils::download.file(gd_url, cache_path, mode = "wb", quiet = TRUE)
      cache_obj <- tryCatch(readRDS(cache_path), error = function(e) NULL)
      if (is.list(cache_obj) && !is.null(cache_obj$data) && valid_climate_frame(cache_obj$data)) {
        climate <- cache_obj$data
      } else if (is.data.frame(cache_obj) && valid_climate_frame(cache_obj)) {
        climate <- cache_obj
      }
    }, error = function(e) {
      warning("Gagal mengunduh atau membaca RDS dari Google Drive: ", conditionMessage(e))
      if (file.exists(cache_path)) try(unlink(cache_path), silent = TRUE)
    })
  }

  if (!valid_climate_frame(climate)) {
    era5_dir <- NULL
    for (path in era5_dir_candidates) {
      if (dir.exists(path) || file.exists(path)) {
        era5_dir <- path
        break
      }
    }
    if (!is.null(era5_dir)) {
      climate <- tryCatch(
        read_era5_daily(era5_dir, start_date, end_date, cache_path, config$era5_extent),
        error = function(e) {
          warning("Gagal baca ERA5 lokal: ", conditionMessage(e))
          NULL
        }
      )
    }
  }

  if (!valid_climate_frame(climate)) {
    dates <- seq.Date(start_date, end_date, by = "day")
    climate <- data.frame(
      tanggal = dates,
      suhu_puncak = NA_real_,
      kelembaban = NA_real_,
      hujan = NA_real_
    )
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
    },
    cache_metadata = list(
      raw_market = list(path = market_cache_path, generated_at = if (file.exists(market_cache_path)) file.info(market_cache_path)$mtime else as.POSIXct(NA)),
      climate = list(path = cache_path, generated_at = if (file.exists(cache_path)) file.info(cache_path)$mtime else as.POSIXct(NA)),
      forecast = list(path = bmkg_cache_path, generated_at = if (file.exists(bmkg_cache_path)) file.info(bmkg_cache_path)$mtime else as.POSIXct(NA))
    )
  )
}
