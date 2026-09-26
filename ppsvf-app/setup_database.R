#!/usr/bin/env Rscript

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_file <- if (length(script_arg)) sub("^--file=", "", script_arg[[1L]]) else "setup_database.R"
app_dir <- dirname(normalizePath(script_file, winslash = "/", mustWork = TRUE))
source(file.path(app_dir, "R", "load_backend.R"))

db_file <- Sys.getenv("PPSV_DB_FILE", unset = "")
if (!nzchar(db_file)) {
  if (!identical(tolower(Sys.getenv("AUTH_MODE", unset = "ldap")), "test")) {
    stop("PPSV_DB_FILE is required outside AUTH_MODE=test; refusing to create mutable state in the application release.")
  }
  db_file <- file.path(app_dir, "ppsv_projects.db")
}
config <- ppsv_config(list(app_dir = app_dir, db_file = db_file))
if (ppsv_env_flag("PPSV_RESET_DB", FALSE)) {
  stop("PPSV_RESET_DB is not supported by the operator initializer. Select a new, absent PPSV_DB_FILE instead.")
}
path <- ppsv_initialize_database(config, reset = FALSE)
con <- ppsv_db_connect(config)
on.exit(DBI::dbDisconnect(con), add = TRUE)
schema_version <- DBI::dbGetQuery(
  con,
  "SELECT COALESCE(MAX(version),0) AS version FROM schema_migrations"
)$version[[1L]]
module_count <- DBI::dbGetQuery(
  con,
  "SELECT count(*) AS count FROM service_modules WHERE active=1"
)$count[[1L]]
message("PPSV database ready: ", path)
message("Schema version: ", schema_version, "; active service modules: ", module_count, ".")
message("Existing recognized PPSV schemas are migrated transactionally; unrecognized/legacy databases are rejected.")
