# Fetch profile attributes using only the username authenticated by Apache.
# Shiny Server Open Source does not forward the proxy's profile headers.

ppsv_ldap_empty_profile <- function() {
  list(display_name = "", email = "", research_group = "", phone = "")
}

ppsv_ldap_settings <- function() {
  timeout <- suppressWarnings(as.integer(Sys.getenv("LDAP_TIMEOUT_SECONDS", "3")))
  if (is.na(timeout) || timeout < 1L || timeout > 30L) timeout <- 3L
  list(
    uris = trimws(strsplit(Sys.getenv("LDAP_URI", paste(
      "ldaps://ldapserv1.biochem.mpg.de", "ldaps://ldapserv2.biochem.mpg.de",
      "ldaps://ldapserv3.biochem.mpg.de", sep = ","
    )), ",", fixed = TRUE)[[1L]]),
    base_dn = Sys.getenv("LDAP_BASE_DN", "dc=biochem,dc=mpg,dc=de"),
    attributes = c(
      uid = Sys.getenv("LDAP_ATTR_UID", "uid"),
      email = Sys.getenv("LDAP_ATTR_MAIL", "mail"),
      phone = Sys.getenv("LDAP_ATTR_PHONE", "telephoneNumber"),
      group = Sys.getenv("LDAP_ATTR_OU", "ou"),
      name = Sys.getenv("LDAP_ATTR_CN", "cn"),
      given = Sys.getenv("LDAP_ATTR_GIVENNAME", "givenName"),
      surname = Sys.getenv("LDAP_ATTR_SN", "sn")
    ),
    bind_dn = Sys.getenv("LDAP_BIND_DN", ""),
    bind_password = Sys.getenv("LDAP_BIND_PW", ""),
    command = Sys.getenv("LDAPSEARCH_PATH", "ldapsearch"),
    timeout = timeout
  )
}

# LDAP values can be base64 encoded and folded over several physical lines.
# URL references are deliberately ignored; profile lookup never fetches them.
ppsv_ldap_parse_ldif <- function(lines) {
  unfolded <- character()
  for (line in sub("\r$", "", lines)) {
    if (grepl("^[ \t]", line) && length(unfolded)) {
      unfolded[[length(unfolded)]] <- paste0(tail(unfolded, 1L), substring(line, 2L))
    } else {
      unfolded <- c(unfolded, line)
    }
  }
  records <- list()
  record <- list()
  for (line in c(unfolded, "")) {
    if (!nzchar(trimws(line))) {
      if (length(record$dn)) records[[length(records) + 1L]] <- record
      record <- list()
      next
    }
    if (startsWith(line, "#")) next
    match <- regmatches(line, regexec("^([^:;]+)(;[^:]*)?:(:|<)?[ ]?(.*)$", line))[[1L]]
    if (length(match) != 5L || identical(match[[4L]], "<")) next
    value <- match[[5L]]
    if (identical(match[[4L]], ":")) {
      value <- tryCatch(
        rawToChar(base64enc::base64decode(value)),
        error = function(error) ""
      )
    }
    key <- tolower(match[[2L]])
    record[[key]] <- c(record[[key]], value)
  }
  records
}

# Split RDNs without treating an escaped comma/plus as a separator, and decode
# RFC 4514 escaped characters (including UTF-8 hex octets).
ppsv_ldap_group_from_dn <- function(dn) {
  pieces <- character()
  piece <- ""
  escaped <- FALSE
  for (character in strsplit(dn, "", fixed = TRUE)[[1L]]) {
    if (!escaped && character %in% c(",", "+")) {
      pieces <- c(pieces, piece)
      piece <- ""
    } else {
      piece <- paste0(piece, character)
    }
    escaped <- !escaped && identical(character, "\\")
  }
  pieces <- c(pieces, piece)
  for (piece in pieces) {
    if (!grepl("^\\s*ou\\s*=", piece, ignore.case = TRUE)) next
    value <- sub("^\\s*ou\\s*=\\s*", "", piece, ignore.case = TRUE)
    chars <- strsplit(value, "", fixed = TRUE)[[1L]]
    bytes <- raw()
    i <- 1L
    while (i <= length(chars)) {
      if (identical(chars[[i]], "\\") && i < length(chars)) {
        if (i + 2L <= length(chars) &&
            grepl("^[0-9a-fA-F]{2}$", paste0(chars[[i + 1L]], chars[[i + 2L]]))) {
          bytes <- c(bytes, as.raw(strtoi(paste0(chars[[i + 1L]], chars[[i + 2L]]), 16L)))
          i <- i + 3L
          next
        }
        i <- i + 1L
      }
      bytes <- c(bytes, charToRaw(chars[[i]]))
      i <- i + 1L
    }
    return(tryCatch(ppsv_trim(rawToChar(bytes)), error = function(error) ""))
  }
  ""
}

