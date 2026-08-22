# Distribution stress proxy model (Methodology V2, Sprint 5).

RISK_PROXY_VERSION <- "risk_proxy_v1"
RISK_SCORE_LABEL <- "Skor Risiko Tekanan Distribusi"
RISK_SCORE_TECH_LABEL <- "Distribution Stress Score"
RISK_STATUS_LABELS <- c("Aman", "Waspada", "Darurat")
RISK_PROXY_FIELDS <- c("future_jump", "heat_flag", "margin_flag", "gagal_distribusi")
RISK_FORBIDDEN_PREDICTORS <- c(
  RISK_PROXY_FIELDS,
  "status", "distribution_stress_score", "stress_score",
  "harga", "harga_aktual", "margin_hl"
)

finite_quantile <- function(x, probability, label) {
  x <- as.numeric(x)
  x <- x[is.finite(x)]
  if (length(x) == 0) stop("Tidak ada nilai finite untuk ", label, ".", call. = FALSE)
  as.numeric(stats::quantile(x, probability, names = FALSE, type = 7))
}

future_price_jump <- function(prices, horizon = 3L) {
  prices <- as.numeric(prices)
  if (length(horizon) != 1L || !is.finite(horizon) || horizon < 1) {
    stop("horizon harus bilangan bulat positif.", call. = FALSE)
  }
  horizon <- as.integer(horizon)
  if (length(prices) == 0) return(numeric())
  vapply(seq_along(prices), function(i) {
    if (i >= length(prices) || !is.finite(prices[i]) || prices[i] == 0) return(NA_real_)
    future <- prices[seq.int(i + 1L, min(length(prices), i + horizon))]
    future <- future[is.finite(future)]
    if (length(future) == 0) NA_real_ else max(future) / prices[i] - 1
  }, numeric(1))
}

#' Build the versioned historical proxy label. It is not an observed event label.
build_risk_proxy_v1 <- function(model_frame, horizon = 3L,
                                future_jump_cutoff = 0.10,
                                heat_quantile = 0.75,
                                margin_quantile = 0.80) {
  required <- c("harga", "suhu_puncak_lag1", "margin_hl")
  if (!is.data.frame(model_frame) || !all(required %in% names(model_frame))) {
    stop("Frame proxy harus memiliki: ", paste(required, collapse = ", "), call. = FALSE)
  }
  future_jump <- future_price_jump(model_frame$harga, horizon)
  heat_cutoff <- finite_quantile(model_frame$suhu_puncak_lag1, heat_quantile, "heat threshold")
  margin_cutoff <- finite_quantile(model_frame$margin_hl, margin_quantile, "margin threshold")
  heat_flag <- is.finite(model_frame$suhu_puncak_lag1) & model_frame$suhu_puncak_lag1 >= heat_cutoff
  margin_flag <- is.finite(model_frame$margin_hl) & model_frame$margin_hl >= margin_cutoff
  label <- as.integer((future_jump >= future_jump_cutoff) | (margin_flag & heat_flag))
  label[is.na(label)] <- 0L

  fallback_used <- FALSE
  fallback_cutoff <- NA_real_
  if (length(unique(label)) < 2L) {
    fallback_cutoff <- finite_quantile(future_jump, 0.80, "fallback future-jump threshold")
    label <- as.integer(future_jump >= fallback_cutoff)
    label[is.na(label)] <- 0L
    fallback_used <- TRUE
  }
  if (length(unique(label)) < 2L) {
    stop("risk_proxy_v1 menghasilkan satu kelas saja; data tidak cukup bervariasi.", call. = FALSE)
  }

  fields <- data.frame(
    future_jump = as.numeric(future_jump),
    heat_flag = as.integer(heat_flag),
    margin_flag = as.integer(margin_flag),
    gagal_distribusi = as.integer(label),
    stringsAsFactors = FALSE
  )
  list(
    version = RISK_PROXY_VERSION,
    fields = fields,
    target = fields$gagal_distribusi,
    target_name = "gagal_distribusi",
    formula = "future_jump >= 0.10 OR (margin_flag AND heat_flag)",
    parameters = list(
      horizon_days = as.integer(horizon),
      future_jump_cutoff = future_jump_cutoff,
      heat_quantile = heat_quantile,
      margin_quantile = margin_quantile,
      heat_cutoff = heat_cutoff,
      margin_cutoff = margin_cutoff,
      fallback_used = fallback_used,
      fallback_cutoff = fallback_cutoff
    )
  )
}

