# Request lifecycle facade. These are the primary functions consumed by Shiny.

ppsv_db_value <- function(value) {
  if (is.null(value) || !length(value)) NA
  else value[[1L]]
}

ppsv_apply_verified_identity <- function(payload, user) {
  user <- ppsv_user_as_list(user)
  name_verified <- identical(as.integer(user$ldap_name_verified %||% 0L), 1L) &&
    nzchar(ppsv_scalar(user$display_name))
  if (name_verified) payload$contact_name <- ppsv_scalar(user$display_name)
  verified <- identical(as.integer(user$ldap_email_verified %||% 0L), 1L) &&
    ppsv_valid_email(ppsv_scalar(user$email))
  if (verified) payload$contact_email <- tolower(ppsv_scalar(user$email))
  payload
}

ppsv_insert_file_records <- function(con, request_id, records, now = ppsv_now()) {
  if (!nrow(records)) return(invisible(0L))
  sql <- paste(
    "INSERT INTO request_files(request_id,category,original_name,stored_name,mime_type,size_bytes,sha256,",
    "storage_location,absolute_path,uploaded_by,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
  )
  for (i in seq_len(nrow(records))) {
    row <- records[i, ]
    DBI::dbExecute(
      con,
      sql,
      params = list(
        request_id, row$category, row$original_name, row$stored_name,
        if (nzchar(row$mime_type)) row$mime_type else NA_character_,
        as.numeric(row$size_bytes), row$sha256, row$storage_location,
        row$absolute_path, row$uploaded_by, now
      )
    )
  }
  invisible(nrow(records))
}

ppsv_insert_request_detail <- function(con, request_id, payload) {
  if (identical(payload$request_kind, "inquiry")) {
    DBI::dbExecute(
      con,
      "INSERT INTO inquiries(request_id,related_service_module_slug,subject,message) VALUES (?,?,?,?)",
      params = list(
        request_id,
        if (nzchar(payload$related_service_module_slug)) payload$related_service_module_slug else NA_character_,
        payload$inquiry_subject,
        payload$inquiry_message
      )
    )
    return(invisible(TRUE))
  }
  fields <- c(PPSV_REQUIRED_PROTEIN_FIELDS, PPSV_OPTIONAL_PROTEIN_FIELDS)
  sql <- sprintf(
    "INSERT INTO protein_submissions(request_id,%s) VALUES (%s)",
    paste(fields, collapse = ","),
    paste(rep("?", length(fields) + 1L), collapse = ",")
  )
  DBI::dbExecute(
    con,
    sql,
    params = c(list(request_id), lapply(fields, function(field) ppsv_db_value(payload[[field]])))
  )
  invisible(TRUE)
}

create_request <- function(payload, uploads = NULL, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_require(user, "create_request")
  payload <- ppsv_apply_verified_identity(payload, user)
  payload <- ppsv_validate_request_payload(payload)
  staging <- new.env(parent = emptyenv())
  staging$records <- data.frame()
  success <- FALSE
  on.exit(if (!success) ppsv_cleanup_staged_uploads(staging$records), add = TRUE)

  request_code <- ppsv_db_transaction(con, {
    db_user <- ppsv_actor_from_connection(con, user)
    payload <- ppsv_apply_verified_identity(payload, db_user)
    payload <- ppsv_validate_request_payload(payload)
    code <- ppsv_allocate_request_code_in_transaction(con)
    staging$records <- ppsv_store_uploads(code, uploads, "inputs", db_user$username, ctx$config)
    storage_state <- if (!nrow(staging$records)) "none" else if (any(staging$records$storage_location == "fallback")) "fallback" else "pool"
    now <- ppsv_now()
    module <- if (payload$request_kind == "service") payload$service_module_slug else NA_character_
    billing <- if (payload$request_kind == "service") payload$billing_code else NA_character_
    DBI::dbExecute(
      con,
      paste(
        "INSERT INTO requests(request_code,request_kind,service_module_slug,owner_username,contact_name,",
        "contact_email,contact_email_verified,contact_name_verified,research_group,phone,billing_code,",
        "current_status,ticket_state,storage_state,created_at,updated_at)",
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'queued',?,?,?)"
      ),
      params = list(
        code, payload$request_kind, module, db_user$username, payload$contact_name,
        payload$contact_email, as.integer(db_user$ldap_email_verified %||% 0L),
        as.integer(db_user$ldap_name_verified %||% 0L), payload$research_group,
        payload$phone, billing, "Submitted", storage_state, now, now
      )
    )
    request_id <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id[[1L]]
    ppsv_insert_request_detail(con, request_id, payload)
    ppsv_insert_file_records(con, request_id, staging$records, now)
    DBI::dbExecute(
      con,
      "INSERT INTO status_history(request_id,old_status,new_status,note,changed_by,changed_at) VALUES (?,NULL,'Submitted',NULL,?,?)",
      params = list(request_id, db_user$username, now)
    )
    ppsv_enqueue_request_mail(con, request_id, code, payload, db_user, ctx$config)
    code
  }, immediate = TRUE)
  success <- TRUE
  get_request(request_code, user, ctx)
}

