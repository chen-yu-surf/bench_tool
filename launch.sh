#!/bin/bash
# Benchmark test tool for hackbench and schbench evaluation
# Usage:
#   ./launch.sh hackbench <result_name>
#   ./launch.sh schbench <result_name>
#   ./launch.sh compare hackbench <result_name1> <result_name2>
#   ./launch.sh compare schbench <result_name1> <result_name2>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
HACKBENCH_BIN="${SCRIPT_DIR}/rt-tests/hackbench"
SCHBENCH_BIN="${SCRIPT_DIR}/schbench/schbench"

# ============================================================
# User-customizable parameters - modify these as needed
# ============================================================

# hackbench: groups to test
HACKBENCH_GROUPS=(1)
# hackbench: file descriptors to test
HACKBENCH_FDS=(2 4)
# hackbench: modes to test (threads, process, or both)
HACKBENCH_MODES=(threads process)

# schbench: message threads to test
SCHBENCH_MSG_THREADS=(1)
# schbench: worker threads per message thread to test
SCHBENCH_WORKER_THREADS=(2 4)
# schbench: warmup time in seconds (stats are reset after warmup)
SCHBENCH_WARMUP=5

# Number of iterations per configuration (for std-err calculation)
NUM_RUNS=3

# ============================================================
# CPU tuning for stable benchmarking
# ============================================================

setup_cpu_for_bench() {
    echo "Setting up CPU for benchmarking..."

    # Save original settings for restore
    ORIG_GOVERNOR=""
    ORIG_TURBO=""
    local cpu0_gov="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [ -f "$cpu0_gov" ]; then
        ORIG_GOVERNOR=$(cat "$cpu0_gov")
    fi

    # 1. Set cpufreq governor to performance
    if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$gov" 2>/dev/null || true
        done
        echo "  [OK] cpufreq governor set to 'performance'"
    else
        echo "  [SKIP] cpufreq governor not available"
    fi

    # 2. Disable turbo boost
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        ORIG_TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        echo "  [OK] Intel turbo boost disabled"
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        ORIG_TURBO=$(cat /sys/devices/system/cpu/cpufreq/boost)
        echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        echo "  [OK] CPU boost disabled"
    else
        echo "  [SKIP] Turbo/boost control not available"
    fi

    # 3. Disable C-states deeper than C1
    if ls /sys/devices/system/cpu/cpu*/cpuidle/state*/disable &>/dev/null; then
        for state_dir in /sys/devices/system/cpu/cpu*/cpuidle/state*/; do
            local state_name
            state_name=$(cat "${state_dir}/name" 2>/dev/null || echo "")
            local state_idx
            state_idx=$(basename "$state_dir" | sed 's/state//')
            # Disable states with index > 1 (keep C0 and C1)
            if [ "$state_idx" -gt 1 ] 2>/dev/null; then
                echo 1 > "${state_dir}/disable" 2>/dev/null || true
            fi
        done
        echo "  [OK] C-states deeper than C1 disabled"
    else
        echo "  [SKIP] cpuidle control not available"
    fi

    echo ""
}

restore_cpu_settings() {
    echo ""
    echo "Restoring CPU settings..."

    # Restore governor
    if [ -n "$ORIG_GOVERNOR" ]; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "$ORIG_GOVERNOR" > "$gov" 2>/dev/null || true
        done
        echo "  [OK] cpufreq governor restored to '${ORIG_GOVERNOR}'"
    fi

    # Restore turbo
    if [ -n "$ORIG_TURBO" ]; then
        if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
            echo "$ORIG_TURBO" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
            echo "$ORIG_TURBO" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        fi
        echo "  [OK] Turbo/boost restored"
    fi

    # Re-enable C-states
    if ls /sys/devices/system/cpu/cpu*/cpuidle/state*/disable &>/dev/null; then
        for state_dir in /sys/devices/system/cpu/cpu*/cpuidle/state*/; do
            local state_idx
            state_idx=$(basename "$state_dir" | sed 's/state//')
            if [ "$state_idx" -gt 1 ] 2>/dev/null; then
                echo 0 > "${state_dir}/disable" 2>/dev/null || true
            fi
        done
        echo "  [OK] C-states re-enabled"
    fi
}

# ============================================================

usage() {
    echo "Usage:"
    echo "  $0 hackbench <result_name>    - Run hackbench benchmark"
    echo "  $0 schbench <result_name>     - Run schbench benchmark"
    echo "  $0 compare hackbench <name1> <name2> - Compare two hackbench results"
    echo "  $0 compare schbench <name1> <name2>  - Compare two schbench results"
    exit 1
}

