# Read repositories and administrative user operations.

ppsv_resolve_request_row <- function(con, request_id) {
  value <- ppsv_scalar(request_id)
  if (grepl("^PPSV[0-9]{6}$", toupper(value))) {
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM requests WHERE request_code=?",
      params = list(toupper(value))
    )
  } else if (grepl("^[0-9]+$", value)) {
    row <- DBI::dbGetQuery(con, "SELECT * FROM requests WHERE id=?", params = list(as.integer(value)))
  } else {
    ppsv_abort("Invalid PPSV request identifier.", "ppsv_not_found_error")
  }
  if (!nrow(row)) ppsv_abort("PPSV request was not found.", "ppsv_not_found_error")
  row[1L, , drop = FALSE]
}

list_service_modules <- function(active_only = TRUE, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  sql <- "SELECT slug,name,description,url,display_order,active FROM service_modules"
  if (isTRUE(active_only)) sql <- paste(sql, "WHERE active=1")
  DBI::dbGetQuery(con, paste(sql, "ORDER BY display_order"))
}

list_requests <- function(user, include_archived = FALSE, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  where <- character()
  params <- list()
  if (!ppsv_is_staff(user)) {
    where <- c(where, "r.owner_username=?")
    params <- c(params, list(user$username))
  }
  if (!isTRUE(include_archived) || !ppsv_is_admin(user)) where <- c(where, "r.archived_at IS NULL")
  sql <- paste(
    "SELECT r.id,r.request_code,r.request_kind,r.service_module_slug,m.name AS service_module_name,",
    "r.owner_username,r.assignee_username,r.contact_name,r.contact_email,r.current_status,",
    "p.protein_name,i.subject AS inquiry_subject,",
    "r.ticket_state,r.storage_state,r.archived_at,r.created_at,r.updated_at",
    "FROM requests r LEFT JOIN service_modules m ON m.slug=r.service_module_slug",
    "LEFT JOIN protein_submissions p ON p.request_id=r.id",
    "LEFT JOIN inquiries i ON i.request_id=r.id"
  )
  if (length(where)) sql <- paste(sql, "WHERE", paste(where, collapse = " AND "))
  sql <- paste(sql, "ORDER BY r.updated_at DESC, r.id DESC")
  if (length(params)) DBI::dbGetQuery(con, sql, params = params) else DBI::dbGetQuery(con, sql)
}

ppsv_request_detail_from_connection <- function(con, row) {
  result <- as.list(row[1L, , drop = FALSE])
  request_id <- as.integer(result$id)
  if (identical(result$request_kind, "service")) {
    module <- DBI::dbGetQuery(
      con,
      "SELECT name,description,url FROM service_modules WHERE slug=?",
      params = list(result$service_module_slug)
    )
    if (nrow(module)) {
      result$service_module_name <- module$name[[1L]]
      result$service_module_description <- module$description[[1L]]
      result$service_module_url <- module$url[[1L]]
    }
    detail <- DBI::dbGetQuery(con, "SELECT * FROM protein_submissions WHERE request_id=?", params = list(request_id))
  } else {
    detail <- DBI::dbGetQuery(con, "SELECT * FROM inquiries WHERE request_id=?", params = list(request_id))
    if (nrow(detail)) {
      names(detail)[names(detail) == "subject"] <- "inquiry_subject"
      names(detail)[names(detail) == "message"] <- "inquiry_message"
      related_slug <- detail$related_service_module_slug[[1L]]
      if (!is.na(related_slug) && nzchar(related_slug)) {
        related <- DBI::dbGetQuery(
          con,
          "SELECT name FROM service_modules WHERE slug=?",
          params = list(related_slug)
        )
        if (nrow(related)) result$related_service_name <- related$name[[1L]]
      }
    }
  }
  if (nrow(detail)) {
    result <- c(result, as.list(detail[1L, setdiff(names(detail), "request_id"), drop = FALSE]))
  }
  result$status_history <- DBI::dbGetQuery(
    con,
    "SELECT old_status,new_status,note,changed_by,changed_at FROM status_history WHERE request_id=? ORDER BY id",
    params = list(request_id)
  )
  result$files <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT id,category,original_name,mime_type,size_bytes,sha256,storage_location,uploaded_by,",
      "archived_at,created_at FROM request_files WHERE request_id=? ORDER BY id"
    ),
    params = list(request_id)
  )
  result$mail <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT id,message_kind,recipient,from_address,reply_to,status,attempt_count,next_attempt_at,",
      "sent_at,last_error,ticket_url,created_at,updated_at FROM mail_outbox WHERE request_id=? ORDER BY id"
    ),
    params = list(request_id)
  )
  result
}

