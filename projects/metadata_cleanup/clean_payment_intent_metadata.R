# setup -------------------------------------------------------------------
pacman::p_load(
  tidyverse,
  keyring,
  httr2,
  jsonlite,
  stringr,
  bigrquery,
  progress
)

billing <- "noah-e30be"
bigrquery::bq_auth("dennis@work.flowers")

# pull data ---------------------------------------------------------------
sql <- "
  SELECT 
    region,
    id AS payment_intent_id
  FROM all_stripe.payment_intent
  WHERE COALESCE(JSON_VALUE(metadata, '$.customer_email'), JSON_VALUE(metadata, '$.customer_name')) IS NOT NULL;
"
tb <- bigrquery::bq_project_query(billing, sql)
df_raw <- bigrquery::bq_table_download(tb)

# --- helper: resilient request ------------------------------------------
perform_with_retries <- function(req, max_tries = 6, base_sleep = 0.5) {
  attempt <- 0
  repeat {
    attempt <- attempt + 1
    resp <- try(httr2::req_perform(req), silent = TRUE)
    
    if (inherits(resp, "try-error")) {
      if (attempt >= max_tries) return(list(resp=NULL, attempt=attempt, status=NA_integer_, error="network", request_id=NA_character_))
      Sys.sleep(base_sleep * attempt); next
    }
    
    status <- httr2::resp_status(resp)
    rid    <- httr2::resp_header(resp, "request-id")
    
    if (status >= 200 && status < 300) {
      return(list(resp=resp, attempt=attempt, status=status, error=NULL, request_id=rid))
    }
    
    if (status == 429) {
      ra   <- httr2::resp_header(resp, "retry-after")
      wait <- suppressWarnings(as.numeric(ra))
      if (is.na(wait) || is.null(wait)) wait <- base_sleep * attempt
      Sys.sleep(wait)
    } else if (status >= 500 && status < 600) {
      if (attempt >= max_tries) return(list(resp=resp, attempt=attempt, status=status, error="server", request_id=rid))
      Sys.sleep(base_sleep * attempt)
    } else {
      # Non-retryable 4xx
      return(list(resp=resp, attempt=attempt, status=status, error="client", request_id=rid))
    }
    
    if (attempt >= max_tries) return(list(resp=resp, attempt=attempt, status=status, error="max_retries", request_id=rid))
  }
}
# function to unset PII ---------------------------------------------------
remove_payment_intent_pii <- function(payment_intent_id, region) {
  stopifnot(nzchar(payment_intent_id), nzchar(region))
  
  req <- httr2::request(
    stringr::str_glue("https://api.stripe.com/v1/payment_intents/{payment_intent_id}")
  ) |>
    httr2::req_headers(
      Authorization     = paste("Bearer", keyring::key_get("of_stripe", toupper(region))),
      `Idempotency-Key` = stringr::str_glue("wipe-{payment_intent_id}"),
      `User-Agent`      = "work.flowers-pii-wiper/1.0 (+R httr2)"
    ) |>
    httr2::req_body_form(
      `metadata[customer_email]` = "",
      `metadata[customer_name]`  = ""
    )
  
  out <- perform_with_retries(req)
  
  body_json <- NULL
  if (!is.null(out$resp)) {
    body_json <- tryCatch(jsonlite::fromJSON(httr2::resp_body_string(out$resp)), error = function(e) NULL)
  }
  
  # Verify by inspecting the returned object
  md <- body_json$metadata %||% list()
  has_email <- "customer_email" %in% names(md) && nzchar(md[["customer_email"]] %||% "")
  has_name  <- "customer_name"  %in% names(md) && nzchar(md[["customer_name"]]  %||% "")
  verified  <- (out$status >= 200 && out$status < 300) && !has_email && !has_name
  
  # Make auth/permission problems impossible to miss
  if (out$status %in% c(401L, 403L)) {
    msg <- body_json$error$message %||% paste("Stripe 4xx", out$status)
    warning(sprintf("Auth/permission issue for %s (%s). request-id=%s. %s",
                    payment_intent_id, region, out$request_id %||% "n/a", msg))
  }
  
  tibble::tibble(
    payment_intent_id = payment_intent_id,
    region            = region,
    http_status       = as.integer(out$status),
    attempts          = out$attempt,
    request_id        = out$request_id %||% NA_character_,
    error_class       = out$error %||% NA_character_,
    stripe_error_type = body_json$error$type    %||% NA_character_,
    stripe_error_msg  = body_json$error$message %||% NA_character_,
    after_has_email   = has_email,
    after_has_name    = has_name,
    success_verified  = verified
  )
}

# loop with progress ------------------------------------------------------
if (nrow(df_raw) == 0) {
  message("No PaymentIntents to update. Done.")
} else {
  pb <- progress::progress_bar$new(
    total = nrow(df_raw),
    format = "Updating [:bar] :current/:total (:percent) eta: :eta"
  )
  
  results <- vector("list", nrow(df_raw))
  for (i in seq_len(nrow(df_raw))) {
    results[[i]] <- remove_payment_intent_pii(df_raw$payment_intent_id[i], df_raw$region[i])
    pb$tick()
    Sys.sleep(0.1)  # gentle pacing
  }
  
  res_df <- dplyr::bind_rows(results)
  
  message("\nSummary by status:")
  print(res_df %>% count(http_status, error_class, stripe_error_type, sort = TRUE))
  
  message("\nVerification summary:")
  print(res_df %>% count(success_verified, sort = TRUE))
  
  failures <- res_df %>%
    dplyr::filter(is.na(http_status) | http_status < 200 | http_status >= 300 | !success_verified)
  
  if (nrow(failures) > 0) {
    out <- paste0("stripe_pi_wipe_failures_", format(Sys.time(), "%Y%m%d-%H%M%S"), ".csv")
    readr::write_csv(failures, out, na = "")
    message("⚠️ Wrote failures to ", out)
    # Uncomment to hard-fail the run so CI/cron notices:
    # stop(sprintf("Found %d failures (see CSV).", nrow(failures)))
  }
}
