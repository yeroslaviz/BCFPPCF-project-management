# PPSV-branded PDF request summaries. The renderer uses only base graphics plus
# the optional png package, and Cairo when available for reliable Unicode text.

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) if (is.null(x) || !length(x) || all(is.na(x))) y else x
}
if (!exists("PPSV_FACILITY_NAME")) {
  PPSV_FACILITY_NAME <- "Protein Production and Structural Validation Facility"
}
if (!exists("PPSV_FACILITY_EMAIL")) PPSV_FACILITY_EMAIL <- "ppsv-request@biochem.mpg.de"
if (!exists("PPSV_FACILITY_PHONE")) PPSV_FACILITY_PHONE <- "+49 89 8578-3629"

ppsv_pdf_scalar <- function(value, default = "") {
  if (is.null(value) || !length(value) || is.na(value[[1L]])) return(default)
  as.character(value[[1L]])
}

ppsv_pdf_value <- function(record, name, default = "") {
  if (is.null(record)) return(default)
  if (is.data.frame(record)) {
    if (!nrow(record) || !name %in% names(record)) return(default)
    return(ppsv_pdf_scalar(record[[name]][[1L]], default))
  }
  if (is.list(record) && name %in% names(record)) {
    return(ppsv_pdf_scalar(record[[name]], default))
  }
  default
}

ppsv_pdf_first <- function(record, names, default = "") {
  for (name in names) {
    value <- ppsv_pdf_value(record, name)
    if (nzchar(trimws(value))) return(value)
  }
  default
}

ppsv_pdf_open_device <- function(file) {
  directory <- dirname(file)
  if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE)) {
    stop("Could not create PDF output directory: ", directory, call. = FALSE)
  }
  if (capabilities("cairo")) {
    grDevices::cairo_pdf(file, width = 8.27, height = 11.69, family = "sans")
  } else {
    grDevices::pdf(
      file, width = 8.27, height = 11.69, paper = "special",
      family = "sans", useDingbats = FALSE
    )
  }
}

ppsv_pdf_read_logo <- function(path) {
  if (!nzchar(ppsv_pdf_scalar(path)) || !file.exists(path) ||
      !requireNamespace("png", quietly = TRUE)) return(NULL)
  tryCatch(png::readPNG(path), error = function(error) NULL)
}

ppsv_pdf_label <- function(name) {
  labels <- c(
    contact_name = "Name", contact_email = "Email",
    research_group = "Research group", phone = "Phone",
    billing_code = "Billing code", protein_name = "Protein name",
    uniprot_id = "UniProt ID", source_organism = "Source organism",
    expression_construct = "Expression construct", tags = "Tags",
    expression_host = "Expression host",
    antibiotic_resistance = "Antibiotic resistance",
    storage_buffer = "Storage buffer",
    references_previous_experiments = "References / previous experiments",
    amount_required_mg = "Amount required (mg)",
    final_concentration_mg_ml = "Final concentration (mg/mL)",
    delivery_state = "Frozen / unfrozen delivery",
    aliquot_size = "Aliquot size (value and unit)",
    size_uncleaved_da = "Uncleaved size (Da)",
    size_cleaved_da = "Cleaved size (Da)",
    cleavage_size = "Cleavage Size (value and unit)",
    sequence_uncleaved = "Uncleaved sequence",
    sequence_cleaved = "Cleaved sequence",
    purification_strategy = "Purification strategy",
    tag_removal_required = "Tag removal", localisation = "Localisation",
    inquiry_subject = "Subject", inquiry_message = "Message",
    related_service_module_slug = "Related service"
  )
  unname(labels[[name]] %||% tools::toTitleCase(gsub("_", " ", name)))
}

