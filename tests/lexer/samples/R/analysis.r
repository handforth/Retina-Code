#!/usr/bin/env Rscript
# R lexer stress: raw strings, backtick names, numbers, operators, formulas
# R has no block comments; this sample uses many line comments and if (FALSE) blocks.

#' Roxygen doc comment
#' @param x A numeric vector with "quotes" and 'apostrophes'
#' @return The mean
#' @examples
#' compute_mean(c(1, 2, 3))
#' @export
compute_mean <- function(x, na.rm = TRUE, ...) {
  stopifnot(is.numeric(x))
  mean(x, na.rm = na.rm, ...)
}

library(dplyr)
library("ggplot2")
suppressPackageStartupMessages(require(data.table, quietly = TRUE))

# Strings
s1 <- "double \"quoted\" with \\ backslash"
s2 <- 'single \'quoted\' string'
s3 <- "escapes: \n \t \r \a \b \f \v \0 \x41 \101 \u00e9 \U0001F600 \u{1F600}"
s4 <- "trailing backslash \\"
s5 <- "multi-line
string literal spanning
three lines"
s6 <- 'also multi-line
single-quoted'
s7 <- "comment marker # inside string"
s8 <- 'unterminated single quote at end of line
s9 <- "after"

# Raw strings (R >= 4.0)
r1 <- r"(C:\Users\path\no\escapes)"
r2 <- R"[brackets with "quotes" and 'single']"
r3 <- r"{braces {nested-looking} content}"
r4 <- r"-(dash delimited )" still inside )-"
r5 <- r"---(three dashes )--" still )---"
r6 <- r'(single-quoted raw string)'
r7 <- r"(multi-line
raw string with \n literal
)"

# Backtick-quoted names
`my variable` <- 10
`if` <- function() "shadowing a keyword name"
df <- data.frame(`col one` = 1:3, `col-two` = letters[1:3], check.names = FALSE)
df$`col one`
`%+%` <- function(a, b) paste0(a, b)
"a" %+% "b"

# Numbers
n1 <- 42
n2 <- 42L
n3 <- 3.14
n4 <- .5
n5 <- 1e10
n6 <- 1.5e-3
n7 <- 0xFF
n8 <- 0xFFL
n9 <- 1i
n10 <- 2.5i
n11 <- 0x1p4
n12 <- 1e5L
n13 <- Inf
n14 <- -Inf
n15 <- NaN
n16 <- NA_integer_
n17 <- NA_real_
n18 <- NA_character_
n19 <- TRUE; n20 <- FALSE; n21 <- T; n22 <- NULL

# Operators
x <- 5; y = 3; 10 -> z; 20 ->> zz; w <<- 1
ops <- c(x + y, x - y, x * y, x / y, x ^ y, x ** y, x %% y, x %/% y,
         x %in% 1:10, x == y, x != y, x < y, x <= y, x > y, x >= y,
         !TRUE, TRUE & FALSE, TRUE && FALSE, TRUE | FALSE, TRUE || FALSE)
m <- matrix(1:4, 2) %*% matrix(4:1, 2)
o <- 1:10 %o% 1:2
seq_vec <- -5:5

# Pipes
result <- mtcars |>
  subset(cyl == 4) |>
  transform(kpl = mpg * 0.425144) |>
  head(n = 5)

result2 <- mtcars %>%
  filter(cyl > 4, !is.na(mpg)) %>%
  group_by(gear) %>%
  summarise(avg = mean(mpg), n = n(), .groups = "drop") %>%
  arrange(desc(avg))

# Lambda shorthand (R >= 4.1)
squares <- sapply(1:5, \(i) i^2)
add <- \(a, b = 2) a + b

# Formulas
fit <- lm(mpg ~ wt + hp + I(hp^2) + factor(cyl), data = mtcars)
fit2 <- glm(am ~ . - qsec, family = binomial(link = "logit"), data = mtcars)
summary(fit)$coefficients[, "Pr(>|t|)"]

# Control flow
for (i in seq_len(3)) {
  if (i %% 2 == 0) next
  else if (i > 10) break
  print(sprintf("i = %d, sq = %.2f", i, i^2))
}
while (FALSE) {}
repeat { break }
val <- switch("b", a = "first", b = , c = "b or c", "default")

if (FALSE) {
  # Pseudo block comment idiom
  this code never runs "but is still lexed"
}

# S4 and R5
setClass("Person", representation(name = "character", age = "numeric"))
setGeneric("greet", function(obj, ...) standardGeneric("greet"))
setMethod("greet", "Person", function(obj, ...) cat("Hi,", obj@name, "\n"))
p <- new("Person", name = "Ada", age = 36)
greet(p)

Account <- setRefClass("Account",
  fields = list(balance = "numeric"),
  methods = list(
    deposit = function(x) {
      balance <<- balance + x
      invisible(.self)
    }
  )
)

# Indexing
lst <- list(a = 1, b = list(c = "deep"))
lst[["b"]][["c"]]
lst$b$c
v <- c(a = 1, b = 2)[-1]
df[df$`col one` > 1, , drop = FALSE]

# Namespaces and formulas with backticks
stats::median(c(1, 2, 3))
base:::`%||%`
ggplot(df, aes(x = `col one`, y = after_stat(count))) + geom_bar()

# Dots and special names
f <- function(...) { args <- list(...); ..1 }
.hidden <- 1
..reserved <- 2
x.y.z <- 3
._ <- 4

invisible(NULL)
