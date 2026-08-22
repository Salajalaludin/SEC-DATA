make_state_loader <- function(commodity, app_dir, config) {
  raw <- data.frame(
    tanggal = as.Date("2026-01-01") + 0:1,
    pasar = "Harga rata-rata",
    komoditas = commodity,
    harga = c(10000, 11000),
    suhu_puncak = c(30, 31),
    kelembaban = c(80, 81),
    hujan = c(1, 0),
    sumber_iklim = "ERA5"
  )
  climate <- unique(raw[, c("tanggal", "suhu_puncak", "kelembaban", "hujan")])
  list(
    merged = raw,
    bmkg_forecast = NULL,
    climate = climate,
    climate_blended = transform(climate, sumber_iklim = "ERA5"),
    commodity = commodity,
    commodity_choices = c("Tomat", "Kentang"),
    source_label = "test",
    cache_metadata = list()
  )
}

make_state_pipeline <- function(raw, bmkg_forecast, forecast_horizon) {
  data <- transform(
    raw,
    sarima = harga,
    residual = 0,
    xgb_residual = 0,
    residual_hybrid = harga,
    distribution_stress_score = 0.2,
    status = "Aman"
  )
  list(
    data = data,
    forecast = data.frame(horizon = "H+1", harga = tail(raw$harga, 1)),
    live_forecast = data.frame(distribution_stress_score = 0.2),
    test = data.frame(),
    test_metrics = data.frame(),
    selected_model = paste0("model-", unique(raw$komoditas)),
    rolling_test_metrics = data.frame(),
    rolling_test_long = data.frame(),
    validation_metrics = data.frame(),
    final_test_metrics = data.frame(),
    stationarity_label = "test",
    sarima_label = "SARIMA test"
  )
}

state_test_config <- list(
  forecast_horizon = 3L,
  methodology_version = "Methodology V2"
)

test_that("dashboard state builder is Shiny-free and self-contained", {
  generated_at <- as.POSIXct("2026-08-22 10:00:00", tz = "UTC")
  state <- build_dashboard_state(
    "Tomat",
    app_dir = "unused",
    config = state_test_config,
    data_loader = make_state_loader,
    pipeline_builder = make_state_pipeline,
    generated_at = generated_at
  )

  expect_identical(state$commodity, "Tomat")
  expect_identical(state$freshness$generated_at, generated_at)
  expect_identical(state$freshness$methodology_version, "Methodology V2")
  expect_identical(state$freshness$model_identifier, "model-Tomat")
  expect_false(grepl("shiny::|input\\$|output\\$|session\\$", paste(deparse(body(build_dashboard_state)), collapse = " ")))
})

test_that("two state instances remain independent", {
  tomat <- build_dashboard_state(
    "Tomat", "unused", state_test_config,
    make_state_loader, make_state_pipeline
  )
  kentang <- build_dashboard_state(
    "Kentang", "unused", state_test_config,
    make_state_loader, make_state_pipeline
  )

  tomat$raw_data$harga[1] <- -1
  tomat$commodity <- "changed"

  expect_identical(kentang$commodity, "Kentang")
  expect_equal(kentang$raw_data$harga, c(10000, 11000))
  expect_identical(kentang$selected_model, "model-Kentang")
})

test_that("active Shiny code has no global session-state write", {
  files <- c(
    file.path(root, "cilegon_komoditas_shiny", "app.R"),
    list.files(file.path(root, "cilegon_komoditas_shiny", "modules"), pattern = "[.]R$", full.names = TRUE),
    file.path(root, "R", c("data_market.R", "pipeline.R", "explainability.R"))
  )
  code <- paste(unlist(lapply(files, readLines, warn = FALSE)), collapse = "\n")

  expect_false(grepl("\\.GlobalEnv", code))
  expect_false(grepl("<<-", code, fixed = TRUE))
  expect_false(grepl("assign\\s*\\(", code))
  expect_false(grepl("apply_dashboard_state", code, fixed = TRUE))
  expect_true(grepl("reactiveVal\\(bootstrap_snapshot\\)", code))
})

test_that("monitoring module sends namespaced refresh events", {
  skip_if_not_installed("shiny")
  source(file.path(root, "cilegon_komoditas_shiny", "modules", "mod_monitoring.R"), local = FALSE)
  calls <- new.env(parent = emptyenv())
  calls$commodities <- character()
  dates <- as.Date("2026-01-01") + 0:30
  raw <- rbind(
    data.frame(tanggal = dates, pasar = "Pasar A", harga = 10000 + seq_along(dates) * 10),
    data.frame(tanggal = dates, pasar = "Harga rata-rata", harga = 10000 + seq_along(dates) * 10)
  )
  raw$komoditas <- "Tomat"
  raw$suhu_puncak <- 29 + seq_len(nrow(raw)) %% 4
  raw$kelembaban <- 80
  raw$hujan <- 0
  raw$sumber_iklim <- "ERA5"
  pipeline_data <- transform(
    tail(raw[raw$pasar == "Harga rata-rata", ], 8),
    sarima = harga,
    residual = 0,
    xgb_residual = 0,
    residual_hybrid = harga,
    distribution_stress_score = 0.2,
    status = "Aman"
  )
  test_data <- data.frame(
    tanggal = tail(dates, 2),
    sumber_iklim = "ERA5",
    harga_aktual = c(10290, 10300),
    sarima = c(10280, 10290),
    xgb_residual = 0,
    prediksi_final = c(10280, 10290),
    error = 10,
    ape = 10 / c(10290, 10300)
  )
  monitoring_state <- list(
    commodity = "Tomat",
    source_label = "test",
    climate_latest = max(dates),
    climate_blended_latest = max(dates),
    bmkg_latest = max(dates),
    selected_model = "test",
    last_refresh_time = Sys.time(),
    raw_data = raw,
    pipeline_data = pipeline_data,
    test_data = test_data,
    current = tail(pipeline_data, 1),
    previous = pipeline_data[nrow(pipeline_data) - 1, ]
  )

  shiny::testServer(
    mod_monitoring_server,
    args = list(
      state = shiny::reactive(monitoring_state),
      refresh_dashboard = function(commodity) {
        calls$commodities <- c(calls$commodities, commodity)
        TRUE
      },
      refresh_interval_ms = 1e9
    ),
    {
      session$setInputs(commoditySelect = "Tomat")
      session$flushReact()
      session$setInputs(commoditySelect = "Kentang", refreshNow = 1)
      session$flushReact()
      expect_identical(tail(calls$commodities, 1), "Kentang")
    }
  )
})
