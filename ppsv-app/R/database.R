# SQLite connection, versioned schema, immutable seeds, and identity sync.

ppsv_now <- function(time = Sys.time()) {
  format(as.POSIXct(time, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

ppsv_db_connect <- function(config = ppsv_config()) {
  if (!requireNamespace("DBI", quietly = TRUE) || !requireNamespace("RSQLite", quietly = TRUE)) {
    stop("DBI and RSQLite are required by the PPSV backend.", call. = FALSE)
  }
  directory <- dirname(config$db_file)
  if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE, mode = "0770")) {
    stop("Cannot create PPSV database directory: ", directory, call. = FALSE)
  }
  con <- DBI::dbConnect(RSQLite::SQLite(), config$db_file)
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON")
  DBI::dbExecute(con, "PRAGMA busy_timeout = 10000")
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  for (path in c(config$db_file, paste0(config$db_file, "-wal"), paste0(config$db_file, "-shm"))) {
    if (file.exists(path)) Sys.chmod(path, mode = "0660", use_umask = FALSE)
  }
  con
}

ppsv_db_transaction <- function(con, code, immediate = FALSE) {
  if (immediate) DBI::dbExecute(con, "BEGIN IMMEDIATE") else DBI::dbBegin(con)
  committed <- FALSE
  on.exit(if (!committed && DBI::dbIsValid(con)) try(DBI::dbRollback(con), silent = TRUE), add = TRUE)
  value <- force(code)
  DBI::dbCommit(con)
  committed <- TRUE
  value
}

ppsv_schema_statements_v1 <- function() {
  c(
    "CREATE TABLE schema_migrations (
       version INTEGER PRIMARY KEY,
       applied_at TEXT NOT NULL
     )",
    "CREATE TABLE sequence_counters (
       name TEXT PRIMARY KEY,
       next_value INTEGER NOT NULL CHECK (next_value >= 1)
     )",
    "CREATE TABLE users (
       username TEXT PRIMARY KEY COLLATE NOCASE,
       display_name TEXT,
       email TEXT,
       research_group TEXT,
       phone TEXT,
       role TEXT NOT NULL CHECK (role IN ('user','technician','admin')),
       active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
       ldap_email_verified INTEGER NOT NULL DEFAULT 0 CHECK (ldap_email_verified IN (0,1)),
       last_login_at TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL
     )",
    "CREATE TABLE service_modules (
       slug TEXT PRIMARY KEY,
       name TEXT NOT NULL UNIQUE,
       description TEXT NOT NULL,
       url TEXT NOT NULL,
       display_order INTEGER NOT NULL UNIQUE,
       active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
     )",
    "CREATE TABLE requests (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       request_code TEXT NOT NULL UNIQUE CHECK (request_code GLOB 'PPSV[0-9][0-9][0-9][0-9][0-9][0-9]'),
       request_kind TEXT NOT NULL CHECK (request_kind IN ('service','inquiry')),
       service_module_slug TEXT REFERENCES service_modules(slug),
       owner_username TEXT NOT NULL REFERENCES users(username) COLLATE NOCASE,
       assignee_username TEXT REFERENCES users(username) COLLATE NOCASE,
       contact_name TEXT NOT NULL,
       contact_email TEXT NOT NULL,
       contact_email_verified INTEGER NOT NULL DEFAULT 0 CHECK (contact_email_verified IN (0,1)),
       research_group TEXT NOT NULL,
       phone TEXT NOT NULL,
       billing_code TEXT,
       current_status TEXT NOT NULL,
       ticket_state TEXT NOT NULL DEFAULT 'queued',
       storage_state TEXT NOT NULL DEFAULT 'pool' CHECK (storage_state IN ('pool','fallback','none')),
       archived_at TEXT,
       archived_by TEXT REFERENCES users(username) COLLATE NOCASE,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       CHECK ((request_kind = 'service' AND service_module_slug IS NOT NULL AND length(billing_code) > 0)
          OR (request_kind = 'inquiry'))
     )",
    "CREATE TABLE protein_submissions (
       request_id INTEGER PRIMARY KEY REFERENCES requests(id) ON DELETE RESTRICT,
       protein_name TEXT NOT NULL,
       uniprot_id TEXT NOT NULL,
       source_organism TEXT NOT NULL,
       expression_construct TEXT NOT NULL,
       tags TEXT NOT NULL,
       expression_host TEXT NOT NULL,
       antibiotic_resistance TEXT NOT NULL,
       storage_buffer TEXT NOT NULL,
       references_previous_experiments TEXT NOT NULL,
       amount_required_mg REAL NOT NULL CHECK (amount_required_mg > 0),
       final_concentration_mg_ml REAL NOT NULL CHECK (final_concentration_mg_ml > 0),
       delivery_state TEXT NOT NULL CHECK (delivery_state IN ('Frozen','Unfrozen')),
       aliquot_size TEXT NOT NULL,
       size_uncleaved_da REAL CHECK (size_uncleaved_da IS NULL OR size_uncleaved_da > 0),
       size_cleaved_da REAL CHECK (size_cleaved_da IS NULL OR size_cleaved_da > 0),
       cleavage_size TEXT,
       sequence_uncleaved TEXT,
       sequence_cleaved TEXT,
       purification_strategy TEXT,
       tag_removal_required INTEGER CHECK (tag_removal_required IS NULL OR tag_removal_required IN (0,1)),
       localisation TEXT
     )",
    "CREATE TABLE inquiries (
       request_id INTEGER PRIMARY KEY REFERENCES requests(id) ON DELETE RESTRICT,
       related_service_module_slug TEXT REFERENCES service_modules(slug),
       subject TEXT NOT NULL,
       message TEXT NOT NULL
     )",
    "CREATE TABLE request_files (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       request_id INTEGER NOT NULL REFERENCES requests(id) ON DELETE RESTRICT,
       category TEXT NOT NULL CHECK (category IN ('inputs','results')),
       original_name TEXT NOT NULL,
       stored_name TEXT NOT NULL,
       mime_type TEXT,
       size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
       sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
       storage_location TEXT NOT NULL CHECK (storage_location IN ('pool','fallback')),
       absolute_path TEXT NOT NULL UNIQUE,
       uploaded_by TEXT NOT NULL REFERENCES users(username) COLLATE NOCASE,
       archived_at TEXT,
       archived_by TEXT REFERENCES users(username) COLLATE NOCASE,
       created_at TEXT NOT NULL,
       UNIQUE (request_id, stored_name)
     )",
    "CREATE TABLE status_history (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       request_id INTEGER NOT NULL REFERENCES requests(id) ON DELETE RESTRICT,
       old_status TEXT,
       new_status TEXT NOT NULL,
       note TEXT,
       changed_by TEXT NOT NULL REFERENCES users(username) COLLATE NOCASE,
       changed_at TEXT NOT NULL
     )",
    "CREATE TABLE mail_outbox (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       request_id INTEGER NOT NULL REFERENCES requests(id) ON DELETE RESTRICT,
       message_kind TEXT NOT NULL CHECK (message_kind IN ('ticket','acknowledgement')),
       recipient TEXT,
       from_address TEXT NOT NULL,
       reply_to TEXT,
       subject TEXT NOT NULL,
       body TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('pending','sending','sent','failed','suppressed')),
       attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
       next_attempt_at TEXT,
       sent_at TEXT,
       last_error TEXT,
       ticket_url TEXT,
       dedupe_key TEXT NOT NULL UNIQUE,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL
     )",
    "CREATE TABLE mail_attempts (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       outbox_id INTEGER NOT NULL REFERENCES mail_outbox(id) ON DELETE RESTRICT,
       attempt_number INTEGER NOT NULL,
       attempted_at TEXT NOT NULL,
       succeeded INTEGER NOT NULL CHECK (succeeded IN (0,1)),
       error_message TEXT
     )",
    "CREATE INDEX idx_requests_owner ON requests(owner_username, archived_at, updated_at)",
    "CREATE INDEX idx_requests_assignee ON requests(assignee_username, archived_at, updated_at)",
    "CREATE INDEX idx_status_history_request ON status_history(request_id, changed_at)",
    "CREATE INDEX idx_files_request ON request_files(request_id, archived_at)",
    "CREATE INDEX idx_outbox_due ON mail_outbox(status, next_attempt_at)",
    "INSERT INTO sequence_counters(name, next_value) VALUES ('request', 1)"
  )
}

