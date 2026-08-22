prepare_avg_frame <- function(df) {
  avg <- df[df$pasar == "Harga rata-rata", ]
  avg <- avg[order(avg$tanggal), ]
  avg <- avg[complete.cases(avg[, c("tanggal", "harga", "suhu_puncak", "kelembaban", "hujan")]), ]
  market_only <- df[df$pasar != "Harga rata-rata", ]
  margin <- aggregate(harga ~ tanggal, market_only, function(x) diff(range(x, na.rm = TRUE)))
  names(margin)[2] <- "margin_hl"
  avg <- merge(avg, margin, by = "tanggal", all.x = TRUE)
  avg$margin_hl[is.na(avg$margin_hl)] <- 0
  avg <- avg[order(avg$tanggal), ]
  build_training_features(avg)
}

fit_pipeline_models <- function(train_avg, risk_training_avg = train_avg) {
  core <- fit_forecast_models(train_avg)
  model_frame <- core$model_frame
  x_reg <- core$x_reg

  risk_index <- match(as.Date(risk_training_avg$tanggal), as.Date(model_frame$tanggal))
  risk_index <- risk_index[is.finite(risk_index)]
  if (length(risk_index) < 2L) {
    stop("Data development terlalu sedikit untuk model risk.", call. = FALSE)
  }
  risk_training_frame <- model_frame[risk_index, , drop = FALSE]
  risk_proxy <- build_risk_proxy_v1(risk_training_frame)
  risk_fit <- fit_risk_proxy_model(x_reg[risk_index, , drop = FALSE], risk_proxy)

  full_proxy <- build_risk_proxy_v1(model_frame)
  for (nm in names(full_proxy$fields)) model_frame[[nm]] <- full_proxy$fields[[nm]]
  model_frame$distribution_stress_score <- score_distribution_stress(risk_fit$model, x_reg)
  model_frame$status <- map_stress_status(
    model_frame$distribution_stress_score,
    risk_fit$stress_thresholds
  )
  shap <- build_shap_artifacts(core$models$xgb_reg, risk_fit$model, x_reg, model_frame)

  c(list(
    model_frame = model_frame,
    feature_formula = core$feature_formula,
    feature_cols = core$feature_cols,
    xgb_config = data.frame(max_depth = 3, eta = 0.05, nrounds = 120),
    risk_proxy_version = risk_fit$version,
    risk_score_label = RISK_SCORE_LABEL,
    risk_score_tech_label = RISK_SCORE_TECH_LABEL,
    risk_proxy_parameters = risk_fit$proxy$parameters,
    stress_thresholds = risk_fit$stress_thresholds,
    risk_predictor_cols = risk_fit$predictor_cols,
    risk_training_range = range(risk_training_frame$tanggal),
    stationarity_label = core$stationarity_label,
    sarima_label = core$sarima_label,
    models = list(
      sarima = core$models$sarima,
      xgb_reg = core$models$xgb_reg,
      xgb_price = core$models$xgb_price,
      xgb_cls = risk_fit$model
    )
  ), shap)
}

predict_future_path <- function(fit_obj, history_avg, future_climate, selected_model_key) {
  future_features <- future_climate[
    order(future_climate$tanggal),
    c("tanggal", "suhu_puncak", "kelembaban", "hujan"),
    drop = FALSE
  ]
  horizon <- nrow(future_features)
  if (horizon == 0) return(data.frame())
  sarima_forecast <- as.numeric(forecast::forecast(fit_obj$models$sarima, h = horizon)$mean)
  last_margin <- tail(history_avg$margin_hl, 1)
  prev_suhu <- tail(history_avg$suhu_puncak, 1)
  future_residual <- numeric(horizon)
  future_price <- numeric(horizon)
  future_naive <- numeric(horizon)
  future_snaive7 <- numeric(horizon)
  future_ma7 <- numeric(horizon)
  future_residual_hybrid <- numeric(horizon)
  future_selected <- numeric(horizon)
  future_score <- numeric(horizon)
  proxy_prices <- as.numeric(history_avg$harga)
  for (i in seq_len(horizon)) {
    row <- build_future_feature_row(
      prices = proxy_prices,
      last_margin = last_margin,
      target_climate_row = future_features[i, , drop = FALSE],
      prev_suhu = prev_suhu,
      day_levels = levels(fit_obj$model_frame$day_of_week),
      month_levels = levels(fit_obj$model_frame$month)
    )
    x_row <- model.matrix(fit_obj$feature_formula, row)
    x_row <- align_future_matrix(x_row, fit_obj$feature_cols)
    future_residual[i] <- as.numeric(predict(fit_obj$models$xgb_reg, x_row))
    future_price[i] <- as.numeric(predict(fit_obj$models$xgb_price, x_row))
    future_naive[i] <- tail(proxy_prices, 1)
    future_snaive7[i] <- proxy_prices[length(proxy_prices) - 6]
    future_ma7[i] <- mean(tail(proxy_prices, 7))
    future_residual_hybrid[i] <- residual_hybrid_prediction(sarima_forecast[i], future_residual[i])
    candidates <- c(
      naive = future_naive[i],
      sNaive7 = future_snaive7[i],
      ma7 = future_ma7[i],
      sarima = sarima_forecast[i],
      xgb_price = future_price[i],
      residual_hybrid = future_residual_hybrid[i]
    )
    future_selected[i] <- candidate_prediction(candidates, selected_model_key)
    future_score[i] <- score_distribution_stress(fit_obj$models$xgb_cls, x_row)
    proxy_prices <- c(proxy_prices, future_selected[i])
    prev_suhu <- as.numeric(future_features$suhu_puncak[i])
  }
  data.frame(
    tanggal = as.Date(future_features$tanggal),
    naive = future_naive,
    sNaive7 = future_snaive7,
    ma7 = future_ma7,
    sarima = sarima_forecast,
    xgb_residual = future_residual,
    xgb_price = future_price,
    residual_hybrid = future_residual_hybrid,
    selected_prediction = future_selected,
    distribution_stress_score = future_score,
    status = map_stress_status(future_score, fit_obj$stress_thresholds),
    stringsAsFactors = FALSE
  )
}

