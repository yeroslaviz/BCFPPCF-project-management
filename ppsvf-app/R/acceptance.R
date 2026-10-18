# Staff-reviewed project acceptance, with a durable PDF shared with the requester.

ppsv_format_acceptance <- function(request) {
  paste(c(
    paste0("Dear ", ppsv_mail_request_value(request, "submitter_name", "colleague"), ","),
    "",
    paste0("Your PPSV project ", request$request_code,
           " has been accepted. A PDF report containing your project details is attached."),
    "",
    "A member of our team will contact you to discuss the next steps.",
    "", "Yours sincerely,", "The PPSV Team"
  ), collapse = "\n")
}

accept_request <- function(id, message = NULL, recipient = NULL, user,
                           ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  staging <- new.env(parent = emptyenv())
  staging$records <- data.frame()
  committed <- FALSE
  on.exit(if (!committed) ppsv_cleanup_staged_uploads(staging$records), add = TRUE)
  pdf_path <- tempfile("ppsv-acceptance-", fileext = ".pdf")
  on.exit(unlink(pdf_path), add = TRUE)

  ppsv_db_transaction(con, {
    actor <- ppsv_actor_from_connection(con, user)
    row <- ppsv_resolve_request_row(con, id)
    ppsv_require(actor, "accept_request", row)
    settings <- ppsv_mail_settings(config = ctx$config)
    if (identical(settings$mode, "disabled")) {
      ppsv_abort("Mail delivery is disabled; acceptance confirmation cannot be queued.", "ppsv_validation_error")
    }
    errors <- ppsv_validate_mail_settings(settings)
    if (length(errors)) ppsv_abort(paste(errors, collapse = "; "), "ppsv_validation_error")

    request <- ppsv_request_detail_from_connection(con, row)
    verified_recipient <- request$acceptance_recipient
    if (!nzchar(verified_recipient)) {
      ppsv_abort("The requester has no verified LDAP email for the acceptance confirmation.", "ppsv_validation_error")
    }
    if (!is.null(recipient) && !identical(tolower(ppsv_trim(recipient)), verified_recipient)) {
      ppsv_abort("The verified requester email changed. Refresh and review the recipient again.", "ppsv_validation_error")
    }
    key <- paste0(request$request_code, ":acceptance")
    existing <- DBI::dbGetQuery(con, "SELECT id FROM mail_outbox WHERE dedupe_key=?", params = list(key))
    if (nrow(existing)) {
      ppsv_abort("An acceptance confirmation already exists. Check the delivery log; an administrator can retry failed delivery.", "ppsv_validation_error")
    }
    body <- if (is.null(message)) ppsv_format_acceptance(request) else ppsv_scalar(message)
    if (!nzchar(trimws(body))) {
      ppsv_abort("The acceptance message must not be empty.", "ppsv_validation_error")
    }
    if (file.exists(body)) {
      ppsv_abort("Enter acceptance message text rather than a server file path.", "ppsv_validation_error")
    }

    now <- ppsv_now()
    if (!identical(request$current_status, "Accepted")) {
      DBI::dbExecute(
        con, "UPDATE requests SET current_status='Accepted',updated_at=? WHERE id=?",
        params = list(now, request$id)
      )
    }
    # Record who approved this message even if staff had already selected the
    # Accepted status without sending a confirmation.
    DBI::dbExecute(
      con,
      paste("INSERT INTO status_history(request_id,old_status,new_status,note,changed_by,changed_at)",
            "VALUES (?,?,'Accepted',?,?,?)"),
      params = list(request$id, request$current_status,
                    "Project accepted; confirmation with PDF queued by staff.", actor$username, now)
    )
    request <- ppsv_request_detail_from_connection(con, ppsv_resolve_request_row(con, id))
    # Archived files are not part of the report shared with the requester.
    request$files <- request$files[is.na(request$files$archived_at) | request$files$archived_at == "", , drop = FALSE]
    slug <- if (request$request_kind == "inquiry") request$related_service_module_slug else request$service_module_slug
    module <- if (nzchar(ppsv_trim(slug))) {
      DBI::dbGetQuery(con, "SELECT name,description,url FROM service_modules WHERE slug=?", params = list(slug))
    } else NULL
    ppsv_write_request_pdf(
      request, details = request, status_history = request$status_history,
      files = request$files, module = module, file = pdf_path,
      logo_path = ctx$config$logo_path, public_url = ctx$config$public_url
    )
    Sys.chmod(pdf_path, mode = "0600", use_umask = FALSE)
    existing_bytes <- DBI::dbGetQuery(
      con, "SELECT COALESCE(SUM(size_bytes),0) AS bytes FROM request_files WHERE request_id=?",
      params = list(request$id)
    )$bytes[[1L]]
    if (existing_bytes + file.info(pdf_path)$size > ctx$config$max_upload_mb * 1024^2) {
      ppsv_abort("The acceptance PDF would exceed the configured request storage limit.", "ppsv_storage_error")
    }
    staging$records <- ppsv_store_uploads(
      request$request_code,
      list(datapath = pdf_path, name = paste0(request$request_code, "-acceptance.pdf"), type = "application/pdf"),
      "results", actor$username, ctx$config
    )
    ppsv_insert_file_records(con, request$id, staging$records, now)
    file_id <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id[[1L]]
    state <- DBI::dbGetQuery(
      con, "SELECT EXISTS(SELECT 1 FROM request_files WHERE request_id=? AND storage_location='fallback' AND archived_at IS NULL) AS fallback",
      params = list(request$id)
    )$fallback[[1L]]
    DBI::dbExecute(
      con, "UPDATE requests SET storage_state=?,updated_at=? WHERE id=?",
      params = list(if (state == 1L) "fallback" else "pool", now, request$id)
    )
    mail <- ppsv_mail_message(
      settings$service_from, verified_recipient,
      paste(request$request_code, "PPSV project accepted", sep = " - "),
      body, reply_to = settings$ticket_to, kind = "acceptance"
    )
    ppsv_outbox_insert(con, request$id, "acceptance", mail, dedupe_key = key, now = now)
    outbox_id <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id[[1L]]
    DBI::dbExecute(
      con, "INSERT INTO mail_attachments(outbox_id,file_id) VALUES (?,?)",
      params = list(outbox_id, file_id)
    )
  }, immediate = TRUE)
  committed <- TRUE
  get_request(id, user, ctx)
}
