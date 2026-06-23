###############################################################################
## Limpieza / tidy de los 3 cuadros MENSUALES (04A, 04C, 04E)
## de la seccion sci/cotycot/ingimp de spensiones.cl
##
## Convierte las tablas crudas (cruzadas, con encabezados de 2 niveles) a
## formato LARGO listo para analisis/regresiones. Reutiliza la cache de
## scrape_spensiones.R (./cache/); si no existe, descarga lo necesario.
##
## Salida (en ./tidy/):
##   mensual_04A_tipo_sexo.csv        -> periodo, tipo, sexo, n_cotizantes, ingreso_imponible_promedio
##   mensual_04C_afp_tipo_sexo.csv    -> periodo, afp, tipo, sexo, ingreso_imponible_promedio
##   mensual_04E_fondo_afp_tipo_sexo.csv -> periodo, fondo, afp, tipo, sexo, ingreso_imponible_promedio
##
## Uso:  Rscript clean_mensuales.R
###############################################################################

library(rvest)
library(httr)
library(dplyr)
library(tidyr)
library(stringr)
library(readr)
library(purrr)

PAGINA <- "https://www.spensiones.cl/apps/centroEstadisticas/paginaCuadrosCCEE.php?menu=sci&menuN1=cotycot&menuN2=ingimp"
BASE   <- "https://www.spensiones.cl/apps/loadEstadisticas/siSP.php"
UA     <- "Mozilla/5.0 (investigacion academica; R/rvest)"

# Editable aqui o via entorno SP_DESDE / SP_HASTA (AAAA/MM; vacio = sin limite)
DESDE <- { v <- Sys.getenv("SP_DESDE", "2018/01"); if (v == "") NULL else v }
HASTA <- { v <- Sys.getenv("SP_HASTA", "2026/12"); if (v == "") NULL else v }

## ---- Helpers ----------------------------------------------------------------

# "1.351.046" -> 1351046 ; "0" -> 0 ; "" / "-" -> NA
num <- function(x) {
  x <- str_replace_all(x, "[^0-9-]", "")
  suppressWarnings(as.numeric(if_else(x %in% c("", "-"), NA_character_, x)))
}

# texto (trim) de las celdas <td> de una fila
celdas <- function(tr) {
  td <- html_elements(tr, "td")
  if (length(td) == 0) return(character(0))
  str_squish(html_text2(td))
}

# Orden FIJO de las 16 columnas de las tablas cruzadas (04C / 04E):
# tipo "afuera", sexo "adentro"  -> DEP[T,M,F,SI], INDEP[...], VOL[...], TOTAL[...]
TIPOS <- c("Dependientes", "Independientes", "Afiliados voluntarios", "Total")
SEXOS <- c("Total", "Masculino", "Femenino", "S/I")
COLS  <- expand_grid(tipo = TIPOS, sexo = SEXOS)   # 16 filas, en el orden correcto

## ---- Parsers por cuadro -----------------------------------------------------

# 04A: jerarquico. Filas de 3 celdas. Las filas DEPENDIENTES/INDEPENDIENTES/
# VOLUNTARIOS son el total del tipo (sexo = "Total"); luego Masculino/Femenino/S/I.
parse_04A <- function(doc, periodo) {
  tipo <- NA_character_; acc <- list()
  for (tr in html_elements(doc, "tr")) {
    c <- celdas(tr); c <- c[c != ""]
    if (length(c) != 3) next
    if (!str_detect(c[2], "[0-9]")) next            # salta encabezados
    lab <- c[1]; U <- str_to_upper(lab)
    if (U %in% c("DEPENDIENTES", "INDEPENDIENTES", "VOLUNTARIOS", "TOTAL")) {
      tipo <- str_to_sentence(lab); sexo <- "Total"   # "TOTAL" = total general (todos los tipos)
    } else if (lab %in% c("Masculino", "Femenino", "S/I")) {
      sexo <- lab
    } else next
    acc[[length(acc) + 1]] <- tibble(
      periodo, tipo, sexo,
      n_cotizantes               = num(c[2]),
      ingreso_imponible_promedio = num(c[3])
    )
  }
  bind_rows(acc)
}

# 04C: tabla cruzada AFP x (tipo x sexo). Filas de datos = 17 celdas
# (1 AFP + 16 valores). Los encabezados son <th>, asi que no aparecen como <td>.
parse_04C <- function(doc, periodo) {
  acc <- list()
  for (tr in html_elements(doc, "tr")) {
    c <- celdas(tr); c <- c[c != ""]
    if (length(c) != 17) next
    vals <- num(c[2:17])
    if (all(is.na(vals))) next
    acc[[length(acc) + 1]] <- bind_cols(
      tibble(periodo, afp = c[1]), COLS,
      tibble(ingreso_imponible_promedio = vals)
    )
  }
  bind_rows(acc)
}

