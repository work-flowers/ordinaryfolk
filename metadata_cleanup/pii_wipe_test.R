
# setup -------------------------------------------------------------------
pacman::p_load(
  tidyverse,
  keyring,
  httr,
  jsonlite,
  stringr,
  bigrquery
)

# get data from sheet 

billing <- "noah-e30be"
bq_auth("dennis@work.flowers")

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
# function to update products ---------------------------------------------------------

remove_pii <- function(payment_intent_id, region) {
  
  response <- POST(
    url = stringr::str_glue("https://api.stripe.com/v1/payment_intents/{payment_intent_id}"),
    add_headers(
      Authorization = paste("Bearer", keyring::key_get("of_stripe", toupper(region))),
      `Content-Type` = "application/x-www-form-urlencoded"
    ),
    body = list(
      `metadata[customer_name]` = "",
      `metadata[customer_email]` = ""
    ),
    encode = "form"
  )
  return(fromJSON(content(response, as = "text", encoding = "UTF-8"), flatten = TRUE))
} 


# run loop ----------------------------------------------------------------

test <- remove_pii("pi_1HZdcXADAOM0ddHnpeoLOtce", "sg")


response <- GET(
  url = stringr::str_glue("https://api.stripe.com/v1/payment_intents/pi_1IGaAYADAOM0ddHnHRAU2q1Y"),
  add_headers(
    Authorization = paste("Bearer", keyring::key_get("of_stripe", toupper("sg"))),
    `Content-Type` = "application/x-www-form-urlencoded"
  )
)
out <- fromJSON(content(response, as = "text", encoding = "UTF-8"), flatten = TRUE)
