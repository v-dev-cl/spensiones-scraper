# CLAUDE.md — guía para contribuir (humanos y agentes)

Notas técnicas para extender o mantener este repo sin tener que redescubrir cómo
funciona el sitio de la Superintendencia de Pensiones (SP) de Chile.

## Qué es esto

Scraper en R de la sección **Cotizantes / Ingreso Imponible** (`sci/cotycot/ingimp`) del
Centro de Estadísticas de `spensiones.cl`. Dos scripts:

- `scrape_spensiones.R` — descarga los 19 cuadros crudos → un CSV por cuadro en `csv/`.
- `clean_mensuales.R` — convierte los 3 cuadros mensuales (04A/04C/04E) a formato largo → `tidy/`.

## El modelo del sitio (lo esencial)

- La página **no** renderiza las tablas con JS. El ícono "XLS" solo hace
  `document.location.href = ".../loadEstadisticas/siSP.php?id=<ruta>.xls&menu=...&..."`.
  → **No se necesita RSelenium.** `httr::GET` + `rvest` basta.
- El endpoint devuelve **HTML** (un `<table>`) con `Content-Type: application/vnd.ms-xls`.
  El cuerpo es Latin-1.
- El parámetro `id` = el `value` de un `<option>` del `<select>` de período + `.xls`.
  Formato: `inf_estadistica/aficot/{mensual|trimestral}/AAAA/MM/<código>`.
- `<código>` (p.ej. `04A`, `32C`) distingue cada uno de los 19 cuadros. `orden` y `ext`
  son irrelevantes para el contenido.
- La lista de períodos se lee **en vivo** del `<select>` (no hardcodear meses). Mensuales
  ~283 períodos; trimestrales = cierres de trimestre (03/06/09/12), ~94.

## Gotchas verificados contra datos reales

1. **Encoding.** El servidor entrega `ISO-8859-1`. Siempre
   `content(r, as="text", encoding="ISO-8859-1")`. Si no, salen `Ã±`/`Ã³`.
   Escribir con `write_excel_csv` (UTF-8 + BOM) para que Excel lo abra bien.
2. **Encabezados = `<th>`, datos = `<td>`.** Parsear solo `<td>` excluye los encabezados
   automáticamente. Las filas de datos cruzadas tienen exactamente **17** `<td>`
   (1 etiqueta + 16 valores).
3. **Números:** separador de miles `.` y a veces sin separador. Limpiar con
   `str_replace_all(x, "[^0-9-]", "")` y `as.numeric`. `""`/`-` → `NA`.
4. **Orden de las 16 columnas** en tablas cruzadas: tipo *afuera*, sexo *adentro* →
   `DEPENDIENTES[Total,Masc,Fem,S/I], INDEPENDIENTES[...], AFILIADOS VOLUNTARIOS[...], TOTAL[...]`.
   En R: `expand_grid(tipo = TIPOS, sexo = SEXOS)`.
5. **04A** tiene un 4º bloque `TOTAL` (total general) además de los 3 tipos. La fila del
   tipo es su total → se mapea a `sexo = "Total"`.
6. **04E NO es solo Fondo A.** Concatena los **5 multifondos (A–E)**, cada uno con su
   título `FONDO TIPO X` que está **fuera** de las `<tr>`. → el fondo se asigna por
   **orden de bloque** (8 AFP por fondo: 7 AFP + TOTAL). 55 `<tr>` = 5×(3 th + 8 td).
   Las etiquetas A–E se extraen de `html_text2(doc)` con `FONDO TIPO ([A-E])` (en orden).

## Catálogo de códigos (orden de la página)

| código | tipo | dimensiones |
|--------|------|-------------|
| `04A` | mensual    | tipo × sexo (nº cotizantes + ingreso) |
| `04C` | mensual    | AFP × tipo × sexo (ingreso) |
| `04E` | mensual    | fondo × AFP × tipo × sexo (ingreso) |
| `13C` `14C` `19B` `24C` `25C` `26C` `27C` | trimestral | cotizantes por tramo de ingreso × AFP (varios cortes por sexo/dependencia) |
| `32A` `32B` `32C` `33A` `33B` `33C` `34A` `34B` `34C` | trimestral | ingreso promedio por actividad económica / región / AFP (total/hombres/mujeres) |

## Convenciones del repo

- R ≥ 4.1 (pipe nativo `|>`). Paquetes: rvest, httr, dplyr, tidyr, stringr, readr, purrr.
- `cache/`, `csv/`, `tidy/` están en `.gitignore` (son artefactos, no se versionan).
- **Cortesía con el servidor:** `Sys.sleep(0.25)` entre descargas + `RETRY` con backoff.
  No paralelizar agresivo. La caché en disco evita redescargar.
- Comentarios y mensajes en español, sin tildes en identificadores de código.

## Cómo probar cambios (sin instalar R)

```bash
docker build -t spensiones .
# test offline de parsers: pre-cargar cache/ con HTML reales y correr con --network none
docker run --rm --network none -v "$PWD:/work" spensiones Rscript clean_mensuales.R
```

Para validar un parser nuevo, usar chequeos de consistencia (p.ej. en 04A la fila `Total`
de cada tipo debe igualar la suma `Masculino+Femenino+S/I`).

## Tareas pendientes / extensiones naturales

- Limpieza a formato largo de los **16 cuadros trimestrales** (`clean_trimestrales.R`),
  siguiendo el mismo patrón. Cada familia (13–27 = tramos de ingreso; 32–34 = actividad/
  región) necesita su propio mapeo de columnas.
- Generalizar el scraper a otras secciones del Centro de Estadísticas: cambiar
  `menu/menuN1/menuN2` y el catálogo de códigos; el resto (períodos en vivo, descarga,
  caché) se reutiliza tal cual.
