library(shiny)

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0L) y else x
}

scalar_text <- function(x, default = "") {
  if (is.null(x) || length(x) == 0L || is.na(x[[1L]])) return(default)
  as.character(x[[1L]])
}

trim_scalar <- function(x, default = "") trimws(scalar_text(x, default))

is_truthy <- function(x) {
  tolower(trim_scalar(x)) %in% c("1", "true", "yes", "on")
}

options(
  shiny.maxRequestSize = suppressWarnings(
    as.numeric(Sys.getenv("PPSV_MAX_UPLOAD_MB", "75")) * 1024^2
  )
)

# Backend files own persistence, validation, authorization, storage, mail and PDF
# generation. Keeping them under R/ makes this entrypoint intentionally thin.
backend_source_errors <- character()
backend_loader <- file.path("R", "load_backend.R")
backend_files <- if (file.exists(backend_loader)) {
  backend_loader
} else {
  sort(list.files("R", pattern = "\\.[Rr]$", full.names = TRUE))
}
for (backend_file in backend_files) {
  tryCatch(
    sys.source(backend_file, envir = .GlobalEnv),
    error = function(error) {
      backend_source_errors <<- c(
        backend_source_errors,
        sprintf("%s: %s", basename(backend_file), conditionMessage(error))
      )
    }
  )
}

backend_exists <- function(name) {
  is.function(get0(name, mode = "function", inherits = TRUE))
}

app_context <- NULL
startup_error <- NULL
if (backend_exists("ppsv_initialize")) {
  app_context <- tryCatch(
    {
      config <- if (backend_exists("ppsv_config")) ppsv_config() else NULL
      ppsv_initialize(config = config, initialize_db = TRUE)
    },
    error = function(error) {
      startup_error <<- conditionMessage(error)
      NULL
    }
  )
} else {
  startup_error <- "PPSV backend modules are not available."
}

backend_call <- function(name, ..., .default = NULL, .required = TRUE) {
  fn <- get0(name, mode = "function", inherits = TRUE)
  if (!is.function(fn)) {
    if (.required) stop(sprintf("Backend function '%s' is unavailable.", name), call. = FALSE)
    return(.default)
  }

  args <- list(...)
  fn_formals <- names(formals(fn))
  if (!is.null(app_context) && "ctx" %in% fn_formals && !"ctx" %in% names(args)) {
    args$ctx <- app_context
  }
  if (!"..." %in% fn_formals) {
    args <- args[names(args) %in% fn_formals]
  }
  do.call(fn, args)
}

PPSV_STATUSES <- c(
  "Submitted",
  "Under review",
  "Accepted",
  "In progress",
  "Awaiting requester input",
  "Completed",
  "Closed"
)

PPSV_MODULES <- data.frame(
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
  description = c(
    "Molecular cloning assists you with access to a series of vectors and protocols for single- or multigene assembly. An online primer design tool is available for cloning into the parallel pCoofy vector series.",
    "With our expression host repertoire including bacteria, yeast, insect and mammalian cells we will identify the system most appropriate for your target protein. Parallel screening aims at achieving high expression levels of cytoplasmic or secreted proteins.",
    "We produce bacteria and yeast at high cell density in stirred tank reactors from 1 to 10 L including protocols for metabolic labelling. Insect and mammalian cells are cultivated in shake flasks up to 5 L scale.",
    "We establish a purification strategy for your target protein if no protocols are available. In addition to standard chromatography procedures (affinity, IEX and SEC) we apply special protocols like additive screens and protein refolding for difficult targets.",
    "As final quality control of the delivered protein, we routinely assess purity, intact mass and integrity or homogeneity by SDS-PAGE, LC-MS, DLS and analytical gel filtration. Additional characterization like CD-spectroscopy or nanoDSF is performed if required.",
    "Automated macromolecular crystallisation screening and optimisation.",
    "We characterize macromolecular crystals using X-Ray Crystallography.",
    "We can refine, build and validate macromolecular structures (X-ray and CryoEM). We can also support the deposition of structures to the Protein Data Bank."
  ),
  stringsAsFactors = FALSE
)

# The checked-in backend catalogue is canonical. This local table remains only
# as a startup fallback so a database failure is visible rather than silently
# changing service wording or order.
if (exists("PPSV_SERVICE_MODULES", inherits = TRUE)) {
  PPSV_MODULES <- PPSV_SERVICE_MODULES[, c("slug", "name", "url", "description"), drop = FALSE]
}

SERVICE_FIELD_KEYS <- c(
  "contact_name", "contact_email", "research_group", "phone", "billing_code",
  "protein_name", "uniprot_id", "source_organism", "expression_construct",
  "tags", "expression_host", "antibiotic_resistance", "storage_buffer",
  "references_previous_experiments", "amount_required_mg",
  "final_concentration_mg_ml", "delivery_state", "aliquot_size",
  "size_uncleaved_da", "size_cleaved_da", "cleavage_size",
  "sequence_uncleaved", "sequence_cleaved", "purification_strategy",
  "tag_removal_required", "localisation"
)

INQUIRY_FIELD_KEYS <- c(
  "contact_name", "contact_email", "research_group", "phone",
  "related_service_module_slug", "inquiry_subject", "inquiry_message"
)

record_list <- function(value) {
  if (is.null(value)) return(list())
  if (is.data.frame(value)) {
    if (nrow(value) == 0L) return(list())
    return(as.list(value[1L, , drop = FALSE]))
  }
  if (is.list(value)) return(value)
  list(value = value)
}

field_value <- function(record, key, default = "") {
  record <- record_list(record)
  value <- record[[key]]
  if (is.null(value) && is.list(record$details)) value <- record$details[[key]]
  if (is.null(value) && is.list(record$submission)) value <- record$submission[[key]]
  if (is.null(value) && is.list(record$inquiry)) value <- record$inquiry[[key]]
  scalar_text(value, default)
}

user_field <- function(user, ..., default = "") {
  user <- record_list(user)
  keys <- c(...)
  for (key in keys) {
    value <- user[[key]]
    if (!is.null(value) && length(value) > 0L && !is.na(value[[1L]]) && nzchar(trimws(as.character(value[[1L]])))) {
      return(as.character(value[[1L]]))
    }
  }
  default
}

normalize_role <- function(user) {
  role <- tolower(user_field(user, "role", default = "user"))
  if (!role %in% c("user", "technician", "admin")) "user" else role
}

request_identifier <- function(request) {
  first <- field_value(request, "id")
  if (nzchar(first)) return(first)
  field_value(request, "request_code", field_value(request, "code"))
}

request_code <- function(request) {
  first <- field_value(request, "request_code")
  if (nzchar(first)) return(first)
  field_value(request, "code", request_identifier(request))
}

required_label <- function(text) {
  tags$span(text, tags$span(" *", class = "required-mark", `aria-hidden` = "true"))
}

text_control <- function(id, label, value = "", required = FALSE, placeholder = NULL, help = NULL) {
  tagList(
    textInput(
      id,
      if (required) required_label(label) else label,
      value = scalar_text(value),
      placeholder = placeholder
    ),
    if (!is.null(help)) tags$p(help, class = "field-help")
  )
}

area_control <- function(id, label, value = "", required = FALSE, placeholder = NULL, rows = 4L, help = NULL) {
  tagList(
    textAreaInput(
      id,
      if (required) required_label(label) else label,
      value = scalar_text(value),
      placeholder = placeholder,
      rows = rows,
      width = "100%"
    ),
    if (!is.null(help)) tags$p(help, class = "field-help")
  )
}

number_control <- function(id, label, value = NULL, required = FALSE, help = NULL) {
  numeric_value <- suppressWarnings(as.numeric(scalar_text(value, NA_character_)))
  if (!is.finite(numeric_value)) numeric_value <- NA_real_
  tagList(
    numericInput(
      id,
      if (required) required_label(label) else label,
      value = numeric_value,
      min = 0,
      step = "any"
    ),
    if (!is.null(help)) tags$p(help, class = "field-help")
  )
}

