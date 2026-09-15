#!/bin/sh
# ---------------------------------------------------------------------------
# d6_fino.sh - Consumo contra numero de canales, con incertidumbre.
#
# La primera version media una vez parado y una vez corriendo. Con 32 y 64
# canales bastaba, pero con 4 y 8 el resultado quedaba dentro del ruido del
# INA260 (+-0,02 W) y uno de los puntos salio NEGATIVO, que es fisicamente
# imposible. Un numero asi no es un dato, es un aviso de que el metodo no da.
#
# Aqui se ALTERNA parado/corriendo muchas veces y se promedian las diferencias.
# Eso hace dos cosas que una sola medida no puede:
#
#   - cancela la deriva. La placa se calienta durante la tanda, y con una sola
#     medida esa deriva se suma entera al delta. Alternando, se reparte entre
#     las dos fases y se resta.
#   - baja el ruido con la raiz del numero de ciclos.
#
# Y se reporta el ERROR ESTANDAR junto a la media. Un delta de 5 mW con un error
# de 1 mW es una medida; el mismo delta con un error de 20 mW no dice nada, y
# hay que poder distinguirlo de un vistazo.
#
#     sudo sh d6_fino.sh [ciclos]        (por defecto 12)
# ---------------------------------------------------------------------------

CICLOS="${1:-12}"
FASE=8                      # segundos por fase

CASA=$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)
[ -d "$CASA" ] || CASA=$HOME
BITS=$CASA/scanner64/pl/sweep
CTL=$CASA/scanner64/sw/scanner_ctl
OUT=/tmp/d6_fino.csv

HW=""
for h in /sys/class/hwmon/hwmon*; do
    if [ "$(cat "$h/name" 2>/dev/null)" = "ina260_u14" ]; then HW="$h"; fi
done
[ -z "$HW" ] && { echo "no encuentro el INA260"; exit 1; }

# Media de potencia en microvatios durante $1 segundos.
media_uw() {
    n=0; s=0; i=0
    lim=$(( $1 * 5 ))
    while [ $i -lt $lim ]; do
        v=$(cat "$HW/power1_input" 2>/dev/null)
        [ -n "$v" ] && { s=$(( s + v )); n=$(( n + 1 )); }
        i=$(( i + 1 ))
        sleep 0.2
    done
    [ "$n" -gt 0 ] && echo $(( s / n )) || echo 0
}

echo "N_CH,delta_mW,error_mW,ciclos,parado_W" > $OUT
echo
printf "%5s %12s %12s %14s\n" N_CH "delta (mW)" "+-error" "parado (W)"

for N in 4 8 16 32 64; do
    B=$BITS/scanner64_n$N.bit.bin
    [ -f "$B" ] || { echo "falta $B"; continue; }

    fpgautil -b "$B" -f Full > /dev/null 2>&1
    sleep 3
    NCH=$($CTL info 2>/dev/null | awk '/canales/{print $3}')
    [ "$NCH" = "$N" ] || { echo "N=$N: el bitstream dice $NCH. Saltando."; continue; }

    # Sintonizar algo real: con los canales en banda vacia el consumo dinamico
    # seria el de un filtro que no filtra nada interesante.
    $CTL test $N > /dev/null 2>&1

    suma=0; suma2=0; c=0; ref=0
    while [ $c -lt $CICLOS ]; do
        # Nada en segundo plano: el guion manda y el escaner obedece. Matar un
        # `run` a mitad dejaba el generador encendido y la fase de "parado"
        # siguiente medía el escaner corriendo.
        $CTL stop > /dev/null 2>&1
        sleep 1
        P0=$(media_uw $FASE)

        $CTL start > /dev/null 2>&1
        sleep 1
        P1=$(media_uw $FASE)

        d=$(( (P1 - P0) / 1000 ))       # miliwatios
        suma=$(( suma + d ))
        suma2=$(( suma2 + d * d ))
        ref=$P0
        c=$(( c + 1 ))
        printf "  N=%s ciclo %s/%s: %s mW      " "$N" "$c" "$CICLOS" "$d" >&2
    done
    $CTL stop > /dev/null 2>&1

    # Media y error estandar de la media.
    MED=$(awk "BEGIN{printf \"%.1f\", $suma/$c}")
    ERR=$(awk "BEGIN{v=($suma2 - $suma*$suma/$c)/($c-1); if(v<0)v=0; printf \"%.1f\", sqrt(v/$c)}")
    PAR=$(awk "BEGIN{printf \"%.3f\", $ref/1000000}")

    echo "$N,$MED,$ERR,$c,$PAR" >> $OUT
    printf "%5s %12s %12s %14s\n" "$N" "$MED" "$ERR" "$PAR"
done

echo
echo "Escrito en $OUT"