check_result_unique() {
    local bench="$1"
    local name="$2"
    local result_dir="${RESULTS_DIR}/${bench}/${name}"
    if [ -d "$result_dir" ]; then
        echo "WARNING: Result '${name}' already exists for ${bench} at:"
        echo "  ${result_dir}"
        read -r -p "Overwrite? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$result_dir"
        else
            echo "Aborted."
            exit 1
        fi
    fi
}

check_result_exists() {
    local bench="$1"
    local name="$2"
    local result_dir="${RESULTS_DIR}/${bench}/${name}"
    if [ ! -d "$result_dir" ]; then
        echo "Error: Result '${name}' does not exist for ${bench}"
        echo "Available results:"
        ls "${RESULTS_DIR}/${bench}/" 2>/dev/null || echo "  (none)"
        exit 1
    fi
}

run_hackbench() {
    local result_name="$1"
    local result_dir="${RESULTS_DIR}/hackbench/${result_name}"

    check_result_unique "hackbench" "$result_name"

    if [ ! -x "$HACKBENCH_BIN" ]; then
        echo "Building hackbench..."
        make -C "${SCRIPT_DIR}/rt-tests" hackbench
    fi

    mkdir -p "$result_dir"

    setup_cpu_for_bench
    trap restore_cpu_settings EXIT INT TERM

    echo "========================================="
    echo "Running hackbench benchmark: ${result_name}"
    echo "Groups: ${HACKBENCH_GROUPS[*]}"
    echo "FDs: ${HACKBENCH_FDS[*]}"
    echo "Modes: ${HACKBENCH_MODES[*]}"
    echo "Runs per config: ${NUM_RUNS}"
    echo "========================================="

    for mode in "${HACKBENCH_MODES[@]}"; do
        for grp in "${HACKBENCH_GROUPS[@]}"; do
            for fd in "${HACKBENCH_FDS[@]}"; do
                echo "[hackbench] mode=${mode} groups=${grp} fds=${fd} (${NUM_RUNS} runs) ..."
                local times=""
                for ((run=1; run<=NUM_RUNS; run++)); do
                    if [ "$run" -gt 1 ]; then
                        sync
                        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
                        sleep 1
                    fi
                    local outfile="${result_dir}/${mode}_g${grp}_f${fd}_run${run}.txt"
                    "$HACKBENCH_BIN" -g "$grp" --${mode} --pipe -l 3000000 -s 100 -f "$fd" \
                        > "$outfile" 2>&1 || true
                    local t
                    t=$(grep -oP 'Time:\s+\K[0-9]+\.[0-9]+' "$outfile" 2>/dev/null || echo "")
                    if [ -n "$t" ]; then
                        times="${times} ${t}"
                    fi
                done
                # Compute mean and stderr, save summary
                local summary="${result_dir}/${mode}_g${grp}_f${fd}.summary"
                echo "$times" | awk '{
                    n=0; sum=0; sumsq=0
                    for(i=1;i<=NF;i++){n++;sum+=$i;sumsq+=$i*$i}
                    if(n>0){mean=sum/n}else{mean=0}
                    if(n>1){stderr=sqrt((sumsq/n-mean*mean)/(n-1))}else{stderr=0}
                    if(mean>0){pct=stderr/mean*100}else{pct=0}
                    printf "mean=%.3f stderr=%.3f pct_stderr=%.2f n=%d\n", mean, stderr, pct, n
                }' > "$summary"
                local stats
                stats=$(cat "$summary")
                echo "  -> ${stats}"
            done
        done
    done

    echo ""
    echo "Results saved to: ${result_dir}"
    restore_cpu_settings
    trap - EXIT INT TERM
    echo "Done."
}

