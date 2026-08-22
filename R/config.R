FORECAST_HORIZON <- 3L
DEFAULT_REFRESH_INTERVAL_MS <- 86400000L
METHODOLOGY_VERSION <- "Methodology V2"

dashboard_config <- function(app_dir) {
  list(
    app_dir = normalizePath(app_dir, winslash = "/", mustWork = FALSE),
    era5_extent = era5_config()$extent,
    forecast_horizon = FORECAST_HORIZON,
    refresh_interval_ms = as.integer(Sys.getenv(
      "REFRESH_INTERVAL_MS",
      as.character(DEFAULT_REFRESH_INTERVAL_MS)
    )),
    methodology_version = METHODOLOGY_VERSION
  )
}
