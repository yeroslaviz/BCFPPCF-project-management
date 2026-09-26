testthat::test_that("service sender uses only verified LDAP Reply-To and gates acknowledgement", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = TRUE)
  user <- ppsv_test_user(ctx, "alice", "alice@example.org", "Alice")
  payload <- ppsv_valid_inquiry_payload(contact_email = "forged@evil.example")
  request <- create_request(payload, user = user, ctx = ctx)
  outbox <- list_mail_status(request$request_code, user, ctx)

  ticket <- outbox[outbox$message_kind == "ticket", , drop = FALSE]
  ack <- outbox[outbox$message_kind == "acknowledgement", , drop = FALSE]
  testthat::expect_equal(ticket$from_address, "ppsv-service@biochem.mpg.de")
  testthat::expect_equal(ticket$reply_to, "alice@example.org")
  testthat::expect_false(any(grepl("forged@evil.example", c(ticket$from_address, ticket$reply_to), fixed = TRUE)))
  testthat::expect_equal(ack$recipient, "alice@example.org")
  testthat::expect_equal(ack$status, "suppressed")

  calls <- character()
  sender <- function(message, config) {
    calls <<- c(calls, message$message_kind)
    list(ticket_url = "https://tickets.example.org/T-1")
  }
  result <- ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)
  testthat::expect_equal(calls, c("ticket", "acknowledgement"))
  testthat::expect_equal(result$sent, 2L)
  final <- list_mail_status(request$request_code, user, ctx)
  testthat::expect_true(all(final$status == "sent"))
  ack_row <- ppsv_db_query(ctx, "SELECT body FROM mail_outbox WHERE message_kind='acknowledgement'")
  testthat::expect_match(ack_row$body, "https://tickets.example.org/T-1", fixed = TRUE)
})

testthat::test_that("unapproved sender modes fail closed while retaining the request", {
  service_ctx <- ppsv_test_context("service_reply_to")
  service_ctx$config$service_identity_authorized <- FALSE
  owner <- ppsv_test_user(service_ctx, "alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = service_ctx)
  rows <- list_mail_status(request$request_code, owner, service_ctx)
  testthat::expect_equal(request$ticket_state, "configuration_error")
  testthat::expect_true(all(rows$status == "suppressed"))
  testthat::expect_match(rows$last_error, "PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK")
  testthat::expect_equal(ppsv_process_mail_outbox(ctx = service_ctx)$processed, 0L)

  ldap_ctx <- ppsv_test_context("ldap_from")
  ldap_ctx$config$ticket_e2e_test_ack <- FALSE
  ldap_owner <- ppsv_test_user(ldap_ctx, "bob")
  ldap_request <- create_request(ppsv_valid_inquiry_payload(), user = ldap_owner, ctx = ldap_ctx)
  ldap_rows <- list_mail_status(ldap_request$request_code, ldap_owner, ldap_ctx)
  testthat::expect_equal(ldap_request$ticket_state, "configuration_error")
  testthat::expect_match(ldap_rows$last_error, "PPSV_TICKET_E2E_TEST_ACK")

  untested_ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  untested_ctx$config$ticket_e2e_test_ack <- FALSE
  untested_owner <- ppsv_test_user(untested_ctx, "carol")
  untested_request <- create_request(
    ppsv_valid_inquiry_payload(),
    user = untested_owner,
    ctx = untested_ctx
  )
  testthat::expect_equal(untested_request$ticket_state, "configuration_error")
  testthat::expect_match(
    list_mail_status(untested_request$request_code, untested_owner, untested_ctx)$last_error,
    "PPSV_TICKET_E2E_TEST_ACK"
  )
})

testthat::test_that("LDAP From rejection activates service fallback and exactly one acknowledgement", {
  ctx <- ppsv_test_context("ldap_from", direct_ack = TRUE)
  user <- ppsv_test_user(ctx, "alice", "alice@example.org", "Alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  calls <- character()
  sender <- function(message, config) {
    calls <<- c(calls, message$dedupe_key)
    if (grepl(":ticket:ldap$", message$dedupe_key)) stop("relay rejected sender")
    list(ticket_url = NULL)
  }
  result <- ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)
  testthat::expect_equal(
    calls,
    c("PPSV000001:ticket:ldap", "PPSV000001:ticket:fallback", "PPSV000001:ack")
  )
  testthat::expect_equal(result$processed, 3L)
  rows <- ppsv_db_query(ctx, "SELECT dedupe_key,status,attempt_count FROM mail_outbox ORDER BY id")
  testthat::expect_equal(rows$status, c("failed", "sent", "sent"))
  testthat::expect_equal(nrow(rows[grepl(":ack$", rows$dedupe_key), ]), 1L)
})

testthat::test_that("LDAP From success leaves fallback and direct acknowledgement suppressed", {
  ctx <- ppsv_test_context("ldap_from", direct_ack = TRUE)
  user <- ppsv_test_user(ctx, "alice", "alice@example.org", "Alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  calls <- character()
  sender <- function(message, config) {
    calls <<- c(calls, message$dedupe_key)
    list(success = TRUE, ticket_url = "https://tickets.example.org/T-ldap")
  }
  first <- ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)
  second <- ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)
  testthat::expect_equal(first$sent, 1L)
  testthat::expect_equal(second$processed, 0L)
  testthat::expect_equal(calls, "PPSV000001:ticket:ldap")
  rows <- ppsv_db_query(ctx, "SELECT dedupe_key,status FROM mail_outbox ORDER BY id")
  testthat::expect_equal(rows$status, c("sent", "suppressed", "suppressed"))
  testthat::expect_equal(get_request(request$request_code, user, ctx)$ticket_state, "sent")
})

