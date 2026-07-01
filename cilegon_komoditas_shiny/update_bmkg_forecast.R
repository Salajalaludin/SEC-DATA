suppressPackageStartupMessages({
  library(jsonlite)
})

app_file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- if (file.exists("cilegon_komoditas_shiny/update_bmkg_forecast.R")) "cilegon_komoditas_shiny/update_bmkg_forecast.R" else "update_bmkg_forecast.R"
app_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

bmkg_adm4 <- Sys.getenv("BMKG_ADM4", "36.72.07.1001")
forecast_days <- max(3L, as.integer(Sys.getenv("BMKG_FORECAST_DAYS", "4")))
cache_dir <- file.path(app_dir, "cache")
cache_path <- file.path(cache_dir, "bmkg_forecast_daily.rds")
api_url <- sprintf("https://api.bmkg.go.id/publik/prakiraan-cuaca?adm4=%s", bmkg_adm4)

safe_mode <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_character_)
  names(sort(table(x), decreasing = TRUE))[1]
}

flatten_cuaca <- function(cuaca_nested) {
  slots <- unlist(cuaca_nested, recursive = FALSE)
  rows <- lapply(slots, function(item) {
    data.frame(
      tanggal = as.Date(substr(item$local_datetime, 1, 10)),
      local_datetime = as.POSIXct(item$local_datetime, tz = "Asia/Jakarta"),
      suhu = as.numeric(item$t),
      kelembaban = as.numeric(item$hu),
      hujan = as.numeric(item$tp),
      weather_desc = as.character(item$weather_desc),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out[!is.na(out$tanggal), , drop = FALSE]
}

payload <- jsonlite::fromJSON(api_url, simplifyVector = FALSE)
if (length(payload$data) == 0) stop("Payload BMKG kosong.", call. = FALSE)

cuaca_hourly <- flatten_cuaca(payload$data[[1]]$cuaca)
if (!is.data.frame(cuaca_hourly) || nrow(cuaca_hourly) == 0) stop("Data cuaca BMKG kosong.", call. = FALSE)

today_local <- as.Date(Sys.time(), tz = "Asia/Bangkok")
future_limit <- today_local + forecast_days
cuaca_hourly <- cuaca_hourly[cuaca_hourly$tanggal >= today_local & cuaca_hourly$tanggal <= future_limit, , drop = FALSE]
if (nrow(cuaca_hourly) == 0) stop("Tidak ada prakiraan BMKG pada horizon yang diminta.", call. = FALSE)

dates <- sort(unique(cuaca_hourly$tanggal))
daily <- data.frame(
  tanggal = dates,
  suhu_puncak = as.numeric(tapply(cuaca_hourly$suhu, cuaca_hourly$tanggal, max, na.rm = TRUE)[as.character(dates)]),
  kelembaban = as.numeric(tapply(cuaca_hourly$kelembaban, cuaca_hourly$tanggal, mean, na.rm = TRUE)[as.character(dates)]),
  hujan = as.numeric(tapply(cuaca_hourly$hujan, cuaca_hourly$tanggal, sum, na.rm = TRUE)[as.character(dates)]),
  weather_desc = vapply(split(cuaca_hourly$weather_desc, cuaca_hourly$tanggal), safe_mode, character(1)),
  stringsAsFactors = FALSE
)

dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  list(
    key = paste("bmkg-forecast", bmkg_adm4, min(daily$tanggal), max(daily$tanggal)),
    updated_at = Sys.time(),
    adm4 = bmkg_adm4,
    lokasi = payload$lokasi,
    data = daily
  ),
  cache_path
)

message("BMKG forecast updated: ", as.character(min(daily$tanggal)), " sampai ", as.character(max(daily$tanggal)))

