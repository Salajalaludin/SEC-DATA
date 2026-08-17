# evaluation.R — Time-series evaluation (Methodology V2, Sprint 3)
#
# Statistically valid evaluation using time-ordered data:
#
#   development period  ->  rolling-origin validation  ->  untouched final test
#
# Rules enforced here:
#   * chronological order only (never randomized);
#   * expanding-window (rolling-origin) validation folds with no future leakage;
#   * SARIMA/XGBoost models are REFIT at every one-step forecast origin using
#     the currently available history (no "fit once, claim rolling");
#   * every baseline receives the same information availability at each origin;
#   * the final test is isolated and evaluated only after all decisions are
#     frozen (no tuning/calibration/selection on the final test);
#   * no final-test bias tuning (the old hybrid_bias_grid search is gone).
#
# The in-sample bias inside the hybrid definition (median of recent 14
# residuals + 30) is part of the frozen legacy model formula (see
# fit_forecast_models) and is recomputed only from training history at each
# origin; it is never fit from the final test. Hybrid weights will be redesigned
# in Sprint 4, not here.
#
# Depends on R/features.R (build_future_feature_row, align_future_matrix) and
# packages forecast and xgboost.

# ---------------------------------------------------------------------------
# Configuration (kept here, not in UI code)
# ---------------------------------------------------------------------------

#' Evaluation configuration.
#'
#' All split/validation values are defined here so they are explicit and
#' auditable instead of being buried in UI/render code.
#'
#' Defaults are bounded so the Shiny app stays responsive (each one-step refit
#' costs ~1-3 s because SARIMA is refit at every origin). The authoritative,
#' larger protocol is run via scripts/run_evaluation.R which overrides
#' max_folds/validation_step/final_test_size.
eval_config <- function() {
  list(
    min_train_obs = 60L,        # minimum history before the first origin
    validation_horizon = 7L,    # validated days per fold (H)
    validation_step = 7L,       # days between forecast origins (adjacent windows)
    max_folds = 2L,             # cap on validation origins (most recent window)
    final_test_size = 0.02,     # fraction of rows reserved as untouched final test
    min_final_test_obs = 14L,   # floor on final test size (days)
    forecast_horizon = 3L       # operational horizon (H+1..H+3; eval is 1-step)
  )
}

#' Full-protocol configuration for scripts/run_evaluation.R (authoritative).
eval_config_full <- function() {
  c(eval_config(), list(
    max_folds = 12L,
    final_test_size = 0.12,
    min_final_test_obs = 42L
  ))
}

# ---------------------------------------------------------------------------
# Splits
# ---------------------------------------------------------------------------

#' Split a sorted average-price frame into development and untouched final test.
#'
#' The final test is the most recent block; it is never used for fitting,
#' tuning, calibration, or selection. `final_test` is returned separately so the
#' caller cannot accidentally leak it.
#'
#' @param avg sorted "Harga rata-rata" frame with features (prepare_avg_frame output).
#' @param config list from eval_config().
#' @return list(development = data.frame, final_test = data.frame).
split_evaluation_periods <- function(avg, config = eval_config()) {
  avg <- avg[order(avg$tanggal), , drop = FALSE]
  n <- nrow(avg)
  if (n < config$min_train_obs + config$min_final_test_obs) {
    stop("Tidak cukup observasi untuk split evaluasi.", call. = FALSE)
  }
  n_test <- max(config$min_final_test_obs, floor(n * config$final_test_size))
  n_test <- min(n_test, n - config$min_train_obs)
  list(
    development = avg[seq_len(n - n_test), , drop = FALSE],
    final_test = avg[(n - n_test + 1):n, , drop = FALSE]
  )
}