testthat::test_that("admin retry cannot resurrect LDAP From after fallback activation", {
  ctx <- ppsv_test_context("ldap_from", direct_ack = TRUE)
  owner <- ppsv_test_user(ctx, "alice")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  start <- Sys.time() + 60
  failed <- function(message, config) stop("relay rejected sender")

  testthat::expect_equal(
    ppsv_process_mail_outbox(limit = 1L, send_fun = failed, now = start, ctx = ctx)$failed,
    1L
  )
  rows <- ppsv_db_query(ctx, "SELECT id,dedupe_key,status FROM mail_outbox ORDER BY id")
  ldap_id <- rows$id[grepl(":ticket:ldap$", rows$dedupe_key)][[1L]]
  fallback_id <- rows$id[grepl(":ticket:fallback$", rows$dedupe_key)][[1L]]
  testthat::expect_equal(rows$status[rows$id == fallback_id], "pending")
  testthat::expect_error(
    retry_mail(ldap_id, user = admin, ctx = ctx),
    "cannot be retried after fallback exists",
    class = "ppsv_validation_error"
  )

  testthat::expect_equal(
    ppsv_process_mail_outbox(limit = 1L, send_fun = failed, now = start, ctx = ctx)$failed,
    1L
  )
  testthat::expect_silent(retry_mail(fallback_id, user = admin, ctx = ctx))
  testthat::expect_equal(
    get_request(request$request_code, owner, ctx)$ticket_state,
    "retrying"
  )
})

testthat::test_that("structured adapter failures are never recorded as successful delivery", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  owner <- ppsv_test_user(ctx, "alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  sender <- function(message, config) list(success = FALSE, error = "adapter declined")
  result <- ppsv_process_mail_outbox(send_fun = sender, now = Sys.time() + 60, ctx = ctx)
  testthat::expect_equal(result$sent, 0L)
  testthat::expect_equal(result$failed, 1L)
  row <- list_mail_status(request$request_code, owner, ctx)[1L, ]
  testthat::expect_equal(row$status, "failed")
  testthat::expect_match(row$last_error, "adapter declined")
  attempts <- ppsv_db_query(ctx, "SELECT succeeded,error_message FROM mail_attempts")
  testthat::expect_equal(attempts$succeeded, 0L)
  testthat::expect_match(attempts$error_message, "adapter declined")
})

testthat::test_that("a plain FALSE mail-adapter result is a delivery failure", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  owner <- ppsv_test_user(ctx, "alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  sender <- function(message, config) FALSE
  result <- ppsv_process_mail_outbox(send_fun = sender, now = Sys.time() + 60, ctx = ctx)
  testthat::expect_equal(result$sent, 0L)
  testthat::expect_equal(result$failed, 1L)
  row <- list_mail_status(request$request_code, owner, ctx)[1L, ]
  testthat::expect_equal(row$status, "failed")
  testthat::expect_match(row$last_error, "reported delivery failure")
})

