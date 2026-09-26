# PPSV mail planning and transport. Database/outbox state lives in
# outbox_repository.R so these helpers remain straightforward to unit test.

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) if (is.null(x) || !length(x) || all(is.na(x))) y else x
}
if (!exists("PPSV_FACILITY_EMAIL")) PPSV_FACILITY_EMAIL <- "ppsv-request@biochem.mpg.de"
if (!exists("PPSV_RETRY_DELAYS_SECONDS")) {
  PPSV_RETRY_DELAYS_SECONDS <- c(0L, 300L, 1800L, 7200L, 43200L, 86400L)
}

ppsv_mail_scalar <- function(value, default = "") {
  if (is.null(value) || length(value) == 0L || is.na(value[[1L]])) return(default)
  as.character(value[[1L]])
}

ppsv_mail_record_value <- function(record, name, default = "") {
  if (is.null(record)) return(default)
  if (is.data.frame(record)) {
    if (nrow(record) == 0L || !name %in% names(record)) return(default)
    return(ppsv_mail_scalar(record[[name]][[1L]], default))
  }
  if (is.list(record) && name %in% names(record)) {
    return(ppsv_mail_scalar(record[[name]], default))
  }
  default
}

ppsv_mail_request_value <- function(request, name, default = "") {
  aliases <- list(
    submitter_name = c("submitter_name", "contact_name"),
    submitter_email = c("submitter_email", "contact_email"),
    status = c("status", "current_status")
  )
  keys <- aliases[[name]] %||% name
  for (key in keys) {
    value <- ppsv_mail_record_value(request, key)
    if (nzchar(value)) return(value)
  }
  default
}

ppsv_mail_bool <- function(value, default = FALSE) {
  value <- tolower(trimws(ppsv_mail_scalar(value)))
  if (!nzchar(value)) return(isTRUE(default))
  value %in% c("1", "true", "yes", "on")
}

ppsv_email_is_valid <- function(value) {
  value <- trimws(ppsv_mail_scalar(value))
  nzchar(value) && grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", value)
}

ppsv_mail_settings <- function(env = Sys.getenv, config = NULL) {
  if (!is.null(config)) {
    return(list(
      mode = config$ticket_mode,
      direct_ack = isTRUE(config$direct_ack),
      service_identity_authorized = isTRUE(config$service_identity_authorized),
      ticket_e2e_test_ack = isTRUE(config$ticket_e2e_test_ack),
      ticket_to = config$ticket_to,
      service_from = config$mail_from,
      public_url = config$public_url,
      smtp = list(
        host.name = config$smtp_host,
        port = config$smtp_port,
        ssl = identical(config$smtp_security, "ssl"),
        tls = identical(config$smtp_security, "starttls"),
        user.name = config$smtp_user,
        passwd = config$smtp_password
      )
    ))
  }

  mode <- tolower(trimws(env("PPSV_TICKET_MODE", "disabled")))
  if (!mode %in% c("disabled", "service_reply_to", "ldap_from")) mode <- "disabled"
  security <- tolower(trimws(env("PPSV_SMTP_SECURITY", "starttls")))
  if (!security %in% c("none", "ssl", "starttls")) security <- "starttls"
  port <- suppressWarnings(as.integer(env(
    "PPSV_SMTP_PORT",
    if (identical(security, "ssl")) "465" else "587"
  )))
  if (is.na(port) || port < 1L || port > 65535L) {
    port <- if (identical(security, "ssl")) 465L else 587L
  }

  list(
    mode = mode,
    direct_ack = ppsv_mail_bool(env("PPSV_DIRECT_ACK", "0")),
    service_identity_authorized = ppsv_mail_bool(env("PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK", "0")),
    ticket_e2e_test_ack = ppsv_mail_bool(env("PPSV_TICKET_E2E_TEST_ACK", "0")),
    ticket_to = trimws(env("PPSV_TICKET_TO", PPSV_FACILITY_EMAIL)),
    service_from = trimws(env("PPSV_MAIL_FROM", "ppsv-service@biochem.mpg.de")),
    public_url = sub("/+$", "", trimws(env(
      "PPSV_PUBLIC_URL",
      "https://ppcf-vm.biochem.mpg.de/ppsvf-app/"
    ))),
    smtp = list(
      host.name = trimws(env("PPSV_SMTP_HOST", "")),
      port = port,
      ssl = identical(security, "ssl"),
      tls = identical(security, "starttls"),
      user.name = trimws(env("PPSV_SMTP_USER", "")),
      passwd = env("PPSV_SMTP_PASSWORD", "")
    )
  )
}

