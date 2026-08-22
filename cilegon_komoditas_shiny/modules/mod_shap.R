mod_shap_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::div(
      class = "card",
      shiny::div("Kenapa SHAP dipisah?", class = "section-title"),
      shiny::div("Regresi dan klasifikasi punya target, satuan output, dan pertanyaan kebijakan yang berbeda", class = "section-subtitle"),
      shiny::div(
        class = "explain-grid",
        shiny::div(
          class = "explain-item",
          shiny::tags$b("SHAP regresi"),
          "Menjelaskan contribution to forecast/model prediction pada output regresi residual SARIMA. Nilai SHAP dibaca pada skala output model dan bersifat associational, bukan causal."
        ),
        shiny::div(
          class = "explain-item",
          shiny::tags$b("SHAP klasifikasi"),
          "Menjelaskan kontribusi fitur terhadap Distribution Stress Score. Nilai SHAP di jalur ini dibaca pada skala output model, bukan sebagai perubahan rupiah atau efek kausal."
        ),
        shiny::div(
          class = "explain-item",
          shiny::tags$b("Implikasi interpretasi"),
          "Karena targetnya berbeda, jalur SHAP tetap dipisah. Model regresi menjelaskan contribution to forecast/model prediction, sedangkan model klasifikasi menjelaskan contribution to Distribution Stress Score."
        )
      )
    ),
    shiny::fluidRow(
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Regresi - Summary plot", class = "section-title"),
          shiny::div("Ranking kontribusi variabel terhadap forecast/model prediction", class = "section-subtitle"),
          shiny::plotOutput(ns("shapRegSummary"), height = 260)
        )
      ),
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Regresi - Dependence plot", class = "section-title"),
          shiny::div("Asosiasi suhu dengan contribution to forecast/model prediction", class = "section-subtitle"),
          shiny::plotOutput(ns("shapRegDependence"), height = 260)
        )
      )
    ),
    shiny::fluidRow(
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Klasifikasi - Summary plot", class = "section-title"),
          shiny::div("Variabel terkait Distribution Stress Score proxy", class = "section-subtitle"),
          shiny::plotOutput(ns("shapClsSummary"), height = 260)
        )
      ),
      shiny::column(
        6,
        shiny::div(
          class = "card",
          shiny::div("Klasifikasi - Dependence plot", class = "section-title"),
          shiny::div("Asosiasi suhu dengan Distribution Stress Score", class = "section-subtitle"),
          shiny::plotOutput(ns("shapClsDependence"), height = 260)
        )
      )
    ),
    shiny::div(
      class = "card",
      shiny::div("Keterangan variabel", class = "section-title"),
      shiny::div("Definisi fitur yang dipakai pada model regresi residual dan klasifikasi risiko", class = "section-subtitle"),
      shiny::div(
        class = "note-grid",
          shiny::div(class = "note-item", shiny::HTML("<b>suhu_puncak_lag1</b><br>Suhu puncak Cilegon Local Climate pada hari sebelumnya. Dipakai sebagai predictor kondisi suhu dalam output model, bukan bukti efek kausal pada harga atau distribusi.")),
        shiny::div(class = "note-item", shiny::HTML("<b>HEI</b><br>Heat Exposure Index, indeks paparan panas. Referensi 32 derajat C adalah heuristic feature reference, bukan threshold risiko atau temuan kausal.")),
        shiny::div(class = "note-item", shiny::HTML("<b>delta_suhu</b><br>Perubahan suhu puncak dibanding hari sebelumnya. Nilai besar berarti terjadi lonjakan atau penurunan suhu mendadak.")),
        shiny::div(class = "note-item", shiny::HTML("<b>ma7</b><br>Rata-rata bergerak harga tomat 7 hari. Fitur ini mewakili level harga jangka pendek sebelum prediksi dibuat.")),
        shiny::div(class = "note-item", shiny::HTML("<b>margin_hl_lag1</b><br>Selisih harga tertinggi dan terendah dari tiga pasar pada HARI SEBELUMNYA (margin_hl di-lag 1 hari). Karena margin hari yang sama baru diketahui setelah pasar tutup, fitur forecasting memakai margin kemarin agar tidak bocor. margin_hl hari yang sama hanya dipakai untuk label proxy risiko, bukan sebagai prediktor.")),
        shiny::div(class = "note-item", shiny::HTML("<b>hujan</b><br>Total curah hujan harian dari ERA5. Dipakai sebagai predictor konteks cuaca dalam output model; SHAP tidak membuktikan pengaruh kausal.")),
        shiny::div(class = "note-item", shiny::HTML("<b>day_of_week</b><br>Hari dalam minggu. Fitur kalender untuk menangkap pola pasar mingguan.")),
        shiny::div(class = "note-item", shiny::HTML("<b>month</b><br>Bulan kalender. Fitur ini membantu membaca pola musiman pasokan dan cuaca.")),
        shiny::div(class = "note-item", shiny::HTML("<b>Nilai SHAP</b><br>Regresi: contribution to forecast/model prediction. Risk: contribution to Distribution Stress Score. Interpretasi bersifat associational, bukan causal.")),
        shiny::div(class = "note-item", shiny::HTML("<b>gagal_distribusi</b><br>Technical proxy label risk_proxy_v1; bukan catatan kejadian distribusi teramati. Dibentuk dari lonjakan harga 3 hari ke depan atau kombinasi margin tinggi dan panas tinggi."))
      )
    )
  )
}