testthat::test_that("mail retries follow all six durable attempts and then stop", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  owner <- ppsv_test_user(ctx, "alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  failed <- function(message, config) stop("SMTP unavailable")
  start <- Sys.time() + 60
  offsets <- c(0, 300, 300 + 1800, 300 + 1800 + 7200,
               300 + 1800 + 7200 + 43200,
               300 + 1800 + 7200 + 43200 + 86400)
  for (offset in offsets) {
    result <- ppsv_process_mail_outbox(
      limit = 1L,
      send_fun = failed,
      now = start + offset,
      ctx = ctx
    )
    testthat::expect_equal(result$failed, 1L)
  }
  row <- list_mail_status(request$request_code, owner, ctx)[1L, ]
  testthat::expect_equal(row$status, "failed")
  testthat::expect_equal(row$attempt_count, 6L)
  testthat::expect_true(is.na(row$next_attempt_at) || !nzchar(row$next_attempt_at))
  attempts <- ppsv_db_query(
    ctx,
    "SELECT attempt_number,succeeded FROM mail_attempts ORDER BY attempt_number"
  )
  testthat::expect_equal(attempts$attempt_number, 1:6)
  testthat::expect_true(all(attempts$succeeded == 0L))
  testthat::expect_equal(get_request(request$request_code, owner, ctx)$ticket_state, "failed")
  testthat::expect_equal(
    ppsv_process_mail_outbox(send_fun = failed, now = start + max(offsets) + 86400, ctx = ctx)$processed,
    0L
  )
})

testthat::test_that("queued mail obeys current disabled, sender, and mode gates", {
  service_ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  service_owner <- ppsv_test_user(service_ctx, "alice")
  create_request(ppsv_valid_inquiry_payload(), user = service_owner, ctx = service_ctx)
  service_row <- as.list(ppsv_db_query(service_ctx, "SELECT * FROM mail_outbox LIMIT 1")[1L, ])

  disabled <- service_ctx$config
  disabled$ticket_mode <- "disabled"
  testthat::expect_error(
    ppsv_default_mail_sender(service_row, disabled),
    "currently disabled"
  )
  changed_sender <- service_ctx$config
  changed_sender$mail_from <- "new-service@biochem.mpg.de"
  testthat::expect_error(
    ppsv_default_mail_sender(service_row, changed_sender),
    "currently authorized PPSV sender"
  )

  ldap_ctx <- ppsv_test_context("ldap_from", direct_ack = TRUE)
  ldap_owner <- ppsv_test_user(ldap_ctx, "bob")
  create_request(ppsv_valid_inquiry_payload(), user = ldap_owner, ctx = ldap_ctx)
  ldap_row <- as.list(ppsv_db_query(
    ldap_ctx,
    "SELECT * FROM mail_outbox WHERE dedupe_key LIKE '%:ticket:ldap'"
  )[1L, ])
  switched <- ldap_ctx$config
  switched$ticket_mode <- "service_reply_to"
  testthat::expect_error(
    ppsv_default_mail_sender(ldap_row, switched),
    "not permitted by the current ticket mode"
  )
})

testthat::test_that("missing LDAP email suppresses acknowledgement and never uses manual email headers", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = TRUE)
  user <- ppsv_test_user(ctx, "alice", email_present = FALSE)
  request <- create_request(
    ppsv_valid_inquiry_payload(contact_email = "manual@example.org"),
    user = user,
    ctx = ctx
  )
  rows <- list_mail_status(request$request_code, user, ctx)
  ticket <- rows[rows$message_kind == "ticket", ]
  ack <- rows[rows$message_kind == "acknowledgement", ]
  testthat::expect_true(is.na(ticket$reply_to) || !nzchar(ticket$reply_to))
  testthat::expect_equal(ticket$from_address, "ppsv-service@biochem.mpg.de")
  testthat::expect_equal(ack$status, "suppressed")
  testthat::expect_match(ack$last_error, "no verified LDAP email")
  stored <- get_request(request$request_code, user, ctx)
  testthat::expect_equal(stored$contact_email_verified, 0L)
})

