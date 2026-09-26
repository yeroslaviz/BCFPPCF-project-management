ppsv_test_repo_root <- function() {
  candidates <- c(".", "..", "../..")
  matches <- candidates[file.exists(file.path(candidates, "ppsvf-app", "R", "load_backend.R"))]
  if (!length(matches)) stop("Could not locate the PPSV repository root.")
  normalizePath(matches[[1L]], winslash = "/")
}

PPSV_TEST_REPO <- ppsv_test_repo_root()
source(file.path(PPSV_TEST_REPO, "ppsvf-app", "R", "load_backend.R"), local = FALSE)

ppsv_test_context <- function(ticket_mode = "disabled", direct_ack = FALSE,
                              max_upload_mb = 75, pool = TRUE) {
  root <- tempfile("ppsv-test-")
  dir.create(root, recursive = TRUE)
  pool_root <- file.path(root, "pool")
  if (pool) dir.create(pool_root)
  config <- ppsv_config(list(
    app_dir = file.path(PPSV_TEST_REPO, "ppsvf-app"),
    db_file = file.path(root, "ppsv.sqlite"),
    pool_root = pool_root,
    pool_expected_source = "",
    allow_local_pool = TRUE,
    fallback_root = file.path(root, "fallback"),
    public_url = "https://ppcf-vm.biochem.mpg.de/ppsvf-app",
    max_upload_mb = max_upload_mb,
    ticket_mode = ticket_mode,
    direct_ack = direct_ack,
    service_identity_authorized = !identical(ticket_mode, "disabled"),
    ticket_e2e_test_ack = !identical(ticket_mode, "disabled"),
    smtp_host = if (identical(ticket_mode, "disabled")) "" else "smtp.example.org",
    smtp_port = 587L,
    smtp_security = "starttls",
    smtp_user = "",
    smtp_password = "",
    auth_mode = "test",
    logo_path = file.path(PPSV_TEST_REPO, "ppsvf-app", "www", "ppsv-logo.png")
  ))
  ctx <- ppsv_initialize(config)
  attr(ctx, "test_root") <- root
  ctx
}

ppsv_test_user <- function(ctx, username, email = paste0(username, "@example.org"),
                           name = tools::toTitleCase(username), email_present = TRUE) {
  headers <- list(
    HTTP_X_REMOTE_NAME = name,
    HTTP_X_REMOTE_EMAIL = if (email_present) email else "",
    HTTP_X_REMOTE_GROUP = "Test research group",
    HTTP_X_REMOTE_PHONE = "+49 123"
  )
  current_user(username = username, headers = headers, ctx = ctx)
}

ppsv_valid_service_payload <- function(...) {
  payload <- list(
    request_kind = "service",
    service_module_slug = "protein-purification",
    contact_name = "Manual Name",
    contact_email = "manual@example.org",
    research_group = "Structural Biology",
    phone = "+49 123",
    billing_code = "BIO-123",
    protein_name = "β test protein",
    uniprot_id = "P12345",
    source_organism = "Homo sapiens",
    expression_construct = "Residues 1–100\nvariant α",
    tags = "His6",
    expression_host = "E. coli",
    antibiotic_resistance = "Kanamycin",
    storage_buffer = "20 mM HEPES, pH 7.5",
    references_previous_experiments = "N/A",
    amount_required_mg = 1.5,
    final_concentration_mg_ml = 2.5,
    delivery_state = "Frozen",
    aliquot_size = "100 µL",
    size_uncleaved_da = "",
    size_cleaved_da = "",
    cleavage_size = "5 kDa",
    sequence_uncleaved = "MSTNPK",
    sequence_cleaved = "",
    purification_strategy = "Affinity then SEC",
    tag_removal_required = "Yes",
    localisation = "Cytosolic"
  )
  changes <- list(...)
  payload[names(changes)] <- changes
  payload
}

ppsv_valid_inquiry_payload <- function(...) {
  payload <- list(
    request_kind = "inquiry",
    contact_name = "Manual Name",
    contact_email = "manual@example.org",
    research_group = "Structural Biology",
    phone = "+49 123",
    related_service_module_slug = "molecular-cloning",
    inquiry_subject = "Construct consultation",
    inquiry_message = "Please advise.\nUnicode: αβγ"
  )
  changes <- list(...)
  payload[names(changes)] <- changes
  payload
}

ppsv_test_upload <- function(root, name = "input.txt", content = "test content") {
  path <- file.path(root, paste0("upload-", length(list.files(root)), ".tmp"))
  writeLines(content, path, useBytes = TRUE)
  data.frame(
    name = name,
    size = file.info(path)$size,
    type = "text/plain",
    datapath = path,
    stringsAsFactors = FALSE
  )
}

ppsv_db_query <- function(ctx, sql, params = NULL) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbGetQuery(con, sql, params = params)
}
