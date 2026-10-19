ppsv_billing_fixture <- function(lines, encoding = "UTF-8") {
  directory <- tempfile("ppsv-billing-")
  dir.create(directory)
  path <- file.path(directory, "budget_holders.csv")
  content <- paste(c(lines, ""), collapse = "\n")
  if (!identical(encoding, "UTF-8")) content <- iconv(content, from = "UTF-8", to = encoding)
  writeBin(charToRaw(content), path)
  list(app_dir = directory, budget_holders_file = path)
}

testthat::test_that("the facility export loads MacRoman names, metadata, and continuation codes", {
  config <- ppsv_billing_fixture(c(
    ",,,,,,Stand 01.01.2026",
    "Spalte1,budget holder,cost_center,description,Spalte4,Infos,department",
    "X,Müller,K100,Group Müller,,,Research",
    ",,K101,Second cost centre,,,Research",
    "X,Other,K200,Other group,,,Research"
  ), "macintosh")
  holders <- ppsv_budget_holders(config)
  testthat::expect_equal(holders$pi, c("Müller", "Müller", "Other"))
  testthat::expect_equal(holders$cost_center, c("K100", "K101", "K200"))
  testthat::expect_equal(holders$description[[1L]], "Group Müller")
  testthat::expect_null(attr(holders, "catalogue_error"))
})

testthat::test_that("normalized NGS catalogues preserve codes and discard unusable duplicates", {
  config <- ppsv_billing_fixture(c(
    "name,surname,email,cost_center",
    "Cox,Juergen,pi@example.org,K435",
    "Cox,Juergen,pi@example.org,K000",
    "Cox,Juergen,pi@example.org,K000",
    "Other,PI,other@example.org,N.A.",
    "Missing,PI,other@example.org,"
  ))
  holders <- ppsv_budget_holders(config)
  testthat::expect_equal(holders$cost_center, c("K435", "K000"))
  testthat::expect_equal(holders$pi, rep("Cox Juergen", 2L))
  testthat::expect_equal(ppsv_group_budgets("Research Group (Cox)", config)$cost_center, c("K435", "K000"))
  testthat::expect_equal(nrow(ppsv_group_budgets("Juergen", config)), 2L)
  testthat::expect_equal(nrow(ppsv_group_budgets("  cox juergen  ", config)), 2L)
  testthat::expect_equal(nrow(ppsv_group_budgets("uid=requester,ou=Cox,ou=Research Group", config)), 2L)
  testthat::expect_equal(nrow(ppsv_group_budgets("Unknown", config)), 0L)
})

testthat::test_that("delimited UTF-8 catalogues and normalized PI profiles match facility labels", {
  config <- ppsv_billing_fixture(c(
    "budget holder;cost_center;description",
    "Cox;K435;Group",
    "Müller;K001;Group"
  ))
  testthat::expect_equal(ppsv_group_budgets("Cox Juergen", config)$cost_center, "K435")
  testthat::expect_equal(ppsv_group_budgets("Group (Müller)", config)$cost_center, "K001")
  testthat::expect_equal(ppsv_group_budgets("C.x", config)$cost_center, character())
  tab_config <- ppsv_billing_fixture(c(
    "name\tsurname\temail\tcost_center",
    "Cox\tJuergen\tpi@example.org\tK435"
  ))
  testthat::expect_equal(ppsv_group_budgets("Cox", tab_config)$cost_center, "K435")
})

testthat::test_that("blank separator rows prevent continuation into an unrelated section", {
  config <- ppsv_billing_fixture(c(
    "budget holder,cost_center",
    "First,K100",
    ",",
    ",K999",
    "Next,K200"
  ))
  testthat::expect_equal(ppsv_budget_holders(config)$cost_center, c("K100", "K200"))
})

testthat::test_that("the supplied facility catalogue is read without changing the source export", {
  config <- list(app_dir = file.path(PPSV_TEST_REPO, "ppsvf-app"))
  holders <- ppsv_budget_holders(config)
  testthat::expect_gt(nrow(holders), 0L)
  testthat::expect_true(all(nzchar(holders$pi)))
  testthat::expect_true(all(nzchar(holders$cost_center)))
  testthat::expect_equal(ppsv_group_budgets("Cox", config)$cost_center, "K435")
  testthat::expect_true(any(grepl("Kälte", holders$description, fixed = TRUE)))
})

