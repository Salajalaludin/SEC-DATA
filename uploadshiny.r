library(rsconnect)

rsconnect::deployApp(
  appDir  = "c:/2025 coding/Mini Project/Agriculture/NEC SATRIA DATA 2026/cilegon_komoditas_shiny",
  appName = "cilegon_komoditas_shiny",   # nama yang sudah ada, supaya update bukan buat baru
  account = "orion-synapse",        # username shinyapps.io Anda
  forceUpdate = TRUE
)
