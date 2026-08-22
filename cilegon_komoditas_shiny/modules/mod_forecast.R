mod_forecast_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::column(
    7,
    shiny::div(
      class = "card",
      shiny::div("Panel prediksi", class = "section-title"),
      shiny::uiOutput(ns("forecastSubtitle")),
      shiny::plotOutput(ns("forecastPlot"), height = 265)
    )
  )
}

mod_forecast_flow_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::div(
      class = "card",
      shiny::div("Pipeline SARIMA-XGBoost-SHAP", class = "section-title"),
      shiny::div("Tahap 1 sampai 8 sesuai alur penelitian dan dashboard kebijakan", class = "section-subtitle"),
      shiny::p(
        class = "flow-narrative",
        "Alur dimulai dari pengumpulan harga tomat harian SAGON Cilegon dan data iklim ERA5. ",
        "Keduanya dibersihkan lalu digabung berdasarkan tanggal agar setiap observasi memiliki pasangan harga, suhu, kelembaban, dan hujan pada hari yang sama. ",
        "Harga rata-rata kemudian diuji stasioneritasnya dengan ADF/KPSS; jika belum stasioner, komponen differencing dipilih melalui proses SARIMA. ",
        "SARIMA menangkap pola autokorelasi dan musiman, sedangkan residual epsilon yang tersisa dipakai sebagai target XGBoost regresi untuk menangkap pola non-linear."
      ),
      shiny::div(
        class = "flow-grid",
        shiny::div(class = "flow-box price", shiny::strong("Tahap 1 - SAGON Cilegon"), "Harga tomat harian dari tiga pasar."),
        shiny::div(class = "flow-box climate", shiny::strong("Tahap 1 - ERA5 Reanalysis"), "Suhu, kelembaban, dan hujan Cilegon Local Climate."),
        shiny::div(class = "flow-box", shiny::strong("Tahap 2 - Pra-pemrosesan"), "Cleaning dan merge berdasarkan tanggal yang sama."),
        shiny::uiOutput(ns("stationarityStep")),
        shiny::uiOutput(ns("sarimaStep")),
        shiny::div(class = "flow-box", shiny::strong("Tahap 5 - Rekayasa fitur"), "Suhu, harga, dan kalender digabung sebagai prediktor."),
        shiny::div(class = "flow-box xgb", shiny::strong("Tahap 6 - XGBoost regresi"), "Residual SARIMA dan harga langsung dimodelkan sebagai dua kandidat terpisah."),
        shiny::div(class = "flow-box shap", shiny::strong("Tahap 6 - XGBoost klasifikasi"), "Model independen untuk skor tekanan berbasis proxy."),
        shiny::div(class = "flow-box shap", shiny::strong("Tahap 7 - SHAP regresi"), "Kontribusi fitur terhadap forecast/model prediction."),
        shiny::div(class = "flow-box shap", shiny::strong("Tahap 7 - SHAP klasifikasi"), "Kontribusi fitur terhadap Distribution Stress Score."),
        shiny::div(class = "flow-box policy", shiny::strong("Tahap 8 - Dashboard"), "Monitoring, prediksi, dan early warning."),
        shiny::div(class = "flow-box policy", shiny::strong("Output"), "Rekomendasi kebijakan intervensi Pemkot Cilegon.")
      )
    ),
    shiny::div(
      class = "card",
      shiny::div("Keterkaitan teknis dashboard", class = "section-title"),
      shiny::div("Tiga panel memakai sumber data yang sama, tetapi menjawab kebutuhan keputusan yang berbeda", class = "section-subtitle"),
      shiny::div(
        class = "explain-grid",
        shiny::div(
          class = "explain-item",
          shiny::tags$b("Panel monitoring"),
          "Memakai data hasil cleaning dan merge untuk memperlihatkan tren harga tiga pasar bersama suhu puncak harian. Panel ini menjadi konteks operasional: apakah kenaikan harga bergerak bersamaan dengan kondisi panas."
        ),
        shiny::div(
          class = "explain-item",
          shiny::tags$b("Panel prediksi"),
          "Memakai kandidat dengan WAPE rolling-validation terendah. SARIMA, XGBoost Direct, dan SARIMA + XGBoost Residual tetap memiliki jalur prediksi yang terpisah."
        ),
        shiny::div(
          class = "explain-item",
          shiny::tags$b("Panel early warning"),
          "Memakai XGBoost klasifikasi untuk mengubah fitur suhu, harga, dan kalender menjadi skor tekanan berbasis proxy. Skor itu diterjemahkan ke status Aman, Waspada, atau Darurat sebagai panduan monitoring dan eskalasi."
        )
      )
    ),
    shiny::fluidRow(
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Diagnostik residual SARIMA", class = "section-title"),
          shiny::uiOutput(ns("residualSubtitle")),
          shiny::plotOutput(ns("residualPlot"), height = 260)
        )
      ),
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Gambar kandidat residual SARIMA-XGBoost", class = "section-title"),
          shiny::div("Champion operasional dipilih dari seluruh kandidat melalui rolling-validation", class = "section-subtitle"),
          shiny::plotOutput(ns("hybridPlot"), height = 260)
        )
      )
    )
  )
}

