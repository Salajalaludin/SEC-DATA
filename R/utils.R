rupiah <- function(x) {
  paste0("Rp", format(round(x, 0), big.mark = ".", decimal.mark = ","))
}

format_tanggal <- function(x) {
  bulan <- c("Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des")
  x <- as.Date(x, origin = "1970-01-01")
  paste(format(x, "%d"), bulan[as.integer(format(x, "%m"))], format(x, "%Y"))
}

theme_dark_cilegon <- function(base_size = 12) {
  ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "#20211f", color = NA),
      panel.background = ggplot2::element_rect(fill = "#20211f", color = NA),
      panel.grid.major = ggplot2::element_line(color = "#363833", linewidth = 0.35),
      panel.grid.minor = ggplot2::element_blank(),
      axis.text = ggplot2::element_text(color = "#b9b9b0"),
      axis.title = ggplot2::element_text(color = "#deded6"),
      plot.title = ggplot2::element_text(color = "#f5f2e8", face = "bold"),
      plot.subtitle = ggplot2::element_text(color = "#b9b9b0"),
      legend.position = "bottom",
      legend.text = ggplot2::element_text(color = "#deded6"),
      legend.title = ggplot2::element_blank()
    )
}
