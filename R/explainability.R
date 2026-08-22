build_shap_artifacts <- function(reg_model, risk_model, predictor_matrix, model_frame) {
  reg_contrib <- as.data.frame(predict(reg_model, predictor_matrix, predcontrib = TRUE))
  cls_contrib <- as.data.frame(predict(risk_model, predictor_matrix, predcontrib = TRUE))
  reg_contrib <- reg_contrib[, !names(reg_contrib) %in% c("BIAS", "(Intercept)"), drop = FALSE]
  cls_contrib <- cls_contrib[, !names(cls_contrib) %in% c("BIAS", "(Intercept)"), drop = FALSE]

  summarize_contributions <- function(contrib) {
    summary <- data.frame(
      fitur = names(contrib),
      kontribusi = colMeans(abs(contrib), na.rm = TRUE),
      stringsAsFactors = FALSE
    )
    summary <- summary[order(summary$kontribusi, decreasing = TRUE), ][seq_len(min(8, nrow(summary))), ]
    summary$fitur <- factor(summary$fitur, levels = rev(summary$fitur))
    summary
  }

  list(
    shap_reg_summary = summarize_contributions(reg_contrib),
    shap_cls_summary = summarize_contributions(cls_contrib),
    dep_reg = data.frame(
      suhu = model_frame$suhu_puncak_lag1,
      shap = reg_contrib[["suhu_puncak_lag1"]],
      harga = model_frame$harga
    ),
    dep_cls = data.frame(
      suhu = model_frame$suhu_puncak_lag1,
      shap = cls_contrib[["suhu_puncak_lag1"]],
      stress_score = model_frame$distribution_stress_score
    )
  )
}
