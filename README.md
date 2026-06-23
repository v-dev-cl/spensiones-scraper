# spensiones-scraper

Descarga programática de las estadísticas de **Cotizantes e Ingreso Imponible** del
**Centro de Estadísticas de la Superintendencia de Pensiones de Chile** (`spensiones.cl`),
en R, **sin RSelenium**.

> Sección cubierta: `sci / cotycot / ingimp`
> ([página oficial](https://www.spensiones.cl/apps/centroEstadisticas/paginaCuadrosCCEE.php?menu=sci&menuN1=cotycot&menuN2=ingimp)) —
> 19 cuadros, mensuales y trimestrales, desde 2002 a la fecha.

---

## El hallazgo clave: no se necesita Selenium

La página *parece* dinámica (los cuadros aparecen al hacer clic en un ícono "XLS"),
pero **no se renderizan con JavaScript en el navegador**. El ícono solo redirige a un
script PHP que devuelve la tabla ya construida. Lo que baja es **HTML disfrazado de
`.xls`** (`Content-Type: application/vnd.ms-xls`, pero el cuerpo es un `<table>` limpio).

Por eso `rvest` lo parsea directo y `RSelenium` es innecesario (y mucho más lento/frágil).

### El endpoint real

```
https://www.spensiones.cl/apps/loadEstadisticas/siSP.php
    ?id=<RUTA>.xls          # ej: inf_estadistica/aficot/mensual/2026/04/04A
    &menu=sci&menuN1=cotycot&menuN2=ingimp
    &orden=10&ext=.xls
```

- **`id`** = el `value` del `<select>` de período + `.xls`. **No es `AAAAMM`**: es una
  ruta del tipo `inf_estadistica/aficot/{mensual|trimestral}/AAAA/MM/<código>`.
- **`<código>`** es lo que distingue cada uno de los 19 cuadros (ver tabla abajo).
- `menu/menuN1/menuN2` vienen del menú de la sección.
- `orden` y `ext` son irrelevantes para el contenido (se mantienen por compatibilidad).
- El servidor hace un `302` intermedio: deja que el cliente siga redirecciones
  (`httr` lo hace por defecto; en `curl` usa `-L`).

> **Tip transferible:** antes de recurrir a Selenium en cualquier sitio, abre
> **DevTools → Network → XHR/Doc**, dispara la acción y observa el request real.
> En la mayoría de los casos hay un endpoint directo (PHP/JSON/CSV) que puedes llamar
> con `httr::GET()`. Selenium solo se justifica cuando la data se construye **en el
> cliente** (SPAs React/Vue, scroll infinito, tokens dinámicos, etc.).

---

## Los 19 cuadros

| #  | Tipo        | Código | Cuadro |
|----|-------------|--------|--------|
| 1  | mensual     | `04A`  | Cotizantes e ingreso imponible promedio por tipo y sexo |
| 2  | mensual     | `04C`  | Ingreso imponible promedio por tipo, sexo y AFP |
| 3  | mensual     | `04E`  | Ingreso imponible promedio Fondo Tipo A por tipo, sexo y AFP |
| 4  | trimestral  | `13C`  | Cotizantes hombres por ingreso imponible y AFP |
| 5  | trimestral  | `14C`  | Cotizantes mujeres por ingreso imponible y AFP |
| 6  | trimestral  | `19B`  | Cotizantes por ingreso imponible y AFP |
| 7  | trimestral  | `24C`  | Cotizantes dependientes según ingreso imponible y AFP |
| 8  | trimestral  | `25C`  | Cotizantes independientes según ingreso imponible y AFP |
| 9  | trimestral  | `26C`  | Cotizantes dependientes hombres según ingreso imponible y AFP |
| 10 | trimestral  | `27C`  | Cotizantes dependientes mujeres según ingreso imponible y AFP |
| 11 | trimestral  | `32A`  | Ingreso imponible promedio por actividad económica y región |
| 12 | trimestral  | `32B`  | Ingreso imponible promedio por actividad económica y AFP |
| 13 | trimestral  | `32C`  | Ingreso imponible promedio por región y AFP |
| 14 | trimestral  | `33A`  | Ingreso imponible promedio hombres por actividad económica y región |
| 15 | trimestral  | `33B`  | Ingreso imponible promedio hombres por actividad económica y AFP |
| 16 | trimestral  | `33C`  | Ingreso imponible promedio hombres por región y AFP |
| 17 | trimestral  | `34A`  | Ingreso imponible promedio mujeres por actividad económica y región |
| 18 | trimestral  | `34B`  | Ingreso imponible promedio mujeres por actividad económica y AFP |
| 19 | trimestral  | `34C`  | Ingreso imponible promedio mujeres por región y AFP |

Los **mensuales** llegan hasta ~2002 (≈ 283 períodos c/u); los **trimestrales** son
cierres de trimestre (03/06/09/12, ≈ 94 períodos c/u).

---

## Requisitos

```r
install.packages(c("rvest", "httr", "purrr", "dplyr", "stringr", "readr"))
```

R ≥ 4.1 (se usa el pipe nativo `|>`).

## Uso

```bash
Rscript scrape_spensiones.R
```

Ajusta el rango de fechas editando las variables al inicio del script, o por
**variables de entorno** (útil en Docker/CI) `SP_DESDE` / `SP_HASTA` (formato `AAAA/MM`;
cadena vacía = sin límite, es decir toda la historia):

```r
DESDE <- "2018/01"   # AAAA/MM mínimo  (NULL = toda la historia)
HASTA <- "2026/12"   # AAAA/MM máximo
```

```bash
SP_DESDE=2026/01 SP_HASTA=2026/04 Rscript scrape_spensiones.R   # solo ene–abr 2026
```

### Salida

Un CSV por cuadro en `./csv/`, p. ej. `csv/cuadro_01_04A.csv`, con **todos los períodos
apilados** y columnas de metadatos para filtrar/unir:

| cuadro | codigo | periodicidad | nombre | periodo | …columnas originales del cuadro… |
|--------|--------|--------------|--------|---------|----------------------------------|

Los archivos se guardan como **UTF-8 con BOM** (`write_excel_csv`), así Excel los abre
con tildes y `ñ` correctas sin configurar nada.

---

## Limpieza a formato largo: `clean_mensuales.R`

`scrape_spensiones.R` baja las tablas **fieles a su forma original** (cruzadas, con
encabezados de dos niveles). Para análisis conviene formato *largo* (tidy).
`clean_mensuales.R` lo hace para los tres cuadros **mensuales** (reutiliza la misma
`./cache/`) y deja los resultados en `./tidy/`:

| Archivo | Estructura | Columnas |
|---------|-----------|----------|
| `mensual_04A_tipo_sexo.csv`        | tipo × sexo            | `periodo, tipo, sexo, n_cotizantes, ingreso_imponible_promedio` |
| `mensual_04C_afp_tipo_sexo.csv`    | AFP × tipo × sexo      | `periodo, afp, tipo, sexo, ingreso_imponible_promedio` |
| `mensual_04E_fondo_afp_tipo_sexo.csv` | fondo × AFP × tipo × sexo | `periodo, fondo, afp, tipo, sexo, ingreso_imponible_promedio` |

Detalles no obvios que maneja el parser (verificados contra los datos reales):

- **04A** incluye una fila `TOTAL` (total general) además de los 3 tipos; el total de
  cada tipo queda como `sexo = "Total"`.
- **04E** no es solo "Fondo Tipo A": trae los **5 multifondos (A–E)** concatenados. Los
  títulos `FONDO TIPO X` van *fuera* de las `<tr>`, así que el fondo se asigna por orden
  de bloque (8 AFP por fondo). Quedan 5 × 8 × 16 = 640 filas por período.

Para añadir limpieza de los cuadros **trimestrales**, ver [`CLAUDE.md`](CLAUDE.md).

---

## Correr sin instalar R (Docker)

¿No quieres instalar R? Usa el contenedor. La imagen `rocker/r-ver` trae R con paquetes
**binarios** (instala en segundos, sin compilar):

```bash
docker build -t spensiones .

# se recomienda --user para que los CSV queden a tu nombre (no root), y -e HOME=/tmp:
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e SP_DESDE=2026/01 -e SP_HASTA=2026/04 \
  -v "$PWD:/work" spensiones Rscript scrape_spensiones.R   # CSV crudos

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e SP_DESDE=2026/01 -e SP_HASTA=2026/04 \
  -v "$PWD:/work" spensiones Rscript clean_mensuales.R     # tidy mensuales
```

El volumen `-v "$PWD:/work"` deja `cache/`, `csv/` y `tidy/` en tu disco.

> Pipeline verificado en contenedor contra datos reales (mar 2026): 19 CSVs crudos
> (04E con sus 5 fondos) y los 3 tidy mensuales (04A/04C/04E).

---

## Recomendaciones

1. **Uso responsable / rate limiting.** El script ya incluye `Sys.sleep(0.25)` entre
   descargas y reintentos con backoff. No lo paralelices agresivamente: es un servicio
   público. La historia completa son ~2.350 requests; córrela una vez y reutiliza la caché.

2. **Caché en disco (`./cache/`).** Cada respuesta cruda se guarda. Si el proceso se
   corta, vuelve a correrlo y **no re-descarga** lo ya bajado. Para forzar una
   actualización, borra los `.html` correspondientes (o toda la carpeta).

3. **Encoding.** El servidor entrega **Latin-1** (`ISO-8859-1`). El script lo fuerza al
   leer; si lo adaptas, no omitas ese paso o verás `Ã±`/`Ã³` en lugar de `ñ`/`ó`.

4. **Limpieza por familia de cuadro.** Cada cuadro tiene una estructura distinta (tablas
   cruzadas tipo×sexo, región×AFP, etc.). El script los baja **fieles a su forma
   original** (la primera fila suele ser el título y hay encabezados de dos niveles). Para
   análisis, añade un paso de *tidy* **por familia** —no uno genérico—: descartar la fila
   de título, fijar encabezados y pivotar a formato largo
   (`periodo, afp, sexo, tipo, n_cotizantes, ingreso_promedio`).

5. **Generalizar a otras secciones.** El mismo patrón sirve para el resto del Centro de
   Estadísticas: cambia `menu/menuN1/menuN2` y los `<select>` traerán nuevas rutas `id`.
   El script lee los períodos en vivo desde la página, así que adaptarlo a otra sección es
   sobre todo actualizar el catálogo de códigos.

6. **Reproducibilidad.** Considera fijar versiones con `renv` y registrar la fecha de
   descarga: la SP **revisa cifras** de meses recientes, por lo que un mismo período puede
   cambiar de valor entre corridas.

---

## Aviso legal

Datos públicos de la Superintendencia de Pensiones de Chile. Este proyecto solo
automatiza el acceso a información ya disponible públicamente; respeta los términos de uso
del sitio y cita la fuente en cualquier publicación derivada. Sin afiliación con la SP.

## Licencia

MIT — ver [`LICENSE`](LICENSE).
