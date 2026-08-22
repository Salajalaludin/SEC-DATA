suppressPackageStartupMessages({
  library(shiny)
  library(ggplot2)
  library(readxl)
  library(terra)
  library(forecast)
  library(xgboost)
})

set.seed(2026)

app_file_arg <- if (file.exists("cilegon_komoditas_shiny/app.R")) {
  "cilegon_komoditas_shiny/app.R"
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
if (is.na(app_file_arg) || !nzchar(app_file_arg)) app_file_arg <- "app.R"
app_start_dir <- dirname(normalizePath(app_file_arg, winslash = "/", mustWork = FALSE))
app_renviron <- file.path(app_start_dir, ".Renviron")
if (file.exists(app_renviron)) readRenviron(app_renviron)

source_project_file <- function(relative_path) {
  candidates <- unique(c(
    file.path(dirname(app_start_dir), relative_path),
    file.path(app_start_dir, relative_path),
    file.path(getwd(), relative_path)
  ))
  hit <- candidates[file.exists(candidates)]
  if (length(hit) == 0) stop("File project tidak ditemukan: ", relative_path, call. = FALSE)
  source(hit[[1]], local = FALSE)
}

repo_modules <- c(
  "R/config.R",
  "R/utils.R",
  "R/data_climate.R",
  "R/data_market.R",
  "R/features.R",
  "R/model_risk.R",
  "R/evaluation.R",
  "R/explainability.R",
  "R/pipeline.R"
)
app_modules <- file.path("modules", c(
  "mod_monitoring.R",
  "mod_forecast.R",
  "mod_risk.R",
  "mod_evaluation.R",
  "mod_shap.R"
))
invisible(lapply(c(repo_modules, app_modules), source_project_file))

config <- dashboard_config(app_start_dir)
commodity_files <- discover_commodity_files(app_start_dir)
tomato_index <- grep("^Tomat$", names(commodity_files), ignore.case = TRUE)
initial_commodity <- if (length(tomato_index) > 0) {
  names(commodity_files)[tomato_index[[1]]]
} else {
  names(commodity_files)[[1]]
}

# Immutable bootstrap artifact. Each session owns the reactive container that
# receives this snapshot and replaces it independently on refresh.
bootstrap_snapshot <- build_dashboard_state(initial_commodity, app_start_dir, config)

ui <- fluidPage(
  tags$head(
    tags$title("Dashboard Tomat Cilegon"),
    tags$meta(name = "theme-color", content = "#1f201e"),
    tags$meta(name = "color-scheme", content = "dark"),
    tags$link(rel = "stylesheet", type = "text/css", href = "app.css")
  ),
  h1("Dashboard ketahanan pangan Cilegon", class = "app-title"),
  div(
    "Monitoring harga dan Cilegon Local Climate",
    class = "app-subtitle"
  ),
  tabsetPanel(
    tabPanel(
      "Dashboard",
      mod_monitoring_ui(
        "monitoring",
        bootstrap_snapshot$commodity_choices,
        bootstrap_snapshot$commodity
      ),
      fluidRow(mod_forecast_ui("forecast"), mod_risk_ui("risk"))
    ),
    tabPanel("Alur Model", mod_forecast_flow_ui("forecast")),
    tabPanel("Evaluasi Model", mod_evaluation_ui("evaluation")),
    tabPanel("Interpretasi SHAP", mod_shap_ui("shap")),
    tabPanel("Data", mod_monitoring_data_ui("monitoring"))
  )
)

server <- function(input, output, session) {
  state <- reactiveVal(bootstrap_snapshot)

  refresh_dashboard <- function(commodity_value = NULL) {
    previous_state <- isolate(state())
    if (is.null(commodity_value) || !nzchar(commodity_value)) {
      commodity_value <- previous_state$commodity
    }
    tryCatch({
      next_state <- build_dashboard_state(commodity_value, app_start_dir, config)
      state(next_state)
      showNotification("Data realtime berhasil diperbarui.", type = "message", duration = 3)
      invisible(TRUE)
    }, error = function(e) {
      showNotification(
        paste("Refresh gagal:", conditionMessage(e)),
        type = "error",
        duration = 7
      )
      invisible(FALSE)
    })
  }

  mod_monitoring_server(
    "monitoring",
    state,
    refresh_dashboard,
    config$refresh_interval_ms
  )
  mod_forecast_server("forecast", state)
  mod_risk_server("risk", state)
  mod_evaluation_server("evaluation", state)
  mod_shap_server("shap", state)
}

shinyApp(ui, server)
