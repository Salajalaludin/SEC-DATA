# Tests for target leakage and train/serve skew (R/features.R, Sprint 2).

build_test_avg <- function(prices, n = length(prices)) {
  # dates span two months so the month factor has >= 2 levels for model.matrix
  data.frame(
    tanggal = as.Date("2023-01-25") + 0:(n - 1),
    harga = prices,
    suhu_puncak = rep(30, n),
    kelembaban = rep(80, n),
    hujan = rep(0, n),
    margin_hl = rep(2, n)
  )
}

feature_cols <- c("harga_kemarin", "lag2", "lag3", "lag7",
                  "ma7", "vol7", "min7", "max7", "margin_hl_lag1")

# ---------------------------------------------------------------------------
# No target leakage
# ---------------------------------------------------------------------------

test_that("changing harga[t] does not change features for predicting t", {
  base_prices <- c(100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
  t_idx <- 8
  avg_a <- build_test_avg(base_prices)
  avg_b <- build_test_avg(replace(base_prices, t_idx, 99999))  # perturb harga[t]
  fa <- build_training_features(avg_a)
  fb <- build_training_features(avg_b)
  # features for target day t must be identical (harga[t] is not a predictor)
  expect_equal(fa[t_idx, feature_cols], fb[t_idx, feature_cols])
  # harga[t] IS legitimately part of history for t+1 -> features change there
  expect_false(isTRUE(all.equal(fa[t_idx + 1, feature_cols], fb[t_idx + 1, feature_cols])))
})

test_that("changing harga[t+1] never affects features for t", {
  base_prices <- c(100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
  t_idx <- 8
  avg_a <- build_test_avg(base_prices)
  avg_b <- build_test_avg(replace(base_prices, t_idx + 1, 99999))  # perturb harga[t+1]
  fa <- build_training_features(avg_a)
  fb <- build_training_features(avg_b)
  expect_equal(fa[t_idx, feature_cols], fb[t_idx, feature_cols])
})

test_that("rolling windows use only prior observations (direct value check)", {
  p <- c(10, 20, 30, 40, 50, 60, 70, 100)
  avg <- build_test_avg(p)
  f <- build_training_features(avg)
  expect_equal(f$ma7[8], mean(p[1:7]))
  expect_equal(f$max7[8], max(p[1:7]))
  expect_equal(f$min7[8], min(p[1:7]))
  expect_equal(f$vol7[8], sd(p[1:7]))
})

test_that("margin_hl_lag1 uses the prior day margin", {
  n <- 10
  avg <- build_test_avg(seq(100, by = 10, length.out = n))
  avg$margin_hl <- seq_len(n)  # margin_hl[t] = t
  f <- build_training_features(avg)
  expect_equal(f$margin_hl_lag1, c(NA_real_, seq_len(n - 1)))
  expect_true(is.na(f$margin_hl_lag1[1]))
  expect_equal(f$margin_hl_lag1[8], f$margin_hl[7])
})

# ---------------------------------------------------------------------------
# Train / serve consistency
# ---------------------------------------------------------------------------

test_that("train feature row equals inference feature row for the same target day", {
  prices <- c(100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
  avg <- build_test_avg(prices)
  tr <- build_training_features(avg)
  t_idx <- 8
  # inference builder with history = prices[1..7] and target day t=8
  fr <- build_future_feature_row(
    prices = prices[1:(t_idx - 1)],
    last_margin = tr$margin_hl[t_idx - 1],
    target_climate_row = tr[t_idx, c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE],
    prev_suhu = tr$suhu_puncak[t_idx - 1],
    day_levels = levels(tr$day_of_week),
    month_levels = levels(tr$month)
  )
  train_row <- tr[t_idx, c("suhu_puncak", "suhu_puncak_lag1", "delta_suhu", "hei",
                           "hujan", "kelembaban", "harga_kemarin", "lag2", "lag3",
                           "lag7", "ma7", "vol7", "min7", "max7", "margin_hl_lag1")]
  expect_equal(as.numeric(fr$ma7), as.numeric(train_row$ma7))
  expect_equal(as.numeric(fr$vol7), as.numeric(train_row$vol7))
  expect_equal(as.numeric(fr$min7), as.numeric(train_row$min7))
  expect_equal(as.numeric(fr$max7), as.numeric(train_row$max7))
  expect_equal(as.numeric(fr$harga_kemarin), as.numeric(train_row$harga_kemarin))
  expect_equal(as.numeric(fr$margin_hl_lag1), as.numeric(train_row$margin_hl_lag1))
  expect_equal(as.numeric(fr$suhu_puncak_lag1), as.numeric(train_row$suhu_puncak_lag1))
  expect_equal(as.numeric(fr$hei), as.numeric(train_row$hei))
})

test_that("train and inference model-matrix column sets match", {
  prices <- c(100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
  avg <- build_test_avg(prices)
  tr <- build_training_features(avg)
  formula <- ~ suhu_puncak + suhu_puncak_lag1 + delta_suhu + hei + hujan +
    kelembaban + harga_kemarin + lag2 + lag3 + lag7 + ma7 + vol7 + min7 +
    max7 + margin_hl_lag1 + day_of_week + month - 1
  mm_train <- model.matrix(formula, tr[8, , drop = FALSE])
  fr <- build_future_feature_row(
    prices = prices[1:7],
    last_margin = tr$margin_hl[7],
    target_climate_row = tr[8, c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE],
    prev_suhu = tr$suhu_puncak[7],
    day_levels = levels(tr$day_of_week),
    month_levels = levels(tr$month)
  )
  mm_future <- model.matrix(formula, fr)
  expect_equal(colnames(mm_train), colnames(mm_future))
  expect_equal(ncol(mm_train), ncol(mm_future))
})

test_that("align_future_matrix reorders deterministically to training columns", {
  feature_cols <- c("b", "a", "c")
  mat <- matrix(1:4, nrow = 2, dimnames = list(NULL, c("c", "a")))
  aligned <- align_future_matrix(mat, feature_cols)
  expect_equal(colnames(aligned), feature_cols)
  expect_equal(aligned[, "b"], c(0, 0))  # missing column filled with 0
  expect_equal(aligned[, "a"], mat[, "a"])
  expect_equal(aligned[, "c"], mat[, "c"])
  expect_identical(aligned, align_future_matrix(mat, feature_cols))
})
