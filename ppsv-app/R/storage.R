# Safe external file storage with pool/fallback selection and checksums.

ppsv_safe_original_name <- function(name) {
  value <- basename(ppsv_scalar(name))
  value <- gsub("[[:cntrl:]]", "", value)
  value <- gsub("[^[:alnum:]. _()-]", "_", value)
  value <- sub("^\\.+", "", value)
  value <- trimws(value)
  if (!nzchar(value) || value %in% c(".", "..")) value <- "upload"
  substr(value, 1L, 180L)
}

ppsv_random_stored_name <- function(original_name) {
  if (!requireNamespace("digest", quietly = TRUE)) stop("digest is required for file storage.", call. = FALSE)
  extension <- tools::file_ext(original_name)
  extension <- if (nzchar(extension)) paste0(".", tolower(gsub("[^a-zA-Z0-9]", "", extension))) else ""
  entropy <- paste(Sys.time(), Sys.getpid(), runif(1L), tempfile(), sep = ":")
  paste0(substr(digest::digest(entropy, algo = "sha256", serialize = FALSE), 1L, 32L), extension)
}

ppsv_path_is_within <- function(path, root) {
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  root <- sub("/+$", "", normalizePath(root, winslash = "/", mustWork = TRUE))
  identical(path, root) || startsWith(path, paste0(root, "/"))
}

ppsv_is_symlink <- function(path) {
  target <- Sys.readlink(path)
  length(target) > 0L && !is.na(target[[1L]]) && nzchar(target[[1L]])
}

ppsv_storage_root_usable <- function(root, writable = TRUE) {
  root <- ppsv_scalar(root)
  nzchar(root) && dir.exists(root) && !ppsv_is_symlink(root) &&
    (!isTRUE(writable) || file.access(root, 2L) == 0L)
}

# Production pool writes fail closed unless the configured mount point resolves
# to the exact operator-reviewed source. Tests and explicit local development
# may opt in to a normal directory with PPSV_ALLOW_LOCAL_POOL=1.
ppsv_pool_root_usable <- function(config, writable = TRUE) {
  if (!ppsv_storage_root_usable(config$pool_root, writable = writable)) return(FALSE)
  if (isTRUE(config$allow_local_pool %||% FALSE)) return(TRUE)
  expected <- ppsv_scalar(config$pool_expected_source)
  if (!nzchar(expected) || grepl("REQUIRED", expected, fixed = TRUE)) return(FALSE)
  findmnt <- Sys.which("findmnt")
  if (!nzchar(findmnt)) return(FALSE)
  actual <- tryCatch(
    system2(
      findmnt,
      c("-n", "-o", "SOURCE", "-T", config$pool_root),
      stdout = TRUE,
      stderr = FALSE
    ),
    error = function(error) character()
  )
  identical(length(actual), 1L) && identical(trimws(actual[[1L]]), expected)
}

# Reject links anywhere below the configured root, even when a link resolves
# back into that same root. Stored paths are written canonically by this
# application, so non-canonical or parent-traversing paths are unsafe too.
ppsv_path_has_symlink_component <- function(path, root) {
  root_normal <- sub("/+$", "", normalizePath(root, winslash = "/", mustWork = TRUE))
  path_text <- gsub("\\\\", "/", ppsv_scalar(path), fixed = TRUE)
  if (!identical(path_text, root_normal) && !startsWith(path_text, paste0(root_normal, "/"))) {
    return(TRUE)
  }
  relative <- substring(path_text, nchar(root_normal) + 2L)
  parts <- if (nzchar(relative)) strsplit(relative, "/", fixed = TRUE)[[1L]] else character()
  if (any(parts %in% c("", ".", ".."))) return(TRUE)
  current <- root_normal
  if (ppsv_is_symlink(current)) return(TRUE)
  for (part in parts) {
    current <- file.path(current, part)
    if (ppsv_is_symlink(current)) return(TRUE)
  }
  FALSE
}