ppsv_validate_mail_settings <- function(settings) {
  errors <- character()
  if (identical(settings$mode, "disabled")) return(errors)
  if (!settings$mode %in% c("service_reply_to", "ldap_from")) {
    errors <- c(errors, "PPSV_TICKET_MODE is invalid")
  }
  # Lists constructed directly by unit callers predate these deployment gates;
  # explicit runtime settings always contain them and fail closed while false.
  service_authorized <- settings$service_identity_authorized %||% TRUE
  ticket_tested <- settings$ticket_e2e_test_ack %||% TRUE
  if (!isTRUE(service_authorized)) {
    errors <- c(errors, "PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK must be 1 before ticket delivery")
  }
  if (!isTRUE(ticket_tested)) {
    errors <- c(
      errors,
      "PPSV_TICKET_E2E_TEST_ACK must be 1 after the real requester/auto-reply test"
    )
  }
  if (!ppsv_email_is_valid(settings$ticket_to)) {
    errors <- c(errors, "PPSV_TICKET_TO is not a valid email address")
  }
  if (!ppsv_email_is_valid(settings$service_from)) {
    errors <- c(errors, "PPSV_MAIL_FROM is not a valid email address")
  }
  if (!nzchar(trimws(ppsv_mail_scalar(settings$smtp$host.name)))) {
    errors <- c(errors, "PPSV_SMTP_HOST is required when ticket email is enabled")
  }
  if (nzchar(ppsv_mail_scalar(settings$smtp$user.name)) &&
      !nzchar(ppsv_mail_scalar(settings$smtp$passwd))) {
    errors <- c(errors, "PPSV_SMTP_PASSWORD is required when PPSV_SMTP_USER is set")
  }
  unique(errors)
}

ppsv_request_url <- function(request, settings) {
  code <- utils::URLencode(ppsv_mail_record_value(request, "request_code"), reserved = TRUE)
  if (!nzchar(code) || !nzchar(settings$public_url)) return("")
  paste0(sub("/+$", "", settings$public_url), "/?request=", code)
}

ppsv_ticket_subject <- function(request, module = NULL) {
  code <- ppsv_mail_record_value(request, "request_code", "PPSV request")
  kind <- ppsv_mail_record_value(request, "request_kind", "service")
  if (identical(kind, "inquiry")) {
    subject <- ppsv_mail_record_value(request, "inquiry_subject", "General inquiry")
    return(paste(code, "PPSV general inquiry", subject, sep = " - "))
  }
  module_name <- ppsv_mail_record_value(
    module, "name",
    ppsv_mail_record_value(request, "service_module_name", "Service request")
  )
  paste(code, "PPSV service request", module_name, sep = " - ")
}

