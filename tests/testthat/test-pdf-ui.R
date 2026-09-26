testthat::test_that("authorized PDF summaries contain service data, history, and file manifest", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  other <- ppsv_test_user(ctx, "mallory")
  admin <- ppsv_test_user(ctx, "yeroslaviz")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_service_payload(),
    uploads = ppsv_test_upload(root, "construct α.txt", "sequence"),
    user = owner,
    ctx = ctx
  )
  update_status(request$request_code, "Under review", "Reviewed\ncarefully", user = admin, ctx = ctx)
  pdf_file <- file.path(root, "summary.pdf")
  testthat::expect_error(
    render_request_pdf(request$request_code, other, file.path(root, "forbidden.pdf"), ctx),
    class = "ppsv_authorization_error"
  )
  testthat::expect_equal(render_request_pdf(request$request_code, owner, pdf_file, ctx), normalizePath(pdf_file))
  testthat::expect_gt(file.info(pdf_file)$size, 1000)
  testthat::expect_equal(rawToChar(readBin(pdf_file, "raw", n = 4L)), "%PDF")
  if (nzchar(Sys.which("pdftotext"))) {
    text <- paste(system2("pdftotext", c("-layout", pdf_file, "-"), stdout = TRUE), collapse = "\n")
    text <- iconv(text, from = "latin1", to = "UTF-8", sub = "")
    testthat::expect_match(text, request$request_code, fixed = TRUE)
    testthat::expect_match(text, "Protein Purification", fixed = TRUE)
    testthat::expect_match(text, "Under review", fixed = TRUE)
    testthat::expect_match(text, "Alice", fixed = TRUE)
    testthat::expect_match(text, "P12345", fixed = TRUE)
    testthat::expect_match(text, "Reviewed", fixed = TRUE)
    testthat::expect_match(text, "yeroslaviz", fixed = TRUE)
    testthat::expect_match(text, "construct", fixed = TRUE)
    testthat::expect_match(text, "SHA-256", fixed = TRUE)
    testthat::expect_match(text, substr(request$files$sha256[[1L]], 1L, 12L), fixed = TRUE)
    testthat::expect_false(grepl("Cost breakdown|Invoice", text, ignore.case = TRUE))
  }
})

testthat::test_that("general-inquiry PDF excludes protein and billing sections", {
  ctx <- ppsv_test_context()
  owner <- ppsv_test_user(ctx, "alice")
  root <- attr(ctx, "test_root")
  request <- create_request(
    ppsv_valid_inquiry_payload(),
    uploads = ppsv_test_upload(root, "consultation-notes.txt", "notes"),
    user = owner,
    ctx = ctx
  )
  pdf_file <- file.path(attr(ctx, "test_root"), "inquiry.pdf")
  render_request_pdf(request$request_code, owner, pdf_file, ctx)
  if (nzchar(Sys.which("pdftotext"))) {
    text <- paste(system2("pdftotext", c(pdf_file, "-"), stdout = TRUE), collapse = "\n")
    text <- iconv(text, from = "latin1", to = "UTF-8", sub = "")
    testthat::expect_match(text, "General inquiry / consultation", fixed = TRUE)
    testthat::expect_match(text, "Construct consultation", fixed = TRUE)
    testthat::expect_match(text, "Please advise", fixed = TRUE)
    testthat::expect_match(text, "Molecular cloning", fixed = TRUE)
    testthat::expect_match(text, "consultation-notes.txt", fixed = TRUE)
    testthat::expect_false(grepl("Protein name|Billing code", text, ignore.case = TRUE))
  }
})