ppsv_prepare_fallback_root <- function(root) {
  if (ppsv_is_symlink(root)) {
    ppsv_abort("The PPSV fallback storage root must not be a symbolic link.", "ppsv_storage_error")
  }
  if (!dir.exists(root)) {
    dir.create(root, recursive = TRUE, mode = "2770", showWarnings = FALSE)
  }
  ppsv_storage_root_usable(root)
}

ppsv_select_storage_root <- function(config) {
  if (ppsv_pool_root_usable(config)) {
    return(list(root = config$pool_root, location = "pool"))
  }
  if (ppsv_prepare_fallback_root(config$fallback_root)) {
    Sys.chmod(config$fallback_root, mode = "2770", use_umask = FALSE)
    return(list(root = config$fallback_root, location = "fallback"))
  }
  ppsv_abort("Neither the PPSV pool nor fallback upload storage is writable.", "ppsv_storage_error")
}

ppsv_prepare_storage_directory <- function(root, request_code, category) {
  if (!ppsv_storage_root_usable(root)) {
    ppsv_abort("The PPSV storage root is unavailable, unwritable, or symbolic.", "ppsv_storage_error")
  }
  root_normal <- normalizePath(root, winslash = "/", mustWork = TRUE)
  request_dir <- file.path(root_normal, request_code)
  category_dir <- file.path(request_dir, category)

  for (candidate in c(request_dir, category_dir)) {
    if (ppsv_is_symlink(candidate)) {
      ppsv_abort("Symbolic links are not permitted in PPSV storage paths.", "ppsv_storage_error")
    }
  }
  if (file.exists(request_dir) && !dir.exists(request_dir)) {
    ppsv_abort("The PPSV request storage path is not a directory.", "ppsv_storage_error")
  }
  if (!dir.exists(request_dir) && !dir.create(request_dir, recursive = FALSE, mode = "2770")) {
    ppsv_abort("Could not create the PPSV request storage directory.", "ppsv_storage_error")
  }
  if (ppsv_is_symlink(request_dir)) {
    ppsv_abort("Symbolic links are not permitted in PPSV storage paths.", "ppsv_storage_error")
  }
  if (file.exists(category_dir) && !dir.exists(category_dir)) {
    ppsv_abort("The PPSV file-category path is not a directory.", "ppsv_storage_error")
  }
  if (!dir.exists(category_dir) && !dir.create(category_dir, recursive = FALSE, mode = "2770")) {
    ppsv_abort("Could not create the PPSV file-category directory.", "ppsv_storage_error")
  }
  if (ppsv_is_symlink(category_dir) || !ppsv_path_is_within(category_dir, root_normal)) {
    ppsv_abort("Unsafe PPSV storage path.", "ppsv_storage_error")
  }
  Sys.chmod(request_dir, mode = "2770", use_umask = FALSE)
  Sys.chmod(category_dir, mode = "2770", use_umask = FALSE)
  category_dir
}

ppsv_choose_storage_directory <- function(config, request_code, category) {
  if (ppsv_pool_root_usable(config)) {
    directory <- tryCatch(
      ppsv_prepare_storage_directory(config$pool_root, request_code, category),
      error = function(error) NULL
    )
    if (!is.null(directory)) {
      return(list(root = config$pool_root, location = "pool", directory = directory))
    }
  }
  fallback_usable <- tryCatch(
    ppsv_prepare_fallback_root(config$fallback_root),
    error = function(error) FALSE
  )
  if (isTRUE(fallback_usable)) {
    Sys.chmod(config$fallback_root, mode = "2770", use_umask = FALSE)
    directory <- tryCatch(
      ppsv_prepare_storage_directory(config$fallback_root, request_code, category),
      error = function(error) NULL
    )
    if (!is.null(directory)) {
      return(list(root = config$fallback_root, location = "fallback", directory = directory))
    }
  }
  ppsv_abort("Neither the PPSV pool nor fallback upload storage is writable.", "ppsv_storage_error")
}

