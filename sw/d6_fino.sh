#!/bin/sh
# ---------------------------------------------------------------------------
# d6_fino.sh - Power against number of channels, with an uncertainty.
#
# The first version measured once stopped and once running. With 32 and 64
# channels that was enough, but with 4 and 8 the result fell inside the
# INA260's noise (+-0.02 W) and one of the points came out NEGATIVE, which is
# physically impossible. A number like that is not data, it is a warning that
# the method does not reach.
#
# Here stopped/running is ALTERNATED many times and the differences averaged.
# That does two things a single measurement cannot:
#
#   - it cancels drift. The board warms up during the run, and with a single
#     measurement that whole drift lands on the delta. Alternating, it is
#     shared between the two phases and subtracts out.
#   - it brings the noise down with the square root of the number of cycles.
#
# And the STANDARD ERROR is reported next to the mean. A delta of 5 mW with an
# error of 1 mW is a measurement; the same delta with an error of 20 mW says
# nothing, and you have to be able to tell them apart at a glance.
#
#     sudo sh d6_fino.sh [cycles]        (default 12)
# ---------------------------------------------------------------------------

CYCLES="${1:-12}"
PHASE=8                     # seconds per phase

HOMEDIR=$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)
[ -d "$HOMEDIR" ] || HOMEDIR=$HOME
BITS=$HOMEDIR/scanner64/pl/sweep
CTL=$HOMEDIR/scanner64/sw/scanner_ctl
OUT=/tmp/d6_fino.csv

HW=""
for h in /sys/class/hwmon/hwmon*; do
    if [ "$(cat "$h/name" 2>/dev/null)" = "ina260_u14" ]; then HW="$h"; fi
done
[ -z "$HW" ] && { echo "cannot find the INA260"; exit 1; }

# Mean power in microwatts over $1 seconds.
mean_uw() {
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

echo "N_CH,delta_mW,error_mW,cycles,idle_W" > $OUT
echo
printf "%5s %12s %12s %14s\n" N_CH "delta (mW)" "+-error" "idle (W)"

for N in 4 8 16 32 64; do
    B=$BITS/scanner64_n$N.bit.bin
    [ -f "$B" ] || { echo "missing $B"; continue; }

    fpgautil -b "$B" -f Full > /dev/null 2>&1
    sleep 3
    NCH=$($CTL info 2>/dev/null | awk '/channels/{print $3}')
    [ "$NCH" = "$N" ] || { echo "N=$N: the bitstream says $NCH. Skipping."; continue; }

    # Tune something real: with the channels on empty band the dynamic power
    # would be that of a filter not filtering anything interesting.
    $CTL test $N > /dev/null 2>&1

    sum=0; sum2=0; c=0; ref=0
    while [ $c -lt $CYCLES ]; do
        # Nothing in the background: the script is in charge and the scanner
        # obeys. Killing a `run` halfway left the generator on and the next
        # "stopped" phase was measuring the scanner running.
        $CTL stop > /dev/null 2>&1
        sleep 1
        P0=$(mean_uw $PHASE)

        $CTL start > /dev/null 2>&1
        sleep 1
        P1=$(mean_uw $PHASE)

        d=$(( (P1 - P0) / 1000 ))       # milliwatts
        sum=$(( sum + d ))
        sum2=$(( sum2 + d * d ))
        ref=$P0
        c=$(( c + 1 ))
        printf "  N=%s cycle %s/%s: %s mW      " "$N" "$c" "$CYCLES" "$d" >&2
    done
    $CTL stop > /dev/null 2>&1

    # Mean and standard error of the mean.
    MEAN=$(awk "BEGIN{printf \"%.1f\", $sum/$c}")
    ERR=$(awk "BEGIN{v=($sum2 - $sum*$sum/$c)/($c-1); if(v<0)v=0; printf \"%.1f\", sqrt(v/$c)}")
    IDLE=$(awk "BEGIN{printf \"%.3f\", $ref/1000000}")

    echo "$N,$MEAN,$ERR,$c,$IDLE" >> $OUT
    printf "%5s %12s %12s %14s\n" "$N" "$MEAN" "$ERR" "$IDLE"
done

echo
echo "Written to $OUT"
