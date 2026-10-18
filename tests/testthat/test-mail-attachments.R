ppsv_test_queue_attachment <- function(ctx, request, file_id) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  ppsv_db_transaction(con, {
    message <- ppsv_mail_message(
      ctx$config$mail_from, request$contact_email,
      paste(request$request_code, "accepted"), "Your project has been accepted.",
      kind = "acceptance"
    )
    ppsv_outbox_insert(
      con, request$id, "acceptance", message,
      dedupe_key = paste0(request$request_code, ":acceptance:test")
    )
    id <- DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id[[1L]]
    DBI::dbExecute(
      con, "INSERT INTO mail_attachments(outbox_id,file_id) VALUES (?,?)",
      params = list(id, file_id)
    )
    id
  }, immediate = TRUE)
}

testthat::test_that("mailR receives the validated PDF and its public filename", {
  captured <- NULL
  settings <- list(smtp = list(host.name = "smtp.example.org", user.name = "", passwd = ""))
  mail <- ppsv_mail_message(
    "ppsv-service@biochem.mpg.de", "alice@example.org", "PPSV000001 accepted",
    "Your project has been accepted.", reply_to = "ppsv-request@biochem.mpg.de",
    kind = "acceptance", attachments = "/pool/PPSV000001/results/unique-name.pdf",
    attachment_names = "PPSV000001-project-report.pdf"
  )
  injected_transport <- function(...) captured <<- list(...)
  testthat::expect_true(ppsv_mailr_send(mail, settings, send_mail = injected_transport)$success)
  testthat::expect_equal(captured$attach.files, mail$attachments)
  testthat::expect_equal(captured$file.names, "PPSV000001-project-report.pdf")
  testthat::expect_equal(captured$replyTo, "ppsv-request@biochem.mpg.de")
  testthat::expect_false(captured$authenticate)
  testthat::expect_true(captured$send)
  testthat::expect_false(captured$html)

  mail$attachments <- character()
  mail$attachment_names <- character()
  ppsv_mailr_send(mail, settings, send_mail = injected_transport)
  testthat::expect_false("attach.files" %in% names(captured))
  testthat::expect_false("file.names" %in% names(captured))
})

testthat::test_that("editable mail text cannot cause mailR to read a server file", {
  path <- tempfile("ppsv-private-")
  writeLines("Private server data", path)
  on.exit(unlink(path), add = TRUE)
  mail <- ppsv_mail_message("service@example.org", "alice@example.org", "Accepted", path)
  called <- FALSE
  testthat::expect_error(
    ppsv_mailr_send(mail, send_mail = function(...) called <<- TRUE),
    "message text rather than a server file path"
  )
  testthat::expect_false(called)
})

testthat::test_that("staff acceptance does not depend on automatic acknowledgement settings", {
  ctx <- ppsv_test_context("service_reply_to", direct_ack = FALSE)
  user <- ppsv_test_user(ctx, "alice")
  request <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  row <- as.list(ppsv_db_query(ctx, "SELECT * FROM mail_outbox LIMIT 1")[1L, ])
  row$message_kind <- "acceptance"
  row$dedupe_key <- paste0(request$request_code, ":acceptance")
  row$recipient <- user$email
  row$attachments <- "/pool/report.pdf"
  row$attachment_names <- "project-report.pdf"
  captured <- NULL
  transport <- function(message, settings) {
    captured <<- message
    list(success = TRUE)
  }
  testthat::expect_true(ppsv_default_mail_sender(row, ctx$config, send_fun = transport)$success)
  testthat::expect_equal(captured$kind, "acceptance")
  testthat::expect_equal(captured$attachments, row$attachments)
  testthat::expect_equal(captured$attachment_names, row$attachment_names)

  acknowledgement <- row
  acknowledgement$message_kind <- "acknowledgement"
  testthat::expect_error(
    ppsv_default_mail_sender(acknowledgement, ctx$config, send_fun = transport),
    "Direct acknowledgements are currently disabled"
  )
  disabled <- ctx$config
  disabled$ticket_mode <- "disabled"
  testthat::expect_error(ppsv_default_mail_sender(row, disabled, send_fun = transport), "currently disabled")
  unauthorized <- ctx$config
  unauthorized$service_identity_authorized <- FALSE
  testthat::expect_error(
    ppsv_default_mail_sender(row, unauthorized, send_fun = transport),
    "PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK"
  )
  changed_sender <- ctx$config
  changed_sender$mail_from <- "changed@example.org"
  testthat::expect_error(
    ppsv_default_mail_sender(row, changed_sender, send_fun = transport),
    "currently authorized PPSV sender"
  )
})

