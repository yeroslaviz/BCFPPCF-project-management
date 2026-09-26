library(testthat)

# Support both documented entry points:
#   Rscript tests/testthat.R       (repository root)
#   Rscript testthat.R             (tests directory)
test_directory <- if (dir.exists(file.path("tests", "testthat"))) {
  file.path("tests", "testthat")
} else if (dir.exists("testthat")) {
  "testthat"
} else {
  stop("Could not locate tests/testthat.", call. = FALSE)
}

test_dir(test_directory, reporter = "summary", stop_on_failure = TRUE)