testthat::test_that("manually entered contact identity remains marked unverified", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice", email_present = FALSE, name = "")
  request <- create_request(
    ppsv_valid_inquiry_payload(
      contact_name = "Manual Contact",
      contact_email = "manual@example.org"
    ),
    user = user,
    ctx = ctx
  )
  testthat::expect_equal(request$contact_name, "Manual Contact")
  testthat::expect_equal(request$contact_email, "manual@example.org")
  testthat::expect_equal(request$contact_name_verified, 0L)
  testthat::expect_equal(request$contact_email_verified, 0L)
})

testthat::test_that("failed messages retain exact retry timing and admin retry is enforced", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  user <- ppsv_test_user(ctx, "alice")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  request <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  start <- Sys.time() + 60
  failed <- function(message, config) stop("SMTP unavailable")
  result <- ppsv_process_mail_outbox(send_fun = failed, now = start, ctx = ctx)
  testthat::expect_equal(result$failed, 1L)
  row <- list_mail_status(request$request_code, user, ctx)[1, ]
  testthat::expect_equal(row$attempt_count, 1L)
  testthat::expect_equal(row$next_attempt_at, ppsv_now(start + 300))
  testthat::expect_error(retry_mail(row$id, user = user, ctx = ctx), class = "ppsv_authorization_error")
  testthat::expect_silent(retry_mail(row$id, user = admin, ctx = ctx))
  testthat::expect_equal(list_mail_status(request$request_code, user, ctx)$status[[1L]], "pending")
})

testthat::test_that("storage sanitizes names, verifies checksums, and falls back safely", {
  ctx <- ppsv_test_context(pool = FALSE)
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  upload <- ppsv_test_upload(root, "../../unsafe α?.txt", "hello")
  request <- create_request(ppsv_valid_inquiry_payload(), uploads = upload, user = user, ctx = ctx)
  testthat::expect_equal(request$storage_state, "fallback")
  testthat::expect_equal(nrow(request$files), 1L)
  testthat::expect_false(grepl("/|\\\\|\\.\\.", request$files$original_name))
  path <- download_file(request$request_code, request$files$id, user = user, ctx = ctx)
  testthat::expect_true(file.exists(path))
  writeLines("tampered", path)
  testthat::expect_error(
    download_file(request$request_code, request$files$id, user = user, ctx = ctx),
    "checksum verification failed"
  )
})

testthat::test_that("an unverified pool mount point falls back instead of using local disk", {
  ctx <- ppsv_test_context()
  ctx$config$allow_local_pool <- FALSE
  ctx$config$pool_expected_source <- "definitely-not-the-current-mount"
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "mount-loss.txt", "keep me safe"),
    user = user,
    ctx = ctx
  )
  testthat::expect_equal(request$storage_state, "fallback")
  testthat::expect_equal(request$files$storage_location, "fallback")
  stored_path <- ppsv_db_query(
    ctx,
    "SELECT absolute_path FROM request_files WHERE request_id=?",
    list(request$id)
  )$absolute_path[[1L]]
  testthat::expect_true(startsWith(
    stored_path,
    normalizePath(ctx$config$fallback_root, winslash = "/")
  ))
})

testthat::test_that("downloads fail closed when the configured pool identity changes", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "pool-file.txt", "trusted bytes"),
    user = user,
    ctx = ctx
  )
  testthat::expect_equal(request$files$storage_location, "pool")
  ctx$config$allow_local_pool <- FALSE
  ctx$config$pool_expected_source <- "different-reviewed-source"
  testthat::expect_error(
    download_file(request$request_code, request$files$id, user = user, ctx = ctx),
    "outside its configured storage root",
    class = "ppsv_storage_error"
  )
})

