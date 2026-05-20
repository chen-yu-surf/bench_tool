#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Intel Corporation

cd "$(dirname "$0")" 2>/dev/null || exit 1
SCRIPT_DIR="$PWD"

# ---------------------------------------------------------------------------
# Topology detection — run once at startup, used by all test functions
# ---------------------------------------------------------------------------
# LLC_IDS    : space-separated list of unique LLC ids (e.g. "0 1 2 3")
# LLC_COUNT  : number of LLCs
# LLC_SIZE   : number of CPUs per LLC (assumes uniform)
# LLC_CPUS_<id> : comma-separated CPU list for each LLC
# ---------------------------------------------------------------------------
LLC_IDS=$(for cpu in $(seq 0 $(($(nproc) - 1))); do
    cat /sys/devices/system/cpu/cpu${cpu}/cache/index3/id
done | sort -un)
LLC_COUNT=$(echo "$LLC_IDS" | wc -w)
for _llc_id in $LLC_IDS; do
    eval "LLC_CPUS_${_llc_id}=$(for cpu in $(seq 0 $(($(nproc) - 1))); do
        [ "$(cat /sys/devices/system/cpu/cpu${cpu}/cache/index3/id)" = "$_llc_id" ] && echo $cpu
    done | tr '\n' ',' | sed 's/,$//')"
done
LLC_SIZE=$(echo "$LLC_CPUS_0" | tr ',' '\n' | wc -l)
# SMT_THREADS: hardware threads per core, counted from the siblings of the
# first CPU of LLC0 (thread_siblings_list is e.g. "0,16" or "0-1").
_first_cpu=${LLC_CPUS_0%%,*}
SMT_THREADS=$(for _range in $(tr ',' ' ' < /sys/devices/system/cpu/cpu${_first_cpu}/topology/thread_siblings_list); do
    seq "${_range%-*}" "${_range#*-}"
done | wc -l)
LLC_CORES=$(( LLC_SIZE / SMT_THREADS ))
# DEFAULT_NTHREADS: 70% of the cores of an LLC. invalid_llc_nr() treats the
# SMT siblings of a core as one available core: it refuses to aggregate once
# nr_running * cpu_smt_num_threads exceeds ~80% of the LLC's CPUs, i.e. ~80%
# of its cores. At least 2 threads, as a single threaded process is never
# aggregated.
DEFAULT_NTHREADS=$(( LLC_CORES * 7 / 10 ))
[ "$DEFAULT_NTHREADS" -lt 2 ] && DEFAULT_NTHREADS=2
echo "Detected $LLC_COUNT LLCs, $LLC_SIZE CPUs ($LLC_CORES cores) each (DEFAULT_NTHREADS=$DEFAULT_NTHREADS)"

# Rebuild test_llc_agg with -DNTHREADS=N; called at source-time with DEFAULT_NTHREADS
# and by individual tests that need a different count. Falls back to prebuilt binary if
# gcc is unavailable.
build_llc_agg() {
    local _n=${1:-$DEFAULT_NTHREADS}
    if gcc -O2 -pthread -DNTHREADS="$_n" \
        -o "$SCRIPT_DIR/test_llc_agg" "$SCRIPT_DIR/test_llc_agg.c"; then
        return 0
    fi
    if [ -x "$SCRIPT_DIR/test_llc_agg" ]; then
        echo "[WARN] gcc build of test_llc_agg (NTHREADS=$_n) failed; using existing binary"
        return 0
    fi
    echo "[ERROR] cannot build test_llc_agg (NTHREADS=$_n) and no prebuilt binary present" >&2
    return 1
}

build_llc_agg "$DEFAULT_NTHREADS" && \
    echo "Built test_llc_agg (NTHREADS=$DEFAULT_NTHREADS)"

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}
PASS_THRESHOLD=${PASS_THRESHOLD:-2}

# ---------------------------------------------------------------------------
# llc_balancing parameter save/restore
# ---------------------------------------------------------------------------
LLC_PARAMS="enabled aggr_tolerance epoch_period epoch_affinity_timeout overaggr_pct imb_pct"
LLC_DBG=/sys/kernel/debug/sched/llc_balancing