readonly_identity_control <- function(id, label, value, verified = TRUE) {
  value <- scalar_text(value)
  if (!nzchar(value) || !isTRUE(verified)) {
    return(tagList(
      text_control(id, label, value, required = TRUE),
      tags$p("This value was not verified by LDAP. Staff will see it as unverified.", class = "field-help warning-text")
    ))
  }
  tags$div(
    class = "form-group",
    tags$label(required_label(label), `for` = id),
    tags$input(
      id = id,
      type = "text",
      class = "form-control identity-readonly",
      value = value,
      readonly = "readonly",
      `aria-readonly` = "true"
    ),
    tags$p(icon("lock"), " Verified by your institute account", class = "field-help verified-text")
  )
}

contact_fields_ui <- function(prefix, user, values = list(), include_billing = TRUE) {
  user <- record_list(user)
  values <- record_list(values)
  name_value <- field_value(values, "contact_name", user_field(user, "display_name", "name", "full_name", "username"))
  email_value <- field_value(values, "contact_email", user_field(user, "email", "mail"))
  name_verified <- is_truthy(user_field(user, "ldap_name_verified", default = "false")) &&
    nzchar(user_field(user, "display_name", "name", "full_name"))
  email_verified <- is_truthy(user_field(user, "email_verified", "ldap_email_verified", default = "false")) &&
    nzchar(user_field(user, "email", "mail"))

  tags$section(
    class = "form-section",
    tags$div(
      class = "section-heading",
      tags$span(class = "step-number", "1"),
      tags$div(tags$h3("Contact details"), tags$p("Who should the PPSV team contact about this request?"))
    ),
    fluidRow(
      column(6, readonly_identity_control(paste0(prefix, "contact_name"), "Name", name_value, name_verified)),
      column(6, readonly_identity_control(paste0(prefix, "contact_email"), "E-mail", email_value, email_verified))
    ),
    fluidRow(
      column(6, text_control(paste0(prefix, "research_group"), "Research group", field_value(values, "research_group", user_field(user, "research_group", "department")), required = TRUE)),
      column(6, text_control(paste0(prefix, "phone"), "Phone", field_value(values, "phone", user_field(user, "phone", "telephone")), required = TRUE))
    ),
    if (include_billing) fluidRow(
      column(6, text_control(paste0(prefix, "billing_code"), "Billing code", field_value(values, "billing_code"), required = TRUE)),
      column(6, tags$div(class = "context-note", icon("circle-info"), "A billing code is collected for project attribution; this application does not calculate costs."))
    )
  )
}

service_fields_ui <- function(prefix = "", values = list()) {
  values <- record_list(values)
  tag_removal_selected <- switch(
    tolower(field_value(values, "tag_removal_required")),
    `1` = "Yes", `true` = "Yes", `yes` = "Yes",
    `0` = "No", `false` = "No", `no` = "No",
    ""
  )
  tags$section(
    class = "form-section",
    tags$div(
      class = "section-heading",
      tags$span(class = "step-number", "2"),
      tags$div(tags$h3("Protein and request details"), tags$p("Fields marked with an asterisk are required. Enter N/A only when a field is genuinely not applicable."))
    ),
    fluidRow(
      column(6, text_control(paste0(prefix, "protein_name"), "Protein name", field_value(values, "protein_name"), required = TRUE)),
      column(6, text_control(paste0(prefix, "uniprot_id"), "UniProt ID", field_value(values, "uniprot_id"), required = TRUE))
    ),
    fluidRow(
      column(6, text_control(paste0(prefix, "source_organism"), "Source organism", field_value(values, "source_organism"), required = TRUE)),
      column(6, text_control(paste0(prefix, "expression_host"), "Expression host", field_value(values, "expression_host"), required = TRUE))
    ),
    area_control(paste0(prefix, "expression_construct"), "Expression construct", field_value(values, "expression_construct"), required = TRUE, rows = 3),
    fluidRow(
      column(6, text_control(paste0(prefix, "tags"), "Tag(s)", field_value(values, "tags"), required = TRUE)),
      column(6, text_control(paste0(prefix, "antibiotic_resistance"), "Antibiotic resistance", field_value(values, "antibiotic_resistance"), required = TRUE))
    ),
    area_control(paste0(prefix, "storage_buffer"), "Storage buffer", field_value(values, "storage_buffer"), required = TRUE, rows = 3),
    area_control(
      paste0(prefix, "references_previous_experiments"),
      "References / previous experiments",
      field_value(values, "references_previous_experiments"),
      required = TRUE,
      rows = 4
    ),
    fluidRow(
      column(6, number_control(paste0(prefix, "amount_required_mg"), "Amount required (mg)", field_value(values, "amount_required_mg"), required = TRUE)),
      column(6, number_control(paste0(prefix, "final_concentration_mg_ml"), "Final concentration required (mg/mL)", field_value(values, "final_concentration_mg_ml"), required = TRUE))
    ),
    fluidRow(
      column(6, selectInput(
        paste0(prefix, "delivery_state"),
        required_label("To be delivered frozen / unfrozen"),
        choices = c("Choose delivery state" = "", "Frozen" = "Frozen", "Unfrozen" = "Unfrozen"),
        selected = field_value(values, "delivery_state")
      )),
      column(6, text_control(
        paste0(prefix, "aliquot_size"),
        "Aliquot size",
        field_value(values, "aliquot_size"),
        required = TRUE,
        placeholder = "Include value and unit, e.g. 100 µL",
        help = "Include the unit."
      ))
    ),
    tags$details(
      class = "optional-fields",
      tags$summary(tags$span("Optional protein details"), tags$span("8 optional fields", class = "summary-badge")),
      tags$div(
        class = "optional-fields-body",
        fluidRow(
          column(6, number_control(paste0(prefix, "size_uncleaved_da"), "Size uncleaved (Da)", field_value(values, "size_uncleaved_da"))),
          column(6, number_control(paste0(prefix, "size_cleaved_da"), "Size cleaved (Da)", field_value(values, "size_cleaved_da")))
        ),
        fluidRow(
          column(6, text_control(
            paste0(prefix, "cleavage_size"),
            "Cleavage Size",
            field_value(values, "cleavage_size"),
            placeholder = "Include value and unit or explanatory text",
            help = "The source form does not define a unit; include one where relevant."
          )),
          column(6, selectInput(
            paste0(prefix, "tag_removal_required"),
            "Tag removal required?",
            choices = c("Not specified" = "", "Yes" = "Yes", "No" = "No"),
            selected = tag_removal_selected
          ))
        ),
        area_control(paste0(prefix, "sequence_uncleaved"), "Sequence (uncleaved)", field_value(values, "sequence_uncleaved"), rows = 5),
        area_control(paste0(prefix, "sequence_cleaved"), "Sequence (cleaved)", field_value(values, "sequence_cleaved"), rows = 5),
        area_control(paste0(prefix, "purification_strategy"), "Purification strategy", field_value(values, "purification_strategy"), rows = 4),
        text_control(paste0(prefix, "localisation"), "Localisation", field_value(values, "localisation"))
      )
    )
  )
}

inquiry_fields_ui <- function(prefix = "", values = list()) {
  values <- record_list(values)
  module_choices <- setNames(PPSV_MODULES$slug, PPSV_MODULES$name)
  tags$section(
    class = "form-section",
    tags$div(
      class = "section-heading",
      tags$span(class = "step-number", "2"),
      tags$div(tags$h3("Your question"), tags$p("Share enough context for the PPSV team to route your inquiry."))
    ),
    selectInput(
      paste0(prefix, "related_service_module_slug"),
      "Related service (optional)",
      choices = c("Not sure / no specific service" = "", module_choices),
      selected = field_value(values, "related_service_module_slug")
    ),
    text_control(paste0(prefix, "inquiry_subject"), "Subject", field_value(values, "inquiry_subject"), required = TRUE),
    area_control(
      paste0(prefix, "inquiry_message"),
      "Question or consultation request",
      field_value(values, "inquiry_message"),
      required = TRUE,
      rows = 8,
      placeholder = "Describe the problem, your goal, and any timing constraints."
    )
  )
}

