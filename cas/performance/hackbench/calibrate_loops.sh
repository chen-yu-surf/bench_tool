#!/bin/bash
#
# calibrate_loops.sh <hackbench-dir> <out-loops.conf>
#
# Run as root on the BASE kernel. For every config of the sweep (MODES_LIST x
# GROUPS_LIST x FDS_LIST, normally eval'ed from test_all.sh) find the -l that
# makes ONE hackbench run last >= MIN_SEC seconds and as close to MIN_SEC as
# possible. Every step is a single hackbench run (no repetitions):
#
#   1. probe:  start at PROBE_LOOPS and grow until one run takes >= PROBE_SEC,
#              so the time estimate isn't dominated by startup cost.
#   2. aim:    -l = l * AIM_SEC / t, where AIM_SEC = MIN_SEC * AIM (slightly
#              above MIN_SEC to absorb run-to-run noise), run once.
#   3. accept: if MIN_SEC <= t <= MIN_SEC * MAX_OVER, accept. Otherwise rescale
#              from the last run and try again, up to MAX_TRIES. If no try
#              landed in the window, keep the shortest try that was >= MIN_SEC.
#              If none was >= MIN_SEC, the config fails.
#
# The output loops.conf ("mode grp fd loops" per line, the format that
# launch_hackbench.sh run reads) is then frozen and reused unchanged for every
# run of every kernel. The calibration time of each config is written to
# <out>.times.
#
# Env: MIN_SEC (30)  AIM (1.03)  MAX_OVER (1.10)  MAX_TRIES (8)
#      PROBE_LOOPS (10000)  PROBE_SEC (3)
set -u

HB_DIR="${1:?usage: $0 <hackbench-dir> <out-loops.conf>}"
OUT="${2:?usage: $0 <hackbench-dir> <out-loops.conf>}"
BIN="$HB_DIR/rt-tests/hackbench"
MIN_SEC=${MIN_SEC:-30}
AIM=${AIM:-1.03}
MAX_OVER=${MAX_OVER:-1.10}
MAX_TRIES=${MAX_TRIES:-8}
PROBE_LOOPS=${PROBE_LOOPS:-10000}
PROBE_SEC=${PROBE_SEC:-3}

read -r -a MODES <<< "${MODES_LIST:?MODES_LIST not set}"
read -r -a GRPS  <<< "${GROUPS_LIST:?GROUPS_LIST not set}"
read -r -a FDS   <<< "${FDS_LIST:?FDS_LIST not set}"

AIM_SEC=$(awk -v m="$MIN_SEC" -v a="$AIM" 'BEGIN { printf "%.3f", m * a }')
HI_SEC=$(awk -v m="$MIN_SEC" -v o="$MAX_OVER" 'BEGIN { printf "%.3f", m * o }')

hb_time() {   # mode grp fd loops -> seconds
    "$BIN" -g "$2" --"$1" --pipe -l "$4" -s 100 -f "$3" < /dev/null 2>&1 \
        | grep -oP 'Time:\s+\K[0-9]+\.[0-9]+'
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
scale() {     # loops t target -> new loops (always changes by >= 1%)
    awk -v l="$1" -v t="$2" -v g="$3" 'BEGIN {
        n = int(l * g / t + 0.5)
        if (t < g && n <= l) n = int(l * 1.01) + 1
        if (t > g && n >= l) n = int(l * 0.99)
        if (n < 1) n = 1
        print n }'
}

echo "calibrate: one run per step, accept ${MIN_SEC}s <= t <= ${HI_SEC}s, aim ${AIM_SEC}s"
: > "$OUT.tmp"
: > "$OUT.times.tmp"
fail=0
for mode in "${MODES[@]}"; do
for grp in "${GRPS[@]}"; do
for fd in "${FDS[@]}"; do
    # 1. probe
    loops=$PROBE_LOOPS
    while :; do
        t=$(hb_time "$mode" "$grp" "$fd" "$loops")
        [ -n "$t" ] || { echo "  $mode g$grp f$fd -l $loops -> hackbench FAILED"; exit 1; }
        printf "  %-7s g%-2s f%-2s -l %-10s -> %8ss (probe)\n" "$mode" "$grp" "$fd" "$loops" "$t"
        ge "$t" "$PROBE_SEC" && break
        # grow toward PROBE_SEC, at most 100x per step
        loops=$(awk -v l="$loops" -v t="$t" -v p="$PROBE_SEC" 'BEGIN {
            f = (t > 0) ? p * 1.2 / t : 100; if (f > 100) f = 100; if (f < 2) f = 2
            print int(l * f) + 1 }')
    done

    # 2./3. aim at AIM_SEC, accept in [MIN_SEC, HI_SEC]
    best_l="" best_t=""
    ok=0
    for ((try = 1; try <= MAX_TRIES; try++)); do
        loops=$(scale "$loops" "$t" "$AIM_SEC")
        t=$(hb_time "$mode" "$grp" "$fd" "$loops")
        [ -n "$t" ] || { echo "  $mode g$grp f$fd -l $loops -> hackbench FAILED"; exit 1; }
        printf "  %-7s g%-2s f%-2s -l %-10s -> %8ss (try %d)\n" "$mode" "$grp" "$fd" "$loops" "$t" "$try"
        if ge "$t" "$MIN_SEC"; then
            if [ -z "$best_t" ] || ! ge "$t" "$best_t"; then
                best_l=$loops best_t=$t
            fi
            if ! ge "$t" "$HI_SEC" || [ "$t" = "$HI_SEC" ]; then
                ok=1
                break
            fi
        fi
    done

    if [ -z "$best_l" ]; then
        echo "  $mode g$grp f$fd: FAILED, no run reached ${MIN_SEC}s in $MAX_TRIES tries"
        fail=1
        continue
    fi
    [ "$ok" -eq 1 ] || echo "  $mode g$grp f$fd: not within ${HI_SEC}s, using shortest >= ${MIN_SEC}s"
    printf "  => %-7s g%-2s f%-2s -l %s (%ss)\n" "$mode" "$grp" "$fd" "$best_l" "$best_t"
    echo "$mode $grp $fd $best_l" >> "$OUT.tmp"
    echo "$mode $grp $fd $best_l $best_t" >> "$OUT.times.tmp"
done
done
done

mv "$OUT.tmp" "$OUT"
mv "$OUT.times.tmp" "$OUT.times"
echo "Saved: $OUT ($(wc -l < "$OUT") configs)"
[ "$fail" -eq 0 ] && echo "CALIBRATE_OK" || echo "CALIBRATE_INCOMPLETE"
exit "$fail"
