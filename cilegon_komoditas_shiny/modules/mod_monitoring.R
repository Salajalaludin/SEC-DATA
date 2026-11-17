mod_monitoring_ui <- function(id, commodity_choices, selected_commodity) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::div(
      class = "card refresh-bar",
      shiny::uiOutput(ns("refreshStatus")),
      shiny::selectInput(
        ns("commoditySelect"),
        "Komoditas",
        choices = commodity_choices,
        selected = selected_commodity,
        width = "260px"
      ),
      shiny::actionButton(ns("refreshNow"), "Refresh data", class = "btn-refresh")
    ),
    shiny::fluidRow(
      shiny::column(6, shiny::div(class = "card metric", shiny::uiOutput(ns("priceMetric")))),
      shiny::column(6, shiny::div(class = "card metric", shiny::uiOutput(ns("tempMetric"))))
    ),
    shiny::div(
      class = "card",
      shiny::div("Panel monitoring", class = "section-title"),
      shiny::div(
        "Harga tiga pasar diringkas sebagai rentang, rata-rata, dan suhu puncak harian",
        class = "section-subtitle"
      ),
      shiny::plotOutput(ns("monitorPlot"), height = 320)
    )
  )
}

mod_monitoring_data_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::div(
    class = "card",
    shiny::div("Data hasil cleaning dan merge", class = "section-title"),
    shiny::div(
      "Contoh struktur data akhir setelah harga dan iklim disatukan berdasarkan tanggal",
      class = "section-subtitle"
    ),
    shiny::tableOutput(ns("dataPreview"))
  )
}