mod_forecast_server <- function(id, state) {
  shiny::moduleServer(id, function(input, output, session) {
    output$forecastSubtitle <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      sources <- if ("sumber_iklim" %in% names(snapshot$forecast_data)) {
        unique(as.character(snapshot$forecast_data$sumber_iklim[snapshot$forecast_data$komponen == "Forecast"]))
      } else {
        "source not recorded"
      }
      sources <- sources[!is.na(sources) & nzchar(sources)]
      if (length(sources) == 0) sources <- "source not recorded"
      shiny::div(
        paste(
          "Forecast live H+1 sampai H+3 memakai champion",
          snapshot$selected_model,
          "dan sumber iklim",
          paste(sources, collapse = ", "),
          "."
        ),
        class = "section-subtitle"
      )
    })

    output$stationarityStep <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      shiny::div(
        class = "flow-box sarima",
        shiny::strong("Tahap 3 - Uji stasioneritas"),
        paste("ADF/KPSS pada harga rata-rata:", snapshot$stationarity_label)
      )
    })

    output$sarimaStep <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      shiny::div(
        class = "flow-box sarima",
        shiny::strong("Tahap 4 - SARIMA"),
        paste(snapshot$sarima_label, "diagnostik residual, ekstraksi epsilon.")
      )
    })

    output$residualSubtitle <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      shiny::div(
        paste("Residual epsilon dari", snapshot$sarima_label, "sebagai target XGBoost regresi"),
        class = "section-subtitle"
      )
    })

    output$forecastPlot <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$forecast_data, ggplot2::aes(horizon, harga, fill = komponen)) +
        ggplot2::geom_col(width = 0.66, color = NA) +
        ggplot2::geom_text(
          ggplot2::aes(label = rupiah(harga)),
          vjust = -0.45,
          color = "#f5f2e8",
          size = 4,
          fontface = "bold"
        ) +
        ggplot2::scale_fill_manual(values = c("Observasi" = "#61c9a8", "Forecast" = "#f5a623")) +
        ggplot2::scale_y_continuous(
          labels = rupiah,
          limits = c(0, max(snapshot$forecast_data$harga, na.rm = TRUE) * 1.18)
        ) +
        ggplot2::labs(x = "Horizon", y = "Harga (Rp)", fill = NULL) +
        theme_dark_cilegon() +
        ggplot2::theme(legend.position = "bottom")
    })

    output$residualPlot <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(tail(snapshot$pipeline_data, 45), ggplot2::aes(tanggal, residual)) +
        ggplot2::geom_hline(yintercept = 0, color = "#8a8c84") +
        ggplot2::geom_col(fill = "#b2a7ff", alpha = 0.82, width = 0.8) +
        ggplot2::labs(x = "Tanggal", y = "Residual (Rp)") +
        theme_dark_cilegon()
    })

    output$hybridPlot <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      df <- tail(snapshot$pipeline_data, 45)
      tst <- snapshot$test_data
      ggplot2::ggplot(df, ggplot2::aes(tanggal)) +
        ggplot2::geom_line(ggplot2::aes(y = harga, color = "Observasi"), linewidth = 1) +
        ggplot2::geom_line(ggplot2::aes(y = sarima, color = "SARIMA"), linewidth = 0.9) +
        ggplot2::geom_line(ggplot2::aes(y = residual_hybrid, color = "SARIMA + XGBoost Residual"), linewidth = 1.1) +
        ggplot2::geom_vline(xintercept = as.numeric(max(df$tanggal)), linetype = 2, color = "#8a8c84") +
        ggplot2::geom_line(data = tst, ggplot2::aes(tanggal, prediksi_final, color = "Prediksi test"), linewidth = 1.1, inherit.aes = FALSE) +
        ggplot2::geom_point(data = tst, ggplot2::aes(tanggal, harga_aktual, color = "Aktual test"), size = 2.8, inherit.aes = FALSE) +
        ggplot2::scale_color_manual(values = c(
          "Observasi" = "#f5f2e8",
          "SARIMA" = "#b2a7ff",
          "SARIMA + XGBoost Residual" = "#f5a623",
          "Prediksi test" = "#f5a623",
          "Aktual test" = "#61c9a8"
        )) +
        ggplot2::scale_y_continuous(labels = rupiah) +
        ggplot2::labs(x = "Tanggal", y = "Harga (Rp)") +
        theme_dark_cilegon()
    })
  })
}