ppsv_merge_edit_payload <- function(current, changes) {
  fields <- unique(c(
    "request_kind", "service_module_slug", "related_service_module_slug",
    PPSV_REQUIRED_CONTACT_FIELDS, PPSV_REQUIRED_PROTEIN_FIELDS, PPSV_OPTIONAL_PROTEIN_FIELDS,
    "inquiry_subject", "inquiry_message"
  ))
  merged <- setNames(lapply(fields, function(field) current[[field]] %||% NULL), fields)
  for (field in intersect(names(changes), fields)) merged[[field]] <- changes[[field]]
  merged$request_kind <- current$request_kind
  merged
}

ppsv_update_request_detail <- function(con, request_id, payload) {
  if (payload$request_kind == "inquiry") {
    DBI::dbExecute(
      con,
      "UPDATE inquiries SET related_service_module_slug=?,subject=?,message=? WHERE request_id=?",
      params = list(
        if (nzchar(payload$related_service_module_slug)) payload$related_service_module_slug else NA_character_,
        payload$inquiry_subject, payload$inquiry_message, request_id
      )
    )
  } else {
    fields <- c(PPSV_REQUIRED_PROTEIN_FIELDS, PPSV_OPTIONAL_PROTEIN_FIELDS)
    sql <- paste0("UPDATE protein_submissions SET ", paste0(fields, "=?", collapse = ","), " WHERE request_id=?")
    DBI::dbExecute(
      con,
      sql,
      params = c(lapply(fields, function(field) ppsv_db_value(payload[[field]])), list(request_id))
    )
  }
}

update_request <- function(id, payload, user, ctx = ppsv_default_context()) {
  current <- get_request(id, user, ctx)
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_require(user, "edit_request", current)
  merged <- ppsv_merge_edit_payload(current, payload)
  # Only the request owner may have their current verified LDAP attributes
  # refreshed. Staff edits preserve the original requester contact snapshot.
  if (identical(user$username, current$owner_username)) {
    merged <- ppsv_apply_verified_identity(merged, user)
  }
  normalized <- ppsv_validate_request_payload(merged)
  email_verified <- if (identical(user$username, current$owner_username)) {
    as.integer(user$ldap_email_verified %||% 0L)
  } else {
    as.integer(current$contact_email_verified %||% 0L)
  }
  name_verified <- if (identical(user$username, current$owner_username)) {
    as.integer(user$ldap_name_verified %||% 0L)
  } else {
    as.integer(current$contact_name_verified %||% 0L)
  }
  ppsv_db_transaction(con, {
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "edit_request", row)
    module <- if (normalized$request_kind == "service") normalized$service_module_slug else NA_character_
    billing <- if (normalized$request_kind == "service") normalized$billing_code else NA_character_
    DBI::dbExecute(
      con,
      paste(
        "UPDATE requests SET service_module_slug=?,contact_name=?,contact_email=?,",
        "contact_email_verified=?,contact_name_verified=?,research_group=?,phone=?,billing_code=?,",
        "updated_at=? WHERE id=?"
      ),
      params = list(
        module, normalized$contact_name, normalized$contact_email, email_verified, name_verified,
        normalized$research_group, normalized$phone, billing, ppsv_now(), row$id[[1L]]
      )
    )
    ppsv_update_request_detail(con, row$id[[1L]], normalized)
  }, immediate = TRUE)
  get_request(id, user, ctx)
}

