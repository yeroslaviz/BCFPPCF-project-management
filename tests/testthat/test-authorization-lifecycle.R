testthat::test_that("direct actions enforce ownership and the derived allowlist", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  other <- ppsv_test_user(ctx, "mallory")
  technician <- ppsv_test_user(ctx, "GrZeJsZc")
  admin <- ppsv_test_user(ctx, "YEROSLAVIZ")
  request <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)

  testthat::expect_equal(get_request(request$request_code, owner, ctx)$owner_username, "alice")
  testthat::expect_error(
    get_request(request$request_code, other, ctx),
    class = "ppsv_authorization_error"
  )
  forged <- list(username = "mallory", role = "admin", active = 1L)
  testthat::expect_error(
    get_request(request$request_code, forged, ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    update_status(request$request_code, "Accepted", user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    assign_request(request$request_code, "grzejszc", user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    archive_request(request$request_code, user = technician, ctx = ctx),
    class = "ppsv_authorization_error"
  )

  assigned <- assign_request(request$request_code, "grzejszc", user = technician, ctx = ctx)
  testthat::expect_equal(assigned$assignee_username, "grzejszc")
  updated <- update_status(
    request$request_code, "In progress", "Started\nwith approval",
    user = technician, ctx = ctx
  )
  testthat::expect_equal(updated$current_status, "In progress")
  testthat::expect_equal(tail(updated$status_history$new_status, 1), "In progress")
  testthat::expect_equal(tail(updated$status_history$changed_by, 1), "grzejszc")
  testthat::expect_equal(tail(updated$status_history$note, 1), "Started\nwith approval")

  testthat::expect_true(can(admin, "archive_request", updated))
  archive_request(request$request_code, user = admin, ctx = ctx)
  testthat::expect_equal(nrow(list_requests(admin, include_archived = TRUE, ctx = ctx)), 1L)
  testthat::expect_equal(nrow(list_requests(admin, include_archived = FALSE, ctx = ctx)), 0L)
  testthat::expect_error(
    get_request(request$request_code, owner, ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    get_request(request$request_code, technician, ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_equal(
    get_request(request$request_code, admin, ctx)$request_code,
    request$request_code
  )
})

testthat::test_that("stored role text cannot remove or grant allowlist privileges", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  technician <- ppsv_test_user(ctx, "grzejszc")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)

  con <- ppsv_db_connect(ctx$config)
  DBI::dbExecute(con, "UPDATE users SET role='admin' WHERE username='alice'")
  DBI::dbExecute(con, "UPDATE users SET role='user' WHERE username='grzejszc'")
  DBI::dbDisconnect(con)

  testthat::expect_error(
    update_status(request$request_code, "Accepted", user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    assign_request(request$request_code, "alice", user = technician, ctx = ctx),
    "active PPSV technician or administrator",
    class = "ppsv_validation_error"
  )
  testthat::expect_equal(
    update_status(request$request_code, "Accepted", user = technician, ctx = ctx)$current_status,
    "Accepted"
  )
  testthat::expect_equal(
    assign_request(request$request_code, "grzejszc", user = technician, ctx = ctx)$assignee_username,
    "grzejszc"
  )
  directory <- list_users(admin, ctx)
  testthat::expect_equal(directory$role[directory$username == "alice"], "user")
  testthat::expect_equal(directory$role[directory$username == "grzejszc"], "technician")
})

testthat::test_that("staff edits preserve the requester contact snapshot", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice", "alice@example.org", "Alice Requester")
  technician <- ppsv_test_user(ctx, "grzejszc", "tech@example.org", "PPSV Technician")
  request <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)

  edited <- update_request(
    request$request_code,
    list(protein_name = "Edited protein"),
    user = technician,
    ctx = ctx
  )
  testthat::expect_equal(edited$protein_name, "Edited protein")
  testthat::expect_equal(edited$contact_name, "Alice Requester")
  testthat::expect_equal(edited$contact_email, "alice@example.org")

  # Omitting contact changes—the normal staff editor path—must never replace
  # the snapshot with the staff actor's own LDAP identity.
  edited_again <- update_request(
    request$request_code,
    list(protein_name = "Edited again"),
    user = technician,
    ctx = ctx
  )
  testthat::expect_equal(edited_again$contact_name, "Alice Requester")
  testthat::expect_equal(edited_again$contact_email, "alice@example.org")
  testthat::expect_false(identical(edited_again$contact_name, "PPSV Technician"))
})

testthat::test_that("owner edits round-trip Unicode and multiline values without field loss", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  service <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)
  service_edit <- update_request(
    service$request_code,
    list(
      expression_construct = "ΔN construct αβγ\nresidues 12–248",
      references_previous_experiments = "First line\nSecond line: naïve control"
    ),
    user = owner,
    ctx = ctx
  )
  testthat::expect_equal(
    service_edit$expression_construct,
    "ΔN construct αβγ\nresidues 12–248"
  )
  testthat::expect_equal(
    service_edit$references_previous_experiments,
    "First line\nSecond line: naïve control"
  )
  testthat::expect_equal(service_edit$protein_name, service$protein_name)
  testthat::expect_equal(service_edit$billing_code, service$billing_code)

  inquiry <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  inquiry_edit <- update_request(
    inquiry$request_code,
    list(inquiry_message = "Überprüfung αβγ\nFollow-up line"),
    user = owner,
    ctx = ctx
  )
  testthat::expect_equal(
    inquiry_edit$inquiry_message,
    "Überprüfung αβγ\nFollow-up line"
  )
  testthat::expect_equal(inquiry_edit$inquiry_subject, inquiry$inquiry_subject)
})