run_schbench() {
    local result_name="$1"
    local result_dir="${RESULTS_DIR}/schbench/${result_name}"

    check_result_unique "schbench" "$result_name"

    if [ ! -x "$SCHBENCH_BIN" ]; then
        echo "Building schbench..."
        make -C "${SCRIPT_DIR}/schbench"
    fi

    mkdir -p "$result_dir"

    setup_cpu_for_bench
    trap restore_cpu_settings EXIT INT TERM

    echo "========================================="
    echo "Running schbench benchmark: ${result_name}"
    echo "Message threads: ${SCHBENCH_MSG_THREADS[*]}"
    echo "Worker threads: ${SCHBENCH_WORKER_THREADS[*]}"
    echo "========================================="

    for msg in "${SCHBENCH_MSG_THREADS[@]}"; do
        for thd in "${SCHBENCH_WORKER_THREADS[@]}"; do
            echo "[schbench] msg_threads=${msg} worker_threads=${thd} (${NUM_RUNS} runs) ..."
            local wlat_vals="" rlat_vals="" rps_vals=""
            for ((run=1; run<=NUM_RUNS; run++)); do
                if [ "$run" -gt 1 ]; then
                    sync
                    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
                    sleep 1
                fi
                local outfile="${result_dir}/m${msg}_t${thd}_run${run}.txt"
                "$SCHBENCH_BIN" -m "$msg" -t "$thd" -r 100 -w "$SCHBENCH_WARMUP" \
                    > "$outfile" 2>&1 || true

                # Extract last occurrence of each metric (final cumulative block)
                local wlat rlat rps
                wlat=$(grep -A5 'Wakeup Latencies' "$outfile" 2>/dev/null | grep -oP '99\.0th:\s+\K[0-9]+' | tail -1 || echo "")
                rlat=$(grep -A5 'Request Latencies' "$outfile" 2>/dev/null | grep -oP '99\.0th:\s+\K[0-9]+' | tail -1 || echo "")
                rps=$(grep -oP 'average rps:\s+\K[0-9]+(\.[0-9]+)?' "$outfile" 2>/dev/null | tail -1 || echo "")
                [ -n "$wlat" ] && wlat_vals="${wlat_vals} ${wlat}"
                [ -n "$rlat" ] && rlat_vals="${rlat_vals} ${rlat}"
                [ -n "$rps" ] && rps_vals="${rps_vals} ${rps}"
            done

            # Compute mean and stderr for each metric
            local summary="${result_dir}/m${msg}_t${thd}.summary"
            {
                echo "$wlat_vals" | awk '{
                    n=0;sum=0;sumsq=0
                    for(i=1;i<=NF;i++){n++;sum+=$i;sumsq+=$i*$i}
                    if(n>0){mean=sum/n}else{mean=0}
                    if(n>1){se=sqrt((sumsq/n-mean*mean)/(n-1))}else{se=0}
                    printf "wlat_p99 mean=%.1f stderr=%.1f n=%d\n",mean,se,n}'
                echo "$rlat_vals" | awk '{
                    n=0;sum=0;sumsq=0
                    for(i=1;i<=NF;i++){n++;sum+=$i;sumsq+=$i*$i}
                    if(n>0){mean=sum/n}else{mean=0}
                    if(n>1){se=sqrt((sumsq/n-mean*mean)/(n-1))}else{se=0}
                    printf "rlat_p99 mean=%.1f stderr=%.1f n=%d\n",mean,se,n}'
                echo "$rps_vals" | awk '{
                    n=0;sum=0;sumsq=0
                    for(i=1;i<=NF;i++){n++;sum+=$i;sumsq+=$i*$i}
                    if(n>0){mean=sum/n}else{mean=0}
                    if(n>1){se=sqrt((sumsq/n-mean*mean)/(n-1))}else{se=0}
                    printf "rps_avg mean=%.1f stderr=%.1f n=%d\n",mean,se,n}'
            } > "$summary"

            echo "  -> wlat_p99: $(sed -n '1p' "$summary")"
            echo "  -> rlat_p99: $(sed -n '2p' "$summary")"
            echo "  -> rps_avg:  $(sed -n '3p' "$summary")"
        done
    done

    echo ""
    echo "Results saved to: ${result_dir}"
    restore_cpu_settings
    trap - EXIT INT TERM
    echo "Done."
}