assert_risk_predictors_safe <- function(predictor_cols) {
  leakage <- intersect(as.character(predictor_cols), RISK_FORBIDDEN_PREDICTORS)
  if (length(leakage) > 0) {
    stop("Predictor risk mengandung field target/hasil turunan: ",
         paste(leakage, collapse = ", "), call. = FALSE)
  }
  invisible(TRUE)
}

derive_stress_thresholds <- function(training_scores,
                                     probabilities = c(1 / 3, 2 / 3)) {
  scores <- as.numeric(training_scores)
  scores <- scores[is.finite(scores)]
  if (length(scores) == 0) stop("Tidak ada score development untuk threshold.", call. = FALSE)
  if (length(probabilities) != 2L || any(!is.finite(probabilities)) ||
      probabilities[1] <= 0 || probabilities[2] >= 1 || probabilities[1] >= probabilities[2]) {
    stop("probabilities harus dua kuantil terurut di dalam (0, 1).", call. = FALSE)
  }
  values <- as.numeric(stats::quantile(scores, probabilities, names = FALSE, type = 7))
  if (values[1] >= values[2]) {
    epsilon <- max(1e-6, diff(range(scores)) * 1e-6)
    values <- c(values[1] - epsilon, values[2] + epsilon)
  }
  list(
    method = "development_score_quantiles",
    probabilities = probabilities,
    values = c(waspada = values[1], darurat = values[2]),
    n_development_scores = length(scores),
    score_range = range(scores)
  )
}

map_stress_status <- function(score, stress_thresholds) {
  values <- if (is.list(stress_thresholds)) stress_thresholds$values else stress_thresholds
  if (is.null(values) || !all(c("waspada", "darurat") %in% names(values)) ||
      values[["waspada"]] >= values[["darurat"]]) {
    stop("stress_thresholds tidak valid.", call. = FALSE)
  }
  as.character(cut(
    as.numeric(score),
    breaks = c(-Inf, values[["waspada"]], values[["darurat"]], Inf),
    labels = RISK_STATUS_LABELS,
    right = FALSE
  ))
}

score_distribution_stress <- function(model, predictor_matrix) {
  as.numeric(predict(model, predictor_matrix))
}

#' Fit the proxy classifier and freeze score bands from its development scores.
fit_risk_proxy_model <- function(predictor_matrix, proxy,
                                 nrounds = 120L) {
  predictor_matrix <- as.matrix(predictor_matrix)
  if (is.null(colnames(predictor_matrix))) stop("Predictor matrix harus bernama.", call. = FALSE)
  assert_risk_predictors_safe(colnames(predictor_matrix))
  if (!is.list(proxy) || is.null(proxy$target)) stop("Proxy label tidak valid.", call. = FALSE)
  if (nrow(predictor_matrix) != length(proxy$target)) {
    stop("Jumlah baris predictor dan proxy tidak sama.", call. = FALSE)
  }
  if (any(!is.finite(predictor_matrix))) stop("Predictor matrix mengandung nilai non-finite.", call. = FALSE)
  if (length(unique(proxy$target)) < 2L) stop("Model risk membutuhkan dua kelas proxy.", call. = FALSE)

  model <- xgboost::xgb.train(
    params = list(
      objective = "binary:logistic", eval_metric = "logloss", max_depth = 3,
      eta = 0.05, subsample = 0.9, colsample_bytree = 0.9, nthread = 1
    ),
    data = xgboost::xgb.DMatrix(data = predictor_matrix, label = proxy$target),
    nrounds = as.integer(nrounds),
    verbose = 0
  )
  training_scores <- score_distribution_stress(model, predictor_matrix)
  list(
    version = RISK_PROXY_VERSION,
    model = model,
    predictor_cols = colnames(predictor_matrix),
    stress_thresholds = derive_stress_thresholds(training_scores),
    training_scores = training_scores,
    proxy = proxy
  )
}
