# stripe_pii_wipe_parallel.R
# Batch-remove PII metadata from Stripe Charges across multiple regions/accounts.
# Parallelised with chunking, idempotency, retries, and gentle pacing.

# --- packages -------------------------------------------------------------
pacman::p_load(
  tidyverse, 
  rlang, 
  keyring, 
  httr2, 
  jsonlite, 
  stringr,
  bigrquery, 
  future, 
  future.apply, 
  readr,
  digest
)

# --- config knobs ---------------------------------------------------------
BILLING_PROJECT <- "noah-e30be"                 # your BigQuery billing project
BQ_AUTH_EMAIL <- "dennis@work.flowers"         # BQ auth identity

# Concurrency knobs
CONCURRENCY <- 8      # total parallel workers across all regions/chunks (tune 6–10)
CHUNK_SIZE_PER_TASK <- 200    # how many Charges each worker handles sequentially
PACE_SECS <- 0.05   # small pause between calls within a worker (tune to reduce 429s)

# Retry/backoff knobs
MAX_TRIES <- 6
BASE_SLEEP_SEC <- 0.5

# Output directory for artefacts
OUT_DIR <- "stripe_pii_wipe_output_charge"
dir.create(OUT_DIR, showWarnings = FALSE)

# --- auth -----------------------------------------------------------------
bigrquery::bq_auth(BQ_AUTH_EMAIL)

# --- query BigQuery -------------------------------------------------------
sql <- "
  SELECT 
    region,
    id AS charge_id
  FROM all_stripe.charge
  WHERE 
    COALESCE(JSON_VALUE(metadata, '$.customer_email'), JSON_VALUE(metadata, '$.customer_name')) IS NOT NULL
"

message("Running BigQuery…")
job <- bigrquery::bq_project_query(BILLING_PROJECT, sql)
df_raw <- bigrquery::bq_table_download(
  job, 
  bigint = "character"
) %>%
  tibble::as_tibble()

if (nrow(df_raw) == 0) {
  message("No Charges matched. Nothing to do.")
  quit(status = 0)
}

message(glue::glue("Total Charges to update: {nrow(df_raw)}"))
regions <- sort(unique(df_raw$region))
message("Regions discovered: ", paste(regions, collapse = ", "))

# --- FETCH STRIPE KEYS ONCE (MAIN SESSION ONLY) --------------------------
# Avoid calling keyring inside worker processes.
# Keys are stored in keychain under service 'of_stripe' and username = toupper(region).

keys_by_region <- setNames(
  vapply(regions, function(r) keyring::key_get("of_stripe", toupper(r)), FUN.VALUE = character(1)),
  regions
)

# --- helpers --------------------------------------------------------------

# Safe perform with retries/backoff + Retry-After (429) handling
perform_with_retries <- function(req, max_tries = MAX_TRIES, base_sleep = BASE_SLEEP_SEC) {
  attempt <- 0
  repeat {
    attempt <- attempt + 1
    resp <- try(httr2::req_perform(req), silent = TRUE)
    
    if (inherits(resp, "try-error")) {
      if (attempt >= max_tries) return(list(resp = NULL, attempt = attempt, status = NA_integer_, error = "network"))
      Sys.sleep(base_sleep * attempt); next
    }
    
    status <- httr2::resp_status(resp)
    
    if (status >= 200 && status < 300) {
      return(list(resp = resp, attempt = attempt, status = status, error = NULL))
    }
    
    if (status == 429) {
      ra   <- httr2::resp_header(resp, "retry-after")
      wait <- suppressWarnings(as.numeric(ra))
      if (is.na(wait) || is.null(wait)) wait <- base_sleep * attempt
      Sys.sleep(wait)
    } else if (status >= 500 && status < 600) {
      if (attempt >= max_tries) return(list(resp = resp, attempt = attempt, status = status, error = "server"))
      Sys.sleep(base_sleep * attempt)
    } else {
      return(list(resp = resp, attempt = attempt, status = status, error = "client"))
    }
    
    if (attempt >= max_tries) return(list(resp = resp, attempt = attempt, status = status, error = "max_retries"))
  }
}

