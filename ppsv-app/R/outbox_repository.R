# Durable PPSV mail outbox. Request creation inserts these rows in the same
# SQLite transaction; a separate worker performs all network I/O.

ppsv_outbox_insert <- function(con, request_id, kind, message, status = "pending",
                               dedupe_key, last_error = NULL, now = ppsv_now()) {
  DBI::dbExecute(
    con,
    paste(
      "INSERT INTO mail_outbox(request_id,message_kind,recipient,from_address,reply_to,subject,body,",
      "status,attempt_count,next_attempt_at,last_error,dedupe_key,created_at,updated_at)",
      "VALUES (?,?,?,?,?,?,?,?,0,?,?,?,?,?)"
    ),
    params = list(
      request_id, kind, message$to, message$from,
      if (nzchar(ppsv_mail_scalar(message$reply_to))) message$reply_to else NA_character_,
      message$subject, message$body, status,
      if (identical(status, "pending")) now else NA_character_,
      if (nzchar(ppsv_trim(last_error))) ppsv_trim(last_error) else NA_character_,
      dedupe_key, now, now
    )
  )
}

ppsv_outbox_set_request_state <- function(con, request_id, state, now = ppsv_now()) {
  DBI::dbExecute(
    con,
    "UPDATE requests SET ticket_state=?,updated_at=? WHERE id=?",
    params = list(state, now, request_id)
  )
}

# Called from create_request's open transaction. It intentionally performs no
# SMTP or ticket-system I/O.
ppsv_enqueue_request_mail <- function(con, request_id, request_code, payload, user, config) {
  user <- ppsv_user_as_list(user)
  verified <- identical(as.integer(user$ldap_email_verified %||% 0L), 1L) &&
    ppsv_email_is_valid(ppsv_scalar(user$email))
  ldap_email <- if (verified) tolower(ppsv_scalar(user$email)) else ""
  settings <- ppsv_mail_settings(config = config)

  module <- NULL
  if (identical(payload$request_kind, "service")) {
    index <- match(payload$service_module_slug, PPSV_SERVICE_MODULES$slug)
    if (!is.na(index)) module <- PPSV_SERVICE_MODULES[index, , drop = FALSE]
  }
  request <- c(
    payload,
    list(
      request_code = request_code,
      owner_username = user$username,
      contact_name = payload$contact_name,
      contact_email = payload$contact_email
    )
  )
  files <- DBI::dbGetQuery(
    con,
    "SELECT original_name FROM request_files WHERE request_id=? AND archived_at IS NULL ORDER BY id",
    params = list(request_id)
  )
  plan <- ppsv_plan_ticket_messages(
    request = request,
    module = module,
    details = payload,
    files = files,
    verified_ldap_email = ldap_email,
    settings = settings
  )
  now <- ppsv_now()

  if (identical(settings$mode, "disabled")) {
    disabled_message <- ppsv_mail_message(
      settings$service_from,
      settings$ticket_to,
      ppsv_ticket_subject(request, module),
      ppsv_format_ticket_body(request, module, payload, files, settings),
      kind = "ticket_service"
    )
    ppsv_outbox_insert(
      con, request_id, "ticket", disabled_message, "suppressed",
      paste0(request_code, ":ticket:disabled"),
      "Ticket delivery is disabled by PPSV_TICKET_MODE.", now
    )
    ppsv_outbox_set_request_state(con, request_id, "disabled", now)
    return(invisible(TRUE))
  }

  if (!isTRUE(plan$enabled)) {
    invalid_message <- list(
      from = settings$service_from,
      to = settings$ticket_to,
      reply_to = "",
      subject = paste0("[", request_code, "] PPSV request"),
      body = "Ticket delivery could not be configured."
    )
    ppsv_outbox_insert(
      con, request_id, "ticket", invalid_message, "suppressed",
      paste0(request_code, ":ticket:configuration"),
      paste(plan$errors, collapse = "; "), now
    )
    ppsv_outbox_set_request_state(con, request_id, "configuration_error", now)
    return(invisible(TRUE))
  }

  ldap_primary <- identical(plan$primary$kind, "ticket_ldap_from")
  primary_key <- paste0(
    request_code,
    if (ldap_primary) ":ticket:ldap" else ":ticket:service"
  )
  ppsv_outbox_insert(
    con, request_id, "ticket", plan$primary, "pending", primary_key,
    now = now
  )

  if (!is.null(plan$fallback)) {
    ppsv_outbox_insert(
      con, request_id, "ticket", plan$fallback, "suppressed",
      paste0(request_code, ":ticket:fallback"),
      "Held unless the authenticated-user From address is rejected.", now
    )
  }

  if (isTRUE(settings$direct_ack)) {
    if (!is.null(plan$acknowledgement)) {
      ppsv_outbox_insert(
        con, request_id, "acknowledgement", plan$acknowledgement, "suppressed",
        paste0(request_code, ":ack"),
        if (ldap_primary) {
          "Held unless fixed-sender fallback is used."
        } else {
          "Awaiting successful fixed-sender ticket delivery."
        },
        now
      )
    } else {
      suppressed_ack <- list(
        from = settings$service_from,
        to = NA_character_,
        reply_to = "",
        subject = paste0("PPSV request received: ", request_code),
        body = ppsv_format_acknowledgement(request)
      )
      ppsv_outbox_insert(
        con, request_id, "acknowledgement", suppressed_ack, "suppressed",
        paste0(request_code, ":ack"),
        "Acknowledgement suppressed: no verified LDAP email.", now
      )
    }
  }
  ppsv_outbox_set_request_state(con, request_id, "queued", now)
  invisible(TRUE)
}