get_request <- function(id, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  row <- ppsv_resolve_request_row(con, id)
  ppsv_require(user, "view_request", row)
  detail <- ppsv_request_detail_from_connection(con, row)
  if (!ppsv_is_admin(user) && is.data.frame(detail$files) && nrow(detail$files)) {
    detail$files <- detail$files[
      is.na(detail$files$archived_at) | detail$files$archived_at == "",
      ,
      drop = FALSE
    ]
  }
  detail
}

list_files <- function(id, user, include_archived = FALSE, ctx = ppsv_default_context()) {
  request <- get_request(id, user, ctx)
  files <- request$files
  if (!isTRUE(include_archived) || !ppsv_is_admin(user)) {
    files <- files[is.na(files$archived_at) | files$archived_at == "", , drop = FALSE]
  }
  files
}

list_users <- function(user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_require(user, "view_users")
  rows <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT username,display_name,email,research_group,phone,role,active,ldap_email_verified,",
      "last_login_at,created_at,updated_at FROM users ORDER BY role,username"
    )
  )
  rows$role <- vapply(rows$username, ppsv_role_for_username, character(1L))
  rows[order(rows$role, rows$username), , drop = FALSE]
}

list_assignable_staff <- function(user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  if (!ppsv_is_staff(user)) {
    ppsv_abort("Only PPSV staff may list assignees.", "ppsv_authorization_error")
  }
  rows <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT username,display_name,role FROM users",
      "WHERE active=1 ORDER BY display_name,username"
    )
  )
  rows$role <- vapply(rows$username, ppsv_role_for_username, character(1L))
  rows[rows$role %in% c("technician", "admin"), , drop = FALSE]
}

set_user_active <- function(username, active, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_require(user, "manage_users")
  target <- ppsv_normalize_username(username)
  if (identical(ppsv_role_for_username(target), "admin")) {
    ppsv_abort("Administrator activation is controlled by the allowlist and cannot be changed here.", "ppsv_authorization_error")
  }
  value <- as.integer(isTRUE(as.logical(active)))
  changed <- DBI::dbExecute(
    con,
    "UPDATE users SET active=?,updated_at=? WHERE username=?",
    params = list(value, ppsv_now(), target)
  )
  if (!identical(changed, 1L)) ppsv_abort("User was not found.", "ppsv_not_found_error")
  invisible(value == 1L)
}

list_mail_status <- function(id, user, ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  if (is.null(id) || !nzchar(ppsv_trim(id))) {
    ppsv_require(user, "view_mail")
    return(DBI::dbGetQuery(
      con,
      paste(
        "SELECT o.id,o.request_id,r.request_code,o.message_kind,o.recipient,o.from_address,o.reply_to,",
        "o.status,o.attempt_count,o.next_attempt_at,o.sent_at,o.last_error,o.ticket_url,o.created_at,o.updated_at",
        "FROM mail_outbox o JOIN requests r ON r.id=o.request_id ORDER BY o.created_at DESC,o.id DESC"
      )
    ))
  }
  row <- ppsv_resolve_request_row(con, id)
  ppsv_require(user, "view_request", row)
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT id,message_kind,recipient,from_address,reply_to,status,attempt_count,next_attempt_at,",
      "sent_at,last_error,ticket_url,created_at,updated_at FROM mail_outbox",
      "WHERE request_id=? ORDER BY id"
    ),
    params = list(row$id[[1L]])
  )
}
