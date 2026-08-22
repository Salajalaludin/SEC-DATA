mod_risk_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::column(
    5,
    shiny::div(
      class = "card",
      shiny::div("Panel early warning", class = "section-title"),
      shiny::div("Skor Risiko Tekanan Distribusi (proxy)", class = "section-subtitle"),
      shiny::uiOutput(ns("warningBox")),
      shiny::tags$hr(),
      shiny::tableOutput(ns("policyTable"))
    )
  )
}

mod_risk_server <- function(id, state) {
  shiny::moduleServer(id, function(input, output, session) {
    output$warningBox <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      scores <- as.numeric(snapshot$live_forecast_data$distribution_stress_score)
      if (!any(is.finite(scores))) {
        return(shiny::HTML("<p style='color:#ffd573;'>Skor Risiko Tekanan Distribusi belum tersedia untuk forecast ini.</p>"))
      }
      risk_3day <- max(scores, na.rm = TRUE)
      status <- map_stress_status(risk_3day, snapshot$stress_thresholds)
      threshold_values <- snapshot$stress_thresholds$values
      band_text <- sprintf(
        "Band: Aman < %.0f/100; Waspada %.0f sampai < %.0f/100; Darurat >= %.0f/100.",
        100 * threshold_values[["waspada"]],
        100 * threshold_values[["waspada"]],
        100 * threshold_values[["darurat"]],
        100 * threshold_values[["darurat"]]
      )
      forecast_sources <- if ("sumber_iklim" %in% names(snapshot$live_forecast_data)) {
        unique(as.character(snapshot$live_forecast_data$sumber_iklim))
      } else {
        "source not recorded"
      }
      forecast_sources <- forecast_sources[!is.na(forecast_sources) & nzchar(forecast_sources)]
      if (length(forecast_sources) == 0) forecast_sources <- "source not recorded"
      shiny::HTML(sprintf(
        "<div class='status-pill %s'>%s</div><p style='margin-top:12px;color:#f5f2e8;font-weight:700;'>Skor Risiko Tekanan Distribusi tertinggi %.0f/100 pada prediksi H+1 sampai H+3</p><p style='color:#c8c7bc;'>%s Champion validasi: <b>%s</b>. Sumber iklim forecast: <b>%s</b>. Ini adalah sinyal turunan model berbasis proxy, bukan probabilitas kejadian nyata teramati.</p>",
        status,
        status,
        100 * risk_3day,
        band_text,
        snapshot$selected_model,
        paste(forecast_sources, collapse = ", ")
      ))
    })

    output$policyTable <- shiny::renderTable({
      state()
      data.frame(
        Status = c("Aman", "Waspada", "Darurat"),
        Makna = c("Band skor proxy rendah", "Band skor proxy menengah", "Band skor proxy tinggi"),
        Tindakan = c(
          "Monitoring harian harga, pasar, dan cuaca",
          "Verifikasi stok/pasokan dan koordinasi distributor",
          "Eskalasi pemantauan, cek lapangan, siapkan opsi operasi pasar"
        )
      )
    }, striped = FALSE, bordered = FALSE, spacing = "s")
  })
}