ppsv_write_request_pdf <- function(request, details = list(), status_history = data.frame(),
                                   files = data.frame(), module = NULL, file,
                                   logo_path = "", public_url = "") {
  request <- if (is.data.frame(request)) as.list(request[1L, , drop = FALSE]) else request
  details <- if (is.data.frame(details)) as.list(details[1L, , drop = FALSE]) else details
  if (!is.list(request)) stop("request must be a list or one-row data frame", call. = FALSE)
  if (!is.list(details)) details <- list()
  if (!is.data.frame(status_history)) status_history <- as.data.frame(status_history, stringsAsFactors = FALSE)
  if (!is.data.frame(files)) files <- as.data.frame(files, stringsAsFactors = FALSE)

  navy <- "#123047"
  teal <- "#007E87"
  pale <- "#EAF5F4"
  ink <- "#1F2A30"
  muted <- "#60717B"
  line <- "#CBD8DC"
  logo <- ppsv_pdf_read_logo(logo_path)
  page <- 0L
  y <- 0.80
  ppsv_pdf_open_device(file)
  on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)
  graphics::par(mar = c(0, 0, 0, 0), xpd = NA)

  draw_page <- function() {
    graphics::plot.new()
    graphics::plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
    grid::grid.rect(
      x = 0.5, y = 0.94, width = 1, height = 0.12,
      gp = grid::gpar(fill = navy, col = NA)
    )
    if (!is.null(logo) && page == 1L) {
      grid::grid.raster(logo, x = 0.13, y = 0.94, width = 0.15, height = 0.075)
    } else {
      grid::grid.text(
        "PPSV", x = 0.06, y = 0.946, just = c("left", "centre"),
        gp = grid::gpar(col = "white", fontsize = 17, fontface = "bold")
      )
    }
    grid::grid.text(
      PPSV_FACILITY_NAME, x = 0.94, y = 0.953, just = c("right", "centre"),
      gp = grid::gpar(col = "white", fontsize = 7.8, fontface = "bold")
    )
    grid::grid.text(
      paste(PPSV_FACILITY_EMAIL, PPSV_FACILITY_PHONE, sep = "  |  "),
      x = 0.94, y = 0.918, just = c("right", "centre"),
      gp = grid::gpar(col = "#DCEAED", fontsize = 6.4)
    )
    grid::grid.segments(
      0.055, 0.055, 0.945, 0.055,
      gp = grid::gpar(col = line, lwd = 0.8)
    )
    footer <- paste0("PPSV request summary  |  Page ", page)
    if (nzchar(public_url)) footer <- paste(footer, sub("/+$", "", public_url), sep = "  |  ")
    grid::grid.text(
      footer, x = 0.055, y = 0.035, just = c("left", "centre"),
      gp = grid::gpar(col = muted, fontsize = 6.0)
    )
    y <<- 0.842
  }

  new_page <- function() {
    page <<- page + 1L
    draw_page()
  }

  ensure_space <- function(height) {
    if (y - height < 0.075) new_page()
  }

  section <- function(title, subtitle = "") {
    ensure_space(if (nzchar(subtitle)) 0.075 else 0.052)
    graphics::rect(0.055, y - 0.034, 0.945, y + 0.008, col = pale, border = NA)
    graphics::rect(0.055, y - 0.034, 0.062, y + 0.008, col = teal, border = NA)
    graphics::text(0.075, y - 0.011, title, adj = c(0, 0.5), cex = 0.90, font = 2, col = navy)
    y <<- y - 0.047
    if (nzchar(subtitle)) {
      graphics::text(0.065, y, subtitle, adj = c(0, 1), cex = 0.61, col = muted)
      y <<- y - 0.026
    }
  }

  field <- function(label, value, width = 92L, show_blank = FALSE) {
    value <- ppsv_pdf_scalar(value)
    if (!nzchar(trimws(value))) {
      if (!show_blank) return(invisible(NULL))
      value <- "Not provided"
    }
    value <- gsub("\r\n?", "\n", value)
    chunks <- unlist(strsplit(value, "\n", fixed = TRUE), use.names = FALSE)
    split_long_line <- function(text) {
      if (nchar(text, type = "width") <= width) return(text)
      starts <- seq.int(1L, nchar(text), by = width)
      vapply(starts, function(start) substr(text, start, start + width - 1L), character(1L))
    }
    wrapped <- unlist(lapply(chunks, function(chunk) {
      if (!nzchar(chunk)) return("")
      lines <- strwrap(chunk, width = width, simplify = FALSE)[[1L]]
      unlist(lapply(lines, split_long_line), use.names = FALSE)
    }), use.names = FALSE)
    if (!length(wrapped)) wrapped <- ""
    height <- 0.021 + 0.020 * length(wrapped) + 0.008
    ensure_space(height)
    graphics::text(0.065, y, label, adj = c(0, 1), cex = 0.61, font = 2, col = teal)
    graphics::text(
      0.36, y, paste(wrapped, collapse = "\n"),
      adj = c(0, 1), cex = 0.65, col = ink
    )
    y <<- y - height
    invisible(NULL)
  }

  note <- function(text) {
    wrapped <- strwrap(ppsv_pdf_scalar(text), width = 105L)
    height <- max(0.035, length(wrapped) * 0.019 + 0.012)
    ensure_space(height)
    graphics::text(
      0.065, y, paste(wrapped, collapse = "\n"),
      adj = c(0, 1), cex = 0.62, col = muted
    )
    y <<- y - height
  }

  new_page()
  code <- ppsv_pdf_first(request, c("request_code", "code"), "PPSV request")
  kind <- tolower(ppsv_pdf_value(request, "request_kind", "service"))
  status <- ppsv_pdf_first(request, c("current_status", "status"), "Submitted")
  graphics::text(0.055, y, code, adj = c(0, 1), cex = 1.55, font = 2, col = navy)
  graphics::rect(0.74, y - 0.035, 0.945, y + 0.005, col = teal, border = NA)
  graphics::text(0.8425, y - 0.015, status, cex = 0.70, font = 2, col = "white")
  y <- y - 0.065
  summary_title <- if (identical(kind, "inquiry")) {
    "General inquiry / consultation"
  } else {
    ppsv_pdf_first(module, c("name"), ppsv_pdf_first(request, c("service_module_name", "service_module_slug"), "PPSV service request"))
  }
  graphics::text(0.055, y, summary_title, adj = c(0, 1), cex = 0.93, font = 2, col = teal)
  y <- y - 0.045

  section("Request overview")
  field("Request type", if (identical(kind, "inquiry")) "General inquiry / consultation" else "Service request")
  field("Owner", ppsv_pdf_value(request, "owner_username"), show_blank = TRUE)
  field("Assigned to", ppsv_pdf_value(request, "assignee_username"), show_blank = TRUE)
  field("Created", ppsv_pdf_value(request, "created_at"), show_blank = TRUE)
  field("Last updated", ppsv_pdf_value(request, "updated_at"))

  if (!identical(kind, "inquiry")) {
    section("Service module")
    field("Service", ppsv_pdf_first(module, c("name"), summary_title), show_blank = TRUE)
    field("Description", ppsv_pdf_value(module, "description"))
    field("Reference", ppsv_pdf_value(module, "url"))
  }

  section("Contact snapshot", "Captured with the request; LDAP verification is recorded separately.")
  for (name in c("contact_name", "contact_email", "research_group", "phone")) {
    value <- ppsv_pdf_first(request, c(name, switch(
      name,
      contact_name = "submitter_name",
      contact_email = "submitter_email",
      name
    )))
    field(ppsv_pdf_label(name), value, show_blank = TRUE)
  }
  name_verified <- ppsv_pdf_value(request, "contact_name_verified")
  if (nzchar(name_verified)) {
    field("LDAP name verified", if (name_verified %in% c("1", "TRUE", "true")) "Yes" else "No")
  }
  email_verified <- ppsv_pdf_value(request, "contact_email_verified")
  if (nzchar(email_verified)) {
    field("LDAP email verified", if (email_verified %in% c("1", "TRUE", "true")) "Yes" else "No")
  }

  if (identical(kind, "inquiry")) {
    section("Inquiry")
    related <- ppsv_pdf_first(module, c("name"), ppsv_pdf_first(details, c("related_service_name", "related_service_module_slug")))
    field("Related service", related, show_blank = TRUE)
    field("Subject", ppsv_pdf_first(details, c("subject", "inquiry_subject"), ppsv_pdf_value(request, "inquiry_subject")), show_blank = TRUE)
    field("Message", ppsv_pdf_first(details, c("message", "inquiry_message"), ppsv_pdf_value(request, "inquiry_message")), width = 88L, show_blank = TRUE)
  } else {
    section("Scientific request")
    service_fields <- c(
      "billing_code", "protein_name", "uniprot_id", "source_organism",
      "expression_construct", "tags", "expression_host", "antibiotic_resistance",
      "storage_buffer", "references_previous_experiments", "amount_required_mg",
      "final_concentration_mg_ml", "delivery_state", "aliquot_size",
      "size_uncleaved_da", "size_cleaved_da", "cleavage_size",
      "sequence_uncleaved", "sequence_cleaved", "purification_strategy",
      "tag_removal_required", "localisation"
    )
    for (name in service_fields) {
      value <- ppsv_pdf_value(details, name, ppsv_pdf_value(request, name))
      if (identical(name, "tag_removal_required") && nzchar(value)) {
        value <- switch(value, `1` = "Yes", `0` = "No", value)
      }
      field(ppsv_pdf_label(name), value, width = if (grepl("sequence|references|construct", name)) 84L else 92L)
    }
  }

  section("Status history")
  if (!nrow(status_history)) {
    note("No status history recorded.")
  } else {
    for (index in seq_len(nrow(status_history))) {
      row <- status_history[index, , drop = FALSE]
      event_status <- ppsv_pdf_first(row, c("new_status", "status"), "Status updated")
      event_time <- ppsv_pdf_first(row, c("changed_at", "created_at"))
      actor <- ppsv_pdf_first(row, c("changed_by", "actor_username", "actor"))
      heading <- paste(Filter(nzchar, c(event_time, event_status, if (nzchar(actor)) paste("by", actor) else "")), collapse = "  |  ")
      field("Event", heading, show_blank = TRUE)
      event_note <- ppsv_pdf_value(row, "note")
      if (nzchar(event_note)) field("Note", event_note, width = 88L)
    }
  }

  section("File manifest")
  if (!nrow(files)) {
    note("No files attached.")
  } else {
    for (index in seq_len(nrow(files))) {
      row <- files[index, , drop = FALSE]
      name <- ppsv_pdf_first(row, c("original_name", "name"), "Unnamed file")
      category <- ppsv_pdf_first(row, c("category", "kind"), "file")
      size <- ppsv_pdf_first(row, c("size_bytes", "size"), "0")
      checksum <- ppsv_pdf_first(row, c("sha256", "checksum"))
      archive <- ppsv_pdf_value(row, "archived_at")
      manifest <- paste0(category, " | ", size, " bytes")
      if (nzchar(checksum)) manifest <- paste0(manifest, " | SHA-256 ", checksum)
      if (nzchar(archive)) manifest <- paste0(manifest, " | archived ", archive)
      field(name, manifest, width = 78L, show_blank = TRUE)
    }
  }

  note(paste("Generated by the PPSV Project Management System for", code))
  grDevices::dev.off()
  on.exit(NULL, add = FALSE)
  normalizePath(file, winslash = "/", mustWork = TRUE)
}

render_request_pdf <- function(id, user, path, ctx = ppsv_default_context()) {
  request <- get_request(id, user, ctx)
  ppsv_require(user, "download_pdf", request)
  modules <- list_service_modules(active_only = FALSE, ctx = ctx)
  module_slug <- if (identical(request$request_kind, "inquiry")) {
    request$related_service_module_slug %||% ""
  } else {
    request$service_module_slug %||% ""
  }
  module <- modules[modules$slug == module_slug, , drop = FALSE]
  if (!nrow(module)) module <- NULL
  ppsv_write_request_pdf(
    request = request,
    details = request,
    status_history = request$status_history,
    files = request$files,
    module = module,
    file = path,
    logo_path = ctx$config$logo_path,
    public_url = ctx$config$public_url
  )
}
