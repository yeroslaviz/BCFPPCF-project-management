testthat::test_that("request form maps the PI and requires an explicit choice of multiple cost centres", {
  root <- tempfile("ppsv-billing-ui-")
  dir.create(root)
  dir.create(file.path(root, "pool"))
  catalogue <- file.path(root, "budgets.csv")
  utils::write.csv(data.frame(
    name = c("Alex", "Alex", "Jane"),
    surname = c("Multi", "Multi", "Single"),
    cost_center = c("M1", "M2", "S1")
  ), catalogue, row.names = FALSE)
  withr::local_envvar(c(
    AUTH_MODE = "test", PPSV_TEST_USER = "alice", PPSV_TEST_NAME = "Alice",
    PPSV_TEST_EMAIL = "alice@example.org", PPSV_TEST_GROUP = "Research (Multi)",
    PPSV_BUDGET_HOLDERS_FILE = catalogue,
    PPSV_DB_FILE = file.path(root, "db.sqlite"),
    PPSV_POOL_ROOT = file.path(root, "pool"), PPSV_ALLOW_LOCAL_POOL = "1",
    PPSV_FALLBACK_ROOT = file.path(root, "fallback"), PPSV_TICKET_MODE = "disabled"
  ))
  withr::local_dir(file.path(PPSV_TEST_REPO, "ppsvf-app"))
  app_env <- new.env(parent = globalenv())
  sys.source("app.R", app_env)
  shiny::testServer(app_env$server, {
    session$setInputs(service_choice = "protein-purification")
    session$flushReact()
    form <- output$new_request_branch$html
    testthat::expect_match(form, 'value="Alex Multi"', fixed = TRUE)
    testthat::expect_false(grepl("This value was not verified by LDAP", form, fixed = TRUE))
    choices <- output$new_billing_control$html
    testthat::expect_match(choices, '<option value="" selected>', fixed = TRUE)
    testthat::expect_match(choices, 'value="M1"', fixed = TRUE)
    testthat::expect_match(choices, 'value="M2"', fixed = TRUE)
    testthat::expect_false(grepl('value="S1"', choices, fixed = TRUE))

    values <- ppsv_valid_service_payload(billing_code = "", research_group = "Forged group")
    values <- values[setdiff(names(values), c("request_kind", "service_module_slug"))]
    names(values) <- paste0("new_", names(values))
    do.call(session$setInputs, values)
    session$setInputs(submit_request = 1)
    session$flushReact()
    testthat::expect_match(flash_error(), "multiple cost centres", fixed = TRUE)
    testthat::expect_equal(nrow(list_requests(identity(), ctx = app_env$app_context)), 0L)
    session$setInputs(new_billing_code = "S1", submit_request = 2)
    session$flushReact()
    testthat::expect_match(flash_error(), "listed for your PI", fixed = TRUE)
    session$setInputs(new_billing_code = "M2", submit_request = 3)
    session$flushReact()
    saved <- selected_request()
    testthat::expect_equal(saved$billing_code, "M2")
    testthat::expect_equal(saved$research_group, "Alex Multi")
    testthat::expect_equal(saved$contact_name, "Alice")
    testthat::expect_equal(saved$contact_email, "alice@example.org")
    testthat::expect_equal(saved$contact_email_verified, 1L)

    # Reopening the form starts the multi-code choice empty again.
    session$setInputs(service_choice = "__inquiry__")
    session$flushReact()
    session$setInputs(service_choice = "protein-purification")
    session$flushReact()
    testthat::expect_match(output$new_billing_control$html, '<option value="" selected>', fixed = TRUE)

    single <- as.character(app_env$billing_control_ui("new_", "Single"))
    testthat::expect_match(single, 'value="S1"', fixed = TRUE)
    testthat::expect_match(single, 'readonly="readonly"', fixed = TRUE)
    manual <- as.character(app_env$readonly_identity_control("test_name", "Name", "", verified = FALSE))
    testthat::expect_false(grepl("not verified", manual, fixed = TRUE))
  })
})

testthat::test_that("staff edits keep the requester's billing scope and saved choice", {
  ctx <- ppsv_test_context()
  utils::write.csv(data.frame(
    name = c("Owner", "Owner", "Staff"), surname = c("Group", "Group", "Group"),
    cost_center = c("OWN-1", "OWN-2", "STAFF-1")
  ), ctx$config$budget_holders_file, row.names = FALSE)
  owner <- current_user("alice", list(
    HTTP_X_REMOTE_NAME = "Alice", HTTP_X_REMOTE_EMAIL = "alice@example.org",
    HTTP_X_REMOTE_GROUP = "Owner Group"
  ), ctx)
  staff <- current_user("grzejszc", list(
    HTTP_X_REMOTE_NAME = "Staff", HTTP_X_REMOTE_EMAIL = "staff@example.org",
    HTTP_X_REMOTE_GROUP = "Staff Group"
  ), ctx)
  request <- create_request(ppsv_valid_service_payload(billing_code = "OWN-2"), user = owner, ctx = ctx)
  edited <- update_request(request$request_code, list(protein_name = "Reviewed"), user = staff, ctx = ctx)
  testthat::expect_equal(edited$research_group, "Owner Group")
  testthat::expect_equal(edited$billing_code, "OWN-2")
  testthat::expect_error(
    update_request(request$request_code, list(billing_code = "STAFF-1"), user = staff, ctx = ctx),
    "listed for your PI"
  )
})
