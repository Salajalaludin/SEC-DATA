mod_evaluation_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::fluidRow(
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("In-app final test preview (bounded)", class = "section-title"),
          shiny::div("Blok terbaru tetap untouched, tetapi app memakai eval_config() bounded defaults (2 fold, minimum 14 hari). Canonical full-protocol metrics ada di docs/EVALUATION_PROTOCOL.md.", class = "section-subtitle"),
          shiny::tableOutput(ns("testMetrics"))
        )
      ),
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Rolling-origin validation", class = "section-title"),
          shiny::div("Fold validasi expanding-window; model di-refit ulang di setiap origin memakai histori sampai t-1 (bukan fit sekali di blok awal)", class = "section-subtitle"),
          shiny::tableOutput(ns("rollingTestMetrics"))
        )
      )
    ),
    shiny::div(
      class = "card",
      shiny::div("In-app final-test APE per model", class = "section-title"),
      shiny::div("Absolute percentage error per tanggal untuk preview bounded app; full-protocol artifacts tetap menjadi rujukan metrik final", class = "section-subtitle"),
      shiny::plotOutput(ns("rollingTestPlot"), height = 300)
    ),
    shiny::div(
      class = "card",
      shiny::div("Konfigurasi XGBoost residual", class = "section-title"),
      shiny::div("Parameter tetap dipakai agar alur hanya terdiri dari training, test, dan prediksi", class = "section-subtitle"),
      shiny::tableOutput(ns("tuningTable"))
    ),
    shiny::div(
      class = "card",
      shiny::div("Catatan metodologi", class = "section-title"),
      shiny::div("Jawaban ringkas untuk menjelaskan data, split, dan rolling forecast", class = "section-subtitle"),
      shiny::div(
        class = "note-grid",
        shiny::div(class = "note-item", shiny::HTML("<b>Data SAGON</b><br>Harga diperoleh dengan scraping halaman publik SAGON Cilegon memakai script <code>update_sagon_daily.R</code>. Hasil scraping disimpan sebagai cache <code>sagon_daily_long.rds</code>, lalu app membaca cache tersebut.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Data iklim</b><br>ERA5 diambil via CDS API sebagai data jam-jaman, lalu diagregasi harian: suhu puncak = maksimum harian, kelembaban = rata-rata harian, dan hujan = total harian. BMKG dipakai untuk prakiraan H+1 sampai H+3.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Evaluasi</b><br>Data diurutkan kronologis lalu dibagi: periode development -> rolling-origin validation -> final test (blok terbaru) yang tidak disentuh. Konfigurasi ada di <code>eval_config()</code> di <code>R/evaluation.R</code>.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Rolling one-step (refit)</b><br>Untuk tiap hari: model di-fit ulang pada histori yang tersedia sampai t-1, prediksi satu langkah, aktual diungkap, lalu ditambahkan ke histori. SARIMA benar-benar memakai histori terbaru. Baseline (Naive, Seasonal Naive 7, MA7) memakai informasi yang sama per origin.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Preprocessing</b><br>Handling dilakukan melalui merge tanggal, penghapusan baris iklim/harga yang tidak lengkap, deduplikasi tanggal-pasar-komoditas, serta fitur lag, moving average 7 hari, volatilitas 7 hari, margin pasar, hari, dan bulan.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Model utama</b><br>Champion adalah kandidat dengan WAPE rolling-validation terendah. Pilihan dibekukan sebelum final test dan dipakai oleh forecast live.")),
        shiny::div(class = "note-item", shiny::HTML("<b>SARIMA</b><br>Orde dipilih otomatis oleh <code>forecast::auto.arima()</code> setelah pembacaan kebutuhan differencing ADF/KPSS dan seasonal differencing. Label orde SARIMA ditampilkan di alur model.")),
        shiny::div(class = "note-item", shiny::HTML("<b>XGBoost</b><br>Regresi XGBoost memakai parameter tetap: max_depth 3, eta 0.05, nrounds 120, subsample 0.9, dan colsample_bytree 0.9. Tidak ada cross-validation/early stopping agar alurnya tetap training-test-prediksi.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Persamaan</b><br>Residual SARIMA: e_t = Y_t - SARIMA_t. Kandidat residual adalah max(0, SARIMA + prediksi XGBoost residual). XGBoost Direct tetap kandidat terpisah; tidak ada blend atau koreksi manual.")),
        shiny::div(class = "note-item", shiny::HTML("<b>SHAP</b><br>SHAP regresi dibaca sebagai contribution to forecast/model prediction. SHAP risk dibaca sebagai contribution to Distribution Stress Score. Keduanya bersifat associational, bukan causal."))
      )
    )
  )
}

