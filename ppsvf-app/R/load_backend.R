# Source this file once from app.R, setup scripts, tests, or maintenance jobs.

ppsv_source_files <- vapply(
  sys.frames(),
  function(frame) {
    value <- frame$ofile
    if (is.null(value) || !length(value)) "" else as.character(value[[1L]])
  },
  character(1L)
)
ppsv_loader_matches <- ppsv_source_files[basename(ppsv_source_files) == "load_backend.R"]
ppsv_loader_file <- if (length(ppsv_loader_matches)) tail(ppsv_loader_matches, 1L) else NULL
ppsv_backend_dir <- if (!is.null(ppsv_loader_file)) {
  dirname(normalizePath(ppsv_loader_file, winslash = "/", mustWork = TRUE))
} else {
  file.path(getwd(), "R")
}

for (ppsv_backend_file in c(
  "config.R", "auth.R", "validation.R", "database.R", "context.R",
  "repository.R", "storage.R", "mail.R", "outbox_repository.R", "lifecycle.R", "pdf.R"
)) {
  source(file.path(ppsv_backend_dir, ppsv_backend_file), local = FALSE)
}
rm(ppsv_backend_file, ppsv_backend_dir, ppsv_loader_file, ppsv_loader_matches, ppsv_source_files)