save_llc_params() {
    for _p in $LLC_PARAMS; do
        if [ -r "$LLC_DBG/$_p" ]; then
            # enabled may read as "[always] advise never"; keep the selected mode
            eval "LLC_ORIG_${_p}=\$(sed -n 's/.*\[\(.*\)\].*/\1/p; /\[/!p' $LLC_DBG/$_p)"
        fi
    done
    echo "baseline llc_balancing: $(for _p in $LLC_PARAMS; do
        eval "printf '%s=%s ' \"$_p\" \"\$LLC_ORIG_${_p}\""
    done)"
}

restore_llc_params() {
    for _p in $LLC_PARAMS; do
        eval "_v=\$LLC_ORIG_${_p}"
        [ -n "$_v" ] && [ -w "$LLC_DBG/$_p" ] && echo "$_v" > "$LLC_DBG/$_p"
    done
    echo "llc_balancing baseline restored"
}

# ---------------------------------------------------------------------------
# Asym packing save/disable/restore
# ---------------------------------------------------------------------------
# With asymmetric core priorities (Intel ITMT, AMD preferred cores) the load
# balancer packs tasks onto the highest priority cores (SD_ASYM_PACKING). If
# those sit in one LLC, tasks aggregate there without cache aware scheduling,
# so convergence passes vacuously and the "stay spread" checks fail.
# Writing N to sched_itmt_enabled rebuilds the sched domains without
# SD_ASYM_PACKING.
ITMT_CTL=/sys/kernel/debug/x86/sched_itmt_enabled
ITMT_ORIG=""

disable_asym_packing() {
    if [ ! -e "$ITMT_CTL" ]; then
        echo "asym packing: $ITMT_CTL not present, nothing to disable"
        return 0
    fi
    ITMT_ORIG=$(cat "$ITMT_CTL")
    if [ "$ITMT_ORIG" = N ]; then
        echo "asym packing: already disabled"
        return 0
    fi
    echo N > "$ITMT_CTL" 2>/dev/null
    if [ "$(cat "$ITMT_CTL")" != N ]; then
        echo "[ERROR] cannot disable asym packing via $ITMT_CTL" >&2
        return 1
    fi
    echo "asym packing: disabled (sched_itmt_enabled $ITMT_ORIG -> N)"
}

