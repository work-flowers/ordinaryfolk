
# setup -------------------------------------------------------------------
pacman::p_load(
  tidyverse,
  keyring,
  httr2,
  jsonlite,
  stringr,
  bigrquery,
  googlesheets4
)

google_user <- "dennis@work.flowers"

# google sheet for source data
gs4_auth(google_user)
sheet_url <- "https://docs.google.com/spreadsheets/d/1roA7asZKfNFd_y2NZr827DqWJyyS2rGTh4GWzhfcupo/edit"
sheet_name <- "(SG) Product Cost"
row_start <- 108
range <- "A4:M"

# get data from sheet 
ss <- gs4_get(sheet_url)
df_raw <- read_sheet(ss, sheet = sheet_name, range = range)

# filter for relevant rows
df_final <- df_raw[row_start:nrow(df_raw),] |> 
  transmute(
    product_id = id,
    name = Name,
    condition = Condition
  )


# function to update products ---------------------------------------------------------

update_product <- function(product_id, condition_name, region) {
  req <- httr2::request(
    glue::glue("https://api.stripe.com/v1/products/{product_id}")
    ) |>
    httr2::req_headers(
      Authorization     = paste("Bearer", keyring::key_get("of_stripe", toupper(region))),
    ) |>
    httr2::req_body_form(
      `metadata[condition]` = condition_name,
    )
  
  out <- req_perform(req)
} 


# run loop ----------------------------------------------------------------

for (i in 1:nrow(df_final)) {
  
  product_id <- df_final$product_id[i]
  condition_name <- df_final$condition[i]
  
  response <- update_product(product_id, condition_name, region = "SG")
  
  if (response$status_code == 200) {
    message(str_glue("Set condition of {product_id} to {condition_name}. {i} of {nrow(df_final)}"))
  } else {
    message(str_glue("Failed to update {product_id}. Error: {response$error$message}"))
  }
}