build_live_future_climate <- function(avg, bmkg_forecast, horizon = FORECAST_HORIZON) {
  if (is.data.frame(bmkg_forecast) && nrow(bmkg_forecast) > 0) {
    future <- bmkg_forecast[
      bmkg_forecast$tanggal > max(avg$tanggal),
      c("tanggal", "suhu_puncak", "kelembaban", "hujan"),
      drop = FALSE
    ]
    future <- head(future[order(future$tanggal), ], horizon)
    if (nrow(future) >= horizon) return(future)
    if (nrow(future) > 0) {
      extra_n <- horizon - nrow(future)
      tail_row <- future[nrow(future), c("suhu_puncak", "kelembaban", "hujan"), drop = FALSE]
      extra <- data.frame(
        tanggal = seq.Date(max(future$tanggal) + 1, by = "day", length.out = extra_n),
        suhu_puncak = rep(tail_row$suhu_puncak, extra_n),
        kelembaban = rep(tail_row$kelembaban, extra_n),
        hujan = rep(tail_row$hujan, extra_n)
      )
      return(rbind(future, extra))
    }
  }
  data.frame(
    tanggal = seq.Date(max(avg$tanggal) + 1, by = "day", length.out = horizon),
    suhu_puncak = rep(tail(avg$suhu_puncak, 1), horizon),
    kelembaban = rep(tail(avg$kelembaban, 1), horizon),
    hujan = rep(tail(avg$hujan, 1), horizon)
  )
}