compare_hackbench() {
    local name1="$1"
    local name2="$2"

    check_result_exists "hackbench" "$name1"
    check_result_exists "hackbench" "$name2"

    local dir1="${RESULTS_DIR}/hackbench/${name1}"
    local dir2="${RESULTS_DIR}/hackbench/${name2}"

    echo "========================================="
    echo "Hackbench comparison"
    printf "BASE: %s\n" "$name1" | fold -w 75
    printf "TEST: %s\n" "$name2" | fold -w 75
    echo "========================================="
    printf "%-7s %2s %3s | %15s | %15s | %7s | %s\n" \
        "MODE" "G" "FD" "BASE(s)" "TEST(s)" "DIFF%" "RESULT"
    printf "%-7s %2s %3s-+-%15s-+-%15s-+-%7s-+-%s\n" \
        "-------" "--" "---" "---------------" "---------------" "-------" "---------"

    # Auto-detect modes/groups/fds from summary files in both result dirs
    local all_summaries
    all_summaries=$(ls "${dir1}"/*.summary "${dir2}"/*.summary 2>/dev/null | xargs -I{} basename {} .summary | sort -u)

    for entry in $all_summaries; do
        local mode grp fd
        mode=$(echo "$entry" | sed 's/_g[0-9]*_f[0-9]*//')
        grp=$(echo "$entry" | grep -oP '(?<=_g)\d+')
        fd=$(echo "$entry" | grep -oP '(?<=_f)\d+')

        local sum1="${dir1}/${entry}.summary"
        local sum2="${dir2}/${entry}.summary"

        local mean1="N/A" se1="" mean2="N/A" se2=""
        local diff_pct="N/A"
        local diff_disp="N/A"
        local verdict="-"

        if [ -f "$sum1" ]; then
            mean1=$(awk -F'[ =]+' '{print $2}' "$sum1")
            se1=$(awk -F'[ =]+' '{print $4}' "$sum1")
        fi
        if [ -f "$sum2" ]; then
            mean2=$(awk -F'[ =]+' '{print $2}' "$sum2")
            se2=$(awk -F'[ =]+' '{print $4}' "$sum2")
        fi

        local disp1="${mean1}"
        local disp2="${mean2}"
        if [ -n "$se1" ] && [ "$mean1" != "N/A" ] && [ "$mean1" != "0" ]; then
            local pct1
            pct1=$(awk "BEGIN {printf \"%.1f\", $se1/$mean1*100}")
            disp1="${mean1}/${pct1}%"
        fi
        if [ -n "$se2" ] && [ "$mean2" != "N/A" ] && [ "$mean2" != "0" ]; then
            local pct2
            pct2=$(awk "BEGIN {printf \"%.1f\", $se2/$mean2*100}")
            disp2="${mean2}/${pct2}%"
        fi

        if [ "$mean1" != "N/A" ] && [ "$mean2" != "N/A" ]; then
            diff_pct=$(awk "BEGIN {d=($mean1-$mean2)/$mean1*100; printf \"%.2f\", d}")
            diff_disp="${diff_pct}%"
            local sign
            sign=$(awk "BEGIN {print ($mean2 < $mean1) ? 1 : 0}")
            if [ "$sign" -eq 1 ]; then
                verdict="IMPROVED"
            else
                local same
                same=$(awk "BEGIN {print ($mean2 == $mean1) ? 1 : 0}")
                if [ "$same" -eq 1 ]; then
                    verdict="SAME"
                else
                    verdict="REGRESSED"
                fi
            fi
        fi

        printf "%-7s %2s %3s | %15s | %15s | %7s | %s\n" \
            "$mode" "$grp" "$fd" "$disp1" "$disp2" "$diff_disp" "$verdict"
    done

    echo ""
    echo "Note: BASE/TEST values are mean/stderr% seconds."
    echo "      DIFF = (BASE - TEST) / BASE * 100."
    echo "      Positive means TEST is faster; negative means regression."
}

compare_schbench() {
    local name1="$1"
    local name2="$2"

    check_result_exists "schbench" "$name1"
    check_result_exists "schbench" "$name2"

    local dir1="${RESULTS_DIR}/schbench/${name1}"
    local dir2="${RESULTS_DIR}/schbench/${name2}"

    echo "========================================="
    echo "Schbench Comparison: ${name1} vs ${name2}"
    echo "========================================="
    echo ""

    # Auto-detect configurations from summary files
    local all_configs
    all_configs=$(ls "${dir1}"/m*_t*.summary "${dir2}"/m*_t*.summary 2>/dev/null | xargs -I{} basename {} .summary | sort -u)

    for entry in $all_configs; do
        local msg thd
        msg=$(echo "$entry" | grep -oP '(?<=m)\d+')
        thd=$(echo "$entry" | grep -oP '(?<=_t)\d+')
        local sum1="${dir1}/${entry}.summary"
        local sum2="${dir2}/${entry}.summary"

            echo "--- msg_threads=${msg} worker_threads=${thd} ---"
            printf "  %-16s | %18s | %18s | %10s | %s\n" \
                "METRIC" "${name1}" "${name2}" "DIFF(%)" "VERDICT"
            printf "  %-16s-+-%18s-+-%18s-+-%10s-+-%s\n" \
                "----------------" "------------------" "------------------" "----------" "----------"

            # Process each metric line: wlat_p99, rlat_p99, rps_avg
            local metrics=("wlat_p99" "rlat_p99" "rps_avg")
            local labels=("Wakeup Lat p99" "Request Lat p99" "Avg RPS")
            # For latency metrics, lower is better; for RPS, higher is better
            local higher_better=(0 0 1)

            for idx in 0 1 2; do
                local metric="${metrics[$idx]}"
                local label="${labels[$idx]}"
                local hb="${higher_better[$idx]}"

                local mean1="N/A" se1="" mean2="N/A" se2=""
                local diff_pct="N/A"
                local verdict="-"

                if [ -f "$sum1" ]; then
                    mean1=$(grep "^${metric}" "$sum1" 2>/dev/null | awk -F'[ =]+' '{print $3}')
                    se1=$(grep "^${metric}" "$sum1" 2>/dev/null | awk -F'[ =]+' '{print $5}')
                fi
                if [ -f "$sum2" ]; then
                    mean2=$(grep "^${metric}" "$sum2" 2>/dev/null | awk -F'[ =]+' '{print $3}')
                    se2=$(grep "^${metric}" "$sum2" 2>/dev/null | awk -F'[ =]+' '{print $5}')
                fi

                [ -z "$mean1" ] && mean1="N/A"
                [ -z "$mean2" ] && mean2="N/A"

                local disp1="${mean1}"
                local disp2="${mean2}"
                if [ -n "$se1" ] && [ "$mean1" != "N/A" ] && [ "$mean1" != "0" ]; then
                    local pct1
                    pct1=$(awk "BEGIN {printf \"%.2f\", $se1/$mean1*100}")
                    disp1="${mean1} ±${pct1}%"
                fi
                if [ -n "$se2" ] && [ "$mean2" != "N/A" ] && [ "$mean2" != "0" ]; then
                    local pct2
                    pct2=$(awk "BEGIN {printf \"%.2f\", $se2/$mean2*100}")
                    disp2="${mean2} ±${pct2}%"
                fi

                if [ "$mean1" != "N/A" ] && [ "$mean2" != "N/A" ] && [ "$mean1" != "0" ]; then
                    if [ "$hb" -eq 0 ]; then
                        # Lower is better: positive diff = improvement
                        diff_pct=$(awk "BEGIN {d=($mean1-$mean2)/$mean1*100; printf \"%.2f\", d}")
                        local cmp
                        cmp=$(awk "BEGIN {print ($mean2 < $mean1) ? 1 : ($mean2 == $mean1) ? 0 : -1}")
                    else
                        # Higher is better: positive diff = improvement
                        diff_pct=$(awk "BEGIN {d=($mean2-$mean1)/$mean1*100; printf \"%.2f\", d}")
                        local cmp
                        cmp=$(awk "BEGIN {print ($mean2 > $mean1) ? 1 : ($mean2 == $mean1) ? 0 : -1}")
                    fi
                    if [ "$cmp" = "1" ]; then
                        verdict="IMPROVED"
                    elif [ "$cmp" = "0" ]; then
                        verdict="SAME"
                    else
                        verdict="REGRESSED"
                    fi
                fi

                printf "  %-16s | %18s | %18s | %9s%% | %s\n" \
                    "$label" "$disp1" "$disp2" "$diff_pct" "$verdict"
            done
            echo ""
    done

    echo "Note: Values shown as mean ±%stddev."
    echo "      Latency metrics (usec): Positive DIFF = improvement (lower latency)."
    echo "      RPS metric: Positive DIFF = improvement (higher throughput)."
}

# ============================================================
# Main
# ============================================================

if [ $# -lt 2 ]; then
    usage
fi

case "$1" in
    hackbench)
        if [ $# -ne 2 ]; then
            usage
        fi
        run_hackbench "$2"
        ;;
    schbench)
        if [ $# -ne 2 ]; then
            usage
        fi
        run_schbench "$2"
        ;;
    compare)
        if [ $# -ne 4 ]; then
            echo "Usage: $0 compare <hackbench|schbench> <name1> <name2>"
            exit 1
        fi
        case "$2" in
            hackbench)
                compare_hackbench "$3" "$4"
                ;;
            schbench)
                compare_schbench "$3" "$4"
                ;;
            *)
                echo "Error: Unknown benchmark '$2'. Use 'hackbench' or 'schbench'."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Error: Unknown command '$1'"
        usage
        ;;
esac
