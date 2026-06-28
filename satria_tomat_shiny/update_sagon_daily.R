suppressPackageStartupMessages({
  library(xml2)
  library(rvest)
})

app_file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- if (file.exists("satria_tomat_shiny/update_sagon_daily.R")) "satria_tomat_shiny/update_sagon_daily.R" else "update_sagon_daily.R"
app_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

base_url <- sub("/+$", "", Sys.getenv("SAGON_BASE_URL", "https://sagon.cilegon.go.id"))
cache_dir <- file.path(app_dir, "cache")
cache_path <- file.path(cache_dir, "sagon_daily_long.rds")

normalize_market_name <- function(x) {
  key <- tolower(gsub("\\s+", " ", trimws(x)))
  if (grepl("blok", key)) return("Pasar Blok F")
  if (grepl("merak", key)) return("Pasar Baru Merak")
  if (grepl("cilegon", key)) return("Pasar Baru Cilegon")
  if (grepl("rata", key) || grepl("semua", key)) return("Harga rata-rata")
  x
}

normalize_commodity_name <- function(x) {
  x <- gsub("\\s+", " ", trimws(x))
  if (!nzchar(x)) return(NA_character_)
  tools::toTitleCase(tolower(x))
}

parse_local_date <- function(x) {
  x <- trimws(gsub("\\s+", " ", x))
  if (!nzchar(x)) return(as.Date(NA))
  x <- sub("^[^0-9]*", "", x)
  bulan_id <- c(
    januari = "01", februari = "02", maret = "03", april = "04", mei = "05", juni = "06",
    juli = "07", agustus = "08", september = "09", oktober = "10", november = "11", desember = "12"
  )
  lower <- tolower(x)
  hit <- regexec("([0-9]{1,2})\\s+([[:alpha:]]+)\\s+(20[0-9]{2})", lower, perl = TRUE)
  m <- regmatches(lower, hit)[[1]]
  if (length(m) != 4) return(as.Date(NA))
  bulan <- bulan_id[[m[[3]]]]
  if (is.null(bulan)) return(as.Date(NA))
  iso <- sprintf("%s-%s-%02d", m[[4]], bulan, as.integer(m[[2]]))
  as.Date(iso)
}

extract_page_date <- function(html) {
  candidates <- c(
    html %>% html_elements("h4, .section-header, p") %>% html_text2(),
    html %>% html_elements("body") %>% html_text2()
  )
  candidates <- unique(trimws(candidates))
  hit <- grep("[0-9]{1,2}\\s+[A-Za-z]+\\s+20[0-9]{2}", candidates, value = TRUE)
  if (length(hit) == 0) return(as.Date(NA))
  parsed <- as.Date(vapply(hit, function(txt) as.character(parse_local_date(txt)), character(1)))
  parsed <- parsed[!is.na(parsed)]
  if (length(parsed) == 0) as.Date(NA) else max(parsed)
}

parse_price_text <- function(x) {
  x <- trimws(x)
  if (!nzchar(x)) return(NA_real_)
  numeric_part <- gsub("[^0-9]", "", x)
  if (!nzchar(numeric_part)) return(NA_real_)
  as.numeric(numeric_part)
}

extract_price_cards <- function(html) {
  cards <- html %>% html_elements(".product-item")
  out <- lapply(cards, function(card) {
    komoditas <- card %>% html_element("a[class*='h']") %>% html_text2()
    harga_text <- card %>% html_element("span.text-dark") %>% html_text2()
    harga_num <- parse_price_text(harga_text)
    if (is.na(harga_num) || !nzchar(trimws(komoditas))) return(NULL)
    data.frame(
      komoditas = normalize_commodity_name(komoditas),
      harga = harga_num,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, out)
  if (is.null(out) || nrow(out) == 0) return(NULL)
  out[!is.na(out$komoditas) & !is.na(out$harga), , drop = FALSE]
}

scrape_sagon_page <- function(path, market_name) {
  url <- paste0(base_url, path)
  html <- read_html(url)
  page_date <- extract_page_date(html)
  dat <- extract_price_cards(html)
  if (!is.data.frame(dat) || nrow(dat) == 0) stop("Tidak menemukan kartu harga valid pada ", url, call. = FALSE)
  dat$tanggal <- page_date
  dat$pasar <- normalize_market_name(market_name)
  dat$sumber <- url
  dat <- unique(dat[, c("tanggal", "pasar", "komoditas", "harga", "sumber")])
  dat[!is.na(dat$tanggal) & !is.na(dat$harga), ]
}

safe_read_cache <- function(path) {
  if (!file.exists(path)) return(NULL)
  tryCatch(readRDS(path), error = function(e) NULL)
}

pages <- list(
  "/" = "Harga rata-rata",
  "/pasarcilegon" = "Pasar Baru Cilegon",
  "/pasarblokf" = "Pasar Blok F",
  "/pasarmerak" = "Pasar Baru Merak"
)

chunks <- lapply(names(pages), function(path) {
  tryCatch(
    scrape_sagon_page(path, pages[[path]]),
    error = function(e) {
      message("Gagal scrape ", path, ": ", conditionMessage(e))
      NULL
    }
  )
})
chunks <- Filter(function(x) is.data.frame(x) && nrow(x) > 0, chunks)

if (length(chunks) == 0) stop("Tidak ada data SAGON yang berhasil di-scrape.", call. = FALSE)

latest <- do.call(rbind, chunks)
existing <- safe_read_cache(cache_path)
if (is.list(existing) && !is.null(existing$data)) existing <- existing$data

merged <- if (is.data.frame(existing) && nrow(existing) > 0) {
  combined <- rbind(existing, latest)
  combined <- combined[!duplicated(combined[, c("tanggal", "pasar", "komoditas")], fromLast = TRUE), ]
  combined
} else {
  latest
}

merged <- merged[order(merged$tanggal, merged$pasar, merged$komoditas), ]
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  list(
    key = paste("sagon-update", min(merged$tanggal, na.rm = TRUE), max(merged$tanggal, na.rm = TRUE)),
    updated_at = Sys.time(),
    data = merged
  ),
  cache_path
)

message("SAGON updated: ", as.character(min(latest$tanggal, na.rm = TRUE)), " sampai ", as.character(max(latest$tanggal, na.rm = TRUE)))