ppsv_ldapsearch <- function(uri, settings, filter, attributes, runner = system2) {
  command <- unname(Sys.which(settings$command))
  if (!nzchar(command)) return(character())
  args <- c(
    "-LLL", "-x", "-H", uri, "-o", paste0("nettimeout=", settings$timeout),
    "-l", as.character(settings$timeout)
  )
  if (nzchar(settings$bind_dn)) {
    # ldapsearch -w would expose the password in the process list. Create an
    # empty file first, restrict access before writing, and always remove it.
    password_file <- tempfile("ppsv-ldap-password-")
    on.exit(unlink(password_file), add = TRUE)
    if (!file.create(password_file) || !Sys.chmod(password_file, mode = "0600")) {
      return(character())
    }
    writeBin(charToRaw(settings$bind_password), password_file)
    args <- c(args, "-D", settings$bind_dn, "-y", password_file)
  }
  args <- c(args, "-b", settings$base_dn, filter, attributes)
  output <- tryCatch(
    suppressWarnings(runner(
      command, args = vapply(args, shQuote, character(1L)), stdout = TRUE,
      stderr = FALSE, timeout = settings$timeout + 1L
    )),
    error = function(error) character()
  )
  if (!is.null(attr(output, "status")) && attr(output, "status") != 0L) return(character())
  output
}

ppsv_ldap_lookup_user <- function(username, settings = ppsv_ldap_settings(),
                                  lookup = ppsv_ldapsearch) {
  profile <- ppsv_ldap_empty_profile()
  # This also excludes LDAP filter metacharacters. Profile values from query
  # parameters, cookies, or form inputs are never passed into this search.
  username <- ppsv_normalize_username(username)
  if (!nzchar(settings$base_dn) ||
      any(!grepl("^[a-zA-Z][a-zA-Z0-9-]*$", settings$attributes)) ||
      xor(nzchar(settings$bind_dn), nzchar(settings$bind_password))) return(profile)
  uris <- settings$uris[grepl("^ldaps?://[^[:space:]]+$", settings$uris)]
  filter <- sprintf("(&(%s=%s)(objectClass=posixAccount))", settings$attributes[["uid"]], username)
  for (uri in uris) {
    records <- ppsv_ldap_parse_ldif(lookup(uri, settings, filter, unique(settings$attributes)))
    # A directory search must identify exactly one account. Never combine
    # attributes from several search entries or an unrelated returned uid.
    if (length(records) != 1L) next
    record <- records[[1L]]
    get <- function(attribute) {
      values <- record[[tolower(attribute)]] %||% character()
      values <- trimws(values)
      values <- values[nzchar(values)]
      if (length(values)) values[[1L]] else ""
    }
    if (!identical(tolower(get(settings$attributes[["uid"]])), username)) next
    profile$display_name <- get(settings$attributes[["name"]])
    if (!nzchar(profile$display_name)) {
      profile$display_name <- trimws(paste(
        get(settings$attributes[["given"]]), get(settings$attributes[["surname"]])
      ))
    }
    profile$email <- get(settings$attributes[["email"]])
    profile$phone <- get(settings$attributes[["phone"]])
    profile$research_group <- get(settings$attributes[["group"]])
    if (!nzchar(profile$research_group)) {
      profile$research_group <- ppsv_ldap_group_from_dn(get("dn"))
    }
    return(profile)
  }
  profile
}