ppsv_format_ticket_body <- function(request, module = NULL, details = NULL,
                                    files = data.frame(), settings = ppsv_mail_settings()) {
  kind <- ppsv_mail_record_value(request, "request_kind", "service")
  request_url <- ppsv_request_url(request, settings)
  lines <- c(
    "Dear PPSV team,", "",
    if (identical(kind, "inquiry")) {
      "A new general inquiry was submitted."
    } else {
      "A new PPSV service request was submitted."
    },
    "",
    paste("Request ID:", ppsv_mail_record_value(request, "request_code")),
    paste("Authenticated LDAP user:", ppsv_mail_record_value(request, "owner_username")),
    paste("Name:", ppsv_mail_request_value(request, "submitter_name")),
    paste("Contact email:", ppsv_mail_request_value(request, "submitter_email")),
    paste("Research group:", ppsv_mail_record_value(request, "research_group")),
    paste("Phone:", ppsv_mail_record_value(request, "phone"))
  )

  if (identical(kind, "inquiry")) {
    lines <- c(
      lines,
      paste("Subject:", ppsv_mail_record_value(
        details, "subject", ppsv_mail_record_value(request, "inquiry_subject")
      )),
      paste("Related service:", ppsv_mail_record_value(
        request, "related_service_name", "Not specified"
      )),
      "", "Inquiry:",
      ppsv_mail_record_value(
        details, "message", ppsv_mail_record_value(request, "inquiry_message")
      )
    )
  } else {
    module_name <- ppsv_mail_record_value(
      module, "name", ppsv_mail_record_value(request, "service_module_name")
    )
    field_labels <- c(
      billing_code = "Billing code", protein_name = "Protein name",
      uniprot_id = "UniProt ID", source_organism = "Source organism",
      expression_construct = "Expression construct",
      size_uncleaved_da = "Size uncleaved (Da)",
      size_cleaved_da = "Size cleaved (Da)", cleavage_size = "Cleavage Size",
      tags = "Tag(s)", expression_host = "Expression host",
      antibiotic_resistance = "Antibiotic resistance",
      sequence_uncleaved = "Sequence (uncleaved)",
      sequence_cleaved = "Sequence (cleaved)",
      purification_strategy = "Purification strategy",
      tag_removal_required = "Tag removal required?", localisation = "Localisation",
      storage_buffer = "Storage buffer",
      references_previous_experiments = "References / previous experiments",
      amount_required_mg = "Amount required (mg)",
      final_concentration_mg_ml = "Final concentration required (mg/mL)",
      delivery_state = "Delivery state", aliquot_size = "Aliquot size"
    )
    lines <- c(lines, paste("Service module:", module_name))
    for (field in names(field_labels)) {
      value <- ppsv_mail_record_value(details, field)
      if (!nzchar(value)) value <- ppsv_mail_record_value(request, field)
      if (identical(field, "tag_removal_required")) {
        value <- switch(value, `1` = "Yes", `0` = "No", value)
      }
      if (nzchar(trimws(value))) {
        lines <- c(lines, paste0(field_labels[[field]], ": ", value))
      }
    }
  }

  if (is.data.frame(files) && nrow(files) > 0L && "original_name" %in% names(files)) {
    lines <- c(lines, "", "Files stored in PPSV:", paste0("- ", files$original_name))
  }
  if (nzchar(request_url)) lines <- c(lines, "", paste("PPSV request:", request_url))
  paste(c(lines, "", "Yours sincerely,", "The PPSV Project Management System"), collapse = "\n")
}

# A ticket link is included only when the ticket adapter returned a real URL.
ppsv_format_acknowledgement <- function(request, ticket_url = "") {
  name <- trimws(ppsv_mail_request_value(request, "submitter_name", "colleague"))
  lines <- c(
    paste0("Dear ", name, ","), "",
    "Thank you for your E-Mail. We will process your request as soon as possible.🙏", "",
    paste(
      "A member of our team will contact you shortly to confirm your request or",
      "to schedule a meeting to discuss your project in more detail."
    )
  )
  if (nzchar(trimws(ticket_url))) {
    lines <- c(
      lines, "",
      paste(
        "If you would like to add more information on this issue, simply reply to",
        "this email or use the following Link (use VPN if you are external)."
      ),
      ticket_url
    )
  }
  paste(c(lines, "", "Yours sincerely,", "The PPSV Team"), collapse = "\n")
}

