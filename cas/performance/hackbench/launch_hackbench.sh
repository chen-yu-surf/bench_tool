#!/bin/bash
#
# launch_hackbench.sh
#
# Part 1 (calibrate): probe every mode/group/fd combo and compute a per-combo
#                     -l loop count so each run lasts ~TARGET_SEC seconds.
# Part 2 (run):       run the real benchmark using the calibrated -l values.
#
# Usage:
#   ./launch_hackbench.sh calibrate            # only calibrate -> loops.conf
#   ./launch_hackbench.sh run <result_name>    # run using existing loops.conf
#   ./launch_hackbench.sh all <result_name>    # calibrate then run
#   ./launch_hackbench.sh compare <base> <test> # compare two result sets
#
# run writes to results/hackbench/<result_name>/:
#   <mode>_g<G>_f<FD>_run<N>.txt  raw hackbench output of each run
#   <mode>_g<G>_f<FD>.summary     mean/stderr/pct_stderr/n/min/max/loops/times
#   raw_results.csv               every run: mode,groups,fds,loops,run,time_s,wall_s,rc,start
#   loops.conf                    the -l of every config used for this result set
#   env.txt                       kernel, cmdline, CPU state, start/end time
#
# Must be run as root (except compare).
set -u

HB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HB_DIR/rt-tests/hackbench"
LOOPS_CONF="$HB_DIR/loops.conf"

TARGET_SEC=${TARGET_SEC:-30}
PROBE_LOOPS=${PROBE_LOOPS:-10000}
CAL_SEC=${CAL_SEC:-5}
NUM_RUNS=${NUM_RUNS:-6}
MIN_LOOPS=${MIN_LOOPS:-1000}

read -r -a MODES <<< "${MODES_LIST:-process threads}"
read -r -a GRPS  <<< "${GROUPS_LIST:-1 2 4 8 16}"
read -r -a FDS   <<< "${FDS_LIST:-1 2 4 8 16 20}"

tune_cpu() {
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null || true
    done
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/; do
        idx=$(basename "$s" | sed 's/state//')
        [ "$idx" -gt 1 ] 2>/dev/null && echo 1 > "${s}/disable" 2>/dev/null || true
    done
    echo "${LLC_ENABLE:-1}" > /sys/kernel/debug/sched/llc_balancing/enabled 2>/dev/null || true
}

hb_time() {
    local mode="$1" grp="$2" fd="$3" loops="$4"
    "$BIN" -g "$grp" --${mode} --pipe -l "$loops" -s 100 -f "$fd" 2>&1 \
        | grep -oP 'Time:\s+\K[0-9]+\.[0-9]+'
}

scale_loops() {
    awk -v l="$1" -v t="$2" -v tgt="$3" -v m="$MIN_LOOPS" \
        'BEGIN { n = (t > 0) ? int(l * tgt / t) : m; if (n < m) n = m; print n }'
}

calibrate() {
    echo "Calibrating for ~${TARGET_SEC}s per run (two-stage probe) ..."
    : > "$LOOPS_CONF"
    for mode in "${MODES[@]}"; do
        for grp in "${GRPS[@]}"; do
            for fd in "${FDS[@]}"; do
                t1=$(hb_time "$mode" "$grp" "$fd" "$PROBE_LOOPS")
                probe=$(scale_loops "$PROBE_LOOPS" "$t1" "$CAL_SEC")
                t2=$(hb_time "$mode" "$grp" "$fd" "$probe")
                loops=$(scale_loops "$probe" "$t2" "$TARGET_SEC")
                echo "$mode $grp $fd $loops" >> "$LOOPS_CONF"
                printf "  %-7s g%-2s f%-2s cal=%ss@%s -> -l %s\n" "$mode" "$grp" "$fd" "$t2" "$probe" "$loops"
            done
        done
    done
    echo "Saved: $LOOPS_CONF"
}