module_card <- function(module, compact = FALSE) {
  module_url <- trim_scalar(module$url)
  safe_url <- grepl("^https://", module_url, ignore.case = TRUE)
  tags$article(
    class = paste("service-card", if (compact) "service-card-compact" else ""),
    tags$div(class = "service-number", scalar_text(module$order, "")),
    tags$div(
      class = "service-copy",
      tags$h3(scalar_text(module$name)),
      tags$p(scalar_text(module$description)),
      if (safe_url) tags$a(
        "Read about this service ", icon("arrow-up-right-from-square"),
        href = module_url, target = "_blank", rel = "noopener noreferrer",
        class = "service-link"
      )
    )
  )
}

module_from_slug <- function(slug) {
  index <- match(trim_scalar(slug), PPSV_MODULES$slug)
  if (is.na(index)) return(NULL)
  module <- as.list(PPSV_MODULES[index, , drop = FALSE])
  module$order <- index
  module
}

safe_module_data <- function() {
  result <- tryCatch(
    backend_call("list_service_modules", .required = FALSE, .default = NULL),
    error = function(error) NULL
  )
  if (!is.data.frame(result) || nrow(result) != 8L) return(PPSV_MODULES)
  required <- c("slug", "name", "url", "description")
  if (!all(required %in% names(result))) return(PPSV_MODULES)
  result
}

nav_link <- function(id, label, icon_name, active = FALSE) {
  actionLink(
    id,
    tagList(icon(icon_name), tags$span(label)),
    class = paste("side-nav-link", if (active) "active" else "")
  )
}

status_badge <- function(status) {
  key <- gsub("[^a-z]+", "-", tolower(trim_scalar(status)))
  tags$span(trim_scalar(status, "Unknown"), class = paste("status-badge", paste0("status-", key)))
}

empty_state <- function(icon_name, title, message, action = NULL) {
  tags$div(
    class = "empty-state",
    icon(icon_name),
    tags$h3(title),
    tags$p(message),
    action
  )
}

public_ui <- fluidPage(
  tags$head(
    tags$title("PPSV project management"),
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    includeCSS("styles.css")
  ),
  uiOutput("app_root")
)

