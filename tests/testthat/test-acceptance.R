testthat::test_that("staff acceptance saves a PDF and queues it for the verified requester", {
  for (kind in c("service", "inquiry")) {
    ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
    owner <- ppsv_test_user(ctx, "alice", "alice@example.org", "Alice")
    staff <- ppsv_test_user(ctx, "grzejszc")
    payload <- if (kind == "service") ppsv_valid_service_payload() else ppsv_valid_inquiry_payload()
    request <- create_request(payload, user = owner, ctx = ctx)
    testthat::expect_equal(request$acceptance_recipient, "alice@example.org")
    testthat::expect_false(any(request$mail$message_kind == "acceptance"))

    accepted <- accept_request(request$request_code, user = staff, recipient = "alice@example.org", ctx = ctx)
    testthat::expect_equal(accepted$current_status, "Accepted")
    testthat::expect_equal(tail(accepted$status_history$changed_by, 1L), staff$username)
    mail <- ppsv_db_query(ctx, "SELECT * FROM mail_outbox WHERE message_kind='acceptance'")
    testthat::expect_equal(mail$recipient, "alice@example.org")
    testthat::expect_equal(mail$from_address, ctx$config$mail_from)
    testthat::expect_equal(mail$reply_to, ctx$config$ticket_to)
    testthat::expect_equal(mail$status, "pending")
    testthat::expect_match(mail$subject, "PPSV project accepted", fixed = TRUE)
    testthat::expect_match(mail$body, "A PDF report containing your project details is attached.", fixed = TRUE)
    file <- ppsv_db_query(ctx, "SELECT * FROM request_files WHERE mime_type='application/pdf'")
    testthat::expect_equal(file$category, "results")
    testthat::expect_equal(file$original_name, paste0(request$request_code, "-acceptance.pdf"))
    testthat::expect_equal(file$storage_location, "pool")
    testthat::expect_equal(accepted$storage_state, "pool")
    testthat::expect_true(ppsv_path_is_within(file$absolute_path, file.path(ctx$config$pool_root, request$request_code, "results")))
    pdf <- download_file(request$request_code, file$id, owner, ctx)
    testthat::expect_equal(rawToChar(readBin(pdf, "raw", n = 4L)), "%PDF")
    testthat::expect_equal(digest::digest(file = pdf, algo = "sha256", serialize = FALSE), file$sha256)
    attachment <- ppsv_db_query(ctx, "SELECT * FROM mail_attachments")
    testthat::expect_equal(attachment$outbox_id, mail$id)
    testthat::expect_equal(attachment$file_id, file$id)
    testthat::expect_length(accepted$files$id, 1L)

    captured <- NULL
    sender <- function(message, config) {
      if (message$message_kind == "acceptance") captured <<- message
      list(success = TRUE)
    }
    result <- ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)
    testthat::expect_equal(result$failed, 0L)
    testthat::expect_equal(captured$attachments, pdf)
    testthat::expect_equal(captured$attachment_names, file$original_name)
  }
})

testthat::test_that("acceptance requires staff, an eligible project, and reviewed verified LDAP recipient", {
  ctx <- ppsv_test_context("service_reply_to")
  owner <- ppsv_test_user(ctx, "alice")
  staff <- ppsv_test_user(ctx, "grzejszc")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  testthat::expect_error(accept_request(request$request_code, user = owner, ctx = ctx), class = "ppsv_authorization_error")
  testthat::expect_error(
    accept_request(request$request_code, user = staff, recipient = "forged@example.org", ctx = ctx),
    "Refresh and review the recipient"
  )
  testthat::expect_error(accept_request(request$request_code, user = staff, message = " ", ctx = ctx), "must not be empty")
  testthat::expect_error(accept_request(request$request_code, user = staff, message = ctx$config$db_file, ctx = ctx), "message text rather than a server file path")
  for (status in c("In progress", "Completed", "Closed")) {
    update_status(request$request_code, status, user = staff, ctx = ctx)
    testthat::expect_error(accept_request(request$request_code, user = staff, ctx = ctx), class = "ppsv_authorization_error")
  }
  update_status(request$request_code, "Under review", user = staff, ctx = ctx)
  ppsv_test_user(ctx, "alice", email_present = FALSE)
  testthat::expect_equal(get_request(request$request_code, staff, ctx)$acceptance_recipient, "")
  testthat::expect_error(accept_request(request$request_code, user = staff, ctx = ctx), "no verified LDAP email")
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM mail_attachments")), 0L)
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM request_files")), 0L)
})

