###############################################################################
## Descarga de los 19 cuadros de "Cotizantes / Ingreso Imponible" (SP Chile)
## Centro de Estadisticas -> sci / cotycot / ingimp
##
## NO necesita RSelenium: cada cuadro es un <table> HTML servido por
##   https://www.spensiones.cl/apps/loadEstadisticas/siSP.php
## Genera un CSV por cuadro en ./csv/ (todos los periodos apilados).
##
## Uso:  Rscript scrape_spensiones.R
###############################################################################

library(rvest)
library(httr)
library(purrr)
library(dplyr)
library(stringr)
library(readr)

PAGINA <- "https://www.spensiones.cl/apps/centroEstadisticas/paginaCuadrosCCEE.php?menu=sci&menuN1=cotycot&menuN2=ingimp"
BASE   <- "https://www.spensiones.cl/apps/loadEstadisticas/siSP.php"
UA     <- "Mozilla/5.0 (investigacion academica; R/rvest)"

## ---- Filtro de rango. Editable aqui o via variables de entorno --------------
## SP_DESDE / SP_HASTA (formato AAAA/MM). Cadena vacia => sin limite (toda la historia).
DESDE <- { v <- Sys.getenv("SP_DESDE", "2018/01"); if (v == "") NULL else v }
HASTA <- { v <- Sys.getenv("SP_HASTA", "2026/12"); if (v == "") NULL else v }

## ---- Catalogo de los 19 cuadros, en el orden de la pagina -------------------
cuadros <- tribble(
  ~n, ~periodicidad, ~codigo, ~nombre,
   1L, "mensual",    "04A", "Cotizantes e ingreso imponible promedio por tipo y sexo",
   2L, "mensual",    "04C", "Ingreso imponible promedio por tipo, sexo y AFP",
   3L, "mensual",    "04E", "Ingreso imponible promedio Fondo Tipo A por tipo, sexo y AFP",
   4L, "trimestral", "13C", "Cotizantes hombres por ingreso imponible y AFP",
   5L, "trimestral", "14C", "Cotizantes mujeres por ingreso imponible y AFP",
   6L, "trimestral", "19B", "Cotizantes por ingreso imponible y AFP",
   7L, "trimestral", "24C", "Cotizantes dependientes segun ingreso imponible y AFP",
   8L, "trimestral", "25C", "Cotizantes independientes segun ingreso imponible y AFP",
   9L, "trimestral", "26C", "Cotizantes dependientes hombres segun ingreso imponible y AFP",
  10L, "trimestral", "27C", "Cotizantes dependientes mujeres segun ingreso imponible y AFP",
  11L, "trimestral", "32A", "Ingreso imponible promedio por actividad economica y region",
  12L, "trimestral", "32B", "Ingreso imponible promedio por actividad economica y AFP",
  13L, "trimestral", "32C", "Ingreso imponible promedio por region y AFP",
  14L, "trimestral", "33A", "Ingreso imponible promedio hombres por actividad economica y region",
  15L, "trimestral", "33B", "Ingreso imponible promedio hombres por actividad economica y AFP",
  16L, "trimestral", "33C", "Ingreso imponible promedio hombres por region y AFP",
  17L, "trimestral", "34A", "Ingreso imponible promedio mujeres por actividad economica y region",
  18L, "trimestral", "34B", "Ingreso imponible promedio mujeres por actividad economica y AFP",
  19L, "trimestral", "34C", "Ingreso imponible promedio mujeres por region y AFP"
)

## ---- Periodos disponibles: se leen en vivo desde el <select> de la pagina ----
## Asi la lista siempre esta actualizada (no hay que hardcodear meses).
message("Leyendo periodos disponibles desde la pagina...")
opciones <- read_html(PAGINA) |>
  html_elements("option") |>
  html_attr("value")

periodos_tbl <- tibble(value = opciones) |>
  filter(str_detect(value, "inf_estadistica/aficot")) |>
  mutate(
    codigo  = str_extract(value, "[0-9]{2}[A-Z]$"),
    periodo = str_extract(value, "[0-9]{4}/[0-9]{2}")
  ) |>
  filter(!is.na(codigo), !is.na(periodo)) |>
  filter(is.null(DESDE) | periodo >= DESDE, is.null(HASTA) | periodo <= HASTA) |>
  distinct(codigo, periodo, value)

## ---- Descargador robusto (reintentos + cache en disco) ----------------------
dir.create("cache", showWarnings = FALSE)

descargar_tabla <- function(value) {
  cache_file <- file.path("cache", paste0(str_replace_all(value, "/", "_"), ".html"))
  if (file.exists(cache_file)) {
    txt <- read_file(cache_file)
  } else {
    r <- RETRY("GET", BASE,
               query = list(id = paste0(value, ".xls"),
                            menu = "sci", menuN1 = "cotycot", menuN2 = "ingimp",
                            orden = 10, ext = ".xls"),
               # OJO: el endpoint exige Referer; sin el devuelve 404.
               add_headers(`User-Agent` = UA, Referer = PAGINA),
               times = 4, pause_base = 1, timeout(30), quiet = TRUE)
    if (http_error(r)) return(NULL)
    # el servidor declara Latin-1; forzarlo evita los  ile / Ã±
    txt <- content(r, as = "text", encoding = "ISO-8859-1")
    write_file(txt, cache_file)
    Sys.sleep(0.25)  # cortesia con el servidor
  }
  # OJO: algunos cuadros (p.ej. 04E) son VARIAS <table> (una por multifondo);
  # y las tablas cruzadas tienen encabezados repetidos. Por eso:
  #  - tomamos TODAS las <table> (no html_element singular)
  #  - header=FALSE + convert=FALSE -> celdas como texto, sin nombres duplicados
  tablas <- tryCatch(
    read_html(txt) |> html_elements("table") |> html_table(header = FALSE, convert = FALSE),
    error = function(e) list()
  )
  tablas <- tablas |>
    keep(~ nrow(.x) > 0 && ncol(.x) > 0) |>
    map(~ setNames(.x, paste0("c", seq_len(ncol(.x)))))  # nombres posicionales uniformes
  if (length(tablas) == 0) return(NULL)
  bind_rows(tablas)   # apila las sub-tablas (incluye sus filas de encabezado)
}

## ---- Bucle principal: un CSV por cuadro -------------------------------------
dir.create("csv", showWarnings = FALSE)

walk(seq_len(nrow(cuadros)), function(i) {
  cu  <- cuadros[i, ]
  per <- periodos_tbl |> filter(codigo == cu$codigo) |> arrange(desc(periodo))
  if (nrow(per) == 0) { message("  (sin periodos) cuadro ", cu$n); return(invisible()) }

  message(sprintf("Cuadro %02d [%s] %s -- %d periodos",
                  cu$n, cu$codigo, cu$nombre, nrow(per)))

  datos <- map_dfr(seq_len(nrow(per)), function(j) {
    tab <- descargar_tabla(per$value[j])
    if (is.null(tab)) return(NULL)
    tab |> mutate(cuadro = cu$n, codigo = cu$codigo,
                  periodicidad = cu$periodicidad, nombre = cu$nombre,
                  periodo = per$periodo[j], .before = 1)
  })

  archivo <- sprintf("csv/cuadro_%02d_%s.csv", cu$n, cu$codigo)
  write_excel_csv(datos, archivo)   # UTF-8 con BOM: Excel lo abre sin configurar nada
  message(sprintf("   -> %s (%d filas)", archivo, nrow(datos)))
})

message("Listo. Revisa la carpeta ./csv/")
