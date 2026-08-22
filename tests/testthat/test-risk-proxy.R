# Sprint 5 risk proxy, leakage, threshold, and SHAP semantics tests.

make_risk_frame <- function(n = 30) {
  data.frame(
    tanggal = as.Date("2023-01-01") + 0:(n - 1),
    harga = c(seq(100, by = 1, length.out = n - 3), 150, 90, 180),
    suhu_puncak_lag1 = seq(28, 35, length.out = n),
    margin_hl = seq(1, 30, length.out = n)
  )
}

test_that("risk_proxy_v1 generates a versioned proxy label and audit fields", {
  proxy <- build_risk_proxy_v1(make_risk_frame())
  expect_identical(proxy$version, "risk_proxy_v1")
  expect_identical(names(proxy$fields), RISK_PROXY_FIELDS)
  expect_equal(proxy$fields$future_jump[1], max(c(101, 102, 103)) / 100 - 1, tolerance = 1e-12)
  expect_true(all(proxy$target %in% c(0L, 1L)))
  expect_true(length(unique(proxy$target)) == 2L)
})

test_that("future labels and current-row outcomes are absent from predictors", {
  frame <- make_risk_frame()
  proxy <- build_risk_proxy_v1(frame)
  predictors <- c("suhu_puncak", "suhu_puncak_lag1", "delta_suhu", "hei", "hujan",
                  "kelembaban", "harga_kemarin", "lag2", "lag3", "lag7", "ma7",
                  "vol7", "min7", "max7", "margin_hl_lag1", "day_of_week", "month")
  predictor_matrix <- matrix(0, nrow = nrow(frame), ncol = length(predictors),
                             dimnames = list(NULL, predictors))
  expect_silent(assert_risk_predictors_safe(colnames(predictor_matrix)))
  expect_length(intersect(colnames(predictor_matrix), RISK_PROXY_FIELDS), 0)
  expect_error(assert_risk_predictors_safe(c(colnames(predictor_matrix), "future_jump")), "target/hasil")
  expect_identical(proxy$target_name, "gagal_distribusi")
  expect_true(all(c("harga", "margin_hl") %in% names(frame)))
})

test_that("stress thresholds are derived from development scores and then frozen", {
  development_scores <- seq(0.05, 0.95, length.out = 30)
  thresholds <- derive_stress_thresholds(development_scores)
  expected <- as.numeric(stats::quantile(development_scores, c(1 / 3, 2 / 3),
                                         names = FALSE, type = 7))
  expect_equal(unname(thresholds$values), expected)
  expect_identical(thresholds$method, "development_score_quantiles")
  expect_equal(thresholds$n_development_scores, length(development_scores))
  expect_equal(unname(thresholds$values),
               unname(derive_stress_thresholds(development_scores)$values))
  expect_false(any(unname(thresholds$values) ==
                   unname(derive_stress_thresholds(c(development_scores, 0.999, 0.999))$values)))
})

test_that("status mapping is deterministic and uses score bands", {
  thresholds <- list(values = c(waspada = 0.30, darurat = 0.70))
  expected <- c("Aman", "Waspada", "Darurat", NA_character_)
  expect_identical(map_stress_status(c(0.10, 0.30, 0.70, NA), thresholds), expected)
  expect_identical(map_stress_status(c(0.10, 0.30, 0.70, NA), thresholds), expected)
})

test_that("active UI has no legacy probability phrase", {
  root <- find_repo_root()
  active_files <- c(
    "README.md", "cilegon_komoditas_shiny/README.md", "cilegon_komoditas_shiny/app.R",
    "R/model_risk.R", "docs/RISK_PROXY_DEFINITION.md"
  )
  active_text <- paste(unlist(lapply(file.path(root, active_files), readLines, warn = FALSE)), collapse = "\n")
  forbidden_phrase <- paste(c("Probabilitas", "gagal", "distribusi"), collapse = " ")
  expect_false(grepl(forbidden_phrase, active_text, fixed = TRUE))
})

test_that("risk SHAP uses the proxy classifier and remains distinct from regression SHAP", {
  root <- find_repo_root()
  pipeline_text <- paste(readLines(file.path(root, "R/pipeline.R"), warn = FALSE), collapse = "\n")
  explainability_text <- paste(readLines(file.path(root, "R/explainability.R"), warn = FALSE), collapse = "\n")
  shap_ui_text <- paste(readLines(file.path(root, "cilegon_komoditas_shiny/modules/mod_shap.R"), warn = FALSE), collapse = "\n")

  expect_match(pipeline_text, "build_shap_artifacts\\(core\\$models\\$xgb_reg, risk_fit\\$model")
  expect_match(explainability_text, "predict\\(reg_model, predictor_matrix, predcontrib = TRUE\\)")
  expect_match(explainability_text, "predict\\(risk_model, predictor_matrix, predcontrib = TRUE\\)")
  expect_match(shap_ui_text, "contribution to Distribution Stress Score")
  expect_match(shap_ui_text, "contribution to forecast/model prediction")
})
