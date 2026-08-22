# Run the authoritative time-series evaluation and model selection (Methodology V2, Sprint 4).
#
# Full protocol: development period -> rolling-origin validation (expanding
# window, model refit at every origin) -> untouched final test. Produces a
# per-model metrics artifact (CSV) and prints results.
#
# Usage (from repository root):
#   Rscript --vanilla scripts/run_evaluation.R [commodity] [--full|--bounded]
# Examples:
#   Rscript --vanilla scripts/run_evaluation.R Tomat --full
#   Rscript --vanilla scripts/run_evaluation.R
#   Rscript --vanilla scripts/run_evaluation.R --all --full   # every commodity

args <- commandArgs(trailingOnly = TRUE)
want_all <- any(tolower(args) == "--all")
use_full <- if (any(tolower(args) == "--full")) TRUE else if (any(tolower(args) == "--bounded")) FALSE else TRUE
commodity_arg <- args[!tolower(args) %in% c("--all", "--full", "--bounded")]

# `--vanilla` skips the project profile, so add the restored renv library when
# it exists. This keeps the documented command runnable on a clean checkout.
project_libs <- c(
  Sys.glob(file.path("renv", "library", "*", "R-*", "*")),
  Sys.glob(file.path("renv", "library", "R-*", "*"))
)
project_libs <- project_libs[dir.exists(project_libs)]
if (length(project_libs) > 0) .libPaths(unique(c(project_libs, .libPaths())))

# Sourcing app.R loads the shared data-loading helpers (load_project_data,
# prepare_avg_frame) and the repository modules (R/*.R). It also builds the
# default dashboard state once; that is accepted overhead for this script.
suppressPackageStartupMessages({
  library(forecast)
  library(xgboost)
})
source("cilegon_komoditas_shiny/app.R", local = FALSE)

app_dir <- "cilegon_komoditas_shiny"

run_one <- function(commodity, cfg) {
  cat("\n==== Evaluation for:", commodity, "====\n")
  pd <- load_project_data(commodity, app_dir)
  avg <- prepare_avg_frame(pd$merged)
  avg <- avg[order(avg$tanggal), ]
  ev <- evaluate_pipeline(avg, cfg)
  cat("development:", as.character(ev$split$development_range[1]), "to",
      as.character(ev$split$development_range[2]), "\n")
  cat("final test :", as.character(ev$split$final_test_range[1]), "to",
      as.character(ev$split$final_test_range[2]), " (n =", nrow(ev$final_test_long), ")\n")
  cat("validation folds:", ev$n_folds, " (n rows =", nrow(ev$validation_long), ")\n")
  cat("--- validation metrics ---\n")
  print(ev$validation_metrics, row.names = FALSE)
  cat("selected champion:", ev$selected_model, "(", ev$selected_model_key,
      ") by validation", ev$selection_metric, "=", ev$selection_value, "\n")
  cat("--- final test metrics ---\n")
  print(ev$final_test_metrics, row.names = FALSE)
  ev
}

cfg <- if (use_full) eval_config_full() else eval_config()
cat("Evaluation config:", paste(names(cfg), unlist(cfg), sep = "=", collapse = ", "), "\n")
cat("mode:", if (use_full) "FULL protocol" else "bounded\n")

commodities <- if (want_all) load_project_data(NULL, app_dir)$commodity_choices else {
  if (length(commodity_arg) > 0) commodity_arg else "Tomat"
}

out_dir <- "cilegon_komoditas_shiny/cache/evaluation"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

results <- lapply(commodities, function(com) {
  ev <- run_one(com, cfg)
  write.csv(ev$final_test_metrics,
            file.path(out_dir, sprintf("final_test_metrics_%s.csv", gsub(" ", "_", com))),
            row.names = FALSE)
  write.csv(ev$validation_metrics,
            file.path(out_dir, sprintf("validation_metrics_%s.csv", gsub(" ", "_", com))),
            row.names = FALSE)
  saveRDS(ev, file.path(out_dir, sprintf("evaluation_%s.rds", gsub(" ", "_", com))))
  invisible(ev)
})

cat("\nArtifacts written to:", out_dir, "\n")
cat("Done.\n")