build_pipeline <- function(df, bmkg_forecast = NULL, forecast_horizon = FORECAST_HORIZON) {
  avg <- prepare_avg_frame(df)
  if (nrow(avg) < 14) stop("Data hasil merge terlalu sedikit untuk dashboard.", call. = FALSE)
  avg <- avg[order(avg$tanggal), ]

  eval_result <- evaluate_pipeline(avg, eval_config())
  test_metrics <- eval_result$final_test_metrics
  rolling_test_metrics <- eval_result$validation_metrics
  selected_model <- eval_result$selected_model
  selected_model_key <- eval_result$selected_model_key

  final_long <- eval_result$final_test_long
  selected_final <- candidate_prediction(final_long, selected_model_key)
  test_result <- data.frame(
    tanggal = as.Date(final_long$tanggal),
    sumber_iklim = as.character(final_long$sumber_iklim),
    harga_aktual = as.numeric(final_long$actual),
    sarima = final_long$sarima,
    xgb_residual = final_long$xgb_residual,
    xgb_price = final_long$xgb_price,
    residual_hybrid = final_long$residual_hybrid,
    prediksi_final = selected_final,
    error = final_long$actual - selected_final,
    stringsAsFactors = FALSE
  )
  test_result$ape <- abs(test_result$error) / pmax(abs(test_result$harga_aktual), 1)

  rolling_test_long <- rbind(
    data.frame(tanggal = final_long$tanggal, model = "Naive", actual = final_long$actual, predicted = final_long$naive),
    data.frame(tanggal = final_long$tanggal, model = "Seasonal Naive 7", actual = final_long$actual, predicted = final_long$sNaive7),
    data.frame(tanggal = final_long$tanggal, model = "MA7", actual = final_long$actual, predicted = final_long$ma7),
    data.frame(tanggal = final_long$tanggal, model = "SARIMA", actual = final_long$actual, predicted = final_long$sarima),
    data.frame(tanggal = final_long$tanggal, model = "XGBoost Direct", actual = final_long$actual, predicted = final_long$xgb_price),
    data.frame(tanggal = final_long$tanggal, model = "SARIMA + XGBoost Residual", actual = final_long$actual, predicted = final_long$residual_hybrid)
  )
  rolling_test_long$error <- rolling_test_long$actual - rolling_test_long$predicted
  rolling_test_long$ape <- abs(rolling_test_long$error) / pmax(abs(rolling_test_long$actual), 1)

  risk_development <- split_evaluation_periods(avg, eval_result$config)$development
  live_fit <- fit_pipeline_models(avg, risk_training_avg = risk_development)
  live_input <- build_live_future_climate(avg, bmkg_forecast, forecast_horizon)
  live_forecast <- predict_future_path(live_fit, avg, live_input, selected_model_key)
  last_actual_score <- tail(live_fit$model_frame$distribution_stress_score, 1)
  forecast_data <- data.frame(
    horizon = factor(
      c("Aktual terakhir", paste0("H+", seq_len(nrow(live_forecast)))),
      levels = c("Aktual terakhir", paste0("H+", seq_len(nrow(live_forecast))))
    ),
    harga = c(tail(avg$harga, 1), live_forecast$selected_prediction),
    aktual = c(tail(avg$harga, 1), rep(NA_real_, nrow(live_forecast))),
    tanggal = c(tail(avg$tanggal, 1), live_forecast$tanggal),
    komponen = c("Observasi", rep("Forecast", nrow(live_forecast))),
    model_prediksi = c("Aktual", rep(selected_model, nrow(live_forecast))),
    distribution_stress_score = c(last_actual_score, live_forecast$distribution_stress_score),
    status = c(
      map_stress_status(last_actual_score, live_fit$stress_thresholds),
      live_forecast$status
    ),
    stringsAsFactors = FALSE
  )

  list(
    data = data.frame(
      tanggal = as.Date(live_fit$model_frame$tanggal),
      pasar = as.character(live_fit$model_frame$pasar),
      sumber_iklim = as.character(live_fit$model_frame$sumber_iklim),
      harga = as.numeric(live_fit$model_frame$harga),
      suhu_puncak = as.numeric(live_fit$model_frame$suhu_puncak),
      kelembaban = as.numeric(live_fit$model_frame$kelembaban),
      hujan = as.numeric(live_fit$model_frame$hujan),
      harga_kemarin = as.numeric(live_fit$model_frame$harga_kemarin),
      lag2 = as.numeric(live_fit$model_frame$lag2),
      lag3 = as.numeric(live_fit$model_frame$lag3),
      lag7 = as.numeric(live_fit$model_frame$lag7),
      ma7 = as.numeric(live_fit$model_frame$ma7),
      vol7 = as.numeric(live_fit$model_frame$vol7),
      min7 = as.numeric(live_fit$model_frame$min7),
      max7 = as.numeric(live_fit$model_frame$max7),
      margin_hl = as.numeric(live_fit$model_frame$margin_hl),
      margin_hl_lag1 = as.numeric(live_fit$model_frame$margin_hl_lag1),
      suhu_puncak_lag1 = as.numeric(live_fit$model_frame$suhu_puncak_lag1),
      delta_suhu = as.numeric(live_fit$model_frame$delta_suhu),
      hei = as.numeric(live_fit$model_frame$hei),
      sarima = as.numeric(live_fit$model_frame$sarima),
      residual = as.numeric(live_fit$model_frame$residual),
      xgb_residual = as.numeric(live_fit$model_frame$xgb_residual),
      xgb_price = as.numeric(live_fit$model_frame$xgb_price),
      residual_hybrid = as.numeric(live_fit$model_frame$residual_hybrid),
      future_jump = as.numeric(live_fit$model_frame$future_jump),
      heat_flag = as.integer(live_fit$model_frame$heat_flag),
      margin_flag = as.integer(live_fit$model_frame$margin_flag),
      gagal_distribusi = as.integer(live_fit$model_frame$gagal_distribusi),
      distribution_stress_score = as.numeric(live_fit$model_frame$distribution_stress_score),
      status = as.character(live_fit$model_frame$status),
      stringsAsFactors = FALSE
    ),
    forecast = forecast_data,
    live_forecast = live_forecast,
    test = test_result,
    test_metrics = test_metrics,
    validation_metrics = eval_result$validation_metrics,
    final_test_metrics = eval_result$final_test_metrics,
    eval_cfg = eval_result$config,
    eval_n_folds = eval_result$n_folds,
    eval_development_range = eval_result$split$development_range,
    eval_final_test_range = eval_result$split$final_test_range,
    selected_model_key = selected_model_key,
    selected_model = selected_model,
    selection_metric = eval_result$selection_metric,
    selection_value = eval_result$selection_value,
    rolling_test_metrics = rolling_test_metrics,
    rolling_test_long = rolling_test_long,
    xgb_config = live_fit$xgb_config,
    risk_proxy_version = live_fit$risk_proxy_version,
    risk_score_label = live_fit$risk_score_label,
    risk_score_tech_label = live_fit$risk_score_tech_label,
    risk_proxy_parameters = live_fit$risk_proxy_parameters,
    stress_thresholds = live_fit$stress_thresholds,
    risk_predictor_cols = live_fit$risk_predictor_cols,
    risk_training_range = live_fit$risk_training_range,
    shap_reg_summary = live_fit$shap_reg_summary,
    shap_cls_summary = live_fit$shap_cls_summary,
    dep_reg = live_fit$dep_reg,
    dep_cls = live_fit$dep_cls,
    stationarity_label = live_fit$stationarity_label,
    sarima_label = live_fit$sarima_label,
    models = live_fit$models
  )
}

