ppsv_test_ldap_settings <- function() {
  list(
    uris = c("ldaps://directory-one.example.org", "ldaps://directory-two.example.org"),
    base_dn = "dc=example,dc=org",
    attributes = c(
      uid = "uid", email = "mail", phone = "telephoneNumber", group = "ou",
      name = "cn", given = "givenName", surname = "sn"
    ),
    bind_dn = "", bind_password = "", command = file.path(R.home("bin"), "Rscript"),
    timeout = 1L
  )
}

ppsv_test_ldap_lines <- function() {
  c(
    "dn: uid=alice,ou=Cox,dc=example,dc=org", "uid: alice", "cn: Alice Example",
    "mail: alice@example.org", "telephoneNumber: +49 123", "ou: Cox"
  )
}

ppsv_with_ldap_lookup <- function(lookup, code) {
  envir <- environment(current_user)
  previous <- get("ppsv_ldap_lookup_user", envir = envir)
  on.exit(assign("ppsv_ldap_lookup_user", previous, envir = envir), add = TRUE)
  assign("ppsv_ldap_lookup_user", lookup, envir = envir)
  force(code)
}

testthat::test_that("LDAP profiles use ou for the group and cn for the person's name", {
  called <- character()
  profile <- ppsv_ldap_lookup_user(
    "EXAMPLE\\ALICE", settings = ppsv_test_ldap_settings(),
    lookup = function(uri, settings, filter, attributes) {
      called <<- c(called, uri)
      testthat::expect_identical(filter, "(&(uid=alice)(objectClass=posixAccount))")
      testthat::expect_true(all(c("uid", "ou", "cn", "mail") %in% attributes))
      if (length(called) == 1L) return(character())
      ppsv_test_ldap_lines()
    }
  )
  testthat::expect_length(called, 2L)
  testthat::expect_identical(profile, list(
    display_name = "Alice Example", email = "alice@example.org", research_group = "Cox", phone = "+49 123"
  ))
})

testthat::test_that("LDAP parsing decodes folded base64 attributes and DN group fallbacks", {
  name <- "Alice Müller"
  encoded <- base64enc::base64encode(charToRaw(enc2utf8(name)))
  lines <- c(
    "dn: uid=alice,ou=Cox,dc=example,dc=org", "uid: alice",
    paste0("cn:: ", substr(encoded, 1L, 8L)), paste0(" ", substring(encoded, 9L)),
    "mail;lang-en: alice@example.org", "telephoneNumber:< file:///ignored"
  )
  profile <- ppsv_ldap_lookup_user("alice", ppsv_test_ldap_settings(), function(...) lines)
  testthat::expect_equal(profile$display_name, name)
  testthat::expect_equal(profile$email, "alice@example.org")
  testthat::expect_equal(profile$research_group, "Cox")
  testthat::expect_identical(profile$phone, "")
  testthat::expect_equal(ppsv_ldap_group_from_dn("uid=alice,ou=M\\C3\\BCller\\, Lab,dc=example"), "Müller, Lab")
  testthat::expect_equal(ppsv_ldap_group_from_dn("cn=Alice\\,ou=Fake,ou=Cox,dc=example"), "Cox")
  testthat::expect_identical(ppsv_ldap_group_from_dn("cn=Cox,dc=example"), "")

  fallback <- c("dn: uid=alice,dc=example", "uid: alice", "givenName: Alice", "sn: Example")
  profile <- ppsv_ldap_lookup_user("alice", ppsv_test_ldap_settings(), function(...) fallback)
  testthat::expect_equal(profile$display_name, "Alice Example")
  testthat::expect_identical(profile$research_group, "")
})

testthat::test_that("LDAP rejects ambiguous accounts, unsafe attributes, and incomplete bind settings", {
  for (lines in list(
    c(ppsv_test_ldap_lines(), "", sub("alice", "bob", ppsv_test_ldap_lines())),
    sub("uid: alice", "uid: bob", ppsv_test_ldap_lines())
  )) {
    profile <- ppsv_ldap_lookup_user("alice", ppsv_test_ldap_settings(), function(...) lines)
    testthat::expect_identical(profile, ppsv_ldap_empty_profile())
  }
  settings <- ppsv_test_ldap_settings()
  settings$attributes[["uid"]] <- "uid)(cn=*"
  testthat::expect_identical(
    ppsv_ldap_lookup_user("alice", settings, function(...) stop("must not search")),
    ppsv_ldap_empty_profile()
  )
  settings <- ppsv_test_ldap_settings()
  settings$bind_dn <- "uid=service,dc=example"
  testthat::expect_identical(
    ppsv_ldap_lookup_user("alice", settings, function(...) stop("must not search")),
    ppsv_ldap_empty_profile()
  )
  testthat::expect_error(
    ppsv_ldap_lookup_user("alice*)(uid=*)", settings), class = "ppsv_authentication_error"
  )
})

