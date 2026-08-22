# Shared test helper: locate the repo root and source the modules.
find_repo_root <- function() {
  d <- normalizePath(getwd(), winslash = "/")
  repeat {
    if (file.exists(file.path(d, "R", "features.R"))) return(d)
    nd <- dirname(d)
    if (identical(nd, d)) stop("R/features.R tidak ditemukan dari ", getwd())
    d <- nd
  }
}
root <- find_repo_root()
suppressPackageStartupMessages(library(xgboost))
source(file.path(root, "R", "features.R"), local = FALSE)
source(file.path(root, "R", "evaluation.R"), local = FALSE)
source(file.path(root, "R", "model_risk.R"), local = FALSE)

#' Small synthetic "Harga rata-rata" frame with features for evaluation tests.
make_synthetic_avg <- function(n = 100, start = as.Date("2023-01-25")) {
  set.seed(7)
  df <- data.frame(
    tanggal = start + 0:(n - 1),
    harga = round(10000 + cumsum(rnorm(n, 0, 250)), 0),
    suhu_puncak = 28 + 3 * sin(2 * pi * (1:n) / 7) + rnorm(n, 0, 0.5),
    kelembaban = pmax(50, pmin(95, 80 + 5 * sin(2 * pi * (1:n) / 30) + rnorm(n, 0, 2))),
    hujan = pmax(0, rgamma(n, 1, 0.5)),
    margin_hl = pmax(0, abs(rnorm(n, 500, 300))),
    sumber_iklim = "ERA5"
  )
  build_training_features(df)
}