testthat::test_that("staff may select every exact status and every change is audited", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  technician <- ppsv_test_user(ctx, "grzejszc")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)

  # Visit every remaining state, then deliberately move backwards to prove
  # that staff may select any of the seven configured statuses.
  transitions <- c(PPSV_STATUS_OPTIONS[-1L], "Submitted")
  actors <- rep(list(technician, admin), length.out = length(transitions))
  for (i in seq_along(transitions)) {
    request <- update_status(
      request$request_code,
      transitions[[i]],
      note = if (i %% 2L) paste("audit note", i) else NULL,
      user = actors[[i]],
      ctx = ctx
    )
  }

  history <- request$status_history
  expected_new <- c("Submitted", transitions)
  testthat::expect_equal(history$new_status, expected_new)
  testthat::expect_equal(history$old_status[-1L], head(expected_new, -1L))
  testthat::expect_equal(
    history$changed_by,
    c("alice", vapply(actors, function(actor) actor$username, character(1L)))
  )
  testthat::expect_true(all(nzchar(history$changed_at)))

  unchanged_count <- nrow(history)
  request <- update_status(request$request_code, "Submitted", user = technician, ctx = ctx)
  testthat::expect_equal(nrow(request$status_history), unchanged_count)

  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  testthat::expect_error(
    DBI::dbExecute(
      con,
      "UPDATE requests SET current_status='Invented' WHERE request_code=?",
      params = list(request$request_code)
    ),
    "invalid PPSV status"
  )
})

