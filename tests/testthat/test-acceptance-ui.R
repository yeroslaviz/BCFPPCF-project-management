testthat::test_that("staff review and queue acceptance with a PDF while requesters cannot", {
  testthat::skip_if_not_installed("shiny")
  root <- tempfile("ppsv-acceptance-ui-")
  dir.create(root)
  dir.create(file.path(root, "pool"))
  catalogue <- file.path(root, "budget_holders.csv")
  utils::write.csv(data.frame(
    name = "Test research", surname = "group", cost_center = "BIO-123"
  ), catalogue, row.names = FALSE)
  withr::local_envvar(c(
    AUTH_MODE = "test", PPSV_TEST_USER = "yeroslaviz",
    PPSV_TEST_NAME = "Assa Yeroslaviz", PPSV_TEST_EMAIL = "yeroslaviz@biochem.mpg.de",
    PPSV_BUDGET_HOLDERS_FILE = catalogue,
    PPSV_DB_FILE = file.path(root, "db.sqlite"),
    PPSV_POOL_ROOT = file.path(root, "pool"), PPSV_ALLOW_LOCAL_POOL = "true",
    PPSV_FALLBACK_ROOT = file.path(root, "fallback"), PPSV_TICKET_MODE = "disabled"
  ))
  withr::local_dir(file.path(PPSV_TEST_REPO, "ppsvf-app"))
  app_env <- new.env(parent = globalenv())
  sys.source("app.R", app_env)
  ctx <- app_env$app_context
  ctx$config$ticket_mode <- "service_reply_to"
  ctx$config$service_identity_authorized <- TRUE
  ctx$config$ticket_e2e_test_ack <- TRUE
  ctx$config$smtp_host <- "smtp.example.org"
  app_env$app_context <- ctx
  owner <- ppsv_test_user(ctx, "alice", email = "alice@ldap.example.org")
  request <- create_request(ppsv_valid_service_payload(), user = owner, ctx = ctx)
  captured_modal <- NULL
  app_env$showModal <- function(ui, ...) captured_modal <<- as.character(ui)

  shiny::testServer(app_env$server, {
    selected_request_id(request$request_code)
    refresh_detail()
    session$flushReact()
    controls <- output$staff_controls$html
    testthat::expect_match(controls, "Accept and send confirmation", fixed = TRUE)
    testthat::expect_match(controls, "Status updates alone do not send email.", fixed = TRUE)
    session$setInputs(review_acceptance = 1)
    session$flushReact()
    testthat::expect_match(captured_modal, "alice@ldap.example.org", fixed = TRUE)
    testthat::expect_match(captured_modal, "verified LDAP email", fixed = TRUE)
    testthat::expect_match(captured_modal, "result files", fixed = TRUE)
    testthat::expect_match(captured_modal, "A PDF report containing your project details is attached.", fixed = TRUE)
    testthat::expect_equal(acceptance_review()$recipient, "alice@ldap.example.org")

    session$setInputs(acceptance_message = "Dear Alice,\n\nWe have accepted your project.", confirm_acceptance = 1)
    session$flushReact()
    saved <- selected_request()
    testthat::expect_equal(saved$current_status, "Accepted")
    testthat::expect_equal(sum(saved$mail$message_kind == "acceptance"), 1L)
    testthat::expect_true(any(saved$files$original_name == paste0(request$request_code, "-acceptance.pdf")))
    acceptance <- ppsv_db_query(ctx, "SELECT recipient,body FROM mail_outbox WHERE message_kind='acceptance'")
    testthat::expect_equal(acceptance$recipient, "alice@ldap.example.org")
    testthat::expect_equal(acceptance$body, "Dear Alice,\n\nWe have accepted your project.")
    testthat::expect_null(acceptance_review())
    testthat::expect_false(grepl("review_acceptance", output$staff_controls$html, fixed = TRUE))
    testthat::expect_match(output$staff_controls$html, "already been queued", fixed = TRUE)
  })

  Sys.setenv(PPSV_TEST_USER = "alice", PPSV_TEST_NAME = "Alice", PPSV_TEST_EMAIL = "alice@ldap.example.org")
  shiny::testServer(app_env$server, {
    selected_request_id(request$request_code)
    refresh_detail()
    session$flushReact()
    testthat::expect_true(is.null(output$staff_controls) || !nzchar(output$staff_controls$html %||% ""))
  })
})

testthat::test_that("acceptance review keeps the reviewed recipient if LDAP changes", {
  testthat::skip_if_not_installed("shiny")
  root <- tempfile("ppsv-acceptance-review-ui-")
  dir.create(root)
  dir.create(file.path(root, "pool"))
  withr::local_envvar(c(
    AUTH_MODE = "test", PPSV_TEST_USER = "yeroslaviz",
    PPSV_TEST_NAME = "Assa Yeroslaviz", PPSV_TEST_EMAIL = "yeroslaviz@biochem.mpg.de",
    PPSV_DB_FILE = file.path(root, "db.sqlite"),
    PPSV_POOL_ROOT = file.path(root, "pool"), PPSV_ALLOW_LOCAL_POOL = "true",
    PPSV_FALLBACK_ROOT = file.path(root, "fallback"), PPSV_TICKET_MODE = "disabled"
  ))
  withr::local_dir(file.path(PPSV_TEST_REPO, "ppsvf-app"))
  app_env <- new.env(parent = globalenv())
  sys.source("app.R", app_env)
  ctx <- app_env$app_context
  ctx$config$ticket_mode <- "service_reply_to"
  ctx$config$service_identity_authorized <- TRUE
  ctx$config$ticket_e2e_test_ack <- TRUE
  ctx$config$smtp_host <- "smtp.example.org"
  app_env$app_context <- ctx
  owner <- ppsv_test_user(ctx, "alice", email = "alice@ldap.example.org")
  request <- create_request(ppsv_valid_inquiry_payload(), user = owner, ctx = ctx)
  shiny::testServer(app_env$server, {
    selected_request_id(request$request_code)
    refresh_detail()
    session$setInputs(review_acceptance = 1)
    session$flushReact()
    ppsv_test_user(ctx, "alice", email = "new-alice@ldap.example.org")
    session$setInputs(acceptance_message = "Accepted.", confirm_acceptance = 1)
    session$flushReact()
    testthat::expect_match(flash_error(), "email changed", fixed = TRUE)
    testthat::expect_equal(selected_request()$current_status, "Submitted")
    testthat::expect_equal(sum(selected_request()$mail$message_kind == "acceptance"), 0L)
    testthat::expect_equal(acceptance_review()$recipient, "alice@ldap.example.org")
  })
})