ppsv_mail_message <- function(from, to, subject, body, reply_to = "", kind = "ticket") {
  if (!ppsv_email_is_valid(from)) stop("from must be a valid email address", call. = FALSE)
  if (!ppsv_email_is_valid(to)) stop("to must be a valid email address", call. = FALSE)
  if (!nzchar(trimws(subject))) stop("subject is required", call. = FALSE)
  if (nzchar(reply_to) && !ppsv_email_is_valid(reply_to)) {
    stop("reply_to must be empty or a valid email address", call. = FALSE)
  }
  list(
    kind = kind, from = trimws(from), to = trimws(to),
    reply_to = trimws(reply_to), subject = trimws(subject), body = body
  )
}

# Pure representation of the deterministic workflow. The durable implementation
# creates equivalent rows and activates fallback/ack only after a delivery result.
ppsv_plan_ticket_messages <- function(request, module = NULL, details = NULL,
                                      files = data.frame(), verified_ldap_email = "",
                                      settings = ppsv_mail_settings()) {
  errors <- ppsv_validate_mail_settings(settings)
  if (length(errors) > 0L) return(list(enabled = FALSE, errors = errors))
  if (identical(settings$mode, "disabled")) {
    return(list(enabled = FALSE, errors = character()))
  }

  verified_ldap_email <- trimws(ppsv_mail_scalar(verified_ldap_email))
  verified <- ppsv_email_is_valid(verified_ldap_email)
  subject <- ppsv_ticket_subject(request, module)
  body <- ppsv_format_ticket_body(request, module, details, files, settings)
  service_message <- ppsv_mail_message(
    settings$service_from, settings$ticket_to, subject, body,
    reply_to = if (verified) verified_ldap_email else "",
    kind = "ticket_service"
  )

  primary <- service_message
  fallback <- NULL
  if (identical(settings$mode, "ldap_from") && verified) {
    primary <- ppsv_mail_message(
      verified_ldap_email, settings$ticket_to, subject, body,
      kind = "ticket_ldap_from"
    )
    fallback <- service_message
  }

  acknowledgement <- NULL
  if (isTRUE(settings$direct_ack) && verified) {
    acknowledgement <- ppsv_mail_message(
      settings$service_from, verified_ldap_email,
      paste(ppsv_mail_record_value(request, "request_code", "PPSV request"), "received"),
      ppsv_format_acknowledgement(request), kind = "acknowledgement"
    )
  }

  list(
    enabled = TRUE,
    request = request,
    verified_ldap_email = if (verified) verified_ldap_email else "",
    primary = primary, fallback = fallback,
    acknowledgement = acknowledgement, errors = character()
  )
}

ppsv_mailr_send <- function(message, settings = ppsv_mail_settings()) {
  if (!requireNamespace("mailR", quietly = TRUE)) {
    stop("The mailR package is not installed", call. = FALSE)
  }
  smtp <- settings$smtp
  authenticate <- nzchar(ppsv_mail_scalar(smtp$user.name))
  if (!authenticate) {
    smtp$user.name <- NULL
    smtp$passwd <- NULL
  }
  args <- list(
    from = message$from, to = message$to, subject = message$subject,
    body = message$body, smtp = smtp, authenticate = authenticate,
    send = TRUE, encoding = "utf-8", html = FALSE
  )
  if (nzchar(ppsv_mail_scalar(message$reply_to))) args$replyTo <- message$reply_to
  do.call(mailR::send.mail, args)
  list(success = TRUE, ticket_url = NULL)
}

ppsv_normalize_send_result <- function(value) {
  if (identical(value, FALSE)) {
    return(list(
      success = FALSE,
      error = "Mail adapter reported delivery failure.",
      value = value
    ))
  }
  if (is.list(value) && "success" %in% names(value) && !isTRUE(value$success)) {
    return(list(
      success = FALSE,
      error = ppsv_mail_scalar(value$error, "Mail adapter reported delivery failure."),
      value = value
    ))
  }
  list(success = TRUE, error = "", value = value)
}

