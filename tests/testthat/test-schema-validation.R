testthat::test_that("fresh schema, migrations, seeds, and vocabulary are exact", {
  ctx <- ppsv_test_context()
  testthat::expect_equal(ppsv_db_query(ctx, "SELECT version FROM schema_migrations ORDER BY version")$version, 1:3)
  modules <- list_service_modules(ctx = ctx)
  expected_modules <- data.frame(
    slug = c(
      "molecular-cloning", "host-repertoire", "large-scale-production",
      "protein-purification", "protein-analysis", "macromolecular-crystallisation",
      "x-ray-crystallography", "structure-modeling-validation"
    ),
    name = c(
      "Molecular cloning", "Host repertoire for expression optimization",
      "Large Scale Production", "Protein Purification", "Protein Analysis",
      "Macromolecular Crystallisation", "X-Ray Crystallography",
      "Structure Modeling and Validation"
    ),
    description = c(
      paste("Molecular cloning assists you with access to a series of vectors and protocols", "for single - or multigene assembly. An online primer design tool is available", "for cloning into the parallel pCoofy vector series."),
      paste("With our expression host repertoire including bacteria, yeast, insect and", "mammalian cells we will identify the system most appropriate for your target", "protein. Parallel screening aims at achieving high expression levels of", "cytoplasmic or secreted proteins"),
      paste("We produce bacteria and yeast at high cell density in stirred tank reactors", "from 1 to 10 L including protocols for metabolic labelling. Insect and mammalian", "cells are cultivated in shake flasks up to 5 L scale."),
      paste("We establish a purification strategy for your target protein if no protocols", "are available. In addition to standard chromatography procedures (affinity,", "IEX and SEC) we apply special protocols like additive screens, protein refolding", "etc for difficult targets."),
      paste("As final quality control of the delivered protein, we routinely assess purity,", "intact mass and integrity / homogeneity by SDS-PAGE, LC-MS, DLS + analytical gel", "filtration. Additional characterization like CD-spectroscopy or nanoDSF is", "performed if required."),
      "Automated Macromolecular cristallisation screening and optimisation",
      "We characterize macromolecular crystals using X-Ray Crystallography",
      paste("We can refine build and validate macromolecular structures (X-ray and CryoEM).", "We can also support the depostion of structure to the Protein Data Bank.")
    ),
    url = c(
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Molecular-Cloning.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Host-repertoire.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Up-scale-production.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Protein-Purification.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Quality-Control.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Macromolecular%20Crystallisation.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Crystallography.aspx",
      "https://max.mpg.de/sites/biochem/Forschungsservice/Protein-Production/Seiten/Structure%20Modelling%20and%20Validation.aspx"
    ),
    display_order = 1:8,
    active = rep(1L, 8L),
    stringsAsFactors = FALSE
  )
  testthat::expect_equal(modules, expected_modules)
  testthat::expect_equal(PPSV_STATUS_OPTIONS, c(
    "Submitted", "Under review", "Accepted", "In progress",
    "Awaiting requester input", "Completed", "Closed"
  ))
  testthat::expect_equal(tolower(PPSV_ADMIN_USERS$username), c("yeroslaviz", "basquin"))
  testthat::expect_equal(
    tolower(PPSV_TECHNICIAN_USERS$username),
    c("grzejszc", "pleyer", "valer", "wehner", "yaoxiao", "piroddi")
  )
  con <- ppsv_db_connect(ctx$config)
  columns <- DBI::dbListFields(con, "requests")
  DBI::dbDisconnect(con)
  testthat::expect_false(any(grepl("cost|price|invoice", columns, ignore.case = TRUE)))
})