ppsv_apply_migration_v1 <- function(con) {
  for (sql in ppsv_schema_statements_v1()) DBI::dbExecute(con, sql)
  DBI::dbExecute(
    con,
    "INSERT INTO schema_migrations(version, applied_at) VALUES (1, ?)",
    params = list(ppsv_now())
  )
}

ppsv_apply_migration_v2 <- function(con) {
  DBI::dbExecute(
    con,
    "ALTER TABLE users ADD COLUMN ldap_name_verified INTEGER NOT NULL DEFAULT 0 CHECK (ldap_name_verified IN (0,1))"
  )
  allowed <- paste(sprintf("'%s'", PPSV_STATUS_OPTIONS), collapse = ",")
  DBI::dbExecute(
    con,
    sprintf(
      paste(
        "CREATE TRIGGER requests_status_insert BEFORE INSERT ON requests",
        "WHEN NEW.current_status NOT IN (%s)",
        "BEGIN SELECT RAISE(ABORT,'invalid PPSV status'); END"
      ),
      allowed
    )
  )
  DBI::dbExecute(
    con,
    sprintf(
      paste(
        "CREATE TRIGGER requests_status_update BEFORE UPDATE OF current_status ON requests",
        "WHEN NEW.current_status NOT IN (%s)",
        "BEGIN SELECT RAISE(ABORT,'invalid PPSV status'); END"
      ),
      allowed
    )
  )
  DBI::dbExecute(
    con,
    sprintf(
      paste(
        "CREATE TRIGGER status_history_value BEFORE INSERT ON status_history",
        "WHEN NEW.new_status NOT IN (%s) OR (NEW.old_status IS NOT NULL AND NEW.old_status NOT IN (%s))",
        "BEGIN SELECT RAISE(ABORT,'invalid PPSV status history'); END"
      ),
      allowed,
      allowed
    )
  )
  DBI::dbExecute(
    con,
    "INSERT INTO schema_migrations(version, applied_at) VALUES (2, ?)",
    params = list(ppsv_now())
  )
}