testthat::test_that("missing or altered attachments block delivery and can be restored for retry", {
  for (failure in c("missing", "tampered")) {
    ctx <- ppsv_test_context()
    user <- ppsv_test_user(ctx, "alice")
    admin <- ppsv_test_user(ctx, "yeroslaviz")
    request <- create_request(
      ppsv_valid_inquiry_payload(), user = user, ctx = ctx,
      uploads = ppsv_test_upload(attr(ctx, "test_root"), "project-report.pdf", "%PDF report snapshot")
    )
    file <- ppsv_db_query(ctx, "SELECT * FROM request_files LIMIT 1")
    outbox_id <- ppsv_test_queue_attachment(ctx, request, file$id[[1L]])
    original <- readBin(file$absolute_path, "raw", n = file.info(file$absolute_path)$size)
    if (failure == "missing") unlink(file$absolute_path) else writeLines("tampered", file$absolute_path)
    delivered <- list()
    sender <- function(message, config) {
      delivered[[length(delivered) + 1L]] <<- message
      list(success = TRUE)
    }
    start <- Sys.time() + 60
    result <- ppsv_process_mail_outbox(send_fun = sender, now = start, ctx = ctx)
    testthat::expect_equal(result$failed, 1L)
    testthat::expect_length(delivered, 0L)
    failed <- ppsv_db_query(ctx, "SELECT * FROM mail_outbox WHERE id=?", list(outbox_id))
    testthat::expect_equal(failed$status, "failed")
    testthat::expect_match(failed$last_error, if (failure == "missing") "missing" else "checksum")
    testthat::expect_equal(
      ppsv_db_query(ctx, "SELECT succeeded FROM mail_attempts WHERE outbox_id=?", list(outbox_id))$succeeded,
      0L
    )

    writeBin(original, file$absolute_path)
    retry_mail(outbox_id, admin, ctx)
    result <- ppsv_process_mail_outbox(send_fun = sender, now = start + 60, ctx = ctx)
    testthat::expect_equal(result$sent, 1L)
    testthat::expect_length(delivered, 1L)
    testthat::expect_equal(delivered[[1L]]$attachments, file$absolute_path)
    testthat::expect_equal(delivered[[1L]]$attachment_names, "project-report.pdf")
  }
})

testthat::test_that("attachments resolve their current pool path after fallback reconciliation", {
  ctx <- ppsv_test_context(pool = FALSE)
  user <- ppsv_test_user(ctx, "alice")
  request <- create_request(
    ppsv_valid_inquiry_payload(), user = user, ctx = ctx,
    uploads = ppsv_test_upload(attr(ctx, "test_root"), "project-report.pdf", "%PDF snapshot")
  )
  file <- ppsv_db_query(ctx, "SELECT * FROM request_files LIMIT 1")
  testthat::expect_equal(file$storage_location, "fallback")
  ppsv_test_queue_attachment(ctx, request, file$id[[1L]])
  dir.create(ctx$config$pool_root)
  testthat::expect_equal(ppsv_reconcile_storage(ctx), 1L)
  reconciled <- ppsv_db_query(ctx, "SELECT * FROM request_files LIMIT 1")
  testthat::expect_equal(reconciled$storage_location, "pool")
  testthat::expect_false(identical(reconciled$absolute_path, file$absolute_path))
  delivered <- NULL
  result <- ppsv_process_mail_outbox(
    send_fun = function(message, config) {
      delivered <<- message
      list(success = TRUE)
    }, now = Sys.time() + 60, ctx = ctx
  )
  testthat::expect_equal(result$sent, 1L)
  testthat::expect_equal(delivered$attachments, reconciled$absolute_path)
  testthat::expect_equal(delivered$attachment_names, "project-report.pdf")
})

testthat::test_that("an acceptance missing its attachment link cannot be sent without the report", {
  ctx <- ppsv_test_context("service_reply_to")
  owner <- ppsv_test_user(ctx, "alice")
  staff <- ppsv_test_user(ctx, "grzejszc")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  accept_request(request$request_code, user = staff, ctx = ctx)
  con <- ppsv_db_connect(ctx$config)
  DBI::dbExecute(con, "DELETE FROM mail_attachments")
  DBI::dbDisconnect(con)
  accepted_sent <- FALSE
  result <- ppsv_process_mail_outbox(send_fun = function(message, config) {
    if (message$message_kind == "acceptance") accepted_sent <<- TRUE
    list(success = TRUE)
  }, now = Sys.time() + 60, ctx = ctx)
  testthat::expect_equal(result$failed, 1L)
  testthat::expect_false(accepted_sent)
  mail <- ppsv_db_query(ctx, "SELECT last_error FROM mail_outbox WHERE message_kind='acceptance'")
  testthat::expect_match(mail$last_error, "no saved PDF attachment")
})