ppsv_upload_rows <- function(uploads) {
  if (is.null(uploads) || !length(uploads)) return(list())
  if (is.data.frame(uploads)) {
    return(lapply(seq_len(nrow(uploads)), function(i) as.list(uploads[i, , drop = FALSE])))
  }
  if (is.list(uploads) && !is.null(uploads$datapath)) return(list(uploads))
  if (is.list(uploads)) return(uploads)
  ppsv_abort("Uploads must be a Shiny upload data frame or a list of upload records.", "ppsv_storage_error")
}

ppsv_validate_upload_source <- function(upload) {
  source <- ppsv_scalar(upload$datapath %||% upload$path)
  if (!nzchar(source) || !file.exists(source) || isTRUE(file.info(source)$isdir)) {
    ppsv_abort("An uploaded temporary file is missing or invalid.", "ppsv_storage_error")
  }
  if (ppsv_is_symlink(source)) {
    ppsv_abort("Symbolic-link uploads are not accepted.", "ppsv_storage_error")
  }
  source
}

ppsv_upload_total_bytes <- function(rows) {
  sum(vapply(rows, function(upload) {
    source <- ppsv_validate_upload_source(upload)
    as.numeric(file.info(source)$size)
  }, numeric(1L)))
}

# Copy uploaded temporary files to generated names. The returned data frame is
# suitable for insertion into request_files. On failure, only files created by
# this call are removed.
ppsv_store_uploads <- function(request_code, uploads, category, uploaded_by, config) {
  rows <- ppsv_upload_rows(uploads)
  if (!length(rows)) return(data.frame())
  if (!category %in% c("inputs", "results")) {
    ppsv_abort("File category must be inputs or results.", "ppsv_storage_error")
  }
  if (!grepl("^PPSV[0-9]{6}$", request_code)) {
    ppsv_abort("Unsafe request code for storage.", "ppsv_storage_error")
  }
  total <- ppsv_upload_total_bytes(rows)
  if (total > config$max_upload_mb * 1024^2) {
    ppsv_abort(
      sprintf("Uploads exceed the configured %.0f MB request limit.", config$max_upload_mb),
      "ppsv_storage_error"
    )
  }
  target <- ppsv_choose_storage_directory(config, request_code, category)
  directory <- target$directory

  created <- character()
  on.exit({
    if (length(created)) unlink(created, recursive = FALSE, force = TRUE)
  }, add = TRUE)
  records <- vector("list", length(rows))
  for (i in seq_along(rows)) {
    upload <- rows[[i]]
    source <- ppsv_validate_upload_source(upload)
    original <- ppsv_safe_original_name(upload$name %||% basename(source))
    stored <- ppsv_random_stored_name(original)
    destination <- file.path(directory, stored)
    if (file.exists(destination) || ppsv_is_symlink(destination) ||
        !file.copy(source, destination, overwrite = FALSE, copy.mode = FALSE)) {
      ppsv_abort("Could not copy an upload into PPSV storage.", "ppsv_storage_error")
    }
    created <- c(created, destination)
    if (ppsv_path_has_symlink_component(destination, target$root) ||
        !ppsv_path_is_within(destination, target$root)) {
      ppsv_abort("Unsafe PPSV storage path.", "ppsv_storage_error")
    }
    Sys.chmod(destination, mode = "0660", use_umask = FALSE)
    checksum <- digest::digest(file = destination, algo = "sha256", serialize = FALSE)
    records[[i]] <- data.frame(
      category = category,
      original_name = original,
      stored_name = stored,
      mime_type = ppsv_scalar(upload$type),
      size_bytes = as.numeric(file.info(destination)$size),
      sha256 = checksum,
      storage_location = target$location,
      absolute_path = normalizePath(destination, winslash = "/", mustWork = TRUE),
      uploaded_by = ppsv_normalize_username(uploaded_by),
      stringsAsFactors = FALSE
    )
  }
  result <- do.call(rbind, records)
  attr(result, "created_paths") <- created
  created <- character()
  result
}