update_status <- function(id, status, note = NULL, user, ctx = ppsv_default_context()) {
  status <- ppsv_scalar(status)
  if (!status %in% PPSV_STATUS_OPTIONS) ppsv_abort("Unknown PPSV status.", "ppsv_validation_error")
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_db_transaction(con, {
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "change_status", row)
    old <- row$current_status[[1L]]
    if (!identical(old, status)) {
      now <- ppsv_now()
      DBI::dbExecute(con, "UPDATE requests SET current_status=?,updated_at=? WHERE id=?", params = list(status, now, row$id[[1L]]))
      DBI::dbExecute(
        con,
        "INSERT INTO status_history(request_id,old_status,new_status,note,changed_by,changed_at) VALUES (?,?,?,?,?,?)",
        params = list(row$id[[1L]], old, status, if (nzchar(ppsv_scalar(note))) ppsv_scalar(note) else NA_character_, user$username, now)
      )
    }
  }, immediate = TRUE)
  get_request(id, user, ctx)
}

assign_request <- function(id, assignee, user, ctx = ppsv_default_context()) {
  assignee <- ppsv_trim(assignee)
  if (nzchar(assignee)) assignee <- ppsv_normalize_username(assignee)
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_db_transaction(con, {
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "assign_request", row)
    if (nzchar(assignee)) {
      target <- DBI::dbGetQuery(con, "SELECT active FROM users WHERE username=?", params = list(assignee))
      derived_role <- ppsv_role_for_username(assignee)
      if (!nrow(target) || !derived_role %in% c("technician", "admin") || target$active[[1L]] != 1L) {
        ppsv_abort("Assignee must be an active PPSV technician or administrator.", "ppsv_validation_error")
      }
    }
    DBI::dbExecute(
      con,
      "UPDATE requests SET assignee_username=?,updated_at=? WHERE id=?",
      params = list(if (nzchar(assignee)) assignee else NA_character_, ppsv_now(), row$id[[1L]])
    )
  }, immediate = TRUE)
  get_request(id, user, ctx)
}

archive_request <- function(id, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_db_transaction(con, {
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "archive_request", row)
    DBI::dbExecute(
      con,
      "UPDATE requests SET archived_at=?,archived_by=?,updated_at=? WHERE id=?",
      params = list(ppsv_now(), user$username, ppsv_now(), row$id[[1L]])
    )
  }, immediate = TRUE)
  invisible(TRUE)
}

