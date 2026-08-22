# Build and upload the application to shinyapps.io.
#
# Credentials must be provided by the caller, never committed:
#   SHINYAPPS_NAME, SHINYAPPS_TOKEN, SHINYAPPS_SECRET
#
# Usage from the repository root:
#   Rscript scripts/deploy_shinyapps_placeholder.R

args <- commandArgs(trailingOnly = TRUE)
file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(file_arg) > 0) sub("^--file=", "", file_arg[[1]]) else "scripts/deploy_shinyapps_placeholder.R"
script_dir <- dirname(normalizePath(script_path, winslash = "/", mustWork = TRUE))
repo_dir <- if (length(args) > 0 && nzchar(args[[1]])) {
  normalizePath(args[[1]], winslash = "/", mustWork = TRUE)
} else {
  normalizePath(file.path(script_dir, ".."), winslash = "/", mustWork = TRUE)
}

required_env <- c("SHINYAPPS_NAME", "SHINYAPPS_TOKEN", "SHINYAPPS_SECRET")
missing_env <- required_env[!nzchar(Sys.getenv(required_env))]
if (length(missing_env) > 0) {
  stop(
    "Set environment variables before upload: ",
    paste(missing_env, collapse = ", "),
    call. = FALSE
  )
}

if (!requireNamespace("rsconnect", quietly = TRUE)) {
  stop("Package 'rsconnect' belum terpasang. Install it outside this repository.", call. = FALSE)
}

build_script <- file.path(repo_dir, "scripts", "build_shinyapps_bundle.R")
bundle_dir <- file.path(repo_dir, "deploy_bundle")
if (!file.exists(build_script)) stop("Builder tidak ditemukan: ", build_script, call. = FALSE)

rscript <- Sys.which("Rscript")
if (!nzchar(rscript)) stop("Rscript tidak ditemukan di PATH.", call. = FALSE)

build_output <- system2(
  rscript,
  c("--vanilla", build_script, repo_dir),
  stdout = TRUE,
  stderr = TRUE
)
cat(build_output, sep = "\n")
build_status <- attr(build_output, "status")
if (!is.null(build_status) && build_status != 0L) {
  stop("Build deployment bundle gagal.", call. = FALSE)
}
if (!file.exists(file.path(bundle_dir, "app.R"))) {
  stop("Bundle tidak memiliki app.R.", call. = FALSE)
}

rsconnect::setAccountInfo(
  name = Sys.getenv("SHINYAPPS_NAME"),
  token = Sys.getenv("SHINYAPPS_TOKEN"),
  secret = Sys.getenv("SHINYAPPS_SECRET"),
  server = "shinyapps.io"
)

rsconnect::deployApp(
  appDir = bundle_dir,
  appName = Sys.getenv("SHINYAPPS_APP_NAME", "sec-data-cilegon"),
  appTitle = Sys.getenv("SHINYAPPS_APP_TITLE", "SEC-DATA Cilegon"),
  account = Sys.getenv("SHINYAPPS_NAME"),
  launch.browser = FALSE,
  forceUpdate = TRUE
)
