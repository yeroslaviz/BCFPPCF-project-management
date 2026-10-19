# PI and billing-code catalogue shared by the request form and lifecycle API.

ppsv_empty_budget_holders <- function(error = NULL) {
  holders <- data.frame(
    name = character(), surname = character(), cost_center = character(),
    pi = character(), description = character(), department = character(),
    stringsAsFactors = FALSE
  )
  if (!is.null(error)) attr(holders, "catalogue_error") <- error
  holders
}

ppsv_budget_column_key <- function(value) {
  value <- sub("^\ufeff", "", value)
  gsub("^_+|_+$", "", gsub("[^[:alnum:]]+", "_", tolower(trimws(value))))
}

ppsv_read_budget_catalogue <- function(path, encoding = "") {
  bytes <- readBin(path, "raw", n = file.info(path)$size)
  text <- rawToChar(bytes)
  if (nzchar(encoding)) {
    text <- iconv(text, from = encoding, to = "UTF-8", sub = NA_character_)
  } else {
    utf8 <- iconv(text, from = "UTF-8", to = "UTF-8", sub = NA_character_)
    # The facility's original Excel export is Macintosh Roman. Prefer UTF-8
    # for future exports and the normalized CSV used by the NGS system.
    text <- if (is.na(utf8)) iconv(text, from = "macintosh", to = "UTF-8", sub = NA_character_) else utf8
  }
  if (is.na(text)) stop("The budget-holder CSV has an unsupported encoding.")

  for (delimiter in c(",", ";", "\t")) {
    table <- tryCatch({
      connection <- textConnection(text)
      widths <- tryCatch(
        utils::count.fields(connection, sep = delimiter, quote = "\"", comment.char = "", blank.lines.skip = FALSE),
        finally = close(connection)
      )
      columns <- max(widths, na.rm = TRUE)
      if (!is.finite(columns) || columns < 2L) stop("Not a delimited catalogue.")
      utils::read.table(
        text = text, sep = delimiter, header = FALSE, quote = "\"",
        comment.char = "", fill = TRUE, blank.lines.skip = FALSE,
        col.names = paste0("V", seq_len(columns)), colClasses = "character",
        stringsAsFactors = FALSE, na.strings = NULL, check.names = FALSE,
        strip.white = TRUE
      )
    }, error = function(e) NULL)
    if (is.null(table) || !nrow(table)) next
    header <- which(vapply(seq_len(nrow(table)), function(i) {
      keys <- ppsv_budget_column_key(unlist(table[i, ], use.names = FALSE))
      "cost_center" %in% keys && ("budget_holder" %in% keys || all(c("name", "surname") %in% keys))
    }, logical(1L)))
    if (!length(header)) next
    first <- header[[1L]]
    if (first == nrow(table)) return(ppsv_empty_budget_holders())
    names(table) <- make.unique(ppsv_budget_column_key(unlist(table[first, ], use.names = FALSE)))
    rows <- table[seq.int(first + 1L, nrow(table)), , drop = FALSE]
    column <- function(key) {
      if (!key %in% names(rows)) return(rep("", nrow(rows)))
      value <- trimws(rows[[key]])
      value[is.na(value)] <- ""
      value
    }
    exported <- "budget_holder" %in% names(rows)
    name <- if (exported) column("budget_holder") else column("name")
    surname <- if (exported) rep("", nrow(rows)) else column("surname")
    code <- column("cost_center")
    # A blank holder with another code is an Excel continuation row. A fully
    # blank row ends that holder so later sections cannot inherit it.
    last_name <- last_surname <- ""
    for (i in seq_len(nrow(rows))) {
      if (!nzchar(name[[i]]) && !nzchar(surname[[i]])) {
        if (nzchar(code[[i]])) {
          name[[i]] <- last_name
          surname[[i]] <- last_surname
        } else {
          last_name <- last_surname <- ""
        }
      } else {
        last_name <- name[[i]]
        last_surname <- surname[[i]]
      }
    }
    holders <- data.frame(
      name = name, surname = surname, cost_center = code,
      pi = trimws(paste(name, surname)), description = column("description"),
      department = column("department"), stringsAsFactors = FALSE
    )
    valid_code <- nzchar(code) & !toupper(gsub("[^[:alnum:]]", "", code)) %in% c("NA", "NULL", "NONE")
    holders <- holders[nzchar(holders$pi) & valid_code, , drop = FALSE]
    holders <- holders[!duplicated(paste(tolower(holders$pi), holders$cost_center, sep = "\r")), , drop = FALSE]
    rownames(holders) <- NULL
    return(holders)
  }
  stop("The budget-holder CSV must contain cost_center and budget holder, or name and surname, columns.")
}

