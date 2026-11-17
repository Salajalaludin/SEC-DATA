# ERA5 NetCDF I/O (Methodology V2).
#
# This module is used by the local ERA5 updater and cache rebuild scripts.
# It is intentionally excluded from the shinyapps.io cache-only bundle so the
# hosted app does not require the native GDAL/terra build toolchain.

as_era5_extent <- function(extent) {
  if (inherits(extent, "SpatExtent")) return(extent)
  values <- as.numeric(extent)
  if (length(values) != 4L || anyNA(values)) {
    stop("Extent ERA5 harus berisi xmin, xmax, ymin, ymax.", call. = FALSE)
  }
  terra::ext(values[[1]], values[[2]], values[[3]], values[[4]])
}

#' Read one ERA5 variable from a NetCDF file and return a value per layer.
#'
#' @param path character, path to NetCDF file.
#' @param subds character, subdataset name ("t2m", "d2m", "tp").
#' @param extent SpatExtent or numeric xmin/xmax/ymin/ymax extent.
#' @param fun character, spatial aggregation function (default "mean").
#' @return data.frame with columns valid_time (POSIXct UTC) and value.
read_era5_variable <- function(path, subds, extent, fun = "mean") {
  extent <- as_era5_extent(extent)
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

#' Read one ERA5 NetCDF file into timestamp-aligned hourly observations.
#'
#' t2m/d2m/tp are aligned by exact valid_time, relative humidity is computed
#' from timestamp-matched temperature and dewpoint, and the local calendar date
#' is derived only after alignment. No daily aggregation is performed here.
#'
#' @param path character, path to NetCDF file.
#' @param extent SpatExtent or numeric extent (default era5_config()$extent).
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
#' @param extent SpatExtent or numeric extent (default era5_config()$extent).
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
