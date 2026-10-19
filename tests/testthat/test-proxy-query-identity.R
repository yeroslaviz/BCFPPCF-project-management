testthat::test_that("canonical proxy query identity is narrowly parsed", {
  testthat::expect_equal(
    ppsv_proxy_query_username("?auth_user=Yeroslaviz", enabled = TRUE),
    "yeroslaviz"
  )
  testthat::expect_equal(
    ppsv_proxy_query_username("other=value&auth_user=grzejszc", enabled = TRUE),
    "grzejszc"
  )
  testthat::expect_equal(
    ppsv_proxy_query_username("auth_user=bad%2Fadmin", enabled = TRUE),
    ""
  )
  testthat::expect_equal(
    ppsv_proxy_query_username("auth_user=alice&auth_user=basquin", enabled = TRUE),
    ""
  )
  testthat::expect_equal(
    ppsv_proxy_query_username("auth_user=yeroslaviz", enabled = FALSE),
    ""
  )
  # Cookies are intentionally not an input to the identity parser.
  testthat::expect_error(
    ppsv_identity_from_headers(list(HTTP_COOKIE = "auth_user=yeroslaviz")),
    class = "ppsv_authentication_error"
  )
})