server <- function(input, output, session) {
  active_page <- reactiveVal("dashboard")
  identity <- reactiveVal(NULL)
  identity_error <- reactiveVal(NULL)
  requests_data <- reactiveVal(data.frame())
  users_data <- reactiveVal(data.frame())
  staff_data <- reactiveVal(data.frame())
  selected_request_id <- reactiveVal(NULL)
  selected_request <- reactiveVal(NULL)
  flash_error <- reactiveVal(NULL)

  request_headers <- function() {
    if (!is.null(app_context) && identical(app_context$config$auth_mode, "test")) {
      return(list(
        HTTP_X_REMOTE_USER = Sys.getenv("PPSV_TEST_USER", "testuser"),
        HTTP_X_REMOTE_NAME = Sys.getenv("PPSV_TEST_NAME", "PPSV Test User"),
        HTTP_X_REMOTE_EMAIL = Sys.getenv("PPSV_TEST_EMAIL", "testuser@example.org"),
        HTTP_X_REMOTE_GROUP = Sys.getenv("PPSV_TEST_GROUP", "Test research group"),
        HTTP_X_REMOTE_PHONE = Sys.getenv("PPSV_TEST_PHONE", "+49 000")
      ))
    }
    list(
      HTTP_X_REMOTE_USER = session$request$HTTP_X_REMOTE_USER %||% NULL,
      REMOTE_USER = session$request$REMOTE_USER %||% NULL,
      HTTP_X_REMOTE_NAME = session$request$HTTP_X_REMOTE_NAME %||% NULL,
      HTTP_X_REMOTE_EMAIL = session$request$HTTP_X_REMOTE_EMAIL %||% NULL,
      HTTP_X_REMOTE_GROUP = session$request$HTTP_X_REMOTE_GROUP %||% NULL,
      HTTP_X_REMOTE_PHONE = session$request$HTTP_X_REMOTE_PHONE %||% NULL
    )
  }

  remote_username <- function() {
    if (!is.null(app_context) && identical(app_context$config$auth_mode, "test")) {
      return(tolower(trim_scalar(Sys.getenv("PPSV_TEST_USER", "testuser"))))
    }
    candidates <- c(
      scalar_text(session$request$HTTP_X_REMOTE_USER),
      scalar_text(session$request$REMOTE_USER)
    )
    candidates <- trimws(candidates[nzchar(trimws(candidates))])
    if (length(candidates) == 0L) return("")
    username <- candidates[[1L]]
    if (grepl(",", username, fixed = TRUE)) username <- trimws(strsplit(username, ",", fixed = TRUE)[[1L]][[1L]])
    username <- sub("^.*\\\\", "", username)
    username <- sub("@.*$", "", username)
    if (!grepl("^[A-Za-z0-9._-]+$", username)) return("")
    tolower(username)
  }

  load_identity <- function() {
    username <- remote_username()
    if (!nzchar(username)) {
      identity(NULL)
      identity_error("No authenticated LDAP identity was supplied by Apache.")
      return(invisible(NULL))
    }
    test_mode <- !is.null(app_context) && identical(app_context$config$auth_mode, "test")
    user <- tryCatch(
      backend_call(
        "current_user",
        username = if (test_mode) username else NULL,
        headers = request_headers()
      ),
      error = function(error) {
        identity_error(conditionMessage(error))
        NULL
      }
    )
    identity(user)
    if (!is.null(user)) identity_error(NULL)
    invisible(user)
  }

  load_identity()

  call_with_notice <- function(expr, success = NULL, refresh = TRUE) {
    tryCatch(
      {
        value <- force(expr)
        flash_error(NULL)
        if (!is.null(success)) showNotification(success, type = "message", duration = 5)
        if (refresh) refresh_requests()
        value
      },
      error = function(error) {
        message <- conditionMessage(error)
        flash_error(message)
        showNotification(message, type = "error", duration = 8)
        NULL
      }
    )
  }

  can_do <- function(action, request = NULL, default = FALSE) {
    user <- identity()
    if (is.null(user)) return(FALSE)
    tryCatch(
      isTRUE(backend_call("can", user = user, action = action, request = request)),
      error = function(error) default
    )
  }

  require_permission <- function(action, request = NULL) {
    if (!can_do(action, request)) stop("You are not authorized to perform this action.", call. = FALSE)
    invisible(TRUE)
  }

  refresh_requests <- function() {
    user <- identity()
    if (is.null(user)) return(invisible(NULL))
    result <- tryCatch(
      backend_call(
        "list_requests",
        user = user,
        include_archived = identical(normalize_role(user), "admin") && isTRUE(input$show_archived)
      ),
      error = function(error) {
        flash_error(conditionMessage(error))
        data.frame()
      }
    )
    if (is.null(result)) result <- data.frame()
    if (is.list(result) && !is.data.frame(result) && !is.null(result$requests)) result <- result$requests
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    requests_data(result)
    invisible(result)
  }

  refresh_users <- function() {
    if (!can_do("view_users")) return(invisible(NULL))
    result <- tryCatch(
      backend_call("list_users", user = identity()),
      error = function(error) data.frame()
    )
    if (is.list(result) && !is.data.frame(result) && !is.null(result$users)) result <- result$users
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    users_data(result)
    invisible(result)
  }

  refresh_staff <- function() {
    user <- identity()
    if (is.null(user) || !normalize_role(user) %in% c("technician", "admin")) {
      return(invisible(NULL))
    }
    result <- tryCatch(
      backend_call("list_assignable_staff", user = user),
      error = function(error) data.frame()
    )
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    staff_data(result)
    invisible(result)
  }

  refresh_detail <- function() {
    id <- selected_request_id()
    if (is.null(id) || !nzchar(scalar_text(id))) {
      selected_request(NULL)
      return(invisible(NULL))
    }
    detail <- tryCatch(
      backend_call("get_request", id = id, user = identity()),
      error = function(error) {
        showNotification(conditionMessage(error), type = "error")
        NULL
      }
    )
    selected_request(detail)
    invisible(detail)
  }

  observeEvent(identity(), {
    if (!is.null(identity())) {
      refresh_requests()
      if (normalize_role(identity()) %in% c("technician", "admin")) refresh_staff()
      if (normalize_role(identity()) == "admin") refresh_users()
    }
  }, ignoreInit = FALSE)

  observeEvent(input$nav_dashboard, active_page("dashboard"))
  observeEvent(input$nav_create, active_page("create"))
  observeEvent(input$nav_users, {
    require_permission("view_users")
    refresh_users()
    active_page("users")
  })
  observeEvent(input$nav_mail, {
    require_permission("view_mail")
    active_page("mail")
  })
  observeEvent(input$brand_home, active_page("dashboard"))
  observeEvent(input$empty_create, active_page("create"))
  observeEvent(input$hero_create, active_page("create"))
  observeEvent(input$back_to_dashboard, active_page("dashboard"))

  output$app_root <- renderUI({
    user <- identity()
    if (is.null(user)) {
      return(tags$main(
        class = "auth-page",
        tags$div(
          class = "auth-panel",
          tags$img(src = "ppsv-logo.png", alt = "PPSV — Protein Production and Structural Validation Facility", class = "auth-logo"),
          tags$div(class = "auth-rule"),
          tags$h1("Institute sign-in required"),
          tags$p("This application is available through the authenticated PPSV web address."),
          tags$div(
            class = "auth-message",
            icon("shield-halved"),
            tags$div(
              tags$strong("LDAP identity not available"),
              tags$p(identity_error() %||% "Apache did not provide an authenticated user header. Please reopen the secure application URL or contact PPSV.")
            )
          ),
          tags$p(class = "contact-line", tags$a("ppsv-request@biochem.mpg.de", href = "mailto:ppsv-request@biochem.mpg.de"), " · +49 89 8578-3629")
        )
      ))
    }

    role <- normalize_role(user)
    page <- active_page()
    tags$div(
      class = "app-frame",
      tags$header(
        class = "topbar",
        actionLink(
          "brand_home",
          tags$span(
            class = "brand-lockup",
            tags$img(src = "ppsv-logo.png", alt = "PPSV", class = "brand-logo"),
            tags$span(class = "brand-title", tags$strong("Project Management"), tags$small("Protein Production & Structural Validation"))
          ),
          class = "brand-link"
        ),
        tags$div(
          class = "user-summary",
          tags$div(
            class = "user-copy",
            tags$strong(user_field(user, "display_name", "name", "username")),
            tags$span(paste0("@", user_field(user, "username")), " · ", tools::toTitleCase(role))
          ),
          tags$span(substr(toupper(user_field(user, "display_name", "username", default = "U")), 1L, 1L), class = "avatar")
        )
      ),
      tags$div(
        class = "app-body",
        tags$aside(
          class = "sidebar",
          tags$nav(
            `aria-label` = "Primary navigation",
            nav_link("nav_dashboard", "Requests", "table-list", page == "dashboard"),
            nav_link("nav_create", "New request", "plus", page == "create"),
            if (can_do("view_mail")) nav_link("nav_mail", "Delivery log", "envelope-circle-check", page == "mail"),
            if (can_do("view_users")) nav_link("nav_users", "User directory", "users-gear", page == "users")
          ),
          tags$div(
            class = "sidebar-contact",
            tags$span("Need help?"),
            tags$a("ppsv-request@biochem.mpg.de", href = "mailto:ppsv-request@biochem.mpg.de"),
            tags$span("+49 89 8578-3629")
          )
        ),
        tags$main(class = "main-panel", uiOutput("active_page_ui"))
      )
    )
  })

  output$active_page_ui <- renderUI({
    req(identity())
    switch(
      active_page(),
      create = create_page_ui(),
      detail = detail_page_ui(),
      users = users_page_ui(),
      mail = mail_page_ui(),
      dashboard_page_ui()
    )
  })

  dashboard_page_ui <- function() {
    tags$div(
      class = "page-wrap",
      tags$section(
        class = "page-hero",
        tags$div(
          tags$p("PPSV PROJECT PORTAL", class = "eyebrow"),
          tags$h1("Your requests"),
          tags$p("Submit a new request, share files, and follow progress in one place.", class = "hero-lead")
        ),
        actionButton("hero_create", tagList(icon("plus"), "New request"), class = "btn btn-primary btn-lg")
      ),
      uiOutput("startup_notice"),
      fluidRow(
        column(4, uiOutput("metric_total")),
        column(4, uiOutput("metric_active")),
        column(4, uiOutput("metric_attention"))
      ),
      tags$section(
        class = "content-card",
        tags$div(
          class = "card-heading",
          tags$div(tags$h2("Requests"), tags$p("Select a request to see its details, files and delivery status.")),
          tags$div(
            class = "inline-controls",
            if (normalize_role(identity()) == "admin") checkboxInput("show_archived", "Show archived", FALSE),
            actionButton("refresh_requests", icon("rotate"), class = "btn btn-default icon-button", title = "Refresh requests")
          )
        ),
        uiOutput("requests_content")
      )
    )
  }

  output$startup_notice <- renderUI({
    errors <- c(backend_source_errors, startup_error)
    errors <- errors[nzchar(errors)]
    if (length(errors) == 0L) return(NULL)
    tags$div(
      class = "notice notice-error",
      icon("triangle-exclamation"),
      tags$div(tags$strong("Application setup is incomplete"), tags$p(paste(errors, collapse = " ")))
    )
  })

  request_status_vector <- reactive({
    data <- requests_data()
    if (!is.data.frame(data) || nrow(data) == 0L) return(character())
    column <- intersect(c("status", "current_status"), names(data))
    if (length(column) == 0L) return(rep("", nrow(data)))
    as.character(data[[column[[1L]]]])
  })

  metric_card <- function(value, label, icon_name, tone = "teal") {
    tags$div(
      class = paste("metric-card", paste0("metric-", tone)),
      tags$span(icon(icon_name), class = "metric-icon"),
      tags$div(tags$strong(value), tags$span(label))
    )
  }

  output$metric_total <- renderUI(metric_card(nrow(requests_data()), "Total visible", "folder-open"))
  output$metric_active <- renderUI({
    active <- sum(!request_status_vector() %in% c("Completed", "Closed"))
    metric_card(active, "Active", "flask", "blue")
  })
  output$metric_attention <- renderUI({
    waiting <- sum(request_status_vector() == "Awaiting requester input")
    metric_card(waiting, "Awaiting your input", "comment-dots", "amber")
  })

  request_table_view <- function(data) {
    if (!is.data.frame(data) || nrow(data) == 0L) return(data.frame())
    preferred <- c(
      "request_code", "code", "request_kind", "service_module_name", "service_name",
      "protein_name", "inquiry_subject", "status", "current_status", "assignee_name",
      "owner_name", "created_at", "updated_at"
    )
    columns <- unique(preferred[preferred %in% names(data)])
    if (length(columns) == 0L) columns <- head(names(data), 8L)
    view <- data[, columns, drop = FALSE]
    names(view) <- gsub("_", " ", tools::toTitleCase(names(view)))
    view
  }

  output$requests_content <- renderUI({
    data <- requests_data()
    if (!is.data.frame(data) || nrow(data) == 0L) {
      return(empty_state(
        "clipboard-check",
        "No requests yet",
        "Start with a service request or open a general inquiry.",
        actionButton("empty_create", "Create your first request", class = "btn btn-primary")
      ))
    }
    tagList(
      if (requireNamespace("DT", quietly = TRUE)) DT::DTOutput("requests_table") else tableOutput("requests_table_base"),
      uiOutput("request_picker")
    )
  })

  if (requireNamespace("DT", quietly = TRUE)) {
    output$requests_table <- DT::renderDT({
      DT::datatable(
        request_table_view(requests_data()),
        rownames = FALSE,
        selection = "single",
        filter = "top",
        options = list(pageLength = 10, autoWidth = TRUE, dom = "tip")
      )
    })
  } else {
    output$requests_table_base <- renderTable(request_table_view(requests_data()), striped = TRUE, hover = TRUE)
  }

  output$request_picker <- renderUI({
    data <- requests_data()
    if (!is.data.frame(data) || nrow(data) == 0L) return(NULL)
    ids <- vapply(seq_len(nrow(data)), function(index) request_identifier(data[index, , drop = FALSE]), character(1L))
    codes <- vapply(seq_len(nrow(data)), function(index) request_code(data[index, , drop = FALSE]), character(1L))
    choices <- setNames(ids, codes)
    tags$div(
      class = "request-picker",
      selectInput("request_to_open", "Open request", choices = c("Choose a request" = "", choices), width = "280px"),
      actionButton("open_request", tagList("Open", icon("arrow-right")), class = "btn btn-secondary")
    )
  })

  observeEvent(input$refresh_requests, refresh_requests())
  observeEvent(input$show_archived, refresh_requests(), ignoreInit = TRUE)

  observeEvent(input$requests_table_rows_selected, {
    row <- input$requests_table_rows_selected
    data <- requests_data()
    if (length(row) != 1L || row > nrow(data)) return()
    selected_request_id(request_identifier(data[row, , drop = FALSE]))
    active_page("detail")
    refresh_detail()
  })

  observeEvent(input$open_request, {
    req(nzchar(trim_scalar(input$request_to_open)))
    selected_request_id(input$request_to_open)
    active_page("detail")
    refresh_detail()
  })

  create_page_ui <- function() {
    modules <- safe_module_data()
    module_choices <- setNames(as.character(modules$slug), as.character(modules$name))
    tags$div(
      class = "page-wrap form-page",
      tags$div(
        class = "page-title-row",
        tags$div(tags$p("NEW PPSV REQUEST", class = "eyebrow"), tags$h1("How can we help?"), tags$p("Choose one service or open a general consultation inquiry.", class = "hero-lead")),
        tags$span("Typical form time: 5–10 min", class = "quiet-chip")
      ),
      tags$section(
        class = "form-section service-choice-section",
        tags$div(
          class = "section-heading",
          tags$span(class = "step-number", "0"),
          tags$div(tags$h3("Request type"), tags$p("A selection is required before the form appears."))
        ),
        selectInput(
          "service_choice",
          required_label("Service module or inquiry"),
          choices = c(
            "Choose a service module" = "",
            module_choices,
            "General inquiry / consultation" = "__inquiry__"
          ),
          selected = "",
          width = "100%"
        ),
        uiOutput("selected_service_info")
      ),
      uiOutput("new_request_branch"),
      tags$section(
        class = "service-explorer",
        tags$div(class = "card-heading", tags$div(tags$h2("Explore PPSV services"), tags$p("These links open the institute service catalogue in a new tab."))),
        tags$div(class = "service-grid", lapply(seq_len(nrow(modules)), function(index) {
          module <- as.list(modules[index, , drop = FALSE])
          module$order <- index
          module_card(module, compact = TRUE)
        }))
      )
    )
  }

  output$selected_service_info <- renderUI({
    choice <- trim_scalar(input$service_choice)
    if (!nzchar(choice)) return(NULL)
    if (choice == "__inquiry__") {
      return(tags$div(
        class = "selected-service inquiry-selection",
        tags$span(icon("comments"), class = "selected-service-icon"),
        tags$div(tags$h3("General inquiry / consultation"), tags$p("Open a tracked conversation with the PPSV team without creating a protein service submission."))
      ))
    }
    module <- module_from_slug(choice)
    if (is.null(module)) return(NULL)
    tags$div(class = "selected-service", module_card(module))
  })

  output$new_request_branch <- renderUI({
    choice <- trim_scalar(input$service_choice)
    if (!nzchar(choice)) {
      return(empty_state("arrow-up", "Choose a request type", "The relevant form will appear here after you make a selection."))
    }
    inquiry <- identical(choice, "__inquiry__")
    tagList(
      contact_fields_ui("new_", identity(), include_billing = !inquiry),
      if (inquiry) inquiry_fields_ui("new_") else service_fields_ui("new_"),
      tags$section(
        class = "form-section",
        tags$div(
          class = "section-heading",
          tags$span(class = "step-number", "3"),
          tags$div(tags$h3("Supporting files"), tags$p("Optional. Files are stored with your tracked request."))
        ),
        fileInput("new_uploads", "Attach files", multiple = TRUE, width = "100%"),
        tags$p(sprintf("Maximum combined upload size: %s MB.", Sys.getenv("PPSV_MAX_UPLOAD_MB", "75")), class = "field-help")
      ),
      tags$div(
        class = "submit-bar",
        tags$p(icon("shield-halved"), "Your request is saved before ticket delivery is attempted."),
        actionButton("submit_request", tagList("Submit request", icon("paper-plane")), class = "btn btn-primary btn-lg")
      )
    )
  })

  input_payload <- function(prefix, keys) {
    values <- lapply(keys, function(key) input[[paste0(prefix, key)]])
    names(values) <- keys
    values
  }

  local_validate_payload <- function(payload, kind) {
    required <- if (kind == "inquiry") {
      c("contact_name", "contact_email", "research_group", "phone", "inquiry_subject", "inquiry_message")
    } else {
      c(
        "contact_name", "contact_email", "research_group", "phone", "billing_code",
        "protein_name", "uniprot_id", "source_organism", "expression_construct",
        "tags", "expression_host", "antibiotic_resistance", "storage_buffer",
        "references_previous_experiments", "amount_required_mg",
        "final_concentration_mg_ml", "delivery_state", "aliquot_size"
      )
    }
    missing <- required[vapply(required, function(key) !nzchar(trim_scalar(payload[[key]])), logical(1L))]
    if (length(missing) > 0L) {
      stop(sprintf("Complete all required fields: %s.", paste(gsub("_", " ", missing), collapse = ", ")), call. = FALSE)
    }
    if (kind == "service") {
      for (key in c("amount_required_mg", "final_concentration_mg_ml")) {
        value <- suppressWarnings(as.numeric(payload[[key]]))
        if (!is.finite(value) || value <= 0) stop(sprintf("%s must be greater than zero.", gsub("_", " ", key)), call. = FALSE)
      }
      for (key in c("size_uncleaved_da", "size_cleaved_da")) {
        if (nzchar(trim_scalar(payload[[key]]))) {
          value <- suppressWarnings(as.numeric(payload[[key]]))
          if (!is.finite(value) || value <= 0) stop(sprintf("%s must be greater than zero when provided.", gsub("_", " ", key)), call. = FALSE)
        }
      }
    }
    invisible(TRUE)
  }

  observeEvent(input$submit_request, {
    choice <- trim_scalar(input$service_choice)
    if (!nzchar(choice)) {
      showNotification("Choose a service module or General inquiry.", type = "error")
      return()
    }
    kind <- if (choice == "__inquiry__") "inquiry" else "service"
    keys <- if (kind == "inquiry") INQUIRY_FIELD_KEYS else SERVICE_FIELD_KEYS
    payload <- input_payload("new_", keys)
    payload$request_kind <- kind
    payload$service_module_slug <- if (kind == "service") choice else NULL

    result <- call_with_notice({
      require_permission("create_request")
      local_validate_payload(payload, kind)
      backend_call(
        "create_request",
        payload = payload,
        uploads = input$new_uploads,
        user = identity()
      )
    }, success = "Your request was saved. Ticket delivery status is shown on the request page.")

    if (!is.null(result)) {
      selected_request_id(request_identifier(result))
      active_page("detail")
      refresh_detail()
    }
  })

  detail_page_ui <- function() {
    tags$div(
      class = "page-wrap detail-page",
      actionLink("back_to_dashboard", tagList(icon("arrow-left"), "Back to requests"), class = "back-link"),
      uiOutput("request_header"),
      uiOutput("request_overview"),
      uiOutput("request_action_bar"),
      tags$div(
        class = "detail-grid",
        tags$section(class = "content-card", tags$div(class = "card-heading", tags$div(tags$h2("Status history"), tags$p("A complete audit trail of progress updates."))), tableOutput("status_history_table")),
        tags$section(class = "content-card", tags$div(class = "card-heading", tags$div(tags$h2("Files"), tags$p("Inputs and results associated with this request."))), uiOutput("file_controls"), tableOutput("files_table"))
      ),
      uiOutput("staff_controls"),
      tags$section(class = "content-card", tags$div(class = "card-heading", tags$div(tags$h2("Ticket delivery"), tags$p("Submission mail and acknowledgement attempts are recorded here."))), uiOutput("mail_controls"), tableOutput("request_mail_table"))
    )
  }

  output$request_header <- renderUI({
    detail <- selected_request()
    if (is.null(detail)) return(empty_state("spinner", "Loading request", "Request details are being loaded."))
    kind <- field_value(detail, "request_kind", "service")
    title <- if (kind == "inquiry") field_value(detail, "inquiry_subject", "General inquiry") else field_value(detail, "protein_name", field_value(detail, "service_module_name", "Service request"))
    tags$section(
      class = "request-title-card",
      tags$div(
        tags$p(if (kind == "inquiry") "GENERAL INQUIRY" else "SERVICE REQUEST", class = "eyebrow"),
        tags$div(class = "request-code-line", tags$h1(request_code(detail)), status_badge(field_value(detail, "status", field_value(detail, "current_status")))),
        tags$p(title, class = "request-subtitle")
      ),
      tags$dl(
        tags$div(tags$dt("Owner"), tags$dd(field_value(detail, "owner_name", field_value(detail, "contact_name")))),
        tags$div(tags$dt("Created"), tags$dd(field_value(detail, "created_at", "—"))),
        tags$div(tags$dt("Assigned to"), tags$dd(field_value(detail, "assignee_name", field_value(detail, "assignee_username", "Unassigned"))))
      )
    )
  })

  display_labels <- c(
    contact_name = "Name", contact_email = "E-mail", research_group = "Research group",
    phone = "Phone", billing_code = "Billing code", service_module_name = "Service module",
    service_module_slug = "Service module", protein_name = "Protein name", uniprot_id = "UniProt ID",
    source_organism = "Source organism", expression_construct = "Expression construct", tags = "Tag(s)",
    expression_host = "Expression host", antibiotic_resistance = "Antibiotic resistance",
    storage_buffer = "Storage buffer", references_previous_experiments = "References / previous experiments",
    amount_required_mg = "Amount required (mg)", final_concentration_mg_ml = "Final concentration (mg/mL)",
    delivery_state = "Delivery", aliquot_size = "Aliquot size", size_uncleaved_da = "Size uncleaved (Da)",
    size_cleaved_da = "Size cleaved (Da)", cleavage_size = "Cleavage Size",
    sequence_uncleaved = "Sequence (uncleaved)", sequence_cleaved = "Sequence (cleaved)",
    purification_strategy = "Purification strategy", tag_removal_required = "Tag removal required?",
    localisation = "Localisation", related_service_module_slug = "Related service",
    inquiry_subject = "Subject", inquiry_message = "Message"
  )

  detail_values <- function(detail) {
    kind <- field_value(detail, "request_kind", "service")
    keys <- if (kind == "inquiry") INQUIRY_FIELD_KEYS else SERVICE_FIELD_KEYS
    if (kind == "service") keys <- c("service_module_name", keys)
    rows <- lapply(keys, function(key) {
      value <- field_value(detail, key)
      if (identical(key, "tag_removal_required") && nzchar(value)) {
        value <- switch(tolower(value), `1` = "Yes", `true` = "Yes", `0` = "No", `false` = "No", value)
      }
      if (!nzchar(trimws(value))) value <- "—"
      data.frame(Field = unname(display_labels[[key]] %||% gsub("_", " ", key)), Value = value, stringsAsFactors = FALSE)
    })
    do.call(rbind, rows)
  }

  output$request_overview <- renderUI({
    detail <- selected_request()
    req(detail)
    rows <- detail_values(detail)
    staff <- normalize_role(identity()) %in% c("technician", "admin")
    unverified <- character()
    if (!is_truthy(field_value(detail, "contact_name_verified", "0"))) {
      unverified <- c(unverified, "name")
    }
    if (!is_truthy(field_value(detail, "contact_email_verified", "0"))) {
      unverified <- c(unverified, "email address")
    }
    tags$section(
      class = "content-card",
      tags$div(class = "card-heading", tags$div(tags$h2("Request details"), tags$p("The submitted contact and scientific information."))),
      if (staff && length(unverified)) tags$div(
        class = "alert alert-warning",
        icon("triangle-exclamation"),
        tags$strong(" Unverified contact snapshot: "),
        paste(unverified, collapse = " and "),
        ". LDAP did not provide this value; do not use the editable address for mail delivery."
      ),
      tags$dl(class = "detail-list", lapply(seq_len(nrow(rows)), function(index) {
        tags$div(tags$dt(rows$Field[[index]]), tags$dd(rows$Value[[index]]))
      }))
    )
  })

  output$request_action_bar <- renderUI({
    detail <- selected_request()
    req(detail)
    tags$div(
      class = "action-toolbar",
      if (can_do("edit_request", detail)) actionButton("edit_request", tagList(icon("pen"), "Edit request"), class = "btn btn-secondary"),
      downloadButton("download_summary", "Download PDF", class = "btn btn-secondary"),
      actionButton("refresh_detail", icon("rotate"), class = "btn btn-default icon-button", title = "Refresh")
    )
  })

  observeEvent(input$refresh_detail, refresh_detail())

  edit_modal_ui <- function(detail) {
    kind <- field_value(detail, "request_kind", "service")
    modalDialog(
      title = paste("Edit", request_code(detail)),
      size = "l",
      easyClose = FALSE,
      footer = tagList(modalButton("Cancel"), actionButton("save_edit", "Save changes", class = "btn btn-primary")),
      tags$div(
        class = "modal-form",
        contact_fields_ui("edit_", identity(), values = detail, include_billing = kind != "inquiry"),
        if (kind == "inquiry") inquiry_fields_ui("edit_", detail) else service_fields_ui("edit_", detail)
      )
    )
  }

  observeEvent(input$edit_request, {
    detail <- selected_request()
    require_permission("edit_request", detail)
    showModal(edit_modal_ui(detail))
  })

  observeEvent(input$save_edit, {
    detail <- selected_request()
    kind <- field_value(detail, "request_kind", "service")
    keys <- if (kind == "inquiry") INQUIRY_FIELD_KEYS else SERVICE_FIELD_KEYS
    payload <- input_payload("edit_", keys)
    payload$request_kind <- kind
    if (kind == "service") payload$service_module_slug <- field_value(detail, "service_module_slug")
    result <- call_with_notice({
      require_permission("edit_request", detail)
      local_validate_payload(payload, kind)
      backend_call("update_request", id = request_identifier(detail), payload = payload, user = identity())
    }, success = "Request updated.")
    if (!is.null(result)) {
      removeModal()
      refresh_detail()
    }
  })

  output$download_summary <- downloadHandler(
    filename = function() paste0(request_code(selected_request()), "-summary.pdf"),
    contentType = "application/pdf",
    content = function(file) {
      detail <- selected_request()
      require_permission("download_pdf", detail)
      backend_call("render_request_pdf", id = request_identifier(detail), user = identity(), path = file)
    }
  )

  status_history_data <- reactive({
    detail <- selected_request()
    if (is.null(detail)) return(data.frame())
    history <- record_list(detail)$status_history %||% record_list(detail)$history
    if (is.null(history)) return(data.frame())
    if (!is.data.frame(history)) history <- as.data.frame(history, stringsAsFactors = FALSE)
    history
  })

  output$status_history_table <- renderTable({
    history <- status_history_data()
    if (nrow(history) == 0L) return(data.frame(Message = "No status events recorded."))
    history
  }, striped = TRUE, hover = TRUE, na = "—")

  files_data <- reactive({
    detail <- selected_request()
    if (is.null(detail)) return(data.frame())
    result <- tryCatch(
      backend_call(
        "list_files", id = request_identifier(detail), user = identity(),
        include_archived = can_do("archive_file", detail)
      ),
      error = function(error) record_list(detail)$files %||% data.frame()
    )
    if (is.list(result) && !is.data.frame(result) && !is.null(result$files)) result <- result$files
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    result
  })

  output$files_table <- renderTable({
    files <- files_data()
    if (nrow(files) == 0L) return(data.frame(Message = "No files attached."))
    keep <- intersect(c("original_name", "category", "size_bytes", "sha256", "storage_location", "created_at", "uploaded_by", "archived_at"), names(files))
    files[, keep, drop = FALSE]
  }, striped = TRUE, hover = TRUE, na = "—")

  output$file_controls <- renderUI({
    detail <- selected_request()
    req(detail)
    files <- files_data()
    file_ids <- if (nrow(files) > 0L) {
      id_col <- intersect(c("id", "file_id"), names(files))
      name_col <- intersect(c("original_name", "name"), names(files))
      if (length(id_col) > 0L) setNames(as.character(files[[id_col[[1L]]]]), if (length(name_col) > 0L) as.character(files[[name_col[[1L]]]]) else as.character(files[[id_col[[1L]]]])) else character()
    } else character()
    archive_ids <- character()
    if (can_do("archive_file", detail) && nrow(files) > 0L) {
      active <- is.na(files$archived_at) | files$archived_at == ""
      active_files <- files[active, , drop = FALSE]
      if (nrow(active_files)) {
        archive_ids <- setNames(as.character(active_files$id), as.character(active_files$original_name))
      }
    }
    tagList(
      if (can_do("add_file", detail)) tags$div(
        class = "inline-controls file-upload-controls",
        fileInput("detail_uploads", "Add files", multiple = TRUE),
        selectInput("detail_file_kind", "File type", choices = if (normalize_role(identity()) %in% c("technician", "admin")) c("Input" = "inputs", "Result" = "results") else c("Input" = "inputs")),
        actionButton("upload_detail_files", "Upload", class = "btn btn-secondary")
      ),
      if (length(file_ids) > 0L) tags$div(
        class = "inline-controls download-controls",
        selectInput("file_to_download", "Download file", choices = c("Choose a file" = "", file_ids)),
        downloadButton("download_file", "Download", class = "btn btn-default")
      ),
      if (length(archive_ids) > 0L) tags$div(
        class = "inline-controls archive-file-controls",
        selectInput("file_to_archive", "Archive file", choices = c("Choose a file" = "", archive_ids)),
        actionButton("archive_file", "Archive", class = "btn btn-danger")
      )
    )
  })

  observeEvent(input$upload_detail_files, {
    req(input$detail_uploads)
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("add_file", detail)
      backend_call(
        "add_files",
        id = request_identifier(detail), uploads = input$detail_uploads,
        kind = input$detail_file_kind, user = identity()
      )
    }, success = "Files uploaded.")
    if (!is.null(result)) refresh_detail()
  })

  observeEvent(input$archive_file, {
    req(nzchar(trim_scalar(input$file_to_archive)))
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("archive_file", detail)
      backend_call(
        "archive_file", id = request_identifier(detail),
        file_id = input$file_to_archive, user = identity()
      )
    }, success = "File archived.")
    if (!is.null(result)) refresh_detail()
  })

  output$download_file <- downloadHandler(
    filename = function() {
      files <- files_data()
      id_col <- intersect(c("id", "file_id"), names(files))
      name_col <- intersect(c("original_name", "name"), names(files))
      if (length(id_col) == 0L || length(name_col) == 0L) return("download")
      index <- match(as.character(input$file_to_download), as.character(files[[id_col[[1L]]]]))
      if (is.na(index)) "download" else basename(as.character(files[[name_col[[1L]]]][[index]]))
    },
    content = function(file) {
      detail <- selected_request()
      req(nzchar(trim_scalar(input$file_to_download)))
      require_permission("download_file", detail)
      source <- backend_call(
        "download_file", id = request_identifier(detail),
        file_id = input$file_to_download, user = identity()
      )
      if (!file.copy(source, file, overwrite = TRUE)) stop("Unable to prepare the file for download.", call. = FALSE)
    }
  )

  output$staff_controls <- renderUI({
    detail <- selected_request()
    req(detail)
    can_status <- can_do("change_status", detail)
    can_assign <- can_do("assign_request", detail)
    can_archive <- can_do("archive_request", detail)
    if (!can_status && !can_assign && !can_archive) return(NULL)

    users <- staff_data()
    if (nrow(users) == 0L && can_assign) refresh_staff()
    staff_choices <- character()
    if (nrow(staff_data()) > 0L) {
      staff <- staff_data()
      if ("role" %in% names(staff)) staff <- staff[tolower(as.character(staff$role)) %in% c("technician", "admin"), , drop = FALSE]
      if ("active" %in% names(staff)) staff <- staff[as.logical(staff$active), , drop = FALSE]
      username_col <- intersect(c("username", "ldap_username"), names(staff))
      display_col <- intersect(c("display_name", "name", "username"), names(staff))
      if (length(username_col) > 0L) staff_choices <- setNames(as.character(staff[[username_col[[1L]]]]), as.character(staff[[display_col[[1L]]]]))
    }

    tags$section(
      class = "content-card staff-card",
      tags$div(class = "card-heading", tags$div(tags$h2("Staff actions"), tags$p("Changes are authorized and recorded by the backend."))),
      if (can_status) tags$div(
        class = "staff-action-row",
        tags$div(class = "staff-action-copy", tags$h3("Update status"), tags$p("Add an optional note to the audit trail.")),
        tags$div(
          class = "staff-action-inputs",
          selectInput("new_status", "Status", choices = PPSV_STATUSES, selected = field_value(detail, "status", field_value(detail, "current_status"))),
          textInput("status_note", "Note (optional)"),
          actionButton("save_status", "Update", class = "btn btn-secondary")
        )
      ),
      if (can_assign) tags$div(
        class = "staff-action-row",
        tags$div(class = "staff-action-copy", tags$h3("Assignment"), tags$p("Assign a technician or administrator.")),
        tags$div(
          class = "staff-action-inputs",
          selectInput("new_assignee", "Assignee", choices = c("Unassigned" = "", staff_choices), selected = field_value(detail, "assignee_username")),
          actionButton("save_assignment", "Assign", class = "btn btn-secondary")
        )
      ),
      if (can_archive) tags$div(
        class = "staff-action-row danger-row",
        tags$div(class = "staff-action-copy", tags$h3("Archive request"), tags$p("Archive hides the request without permanently deleting its record or files.")),
        actionButton("archive_request", "Archive", class = "btn btn-danger")
      )
    )
  })

  observeEvent(input$save_status, {
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("change_status", detail)
      backend_call(
        "update_status", id = request_identifier(detail), status = input$new_status,
        note = input$status_note, user = identity()
      )
    }, success = "Status updated.")
    if (!is.null(result)) refresh_detail()
  })

  observeEvent(input$save_assignment, {
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("assign_request", detail)
      backend_call(
        "assign_request", id = request_identifier(detail),
        assignee = trim_scalar(input$new_assignee), user = identity()
      )
    }, success = "Assignment updated.")
    if (!is.null(result)) refresh_detail()
  })

  observeEvent(input$archive_request, {
    detail <- selected_request()
    showModal(modalDialog(
      title = paste("Archive", request_code(detail), "?"),
      tags$p("The request and its files remain stored and auditable. It will disappear from normal lists."),
      easyClose = TRUE,
      footer = tagList(modalButton("Cancel"), actionButton("confirm_archive", "Archive request", class = "btn btn-danger"))
    ))
  })

  observeEvent(input$confirm_archive, {
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("archive_request", detail)
      backend_call("archive_request", id = request_identifier(detail), user = identity())
    }, success = "Request archived.")
    if (!is.null(result)) {
      removeModal()
      active_page("dashboard")
      selected_request(NULL)
      selected_request_id(NULL)
    }
  })

  request_mail_data <- reactive({
    detail <- selected_request()
    if (is.null(detail) || !can_do("view_request", detail)) return(data.frame())
    result <- tryCatch(
      backend_call("list_mail_status", id = request_identifier(detail), user = identity()),
      error = function(error) data.frame()
    )
    if (is.list(result) && !is.data.frame(result) && !is.null(result$mail)) result <- result$mail
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    result
  })

  output$request_mail_table <- renderTable({
    data <- request_mail_data()
    if (nrow(data) == 0L) return(data.frame(Message = "No visible delivery attempts."))
    keep <- intersect(c("id", "message_kind", "recipient", "status", "attempt_count", "last_error", "next_attempt_at", "sent_at", "ticket_url", "created_at"), names(data))
    data[, keep, drop = FALSE]
  }, striped = TRUE, hover = TRUE, na = "—")

  output$mail_controls <- renderUI({
    detail <- selected_request()
    req(detail)
    data <- request_mail_data()
    if (!can_do("retry_mail", detail) || nrow(data) == 0L) return(NULL)
    id_col <- intersect(c("id", "outbox_id"), names(data))
    if (length(id_col) == 0L) return(NULL)
    failed <- data$status == "failed"
    data <- data[failed, , drop = FALSE]
    if (!nrow(data)) return(NULL)
    labels <- if ("message_kind" %in% names(data)) paste(data[[id_col[[1L]]]], data$message_kind, sep = " · ") else as.character(data[[id_col[[1L]]]])
    tags$div(
      class = "inline-controls",
      selectInput("mail_to_retry", "Retry delivery", choices = setNames(as.character(data[[id_col[[1L]]]]), labels)),
      actionButton("retry_mail", tagList(icon("rotate-right"), "Retry now"), class = "btn btn-secondary")
    )
  })

  observeEvent(input$retry_mail, {
    req(nzchar(trim_scalar(input$mail_to_retry)))
    detail <- selected_request()
    result <- call_with_notice({
      require_permission("retry_mail", detail)
      backend_call("retry_mail", outbox_id = input$mail_to_retry, user = identity())
    }, success = "Delivery queued for retry.")
    if (!is.null(result)) refresh_detail()
  })

  users_page_ui <- function() {
    tags$div(
      class = "page-wrap",
      tags$div(class = "page-title-row", tags$div(tags$p("ADMINISTRATION", class = "eyebrow"), tags$h1("User directory"), tags$p("Roles are derived from the version-controlled allowlist and cannot be edited here.", class = "hero-lead"))),
      tags$section(
        class = "content-card",
        tags$div(class = "card-heading", tags$div(tags$h2("LDAP users"), tags$p("Select a non-admin account to activate or deactivate access.")), actionButton("refresh_users", icon("rotate"), class = "btn btn-default icon-button")),
        if (requireNamespace("DT", quietly = TRUE)) DT::DTOutput("users_table") else tableOutput("users_table_base"),
        uiOutput("user_admin_controls")
      )
    )
  }

  users_table_view <- function() {
    data <- users_data()
    keep <- intersect(c("username", "display_name", "email", "role", "active", "last_login_at", "updated_at"), names(data))
    data[, keep, drop = FALSE]
  }

  if (requireNamespace("DT", quietly = TRUE)) {
    output$users_table <- DT::renderDT({
      DT::datatable(users_table_view(), rownames = FALSE, selection = "single", filter = "top", options = list(pageLength = 15, dom = "tip"))
    })
  } else {
    output$users_table_base <- renderTable(users_table_view(), striped = TRUE, hover = TRUE)
  }

  observeEvent(input$refresh_users, refresh_users())

  output$user_admin_controls <- renderUI({
    req(can_do("manage_users"))
    data <- users_data()
    if (nrow(data) == 0L) return(empty_state("users", "No users found", "Users appear after their first authenticated visit."))
    username_col <- intersect(c("username", "ldap_username"), names(data))
    if (length(username_col) == 0L) return(NULL)
    choices <- setNames(as.character(data[[username_col[[1L]]]]), as.character(data[[username_col[[1L]]]]))
    tags$div(
      class = "user-controls",
      selectInput("managed_username", "Account", choices = c("Choose an account" = "", choices)),
      actionButton("activate_user", "Activate", class = "btn btn-secondary"),
      actionButton("deactivate_user", "Deactivate", class = "btn btn-danger")
    )
  })

  set_active <- function(active) {
    username <- trim_scalar(input$managed_username)
    req(nzchar(username))
    call_with_notice({
      require_permission("manage_users")
      backend_call("set_user_active", username = username, active = active, user = identity())
    }, success = if (active) "Account activated." else "Account deactivated.", refresh = FALSE)
    refresh_users()
  }

  observeEvent(input$activate_user, set_active(TRUE))
  observeEvent(input$deactivate_user, set_active(FALSE))

  mail_page_ui <- function() {
    tags$div(
      class = "page-wrap",
      tags$div(class = "page-title-row", tags$div(tags$p("OPERATIONS", class = "eyebrow"), tags$h1("Delivery log"), tags$p("Ticket messages, acknowledgements and retry state across visible requests.", class = "hero-lead"))),
      tags$section(
        class = "content-card",
        tags$div(class = "card-heading", tags$div(tags$h2("Mail outbox"), tags$p("A saved request is not presented as delivered until mail succeeds.")), actionButton("refresh_mail_log", icon("rotate"), class = "btn btn-default icon-button")),
        tableOutput("global_mail_table"),
        uiOutput("global_mail_controls")
      )
    )
  }

  global_mail_data <- reactiveVal(data.frame())

  refresh_global_mail <- function() {
    if (!can_do("view_mail")) return(invisible(NULL))
    result <- tryCatch(
      backend_call("list_mail_status", id = NULL, user = identity()),
      error = function(error) data.frame()
    )
    if (is.list(result) && !is.data.frame(result) && !is.null(result$mail)) result <- result$mail
    if (!is.data.frame(result)) result <- as.data.frame(result, stringsAsFactors = FALSE)
    global_mail_data(result)
    invisible(result)
  }

  observeEvent(active_page(), {
    if (active_page() == "mail") refresh_global_mail()
  })
  observeEvent(input$refresh_mail_log, refresh_global_mail())

  output$global_mail_table <- renderTable({
    data <- global_mail_data()
    if (nrow(data) == 0L) return(data.frame(Message = "No visible mail records."))
    keep <- intersect(c("id", "request_code", "message_kind", "recipient", "status", "attempt_count", "last_error", "next_attempt_at", "sent_at", "ticket_url", "created_at"), names(data))
    data[, keep, drop = FALSE]
  }, striped = TRUE, hover = TRUE, na = "—")

  output$global_mail_controls <- renderUI({
    data <- global_mail_data()
    if (!can_do("retry_mail") || nrow(data) == 0L) return(NULL)
    id_col <- intersect(c("id", "outbox_id"), names(data))
    if (length(id_col) == 0L) return(NULL)
    data <- data[data$status == "failed", , drop = FALSE]
    if (!nrow(data)) return(NULL)
    labels <- if ("request_code" %in% names(data)) paste(data$request_code, data[[id_col[[1L]]]], sep = " · ") else as.character(data[[id_col[[1L]]]])
    tags$div(
      class = "inline-controls",
      selectInput("global_mail_to_retry", "Retry delivery", choices = setNames(as.character(data[[id_col[[1L]]]]), labels)),
      actionButton("retry_global_mail", "Retry now", class = "btn btn-secondary")
    )
  })

  observeEvent(input$retry_global_mail, {
    req(nzchar(trim_scalar(input$global_mail_to_retry)))
    result <- call_with_notice({
      require_permission("retry_mail")
      backend_call("retry_mail", outbox_id = input$global_mail_to_retry, user = identity())
    }, success = "Delivery queued for retry.", refresh = FALSE)
    if (!is.null(result)) refresh_global_mail()
  })
}

shinyApp(public_ui, server)
