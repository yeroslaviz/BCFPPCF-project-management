# PPSV configuration and immutable domain vocabulary.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0L || all(is.na(x))) y else x
}

ppsv_trim <- function(x) {
  if (is.null(x) || !length(x) || all(is.na(x))) return("")
  trimws(as.character(x)[1L])
}

ppsv_env_flag <- function(name, default = FALSE) {
  value <- tolower(ppsv_trim(Sys.getenv(name, if (default) "1" else "0")))
  value %in% c("1", "true", "yes", "on")
}

PPSV_FACILITY_NAME <- "Protein Production and Structural Validation Facility"
PPSV_FACILITY_EMAIL <- "ppsv-request@biochem.mpg.de"
PPSV_FACILITY_PHONE <- "+49 89 8578-3629"
PPSV_SCHEMA_VERSION <- 3L

PPSV_STATUS_OPTIONS <- c(
  "Submitted",
  "Under review",
  "Accepted",
  "In progress",
  "Awaiting requester input",
  "Completed",
  "Closed"
)

PPSV_SERVICE_MODULES <- data.frame(
  slug = c(
    "molecular-cloning",
    "host-repertoire",
    "large-scale-production",
    "protein-purification",
    "protein-analysis",
    "macromolecular-crystallisation",
    "x-ray-crystallography",
    "structure-modeling-validation"
  ),
  name = c(
    "Molecular cloning",
    "Host repertoire for expression optimization",
    "Large Scale Production",
    "Protein Purification",
    "Protein Analysis",
    "Macromolecular Crystallisation",
    "X-Ray Crystallography",
    "Structure Modeling and Validation"
  ),
  description = c(
    paste(
      "Molecular cloning assists you with access to a series of vectors and protocols",
      "for single - or multigene assembly. An online primer design tool is available",
      "for cloning into the parallel pCoofy vector series."
    ),
    paste(
      "With our expression host repertoire including bacteria, yeast, insect and",
      "mammalian cells we will identify the system most appropriate for your target",
      "protein. Parallel screening aims at achieving high expression levels of",
      "cytoplasmic or secreted proteins"
    ),
    paste(
      "We produce bacteria and yeast at high cell density in stirred tank reactors",
      "from 1 to 10 L including protocols for metabolic labelling. Insect and mammalian",
      "cells are cultivated in shake flasks up to 5 L scale."
    ),
    paste(
      "We establish a purification strategy for your target protein if no protocols",
      "are available. In addition to standard chromatography procedures (affinity,",
      "IEX and SEC) we apply special protocols like additive screens, protein refolding",
      "etc for difficult targets."
    ),
    paste(
      "As final quality control of the delivered protein, we routinely assess purity,",
      "intact mass and integrity / homogeneity by SDS-PAGE, LC-MS, DLS + analytical gel",
      "filtration. Additional characterization like CD-spectroscopy or nanoDSF is",
      "performed if required."
    ),
    "Automated Macromolecular cristallisation screening and optimisation",
    "We characterize macromolecular crystals using X-Ray Crystallography",
    paste(
      "We can refine build and validate macromolecular structures (X-ray and CryoEM).",
      "We can also support the depostion of structure to the Protein Data Bank."
    )
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
  display_order = seq_len(8L),
  stringsAsFactors = FALSE
)

PPSV_ADMIN_USERS <- data.frame(
  username = c("yeroslaviz", "basquin"),
  display_name = c("Assa Yeroslaviz", "Jerome Basquin"),
  email = c("yeroslaviz@biochem.mpg.de", "basquin@biochem.mpg.de"),
  stringsAsFactors = FALSE
)

PPSV_TECHNICIAN_USERS <- data.frame(
  username = c("grzejszc", "pleyer", "valer", "wehner", "yaoxiao", "piroddi"),
  display_name = c(
    "Michal Grzejszczyk", "Sabine Pleyer", "Karina Valer Saldana",
    "Anja Wehner", "Yao Xiao", "Attilio Piroddi"
  ),
  email = paste0(
    c("grzejszc", "pleyer", "valer", "wehner", "yaoxiao", "piroddi"),
    "@biochem.mpg.de"
  ),
  stringsAsFactors = FALSE
)

PPSV_RETRY_DELAYS_SECONDS <- c(0L, 5L * 60L, 30L * 60L, 2L * 3600L, 12L * 3600L, 24L * 3600L)

# Read non-secret runtime configuration. Callers may pass a named list of
# overrides, which is especially useful for tests and one-off administration.
ppsv_config <- function(overrides = list()) {
  app_dir <- normalizePath(
    Sys.getenv("PPSV_APP_DIR", getwd()),
    winslash = "/",
    mustWork = FALSE
  )
  config <- list(
    app_dir = app_dir,
    db_file = Sys.getenv("PPSV_DB_FILE", file.path(app_dir, "ppsv_projects.db")),
    pool_root = Sys.getenv("PPSV_POOL_ROOT", "/fs/pool/pool-ppsvf-projects"),
    pool_expected_source = Sys.getenv("PPSV_POOL_EXPECTED_SOURCE", ""),
    allow_local_pool = ppsv_env_flag("PPSV_ALLOW_LOCAL_POOL", FALSE),
    fallback_root = Sys.getenv("PPSV_FALLBACK_ROOT", "/srv/ppsv-app-data/uploads_pending_pool"),
    public_url = sub("/+$", "", Sys.getenv("PPSV_PUBLIC_URL", "https://ppcf-vm.biochem.mpg.de/ppsv-app/")),
    max_upload_mb = suppressWarnings(as.numeric(Sys.getenv("PPSV_MAX_UPLOAD_MB", "75"))),
    ticket_to = Sys.getenv("PPSV_TICKET_TO", PPSV_FACILITY_EMAIL),
    mail_from = Sys.getenv("PPSV_MAIL_FROM", "ppsv-service@biochem.mpg.de"),
    ticket_mode = tolower(Sys.getenv("PPSV_TICKET_MODE", "disabled")),
    direct_ack = ppsv_env_flag("PPSV_DIRECT_ACK", FALSE),
    service_identity_authorized = ppsv_env_flag("PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK", FALSE),
    ticket_e2e_test_ack = ppsv_env_flag("PPSV_TICKET_E2E_TEST_ACK", FALSE),
    smtp_host = Sys.getenv("PPSV_SMTP_HOST", ""),
    smtp_port = suppressWarnings(as.integer(Sys.getenv("PPSV_SMTP_PORT", "587"))),
    smtp_security = tolower(Sys.getenv("PPSV_SMTP_SECURITY", "starttls")),
    smtp_user = Sys.getenv("PPSV_SMTP_USER", ""),
    smtp_password = Sys.getenv("PPSV_SMTP_PASSWORD", ""),
    auth_mode = tolower(Sys.getenv("AUTH_MODE", "ldap")),
    logo_path = Sys.getenv("PPSV_LOGO_PATH", file.path(app_dir, "www", "ppsv-logo.png"))
  )
  config[names(overrides)] <- overrides

  if (!is.finite(config$max_upload_mb) || config$max_upload_mb <= 0) {
    stop("PPSV_MAX_UPLOAD_MB must be a positive number.", call. = FALSE)
  }
  if (is.na(config$smtp_port) || config$smtp_port < 1L || config$smtp_port > 65535L) {
    stop("PPSV_SMTP_PORT must be between 1 and 65535.", call. = FALSE)
  }
  if (!config$ticket_mode %in% c("disabled", "service_reply_to", "ldap_from")) {
    stop("PPSV_TICKET_MODE must be disabled, service_reply_to, or ldap_from.", call. = FALSE)
  }
  if (!config$smtp_security %in% c("none", "ssl", "starttls")) {
    stop("PPSV_SMTP_SECURITY must be none, ssl, or starttls.", call. = FALSE)
  }
  if (!config$auth_mode %in% c("ldap", "test")) {
    stop("AUTH_MODE must be ldap in production (test is accepted only by test harnesses).", call. = FALSE)
  }
  config
}