ppsv_apply_migration_v3 <- function(con) {
  DBI::dbExecute(
    con,
    "ALTER TABLE requests ADD COLUMN contact_name_verified INTEGER NOT NULL DEFAULT 0 CHECK (contact_name_verified IN (0,1))"
  )
  DBI::dbExecute(
    con,
    "INSERT INTO schema_migrations(version, applied_at) VALUES (3, ?)",
    params = list(ppsv_now())
  )
}

ppsv_seed_reference_data <- function(con) {
  module_sql <- paste(
    "INSERT INTO service_modules(slug,name,description,url,display_order,active)",
    "VALUES (?,?,?,?,?,1)",
    "ON CONFLICT(slug) DO UPDATE SET name=excluded.name, description=excluded.description,",
    "url=excluded.url, display_order=excluded.display_order, active=1"
  )
  for (i in seq_len(nrow(PPSV_SERVICE_MODULES))) {
    row <- PPSV_SERVICE_MODULES[i, ]
    DBI::dbExecute(con, module_sql, params = unname(as.list(row)))
  }

  seed_users <- rbind(
    transform(PPSV_ADMIN_USERS, role = "admin"),
    transform(PPSV_TECHNICIAN_USERS, role = "technician")
  )
  user_sql <- paste(
    "INSERT INTO users(username,display_name,email,role,active,ldap_email_verified,ldap_name_verified,created_at,updated_at)",
    "VALUES (?,?,?,?,1,0,0,?,?)",
    "ON CONFLICT(username) DO UPDATE SET role=excluded.role,updated_at=excluded.updated_at"
  )
  now <- ppsv_now()
  for (i in seq_len(nrow(seed_users))) {
    row <- seed_users[i, ]
    DBI::dbExecute(
      con,
      user_sql,
      params = list(row$username, row$display_name, row$email, row$role, now, now)
    )
  }

  # Repair any manually altered/stale role values. Privileges always derive
  # from the checked-in allowlist, never from b_profa or an editable column.
  all_staff <- tolower(c(PPSV_ADMIN_USERS$username, PPSV_TECHNICIAN_USERS$username))
  placeholders <- paste(rep("?", length(all_staff)), collapse = ",")
  DBI::dbExecute(
    con,
    sprintf("UPDATE users SET role='user',updated_at=? WHERE lower(username) NOT IN (%s)", placeholders),
    params = c(list(now), as.list(all_staff))
  )
}

# Resolve a caller-supplied principal against the database before every public
# action. This prevents forged role/active fields and invalidates live sessions
# immediately after an administrator deactivates an account.
ppsv_actor_from_connection <- function(con, user) {
  supplied <- ppsv_user_as_list(user)
  row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM users WHERE username=?",
    params = list(supplied$username)
  )
  if (!nrow(row)) {
    ppsv_abort("The authenticated PPSV user is not registered.", "ppsv_authentication_error")
  }
  actor <- as.list(row[1L, , drop = FALSE])
  actor$role <- ppsv_role_for_username(actor$username)
  if (!identical(as.integer(actor$active), 1L)) {
    ppsv_abort("This PPSV account is inactive.", "ppsv_authentication_error")
  }
  actor
}