mod_evaluation_server <- function(id, state) {
  shiny::moduleServer(id, function(input, output, session) {
    output$testMetrics <- shiny::renderTable({
      snapshot <- state()
      shiny::req(snapshot)
      shown <- snapshot$test_metrics
      shown$peran <- ifelse(shown$model == snapshot$selected_model, "champion validasi", "kandidat")
      shown$model_key <- NULL
      shown$MAE <- rupiah(shown$MAE)
      shown$RMSE <- rupiah(shown$RMSE)
      shown$WAPE <- sprintf("%.2f%%", 100 * shown$WAPE)
      shown$MAPE <- sprintf("%.2f%%", 100 * shown$MAPE)
      names(shown)[names(shown) == "MAE"] <- "MAE (Rp)"
      names(shown)[names(shown) == "RMSE"] <- "RMSE (Rp)"
      names(shown)[names(shown) == "WAPE"] <- "WAPE (%)"
      names(shown)[names(shown) == "MAPE"] <- "MAPE (%)"
      shown
    }, striped = FALSE, bordered = FALSE, spacing = "s")

    output$rollingTestMetrics <- shiny::renderTable({
      snapshot <- state()
      shiny::req(snapshot)
      shown <- snapshot$rolling_test_metrics
      shown$peran <- ifelse(shown$model == snapshot$selected_model, "champion", "kandidat")
      shown$model_key <- NULL
      shown$MAE <- rupiah(shown$MAE)
      shown$RMSE <- rupiah(shown$RMSE)
      shown$WAPE <- sprintf("%.2f%%", 100 * shown$WAPE)
      shown$MAPE <- sprintf("%.2f%%", 100 * shown$MAPE)
      names(shown)[names(shown) == "MAE"] <- "MAE (Rp)"
      names(shown)[names(shown) == "RMSE"] <- "RMSE (Rp)"
      names(shown)[names(shown) == "WAPE"] <- "WAPE (%)"
      names(shown)[names(shown) == "MAPE"] <- "MAPE (%)"
      shown
    }, striped = FALSE, bordered = FALSE, spacing = "s")

    output$rollingTestPlot <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$rolling_test_long, ggplot2::aes(tanggal, 100 * ape, color = model)) +
        ggplot2::geom_line(linewidth = 0.8, alpha = 0.85) +
        ggplot2::geom_point(size = 1.2, alpha = 0.7) +
        ggplot2::scale_color_manual(values = c(
          "Naive" = "#8a8c84",
          "Seasonal Naive 7" = "#c9b8ff",
          "MA7" = "#61c9a8",
          "SARIMA" = "#b2a7ff",
          "XGBoost Direct" = "#ffd0a0",
          "SARIMA + XGBoost Residual" = "#f5a623"
        )) +
        ggplot2::labs(title = "In-app final-test APE (bounded)", x = "Tanggal", y = "APE (%)", color = NULL) +
        theme_dark_cilegon()
    })

    output$tuningTable <- shiny::renderTable({
      snapshot <- state()
      shiny::req(snapshot)
      data.frame(
        parameter = c("max_depth", "eta", "nrounds"),
        nilai = c(snapshot$xgb_config$max_depth, snapshot$xgb_config$eta, snapshot$xgb_config$nrounds)
      )
    }, striped = FALSE, bordered = FALSE, spacing = "s")
  })
}
