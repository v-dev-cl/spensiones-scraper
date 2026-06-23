# Imagen reproducible para correr los scripts sin instalar R en tu máquina.
#
# La base rocker/r-ver trae R + paquetes binarios (rápido, sin compilar).
#
#   docker build -t spensiones .
#   # descarga + CSV crudos:
#   docker run --rm -v "$PWD:/work" spensiones Rscript scrape_spensiones.R
#   # tidy de los mensuales:
#   docker run --rm -v "$PWD:/work" spensiones Rscript clean_mensuales.R
#
# El volumen -v "$PWD:/work" hace que ./cache, ./csv y ./tidy queden en tu disco.

FROM rocker/r-ver:4.4.1

# Librerías de sistema que necesitan xml2/curl/openssl (para rvest/httr)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libxml2-dev libcurl4-openssl-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Paquetes R desde el repo binario de Posit (P3M) -> instala en segundos, sin compilar
RUN install2.r --error --skipinstalled \
        rvest httr dplyr tidyr stringr readr purrr

WORKDIR /work
CMD ["Rscript", "scrape_spensiones.R"]
