# features.R — Shared feature builder (Methodology V2, Sprint 2)
#
# Centralised, reusable feature engineering for the forecasting models. The
# same feature definitions are used for:
#   - training (build_training_features)
#   - validation/test and live inference (build_future_feature_row)
#
# ---------------------------------------------------------------------------
# INFORMATION TIMESTAMP RULE
# ---------------------------------------------------------------------------
# For a prediction target Y[t] (price on day t), any feature derived from
# market price must use information available no later than t-1. Features are
# classified below by the timestamp of the information they carry.
#
#   * historical market feature  -> available at t-1 or earlier
#   * observed climate feature   -> ERA5 observation for day t (used in
#                                   training as a historical pseudo-forecast)
#   * forecast climate feature   -> BMKG forecast for day t (used at inference)
#   * calendar feature           -> derived from the target date itself
#
# FEATURE -> CLASS -> INFORMATION TIMESTAMP (for target day t)
#   harga_kemarin    historical market   t-1
#   lag2             historical market   t-2
#   lag3             historical market   t-3
#   lag7             historical market   t-7
#   ma7              historical market   mean(harga[t-7..t-1])
#   vol7             historical market   sd(harga[t-7..t-1])
#   min7             historical market   min(harga[t-7..t-1])
#   max7             historical market   max(harga[t-7..t-1])
#   margin_hl_lag1   historical market   margin_hl[t-1] (same-day margin lagged)
#   suhu_puncak_lag1 observed climate    t-1
#   delta_suhu       climate (obs/forecast)  suhu[t] - suhu[t-1]
#   hei              climate (obs/forecast)  f(suhu[t-1], humidity[t])
#   suhu_puncak      climate (obs/forecast)  day t
#   kelembaban       climate (obs/forecast)  day t
#   hujan            climate (obs/forecast)  day t
#   day_of_week      calendar               day t
#   month            calendar               day t
#
# CLIMATE TIMING LIMITATION (documented, not hidden leakage):
# Historical BMKG forecasts are not stored in this repository. In training,
# same-day climate (suhu_puncak/kelembaban/hujan at day t) uses OBSERVED ERA5 as
# a historical pseudo-forecast, whereas live H+1..H+3 inference uses the BMKG
# forecast for the same day. The structural mapping is identical; the residual
# difference between observed-ERA5 and forecast-BMKG values is a known
# limitation until historical forecasts are archived. No market-price feature
# for day t reads harga[t]; same-day margin is used only for the risk proxy
# label (nowcasting) and is never a forecasting predictor.
#
# MARKET MARGIN SPLIT (no mixing of nowcasting and forecasting):
#   margin_hl      same-day margin across markets  -> NOWCAST / risk proxy label
#   margin_hl_lag1 margin_hl lagged by one day     -> FORECASTING predictor

# ---------------------------------------------------------------------------
# Price lags (positional on the sorted price series)
# ---------------------------------------------------------------------------

#' Positional price lags up to 7 days.
#'
#' @param prices numeric vector (sorted by date, position i = day i).
#' @return data.frame with harga_kemarin (t-1), lag2 (t-2), lag3 (t-3),
#'   lag7 (t-7); NA where history is insufficient.
price_lag_feats <- function(prices) {
  n <- length(prices)
  if (n == 0) {
    return(data.frame(harga_kemarin = numeric(), lag2 = numeric(),
                      lag3 = numeric(), lag7 = numeric()))
  }
  data.frame(
    harga_kemarin = c(NA_real_, head(prices, -1)),
    lag2 = c(rep(NA_real_, 2), head(prices, -2)),
    lag3 = c(rep(NA_real_, 3), head(prices, -3)),
    lag7 = c(rep(NA_real_, 7), head(prices, -7))
  )
}

# ---------------------------------------------------------------------------
# Rolling statistics over the 7 PRIOR days [t-7 .. t-1]
# ---------------------------------------------------------------------------

#' Rolling mean/sd/min/max over the k prior days (excludes the current value).
#'
#' For position i, uses prices[i-k .. i-1]. NA until k prior observations
#' exist (insufficient-history rows must be dropped by the caller).
#'
#' @param prices numeric vector (sorted by date).
#' @param k integer, rolling window length (default 7).
#' @return data.frame with ma7, vol7, min7, max7.
rolling_prior_feats <- function(prices, k = 7) {
  n <- length(prices)
  ma7 <- vol7 <- min7 <- max7 <- rep(NA_real_, n)
  if (n > k) {
    for (i in (k + 1):n) {
      win <- prices[(i - k):(i - 1)]
      ma7[i] <- mean(win, na.rm = TRUE)
      vol7[i] <- stats::sd(win, na.rm = TRUE)
      min7[i] <- min(win, na.rm = TRUE)
      max7[i] <- max(win, na.rm = TRUE)
    }
  }
  data.frame(ma7 = ma7, vol7 = vol7, min7 = min7, max7 = max7)
}

#' Prior market-price features (lags + rolling), position-aligned.
#'
#' Row i holds the features for target day i using only prices[i-1..i-7].
#' For inference, append a placeholder (NA) for the target day and take the
#' last row: the placeholder is never read because prior features only look
#' backwards. This guarantees training and inference use identical definitions.
#'
#' @param prices numeric vector (sorted by date).
#' @return data.frame with harga_kemarin, lag2, lag3, lag7, ma7, vol7, min7,
#'   max7.
prior_price_features <- function(prices) {
  cbind(price_lag_feats(prices), rolling_prior_feats(prices))
}

# ---------------------------------------------------------------------------
# Market margin
# ---------------------------------------------------------------------------

