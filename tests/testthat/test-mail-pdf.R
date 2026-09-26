find_repo_file <- function(...) {
  relative <- file.path(...)
  candidates <- c(relative, file.path("..", relative), file.path("..", "..", relative))
  match <- candidates[file.exists(candidates)][1L]
  if (is.na(match)) stop("Could not locate ", relative)
  normalizePath(match)
}

source(find_repo_file("ppsv-app", "R", "mail.R"), local = TRUE)
source(find_repo_file("ppsv-app", "R", "pdf.R"), local = TRUE)

testthat::test_that("mail configuration fails closed", {
  values <- c(
    PPSV_TICKET_MODE = "service_reply_to",
    PPSV_TICKET_TO = "ppsv-request@biochem.mpg.de",
    PPSV_MAIL_FROM = "ppsv-service@biochem.mpg.de",
    PPSV_SMTP_HOST = ""
  )
  env <- function(name, unset = "") if (name %in% names(values)) values[[name]] else unset
  settings <- ppsv_mail_settings(env)
  errors <- ppsv_validate_mail_settings(settings)
  testthat::expect_true(any(grepl("PPSV_SMTP_HOST", errors, fixed = TRUE)))
  testthat::expect_true(any(grepl("PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK", errors, fixed = TRUE)))
})

testthat::test_that("LDAP From mode has a safe service fallback and one acknowledgement", {
  settings <- list(
    mode = "ldap_from",
    direct_ack = TRUE,
    ticket_to = "ppsv-request@biochem.mpg.de",
    service_from = "ppsv-service@biochem.mpg.de",
    public_url = "https://ppcf-vm.biochem.mpg.de/ppsv-app",
    smtp = list(host.name = "smtp.example.org", port = 587L, ssl = FALSE, tls = TRUE, user.name = "", passwd = "")
  )
  request <- list(
    request_code = "PPSV000001",
    request_kind = "service",
    owner_username = "yeroslaviz",
    submitter_name = "Assa Yeroslaviz",
    submitter_email = "yeroslaviz@biochem.mpg.de",
    research_group = "Test group",
    phone = "123",
    billing_code = "ABC"
  )
  details <- list(
    protein_name = "Protein A",
    uniprot_id = "P12345",
    source_organism = "Homo sapiens",
    expression_construct = "1-100",
    tags = "His6",
    expression_host = "E. coli",
    antibiotic_resistance = "Kanamycin",
    storage_buffer = "HEPES",
    references_previous_experiments = "None",
    amount_required_mg = 1,
    final_concentration_mg_ml = 2,
    delivery_state = "Frozen",
    aliquot_size = "100 uL"
  )
  plan <- ppsv_plan_ticket_messages(
    request,
    list(name = "Protein Purification"),
    details,
    verified_ldap_email = "yeroslaviz@biochem.mpg.de",
    settings = settings
  )

  testthat::expect_equal(plan$primary$from, "yeroslaviz@biochem.mpg.de")
  testthat::expect_equal(plan$fallback$from, "ppsv-service@biochem.mpg.de")
  testthat::expect_equal(plan$fallback$reply_to, "yeroslaviz@biochem.mpg.de")
  testthat::expect_equal(plan$acknowledgement$to, "yeroslaviz@biochem.mpg.de")

  calls <- character()
  sender <- function(message, settings) {
    calls <<- c(calls, message$kind)
    if (identical(message$kind, "ticket_ldap_from")) stop("relay rejected sender")
    list(success = TRUE)
  }
  result <- ppsv_deliver_ticket_plan(plan, sender, settings)
  testthat::expect_true(result$success)
  testthat::expect_true(result$acknowledgement_success)
  testthat::expect_equal(calls, c("ticket_ldap_from", "ticket_service", "acknowledgement"))
})

testthat::test_that("unverified form email is never used in mail headers", {
  settings <- list(
    mode = "service_reply_to",
    direct_ack = TRUE,
    ticket_to = "ppsv-request@biochem.mpg.de",
    service_from = "ppsv-service@biochem.mpg.de",
    public_url = "https://ppcf-vm.biochem.mpg.de/ppsv-app",
    smtp = list(host.name = "smtp.example.org", port = 587L, ssl = FALSE, tls = TRUE, user.name = "", passwd = "")
  )
  request <- list(
    request_code = "PPSV000002",
    request_kind = "inquiry",
    submitter_name = "Requester",
    submitter_email = "forged@example.org",
    inquiry_subject = "Question"
  )
  plan <- ppsv_plan_ticket_messages(request, details = list(subject = "Question", message = "Please advise"), settings = settings)
  testthat::expect_equal(plan$primary$from, "ppsv-service@biochem.mpg.de")
  testthat::expect_equal(plan$primary$reply_to, "")
  testthat::expect_null(plan$acknowledgement)
})

testthat::test_that("retry delays match the documented schedule", {
  testthat::expect_equal(
    vapply(1:7, ppsv_mail_retry_delay_seconds, numeric(1)),
    c(0, 300, 1800, 7200, 43200, 86400, NA_real_)
  )
})

testthat::test_that("the supplied acknowledgement only mentions a ticket link when one exists", {
  request <- list(contact_name = "Alice Requester")
  without_link <- ppsv_format_acknowledgement(request)
  with_link <- ppsv_format_acknowledgement(request, "https://tickets.example.org/T-42")
  testthat::expect_match(without_link, "Thank you for your E-Mail", fixed = TRUE)
  testthat::expect_false(grepl("following Link", without_link, fixed = TRUE))
  testthat::expect_match(with_link, "following Link", fixed = TRUE)
  testthat::expect_match(with_link, "https://tickets.example.org/T-42", fixed = TRUE)
})

testthat::test_that("PPSV PDF contains request data and no cost or invoice sections", {
  pdf_file <- tempfile(fileext = ".pdf")
  on.exit(unlink(pdf_file), add = TRUE)
  request <- list(
    request_code = "PPSV000003",
    request_kind = "inquiry",
    status = "Submitted",
    submitter_name = "Requester",
    submitter_email = "requester@biochem.mpg.de",
    research_group = "Research group",
    phone = "123",
    created_at = "2026-09-25"
  )
  ppsv_write_request_pdf(
    request,
    details = list(subject = "Consultation", message = "Please advise on construct design."),
    file = pdf_file,
    logo_path = ""
  )
  testthat::expect_true(file.exists(pdf_file))
  testthat::expect_gt(file.info(pdf_file)$size, 1000)
  header <- readBin(pdf_file, what = "raw", n = 4L)
  testthat::expect_equal(rawToChar(header), "%PDF")
  if (nzchar(Sys.which("pdftotext"))) {
    text <- paste(system2("pdftotext", c(pdf_file, "-"), stdout = TRUE), collapse = "\n")
    testthat::expect_match(text, "PPSV000003")
    testthat::expect_match(text, "Consultation")
    testthat::expect_false(grepl("Cost breakdown|Invoice", text, ignore.case = TRUE))
  }
})