# A missing/malformed file remains renderable: the form can show the reason,
# while submission raises a normal field-validation error below.
ppsv_budget_holders <- function(config) {
  path <- ppsv_trim(config$budget_holders_file)
  if (!nzchar(path)) path <- file.path(config$app_dir, "budget_holders.csv")
  if (!file.exists(path)) {
    return(ppsv_empty_budget_holders("The budget-holder CSV is unavailable. Please contact the facility."))
  }
  tryCatch({
    holders <- ppsv_read_budget_catalogue(path, ppsv_trim(config$budget_holders_encoding))
    if (!nrow(holders)) attr(holders, "catalogue_error") <- "The budget-holder CSV contains no usable billing codes. Please contact the facility."
    holders
  }, error = function(e) ppsv_empty_budget_holders(paste("The budget-holder CSV could not be read:", conditionMessage(e))))
}

ppsv_extract_group_key <- function(value) {
  value <- ppsv_trim(value)
  if (!nzchar(value)) return("")
  # NGS uses the text in parentheses when ou contains a descriptive label.
  match <- regmatches(value, regexec("\\(([^)]+)\\)", value))[[1L]]
  if (length(match) > 1L) return(trimws(match[[2L]]))
  # Accept a DN as well as an already extracted ou value.
  match <- regmatches(value, regexec("(?:^|,)\\s*ou=([^,]+)", value, ignore.case = TRUE, perl = TRUE))[[1L]]
  if (length(match) > 1L) return(trimws(match[[2L]]))
  value
}

ppsv_match_group_budgets <- function(group, holders) {
  if (!nrow(holders)) return(holders)
  key <- tolower(ppsv_extract_group_key(group))
  if (!nzchar(key)) return(holders[FALSE, , drop = FALSE])
  pi <- tolower(trimws(holders$pi))
  index <- which(pi == key)
  if (!length(index)) index <- which(tolower(trimws(holders$name)) == key)
  if (!length(index)) index <- which(tolower(trimws(holders$surname)) == key)
  if (!length(index)) index <- which(grepl(key, pi, fixed = TRUE))
  # A profile previously normalized by NGS may contain the full PI name,
  # while the facility export contains only the family name.
  if (!length(index)) index <- which(vapply(pi, function(label) {
    startsWith(key, paste0(label, " ")) || endsWith(key, paste0(" ", label))
  }, logical(1L)))
  if (!length(index)) return(holders[FALSE, , drop = FALSE])
  holders[pi == pi[[index[[1L]]]], , drop = FALSE]
}

ppsv_group_budgets <- function(group, config) {
  ppsv_match_group_budgets(group, ppsv_budget_holders(config))
}

ppsv_billing_error <- function(message) {
  stop(ppsv_validation_condition(list(billing_code = message)))
}

# Call before the ordinary payload validator so a group's sole billing code
# can be supplied automatically. On edits pass the requester's group, never
# the staff editor's own LDAP group. Saved legacy values remain editable when
# their group/code pair is unchanged, even if the catalogue has since changed.
ppsv_apply_billing <- function(payload, user, config, current = NULL) {
  user_group <- ppsv_scalar(user$research_group)
  group <- if (nzchar(user_group)) user_group else ppsv_scalar(payload$research_group)
  selected <- ppsv_scalar(payload$billing_code)
  kind <- tolower(ppsv_scalar(payload$request_kind %||% "service"))
  holders <- ppsv_budget_holders(config)
  matches <- ppsv_match_group_budgets(group, holders)
  payload$research_group <- if (nrow(matches)) matches$pi[[1L]] else group

  if (kind %in% c("inquiry", "general", "general_inquiry", "general inquiry")) {
    payload$billing_code <- ""
    return(payload)
  }
  if (!is.null(current) &&
      identical(group, ppsv_scalar(current$research_group)) &&
      identical(selected, ppsv_scalar(current$billing_code)) && nzchar(selected)) {
    payload$research_group <- group
    return(payload)
  }
  if (!nrow(holders)) {
    ppsv_billing_error(attr(holders, "catalogue_error") %||% "No billing codes are available. Please contact the facility.")
  }
  codes <- unique(if (nrow(matches)) matches$cost_center else holders$cost_center)
  if (nrow(matches) && length(codes) == 1L) {
    payload$billing_code <- codes[[1L]]
    return(payload)
  }
  if (!nzchar(selected)) {
    ppsv_billing_error(if (nrow(matches)) "This PI has multiple cost centres. Please choose a billing code." else "Please choose a billing code from the budget-holder CSV.")
  }
  if (!selected %in% codes) {
    ppsv_billing_error(if (nrow(matches)) "Choose a billing code listed for your PI." else "Choose a billing code from the budget-holder CSV.")
  }
  payload$billing_code <- selected
  payload
}
