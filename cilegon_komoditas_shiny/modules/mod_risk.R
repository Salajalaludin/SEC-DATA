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
      risk_3day <- max(snapshot$live_forecast_data$distribution_stress_score, na.rm = TRUE)
      status <- map_stress_status(risk_3day, snapshot$stress_thresholds)
      threshold_values <- snapshot$stress_thresholds$values
      band_text <- sprintf(
        "Band: Aman < %.0f/100; Waspada %.0f sampai < %.0f/100; Darurat >= %.0f/100.",
        100 * threshold_values[["waspada"]],
        100 * threshold_values[["waspada"]],
        100 * threshold_values[["darurat"]],
        100 * threshold_values[["darurat"]]
      )
      test_mape <- mean(snapshot$test_data$ape, na.rm = TRUE)
      shiny::HTML(sprintf(
        "<div class='status-pill %s'>%s</div><p style='margin-top:12px;color:#f5f2e8;font-weight:700;'>Skor Risiko Tekanan Distribusi tertinggi %.0f/100 pada prediksi H+1 sampai H+3</p><p style='color:#c8c7bc;'>%s Model utama: <b>%s</b>. MAPE final test: <b>%.1f%%</b>. Prediksi 3 hari ke depan memakai prakiraan BMKG. Ini adalah sinyal turunan model berbasis proxy, bukan probabilitas kejadian nyata teramati.</p>",
        status,
        status,
        100 * risk_3day,
        band_text,
        snapshot$selected_model,
        100 * test_mape
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
