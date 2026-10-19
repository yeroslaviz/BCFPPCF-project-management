# Backend context and authenticated-user entry points.

.ppsv_state <- new.env(parent = emptyenv())

# Initialize/migrate the configured database and register a process-local default
# context. Connections are short-lived per operation; a connection is never
# shared between Shiny sessions.
ppsv_initialize <- function(config = ppsv_config(), initialize_db = TRUE) {
  if (isTRUE(initialize_db)) ppsv_initialize_database(config)
  context <- structure(list(config = config), class = "ppsv_context")
  .ppsv_state$context <- context
  context
}

ppsv_default_context <- function() {
  if (is.null(.ppsv_state$context)) {
    stop("PPSV backend is not initialized. Call ppsv_initialize() first.", call. = FALSE)
  }
  .ppsv_state$context
}

current_user <- function(username = NULL, headers = list(), ctx = ppsv_default_context()) {
  header_names <- toupper(names(headers) %||% character())
  names(headers) <- header_names
  if (identical(ctx$config$auth_mode, "test") && !is.null(username) && nzchar(ppsv_trim(username))) {
    username <- ppsv_normalize_username(username)
  } else {
    if (!is.null(username) && nzchar(ppsv_trim(username))) {
      ppsv_abort(
        "A direct username is accepted only when AUTH_MODE=test.",
        "ppsv_authentication_error"
      )
    }
    username <- ppsv_identity_from_headers(headers)
  }
  profile <- list(
    display_name = headers[["HTTP_X_REMOTE_NAME"]] %||% "",
    email = headers[["HTTP_X_REMOTE_EMAIL"]] %||% "",
    research_group = headers[["HTTP_X_REMOTE_GROUP"]] %||% "",
    phone = headers[["HTTP_X_REMOTE_PHONE"]] %||% ""
  )
  missing <- !vapply(profile, function(value) nzchar(ppsv_trim(value)), logical(1L))
  if (identical(ctx$config$auth_mode, "ldap") && any(missing)) {
    ldap_profile <- tryCatch(
      ppsv_ldap_lookup_user(username),
      error = function(error) ppsv_ldap_empty_profile()
    )
    profile[missing] <- ldap_profile[names(profile)[missing]]
  }
  identity <- list(
    username = username,
    display_name = profile$display_name,
    email = profile$email,
    research_group = profile$research_group,
    phone = profile$phone,
    ldap_name_verified = nzchar(ppsv_trim(profile$display_name)),
    ldap_email_verified = nzchar(ppsv_trim(profile$email))
  )
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  user <- ppsv_db_transaction(con, ppsv_sync_user(con, identity, login = TRUE), immediate = TRUE)
  if (!identical(as.integer(user$active), 1L)) {
    ppsv_abort("This PPSV account is inactive.", "ppsv_authentication_error")
  }
  user
}