# Recover rows left in 'sending' after a worker crash, then atomically claim one
# due message. A 15-minute lease is deliberately longer than the worker timeout.
ppsv_outbox_claim_due <- function(con, now = Sys.time(), lease_seconds = 15L * 60L) {
  now_text <- if (inherits(now, "POSIXt")) ppsv_now(now) else ppsv_trim(now)
  now_time <- as.POSIXct(now_text, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  stale_text <- ppsv_now(now_time - lease_seconds)
  ppsv_db_transaction(con, {
    DBI::dbExecute(
      con,
      paste(
        "UPDATE mail_outbox SET status='failed',next_attempt_at=?,",
        "last_error='Recovered after an interrupted mail worker.',updated_at=?",
        "WHERE status='sending' AND updated_at<=?"
      ),
      params = list(now_text, now_text, stale_text)
    )
    row <- DBI::dbGetQuery(
      con,
      paste(
        "SELECT * FROM mail_outbox WHERE status IN ('pending','failed')",
        "AND attempt_count < ? AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?",
        "ORDER BY next_attempt_at,id LIMIT 1"
      ),
      params = list(length(PPSV_RETRY_DELAYS_SECONDS), now_text)
    )
    claimed <- NULL
    if (nrow(row)) {
      changed <- DBI::dbExecute(
        con,
        "UPDATE mail_outbox SET status='sending',updated_at=? WHERE id=? AND status IN ('pending','failed')",
        params = list(now_text, row$id[[1L]])
      )
      if (identical(changed, 1L)) claimed <- as.list(row[1L, , drop = FALSE])
    }
    claimed
  }, immediate = TRUE)
}

ppsv_outbox_activate_ack <- function(con, message, result, now_text) {
  ack <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT o.id,r.contact_name,r.request_code FROM mail_outbox o",
      "JOIN requests r ON r.id=o.request_id",
      "WHERE o.request_id=? AND o.message_kind='acknowledgement' AND o.status='suppressed'",
      "AND o.recipient IS NOT NULL LIMIT 1"
    ),
    params = list(message$request_id)
  )
  if (!nrow(ack)) return(invisible(FALSE))
  ticket_url <- ppsv_trim(result$ticket_url %||% "")
  body <- ppsv_format_acknowledgement(
    list(contact_name = ack$contact_name[[1L]]),
    ticket_url = ticket_url
  )
  changed <- DBI::dbExecute(
    con,
    paste(
      "UPDATE mail_outbox SET status='pending',next_attempt_at=?,last_error=NULL,body=?,updated_at=?",
      "WHERE id=? AND status='suppressed'"
    ),
    params = list(now_text, body, now_text, ack$id[[1L]])
  )
  invisible(identical(changed, 1L))
}