testthat::test_that("closed requests and inactive accounts are enforced server-side", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  technician <- ppsv_test_user(ctx, "grzejszc")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  update_status(request$request_code, "Closed", user = admin, ctx = ctx)
  testthat::expect_error(
    update_request(request$request_code, list(inquiry_subject = "Changed"), user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )

  # Closed requests remain editable by facility staff, and staff may reopen
  # them by selecting any status.
  staff_edit <- update_request(
    request$request_code,
    list(inquiry_subject = "Staff correction"),
    user = technician,
    ctx = ctx
  )
  testthat::expect_equal(staff_edit$inquiry_subject, "Staff correction")
  reopened <- update_status(request$request_code, "Under review", user = technician, ctx = ctx)
  testthat::expect_equal(reopened$current_status, "Under review")

  testthat::expect_error(
    set_user_active("alice", FALSE, user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  set_user_active("alice", FALSE, user = admin, ctx = ctx)
  testthat::expect_error(list_requests(owner, ctx = ctx), class = "ppsv_authentication_error")
})

testthat::test_that("file actions enforce owner, staff, and admin boundaries directly", {
  ctx <- ppsv_test_context()
  root <- attr(ctx, "test_root")
  owner <- ppsv_test_user(ctx, "alice")
  other <- ppsv_test_user(ctx, "mallory")
  technician <- ppsv_test_user(ctx, "grzejszc")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "owner input.txt", "owner data"),
    user = owner,
    ctx = ctx
  )
  file_id <- request$files$id[[1L]]

  testthat::expect_error(
    download_file(request$request_code, file_id, user = other, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    add_files(
      request$request_code,
      ppsv_test_upload(root, "forged.txt", "forged"),
      user = other,
      ctx = ctx
    ),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    add_files(
      request$request_code,
      ppsv_test_upload(root, "owner-result.txt", "result"),
      kind = "results",
      user = owner,
      ctx = ctx
    ),
    class = "ppsv_authorization_error"
  )

  files <- add_files(
    request$request_code,
    ppsv_test_upload(root, "staff-result.txt", "validated result"),
    kind = "results",
    user = technician,
    ctx = ctx
  )
  result_id <- files$id[files$category == "results"][[1L]]
  testthat::expect_error(
    archive_file(request$request_code, result_id, user = owner, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    archive_file(request$request_code, result_id, user = technician, ctx = ctx),
    class = "ppsv_authorization_error"
  )

  result_path <- download_file(request$request_code, result_id, user = admin, ctx = ctx)
  testthat::expect_silent(
    archive_file(request$request_code, result_id, user = admin, ctx = ctx)
  )
  testthat::expect_true(file.exists(result_path))
  testthat::expect_equal(nrow(list_files(request$request_code, admin, ctx = ctx)), 1L)
  archived <- list_files(request$request_code, admin, include_archived = TRUE, ctx = ctx)
  testthat::expect_equal(nrow(archived), 2L)
  testthat::expect_true(nzchar(archived$archived_at[archived$id == result_id]))
  testthat::expect_equal(nrow(get_request(request$request_code, owner, ctx)$files), 1L)
  testthat::expect_error(
    download_file(request$request_code, result_id, user = owner, ctx = ctx),
    class = "ppsv_not_found_error"
  )
  testthat::expect_equal(
    download_file(request$request_code, result_id, user = admin, ctx = ctx),
    result_path
  )
})

testthat::test_that("production current_user rejects direct identity injection", {
  ctx <- ppsv_test_context()
  ldap_ctx <- ctx
  ldap_ctx$config$auth_mode <- "ldap"
  testthat::expect_error(
    current_user("yeroslaviz", headers = list(), ctx = ldap_ctx),
    "accepted only when AUTH_MODE=test"
  )
  header_user <- current_user(
    headers = list(
      HTTP_X_REMOTE_USER = "alice",
      HTTP_X_REMOTE_NAME = "Alice",
      HTTP_X_REMOTE_EMAIL = "alice@example.org"
    ),
    ctx = ldap_ctx
  )
  testthat::expect_equal(header_user$username, "alice")
})

testthat::test_that("administrative repositories and b_profa membership obey derived roles", {
  ctx <- ppsv_test_context()
  alice <- ppsv_test_user(ctx, "alice")
  bob <- ppsv_test_user(ctx, "bob")
  technician <- ppsv_test_user(ctx, "grzejszc")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  alice_request <- create_request(ppsv_valid_inquiry_payload(), user = alice, ctx = ctx)
  create_request(
    ppsv_valid_inquiry_payload(inquiry_subject = "Bob only"),
    user = bob,
    ctx = ctx
  )

  alice_rows <- list_requests(alice, ctx = ctx)
  testthat::expect_equal(alice_rows$request_code, alice_request$request_code)
  testthat::expect_error(list_users(technician, ctx), class = "ppsv_authorization_error")
  testthat::expect_error(
    set_user_active("alice", FALSE, user = technician, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_error(
    list_mail_status(NULL, alice, ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_gt(nrow(list_mail_status(NULL, technician, ctx)), 0L)
  outbox_id <- ppsv_db_query(ctx, "SELECT id FROM mail_outbox ORDER BY id LIMIT 1")$id[[1L]]
  testthat::expect_error(
    retry_mail(outbox_id, user = technician, ctx = ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_gt(nrow(list_users(admin, ctx)), 0L)

  pool_member <- current_user(
    username = "poolmember",
    headers = list(
      HTTP_X_REMOTE_NAME = "Pool Member",
      HTTP_X_REMOTE_EMAIL = "poolmember@example.org",
      HTTP_X_REMOTE_GROUP = "b_profa"
    ),
    ctx = ctx
  )
  testthat::expect_equal(pool_member$role, "user")
  testthat::expect_false(ppsv_is_staff(pool_member))
})
