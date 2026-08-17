# Shared test helper: locate the repo root and source the features module.
find_repo_root <- function() {
  d <- normalizePath(getwd(), winslash = "/")
  repeat {
    if (file.exists(file.path(d, "R", "features.R"))) return(d)
    nd <- dirname(d)
    if (identical(nd, d)) stop("R/features.R tidak ditemukan dari ", getwd())
    d <- nd
  }
}
source(file.path(find_repo_root(), "R", "features.R"), local = FALSE)
