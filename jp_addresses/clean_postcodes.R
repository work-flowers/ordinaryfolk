# packages
library(readr)
library(dplyr)
library(stringr)
library(tibble)


# --- CONFIG ---
# Path to the Japan Post CSV you downloaded from the UTF-8 page
# (one-record-per-line format, inside the zip)
csv_path <- "KEN_ALL.CSV"   # change if needed

# --- READ (force character to preserve leading zeros) ---
jp <- read_csv(
  csv_path,
  col_names = FALSE,
  locale = locale(encoding = "UTF-8"),
  col_types = cols(.default = col_character()),
  show_col_types = FALSE
)

# Japan Post column names (15 cols)
names(jp) <- c(
  "jis_code","old_postcode","postcode",
  "prefecture_kana","municipality_kana","town_area_kana",
  "prefecture_ja","municipality","town_area",
  "is_multiple_codes","has_subarea","has_chome",
  "multiple_postcodes_area","update_reason_flag","change_reason_flag"
)

# --- JIS prefecture code -> English lookup (01..47) ---
pref_lookup <- tribble(
  ~pref_code, ~prefecture_en,
  "01","Hokkaido","02","Aomori","03","Iwate","04","Miyagi","05","Akita","06","Yamagata","07","Fukushima",
  "08","Ibaraki","09","Tochigi","10","Gunma","11","Saitama","12","Chiba","13","Tokyo","14","Kanagawa",
  "15","Niigata","16","Toyama","17","Ishikawa","18","Fukui","19","Yamanashi","20","Nagano",
  "21","Gifu","22","Shizuoka","23","Aichi","24","Mie",
  "25","Shiga","26","Kyoto","27","Osaka","28","Hyogo","29","Nara","30","Wakayama",
  "31","Tottori","32","Shimane","33","Okayama","34","Hiroshima","35","Yamaguchi",
  "36","Tokushima","37","Kagawa","38","Ehime","39","Kochi",
  "40","Fukuoka","41","Saga","42","Nagasaki","43","Kumamoto","44","Oita","45","Miyazaki","46","Kagoshima","47","Okinawa"
)

# --- Transform & keep only what you need ---
out <- jp %>%
  transmute(
    pref_code = str_sub(jis_code, 1, 2),
    postcode_prefix = str_sub(str_replace_all(postcode, "[^0-9]", ""), 1, 3)
  ) %>%
  left_join(pref_lookup, by = "pref_code") %>%
  filter(str_detect(postcode_prefix, "^[0-9]{3}$")) %>%
  select(postcode_prefix, prefecture_en) %>%
  distinct() %>%
  arrange(postcode_prefix)

# sanity check: should be 0
sum(is.na(out$prefecture_en))

# --- Write outputs ---
write_csv(out, "jp_postcode_prefix_prefecture_en.csv")
