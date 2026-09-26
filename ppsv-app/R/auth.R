# Authentication identity normalization and server-side authorization.

ppsv_abort <- function(message, class = "ppsv_error", details = NULL) {
  condition <- structure(
    list(message = message, call = NULL, details = details),
    class = c(class, "ppsv_error", "error", "condition")
  )
  stop(condition)
}

ppsv_normalize_username <- function(username) {
  value <- tolower(ppsv_trim(username))
  value <- sub("^.*\\\\", "", value)
  value <- sub("@.*$", "", value)
  if (!nzchar(value) || !grepl("^[a-z0-9._-]+$", value)) {
    ppsv_abort("No valid authenticated LDAP username was supplied.", "ppsv_authentication_error")
  }
  value
}

ppsv_role_for_username <- function(username) {
  username <- ppsv_normalize_username(username)
  if (username %in% tolower(PPSV_ADMIN_USERS$username)) return("admin")
  if (username %in% tolower(PPSV_TECHNICIAN_USERS$username)) return("technician")
  "user"
}

ppsv_identity_from_headers <- function(headers = list()) {
  if (is.null(headers)) headers <- list()
  names(headers) <- toupper(names(headers) %||% character())
  candidate <- headers[["HTTP_X_REMOTE_USER"]] %||%
    headers[["REMOTE_USER"]] %||%
    headers[["HTTP_REMOTE_USER"]]
  ppsv_normalize_username(candidate)
}

ppsv_user_as_list <- function(user) {
  if (is.data.frame(user)) {
    if (nrow(user) != 1L) ppsv_abort("Expected exactly one user.", "ppsv_authentication_error")
    return(as.list(user[1L, , drop = FALSE]))
  }
  if (is.character(user) && length(user) == 1L) {
    return(list(username = ppsv_normalize_username(user), role = ppsv_role_for_username(user), active = 1L))
  }
  if (!is.list(user)) ppsv_abort("Invalid user identity.", "ppsv_authentication_error")
  user$username <- ppsv_normalize_username(user$username)
  # Roles are never accepted from callers or editable database state. The
  # version-controlled allowlist is the sole privilege source.
  user$role <- ppsv_role_for_username(user$username)
  user$active <- as.integer(user$active %||% 1L)
  user
}

ppsv_is_staff <- function(user) {
  ppsv_user_as_list(user)$role %in% c("technician", "admin")
}

ppsv_is_admin <- function(user) {
  identical(ppsv_user_as_list(user)$role, "admin")
}

ppsv_request_owner <- function(request) {
  if (is.data.frame(request)) request <- as.list(request[1L, , drop = FALSE])
  ppsv_trim(request$owner_username)
}

ppsv_request_closed <- function(request) {
  if (is.data.frame(request)) request <- as.list(request[1L, , drop = FALSE])
  identical(ppsv_trim(request$current_status), "Closed") || nzchar(ppsv_trim(request$archived_at))
}

ppsv_request_archived <- function(request) {
  if (is.data.frame(request)) request <- as.list(request[1L, , drop = FALSE])
  nzchar(ppsv_trim(request$archived_at))
}

# Central authorization policy. UI visibility may call this function, but all
# mutating facade functions call it again before touching data or files.
can <- function(user, action, request = NULL) {
  user <- ppsv_user_as_list(user)
  if (!identical(as.integer(user$active), 1L)) return(FALSE)
  role <- user$role
  staff <- role %in% c("technician", "admin")
  admin <- identical(role, "admin")
  owner <- !is.null(request) && identical(user$username, ppsv_request_owner(request))
  closed <- !is.null(request) && ppsv_request_closed(request)
  archived <- !is.null(request) && ppsv_request_archived(request)

  switch(
    action,
    create_request = TRUE,
    # Archive is an administrator-only visibility boundary as well as an
    # administrator-only action. This keeps direct IDs from bypassing the
    # archived-request filtering used by the dashboards.
    view_request = (staff || owner) && (!archived || admin),
    download_file = (staff || owner) && (!archived || admin),
    download_pdf = (staff || owner) && (!archived || admin),
    edit_request = !archived && (staff || (owner && !closed)),
    add_file = !archived && (staff || (owner && !closed)),
    change_status = staff && !archived,
    assign_request = staff && !archived,
    archive_request = admin && !archived,
    archive_file = admin,
    view_users = admin,
    manage_users = admin,
    view_mail = staff,
    retry_mail = admin,
    FALSE
  )
}

ppsv_require <- function(user, action, request = NULL) {
  if (!isTRUE(can(user, action, request))) {
    ppsv_abort(
      sprintf("You are not authorized to perform action '%s'.", action),
      "ppsv_authorization_error"
    )
  }
  invisible(TRUE)
}