# Snapshot of the test environment, written to <results>/env.txt.
sys_info() {
    local c0=/sys/devices/system/cpu/cpu0 s
    echo "host:          $(hostname)"
    echo "kernel:        $(uname -r)"
    echo "cmdline:       $(cat /proc/cmdline)"
    echo "nproc:         $(nproc)"
    echo "llc_balancing: $(cat /sys/kernel/debug/sched/llc_balancing/enabled 2>/dev/null || echo n/a)"
    echo "governor:      $(cat $c0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    echo "no_turbo:      $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
    echo "scaling_khz:   $(cat $c0/cpufreq/scaling_min_freq 2>/dev/null)-$(cat $c0/cpufreq/scaling_max_freq 2>/dev/null)"
    printf "cpuidle:      "
    for s in $c0/cpuidle/state*; do
        printf " %s:%s" "$(cat "$s/name")" "$([ "$(cat "$s/disable")" = 1 ] && echo off || echo on)"
    done
    echo
}

run() {
    local name="${1:?usage: run <result_name>}"
    local results="$HB_DIR/results/hackbench/$name"
    local raw="$results/raw_results.csv"
    [ -f "$LOOPS_CONF" ] || { echo "No $LOOPS_CONF; run calibrate first."; exit 1; }
    mkdir -p "$results"

    # Record exactly what was run: the -l of every config and the environment.
    cp "$LOOPS_CONF" "$results/loops.conf"
    {
        echo "name:          $name"
        echo "start:         $(date '+%F %T')"
        echo "num_runs:      $NUM_RUNS"
        echo "command:       $BIN -g <G> --<MODE> --pipe -l <LOOPS> -s 100 -f <FD>"
        sys_info
    } > "$results/env.txt"
    # One line per hackbench run. time_s is hackbench's "Time:", wall_s is
    # measured around the hackbench process, rc is its exit code.
    echo "mode,groups,fds,loops,run,time_s,wall_s,rc,start" > "$raw"

    echo "Running '${name}' (${NUM_RUNS} runs/config) ..."
    while read -r mode grp fd loops; do
        [ -z "${mode:-}" ] && continue
        local cfg="${mode}_g${grp}_f${fd}"
        echo "[hackbench] ${mode} g${grp} f${fd} -l ${loops}"
        times=""
        for ((r=1; r<=NUM_RUNS; r++)); do
            if [ "$r" -gt 1 ]; then
                sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; sleep 1
            fi
            out="${results}/${cfg}_run${r}.txt"
            start=$(date '+%F %T')
            t0=$(date +%s.%N)
            "$BIN" -g "$grp" --${mode} --pipe -l "$loops" -s 100 -f "$fd" > "$out" 2>&1
            rc=$?
            t1=$(date +%s.%N)
            wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')
            t=$(grep -oP 'Time:\s+\K[0-9]+\.[0-9]+' "$out" 2>/dev/null || echo "")
            echo "${mode},${grp},${fd},${loops},${r},${t:-NA},${wall},${rc},${start}" >> "$raw"
            if [ -n "$t" ]; then
                times="${times} ${t}"
                echo "  run${r}: ${t}s"
            else
                echo "  run${r}: FAILED (rc=${rc}), see ${out}"
            fi
        done
        # mean= and stderr= must stay fields 2 and 4: compare() reads them.
        echo "$times" | awk -v loops="$loops" '{
            n=0; sum=0; sumsq=0; min=""; max=""; list=""
            for(i=1;i<=NF;i++){
                n++; sum+=$i; sumsq+=$i*$i
                if(min=="" || $i<min) min=$i
                if(max=="" || $i>max) max=$i
                list=list (i>1?",":"") $i
            }
            mean=(n>0)?sum/n:0
            se=(n>1)?sqrt((sumsq/n-mean*mean)/(n-1)):0
            pct=(mean>0)?se/mean*100:0
            printf "mean=%.3f stderr=%.3f pct_stderr=%.2f n=%d min=%s max=%s loops=%s times=%s\n",
                   mean, se, pct, n, (n?min:"NA"), (n?max:"NA"), loops, (n?list:"NA")
        }' > "${results}/${cfg}.summary"
        echo "  -> $(cat "${results}/${cfg}.summary")"
    done < "$LOOPS_CONF"
    echo "end:           $(date '+%F %T')" >> "$results/env.txt"
    echo "Raw results:     $raw"
    echo "Results saved to: $results"
}

