#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
})

args <- commandArgs(trailingOnly = TRUE)
source_db <- if (length(args) >= 1L) args[[1L]] else Sys.getenv("PPSV_DB_FILE", unset = "")
backup_file <- if (length(args) >= 2L) args[[2L]] else ""

if (!nzchar(source_db)) stop("Source database path is required.")
if (!nzchar(backup_file)) stop("Backup destination path is required.")
if (!file.exists(source_db)) stop("Source database does not exist: ", source_db)
if (file.exists(backup_file)) stop("Backup destination already exists: ", backup_file)

dir.create(dirname(backup_file), recursive = TRUE, showWarnings = FALSE)

source_con <- dbConnect(SQLite(), source_db)
on.exit(dbDisconnect(source_con), add = TRUE)
invisible(dbExecute(source_con, "PRAGMA busy_timeout = 15000"))

backup_con <- dbConnect(SQLite(), backup_file)
on.exit(dbDisconnect(backup_con), add = TRUE)
RSQLite::sqliteCopyDatabase(source_con, backup_con)

integrity <- dbGetQuery(backup_con, "PRAGMA integrity_check")[[1L]]
if (!identical(integrity, "ok")) {
  stop("Backup integrity check failed: ", paste(integrity, collapse = "; "))
}

Sys.chmod(backup_file, mode = "0660")
message("Verified SQLite backup created: ", normalizePath(backup_file, mustWork = TRUE))