#' Build rolling-origin (expanding-window) validation folds.
#'
#' Fold at origin `o`: train = rows 1..o, validate = next validation_horizon
#' days. Origins advance by validation_step; windows are disjoint when
#' step >= horizon. Only the most recent `max_folds` origins are kept (bounded
#' computational cost). No fold uses any observation from its validation window
#' during training.
#'
#' @param dev development frame (sorted).
#' @param config list from eval_config().
#' @return list of list(train, valid).
rolling_origin_folds <- function(dev, config = eval_config()) {
  n <- nrow(dev)
  if (n < config$min_train_obs + config$validation_horizon) return(list())
  origins <- seq(config$min_train_obs, n - config$validation_horizon, by = config$validation_step)
  if (length(origins) > config$max_folds) origins <- tail(origins, config$max_folds)
  lapply(origins, function(o) {
    list(
      train = dev[seq_len(o), , drop = FALSE],
      valid = dev[(o + 1):min(o + config$validation_horizon, n), , drop = FALSE]
    )
  })
}

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

#' Regression metrics for a forecast evaluation.
#'
#' @param actual numeric vector of actual values.
#' @param predicted numeric vector of predicted values.
#' @return data.frame with MAE, RMSE, WAPE, MAPE.
eval_metrics <- function(actual, predicted) {
  err <- actual - predicted
  data.frame(
    MAE = mean(abs(err), na.rm = TRUE),
    RMSE = sqrt(mean(err^2, na.rm = TRUE)),
    WAPE = sum(abs(err), na.rm = TRUE) / sum(pmax(abs(actual), 1), na.rm = TRUE),
    MAPE = mean(abs(err) / pmax(abs(actual), 1), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Model fitting core (shared with app.R fit_pipeline_models)
# ---------------------------------------------------------------------------

#' Fit the forecasting model core (SARIMA + XGBoost residual + XGBoost direct).
#'
#' This is the single fitting implementation shared by evaluation
#' (refit per origin) and the live pipeline (app.R). Fitting configuration is
#' identical to the legacy model: auto.arima(seasonal=TRUE, stepwise=TRUE,
#' approximation=FALSE, allowdrift=TRUE, allowmean=TRUE), XGBoost fixed params
#' max_depth=3, eta=0.05, nrounds=120, subsample=0.9, colsample_bytree=0.9,
#' and hybrid = pmax(0, 0.001*(sarima+xgb_residual) + 0.999*xgb_price + bias)
#' with in-sample bias = median(last 14 residuals) + 30. No SHAP/risk overhead
#' is computed here (those are added by app.R's fit_pipeline_models).
#'
#' @param history_avg sorted "Harga rata-rata" frame with features.
#' @return list(models = list(sarima, xgb_reg, xgb_price), feature_formula,
#'   feature_cols, x_reg, model_frame, hybrid_bias, stationarity_label,
#'   sarima_label).
fit_forecast_models <- function(history_avg) {
  set.seed(2026)
  price_ts <- ts(history_avg$harga, frequency = 7)
  d_adf <- tryCatch(forecast::ndiffs(price_ts, test = "adf"), error = function(e) NA_integer_)
  d_kpss <- tryCatch(forecast::ndiffs(price_ts, test = "kpss"), error = function(e) NA_integer_)
  d_seasonal <- tryCatch(forecast::nsdiffs(price_ts), error = function(e) NA_integer_)
  sarima_model <- forecast::auto.arima(
    price_ts, seasonal = TRUE, stepwise = TRUE, approximation = FALSE,
    allowdrift = TRUE, allowmean = TRUE
  )
  sarima_fit <- as.numeric(stats::fitted(sarima_model))
  residual <- as.numeric(stats::residuals(sarima_model))

  model_frame <- history_avg
  model_frame$sarima <- sarima_fit
  model_frame$residual <- residual
  model_frame <- model_frame[complete.cases(model_frame[, c(
    "harga_kemarin", "lag2", "lag3", "lag7", "suhu_puncak_lag1",
    "ma7", "vol7", "min7", "max7", "margin_hl_lag1", "hei", "residual"
  )]), ]

  feature_formula <- ~ suhu_puncak + suhu_puncak_lag1 + delta_suhu + hei +
    hujan + kelembaban + harga_kemarin + lag2 + lag3 + lag7 + ma7 + vol7 +
    min7 + max7 + margin_hl_lag1 + day_of_week + month - 1
  x_reg <- model.matrix(feature_formula, model_frame)
  reg_matrix <- xgb.DMatrix(data = x_reg, label = model_frame$residual)
  price_matrix <- xgb.DMatrix(data = x_reg, label = model_frame$harga)
  params <- list(objective = "reg:squarederror", max_depth = 3, eta = 0.05,
                 subsample = 0.9, colsample_bytree = 0.9, nthread = 1)
  xgb_reg <- xgb.train(params = params, data = reg_matrix, nrounds = 120, verbose = 0)
  xgb_price <- xgb.train(params = params, data = price_matrix, nrounds = 120, verbose = 0)

  xgb_residual_fit <- as.numeric(predict(xgb_reg, x_reg))
  xgb_price_fit <- as.numeric(predict(xgb_price, x_reg))
  model_frame$xgb_residual <- xgb_residual_fit
  model_frame$xgb_price <- xgb_price_fit
  residual_hybrid <- model_frame$sarima + model_frame$xgb_residual
  hybrid_raw <- 0.001 * residual_hybrid + 0.999 * model_frame$xgb_price
  recent_bias <- tail(model_frame$harga - hybrid_raw, min(14, nrow(model_frame)))
  hybrid_bias <- if (all(is.na(recent_bias))) 30 else stats::median(recent_bias, na.rm = TRUE) + 30
  model_frame$hybrid <- pmax(0, hybrid_raw + hybrid_bias)

  ord <- forecast::arimaorder(sarima_model)
  sarima_label <- if (all(c("P", "D", "Q", "Frequency") %in% names(ord))) {
    paste0("SARIMA (", paste(ord[c("p", "d", "q")], collapse = ","), ")(",
           paste(ord[c("P", "D", "Q")], collapse = ","), ")[", ord[["Frequency"]], "]")
  } else {
    paste0("SARIMA (", paste(ord[c("p", "d", "q")], collapse = ","), ")(0,0,0)[7]")
  }

  list(
    models = list(sarima = sarima_model, xgb_reg = xgb_reg, xgb_price = xgb_price),
    feature_formula = feature_formula,
    feature_cols = colnames(x_reg),
    x_reg = x_reg,
    model_frame = model_frame,
    hybrid_bias = hybrid_bias,
    stationarity_label = paste0("ADF d=", d_adf, ", KPSS d=", d_kpss, ", seasonal D=", d_seasonal),
    sarima_label = sarima_label
  )
}

# ---------------------------------------------------------------------------
# One-step prediction
# ---------------------------------------------------------------------------

#' One-step-ahead hybrid prediction for a target day using current history.
#'
#' Refits are done by the caller (rolling_one_step_eval); this function uses the
#' fitted model and the currently available history to build the feature row via
#' the shared feature builder, then predicts SARIMA, XGBoost-residual,
#' XGBoost-direct, and the hybrid. Identical formula to the live forecast path.
#'
#' @param fit_obj output of fit_forecast_models().
#' @param history_avg sorted frame of history up to day t-1 (has margin_hl).
#' @param target_row one-row frame for day t (tanggal, suhu_puncak, kelembaban, hujan).
#' @return data.frame with sarima, xgb_residual, xgb_price, hybrid.
predict_one_day_hybrid <- function(fit_obj, history_avg, target_row) {
  row <- build_future_feature_row(
    prices = history_avg$harga,
    last_margin = tail(history_avg$margin_hl, 1),
    target_climate_row = target_row[, c("tanggal", "suhu_puncak", "kelembaban", "hujan"), drop = FALSE],
    prev_suhu = tail(history_avg$suhu_puncak, 1),
    day_levels = levels(fit_obj$model_frame$day_of_week),
    month_levels = levels(fit_obj$model_frame$month)
  )
  x_row <- model.matrix(fit_obj$feature_formula, row)
  x_row <- align_future_matrix(x_row, fit_obj$feature_cols)
  sarima_pred <- as.numeric(forecast::forecast(fit_obj$models$sarima, h = 1)$mean)
  xgb_resid <- as.numeric(predict(fit_obj$models$xgb_reg, x_row))
  xgb_price_pred <- as.numeric(predict(fit_obj$models$xgb_price, x_row))
  hybrid <- max(0, 0.001 * (sarima_pred + xgb_resid) + 0.999 * xgb_price_pred + fit_obj$hybrid_bias)
  data.frame(sarima = sarima_pred, xgb_residual = xgb_resid,
             xgb_price = xgb_price_pred, hybrid = hybrid, stringsAsFactors = FALSE)
}

# ---------------------------------------------------------------------------
# Rolling one-step evaluation
# ---------------------------------------------------------------------------

#' Rolling one-step-ahead evaluation with refit at every forecast origin.
#'
#' For each target day: refit models on currently available history, predict
#' the next day, reveal the actual, append it, and continue. Baselines (Naive,
#' Seasonal Naive 7, MA7) are recomputed at every origin from the same observed
#' history, so every model sees identical information.
#'
#' @param history sorted frame of observed history up to the first target day.
#' @param targets sorted frame of target days to evaluate (one-step).
#' @param config list from eval_config().
#' @return data.frame with tanggal, actual, naive, sNaive7, ma7, sarima,
#'   xgb_residual, xgb_price, hybrid.
rolling_one_step_eval <- function(history, targets, config = eval_config()) {
  h <- history
  out <- vector("list", nrow(targets))
  for (i in seq_len(nrow(targets))) {
    target <- targets[i, , drop = FALSE]
    fit <- fit_forecast_models(h)
    pred <- predict_one_day_hybrid(fit, h, target)
    prices <- h$harga
    out[[i]] <- data.frame(
      tanggal = as.Date(target$tanggal),
      sumber_iklim = if ("sumber_iklim" %in% names(target)) as.character(target$sumber_iklim) else "ERA5",
      actual = as.numeric(target$harga),
      naive = tail(prices, 1),
      sNaive7 = if (length(prices) >= 7) prices[length(prices) - 6] else NA_real_,
      ma7 = if (length(prices) >= 7) mean(tail(prices, 7)) else NA_real_,
      sarima = pred$sarima,
      xgb_residual = pred$xgb_residual,
      xgb_price = pred$xgb_price,
      hybrid = pred$hybrid,
      stringsAsFactors = FALSE
    )
    h <- rbind(h, target)
  }
  do.call(rbind, out)
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

#' Run the full evaluation protocol.
#'
#' Splits development vs untouched final test, runs rolling-origin validation
#' and an untouched final-test evaluation, and computes per-model metrics.
#'
#' @param avg sorted "Harga rata-rata" frame with features.
#' @param config list from eval_config().
#' @return list(validation_long, final_test_long, validation_metrics,
#'   final_test_metrics, config, split, n_folds).
evaluate_pipeline <- function(avg, config = eval_config()) {
  split <- split_evaluation_periods(avg, config)
  folds <- rolling_origin_folds(split$development, config)
  if (length(folds) == 0) {
    stop("Tidak ada fold validasi yang terbentuk; periksa eval_config().", call. = FALSE)
  }
  val_long <- do.call(rbind, lapply(folds, function(f) {
    rolling_one_step_eval(f$train, f$valid, config)
  }))
  final_long <- rolling_one_step_eval(split$development, split$final_test, config)

  model_names <- c("naive", "sNaive7", "ma7", "sarima", "xgb_price", "hybrid")
  label_map <- c(naive = "Naive", sNaive7 = "Seasonal Naive 7", ma7 = "MA7",
                 sarima = "SARIMA-only", xgb_price = "XGBoost Direct", hybrid = "Hybrid")
  metrics_for <- function(long) {
    do.call(rbind, lapply(model_names, function(m) {
      mm <- eval_metrics(long$actual, long[[m]])
      mm$model <- unname(label_map[[m]])
      mm[, c("model", "MAE", "RMSE", "WAPE", "MAPE"), drop = FALSE]
    }))
  }
  val_metrics <- metrics_for(val_long)
  final_metrics <- metrics_for(final_long)

  list(
    validation_long = val_long,
    final_test_long = final_long,
    validation_metrics = val_metrics,
    final_test_metrics = final_metrics,
    config = config,
    n_folds = length(folds),
    split = list(
      development_range = range(split$development$tanggal),
      final_test_range = range(split$final_test$tanggal)
    )
  )
}
