testthat::test_that("PDF wrapping measures proportional text and preserves unbroken values", {
  file <- tempfile(fileext = ".pdf")
  on.exit(unlink(file), add = TRUE)
  ppsv_pdf_open_device(file)
  on.exit(grDevices::dev.off(), add = TRUE)
  graphics::par(mar = c(0, 0, 0, 0))
  graphics::plot.new()
  graphics::plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
  sequence <- paste0(strrep("MKWVTFISLLFLFSSAYS", 275L), "SEQUENCE_END_SENTINEL")
  wrapped <- ppsv_pdf_wrap_text(sequence, width = 0.57, cex = 0.65)
  testthat::expect_identical(paste(wrapped, collapse = ""), sequence)
  testthat::expect_true(all(graphics::strwidth(wrapped, cex = 0.65) <= 0.57))
  testthat::expect_gt(length(wrapped), 36L)
  wide_text <- strrep("W", 120L)
  narrow_text <- strrep("i", 120L)
  testthat::expect_gt(
    length(ppsv_pdf_wrap_text(wide_text, width = 0.57, cex = 0.65)),
    length(ppsv_pdf_wrap_text(narrow_text, width = 0.57, cex = 0.65))
  )
})

testthat::test_that("long PDF values continue across pages inside the body margins", {
  file <- tempfile(fileext = ".pdf")
  on.exit(unlink(file), add = TRUE)
  sequence <- paste0(strrep("MKWVTFISLLFLFSSAYS", 275L), "SEQUENCE_END_SENTINEL")
  long_url <- paste0("https://example.org/", strrep("LongReferencePath", 110L), "/REFERENCE_END_SENTINEL")
  request <- list(
    request_code = "PPSV000123", request_kind = "service", current_status = "Accepted",
    owner_username = "alice", contact_name = "Alice Example", contact_email = "alice@example.org",
    research_group = "Structural Biology", phone = "+49 123", created_at = "2026-10-18",
    updated_at = "2026-10-18", contact_name_verified = 1L, contact_email_verified = 1L
  )
  details <- ppsv_valid_service_payload(
    protein_name = "Pagination QA protein", sequence_uncleaved = sequence,
    references_previous_experiments = long_url,
    expression_construct = "Residues 1-100", aliquot_size = "100 uL"
  )
  ppsv_write_request_pdf(
    request, details = details,
    module = PPSV_SERVICE_MODULES[PPSV_SERVICE_MODULES$slug == "protein-purification", ],
    files = data.frame(
      original_name = paste0(strrep("long-filename-", 12L), ".txt"),
      category = "inputs", size_bytes = 123L, sha256 = strrep("a", 64L)
    ),
    file = file, logo_path = ""
  )
  testthat::expect_gt(file.info(file)$size, 1000)
  testthat::skip_if(!nzchar(Sys.which("pdftotext")), "Poppler text extraction is unavailable")
  extracted <- system2("pdftotext", c("-raw", shQuote(file), "-"), stdout = TRUE)
  compact <- gsub("[[:space:]]", "", paste(extracted, collapse = ""))
  testthat::expect_match(compact, "SEQUENCE_END_SENTINEL", fixed = TRUE)
  testthat::expect_match(compact, "REFERENCE_END_SENTINEL", fixed = TRUE)
  testthat::expect_match(compact, "Uncleavedsequence(continued)", fixed = TRUE)
  testthat::expect_gt(sum(grepl("PPSV request summary", extracted, fixed = TRUE)), 3L)
  # A section heading must share its page with the first field.
  pages <- strsplit(paste(extracted, collapse = "\n"), "\f", fixed = TRUE)[[1L]]
  contact_page <- pages[grepl("Contact snapshot", pages, fixed = TRUE)]
  testthat::expect_length(contact_page, 1L)
  testthat::expect_match(contact_page, "Alice Example", fixed = TRUE)

  python <- Sys.getenv("PPSV_TEST_PYTHON", Sys.which("python3"))
  available <- nzchar(python) && identical(suppressWarnings(system2(
    python, c("-c", shQuote("import pdfplumber")), stdout = FALSE, stderr = FALSE
  )), 0L)
  testthat::skip_if(!available, "Optional pdfplumber geometry checks are unavailable")
  script <- tempfile(fileext = ".py")
  on.exit(unlink(script), add = TRUE)
  writeLines(c(
    "import sys, pdfplumber",
    "with pdfplumber.open(sys.argv[1]) as report:",
    "    for page in report.pages:",
    "        assert all(c['x1'] <= page.width * .95 for c in page.chars), f'Right margin on page {page.page_number}'",
    "        body = [c for c in page.chars if page.height * .12 < c['top'] < page.height * .94]",
    "        assert all(c['bottom'] <= page.height * .93 for c in body), f'Footer overlap on page {page.page_number}'"
  ), script)
  geometry <- suppressWarnings(system2(python, c(shQuote(script), shQuote(file)), stdout = TRUE, stderr = TRUE))
  testthat::expect_null(attr(geometry, "status"), info = paste(geometry, collapse = "\n"))
})