add_files <- function(id, uploads, kind = "inputs", user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  row <- ppsv_resolve_request_row(con, id)
  ppsv_require(user, "add_file", row)
  if (identical(kind, "results") && !ppsv_is_staff(user)) {
    ppsv_abort("Only PPSV staff may upload result files.", "ppsv_authorization_error")
  }
  existing_bytes <- DBI::dbGetQuery(
    con,
    "SELECT COALESCE(SUM(size_bytes),0) AS bytes FROM request_files WHERE request_id=?",
    params = list(row$id[[1L]])
  )$bytes[[1L]]
  upload_rows <- ppsv_upload_rows(uploads)
  incoming_bytes <- ppsv_upload_total_bytes(upload_rows)
  if (as.numeric(existing_bytes) + incoming_bytes > ctx$config$max_upload_mb * 1024^2) {
    ppsv_abort(
      sprintf("Files would exceed the configured %.0f MB request limit.", ctx$config$max_upload_mb),
      "ppsv_storage_error"
    )
  }
  records <- ppsv_store_uploads(row$request_code[[1L]], uploads, kind, user$username, ctx$config)
  success <- FALSE
  on.exit(if (!success) ppsv_cleanup_staged_uploads(records), add = TRUE)
  ppsv_db_transaction(con, {
    latest <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "add_file", latest)
    # The first quota check avoids needless copies. This second check is under
    # BEGIN IMMEDIATE so concurrent uploads cannot both pass against the same
    # pre-staging total and exceed the per-request limit.
    serialized_bytes <- DBI::dbGetQuery(
      con,
      "SELECT COALESCE(SUM(size_bytes),0) AS bytes FROM request_files WHERE request_id=?",
      params = list(latest$id[[1L]])
    )$bytes[[1L]]
    staged_bytes <- if (nrow(records)) sum(as.numeric(records$size_bytes)) else 0
    if (as.numeric(serialized_bytes) + staged_bytes > ctx$config$max_upload_mb * 1024^2) {
      ppsv_abort(
        sprintf("Files would exceed the configured %.0f MB request limit.", ctx$config$max_upload_mb),
        "ppsv_storage_error"
      )
    }
    ppsv_insert_file_records(con, latest$id[[1L]], records)
    has_fallback <- DBI::dbGetQuery(
      con,
      "SELECT EXISTS(SELECT 1 FROM request_files WHERE request_id=? AND storage_location='fallback' AND archived_at IS NULL) AS yes",
      params = list(latest$id[[1L]])
    )$yes[[1L]] == 1L
    state <- if (has_fallback) "fallback" else "pool"
    DBI::dbExecute(con, "UPDATE requests SET storage_state=?,updated_at=? WHERE id=?", params = list(state, ppsv_now(), latest$id[[1L]]))
  }, immediate = TRUE)
  success <- TRUE
  list_files(id, user, ctx = ctx)
}

download_file <- function(id, file_id, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  row <- ppsv_resolve_request_row(con, id)
  ppsv_require(user, "download_file", row)
  file <- DBI::dbGetQuery(
    con,
    "SELECT * FROM request_files WHERE id=? AND request_id=?",
    params = list(as.integer(file_id), row$id[[1L]])
  )
  if (!nrow(file) || (nzchar(ppsv_scalar(file$archived_at[[1L]])) && !ppsv_is_admin(user))) {
    ppsv_abort("File was not found.", "ppsv_not_found_error")
  }
  ppsv_validate_stored_path(file$absolute_path[[1L]], file$storage_location[[1L]], ctx$config, file$sha256[[1L]])
}

ppsv_archive_file <- function(id, file_id, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_db_transaction(con, {
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(user, "archive_file", row)
    now <- ppsv_now()
    changed <- DBI::dbExecute(
      con,
      "UPDATE request_files SET archived_at=?,archived_by=? WHERE id=? AND request_id=? AND archived_at IS NULL",
      params = list(now, user$username, as.integer(file_id), row$id[[1L]])
    )
    if (!identical(changed, 1L)) {
      ppsv_abort("File was not found or already archived.", "ppsv_not_found_error")
    }
    state <- DBI::dbGetQuery(
      con,
      paste(
        "SELECT CASE",
        "WHEN count(*)=0 THEN 'none'",
        "WHEN sum(CASE WHEN storage_location='fallback' THEN 1 ELSE 0 END)>0 THEN 'fallback'",
        "ELSE 'pool' END AS storage_state",
        "FROM request_files WHERE request_id=? AND archived_at IS NULL"
      ),
      params = list(row$id[[1L]])
    )$storage_state[[1L]]
    DBI::dbExecute(
      con,
      "UPDATE requests SET storage_state=?,updated_at=? WHERE id=?",
      params = list(state, now, row$id[[1L]])
    )
  }, immediate = TRUE)
  invisible(TRUE)
}

# Public name used by UI/tests; kept separate from the policy action string.
archive_file <- ppsv_archive_file
