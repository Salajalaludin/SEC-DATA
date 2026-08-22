# Build the self-contained directory uploaded to shinyapps.io.
#
# Usage from the repository root:
#   Rscript scripts/build_shinyapps_bundle.R [repository_directory]

args <- commandArgs(trailingOnly = TRUE)
repo_dir <- if (length(args) > 0 && nzchar(args[[1]])) args[[1]] else getwd()
repo_dir <- normalizePath(repo_dir, winslash = "/", mustWork = TRUE)
bundle_dir <- file.path(repo_dir, "deploy_bundle")
app_dir <- file.path(repo_dir, "cilegon_komoditas_shiny")

stop_if_missing <- function(paths, label) {
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0) {
    stop(
      label, " tidak ditemukan: ", paste(basename(missing), collapse = ", "),
      call. = FALSE
    )
  }
}

copy_tree <- function(source_dir, target_dir, exclude = character()) {
  stop_if_missing(source_dir, "Direktori sumber")
  dir.create(target_dir, recursive = TRUE, showWarnings = FALSE)

  source_files <- list.files(
    source_dir,
    all.files = TRUE,
    recursive = TRUE,
    full.names = TRUE,
    include.dirs = FALSE
  )
  if (length(source_files) == 0) return(invisible(NULL))

  relative_files <- substring(source_files, nchar(source_dir) + 2L)
  keep <- !basename(relative_files) %in% exclude
  source_files <- source_files[keep]
  relative_files <- relative_files[keep]
  if (length(source_files) == 0) return(invisible(NULL))

  target_files <- file.path(target_dir, relative_files)
  for (target_dir_path in unique(dirname(target_files))) {
    dir.create(target_dir_path, recursive = TRUE, showWarnings = FALSE)
  }
  copied <- file.copy(source_files, target_files, overwrite = TRUE)
  if (!all(copied)) stop("Gagal menyalin sebagian isi ", source_dir, call. = FALSE)
  invisible(NULL)
}

dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)

# Only generated paths inside deploy_bundle are removed. README.md and
# .gitignore remain tracked; no repository source or cache is touched.
generated_dirs <- file.path(bundle_dir, c("R", "modules", "www", "cache", "rsconnect"))
generated_files <- c(
  file.path(bundle_dir, "app.R"),
  list.files(bundle_dir, pattern = "^Data komoditas .*\\.xlsx$", full.names = TRUE)
)
for (path in c(generated_dirs, generated_files)) {
  if (dir.exists(path)) unlink(path, recursive = TRUE, force = TRUE)
  if (file.exists(path)) unlink(path, force = TRUE)
}

stop_if_missing(
  c(
    file.path(app_dir, "app.R"),
    file.path(repo_dir, "R"),
    file.path(app_dir, "modules"),
    file.path(app_dir, "www")
  ),
  "Komponen aplikasi"
)

workbooks <- list.files(
  app_dir,
  pattern = "^Data komoditas .*\\.xlsx$",
  full.names = TRUE,
  ignore.case = TRUE
)
if (length(workbooks) == 0) stop("Tidak ada workbook komoditas untuk bundle.", call. = FALSE)

cache_names <- c(
  "sagon_daily_long.rds",
  "bmkg_forecast_daily.rds",
  "era5_daily.rds",
  "era5_daily_bandung_cilegon.rds"
)
cache_files <- file.path(app_dir, "cache", cache_names)
stop_if_missing(cache_files, "Cache runtime wajib")
evaluation_cache_dir <- file.path(app_dir, "cache", "evaluation")
evaluation_cache_files <- if (dir.exists(evaluation_cache_dir)) {
  list.files(
    evaluation_cache_dir,
    pattern = "^evaluation_.*[.]rds$",
    full.names = TRUE,
    ignore.case = TRUE
  )
} else {
  character()
}

if (!file.copy(file.path(app_dir, "app.R"), file.path(bundle_dir, "app.R"), overwrite = TRUE)) {
  stop("Gagal menyalin app.R.", call. = FALSE)
}
# NetCDF/terra code remains available to local refresh scripts but is not part
# of the hosted cache-only runtime bundle.
copy_tree(
  file.path(repo_dir, "R"),
  file.path(bundle_dir, "R"),
  exclude = "era5_netcdf.R"
)
copy_tree(file.path(app_dir, "modules"), file.path(bundle_dir, "modules"))
copy_tree(file.path(app_dir, "www"), file.path(bundle_dir, "www"))

if (!all(file.copy(workbooks, file.path(bundle_dir, basename(workbooks)), overwrite = TRUE))) {
  stop("Gagal menyalin workbook komoditas.", call. = FALSE)
}
dir.create(file.path(bundle_dir, "cache"), recursive = TRUE, showWarnings = FALSE)
if (!all(file.copy(cache_files, file.path(bundle_dir, "cache", cache_names), overwrite = TRUE))) {
  stop("Gagal menyalin cache runtime.", call. = FALSE)
}
if (length(evaluation_cache_files) > 0) {
  dir.create(file.path(bundle_dir, "cache", "evaluation"), recursive = TRUE, showWarnings = FALSE)
  if (!all(file.copy(
    evaluation_cache_files,
    file.path(bundle_dir, "cache", "evaluation", basename(evaluation_cache_files)),
    overwrite = TRUE
  ))) {
    stop("Gagal menyalin cache evaluasi.", call. = FALSE)
  }
}

bundle_files <- list.files(bundle_dir, recursive = TRUE, full.names = FALSE)
cat("Bundle shinyapps.io siap:", bundle_dir, "\n")
cat("Jumlah file:", length(bundle_files), "\n")
cat(
  "Workbooks:", length(workbooks), "| Cache:", length(cache_files),
  "| Evaluation cache:", length(evaluation_cache_files), "\n"
)
