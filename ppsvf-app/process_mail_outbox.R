#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_file <- if (length(script_arg)) sub("^--file=", "", script_arg[[1L]]) else "process_mail_outbox.R"
app_dir <- dirname(normalizePath(script_file, winslash = "/", mustWork = TRUE))
source(file.path(app_dir, "R", "load_backend.R"))

db_file <- Sys.getenv("PPSV_DB_FILE", file.path(app_dir, "ppsv_projects.db"))
ctx <- ppsv_initialize(ppsv_config(list(app_dir = app_dir, db_file = db_file)))
limit <- suppressWarnings(as.integer(Sys.getenv("PPSV_MAIL_BATCH_SIZE", "25")))
if (is.na(limit) || limit < 1L) stop("PPSV_MAIL_BATCH_SIZE must be a positive integer.")
result <- ppsv_process_mail_outbox(limit = limit, ctx = ctx)
message(sprintf("PPSV outbox: processed=%d sent=%d failed=%d", result$processed, result$sent, result$failed))
if (result$failed > 0L) quit(status = 2L)