compare() {
    local name1="${1:?usage: compare <base> <test>}"
    local name2="${2:?usage: compare <base> <test>}"
    local dir1="$HB_DIR/results/hackbench/$name1"
    local dir2="$HB_DIR/results/hackbench/$name2"

    echo "========================================="
    echo "Hackbench comparison"
    echo "BASE: $name1"
    echo "TEST: $name2"
    echo "========================================="
    printf "%-7s %2s %3s | %15s | %15s | %7s | %s\n" \
        "MODE" "G" "FD" "BASE(s)" "TEST(s)" "DIFF%" "RESULT"
    printf "%-7s %2s %3s-+-%15s-+-%15s-+-%7s-+-%s\n" \
        "-------" "--" "---" "---------------" "---------------" "-------" "---------"

    local all
    all=$(ls "${dir1}"/*.summary "${dir2}"/*.summary 2>/dev/null | xargs -r -I{} basename {} .summary | sort -u)
    for entry in $all; do
        local mode grp fd
        mode=$(echo "$entry" | sed 's/_g[0-9]*_f[0-9]*//')
        grp=$(echo "$entry" | grep -oP '(?<=_g)\d+')
        fd=$(echo "$entry" | grep -oP '(?<=_f)\d+')

        local mean1="N/A" se1="" mean2="N/A" se2=""
        [ -f "${dir1}/${entry}.summary" ] && { mean1=$(awk -F'[ =]+' '{print $2}' "${dir1}/${entry}.summary"); se1=$(awk -F'[ =]+' '{print $4}' "${dir1}/${entry}.summary"); }
        [ -f "${dir2}/${entry}.summary" ] && { mean2=$(awk -F'[ =]+' '{print $2}' "${dir2}/${entry}.summary"); se2=$(awk -F'[ =]+' '{print $4}' "${dir2}/${entry}.summary"); }

        local disp1="$mean1" disp2="$mean2" diff_disp="N/A" verdict="-"
        [ "$mean1" != "N/A" ] && [ "$mean1" != "0" ] && [ -n "$se1" ] && \
            disp1="${mean1}/$(awk "BEGIN{printf \"%.1f\", $se1/$mean1*100}")%"
        [ "$mean2" != "N/A" ] && [ "$mean2" != "0" ] && [ -n "$se2" ] && \
            disp2="${mean2}/$(awk "BEGIN{printf \"%.1f\", $se2/$mean2*100}")%"

        if [ "$mean1" != "N/A" ] && [ "$mean2" != "N/A" ]; then
            diff_disp="$(awk "BEGIN{printf \"%.2f\", ($mean1-$mean2)/$mean1*100}")%"
            verdict=$(awk "BEGIN{print ($mean2<$mean1)?\"IMPROVED\":($mean2==$mean1)?\"SAME\":\"REGRESSED\"}")
        fi

        printf "%-7s %2s %3s | %15s | %15s | %7s | %s\n" \
            "$mode" "$grp" "$fd" "$disp1" "$disp2" "$diff_disp" "$verdict"
    done
    echo ""
    echo "Note: BASE/TEST values are mean/stderr% seconds."
    echo "      DIFF = (BASE - TEST) / BASE * 100."
    echo "      Positive means TEST is faster; negative means regression."
}

cmd="${1:-}"
case "$cmd" in
    calibrate) tune_cpu; calibrate ;;
    run)       tune_cpu; run "${2:-}" ;;
    all)       tune_cpu; calibrate; run "${2:-}" ;;
    compare)   compare "${2:-}" "${3:-}" ;;
    *) echo "usage: $0 {calibrate | run <name> | all <name> | compare <base> <test>}"; exit 1 ;;
esac