mod_monitoring_server <- function(id, state, refresh_dashboard, refresh_interval_ms) {
  shiny::moduleServer(id, function(input, output, session) {
    auto_refresh_started <- shiny::reactiveVal(FALSE)

    shiny::observeEvent(input$refreshNow, {
      refresh_dashboard(input$commoditySelect)
    }, ignoreInit = TRUE)

    shiny::observeEvent(input$commoditySelect, {
      refresh_dashboard(input$commoditySelect)
    }, ignoreInit = TRUE)

    shiny::observe({
      shiny::invalidateLater(refresh_interval_ms, session)
      if (isTRUE(shiny::isolate(auto_refresh_started()))) {
        refresh_dashboard(input$commoditySelect)
      } else {
        auto_refresh_started(TRUE)
      }
    })

    output$refreshStatus <- shiny::renderUI({
      snapshot <- state()
      if (is.null(snapshot)) {
        return(shiny::div(
          class = "refresh-info",
          "Menyiapkan data dan model dashboard..."
        ))
      }
      shiny::div(
        class = "refresh-info",
        shiny::div(shiny::strong("Komoditas: "), snapshot$commodity),
        shiny::div(shiny::strong("Sumber data: "), snapshot$source_label),
        shiny::div(shiny::strong("Data pasar sampai: "), format_tanggal(max(snapshot$raw_data$tanggal, na.rm = TRUE))),
        shiny::div(shiny::strong("ERA5 terakhir: "), format_tanggal(snapshot$climate_latest)),
        shiny::div(
          shiny::strong("Iklim gabungan sampai: "),
          if (is.na(snapshot$climate_blended_latest)) "-" else format_tanggal(snapshot$climate_blended_latest)
        ),
        shiny::div(
          shiny::strong("BMKG forecast sampai: "),
          if (is.na(snapshot$bmkg_latest)) "-" else format_tanggal(snapshot$bmkg_latest)
        ),
        shiny::div(shiny::strong("Model prediksi utama: "), snapshot$selected_model),
        shiny::div(
          "Sesi dimuat: ", format(snapshot$last_refresh_time, "%d %b %Y %H:%M:%S"),
          " | Auto-refresh tiap ", round(refresh_interval_ms / 60000, 1), " menit"
        )
      )
    })

    output$priceMetric <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      shiny::div(
        shiny::div(paste("Harga", snapshot$commodity, "data latih terakhir"), class = "metric-label"),
        shiny::div(rupiah(snapshot$current$harga), class = "metric-value"),
        shiny::div(
          sprintf("%+.1f%% vs kemarin", 100 * (snapshot$current$harga - snapshot$previous$harga) / snapshot$previous$harga),
          class = "metric-note"
        )
      )
    })

    output$tempMetric <- shiny::renderUI({
      snapshot <- state()
      shiny::req(snapshot)
      shiny::div(
        shiny::div("Suhu puncak Cilegon", class = "metric-label"),
        shiny::div(sprintf("%.1f derajat C", snapshot$current$suhu_puncak), class = "metric-value"),
        shiny::div(
          paste0(
            ifelse(
              snapshot$current$suhu_puncak >= 32,
              "Di atas referensi HEI 32 derajat C (heuristic)",
              "Di bawah referensi HEI 32 derajat C (heuristic)"
            ),
            " | Sumber: ", snapshot$current$sumber_iklim
          ),
          class = "metric-note"
        )
      )
    })

    output$monitorPlot <- shiny::renderPlot({
      snapshot <- state()
      shiny::req(snapshot)
      last_date <- max(snapshot$raw_data$tanggal, na.rm = TRUE)
      df <- snapshot$raw_data[snapshot$raw_data$tanggal >= last_date - 30, ]
      markets <- df[df$pasar != "Harga rata-rata", ]
      daily <- aggregate(
        harga ~ tanggal,
        markets,
        function(x) c(min = min(x, na.rm = TRUE), mean = mean(x, na.rm = TRUE), max = max(x, na.rm = TRUE))
      )
      daily <- data.frame(
        tanggal = daily$tanggal,
        harga_min = daily$harga[, "min"],
        harga_rata = daily$harga[, "mean"],
        harga_max = daily$harga[, "max"]
      )
      climate <- unique(df[, c("tanggal", "suhu_puncak", "sumber_iklim")])
      daily <- merge(daily, climate, by = "tanggal", all.x = TRUE)
      price_range <- range(c(daily$harga_min, daily$harga_max), na.rm = TRUE)
      temp_range <- range(daily$suhu_puncak, na.rm = TRUE)
      scale_factor <- diff(price_range) / max(diff(temp_range), 1)
      offset <- price_range[1] - temp_range[1] * scale_factor
      ggplot2::ggplot() +
        ggplot2::geom_ribbon(
          data = daily,
          ggplot2::aes(tanggal, ymin = harga_min, ymax = harga_max, fill = "Rentang 3 pasar"),
          alpha = 0.22
        ) +
        ggplot2::geom_line(data = markets, ggplot2::aes(tanggal, harga, color = pasar), linewidth = 0.55, alpha = 0.45) +
        ggplot2::geom_line(data = daily, ggplot2::aes(tanggal, harga_rata, color = "Harga rata-rata"), linewidth = 1.25) +
        ggplot2::geom_point(data = daily, ggplot2::aes(tanggal, harga_rata), color = "#f5f2e8", size = 1.5) +
        ggplot2::geom_line(
          data = daily,
          ggplot2::aes(tanggal, suhu_puncak * scale_factor + offset, color = "Suhu puncak"),
          linewidth = 1.05,
          linetype = 2
        ) +
        ggplot2::geom_point(
          data = daily,
          ggplot2::aes(tanggal, suhu_puncak * scale_factor + offset, shape = sumber_iklim),
          color = "#ffcf92",
          size = 2.2,
          stroke = 0.9
        ) +
        ggplot2::scale_y_continuous(
          labels = rupiah,
          sec.axis = ggplot2::sec_axis(~ (. - offset) / scale_factor, name = "Suhu puncak (derajat C)")
        ) +
        ggplot2::scale_color_manual(values = c(
          "Pasar Baru Cilegon" = "#61c9a8",
          "Pasar Blok F" = "#ffae2a",
          "Pasar Baru Merak" = "#f36b3f",
          "Harga rata-rata" = "#f5f2e8",
          "Suhu puncak" = "#ff7043"
        )) +
        ggplot2::scale_fill_manual(values = c("Rentang 3 pasar" = "#61c9a8")) +
        ggplot2::scale_shape_manual(values = c(
          "ERA5" = 16, "Bridge" = 15, "BMKG" = 17,
          "ERA5 carry-forward" = 15, "Bridge carry-forward" = 15,
          "BMKG carry-forward" = 15
        ), drop = FALSE) +
        ggplot2::labs(x = "Tanggal", y = paste("Harga", snapshot$commodity, "(Rp)"), color = NULL, fill = NULL, shape = "Sumber iklim") +
        theme_dark_cilegon() +
        ggplot2::theme(legend.position = "bottom")
    })

    output$dataPreview <- shiny::renderTable({
      snapshot <- state()
      shiny::req(snapshot)
      train_shown <- tail(snapshot$pipeline_data, 8)
      train_table <- data.frame(
        set = "training",
        tanggal = format_tanggal(train_shown$tanggal),
        sumber_iklim = train_shown$sumber_iklim,
        harga_aktual = rupiah(train_shown$harga),
        sarima = rupiah(train_shown$sarima),
        xgb_residual = rupiah(train_shown$xgb_residual),
        prediksi_final = "-",
        error = "-",
        APE = "-",
        skor_tekanan = sprintf("%.0f/100", 100 * train_shown$distribution_stress_score),
        status = train_shown$status,
        stringsAsFactors = FALSE
      )
      test_table <- data.frame(
        set = "test",
        tanggal = format_tanggal(snapshot$test_data$tanggal),
        sumber_iklim = snapshot$test_data$sumber_iklim,
        harga_aktual = rupiah(snapshot$test_data$harga_aktual),
        sarima = rupiah(snapshot$test_data$sarima),
        xgb_residual = rupiah(snapshot$test_data$xgb_residual),
        prediksi_final = rupiah(snapshot$test_data$prediksi_final),
        error = rupiah(snapshot$test_data$error),
        APE = sprintf("%.2f%%", 100 * snapshot$test_data$ape),
        skor_tekanan = "-",
        status = "-",
        stringsAsFactors = FALSE
      )
      rbind(train_table, test_table)
    }, striped = FALSE, bordered = FALSE, spacing = "s")

    list(commodity = shiny::reactive(input$commoditySelect))
  })
}