build_dashboard_state <- function(commodity = NULL, app_dir = NULL,
                                  config = dashboard_config(app_dir),
                                  data_loader = load_project_data,
                                  pipeline_builder = build_pipeline,
                                  generated_at = Sys.time()) {
  project_data <- data_loader(commodity, app_dir, config)
  raw_data <- project_data$merged
  pipeline <- pipeline_builder(
    raw_data,
    project_data$bmkg_forecast,
    config$forecast_horizon
  )
  pipeline_data <- pipeline$data
  c(list(
    raw_data = raw_data,
    pipeline_data = pipeline_data,
    forecast_data = pipeline$forecast,
    live_forecast_data = pipeline$live_forecast,
    test_data = pipeline$test,
    test_metrics = pipeline$test_metrics,
    selected_model = pipeline$selected_model,
    rolling_test_metrics = pipeline$rolling_test_metrics,
    rolling_test_long = pipeline$rolling_test_long,
    validation_metrics = pipeline$validation_metrics,
    final_test_metrics = pipeline$final_test_metrics,
    eval_cfg = pipeline$eval_cfg,
    eval_n_folds = pipeline$eval_n_folds,
    eval_development_range = pipeline$eval_development_range,
    eval_final_test_range = pipeline$eval_final_test_range,
    xgb_config = pipeline$xgb_config,
    risk_proxy_version = pipeline$risk_proxy_version,
    risk_score_label = pipeline$risk_score_label,
    risk_score_tech_label = pipeline$risk_score_tech_label,
    risk_proxy_parameters = pipeline$risk_proxy_parameters,
    stress_thresholds = pipeline$stress_thresholds,
    risk_predictor_cols = pipeline$risk_predictor_cols,
    risk_training_range = pipeline$risk_training_range,
    shap_reg_summary = pipeline$shap_reg_summary,
    shap_cls_summary = pipeline$shap_cls_summary,
    dep_reg = pipeline$dep_reg,
    dep_cls = pipeline$dep_cls,
    sarima_label = pipeline$sarima_label,
    stationarity_label = pipeline$stationarity_label,
    current = tail(pipeline_data, 1),
    previous = pipeline_data[nrow(pipeline_data) - 1, ],
    commodity = project_data$commodity,
    commodity_choices = project_data$commodity_choices,
    climate_latest = max(project_data$climate$tanggal, na.rm = TRUE),
    climate_blended_latest = if (is.data.frame(project_data$climate_blended) && nrow(project_data$climate_blended) > 0) max(project_data$climate_blended$tanggal, na.rm = TRUE) else as.Date(NA),
    bmkg_latest = if (is.data.frame(project_data$bmkg_forecast) && nrow(project_data$bmkg_forecast) > 0) max(project_data$bmkg_forecast$tanggal, na.rm = TRUE) else as.Date(NA),
    source_label = project_data$source_label,
    last_refresh_time = generated_at,
    freshness = list(
      generated_at = generated_at,
      commodity = project_data$commodity,
      date_range = range(raw_data$tanggal, na.rm = TRUE),
      methodology_version = config$methodology_version,
      model_identifier = pipeline$selected_model
    ),
    cache_boundaries = list(
      raw_data = project_data$cache_metadata,
      processed_features = list(storage = "session memory", generated_at = generated_at),
      model_artifacts = list(storage = "session memory", generated_at = generated_at)
    )
  ))
}
