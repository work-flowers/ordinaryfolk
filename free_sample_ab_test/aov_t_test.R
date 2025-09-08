# Starting Stuff ----------------------------------------------------------
pacman::p_load(
  tidyverse,
  lubridate,
  scales,
  zoo,
  keyring,
  bigrquery
)

query <- read_file("main_query.sql")