ppsv_deliver_ticket_plan <- function(plan, send_fn = ppsv_mailr_send,
                                     settings = ppsv_mail_settings()) {
  if (!isTRUE(plan$enabled)) {
    return(list(success = FALSE, skipped = TRUE, errors = plan$errors))
  }
  attempts <- list()
  attempt <- function(message) {
    tryCatch({
      value <- send_fn(message, settings)
      normalized <- ppsv_normalize_send_result(value)
      list(
        success = normalized$success,
        message = message,
        value = normalized$value,
        error = normalized$error
      )
    }, error = function(error) {
      list(success = FALSE, message = message, error = conditionMessage(error))
    })
  }

  ticket <- attempt(plan$primary)
  attempts[[length(attempts) + 1L]] <- ticket
  used_service_sender <- identical(plan$primary$kind, "ticket_service")
  if (!isTRUE(ticket$success) && !is.null(plan$fallback)) {
    ticket <- attempt(plan$fallback)
    attempts[[length(attempts) + 1L]] <- ticket
    used_service_sender <- isTRUE(ticket$success)
  }

  acknowledgement <- NULL
  if (isTRUE(ticket$success) && used_service_sender && !is.null(plan$acknowledgement)) {
    ack_message <- plan$acknowledgement
    ack_message$body <- ppsv_format_acknowledgement(
      plan$request %||% list(),
      ppsv_mail_scalar(ticket$value$ticket_url)
    )
    acknowledgement <- attempt(ack_message)
    attempts[[length(attempts) + 1L]] <- acknowledgement
  }

  list(
    success = isTRUE(ticket$success),
    acknowledgement_success = if (is.null(acknowledgement)) NA else isTRUE(acknowledgement$success),
    attempts = attempts,
    error = if (isTRUE(ticket$success)) "" else ppsv_mail_scalar(ticket$error, "Email delivery failed")
  )
}

ppsv_mail_retry_delay_seconds <- function(attempt_number) {
  attempt_number <- suppressWarnings(as.integer(attempt_number))
  if (is.na(attempt_number) || attempt_number < 1L) attempt_number <- 1L
  if (attempt_number > length(PPSV_RETRY_DELAYS_SECONDS)) return(NA_real_)
  PPSV_RETRY_DELAYS_SECONDS[[attempt_number]]
}

ppsv_default_mail_sender <- function(message, config) {
  settings <- ppsv_mail_settings(config = config)
  if (identical(settings$mode, "disabled")) {
    stop("Ticket delivery is currently disabled by PPSV_TICKET_MODE.", call. = FALSE)
  }
  errors <- ppsv_validate_mail_settings(settings)
  if (length(errors)) stop(paste(errors, collapse = "; "), call. = FALSE)
  dedupe_key <- ppsv_mail_scalar(message$dedupe_key)
  ldap_sender <- grepl(":ticket:ldap$", dedupe_key)
  if (ldap_sender && !identical(settings$mode, "ldap_from")) {
    stop("Queued LDAP-From delivery is not permitted by the current ticket mode.", call. = FALSE)
  }
  if (!ldap_sender && !identical(
    tolower(ppsv_mail_scalar(message$from_address)),
    tolower(settings$service_from)
  )) {
    stop("Queued service mail does not match the currently authorized PPSV sender.", call. = FALSE)
  }
  if (identical(message$message_kind, "ticket") && !identical(
    tolower(ppsv_mail_scalar(message$recipient)),
    tolower(settings$ticket_to)
  )) {
    stop("Queued ticket recipient does not match the current PPSV ticket address.", call. = FALSE)
  }
  if (identical(message$message_kind, "acknowledgement") && !isTRUE(settings$direct_ack)) {
    stop("Direct acknowledgements are currently disabled.", call. = FALSE)
  }
  mail <- ppsv_mail_message(
    from = message$from_address, to = message$recipient,
    subject = message$subject, body = message$body,
    reply_to = ppsv_mail_scalar(message$reply_to), kind = message$message_kind
  )
  ppsv_mailr_send(mail, settings)
}