ppsv_outbox_finish <- function(con, message, succeeded, error = NULL,
                               result = NULL, now = Sys.time()) {
  attempt <- as.integer(message$attempt_count) + 1L
  now_text <- ppsv_now(now)
  error <- substr(ppsv_trim(error), 1L, 2000L)
  ldap_primary <- grepl(":ticket:ldap$", message$dedupe_key)
  service_ticket <- identical(message$message_kind, "ticket") && !ldap_primary

  ppsv_db_transaction(con, {
    DBI::dbExecute(
      con,
      paste(
        "INSERT INTO mail_attempts(outbox_id,attempt_number,attempted_at,succeeded,error_message)",
        "VALUES (?,?,?,?,?)"
      ),
      params = list(
        message$id, attempt, now_text, as.integer(succeeded),
        if (nzchar(error)) error else NA_character_
      )
    )

    if (isTRUE(succeeded)) {
      ticket_url <- if (identical(message$message_kind, "ticket")) {
        ppsv_trim(result$ticket_url %||% "")
      } else {
        ""
      }
      DBI::dbExecute(
        con,
        paste(
          "UPDATE mail_outbox SET status='sent',attempt_count=?,next_attempt_at=NULL,sent_at=?,",
          "last_error=NULL,ticket_url=?,updated_at=? WHERE id=?"
        ),
        params = list(
          attempt, now_text, if (nzchar(ticket_url)) ticket_url else NA_character_,
          now_text, message$id
        )
      )
      if (identical(message$message_kind, "ticket")) {
        ppsv_outbox_set_request_state(con, message$request_id, "sent", now_text)
        if (service_ticket) ppsv_outbox_activate_ack(con, message, result, now_text)
      }
    } else if (ldap_primary) {
      # LDAP-From is tried once. Any rejection immediately activates the durable
      # service-sender fallback instead of repeatedly retrying an unauthorized From.
      fallback_id <- DBI::dbGetQuery(
        con,
        paste(
          "SELECT id FROM mail_outbox WHERE request_id=? AND dedupe_key LIKE '%:ticket:fallback'",
          "AND status='suppressed' LIMIT 1"
        ),
        params = list(message$request_id)
      )
      has_fallback <- nrow(fallback_id) == 1L
      DBI::dbExecute(
        con,
        paste(
          "UPDATE mail_outbox SET status='failed',attempt_count=?,next_attempt_at=NULL,",
          "last_error=?,updated_at=? WHERE id=?"
        ),
        params = list(
          attempt,
          paste0(error, if (has_fallback) " Fixed-sender fallback activated." else ""),
          now_text, message$id
        )
      )
      if (has_fallback) {
        DBI::dbExecute(
          con,
          paste(
            "UPDATE mail_outbox SET status='pending',next_attempt_at=?,last_error=NULL,updated_at=?",
            "WHERE id=? AND status='suppressed'"
          ),
          params = list(now_text, now_text, fallback_id$id[[1L]])
        )
      }
      ppsv_outbox_set_request_state(
        con, message$request_id, if (has_fallback) "retrying" else "failed", now_text
      )
    } else {
      next_at <- NA_character_
      if (attempt < length(PPSV_RETRY_DELAYS_SECONDS)) {
        next_at <- ppsv_now(
          as.POSIXct(now, tz = "UTC") + PPSV_RETRY_DELAYS_SECONDS[[attempt + 1L]]
        )
      }
      DBI::dbExecute(
        con,
        paste(
          "UPDATE mail_outbox SET status='failed',attempt_count=?,next_attempt_at=?,",
          "last_error=?,updated_at=? WHERE id=?"
        ),
        params = list(
          attempt, next_at, if (nzchar(error)) error else "Mail delivery failed.",
          now_text, message$id
        )
      )
      if (identical(message$message_kind, "ticket")) {
        ppsv_outbox_set_request_state(
          con, message$request_id, if (is.na(next_at)) "failed" else "retrying", now_text
        )
      }
    }
  }, immediate = TRUE)
  invisible(TRUE)
}

ppsv_process_mail_outbox <- function(limit = 25L, send_fun = ppsv_default_mail_sender,
                                     now = Sys.time(), ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  processed <- sent <- failed <- 0L
  for (index in seq_len(as.integer(limit))) {
    message <- ppsv_outbox_claim_due(con, now)
    if (is.null(message)) break
    processed <- processed + 1L
    outcome <- tryCatch(
      {
        value <- send_fun(message, ctx$config)
        normalized <- ppsv_normalize_send_result(value)
        list(ok = normalized$success, value = normalized$value, error = normalized$error)
      },
      error = function(error) {
        list(ok = FALSE, value = NULL, error = conditionMessage(error))
      }
    )
    ppsv_outbox_finish(
      con, message, outcome$ok, outcome$error, outcome$value, now
    )
    if (outcome$ok) sent <- sent + 1L else failed <- failed + 1L
  }
  list(processed = processed, sent = sent, failed = failed)
}

retry_mail <- function(outbox_id, user, ctx = ppsv_default_context()) {
  id <- suppressWarnings(as.integer(outbox_id))
  if (is.na(id)) ppsv_abort("Invalid outbox identifier.", "ppsv_not_found_error")
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_actor_from_connection(con, user)
  ppsv_require(user, "retry_mail")
  ppsv_db_transaction(con, {
    row <- DBI::dbGetQuery(con, "SELECT * FROM mail_outbox WHERE id=?", params = list(id))
    if (!nrow(row) || !identical(row$status[[1L]], "failed")) {
      ppsv_abort("Only failed outbox items can be retried.", "ppsv_not_found_error")
    }
    if (grepl(":ticket:ldap$", row$dedupe_key[[1L]])) {
      fallback <- DBI::dbGetQuery(
        con,
        paste(
          "SELECT id,status FROM mail_outbox WHERE request_id=?",
          "AND dedupe_key LIKE '%:ticket:fallback' LIMIT 1"
        ),
        params = list(row$request_id[[1L]])
      )
      if (nrow(fallback)) {
        ppsv_abort(
          "LDAP-From delivery cannot be retried after fallback exists; retry the fixed-sender fallback if it fails.",
          "ppsv_validation_error"
        )
      }
    }
    now <- ppsv_now()
    changed <- DBI::dbExecute(
      con,
      paste(
        "UPDATE mail_outbox SET status='pending',attempt_count=0,next_attempt_at=?,",
        "last_error=NULL,updated_at=? WHERE id=? AND status='failed'"
      ),
      params = list(now, now, id)
    )
    if (!identical(changed, 1L)) {
      ppsv_abort("The outbox item changed while it was being retried.", "ppsv_validation_error")
    }
    if (identical(row$message_kind[[1L]], "ticket")) {
      ppsv_outbox_set_request_state(con, row$request_id[[1L]], "retrying", now)
    }
  }, immediate = TRUE)
  invisible(TRUE)
}