testthat::test_that("manual acceptance is deduplicated and retains the same PDF across retries and edits", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  owner <- ppsv_test_user(ctx, "alice")
  staff <- ppsv_test_user(ctx, "grzejszc")
  request <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)
  update_status(request$request_code, "Accepted", user = staff, ctx = ctx)
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM mail_outbox WHERE message_kind='acceptance'")), 0L)
  accept_request(request$request_code, message = "Dear Alice,\nWe can proceed. Your report is attached.", user = staff, ctx = ctx)
  history <- get_request(request$request_code, staff, ctx)$status_history
  testthat::expect_match(tail(history$note, 1L), "confirmation with PDF queued", fixed = TRUE)
  original <- ppsv_db_query(ctx, "SELECT * FROM request_files")
  testthat::expect_error(accept_request(request$request_code, user = staff, ctx = ctx), "already exists")
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM request_files")), 1L)
  update_request(request$request_code, list(protein_name = "Changed after acceptance"), user = staff, ctx = ctx)
  seen <- character()
  sender <- function(message, config) {
    if (message$message_kind == "acceptance") {
      seen <<- c(seen, digest::digest(file = message$attachments, algo = "sha256", serialize = FALSE))
      if (length(seen) == 1L) stop("temporary failure")
    }
    list(success = TRUE)
  }
  start <- Sys.time() + 60
  ppsv_process_mail_outbox(send_fun = sender, now = start, ctx = ctx)
  state <- get_request(request$request_code, owner, ctx)$ticket_state
  testthat::expect_equal(state, "sent")
  ppsv_process_mail_outbox(send_fun = sender, now = start + 301, ctx = ctx)
  testthat::expect_equal(seen, rep(original$sha256, 2L))
  testthat::expect_equal(get_request(request$request_code, owner, ctx)$ticket_state, state)
  testthat::expect_equal(ppsv_db_query(ctx, "SELECT status FROM mail_outbox WHERE message_kind='acceptance'")$status, "sent")
})

testthat::test_that("acceptance PDF uses fallback and remains attachable after pool reconciliation", {
  ctx <- ppsv_test_context("service_reply_to", pool = FALSE)
  owner <- ppsv_test_user(ctx, "alice")
  staff <- ppsv_test_user(ctx, "grzejszc")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  accepted <- accept_request(request$request_code, user = staff, ctx = ctx)
  testthat::expect_equal(accepted$storage_state, "fallback")
  file <- ppsv_db_query(ctx, "SELECT * FROM request_files")
  testthat::expect_equal(file$storage_location, "fallback")
  dir.create(ctx$config$pool_root)
  testthat::expect_equal(ppsv_reconcile_storage(ctx), 1L)
  path <- download_file(request$request_code, file$id, owner, ctx)
  testthat::expect_true(ppsv_path_is_within(path, ctx$config$pool_root))
  seen <- NULL
  sender <- function(message, config) {
    if (message$message_kind == "acceptance") seen <<- message$attachments
    list(success = TRUE)
  }
  testthat::expect_equal(ppsv_process_mail_outbox(send_fun = sender, ctx = ctx)$failed, 0L)
  testthat::expect_equal(seen, path)
})

testthat::test_that("failed acceptance rolls back status, PDF record, outbox and staged PDF", {
  ctx <- ppsv_test_context("service_reply_to")
  owner <- ppsv_test_user(ctx, "alice")
  staff <- ppsv_test_user(ctx, "grzejszc")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  con <- ppsv_db_connect(ctx$config)
  DBI::dbExecute(con, paste(
    "CREATE TRIGGER fail_acceptance BEFORE INSERT ON mail_outbox WHEN NEW.message_kind='acceptance'",
    "BEGIN SELECT RAISE(ABORT,'forced acceptance failure'); END"
  ))
  DBI::dbDisconnect(con)
  testthat::expect_error(accept_request(request$request_code, user = staff, ctx = ctx), "forced acceptance failure")
  after <- get_request(request$request_code, staff, ctx)
  testthat::expect_equal(after$current_status, "Submitted")
  testthat::expect_equal(nrow(after$status_history), 1L)
  testthat::expect_equal(nrow(after$files), 0L)
  testthat::expect_equal(nrow(after$mail), 1L)
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM mail_attachments")), 0L)
  testthat::expect_length(list.files(ctx$config$pool_root, recursive = TRUE), 0L)
})

testthat::test_that("mail configuration and storage failures prevent partial acceptance", {
  for (failure in c("disabled", "unapproved", "quota", "storage")) {
    ctx <- ppsv_test_context(if (failure == "disabled") "disabled" else "service_reply_to", pool = failure != "storage")
    owner <- ppsv_test_user(ctx, "alice")
    staff <- ppsv_test_user(ctx, "grzejszc")
    request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
    if (failure == "unapproved") ctx$config$service_identity_authorized <- FALSE
    if (failure == "quota") ctx$config$max_upload_mb <- 0.001
    if (failure == "storage") file.create(ctx$config$fallback_root)
    testthat::expect_error(accept_request(request$request_code, user = staff, ctx = ctx))
    testthat::expect_equal(get_request(request$request_code, staff, ctx)$current_status, "Submitted")
    testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM mail_outbox WHERE message_kind='acceptance'")), 0L)
    testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM request_files")), 0L)
  }
})