# 04E: igual que 04C pero repetido para los 5 multifondos (A-E). OJO: los
# titulos "FONDO TIPO X" NO estan dentro de las <tr> (van fuera de la tabla),
# asi que el fondo se asigna por ORDEN de bloque. Las etiquetas y su orden se
# extraen del texto del documento; los bloques son consecutivos de igual tamano.
parse_04E <- function(doc, periodo) {
  fondos <- unique(str_match_all(str_to_upper(html_text2(doc)),
                                 "FONDO TIPO ([A-E])")[[1]][, 2])
  if (length(fondos) == 0) fondos <- c("A", "B", "C", "D", "E")  # respaldo

  filas <- list()
  for (tr in html_elements(doc, "tr")) {
    c <- celdas(tr); c <- c[c != ""]
    if (length(c) != 17) next
    vals <- num(c[2:17])
    if (all(is.na(vals))) next
    filas[[length(filas) + 1]] <- list(afp = c[1], vals = vals)
  }
  if (length(filas) == 0) return(tibble())

  n_blq <- max(1L, length(filas) %/% length(fondos))   # AFP por fondo (= 8)
  acc <- map(seq_along(filas), function(k) {
    b <- min((k - 1L) %/% n_blq + 1L, length(fondos))
    bind_cols(
      tibble(periodo, fondo = fondos[b], afp = filas[[k]]$afp), COLS,
      tibble(ingreso_imponible_promedio = filas[[k]]$vals)
    )
  })
  bind_rows(acc)
}

## ---- Descarga con cache (compatible con scrape_spensiones.R) -----------------
dir.create("cache", showWarnings = FALSE)

descargar_html <- function(value) {
  cf <- file.path("cache", paste0(str_replace_all(value, "/", "_"), ".html"))
  if (file.exists(cf)) return(read_file(cf))
  r <- RETRY("GET", BASE,
             query = list(id = paste0(value, ".xls"), menu = "sci",
                          menuN1 = "cotycot", menuN2 = "ingimp", orden = 10, ext = ".xls"),
             # OJO: el endpoint exige Referer; sin el devuelve 404.
             add_headers(`User-Agent` = UA, Referer = PAGINA),
             times = 4, pause_base = 1, timeout(30), quiet = TRUE)
  if (http_error(r)) return(NA_character_)
  txt <- content(r, as = "text", encoding = "ISO-8859-1")
  write_file(txt, cf); Sys.sleep(0.25); txt
}

## ---- Lista de periodos (en vivo desde la pagina) ----------------------------
message("Leyendo periodos disponibles...")
opciones <- read_html(PAGINA) |> html_elements("option") |> html_attr("value")
periodos <- tibble(value = opciones) |>
  filter(str_detect(value, "inf_estadistica/aficot/mensual")) |>
  mutate(codigo  = str_extract(value, "[0-9]{2}[A-Z]$"),
         periodo = str_extract(value, "[0-9]{4}/[0-9]{2}")) |>
  filter(!is.na(codigo), !is.na(periodo),
         is.null(DESDE) | periodo >= DESDE, is.null(HASTA) | periodo <= HASTA)

## ---- Procesa los 3 cuadros --------------------------------------------------
dir.create("tidy", showWarnings = FALSE)

procesa <- function(cod, parser, archivo) {
  per <- periodos |> filter(codigo == cod) |> arrange(periodo)
  if (nrow(per) == 0) { message("  (sin periodos) ", cod); return(invisible()) }
  out <- map_dfr(seq_len(nrow(per)), function(i) {
    html <- descargar_html(per$value[i]); if (is.na(html)) return(NULL)
    tryCatch(parser(read_html(html), per$periodo[i]), error = function(e) NULL)
  })
  write_excel_csv(out, file.path("tidy", archivo))
  message(sprintf("OK %s  (%d filas, %d periodos)", archivo, nrow(out), nrow(per)))
}

procesa("04A", parse_04A, "mensual_04A_tipo_sexo.csv")
procesa("04C", parse_04C, "mensual_04C_afp_tipo_sexo.csv")
procesa("04E", parse_04E, "mensual_04E_fondo_afp_tipo_sexo.csv")

message("Listo. Revisa la carpeta ./tidy/")
