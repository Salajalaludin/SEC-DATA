# Tests for lag and rolling feature correctness (R/features.R, Sprint 2).

# ---------------------------------------------------------------------------
# Price lags
# ---------------------------------------------------------------------------

test_that("price_lag_feats has correct lags with no off-by-one", {
  p <- 100:110
  pf <- price_lag_feats(p)
  i <- 6
  expect_equal(pf$harga_kemarin[i], p[i - 1])
  expect_equal(pf$lag2[i], p[i - 2])
  expect_equal(pf$lag3[i], p[i - 3])
  # insufficient history -> NA
  expect_true(is.na(pf$harga_kemarin[1]))
  expect_true(is.na(pf$lag2[2]))
  expect_true(is.na(pf$lag3[3]))
  expect_true(is.na(pf$lag7[7]))
  expect_false(is.na(pf$lag7[8]))
  # lag7 needs 7 prior observations (i >= 8)
  expect_equal(pf$lag7[8], p[1])
  expect_equal(pf$lag7[10], p[3])
})

# ---------------------------------------------------------------------------
# Rolling features (prior window only)
# ---------------------------------------------------------------------------

test_that("rolling_prior_feats uses only the prior 7 observations", {
  p <- c(10, 20, 30, 40, 50, 60, 70, 100)  # target at position 8; prior = 10..70
  rf <- rolling_prior_feats(p, k = 7)
  i <- 8
  expect_equal(rf$ma7[i], mean(p[1:7]))
  expect_equal(rf$vol7[i], sd(p[1:7]))
  expect_equal(rf$min7[i], min(p[1:7]))
  expect_equal(rf$max7[i], max(p[1:7]))
  # the current value (100) is EXCLUDED from the windows
  expect_false(rf$ma7[i] == 100)
  expect_equal(rf$max7[i], 70)
  expect_false(100 %in% rf$min7)
  # insufficient history -> NA (first k rows)
  expect_true(all(is.na(rf$ma7[1:7])))
  expect_true(is.na(rf$vol7[7]))
  expect_false(is.na(rf$max7[8]))
})

test_that("rolling windows shift correctly along the series", {
  p <- c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
  rf <- rolling_prior_feats(p, k = 3)
  # position 4 uses p[1..3]; position 5 uses p[2..4]
  expect_equal(rf$ma7[4], mean(c(1, 2, 3)))
  expect_equal(rf$ma7[5], mean(c(2, 3, 4)))
  expect_equal(rf$max7[4], 3)
  expect_equal(rf$min7[5], 2)
  expect_true(all(is.na(rf$ma7[1:3])))
})

# ---------------------------------------------------------------------------
# Market margin
# ---------------------------------------------------------------------------

test_that("margin_lag_feats lags the same-day margin by one day", {
  m <- c(1, 5, 3, 8)
  mf <- margin_lag_feats(m)
  expect_equal(mf$margin_hl_lag1, c(NA_real_, 1, 5, 3))
  expect_true(is.na(mf$margin_hl_lag1[1]))
  expect_equal(mf$margin_hl_lag1[4], m[3])
})

# ---------------------------------------------------------------------------
# Climate prior
# ---------------------------------------------------------------------------

test_that("climate_prior_feats lags suhu by one day", {
  s <- c(30, 31, 32)
  cf <- climate_prior_feats(s)
  expect_equal(cf$suhu_puncak_lag1, c(NA_real_, 30, 31))
  expect_true(is.na(cf$suhu_puncak_lag1[1]))
})

# ---------------------------------------------------------------------------
# build_training_features integration
# ---------------------------------------------------------------------------

test_that("build_training_features produces non-leaky rolling features", {
  p <- c(10, 20, 30, 40, 50, 60, 70, 100)
  avg <- data.frame(
    tanggal = as.Date("2023-01-01") + 0:7,
    harga = p,
    suhu_puncak = rep(30, 8),
    kelembaban = rep(80, 8),
    hujan = rep(0, 8),
    margin_hl = rep(2, 8)
  )
  f <- build_training_features(avg)
  expect_equal(f$ma7[8], mean(p[1:7]))
  expect_equal(f$max7[8], max(p[1:7]))
  expect_equal(f$min7[8], min(p[1:7]))
  expect_equal(f$vol7[8], sd(p[1:7]))
  expect_equal(f$harga_kemarin[8], p[7])
  expect_true(is.na(f$ma7[1]))
})
