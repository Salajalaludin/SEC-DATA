test_that("evaluation cache is accepted only for matching final-test dates", {
  avg <- make_synthetic_avg(120)
  config <- eval_config_full()
  split <- split_evaluation_periods(avg, config)
  cache_root <- tempfile("evaluation-cache-")
  dir.create(file.path(cache_root, "cache", "evaluation"), recursive = TRUE)
  cached <- list(
    validation_long = data.frame(tanggal = head(split$development$tanggal, 7)),
    final_test_long = data.frame(tanggal = split$final_test$tanggal),
    validation_metrics = data.frame(),
    final_test_metrics = data.frame(),
    selected_model_key = "naive",
    selected_model = "Naive",
    selection_metric = "WAPE",
    selection_value = 0.1,
    config = config,
    n_folds = 1L,
    split = list(
      development_range = range(split$development$tanggal),
      final_test_range = range(split$final_test$tanggal)
    )
  )
  saveRDS(
    cached,
    evaluation_cache_path(cache_root, "Tomat")
  )

  expect_true(!is.null(read_cached_evaluation(avg, cache_root, "Tomat")))

  shifted <- avg
  shifted$tanggal[nrow(shifted)] <- shifted$tanggal[nrow(shifted)] + 1
  expect_null(read_cached_evaluation(shifted, cache_root, "Tomat"))
})