testthat::test_that("LDAP command keeps the bind password private and removes its file", {
  settings <- ppsv_test_ldap_settings()
  settings$bind_dn <- "uid=profile-reader,dc=example,dc=org"
  settings$bind_password <- "a private ' password"
  password_file <- ""
  result <- ppsv_ldapsearch("ldaps://directory.example.org", settings, "(uid=alice)", "mail",
    runner = function(command, args, stdout, stderr, timeout) {
      testthat::expect_false(any(grepl(settings$bind_password, args, fixed = TRUE)))
      unquoted <- substring(args, 2L, nchar(args) - 1L)
      testthat::expect_false("-w" %in% unquoted)
      password_file <<- unquoted[match("-y", unquoted) + 1L]
      testthat::expect_equal(rawToChar(readBin(password_file, "raw", n = 1000L)), settings$bind_password)
      testthat::expect_equal(bitwAnd(as.integer(file.info(password_file)$mode), 511L), 384L)
      testthat::expect_identical(stderr, FALSE)
      testthat::expect_identical(timeout, 2L)
      ppsv_test_ldap_lines()
    }
  )
  testthat::expect_equal(result, ppsv_test_ldap_lines())
  testthat::expect_false(file.exists(password_file))

  failed <- ppsv_ldapsearch("ldaps://directory.example.org", settings, "(uid=alice)", "mail",
    runner = function(...) stop("LDAP process failed")
  )
  testthat::expect_identical(failed, character())
  failed <- ppsv_ldapsearch("ldaps://directory.example.org", settings, "(uid=alice)", "mail",
    runner = function(...) structure(ppsv_test_ldap_lines(), status = 1L)
  )
  testthat::expect_identical(failed, character())
  settings$command <- file.path(tempdir(), "absent-ldapsearch")
  testthat::expect_identical(
    ppsv_ldapsearch("ldaps://directory.example.org", settings, "(uid=alice)", "mail"), character()
  )
})

testthat::test_that("production fills missing trusted profile fields using the authenticated uid", {
  ctx <- ppsv_test_context()
  ctx$config$auth_mode <- "ldap"
  user <- ppsv_with_ldap_lookup(function(username) {
    testthat::expect_identical(username, "alice")
    list(display_name = "Alice Example", email = "alice@example.org", research_group = "Cox", phone = "+49 123")
  }, current_user(headers = list(
    HTTP_X_REMOTE_USER = "EXAMPLE\\ALICE", HTTP_X_REMOTE_EMAIL = "trusted@example.org"
  ), ctx = ctx))
  testthat::expect_equal(user$display_name, "Alice Example")
  testthat::expect_equal(user$email, "trusted@example.org")
  testthat::expect_equal(user$research_group, "Cox")
  testthat::expect_equal(user$phone, "+49 123")
  testthat::expect_equal(user$ldap_name_verified, 1L)
  testthat::expect_equal(user$ldap_email_verified, 1L)
  user <- ppsv_with_ldap_lookup(function(...) {
    list(display_name = "Alice Example", email = "alice@example.org", research_group = "Cox", phone = "+49 123")
  }, current_user(headers = list(HTTP_X_REMOTE_USER = "alice"), ctx = ctx))
  testthat::expect_equal(user$email, "alice@example.org")
  testthat::expect_equal(user$ldap_email_verified, 1L)
})

testthat::test_that("test mode bypasses LDAP and failed lookups do not verify cached values", {
  ctx <- ppsv_test_context()
  user <- ppsv_with_ldap_lookup(function(...) stop("must not search"), ppsv_test_user(ctx, "alice"))
  testthat::expect_equal(user$display_name, "Alice")
  ctx$config$auth_mode <- "ldap"
  user <- ppsv_with_ldap_lookup(function(...) stop("directory unavailable"),
    current_user(headers = list(HTTP_X_REMOTE_USER = "alice"), ctx = ctx)
  )
  testthat::expect_equal(user$display_name, "Alice")
  testthat::expect_equal(user$email, "alice@example.org")
  testthat::expect_equal(user$ldap_name_verified, 0L)
  testthat::expect_equal(user$ldap_email_verified, 0L)
})