testthat::test_that("storage rejects source and destination symlinks and enforces cumulative quota", {
  testthat::skip_on_os("windows")
  ctx <- ppsv_test_context(max_upload_mb = 0.00002)
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  source <- file.path(root, "source.txt")
  writeLines("1234567890", source)
  link <- file.path(root, "source-link")
  file.symlink(source, link)
  upload_link <- data.frame(name = "link.txt", type = "text/plain", datapath = link)
  testthat::expect_error(
    create_request(ppsv_valid_inquiry_payload(), uploads = upload_link, user = user, ctx = ctx),
    "Symbolic-link uploads"
  )

  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "one.txt", "1234567890"),
    user = user,
    ctx = ctx
  )
  testthat::expect_error(
    add_files(
      request$request_code,
      ppsv_test_upload(root, "two.txt", "abcdefghijklmno"),
      user = user,
      ctx = ctx
    ),
    "request limit"
  )
  testthat::expect_equal(nrow(list_files(request$request_code, user, ctx = ctx)), 1L)

  symlink_ctx <- ppsv_test_context()
  symlink_user <- ppsv_test_user(symlink_ctx, "bob")
  outside <- file.path(attr(symlink_ctx, "test_root"), "outside")
  dir.create(outside)
  file.symlink(outside, file.path(symlink_ctx$config$pool_root, "PPSV000001"))
  fallback_request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(attr(symlink_ctx, "test_root"), "safe.txt", "data"),
    user = symlink_user,
    ctx = symlink_ctx
  )
  testthat::expect_equal(fallback_request$storage_state, "fallback")
  testthat::expect_length(list.files(outside), 0L)

  root_link_ctx <- ppsv_test_context()
  root_link_user <- ppsv_test_user(root_link_ctx, "carol")
  root_link_base <- attr(root_link_ctx, "test_root")
  root_link_outside <- file.path(root_link_base, "root-link-outside")
  dir.create(root_link_outside)
  unlink(root_link_ctx$config$pool_root, recursive = TRUE)
  testthat::expect_true(file.symlink(root_link_outside, root_link_ctx$config$pool_root))
  root_link_request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root_link_base, "root-safe.txt", "root data"),
    user = root_link_user,
    ctx = root_link_ctx
  )
  testthat::expect_equal(root_link_request$storage_state, "fallback")
  testthat::expect_length(list.files(root_link_outside), 0L)

  unlink(root_link_ctx$config$fallback_root, recursive = TRUE)
  testthat::expect_true(file.symlink(root_link_outside, root_link_ctx$config$fallback_root))
  testthat::expect_error(
    add_files(
      root_link_request$request_code,
      ppsv_test_upload(root_link_base, "must-fail.txt", "important"),
      user = root_link_user,
      ctx = root_link_ctx
    ),
    "Neither the PPSV pool nor fallback upload storage is writable",
    class = "ppsv_storage_error"
  )
  testthat::expect_length(list.files(root_link_outside), 0L)

  healthy_pool_ctx <- ppsv_test_context()
  healthy_pool_user <- ppsv_test_user(healthy_pool_ctx, "dave")
  healthy_pool_base <- attr(healthy_pool_ctx, "test_root")
  healthy_pool_outside <- file.path(healthy_pool_base, "bad-fallback-target")
  dir.create(healthy_pool_outside)
  testthat::expect_true(file.symlink(
    healthy_pool_outside,
    healthy_pool_ctx$config$fallback_root
  ))
  pool_request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(healthy_pool_base, "pool-still-works.txt", "pool data"),
    user = healthy_pool_user,
    ctx = healthy_pool_ctx
  )
  testthat::expect_equal(pool_request$storage_state, "pool")
  testthat::expect_length(list.files(healthy_pool_outside), 0L)
})

testthat::test_that("downloads reject a stored file replaced by an in-root symbolic link", {
  testthat::skip_on_os("windows")
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "link-swap.txt", "same bytes"),
    user = user,
    ctx = ctx
  )
  stored <- ppsv_db_query(
    ctx,
    "SELECT absolute_path FROM request_files WHERE request_id=?",
    list(request$id)
  )$absolute_path[[1L]]
  alternate <- file.path(dirname(stored), "untracked-same-content")
  testthat::expect_true(file.copy(stored, alternate, overwrite = FALSE))
  unlink(stored)
  testthat::expect_true(file.symlink(alternate, stored))
  testthat::expect_error(
    download_file(request$request_code, request$files$id, user = user, ctx = ctx),
    "outside its configured storage root",
    class = "ppsv_storage_error"
  )
})

