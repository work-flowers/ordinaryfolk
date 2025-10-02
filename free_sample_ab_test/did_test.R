# Starting Stuff ----------------------------------------------------------
pacman::p_load(
  tidyverse,
  keyring,
  bigrquery,
  broom,
  sandwich,
  stringr,
  lmtest,
  gt
)

query <- read_file("main_query.sql")

# bigquery configuration
billing <- "noah-e30be"
bq_auth("dennis@work.flowers")

# read in the SQL query file you uploaded
sql <- read_file("main_query.sql")

window_size <- 30 # days before and after sample datee

# pull data ---------------------------------------------------------------

df <- bq_project_query(billing, sql) %>%
  bq_table_download()


# types and treatment/period flags
dat <- df %>%
  mutate(
    region = factor(region),
    test = as.integer(str_to_lower(received_not_received) == "received"),
    period = if_else(purchase_date < sample_date, "pre", "post"),
    post = as.integer(period == "post"),
    n_days = as.numeric(purchase_date - sample_date)
  ) |> 
  filter(abs(n_days) <= window_size)

# build customer × period outcome: distinct products bought in that period
cust_period <- dat %>%
  group_by(
    customer_id, 
    region, 
    test, 
    period, 
    post
    ) %>%
  summarise(products = n_distinct(product_id), .groups = "drop")


# helper for clustered SE
tidy_cl <- function(m, ids) {
  vc <- vcovCL(m, cluster = ids, type = "HC1")
  broom::tidy(coeftest(m, vcov. = vc), conf.int = TRUE)
}

fit_region <- cust_period %>%
  group_by(region) %>%
  group_modify(~{
    if (n_distinct(.x$test) < 2 || n_distinct(.x$post) < 2 || nrow(.x) < 4) {
      return(
        tibble(
          term = character(),
          estimate = double(),
          conf.low = double(),
          conf.high = double(),
          p.value = double()
          )
        )
    }
    m <- lm(products ~ test*post, data = .x)
    tidy_cl(m, .x$customer_id)
  }) %>%
  ungroup() %>%
  filter(term == "test:post") %>%
  arrange(region)

# Pooled with region fixed effects
m_pooled <- lm(products ~ test*post + region, data = cust_period)
pooled <- tidy_cl(m_pooled, cust_period$customer_id) %>%
  filter(term == "test:post")

# Cell means to mirror the chart
cell_means <- cust_period %>%
  group_by(
      region, 
      group = if_else(test == 1, "Test", "Control"), 
      period
      ) %>%
  summarise(avg_products = mean(products), .groups = "drop") %>%
  arrange(region, group, period)

print(cell_means)  # should match plotted values in Tableau
print(fit_region)  # SG/HK DiD effect, CI, p
print(pooled)      # overall DiD effect

fit_region %>%
  select(region, estimate, conf.low, conf.high, p.value) %>%
  gt() %>%
  fmt_number(
    columns = c(estimate, conf.low, conf.high, p.value),
    decimals = 3
    ) %>%
  cols_label(
    region = "Region",
    estimate = "Estimate",
    conf.low = "95% CI Low",
    conf.high = "95% CI High",
    p.value = "p-value"
  ) %>%
  tab_header(
    title = "Difference-in-Differences Results by Region"
  )
