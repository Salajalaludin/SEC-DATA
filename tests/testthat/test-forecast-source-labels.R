test_that("live forecast records BMKG and carry-forward climate sources", {
  avg <- data.frame(
    tanggal = as.Date("2026-01-03"),
    suhu_puncak = 30,
    kelembaban = 80,
    hujan = 1,
    sumber_iklim = "ERA5"
  )
  bmkg <- data.frame(
    tanggal = as.Date(c("2026-01-04", "2026-01-05")),
    suhu_puncak = c(31, 32),
    kelembaban = c(79, 78),
    hujan = c(0, 2)
  )

  partial <- build_live_future_climate(avg, bmkg, horizon = 3L)
  expect_identical(partial$sumber_iklim, c("BMKG", "BMKG", "BMKG carry-forward"))

  fallback <- build_live_future_climate(avg, NULL, horizon = 2L)
  expect_identical(fallback$sumber_iklim, c("ERA5 carry-forward", "ERA5 carry-forward"))
})

test_that("invalid or unavailable caches fall back without fabricating data", {
  market_cache <- tempfile(fileext = ".rds")
  climate_cache <- tempfile(fileext = ".rds")
  saveRDS(list(unexpected = TRUE), market_cache)
  saveRDS(list(unexpected = TRUE), climate_cache)
  on.exit(unlink(c(market_cache, climate_cache)), add = TRUE)

  expect_null(read_market_cache(market_cache))
  expect_null(read_climate_cache(climate_cache))

  local_market <- data.frame(
    tanggal = as.Date("2026-01-01"),
    pasar = "Pasar Baru Cilegon",
    komoditas = "Tomat",
    harga = 100,
    stringsAsFactors = FALSE
  )
  expect_identical(merge_market_sources(local_market, NULL, "Tomat"), local_market)
})
