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
    
    # Network error -> retry
    if (inherits(resp, "try-error")) {
      if (attempt >= max_tries) return(list(resp = NULL, attempt = attempt, status = NA_integer_, error = "network"))
      Sys.sleep(base_sleep * attempt); next
    }
    
    status <- httr2::resp_status(resp)
    if (status >= 200 && status < 300) {
      return(list(resp = resp, attempt = attempt, status = status, error = NULL))
    }
    
    # Rate limit: honour Retry-After if present
    if (status == 429) {
      ra <- httr2::resp_header(resp, "retry-after")
      wait <- if (!is.null(ra)) suppressWarnings(as.numeric(ra)) else base_sleep * attempt
      Sys.sleep(ifelse(is.na(wait), base_sleep * attempt, wait))
    } else if (status >= 500 && status < 600) {
      if (attempt >= max_tries) return(list(resp = resp, attempt = attempt, status = status, error = "server"))
      Sys.sleep(base_sleep * attempt)
    } else {
      # Non-retryable 4xx (e.g., 400, 404) — return immediately
      return(list(resp = resp, attempt = attempt, status = status, error = "client"))
    }
    
    if (attempt >= max_tries) return(list(resp = resp, attempt = attempt, status = status, error = "max_retries"))
  }
}

# function to unset PII ---------------------------------------------------
remove_payment_intent_pii <- function(payment_intent_id, region) {
  stopifnot(nzchar(payment_intent_id), nzchar(region))
  
  req <- httr2::request(
    stringr::str_glue("https://api.stripe.com/v1/payment_intents/{payment_intent_id}")
  ) |>
    httr2::req_headers(
      Authorization = paste("Bearer", keyring::key_get("of_stripe", toupper(region))),
      `Idempotency-Key` = stringr::str_glue("wipe-{payment_intent_id}"),
      `User-Agent` = "work.flowers-pii-wiper/1.0 (+R httr2)"
    ) |>
    httr2::req_body_form(list(
      "metadata[customer_email]" = "",  # empty value unsets key
      "metadata[customer_name]"  = ""
    ))
  
  out <- perform_with_retries(req)
  
  body_json <- NULL
  if (!is.null(out$resp)) {
    body_json <- tryCatch(jsonlite::fromJSON(httr2::resp_body_string(out$resp)), error = function(e) NULL)
  }
  
  tibble::tibble(
    payment_intent_id = payment_intent_id,
    region = region,
    http_status = as.integer(out$status),
    attempts = out$attempt,
    error_class = out$error %||% NA_character_,
    stripe_error_type = body_json$error$type        %||% NA_character_,
    stripe_error_msg = body_json$error$message     %||% NA_character_
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
  
  failures <- res_df %>% filter(is.na(http_status) | http_status < 200 | http_status >= 300)
  if (nrow(failures) > 0) {
    out <- paste0("stripe_pi_wipe_failures_", format(Sys.time(), "%Y%m%d-%H%M%S"), ".csv")
    readr::write_csv(failures, out)
    message("Wrote failures to ", out)
  }
}