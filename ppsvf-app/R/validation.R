# Workbook-derived form contract and validation.

PPSV_REQUIRED_CONTACT_FIELDS <- c(
  "contact_name", "contact_email", "research_group", "phone", "billing_code"
)

PPSV_REQUIRED_PROTEIN_FIELDS <- c(
  "protein_name", "uniprot_id", "source_organism", "expression_construct",
  "tags", "expression_host", "antibiotic_resistance", "storage_buffer",
  "references_previous_experiments", "amount_required_mg",
  "final_concentration_mg_ml", "delivery_state", "aliquot_size"
)

PPSV_OPTIONAL_PROTEIN_FIELDS <- c(
  "size_uncleaved_da", "size_cleaved_da", "cleavage_size",
  "sequence_uncleaved", "sequence_cleaved", "purification_strategy",
  "tag_removal_required", "localisation"
)

PPSV_INQUIRY_CONTACT_FIELDS <- c(
  "contact_name", "contact_email", "research_group", "phone"
)

ppsv_form_field_spec <- function() {
  data.frame(
    field = c(PPSV_REQUIRED_CONTACT_FIELDS, PPSV_REQUIRED_PROTEIN_FIELDS, PPSV_OPTIONAL_PROTEIN_FIELDS),
    required = c(rep(TRUE, 18L), rep(FALSE, 8L)),
    stringsAsFactors = FALSE
  )
}

ppsv_scalar <- function(value) {
  if (is.null(value) || !length(value) || all(is.na(value))) return("")
  trimws(as.character(value[[1L]]))
}

ppsv_valid_email <- function(value) {
  grepl("^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$", value)
}

ppsv_module_slugs <- function() PPSV_SERVICE_MODULES$slug

ppsv_validation_condition <- function(errors) {
  labels <- paste(sprintf("%s: %s", names(errors), unlist(errors)), collapse = "; ")
  structure(
    list(message = paste("Request validation failed:", labels), call = NULL, errors = errors),
    class = c("ppsv_validation_error", "ppsv_error", "error", "condition")
  )
}

ppsv_validate_positive_number <- function(value, field, required, errors) {
  text <- ppsv_scalar(value)
  if (!nzchar(text)) {
    if (required) errors[[field]] <- "is required"
    return(list(value = if (required) NA_real_ else NULL, errors = errors))
  }
  number <- suppressWarnings(as.numeric(text))
  if (!is.finite(number) || number <= 0) {
    errors[[field]] <- "must be a positive number"
    number <- NA_real_
  }
  list(value = number, errors = errors)
}

# Return a normalized payload or raise ppsv_validation_error with a named
# `errors` list. Literal "N/A" is accepted for required textual scientific
# fields, as requested by the facility.
ppsv_validate_request_payload <- function(payload) {
  if (!is.list(payload)) stop("payload must be a named list", call. = FALSE)
  errors <- list()
  normalized <- list()
  kind <- tolower(ppsv_scalar(payload$request_kind %||% "service"))
  if (kind %in% c("general", "general_inquiry", "general inquiry")) kind <- "inquiry"
  if (!kind %in% c("service", "inquiry")) {
    errors$request_kind <- "must be 'service' or 'inquiry'"
  }
  normalized$request_kind <- kind

  contact_fields <- if (identical(kind, "inquiry")) PPSV_INQUIRY_CONTACT_FIELDS else PPSV_REQUIRED_CONTACT_FIELDS
  for (field in contact_fields) {
    normalized[[field]] <- ppsv_scalar(payload[[field]])
    if (!nzchar(normalized[[field]])) errors[[field]] <- "is required"
  }
  if (nzchar(normalized$contact_email %||% "") && !ppsv_valid_email(normalized$contact_email)) {
    errors$contact_email <- "must be a valid email address"
  }

  if (identical(kind, "inquiry")) {
    normalized$billing_code <- ""
    normalized$service_module_slug <- ""
    related <- ppsv_scalar(payload$related_service_module_slug %||% payload$service_module_slug)
    if (nzchar(related) && !related %in% ppsv_module_slugs()) {
      errors$related_service_module_slug <- "is not a recognized PPSV service module"
    }
    normalized$related_service_module_slug <- related
    normalized$inquiry_subject <- ppsv_scalar(payload$inquiry_subject %||% payload$subject)
    normalized$inquiry_message <- ppsv_scalar(payload$inquiry_message %||% payload$message)
    if (!nzchar(normalized$inquiry_subject)) errors$inquiry_subject <- "is required"
    if (!nzchar(normalized$inquiry_message)) errors$inquiry_message <- "is required"
  } else {
    module <- ppsv_scalar(payload$service_module_slug)
    if (!module %in% ppsv_module_slugs()) {
      errors$service_module_slug <- "is required and must be a recognized PPSV service module"
    }
    normalized$service_module_slug <- module

    text_fields <- setdiff(
      PPSV_REQUIRED_PROTEIN_FIELDS,
      c("amount_required_mg", "final_concentration_mg_ml")
    )
    for (field in text_fields) {
      normalized[[field]] <- ppsv_scalar(payload[[field]])
      if (!nzchar(normalized[[field]])) errors[[field]] <- "is required (use N/A only when not applicable)"
    }

    amount <- ppsv_validate_positive_number(payload$amount_required_mg, "amount_required_mg", TRUE, errors)
    normalized$amount_required_mg <- amount$value
    errors <- amount$errors
    concentration <- ppsv_validate_positive_number(
      payload$final_concentration_mg_ml,
      "final_concentration_mg_ml",
      TRUE,
      errors
    )
    normalized$final_concentration_mg_ml <- concentration$value
    errors <- concentration$errors

    delivery <- tolower(normalized$delivery_state %||% "")
    delivery <- switch(delivery, frozen = "Frozen", unfrozen = "Unfrozen", normalized$delivery_state)
    if (!delivery %in% c("Frozen", "Unfrozen")) {
      errors$delivery_state <- "must be Frozen or Unfrozen"
    }
    normalized$delivery_state <- delivery

    for (field in setdiff(PPSV_OPTIONAL_PROTEIN_FIELDS, c("size_uncleaved_da", "size_cleaved_da", "tag_removal_required"))) {
      value <- ppsv_scalar(payload[[field]])
      normalized[[field]] <- if (nzchar(value)) value else NULL
    }
    for (field in c("size_uncleaved_da", "size_cleaved_da")) {
      result <- ppsv_validate_positive_number(payload[[field]], field, FALSE, errors)
      normalized[[field]] <- result$value
      errors <- result$errors
    }
    tag_removal <- tolower(ppsv_scalar(payload$tag_removal_required))
    if (!nzchar(tag_removal)) {
      normalized$tag_removal_required <- NULL
    } else if (tag_removal %in% c("yes", "y", "true", "1")) {
      normalized$tag_removal_required <- 1L
    } else if (tag_removal %in% c("no", "n", "false", "0")) {
      normalized$tag_removal_required <- 0L
    } else {
      errors$tag_removal_required <- "must be Yes, No, or blank"
    }
  }

  if (length(errors)) stop(ppsv_validation_condition(errors))
  normalized
}