testthat::test_that("a sole code is automatic and the authenticated group takes precedence", {
  config <- ppsv_billing_fixture(c("budget holder,cost_center", "Cox,K435", "Other,K200"))
  payload <- list(request_kind = "service", research_group = "Other", billing_code = "")
  result <- ppsv_apply_billing(payload, list(research_group = "Group (Cox)"), config)
  testthat::expect_equal(result$research_group, "Cox")
  testthat::expect_equal(result$billing_code, "K435")
  payload$billing_code <- "FORGED"
  testthat::expect_equal(ppsv_apply_billing(payload, list(research_group = "Cox"), config)$billing_code, "K435")
})

testthat::test_that("multiple codes require an explicit valid choice for that PI", {
  config <- ppsv_billing_fixture(c("budget holder,cost_center", "Cox,K435", ",K000", "Other,K200"))
  user <- list(research_group = "Cox")
  payload <- list(request_kind = "service", research_group = "Cox", billing_code = "")
  testthat::expect_error(ppsv_apply_billing(payload, user, config), "multiple cost centres", class = "ppsv_validation_error")
  payload$billing_code <- "K200"
  testthat::expect_error(ppsv_apply_billing(payload, user, config), "listed for your PI", class = "ppsv_validation_error")
  payload$billing_code <- "K000"
  testthat::expect_equal(ppsv_apply_billing(payload, user, config)$billing_code, "K000")
})

testthat::test_that("an unknown group can choose catalogue codes but cannot submit free text", {
  config <- ppsv_billing_fixture(c("budget holder,cost_center", "Cox,K435", "Other,K200"))
  payload <- list(request_kind = "service", research_group = "New group", billing_code = "")
  testthat::expect_error(ppsv_apply_billing(payload, list(), config), "Please choose", class = "ppsv_validation_error")
  payload$billing_code <- "FREE-TEXT"
  testthat::expect_error(ppsv_apply_billing(payload, list(), config), "from the budget-holder CSV", class = "ppsv_validation_error")
  payload$billing_code <- "K200"
  result <- ppsv_apply_billing(payload, list(), config)
  testthat::expect_equal(result$research_group, "New group")
  testthat::expect_equal(result$billing_code, "K200")
})

testthat::test_that("unavailable catalogues block new service requests and permit inquiries", {
  config <- list(app_dir = tempfile("missing-budget-"))
  holders <- ppsv_budget_holders(config)
  testthat::expect_equal(nrow(holders), 0L)
  testthat::expect_match(attr(holders, "catalogue_error"), "unavailable")
  payload <- list(request_kind = "service", research_group = "New", billing_code = "K100")
  testthat::expect_error(ppsv_apply_billing(payload, list(), config), "unavailable", class = "ppsv_validation_error")
  payload$request_kind <- "inquiry"
  result <- ppsv_apply_billing(payload, list(research_group = "Cox"), config)
  testthat::expect_equal(result$billing_code, "")
  testthat::expect_equal(result$research_group, "Cox")
})

testthat::test_that("unchanged legacy code/group pairs survive edits but cannot be reassigned", {
  config <- ppsv_billing_fixture(c("budget holder,cost_center", "Cox,K435", "Cox,K000", "Other,K200"))
  current <- list(research_group = "Cox", billing_code = "LEGACY")
  payload <- c(list(request_kind = "service"), current)
  testthat::expect_equal(ppsv_apply_billing(payload, list(research_group = "Cox"), config, current)$billing_code, "LEGACY")
  missing <- list(app_dir = tempfile("missing-budget-"))
  testthat::expect_equal(ppsv_apply_billing(payload, list(research_group = "Cox"), missing, current)$billing_code, "LEGACY")
  payload$billing_code <- "OTHER-LEGACY"
  testthat::expect_error(ppsv_apply_billing(payload, list(research_group = "Cox"), config, current), "listed for your PI", class = "ppsv_validation_error")
})

testthat::test_that("malformed catalogues produce a clear field-validation error", {
  config <- ppsv_billing_fixture(c("unrelated,columns", "value,another"))
  testthat::expect_match(attr(ppsv_budget_holders(config), "catalogue_error"), "must contain")
  payload <- list(request_kind = "service", research_group = "Cox", billing_code = "K435")
  testthat::expect_error(ppsv_apply_billing(payload, list(), config), "could not be read", class = "ppsv_validation_error")
})