testthat::test_that("supported prior schemas migrate transactionally without losing requests", {
  template <- ppsv_test_context()
  cfg <- template$config
  cfg$db_file <- file.path(attr(template, "test_root"), "prior-v1.sqlite")
  con <- ppsv_db_connect(cfg)
  ppsv_db_transaction(con, ppsv_apply_migration_v1(con), immediate = TRUE)
  now <- ppsv_now()
  DBI::dbExecute(
    con,
    paste(
      "INSERT INTO users(username,display_name,email,role,active,ldap_email_verified,created_at,updated_at)",
      "VALUES ('legacy-user','Legacy User','legacy@example.org','user',1,1,?,?)"
    ),
    params = list(now, now)
  )
  DBI::dbExecute(
    con,
    paste(
      "INSERT INTO requests(request_code,request_kind,owner_username,contact_name,contact_email,",
      "contact_email_verified,research_group,phone,current_status,ticket_state,storage_state,created_at,updated_at)",
      "VALUES ('PPSV000777','inquiry','legacy-user','Legacy User','legacy@example.org',1,",
      "'Legacy Group','123','Submitted','disabled','none',?,?)"
    ),
    params = list(now, now)
  )
  DBI::dbExecute(
    con,
    "INSERT INTO inquiries(request_id,subject,message) SELECT id,'Preserve me','Migration payload' FROM requests WHERE request_code='PPSV000777'"
  )
  DBI::dbDisconnect(con)

  testthat::expect_silent(ppsv_initialize_database(cfg))
  migrated <- ppsv_db_query(
    list(config = cfg),
    paste(
      "SELECT r.request_code,r.contact_name_verified,i.subject,i.message",
      "FROM requests r JOIN inquiries i ON i.request_id=r.id",
      "WHERE r.request_code='PPSV000777'"
    )
  )
  testthat::expect_equal(migrated$request_code, "PPSV000777")
  testthat::expect_equal(migrated$contact_name_verified, 0L)
  testthat::expect_equal(migrated$subject, "Preserve me")
  testthat::expect_equal(migrated$message, "Migration payload")
  testthat::expect_equal(
    ppsv_db_query(list(config = cfg), "SELECT version FROM schema_migrations ORDER BY version")$version,
    1:3
  )

  con <- ppsv_db_connect(cfg)
  DBI::dbExecute(
    con,
    "INSERT INTO schema_migrations(version,applied_at) VALUES (99,?)",
    params = list(ppsv_now())
  )
  DBI::dbDisconnect(con)
  testthat::expect_error(
    ppsv_initialize_database(cfg),
    "Unsupported PPSV database schema version: 99"
  )
})

testthat::test_that("database setup is idempotent and rejects a legacy database", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  created <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  ppsv_initialize_database(ctx$config)
  testthat::expect_equal(get_request(created$request_code, user, ctx)$request_code, created$request_code)

  legacy <- tempfile(fileext = ".sqlite")
  con <- DBI::dbConnect(RSQLite::SQLite(), legacy)
  DBI::dbExecute(con, "CREATE TABLE ms_projects(id INTEGER)")
  DBI::dbDisconnect(con)
  legacy_cfg <- ctx$config
  legacy_cfg$db_file <- legacy
  testthat::expect_error(
    ppsv_initialize_database(legacy_cfg),
    "Refusing to migrate an unrecognized/legacy database"
  )
  con <- DBI::dbConnect(RSQLite::SQLite(), legacy)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  testthat::expect_true("ms_projects" %in% DBI::dbListTables(con))
})