mod_shap_server <- function(id, state) {
  shiny::moduleServer(id, function(input, output, session) {
    output$shapRegSummary <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$shap_reg_summary, ggplot2::aes(kontribusi, fitur)) +
        ggplot2::geom_col(fill = "#ffb866", width = 0.7) +
        ggplot2::labs(x = "Mean |SHAP| contribution to forecast/model prediction", y = NULL) +
        theme_dark_cilegon()
    })

    output$shapRegDependence <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$dep_reg, ggplot2::aes(suhu, shap)) +
        ggplot2::geom_point(ggplot2::aes(color = harga), alpha = 0.62, size = 1.7) +
        ggplot2::geom_smooth(color = "#ffb866", linewidth = 1.1, se = FALSE, method = "loess", formula = y ~ x) +
        ggplot2::scale_color_gradient(low = "#61c9a8", high = "#ffb866", name = "Harga (Rp)", labels = rupiah) +
        ggplot2::labs(x = "Suhu puncak lag-1 (derajat C)", y = "SHAP contribution to forecast/model prediction") +
        theme_dark_cilegon()
    })

    output$shapClsSummary <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$shap_cls_summary, ggplot2::aes(kontribusi, fitur)) +
        ggplot2::geom_col(fill = "#ff9a7d", width = 0.7) +
        ggplot2::labs(x = "Mean |SHAP| contribution to Distribution Stress Score", y = NULL) +
        theme_dark_cilegon()
    })

    output$shapClsDependence <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      ggplot2::ggplot(snapshot$dep_cls, ggplot2::aes(suhu, shap)) +
        ggplot2::geom_hline(yintercept = 0, color = "#8a8c84") +
        ggplot2::geom_point(ggplot2::aes(color = stress_score), alpha = 0.62, size = 1.7) +
        ggplot2::geom_smooth(color = "#ff9a7d", linewidth = 1.1, se = FALSE, method = "loess", formula = y ~ x) +
        ggplot2::scale_color_gradient(
          low = "#61c9a8",
          high = "#ff9a7d",
          labels = function(x) paste0(round(100 * x), "/100")
        ) +
        ggplot2::labs(x = "Suhu puncak lag-1 (derajat C)", y = "SHAP contribution to Distribution Stress Score") +
        theme_dark_cilegon()
    })
  })
}