# One-call updater: requires pre-fetched API key
remove_charge_pii <- function(charge_id, region, api_key) {
  stopifnot(nzchar(charge_id), nzchar(region), nzchar(api_key))
  
  req <- httr2::request(glue::glue("https://api.stripe.com/v1/charges/{charge_id}")) |>
    httr2::req_headers(
      Authorization     = paste("Bearer", api_key),
      `Idempotency-Key` = glue::glue("wipe-{charge_id}"),
      `User-Agent`      = "work.flowers-pii-wiper/1.0 (+R httr2)"
    ) |>
    httr2::req_body_form(
      "metadata[customer_email]" = "",
      "metadata[customer_name]"  = ""
    )
  
  out <- perform_with_retries(req)
  
  body_json <- NULL
  if (!is.null(out$resp)) {
    body_json <- tryCatch(jsonlite::fromJSON(httr2::resp_body_string(out$resp)), error = function(e) NULL)
  }
  
  tibble::tibble(
    charge_id = charge_id,
    region = region,
    http_status = as.integer(out$status),
    attempts = out$attempt,
    error_class= out$error %||% NA_character_,
    stripe_error_type = body_json$error$type    %||% NA_character_,
    stripe_error_msg = body_json$error$message %||% NA_character_
  )
}

# Process a chunk sequentially (called by parallel workers)
process_chunk <- function(chunk_df, keys_by_region, pace_secs = PACE_SECS) {
  out <- vector("list", nrow(chunk_df))
  for (i in seq_len(nrow(chunk_df))) {
    region_i <- chunk_df$region[i]
    key_i    <- keys_by_region[[region_i]]
    out[[i]] <- remove_charge_pii(chunk_df$charge_id[i], region_i, key_i)
    Sys.sleep(pace_secs) # gentle pacing inside each worker
  }
  dplyr::bind_rows(out)
}

# --- split by region, then into chunks -----------------------------------
split_by_region <- split(df_raw %>% arrange(region), df_raw$region)

make_chunks <- function(d, chunk_size = CHUNK_SIZE_PER_TASK) {
  idx <- split(seq_len(nrow(d)), ceiling(seq_along(d$charge_id) / chunk_size))
  lapply(idx, function(i) d[i, , drop = FALSE])
}

region_chunks <- purrr::imap(split_by_region, ~ make_chunks(.x, CHUNK_SIZE_PER_TASK))

total_chunks <- sum(purrr::map_int(region_chunks, length))
message(glue::glue("Total chunks to process: {total_chunks} (chunk size ~{CHUNK_SIZE_PER_TASK})"))

# Flatten to a list of chunks; keep region label for logging
worklist <- purrr::imap(
  region_chunks, 
  function(chunks, region) {
    purrr::map(chunks, ~list(region = region, df = .x))
  }
) %>% purrr::list_flatten()

# --- run in parallel ------------------------------------------------------
# Plan AFTER we've fetched keys so workers inherit the values without touching keyring.
future::plan(multisession, workers = CONCURRENCY)

results_list <- future.apply::future_lapply(
  worklist,
  function(task) {
    # Each task is a list: region + df
    res <- process_chunk(task$df, keys_by_region = keys_by_region, pace_secs = PACE_SECS)
    # write intermediate per-chunk result (optional safety)
    out_path <- file.path(OUT_DIR, glue::glue("chunk_{task$region}_{digest::digest(task$df$charge_id)}.csv"))
    readr::write_csv(res, out_path, na = "")
    res
  },
  future.seed = TRUE
)

future::plan(sequential)

# --- collate results ------------------------------------------------------
res_df <- dplyr::bind_rows(results_list)

# Overall summary
message("\n=== Overall summary ===")
print(res_df %>% count(http_status, error_class, stripe_error_type, sort = TRUE))

# Per-region summaries + failure CSVs
message("\n=== Per-region summaries ===")
by_region <- split(res_df, res_df$region)
for (r in names(by_region)) {
  reg_df <- by_region[[r]]
  message(glue::glue("\nRegion: {r}"))
  print(reg_df %>% count(http_status, error_class, stripe_error_type, sort = TRUE))
  
  failures <- reg_df %>% dplyr::filter(is.na(http_status) | http_status < 200 | http_status >= 300)
  if (nrow(failures) > 0) {
    out <- file.path(OUT_DIR, glue::glue("failures_{r}_{format(Sys.time(), '%Y%m%d-%H%M%S')}.csv"))
    readr::write_csv(failures, out, na = "")
    message("  Wrote failures to: ", out)
  }
}

# Combined artefact
combined_path <- file.path(OUT_DIR, glue::glue("results_all_{format(Sys.time(), '%Y%m%d-%H%M%S')}.csv"))
readr::write_csv(res_df, combined_path, na = "")
message("\nWrote combined results to: ", combined_path)

message("\nDone.")