testthat::test_that("workbook-derived field contract has 18 required and eight optional fields", {
  spec <- ppsv_form_field_spec()
  expected_required <- c(
    "contact_name", "contact_email", "research_group", "phone", "billing_code",
    "protein_name", "uniprot_id", "source_organism", "expression_construct",
    "tags", "expression_host", "antibiotic_resistance", "storage_buffer",
    "references_previous_experiments", "amount_required_mg",
    "final_concentration_mg_ml", "delivery_state", "aliquot_size"
  )
  expected_optional <- c(
    "size_uncleaved_da", "size_cleaved_da", "cleavage_size",
    "sequence_uncleaved", "sequence_cleaved", "purification_strategy",
    "tag_removal_required", "localisation"
  )
  testthat::expect_equal(sum(spec$required), 18L)
  testthat::expect_equal(sum(!spec$required), 8L)
  testthat::expect_identical(spec$field[spec$required], expected_required)
  testthat::expect_identical(spec$field[!spec$required], expected_optional)
  testthat::expect_identical(PPSV_OPTIONAL_PROTEIN_FIELDS, expected_optional)

  payload <- ppsv_valid_service_payload()
  testthat::expect_silent(ppsv_validate_request_payload(payload))
  for (field in expected_required) {
    missing <- payload
    missing[[field]] <- ""
    testthat::expect_error(
      ppsv_validate_request_payload(missing),
      class = "ppsv_validation_error",
      info = paste("mandatory field", field)
    )
  }

  scientific_text <- setdiff(
    PPSV_REQUIRED_PROTEIN_FIELDS,
    c("amount_required_mg", "final_concentration_mg_ml", "delivery_state")
  )
  not_applicable <- payload
  not_applicable[scientific_text] <- rep(list("N/A"), length(scientific_text))
  normalized_na <- ppsv_validate_request_payload(not_applicable)
  testthat::expect_true(all(vapply(
    scientific_text,
    function(field) identical(normalized_na[[field]], "N/A"),
    logical(1L)
  )))
  for (field in c("amount_required_mg", "final_concentration_mg_ml")) {
    bad <- payload
    bad[[field]] <- 0
    testthat::expect_error(ppsv_validate_request_payload(bad), "positive number")
  }
  for (field in c("size_uncleaved_da", "size_cleaved_da")) {
    blank <- payload
    blank[[field]] <- ""
    testthat::expect_silent(ppsv_validate_request_payload(blank))
    bad <- payload
    bad[[field]] <- -1
    testthat::expect_error(ppsv_validate_request_payload(bad), "positive number")
  }
  testthat::expect_equal(ppsv_validate_request_payload(payload)$cleavage_size, "5 kDa")
  testthat::expect_equal(ppsv_validate_request_payload(payload)$aliquot_size, "100 µL")
  blank_tag <- payload
  blank_tag$tag_removal_required <- ""
  testthat::expect_null(ppsv_validate_request_payload(blank_tag)$tag_removal_required)
  yes_tag <- payload
  yes_tag$tag_removal_required <- "Yes"
  testthat::expect_equal(ppsv_validate_request_payload(yes_tag)$tag_removal_required, 1L)
  no_tag <- payload
  no_tag$tag_removal_required <- "No"
  testthat::expect_equal(ppsv_validate_request_payload(no_tag)$tag_removal_required, 0L)
  bad_tag <- payload
  bad_tag$tag_removal_required <- "Maybe"
  testthat::expect_error(
    ppsv_validate_request_payload(bad_tag),
    "must be Yes, No, or blank"
  )
})

testthat::test_that("general inquiries ignore protein and billing fields", {
  inquiry <- ppsv_valid_inquiry_payload()
  inquiry$billing_code <- "SHOULD-NOT-PERSIST"
  inquiry$protein_name <- "SHOULD-NOT-PERSIST"
  normalized <- ppsv_validate_request_payload(inquiry)
  testthat::expect_equal(normalized$request_kind, "inquiry")
  testthat::expect_equal(normalized$billing_code, "")
  testthat::expect_false(any(c(PPSV_REQUIRED_PROTEIN_FIELDS, PPSV_OPTIONAL_PROTEIN_FIELDS) %in% names(normalized)))

  for (field in c(PPSV_INQUIRY_CONTACT_FIELDS, "inquiry_subject", "inquiry_message")) {
    missing <- inquiry
    missing[[field]] <- ""
    testthat::expect_error(
      ppsv_validate_request_payload(missing),
      class = "ppsv_validation_error",
      info = paste("inquiry field", field)
    )
  }
  inquiry$related_service_module_slug <- "not-a-service"
  testthat::expect_error(
    ppsv_validate_request_payload(inquiry),
    "not a recognized PPSV service module"
  )
  inquiry$related_service_module_slug <- ""
  testthat::expect_equal(
    ppsv_validate_request_payload(inquiry)$related_service_module_slug,
    ""
  )
})