# Initialize only an empty/new PPSV database. An existing non-PPSV database is
# rejected, which prevents accidental deployment of the copied MS database.
ppsv_initialize_database <- function(config = ppsv_config(), reset = FALSE) {
  if (isTRUE(reset) && file.exists(config$db_file)) {
    if (!file.remove(config$db_file)) stop("Could not reset database: ", config$db_file, call. = FALSE)
    for (suffix in c("-wal", "-shm")) {
      sidecar <- paste0(config$db_file, suffix)
      if (file.exists(sidecar)) file.remove(sidecar)
    }
  }
  con <- ppsv_db_connect(config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  tables <- DBI::dbListTables(con)
  if (length(tables) && !"schema_migrations" %in% tables) {
    stop(
      "Refusing to migrate an unrecognized/legacy database. Configure a fresh PPSV_DB_FILE.",
      call. = FALSE
    )
  }
  ppsv_db_transaction(con, {
    if (!"schema_migrations" %in% DBI::dbListTables(con)) ppsv_apply_migration_v1(con)
    version <- DBI::dbGetQuery(con, "SELECT COALESCE(MAX(version),0) AS version FROM schema_migrations")$version[[1L]]
    if (identical(as.integer(version), 1L)) {
      ppsv_apply_migration_v2(con)
      version <- 2L
    }
    if (identical(as.integer(version), 2L)) {
      ppsv_apply_migration_v3(con)
      version <- 3L
    }
    if (!identical(as.integer(version), PPSV_SCHEMA_VERSION)) {
      stop("Unsupported PPSV database schema version: ", version, call. = FALSE)
    }
    ppsv_seed_reference_data(con)
  }, immediate = TRUE)
  Sys.chmod(config$db_file, mode = "0660", use_umask = FALSE)
  normalizePath(config$db_file, winslash = "/", mustWork = TRUE)
}

ppsv_allocate_request_code_in_transaction <- function(con) {
  current <- DBI::dbGetQuery(
    con,
    "SELECT next_value FROM sequence_counters WHERE name='request'"
  )$next_value
  if (length(current) != 1L || current[[1L]] > 999999L) {
    stop("PPSV request sequence is missing or exhausted.", call. = FALSE)
  }
  changed <- DBI::dbExecute(
    con,
    "UPDATE sequence_counters SET next_value = next_value + 1 WHERE name='request' AND next_value=?",
    params = list(as.integer(current[[1L]]))
  )
  if (!identical(changed, 1L)) stop("Could not reserve a PPSV request number.", call. = FALSE)
  sprintf("PPSV%06d", as.integer(current[[1L]]))
}

ppsv_allocate_request_code <- function(ctx = ppsv_default_context()) {
  con <- ppsv_db_connect(ctx$config)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  ppsv_db_transaction(con, ppsv_allocate_request_code_in_transaction(con), immediate = TRUE)
}

ppsv_sync_user <- function(con, identity, login = TRUE) {
  identity <- ppsv_user_as_list(identity)
  username <- identity$username
  role <- ppsv_role_for_username(username)
  existing <- DBI::dbGetQuery(con, "SELECT * FROM users WHERE username=?", params = list(username))
  now <- ppsv_now()
  display_name <- ppsv_scalar(identity$display_name)
  email <- tolower(ppsv_scalar(identity$email))
  verified <- isTRUE(as.logical(identity$ldap_email_verified)) && ppsv_valid_email(email)
  name_verified <- isTRUE(as.logical(identity$ldap_name_verified)) && nzchar(display_name)
  research_group <- ppsv_scalar(identity$research_group)
  phone <- ppsv_scalar(identity$phone)

  if (!nrow(existing)) {
    DBI::dbExecute(
      con,
      paste(
        "INSERT INTO users(username,display_name,email,research_group,phone,role,active,",
        "ldap_email_verified,ldap_name_verified,last_login_at,created_at,updated_at)",
        "VALUES (?,?,?,?,?,?,1,?,?,?,?,?)"
      ),
      params = list(
        username, display_name, if (nzchar(email)) email else NA_character_,
        research_group, phone, role, as.integer(verified), as.integer(name_verified),
        if (login) now else NA_character_, now, now
      )
    )
  } else {
    old <- existing[1L, ]
    if (!nzchar(display_name)) display_name <- old$display_name %||% ""
    # An LDAP login without a mail attribute must remain visibly unverified.
    # The prior cached address may be retained for the directory, but it must
    # never become a mail header or acknowledgement recipient for this login.
    if (!nzchar(email)) email <- old$email %||% ""
    if (!nzchar(research_group)) research_group <- old$research_group %||% ""
    if (!nzchar(phone)) phone <- old$phone %||% ""
    DBI::dbExecute(
      con,
      paste(
        "UPDATE users SET display_name=?,email=?,research_group=?,phone=?,role=?,",
        "ldap_email_verified=?,ldap_name_verified=?,",
        "last_login_at=CASE WHEN ? THEN ? ELSE last_login_at END,updated_at=?",
        "WHERE username=?"
      ),
      params = list(
        display_name, email, research_group, phone, role, as.integer(verified), as.integer(name_verified),
        as.integer(login), now, now, username
      )
    )
  }
  as.list(DBI::dbGetQuery(con, "SELECT * FROM users WHERE username=?", params = list(username))[1L, ])
}
