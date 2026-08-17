# Tests for the time-series evaluation protocol (R/evaluation.R, Sprint 3).
# All tests use synthetic data and small configs to stay fast.

# ---------------------------------------------------------------------------
# Final-test isolation
# ---------------------------------------------------------------------------

test_that("split_evaluation_periods is chronological and isolates the final test", {
  avg <- make_synthetic_avg(120)
  cfg <- eval_config()
  cfg$min_train_obs <- 30L
  cfg$final_test_size <- 0.1
  cfg$min_final_test_obs <- 10L
  sp <- split_evaluation_periods(avg, cfg)
  expect_true(max(sp$development$tanggal) < min(sp$final_test$tanggal))
  expect_equal(nrow(sp$development) + nrow(sp$final_test), nrow(avg))
  expect_false(any(sp$development$tanggal %in% sp$final_test$tanggal))
})

test_that("the development period never contains final-test rows", {
  avg <- make_synthetic_avg(120)
  cfg <- eval_config()
  cfg$min_train_obs <- 30L
  cfg$final_test_size <- 0.1
  cfg$min_final_test_obs <- 10L
  sp <- split_evaluation_periods(avg, cfg)
  folds <- rolling_origin_folds(sp$development, cfg)
  for (f in folds) {
    expect_false(any(f$train$tanggal %in% sp$final_test$tanggal))
    expect_false(any(f$valid$tanggal %in% sp$final_test$tanggal))
  }
})

# ---------------------------------------------------------------------------
# Chronological folds, expanding windows, no overlap
# ---------------------------------------------------------------------------

test_that("rolling_origin_folds are chronological with expanding windows and no overlap", {
  avg <- make_synthetic_avg(120)
  cfg <- eval_config()
  cfg$min_train_obs <- 30L
  cfg$validation_horizon <- 5L
  cfg$validation_step <- 5L
  cfg$max_folds <- 10L
  folds <- rolling_origin_folds(avg, cfg)
  expect_true(length(folds) >= 2)
  prev_train_max <- -Inf
  prev_valid_max <- -Inf
  for (f in folds) {
    # train strictly before valid -> no future leakage in any fold
    expect_true(max(f$train$tanggal) < min(f$valid$tanggal))
    expect_true(max(f$valid$tanggal) <= max(avg$tanggal))
    # expanding window: each new origin trains on strictly more history
    expect_true(max(f$train$tanggal) > prev_train_max)
    # origins never regress relative to the previous validation window
    expect_true(max(f$train$tanggal) >= prev_valid_max)
    prev_train_max <- max(f$train$tanggal)
    prev_valid_max <- max(f$valid$tanggal)
  }
  # validation windows are disjoint (step >= horizon)
  for (i in seq_len(length(folds) - 1)) {
    expect_true(max(folds[[i]]$valid$tanggal) < min(folds[[i + 1]]$valid$tanggal))
  }
  # fold i+1 training window contains fold i training window
  for (i in seq_len(length(folds) - 1)) {
    expect_true(all(folds[[i]]$train$tanggal %in% folds[[i + 1]]$train$tanggal))
  }
})

test_that("no fold's validation window is used during training", {
  avg <- make_synthetic_avg(150)
  cfg <- eval_config()
  cfg$min_train_obs <- 40L
  cfg$validation_horizon <- 7L
  cfg$validation_step <- 7L
  cfg$max_folds <- 6L
  folds <- rolling_origin_folds(avg, cfg)
  for (f in folds) {
    expect_false(any(f$valid$tanggal %in% f$train$tanggal))
  }
})

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

test_that("eval_metrics computes MAE, RMSE, WAPE, MAPE correctly", {
  a <- c(100, 200, 300)
  p <- c(110, 180, 290)
  m <- eval_metrics(a, p)
  err <- a - p  # -10, 20, 10
  expect_equal(m$MAE, mean(c(10, 20, 10)))
  expect_equal(m$RMSE, sqrt(mean(c(100, 400, 100))))
  expect_equal(m$WAPE, sum(c(10, 20, 10)) / sum(a))
  expect_equal(m$MAPE, mean(c(10, 20, 10) / a))
})

test_that("eval_metrics handles ties and NA predictions", {
  m <- eval_metrics(c(100, 200), c(NA_real_, 200))
  expect_equal(m$MAE, 0)        # only the non-NA pair counts
  expect_equal(m$RMSE, 0)
})

# ---------------------------------------------------------------------------
# Rolling refit + fair baselines
# ---------------------------------------------------------------------------

test_that("rolling_one_step_eval updates history and baselines at each origin", {
  avg <- make_synthetic_avg(95)
  cfg <- eval_config()
  cfg$min_train_obs <- 60L
  cfg$validation_horizon <- 4L
  cfg$validation_step <- 4L
  cfg$max_folds <- 1L
  dev <- avg[1:90, ]
  targets <- avg[91:94, ]
  res <- rolling_one_step_eval(dev, targets, cfg)
  expect_equal(nrow(res), 4)
  expect_true(all(c("naive", "sNaive7", "ma7", "sarima", "xgb_price", "hybrid") %in% names(res)))
  # naive[i] == last observed actual before target i (rolling baseline)
  expect_equal(res$naive[1], dev$harga[90])
  expect_equal(res$naive[2], targets$harga[1])
  expect_equal(res$naive[3], targets$harga[2])
  # ma7[i] == mean of the last 7 observed actuals before target i
  expect_equal(res$ma7[1], mean(tail(dev$harga, 7)))
  expect_equal(res$ma7[2], mean(c(tail(dev$harga, 6), targets$harga[1])))
  # sNaive7[i] == the 7th-lag actual (7 positions back in the updated history)
  expect_equal(res$sNaive7[2], dev$harga[nrow(dev) - 5])
})

test_that("rolling_one_step_eval refits per origin (predictions not constant)", {
  avg <- make_synthetic_avg(95)
  cfg <- eval_config()
  cfg$min_train_obs <- 60L
  cfg$validation_horizon <- 4L
  cfg$validation_step <- 4L
  cfg$max_folds <- 1L
  dev <- avg[1:90, ]
  targets <- avg[91:94, ]
  res <- rolling_one_step_eval(dev, targets, cfg)
  # refit at each origin means predictions react to the newly revealed actual;
  # at minimum the hybrid predictions must not be a single frozen value
  expect_true(length(unique(res$hybrid)) > 1 || nrow(res) == 1)
  # naive must change each step (history is appended)
  expect_equal(length(unique(res$naive)), nrow(res))
})

test_that("fit_forecast_models returns the expected structure", {
  avg <- make_synthetic_avg(90)
  fit <- fit_forecast_models(avg)
  expect_true(all(c("models", "feature_formula", "feature_cols", "x_reg",
                    "model_frame", "hybrid_bias", "stationarity_label",
                    "sarima_label") %in% names(fit)))
  expect_true(all(c("sarima", "xgb_reg", "xgb_price") %in% names(fit$models)))
  expect_true("margin_hl_lag1" %in% fit$feature_cols)
  expect_false("margin_hl" %in% fit$feature_cols)
})
