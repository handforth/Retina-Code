# Second R sample: data pipeline, sprintf/glue strings, ends inside an unterminated raw string
suppressWarnings({
  library(stats)
  library(utils)
})

options(stringsAsFactors = FALSE, digits = 4, warn = 1)

CONFIG <- list(
  input   = "data/input.csv",
  output  = 'out/result.rds',
  sep     = ",",
  quote   = "\"",
  na      = c("", "NA", "N/A", "\\N"),
  pattern = "^\\d{4}-\\d{2}-\\d{2}$",
  regex2  = r"(^\d{4}-\d{2}-\d{2}$)",
  win     = "C:\\data\\file.csv",
  winraw  = r"[C:\data\file.csv]"
)

log_msg <- function(fmt, ...) {
  msg <- sprintf(paste0("[%s] ", fmt), format(Sys.time(), "%H:%M:%S"), ...)
  message(msg)
  invisible(msg)
}

read_data <- function(path = CONFIG$input) {
  if (!file.exists(path)) {
    log_msg("file '%s' not found; generating synthetic data", path)
    set.seed(42L)
    n <- 1e3L
    return(data.frame(
      id    = seq_len(n),
      date  = as.Date("2024-01-01") + sample(0:365, n, replace = TRUE),
      group = sample(c("a", "b", "c"), n, replace = TRUE, prob = c(.5, .3, .2)),
      value = rnorm(n, mean = 100, sd = 15),
      flag  = runif(n) > 0.9
    ))
  }
  utils::read.csv(path, sep = CONFIG$sep, quote = CONFIG$quote, na.strings = CONFIG$na)
}

clean <- function(df) {
  df <- df[!is.na(df$value) & is.finite(df$value), ]
  df$value[df$value < 0] <- 0
  df$z <- (df$value - mean(df$value)) / sd(df$value)
  df$month <- format(df$date, "%Y-%m")
  df$label <- ifelse(df$flag, "flagged", 'ok')
  df
}

summarise_groups <- function(df) {
  agg <- aggregate(value ~ group + month, data = df, FUN = function(v) {
    c(mean = mean(v), median = median(v), n = length(v))
  })
  do.call(data.frame, agg)
}

outliers <- function(df, k = 1.5) {
  q <- quantile(df$value, c(.25, .75), names = FALSE)
  iqr <- diff(q)
  df[df$value < q[1] - k * iqr | df$value > q[2] + k * iqr, c("id", "value")]
}

report <- function(df, groups, out) {
  cat("Rows:", nrow(df), "\n")
  cat("Groups:\n")
  print(head(groups, 10))
  cat(sprintf("%-10s %8.2f %8.2f\n", "overall", mean(df$value), sd(df$value)))
  cat("Outliers:", nrow(out), "(", round(100 * nrow(out) / nrow(df), 1), "%)\n", sep = " ")
  cat('Single-quoted with "double" inside and a tab\there\n')
  cat("Unicode: \u00e9\u00e8 \U0001F4C8\n")
}

main <- function(args = commandArgs(trailingOnly = TRUE)) {
  verbose <- "--verbose" %in% args || "-v" %in% args
  df <- read_data()
  df <- clean(df)
  groups <- summarise_groups(df)
  out <- outliers(df)
  if (verbose) report(df, groups, out)
  dir.create(dirname(CONFIG$output), showWarnings = FALSE, recursive = TRUE)
  saveRDS(list(data = df, groups = groups, outliers = out), CONFIG$output)
  log_msg("wrote %s (%d bytes)", CONFIG$output, file.size(CONFIG$output))
  invisible(0L)
}

tryCatch(
  main(),
  warning = function(w) log_msg("warning: %s", conditionMessage(w)),
  error = function(e) {
    log_msg("error: %s", conditionMessage(e))
    quit(status = 1L)
  },
  finally = log_msg("done")
)

# Environment manipulation and quoting
e <- new.env()
assign("x", 1, envir = e)
get("x", envir = e)
q <- quote(a + b * c)
bq <- bquote(.(q) / 2)
substitute(x <- x + 1, list(x = as.name("y")))
expr <- expression(1 + 2, "string", `name`)
fn_body <- body(function(x) x^2)

# Apply family and closures
make_scaler <- function(k) {
  force(k)
  function(x) x * k
}
scalers <- lapply(1:3, make_scaler)
vals <- vapply(scalers, function(f) f(10), numeric(1))
mat <- outer(1:3, 1:4, FUN = "*")
apply(mat, c(1, 2), function(v) if (v %% 2 == 0) "even" else "odd")
mapply(function(a, b) paste(a, b, sep = "-"), letters[1:3], LETTERS[1:3])
Reduce(`+`, 1:10, accumulate = TRUE)
Filter(Negate(is.null), list(1, NULL, 2))
Map(\(k, v) sprintf("%s=%s", k, v), c("a", "b"), c(1, 2))

# String functions with regexes
gsub("(\\w+)@(\\w+)", "\\2 at \\1", "user@example")
regmatches("a1b22c333", gregexpr("[0-9]+", "a1b22c333"))
sprintf("%5.1f%%", 12.345)
format(1234567.891, big.mark = ",", nsmall = 2)
trimws("  padded  ", which = "both")
strsplit("a,b;c", "[,;]")[[1]]

# Odd numeric forms
nums <- c(0x10, 0X1f, 1e-300, 1E+3, 100L, 0x10L, 1e3L, .1e1, 2i, 0i, 1.L)

# Operators that look like comments or strings
a <- 5 # comment after code with 'quote
b <- "string # not a comment"
c <- '#also not a comment'
d <- `#weird name#`

# Raw strings at line boundaries that DO close
closed_raw <- r"[
  [brackets] inside ]" is not the closer when the delimiter is [
]"
closed_dash <- R"--{
  }" and }-" are not closers
}--"

# A raw string that never closes: everything below is string content.
template <- r"---(
<html>
  <body>
    <p>Generated report: )--- is not the closer</p>
    <p>"quotes" and 'apostrophes' and # hashes</p>
  </body>
</html>
main()