testthat::test_that("file-bearing submissions roll back when both storage roots fail", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  blocked_pool <- file.path(root, "blocked-pool")
  blocked_fallback <- file.path(root, "blocked-fallback")
  writeLines("not a directory", blocked_pool)
  writeLines("not a directory", blocked_fallback)
  ctx$config$pool_root <- blocked_pool
  ctx$config$fallback_root <- blocked_fallback

  testthat::expect_error(
    create_request(
      ppsv_valid_inquiry_payload(),
      uploads = ppsv_test_upload(root, "must-not-disappear.txt", "important"),
      user = user,
      ctx = ctx
    ),
    "Neither the PPSV pool nor fallback upload storage is writable",
    class = "ppsv_storage_error"
  )
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM requests")), 0L)
  testthat::expect_equal(
    ppsv_db_query(ctx, "SELECT next_value FROM sequence_counters WHERE name='request'")$next_value,
    1L
  )

  # Storage availability must not block a submission that has no files.
  created <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  testthat::expect_equal(created$request_code, "PPSV000001")
  testthat::expect_equal(created$storage_state, "none")
})

testthat::test_that("fallback reconciliation is checksum-safe and preserves source copies", {
  ctx <- ppsv_test_context(pool = FALSE)
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "reconcile.txt", "authoritative bytes"),
    user = user,
    ctx = ctx
  )
  file_row <- ppsv_db_query(
    ctx,
    "SELECT id,stored_name,absolute_path,sha256 FROM request_files WHERE request_id=?",
    params = list(request$id)
  )
  fallback_source <- file_row$absolute_path[[1L]]
  testthat::expect_true(file.exists(fallback_source))
  testthat::expect_equal(
    digest::digest(file = fallback_source, algo = "sha256", serialize = FALSE),
    file_row$sha256[[1L]]
  )

  dir.create(ctx$config$pool_root, recursive = TRUE)
  target_dir <- ppsv_prepare_storage_directory(
    ctx$config$pool_root,
    request$request_code,
    "inputs"
  )
  destination <- file.path(target_dir, file_row$stored_name[[1L]])
  writeLines("pre-existing wrong bytes", destination)
  testthat::expect_equal(ppsv_reconcile_storage(ctx), 0L)
  unchanged <- ppsv_db_query(ctx, "SELECT storage_location FROM request_files WHERE id=?", list(file_row$id))
  testthat::expect_equal(unchanged$storage_location, "fallback")
  testthat::expect_equal(readLines(destination), "pre-existing wrong bytes")

  unlink(destination)
  testthat::expect_equal(ppsv_reconcile_storage(ctx), 1L)
  reconciled <- ppsv_db_query(
    ctx,
    "SELECT storage_location,absolute_path,sha256 FROM request_files WHERE id=?",
    list(file_row$id)
  )
  testthat::expect_equal(reconciled$storage_location, "pool")
  testthat::expect_equal(reconciled$absolute_path, normalizePath(destination, winslash = "/"))
  testthat::expect_true(file.exists(fallback_source))
  testthat::expect_equal(
    digest::digest(file = destination, algo = "sha256", serialize = FALSE),
    reconciled$sha256
  )
})

testthat::test_that("stored files and directories use private modes", {
  testthat::skip_on_os("windows")
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "mode.txt", "private"),
    user = user,
    ctx = ctx
  )
  stored <- ppsv_db_query(
    ctx,
    "SELECT absolute_path FROM request_files WHERE request_id=?",
    list(request$id)
  )$absolute_path[[1L]]
  testthat::expect_equal(as.character(file.info(stored)$mode), "660")
  testthat::expect_equal(as.character(file.info(dirname(stored))$mode), "770")
  testthat::expect_equal(as.character(file.info(dirname(dirname(stored)))$mode), "770")
  testthat::expect_equal(as.character(file.info(ctx$config$db_file)$mode), "660")

  # file.info omits special permission bits. On Linux CI, assert setgid using
  # stat as well; macOS development sandboxes commonly strip that bit.
  if (identical(Sys.info()[["sysname"]], "Linux") && nzchar(Sys.which("stat"))) {
    directory_mode <- system2("stat", c("-c", "%a", dirname(stored)), stdout = TRUE)
    testthat::expect_equal(directory_mode, "2770")
  }
})