testthat::test_that("Shiny test mode renders conditional service and inquiry forms", {
  testthat::skip_if_not_installed("shiny")
  root <- tempfile("ppsv-shiny-")
  dir.create(root)
  dir.create(file.path(root, "pool"))
  names <- c(
    "AUTH_MODE", "PPSV_TEST_USER", "PPSV_TEST_NAME", "PPSV_TEST_EMAIL",
    "PPSV_DB_FILE", "PPSV_POOL_ROOT", "PPSV_FALLBACK_ROOT", "PPSV_TICKET_MODE"
  )
  old <- Sys.getenv(names, unset = NA_character_)
  on.exit({
    for (index in seq_along(names)) {
      if (is.na(old[[index]])) {
        Sys.unsetenv(names[[index]])
      } else {
        do.call(Sys.setenv, setNames(list(old[[index]]), names[[index]]))
      }
    }
  }, add = TRUE)
  Sys.setenv(
    AUTH_MODE = "test", PPSV_TEST_USER = "yeroslaviz",
    PPSV_TEST_NAME = "Assa Yeroslaviz",
    PPSV_TEST_EMAIL = "yeroslaviz@biochem.mpg.de",
    PPSV_DB_FILE = file.path(root, "db.sqlite"),
    PPSV_POOL_ROOT = file.path(root, "pool"),
    PPSV_FALLBACK_ROOT = file.path(root, "fallback"),
    PPSV_TICKET_MODE = "disabled"
  )
  old_wd <- setwd(file.path(PPSV_TEST_REPO, "ppsv-app"))
  on.exit(setwd(old_wd), add = TRUE)
  app_env <- new.env(parent = globalenv())
  sys.source("app.R", app_env)
  shiny::testServer(app_env$server, {
    session$flushReact()
    testthat::expect_match(output$app_root$html, "Project Management", fixed = TRUE)
    session$setInputs(nav_create = 1)
    session$flushReact()
    create_page <- output$active_page_ui$html
    ordered_labels <- c(
      "Molecular cloning",
      "Host repertoire for expression optimization",
      "Large Scale Production",
      "Protein Purification",
      "Protein Analysis",
      "Macromolecular Crystallisation",
      "X-Ray Crystallography",
      "Structure Modeling and Validation",
      "General inquiry / consultation"
    )
    positions <- vapply(
      ordered_labels,
      function(label) regexpr(label, create_page, fixed = TRUE)[[1L]],
      integer(1L)
    )
    testthat::expect_true(all(positions > 0L))
    testthat::expect_true(all(diff(positions) > 0L))
    initial <- output$new_request_branch$html
    testthat::expect_match(initial, "Choose a request type", fixed = TRUE)
    testthat::expect_false(grepl("Billing code|Protein name|Your question", initial))

    session$setInputs(
      service_choice = "protein-purification",
      new_billing_code = "STALE-BILLING",
      new_protein_name = "STALE-PROTEIN"
    )
    session$flushReact()
    service <- output$new_request_branch$html
    testthat::expect_match(service, "Protein name", fixed = TRUE)
    testthat::expect_match(service, "Billing code", fixed = TRUE)
    testthat::expect_match(service, "8 optional fields", fixed = TRUE)
    service_info <- output$selected_service_info$html
    testthat::expect_match(
      service_info,
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Protein-Purification.aspx",
      fixed = TRUE
    )
    testthat::expect_match(service_info, "noopener noreferrer", fixed = TRUE)

    session$setInputs(service_choice = "__inquiry__")
    session$flushReact()
    inquiry <- output$new_request_branch$html
    testthat::expect_match(inquiry, "Your question", fixed = TRUE)
    testthat::expect_false(grepl("Billing code|Protein name", inquiry))
    session$setInputs(service_choice = "protein-purification")
    session$flushReact()
    testthat::expect_match(output$new_request_branch$html, "Protein name", fixed = TRUE)

    session$setInputs(
      service_choice = "__inquiry__",
      new_contact_name = "Assa Yeroslaviz",
      new_contact_email = "yeroslaviz@biochem.mpg.de",
      new_research_group = "Test research group",
      new_phone = "+49 000",
      new_related_service_module_slug = "",
      new_inquiry_subject = "Branch isolation",
      new_inquiry_message = "Unicode αβγ\nSecond line",
      submit_request = 1
    )
    session$flushReact()
    saved <- selected_request()
    testthat::expect_equal(app_env$field_value(saved, "request_kind"), "inquiry")
    testthat::expect_equal(app_env$field_value(saved, "inquiry_subject"), "Branch isolation")
    testthat::expect_equal(app_env$field_value(saved, "inquiry_message"), "Unicode αβγ\nSecond line")
    testthat::expect_false(nzchar(app_env$field_value(saved, "billing_code")))
    testthat::expect_false("protein_name" %in% names(saved))
  })
})