restore_asym_packing() {
    [ -n "$ITMT_ORIG" ] && [ -w "$ITMT_CTL" ] || return 0
    echo "$ITMT_ORIG" > "$ITMT_CTL"
    echo "asym packing restored (sched_itmt_enabled=$ITMT_ORIG)"
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# Get LLC ID for a given CPU.
get_llc_id() {
    local cpu=$1
    cat /sys/devices/system/cpu/cpu${cpu}/cache/index3/id
}

# Get LLC distribution for all threads of a process.
get_proc_llc_dist() {
    local pid=$1
    for cpu in $(cat /proc/$pid/task/*/stat 2>/dev/null | awk '{print $39}'); do
        get_llc_id $cpu
    done | sort | uniq -c | sort -rn | awk '{printf "LLC%s:%s ", $2, $1}'
    echo
}

# Get LLC distribution for worker threads only (state=R, excludes main thread).
get_proc_llc_dist_workers() {
    local pid=$1
    local main_tid=$pid
    # shellcheck disable=SC2231
    for stat in /proc/$pid/task/*/stat; do
        read -r fields < "$stat" 2>/dev/null || continue
        tid=$(echo "$fields"   | awk '{print $1}')
        state=$(echo "$fields" | awk '{print $3}')
        cpu=$(echo "$fields"   | awk '{print $39}')
        [ "$tid" = "$main_tid" ] && continue
        [ "$state" = "R" ] && get_llc_id $cpu
    done | sort | uniq -c | sort -rn | awk '{printf "LLC%s:%s ", $2, $1}'
    echo
}

# Get the dominant LLC id for a process (LLC with most running workers).
get_top_llc() {
    get_proc_llc_dist_workers $1 | tr ' ' '\n' | grep "^LLC" | head -1 | cut -d: -f1 | sed 's/LLC//'
}

# Check convergence: pass if all active worker threads are on a single LLC.
check_convergence() {
    local pid=$1
    local total unique_llcs

    # shellcheck disable=SC2231
    total=$(for stat in /proc/$pid/task/*/stat; do
        read -r fields < "$stat" 2>/dev/null || continue
        tid=$(echo "$fields"   | awk '{print $1}')
        state=$(echo "$fields" | awk '{print $3}')
        [ "$tid" = "$pid" ] && continue
        [ "$state" = "R" ] && echo "$tid"
    done | wc -l)

    if [ "$total" -eq 0 ]; then
        echo "  [WARN] no running worker threads found for PID $pid"
        return 1
    fi

    unique_llcs=$(get_proc_llc_dist_workers $pid | tr ' ' '\n' | grep -c "^LLC")
    unique_llcs=${unique_llcs:-0}
    echo "  worker_threads=$total  llcs_used=$unique_llcs"
    [ "$unique_llcs" -eq 1 ]
}

# Saturate a CPU list with one pinned busy loop per CPU. PIDs go to HOG_PIDS
# so stop_cpu_hogs (also run from the exit trap) can kill them.
HOG_PIDS=""
start_cpu_hogs() {
    local cpu
    for cpu in ${1//,/ }; do
        taskset -c "$cpu" bash -c 'while :; do :; done' &
        HOG_PIDS="$HOG_PIDS $!"
    done
}

stop_cpu_hogs() {
    [ -n "$HOG_PIDS" ] || return 0
    # shellcheck disable=SC2086
    kill $HOG_PIDS 2>/dev/null
    # shellcheck disable=SC2086
    wait $HOG_PIDS 2>/dev/null
    HOG_PIDS=""
}

# Scatter all worker threads of PID round-robin across all LLCs, then release affinity.
scatter_workers() {
    local pid=$1
    local tids
    tids=$(ls /proc/$pid/task/ | grep -v "^${pid}$")
    local count=0
    local llc_arr=($LLC_IDS)
    for tid in $tids; do
        local llc_id=${llc_arr[$((count % LLC_COUNT))]}
        eval "local cpus=\$LLC_CPUS_${llc_id}"
        # shellcheck disable=SC2154
        taskset -p -c "$cpus" $tid > /dev/null 2>&1
        count=$(( count + 1 ))
    done
    sleep 0.05
    # shellcheck disable=SC2045
    for tid in $(ls /proc/$pid/task/); do
        taskset -p -c 0-$(($(nproc) - 1)) $tid > /dev/null 2>&1
    done
}

# Scatter workers across all LLCs, release affinity, poll until convergence.
# Returns 0 on converge, 1 on timeout.
launch_and_converge() {
    local _pid_var=$1
    local _llc_var=$2
    local _monitor_secs=$3
    local _interval=$4
    local _threshold=$5

    "$SCRIPT_DIR/test_llc_agg" &
    local _pid=$!
    eval "$_pid_var=$_pid"
    echo "Started test_llc_agg PID=$_pid"
    sleep 0.2

    local _tids
    _tids=$(ls /proc/$_pid/task/ | grep -v "^${_pid}$")
    local _total
    _total=$(echo "$_tids" | wc -w)
    local _count=0
    local _llc_arr=($LLC_IDS)
    echo "Scattering $_total workers round-robin across $LLC_COUNT LLCs..."
    for _tid in $_tids; do
        local _llc_id=${_llc_arr[$((_count % LLC_COUNT))]}
        eval "local _cpus=\$LLC_CPUS_${_llc_id}"
        taskset -p -c "$_cpus" $_tid > /dev/null 2>&1
        _count=$(( _count + 1 ))
    done

    sleep 0.05
    echo "t=0s (after scatter, pre-convergence):"
    echo "    all:     $(get_proc_llc_dist $_pid)"
    echo "    workers: $(get_proc_llc_dist_workers $_pid)"
    echo ""
    echo "Removing CPU affinity restrictions so scheduler can converge..."
    # shellcheck disable=SC2045
    for _tid in $(ls /proc/$_pid/task/); do
        taskset -p -c 0-$(($(nproc) - 1)) $_tid > /dev/null 2>&1
    done
    echo ""

    local _consecutive=0
    local _elapsed=0

    while [ "$(echo "$_elapsed < $_monitor_secs" | bc)" -eq 1 ]; do
        sleep $_interval
        _elapsed=$(echo "$_elapsed + $_interval" | bc)

        if ! kill -0 $_pid 2>/dev/null; then
            echo "  [ERROR] process $_pid exited unexpectedly"
            return 1
        fi

        echo "t=${_elapsed}s  workers: $(get_proc_llc_dist_workers $_pid)"
        if check_convergence $_pid; then
            _consecutive=$(( _consecutive + 1 ))
            echo "  => converged ($_consecutive/$_threshold consecutive)"
            if [ $_consecutive -ge $_threshold ]; then
                local _converged_llc
                _converged_llc=$(get_top_llc $_pid)
                eval "$_llc_var=$_converged_llc"
                echo "  => converged on LLC${_converged_llc}"
                return 0
            fi
        else
            _consecutive=0
        fi
    done

    echo "[FAIL] process did not converge in ${_monitor_secs}s"
    return 1
}

# ---------------------------------------------------------------------------
# F1: Verify workers converge onto a single LLC; confirm spread when disabled.
# ---------------------------------------------------------------------------
run_test_llc_agg() {
    local MONITOR_SECS=${MONITOR_SECS:-60}
    local PID=""

    echo "=== Phase 1: LLC aggregation ==="
    local converged_llc=""
    local result="FAIL"

    if launch_and_converge PID converged_llc "$MONITOR_SECS" "$SAMPLE_INTERVAL" "$PASS_THRESHOLD"; then
        result="PASS"
    fi

    echo ""
    echo "----------------------------------------"
    echo "test_llc_agg phase 1 result: $result"
    echo "----------------------------------------"

    kill $PID 2>/dev/null
    wait $PID 2>/dev/null

    echo ""
    echo "Phase 2: disabling llc_balancing (enabled=0)..."
    echo 0 > /sys/kernel/debug/sched/llc_balancing/enabled

    "$SCRIPT_DIR/test_llc_agg" &
    PID=$!
    echo "Started test_llc_agg PID=$PID"
    sleep 0.2

    echo "Scattering workers and releasing affinity..."
    scatter_workers $PID
    echo "t=0s  workers: $(get_proc_llc_dist_workers $PID)"
    echo ""

    echo "Monitoring for ${MONITOR_SECS}s (sample every ${SAMPLE_INTERVAL}s)..."
    echo ""

    elapsed=0
    local phase2_result="PASS"

    while [ "$(echo "$elapsed < $MONITOR_SECS" | bc)" -eq 1 ]; do
        sleep $SAMPLE_INTERVAL
        elapsed=$(echo "$elapsed + $SAMPLE_INTERVAL" | bc)

        if ! kill -0 $PID 2>/dev/null; then
            echo "  [ERROR] process $PID exited unexpectedly"
            phase2_result="ERROR"
            break
        fi

        echo "t=${elapsed}s  LLC distribution:"
        echo "    all:     $(get_proc_llc_dist $PID | tr '\n' ' ')"
        echo "    workers: $(get_proc_llc_dist_workers $PID | tr '\n' ' ')"

        if check_convergence $PID; then
            echo "  => FAIL (aggregation occurred despite llc_balancing=0)"
            phase2_result="FAIL"
            break
        else
            echo "  => spread (still no aggregation at t=${elapsed}s)"
        fi
        echo ""
    done

    echo ""
    echo "----------------------------------------"
    echo "test_llc_agg phase 2 result: $phase2_result"
    echo "(PASS = threads stayed spread, aggregation correctly suppressed)"
    echo "----------------------------------------"

    echo 1 > /sys/kernel/debug/sched/llc_balancing/enabled

    kill $PID 2>/dev/null
    wait $PID 2>/dev/null

    [ "$result" = "PASS" ] && [ "$phase2_result" = "PASS" ]
}

# ---------------------------------------------------------------------------
# F2: Verify process re-converges onto a new LLC when preferred one is saturated.
# ---------------------------------------------------------------------------
run_test_llc_reselect() {
    local MONITOR_SECS=${MONITOR_SECS:-60}
    local SATURATION_SECS=20
    local PID=""

    echo "=== Phase 1: waiting for LLC convergence ==="
    local converged_llc=""

    if ! launch_and_converge PID converged_llc "$MONITOR_SECS" "$SAMPLE_INTERVAL" "$PASS_THRESHOLD"; then
        kill $PID 2>/dev/null; wait $PID 2>/dev/null
        return 1
    fi

    echo ""
    echo "=== Phase 2: saturating LLC${converged_llc} — expecting re-convergence onto a new LLC ==="
    local SAT_CPUS
    eval "SAT_CPUS=\$LLC_CPUS_${converged_llc}"

    start_cpu_hogs "$SAT_CPUS"
    echo "busy loops saturating LLC${converged_llc} ($SAT_CPUS), one pinned per CPU..."

    elapsed=0
    local phase2_result="FAIL"
    local consecutive_pass=0
    while [ "$(echo "$elapsed < $SATURATION_SECS" | bc)" -eq 1 ]; do
        sleep $SAMPLE_INTERVAL
        elapsed=$(echo "$elapsed + $SAMPLE_INTERVAL" | bc)

        if ! kill -0 $PID 2>/dev/null; then
            echo "  [ERROR] process $PID exited unexpectedly"
            break
        fi

        echo "t=${elapsed}s  workers: $(get_proc_llc_dist_workers $PID)"

        if check_convergence $PID; then
            local new_llc
            new_llc=$(get_top_llc $PID)
            if [ "$new_llc" != "$converged_llc" ]; then
                consecutive_pass=$(( consecutive_pass + 1 ))
                echo "  => re-converged on new LLC${new_llc} ($consecutive_pass/$PASS_THRESHOLD consecutive)"
                if [ $consecutive_pass -ge $PASS_THRESHOLD ]; then
                    phase2_result="PASS"
                    break
                fi
            else
                consecutive_pass=0
                echo "  => still converged on saturated LLC${new_llc}"
            fi
        else
            consecutive_pass=0
            echo "  => spread (re-selection in progress)"
        fi
    done

    stop_cpu_hogs
    echo "busy loops released"

    echo ""
    echo "----------------------------------------"
    echo "test_llc_reselect phase 2 result: $phase2_result"
    echo "----------------------------------------"

    kill $PID 2>/dev/null; wait $PID 2>/dev/null

    [ "$phase2_result" = "PASS" ]
}

# ---------------------------------------------------------------------------
# F3: Verify two processes settle onto different LLCs via even scatter.
# ---------------------------------------------------------------------------
run_test_two_proc() {
    local MONITOR_SECS=${MONITOR_SECS:-60}
    local PID1="" PID2=""

    echo "=== Phase 1: waiting for proc1 to converge ==="
    # shellcheck disable=SC2034
    local proc1_llc=""

    if ! launch_and_converge PID1 proc1_llc "$MONITOR_SECS" "$SAMPLE_INTERVAL" "$PASS_THRESHOLD"; then
        kill $PID1 2>/dev/null; wait $PID1 2>/dev/null
        return 1
    fi

    echo ""
    echo "=== Phase 2: launching proc2, scattering evenly across all LLCs ==="
    "$SCRIPT_DIR/test_llc_agg" &
    local PID2=$!
    echo "Started proc2 PID=$PID2"
    sleep 0.2

    echo "Scattering proc2 workers and releasing affinity..."
    scatter_workers $PID2
    echo "t=0s  proc1: $(get_proc_llc_dist_workers $PID1)  proc2: $(get_proc_llc_dist_workers $PID2)"
    echo ""

    elapsed=0
    local consecutive_pass=0
    local result="FAIL"

    while [ "$(echo "$elapsed < $MONITOR_SECS" | bc)" -eq 1 ]; do
        sleep $SAMPLE_INTERVAL
        elapsed=$(echo "$elapsed + $SAMPLE_INTERVAL" | bc)

        if ! kill -0 $PID1 2>/dev/null || ! kill -0 $PID2 2>/dev/null; then
            echo "  [ERROR] a process exited unexpectedly"
            result="ERROR"
            break
        fi

        local dist1 dist2
        dist1=$(get_proc_llc_dist_workers $PID1)
        dist2=$(get_proc_llc_dist_workers $PID2)
        echo "t=${elapsed}s"
        echo "  proc1 workers: $dist1"
        echo "  proc2 workers: $dist2"

        local llcs1 llcs2 top1 top2
        llcs1=$(echo "$dist1" | tr ' ' '\n' | grep -c "^LLC")
        llcs2=$(echo "$dist2" | tr ' ' '\n' | grep -c "^LLC")
        top1=$(get_top_llc $PID1)
        top2=$(get_top_llc $PID2)

        if [ "$llcs1" -eq 1 ] && [ "$llcs2" -eq 1 ] && [ "$top1" != "$top2" ]; then
            consecutive_pass=$(( consecutive_pass + 1 ))
            echo "  => PASS: proc1 on LLC${top1}, proc2 on LLC${top2} ($consecutive_pass/$PASS_THRESHOLD consecutive)"
            if [ $consecutive_pass -ge $PASS_THRESHOLD ]; then
                result="PASS"
                break
            fi
        else
            consecutive_pass=0
            if [ "$llcs2" -gt 1 ]; then
                echo "  => proc2 still converging..."
            elif [ "$top1" = "$top2" ]; then
                echo "  => proc2 converged on proc1's LLC${top2} (not yet separated)"
            else
                echo "  => proc1 not on a single LLC"
            fi
        fi
        echo ""
    done

    echo ""
    echo "----------------------------------------"
    echo "test_two_proc result: $result"
    echo "----------------------------------------"

    kill $PID1 $PID2 2>/dev/null
    wait $PID1 $PID2 2>/dev/null

    [ "$result" = "PASS" ]
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 -t <test>"
    echo ""
    echo "Available tests:"
    echo "  test_llc_agg       Basic LLC aggregation"
    echo "  test_llc_reselect  Preferred LLC re-selection under saturation"
    echo "  test_two_proc      Two processes separate onto different LLCs"
    echo ""
    echo "Environment overrides:"
    echo "  MONITOR_SECS=<n>       Observation window in seconds (default varies per test)"
    echo "  SAMPLE_INTERVAL=1      Seconds between samples"
    exit 1
}

TEST=""

while getopts "t:" opt; do
    case $opt in
        t) TEST="$OPTARG" ;;
        *) usage ;;
    esac
done

[ -z "$TEST" ] && usage

if pgrep -x test_llc_agg > /dev/null 2>&1; then
    echo "Killing stale test_llc_agg processes..."
    pkill -x test_llc_agg 2>/dev/null
    sleep 0.5
fi

save_llc_params

trap "restore_llc_params
      restore_asym_packing
      pkill -x test_llc_agg 2>/dev/null
      stop_cpu_hogs" EXIT INT TERM

disable_asym_packing || exit 1

echo 1 > /sys/kernel/debug/sched/llc_balancing/enabled
echo ""

case "$TEST" in
    test_llc_agg)       run_test_llc_agg ;;
    test_llc_reselect)  run_test_llc_reselect ;;
    test_two_proc)      run_test_two_proc ;;
    *) echo "Unknown test: $TEST"; usage ;;
esac