ppsv_cleanup_staged_uploads <- function(records) {
  paths <- attr(records, "created_paths") %||% character()
  paths <- paths[file.exists(paths)]
  if (length(paths)) unlink(paths, recursive = FALSE, force = TRUE)
  invisible(NULL)
}

ppsv_validate_stored_path <- function(path, location, config, expected_sha256 = NULL) {
  if (!file.exists(path) || isTRUE(file.info(path)$isdir)) {
    ppsv_abort("Stored file is missing.", "ppsv_storage_error")
  }
  root <- switch(location, pool = config$pool_root, fallback = config$fallback_root, "")
  root_usable <- if (identical(location, "pool")) {
    ppsv_pool_root_usable(config, writable = FALSE)
  } else {
    ppsv_storage_root_usable(root, writable = FALSE)
  }
  if (!nzchar(root) || !isTRUE(root_usable) ||
      ppsv_path_has_symlink_component(path, root) || !ppsv_path_is_within(path, root)) {
    ppsv_abort("Stored file path is outside its configured storage root.", "ppsv_storage_error")
  }
  if (!is.null(expected_sha256)) {
    actual <- digest::digest(file = path, algo = "sha256", serialize = FALSE)
    if (!identical(tolower(actual), tolower(expected_sha256))) {
      ppsv_abort("Stored file checksum verification failed.", "ppsv_storage_error")
    }
  }
  normalizePath(path, winslash = "/", mustWork = TRUE)
}

# Reconcile fallback files into the pool. Each copy is checksum-verified before
# the database path/location changes; the fallback source remains as a safety
# copy and may be removed later by an operator after backup verification.
ppsv_reconcile_storage <- function(ctx = ppsv_default_context()) {
  config <- ctx$config
  if (!ppsv_pool_root_usable(config)) {
    ppsv_abort("PPSV pool is not writable; reconciliation cannot run.", "ppsv_storage_error")
  }
  con <- ppsv_db_connect(config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  rows <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT f.id,f.absolute_path,f.stored_name,f.category,f.sha256,r.request_code",
      "FROM request_files f JOIN requests r ON r.id=f.request_id",
      "WHERE f.storage_location='fallback' AND f.archived_at IS NULL ORDER BY f.id"
    )
  )
  moved <- 0L
  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    source <- ppsv_validate_stored_path(row$absolute_path, "fallback", config, row$sha256)
    directory <- tryCatch(
      ppsv_prepare_storage_directory(config$pool_root, row$request_code, row$category),
      error = function(error) NULL
    )
    if (is.null(directory)) next
    destination <- file.path(directory, row$stored_name)
    existed_before <- file.exists(destination)
    if (ppsv_is_symlink(destination)) next
    if (!existed_before) {
      if (!file.copy(source, destination, overwrite = FALSE, copy.mode = FALSE)) next
    }
    Sys.chmod(destination, mode = "0660", use_umask = FALSE)
    if (!identical(
      digest::digest(file = destination, algo = "sha256", serialize = FALSE),
      row$sha256
    )) {
      if (!existed_before) unlink(destination, force = TRUE)
      next
    }
    changed <- DBI::dbExecute(
      con,
      "UPDATE request_files SET storage_location='pool',absolute_path=? WHERE id=? AND storage_location='fallback'",
      params = list(normalizePath(destination, winslash = "/"), row$id)
    )
    moved <- moved + as.integer(changed)
  }
  DBI::dbExecute(
    con,
    paste(
      "UPDATE requests SET storage_state='pool',updated_at=? WHERE storage_state='fallback'",
      "AND NOT EXISTS (SELECT 1 FROM request_files f WHERE f.request_id=requests.id AND f.storage_location='fallback')"
    ),
    params = list(ppsv_now())
  )
  moved
}
