testthat::test_that("the shared PPSV sequence is collision-free under concurrent allocation", {
  testthat::skip_on_os("windows")
  ctx <- ppsv_test_context()

  allocations <- parallel::mclapply(
    seq_len(16L),
    function(index) ppsv_allocate_request_code(ctx),
    mc.cores = 2L,
    mc.preschedule = FALSE
  )
  testthat::expect_false(any(vapply(allocations, inherits, logical(1L), what = "try-error")))
  codes <- unlist(allocations, use.names = FALSE)

  testthat::expect_length(codes, 16L)
  testthat::expect_equal(length(unique(codes)), 16L)
  testthat::expect_setequal(codes, sprintf("PPSV%06d", seq_len(16L)))
  testthat::expect_equal(
    ppsv_db_query(ctx, "SELECT next_value FROM sequence_counters WHERE name='request'")$next_value,
    17L
  )

  # Both request kinds consume the same counter after the concurrent batch.
  user <- ppsv_test_user(ctx, "alice")
  service <- create_request(ppsv_valid_service_payload(), user = user, ctx = ctx)
  inquiry <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  testthat::expect_equal(c(service$request_code, inquiry$request_code), c("PPSV000017", "PPSV000018"))
})

testthat::test_that("a failed transaction does not consume a PPSV identifier", {
  ctx <- ppsv_test_context()
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  testthat::expect_error(
    ppsv_db_transaction(
      con,
      {
        reserved <- ppsv_allocate_request_code_in_transaction(con)
        testthat::expect_equal(reserved, "PPSV000001")
        stop("force rollback")
      },
      immediate = TRUE
    ),
    "force rollback"
  )
  testthat::expect_equal(ppsv_allocate_request_code(ctx), "PPSV000001")
})

testthat::test_that("request, sequence, file, history, and outbox roll back together", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  con <- ppsv_db_connect(ctx$config)
  DBI::dbExecute(
    con,
    paste(
      "CREATE TRIGGER test_fail_outbox BEFORE INSERT ON mail_outbox",
      "BEGIN SELECT RAISE(ABORT,'forced outbox failure'); END"
    )
  )
  DBI::dbDisconnect(con)

  testthat::expect_error(
    create_request(
      ppsv_valid_inquiry_payload(),
      uploads = ppsv_test_upload(root, "transaction.txt", "must roll back"),
      user = owner,
      ctx = ctx
    ),
    "forced outbox failure"
  )
  for (table in c(
    "requests", "inquiries", "protein_submissions", "request_files",
    "status_history", "mail_outbox", "mail_attempts"
  )) {
    testthat::expect_equal(
      ppsv_db_query(ctx, paste("SELECT count(*) AS n FROM", table))$n,
      0L,
      info = table
    )
  }
  testthat::expect_equal(
    ppsv_db_query(ctx, "SELECT next_value FROM sequence_counters WHERE name='request'")$next_value,
    1L
  )
  pool_entries <- list.files(ctx$config$pool_root, recursive = TRUE, full.names = TRUE)
  pool_files <- pool_entries[file.exists(pool_entries) & !file.info(pool_entries)$isdir]
  testthat::expect_length(pool_files, 0L)

  con <- ppsv_db_connect(ctx$config)
  DBI::dbExecute(con, "DROP TRIGGER test_fail_outbox")
  DBI::dbDisconnect(con)
  created <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  testthat::expect_equal(created$request_code, "PPSV000001")
})