testthat::test_that("services and inquiries share one sequence and persist separate details", {
  ctx <- ppsv_test_context()
  user <- ppsv_test_user(ctx, "alice")
  service <- create_request(ppsv_valid_service_payload(), user = user, ctx = ctx)
  inquiry <- create_request(ppsv_valid_inquiry_payload(), user = user, ctx = ctx)
  testthat::expect_equal(c(service$request_code, inquiry$request_code), c("PPSV000001", "PPSV000002"))
  testthat::expect_equal(service$request_kind, "service")
  testthat::expect_equal(service$protein_name, "β test protein")
  testthat::expect_equal(inquiry$request_kind, "inquiry")
  testthat::expect_true(is.na(inquiry$service_module_slug) || !nzchar(inquiry$service_module_slug))
  testthat::expect_true(is.na(inquiry$billing_code) || !nzchar(inquiry$billing_code))
  testthat::expect_equal(inquiry$inquiry_message, "Please advise.\nUnicode: αβγ")
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM protein_submissions")), 1L)
  testthat::expect_equal(nrow(ppsv_db_query(ctx, "SELECT * FROM inquiries")), 1L)
})

testthat::test_that("the PPSV app contains no legacy database or cost schema artifacts", {
  removed_legacy_artifacts <- c(
    "ms-app",
    "MS_Submission_System.docx",
    "Sample_project_type.xlsx",
    "bugs",
    "new_submission_error.png",
    "docs_screenshots"
  )
  testthat::expect_false(any(file.exists(file.path(PPSV_TEST_REPO, removed_legacy_artifacts))))

  app_files <- list.files(
    file.path(PPSV_TEST_REPO, "ppsvf-app"),
    recursive = TRUE,
    all.files = TRUE,
    full.names = FALSE,
    include.dirs = TRUE
  )
  forbidden_paths <- "(^|/)(ms_projects\\.db|budget_holders\\.csv|.*invoice.*|.*price[_ -]?list.*)$"
  testthat::expect_false(any(grepl(forbidden_paths, app_files, ignore.case = TRUE)))

  ctx <- ppsv_test_context()
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tables <- DBI::dbListTables(con)
  columns <- unlist(lapply(tables, function(table) DBI::dbListFields(con, table)), use.names = FALSE)
  testthat::expect_false(any(grepl("cost|invoice|price", c(tables, columns), ignore.case = TRUE)))
  testthat::expect_false("ms_projects" %in% tables)

  repository_files <- list.files(
    PPSV_TEST_REPO,
    recursive = TRUE,
    all.files = TRUE,
    full.names = FALSE,
    include.dirs = TRUE
  )
  repository_files <- repository_files[
    repository_files != ".git" & !startsWith(repository_files, ".git/")
  ]
  forbidden_repository_paths <- c(
    "(^|/)\\.Renviron$",
    "(^|/)\\.quarto($|/)",
    "(^|/)_site($|/)",
    "[.]sqlite([.-]|$)",
    "[.]db([.-]|$)",
    "(^|/)MS_Submission_System[.]docx$",
    "(^|/)Sample_project_type[.]xlsx$",
    "(^|/)new_submission_error[.]png$",
    "(^|/)docs_screenshots($|/)"
  )
  for (pattern in forbidden_repository_paths) {
    testthat::expect_false(
      any(grepl(pattern, repository_files, ignore.case = TRUE)),
      info = pattern
    )
  }
  production_files <- c(
    list.files(file.path(PPSV_TEST_REPO, "ppsvf-app"), recursive = TRUE, full.names = TRUE),
    list.files(file.path(PPSV_TEST_REPO, "scripts"), recursive = TRUE, full.names = TRUE)
  )
  production_files <- production_files[
    grepl("[.](R|r|sh|conf|service|timer|example|json|lock|sha256)$", production_files)
  ]
  production_text <- paste(vapply(production_files, function(path) {
    paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  }, character(1L)), collapse = "\n")
  testthat::expect_false(grepl("Sys[.]getenv[(][\"']MS_", production_text))
  gitignore <- readLines(file.path(PPSV_TEST_REPO, ".gitignore"), warn = FALSE)
  testthat::expect_false(any(grepl("^/Users/|^[A-Za-z]:[/\\\\]", gitignore)))
})
