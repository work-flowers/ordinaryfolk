# Starting Stuff ----------------------------------------------------------
pacman::p_load(
  tidyverse,
  lubridate,
  scales,
  zoo,
  keyring,
  bigrquery,
  broom
)

query <- read_file("main_query.sql")

# bigquery configuration
billing <- "noah-e30be"
bq_auth("dennis@work.flowers")

window_size <- 30 # days before and after sample datee
# pull raw data -----------------------------------------------------------

tb <- bigrquery::bq_project_query(billing, query)
df_raw <- bigrquery::bq_table_download(tb)

df_cleaned <- df_raw |> 
  mutate(
    n_days = as.numeric(purchase_date - sample_date),
    pre_post = case_when(
      purchase_date < sample_date ~ "Pre-Sample",
      purchase_date >= sample_date ~ "Post-Sample"
    ),
    test_group = case_when(
      received_not_received == "Received" ~ "Test",
      received_not_received == "Not Received" ~ "Control"
    )
  ) |> 
  filter(abs(n_days) <= window_size)


# calculate aov -----------------------------------------------------------

df_aov <- df_cleaned |> 
  group_by(
    customer_id,
    pre_post,
    region,
    test_group
    ) |> 
    summarise(
      aov = sum(gross_revenue) / n_distinct(charge_id),
      .groups = "drop"
    ) |> 
  pivot_wider(
    names_from = pre_post,
    values_from = aov
  ) |> 
  na.omit() |> 
  mutate(uplift = `Post-Sample` - `Pre-Sample`)

df_aov_summary <- df_aov |> 
  group_by(region, test_group) %>%
  summarise(
    across(
      uplift,
      list(
        mean = ~mean(.x, na.rm = TRUE),
        sd   = ~sd(.x, na.rm = TRUE)
      ),
      .names = "{.fn}_uplift"
    ),
    n = n(),
    .groups = "drop"
  )


df_ttests <- df_aov %>%
  group_by(region) %>%
  summarise(
    ttest = list(t.test(uplift ~ test_group, data = pick(everything()), var.equal = FALSE)),
    .groups = "drop"
  ) %>%
  mutate(ttest = map(ttest, tidy)) %>%   # convert to a tidy tibble
  unnest(ttest)