testthat::test_that("a file from a different request cannot be attached", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  first <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  create_request(
    ppsv_valid_inquiry_payload(), user = user, ctx = ctx,
    uploads = ppsv_test_upload(attr(ctx, "test_root"), "other-project.pdf", "%PDF private")
  )
  file <- ppsv_db_query(ctx, "SELECT * FROM request_files LIMIT 1")
  id <- ppsv_test_queue_attachment(ctx, first, file$id[[1L]])
  result <- ppsv_process_mail_outbox(
    send_fun = function(...) stop("Transport must not be called"),
    now = Sys.time() + 60, ctx = ctx
  )
  testthat::expect_equal(result$failed, 1L)
  failed <- ppsv_db_query(ctx, "SELECT last_error FROM mail_outbox WHERE id=?", list(id))
  testthat::expect_match(failed$last_error, "does not belong to this request")
})

testthat::test_that("v4 migration preserves old deliveries, attempts, foreign keys, and counters", {
  ctx <- ppsv_test_context()
  cfg <- ctx$config
  cfg$db_file <- file.path(attr(ctx, "test_root"), "prior-v3.sqlite")
  con <- ppsv_db_connect(cfg)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  ppsv_db_transaction(con, {
    ppsv_apply_migration_v1(con)
    ppsv_apply_migration_v2(con)
    ppsv_apply_migration_v3(con)
    ppsv_seed_reference_data(con)
    DBI::dbExecute(
      con,
      paste(
        "INSERT INTO requests(id,request_code,request_kind,owner_username,contact_name,contact_email,",
        "research_group,phone,current_status,storage_state,created_at,updated_at)",
        "VALUES (1,'PPSV000123','inquiry','yeroslaviz','Legacy User','legacy@example.org',",
        "'Legacy Group','123','Submitted','none',?,?)"
      ), params = list(ppsv_now(), ppsv_now())
    )
    ppsv_outbox_insert(
      con, 1L, "ticket",
      ppsv_mail_message(cfg$mail_from, cfg$ticket_to, "Original subject", "Original body"),
      dedupe_key = "PPSV000123:ticket:service"
    )
    DBI::dbExecute(
      con,
      "INSERT INTO mail_attempts(outbox_id,attempt_number,attempted_at,succeeded,error_message) VALUES (1,1,?,0,'Original failure')",
      params = list(ppsv_now())
    )
    DBI::dbExecute(con, "UPDATE sqlite_sequence SET seq=100 WHERE name='mail_outbox'")
    DBI::dbExecute(con, "UPDATE sqlite_sequence SET seq=200 WHERE name='mail_attempts'")
  }, immediate = TRUE)
  old_mail <- DBI::dbGetQuery(con, "SELECT * FROM mail_outbox")
  old_attempt <- DBI::dbGetQuery(con, "SELECT * FROM mail_attempts")
  testthat::expect_silent(ppsv_initialize_database(cfg))
  testthat::expect_equal(DBI::dbGetQuery(con, "SELECT * FROM mail_outbox"), old_mail)
  testthat::expect_equal(DBI::dbGetQuery(con, "SELECT * FROM mail_attempts"), old_attempt)
  testthat::expect_equal(nrow(DBI::dbGetQuery(con, "PRAGMA foreign_key_check")), 0L)
  testthat::expect_true("mail_attachments" %in% DBI::dbListTables(con))
  ppsv_outbox_insert(
    con, 1L, "acceptance",
    ppsv_mail_message(cfg$mail_from, "legacy@example.org", "Accepted", "Project accepted."),
    dedupe_key = "PPSV000123:acceptance"
  )
  testthat::expect_equal(DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id, 101L)
  DBI::dbExecute(
    con,
    "INSERT INTO mail_attempts(outbox_id,attempt_number,attempted_at,succeeded) VALUES (101,1,?,1)",
    params = list(ppsv_now())
  )
  testthat::expect_equal(DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id, 201L)
  testthat::expect_error(
    DBI::dbExecute(con, "INSERT INTO mail_attachments(outbox_id,file_id) VALUES (101,999)"),
    "FOREIGN KEY"
  )
})