#' Lagged market margin (forecasting predictor).
#'
#' margin_hl_lag1[t] = margin_hl[t-1]. margin_hl is the same-day price range
#' across markets (nowcast-only field); only its lag is used as a predictor.
#'
#' @param margin_hl numeric vector of same-day margins (sorted by date).
#' @return data.frame with margin_hl_lag1 (NA for the first row).
margin_lag_feats <- function(margin_hl) {
  n <- length(margin_hl)
  data.frame(margin_hl_lag1 = c(NA_real_, head(margin_hl, -1)))
}

# ---------------------------------------------------------------------------
# Climate prior (lagged) features
# ---------------------------------------------------------------------------

#' Lagged peak temperature (available at prediction time).
#'
#' @param suhu_puncak numeric vector (sorted by date).
#' @return data.frame with suhu_puncak_lag1 (NA for the first row).
climate_prior_feats <- function(suhu_puncak) {
  n <- length(suhu_puncak)
  data.frame(suhu_puncak_lag1 = c(NA_real_, head(suhu_puncak, -1)))
}

# ---------------------------------------------------------------------------
# Batch builder for training / evaluation
# ---------------------------------------------------------------------------

#' Build all model features on a training/evaluation frame.
#'
#' Input `avg` must be a sorted frame restricted to "Harga rata-rata" with
#' columns: tanggal, harga, suhu_puncak, kelembaban, hujan, margin_hl
#' (same-day margin, kept for the risk proxy label). Rows with insufficient
#' history receive NA for the affected features and must be dropped by the
#' caller (fit_pipeline_models uses complete.cases()).
#'
#' @param avg data.frame as described.
#' @return `avg` plus all forecasting feature columns.
build_training_features <- function(avg) {
  prior <- prior_price_features(avg$harga)
  mf <- margin_lag_feats(avg$margin_hl)
  cf <- climate_prior_feats(avg$suhu_puncak)

  out <- avg
  out$harga_kemarin <- prior$harga_kemarin
  out$lag2 <- prior$lag2
  out$lag3 <- prior$lag3
  out$lag7 <- prior$lag7
  out$ma7 <- prior$ma7
  out$vol7 <- prior$vol7
  out$min7 <- prior$min7
  out$max7 <- prior$max7
  out$margin_hl_lag1 <- mf$margin_hl_lag1
  out$suhu_puncak_lag1 <- cf$suhu_puncak_lag1
  out$delta_suhu <- c(0, diff(avg$suhu_puncak))
  out$hei <- pmax(out$suhu_puncak_lag1 - 32, 0) * pmax(82 - out$kelembaban, 0)
  out$day_of_week <- factor(weekdays(out$tanggal),
                            levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"))
  out$month <- factor(format(out$tanggal, "%m"))
  out
}

# ---------------------------------------------------------------------------
# Per-day builder for validation/test and live inference
# ---------------------------------------------------------------------------

#' Build one feature row for a single target day t.
#'
#' The same definitions as build_training_features(); used iteratively by the
#' forecast path (prices may include previously predicted values for multi-step
#' forecasts). Returns exactly the columns the model matrix needs.
#'
#' @param prices numeric vector of history prices up to t-1 (positional).
#' @param last_margin same-day margin_hl of day t-1 (margin_hl_lag1[t]).
#' @param target_climate_row one-row data.frame(tanggal, suhu_puncak,
#'   kelembaban, hujan) for day t (BMKG forecast at inference; observed ERA5 as
#'   pseudo-forecast in training).
#' @param prev_suhu suhu_puncak of day t-1.
#' @param day_levels character, weekday levels from the training frame.
#' @param month_levels character, month levels from the training frame.
#' @return one-row data.frame with all model feature columns.
build_future_feature_row <- function(prices, last_margin, target_climate_row,
                                     prev_suhu, day_levels, month_levels) {
  ## Prior price features at the target position: append a placeholder (NA)
  ## for the target day; the last row uses only prices up to t-1.
  pf <- tail(prior_price_features(c(prices, NA_real_)), 1)
  data.frame(
    tanggal = as.Date(target_climate_row$tanggal),
    suhu_puncak = as.numeric(target_climate_row$suhu_puncak),
    kelembaban = as.numeric(target_climate_row$kelembaban),
    hujan = as.numeric(target_climate_row$hujan),
    suhu_puncak_lag1 = as.numeric(prev_suhu),
    delta_suhu = as.numeric(target_climate_row$suhu_puncak) - as.numeric(prev_suhu),
    hei = pmax(as.numeric(prev_suhu) - 32, 0) * pmax(82 - as.numeric(target_climate_row$kelembaban), 0),
    harga_kemarin = pf$harga_kemarin,
    lag2 = pf$lag2,
    lag3 = pf$lag3,
    lag7 = pf$lag7,
    ma7 = pf$ma7,
    vol7 = pf$vol7,
    min7 = pf$min7,
    max7 = pf$max7,
    margin_hl_lag1 = as.numeric(last_margin),
    day_of_week = factor(weekdays(as.Date(target_climate_row$tanggal)), levels = day_levels),
    month = factor(format(as.Date(target_climate_row$tanggal), "%m"), levels = month_levels),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Model-matrix alignment
# ---------------------------------------------------------------------------

#' Reorder/align a model matrix to the training feature column order.
#'
#' Missing columns are filled with zeros; extra columns are dropped.
#' Deterministic given `feature_cols`, so inference matrices always match the
#' training matrix column order.
align_future_matrix <- function(mat, feature_cols) {
  missing <- setdiff(feature_cols, colnames(mat))
  if (length(missing) > 0) {
    filler <- matrix(0, nrow = nrow(mat), ncol = length(missing))
    colnames(filler) <- missing
    mat <- cbind(mat, filler)
  }
  mat[, feature_cols, drop = FALSE]
}
