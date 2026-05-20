#!/bin/bash
# test_all.sh
# ---------------------------------------------------------------------------
# Cache-Aware Scheduling (CAS) test driver: functional + performance.
#
# Runs on a target host booted into a CAS-capable kernel and tees everything
# into test_all_result.txt.
#
# Usage:  sudo ./test_all.sh [func|prctl|perf|all]
#
#   func   functional/cache_aware_function_tests.sh only (CAS enabled)
#   prctl  functional/cache_aware_functional_tests_prctl.sh only (CAS enabled)
#   perf   performance/hackbench/launch_hackbench.sh sweep (CAS enabled)
#   all    all of the above (default)
#
# launch_hackbench.sh calibrates a per-config -l once (two-stage probe) so each
# run lasts ~TARGET_SEC.
#
# Must be run as root (writes to debugfs / cpufreq / drop_caches).
# ---------------------------------------------------------------------------
set -u

CMD="${1:-all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNC_DIR="${SCRIPT_DIR}/functional"
HB_DIR="${SCRIPT_DIR}/performance/hackbench"
RESULT_FILE="${SCRIPT_DIR}/test_all_result.txt"
CAS_ENABLE="/sys/kernel/debug/sched/llc_balancing/enabled"

# hackbench sweep matrix (consumed by launch_hackbench.sh)
#export MODES_LIST="threads process"
export MODES_LIST="threads"
#export GROUPS_LIST="1 2 4 8 16"
export GROUPS_LIST="1 2 4"
#export FDS_LIST="1 2 4 8 16 20"
export FDS_LIST="1 2 4 20"
export NUM_RUNS="${NUM_RUNS:-3}"
# launch_hackbench.sh calibrates a per-config -l so each run lasts ~TARGET_SEC
# seconds (two-stage probe). Keep this modest for a sanity run; raise for real
# perf work.
export TARGET_SEC="${TARGET_SEC:-5}"
export CAL_SEC="${CAL_SEC:-3}"
# Name of the hackbench result set (results/hackbench/<TESTNAME>); a wrapper
# script can override it.
TESTNAME="${TESTNAME:-testname}"

# Functional test observation window (seconds). Smaller than the default 60s
# to keep the sanity run short; convergence normally happens within a few sec.
export MONITOR_SECS="${MONITOR_SECS:-40}"
export SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"

# ---------------------------------------------------------------------------
# Redirect all output to both stdout and the result file.
# ---------------------------------------------------------------------------
: > "$RESULT_FILE"
exec > >(tee -a "$RESULT_FILE") 2>&1

hr()  { printf '%s\n' "============================================================"; }
log() { echo "[sanity] $*"; }

set_cas() {   # $1 = 0|1
    echo "$1" > "$CAS_ENABLE"
    log "cache_aware_scheduling enabled=$(cat "$CAS_ENABLE")"
}

usage() { echo "Usage: sudo $0 [func|prctl|perf|all]"; exit 1; }

# ---------------------------------------------------------------------------
# Part: functional smoke tests (cache_aware_function_tests.sh), CAS enabled
# ---------------------------------------------------------------------------
run_func() {
    hr
    echo "FUNCTIONAL: cache_aware_function_tests.sh (CAS enabled)"
    hr
    set_cas 1
    declare -A res
    for t in test_llc_agg test_llc_reselect test_two_proc; do
        hr; echo ">>> functional test: $t"; hr
        if "${FUNC_DIR}/cache_aware_function_tests.sh" -t "$t"; then
            res[$t]="PASS"
        else
            res[$t]="FAIL"
        fi
        echo ">>> $t: ${res[$t]}"
    done
    hr
    echo "FUNCTIONAL SUMMARY (CAS enabled):"
    for t in test_llc_agg test_llc_reselect test_two_proc; do
        printf "  %-20s %s\n" "$t" "${res[$t]:-SKIP}"
    done
    hr
}

# ---------------------------------------------------------------------------
# Part: prctl functional tests (cache_aware_functional_tests_prctl.sh)
# ---------------------------------------------------------------------------
run_prctl() {
    hr
    echo "FUNCTIONAL: cache_aware_functional_tests_prctl.sh (CAS enabled)"
    hr
    set_cas 1
    "${FUNC_DIR}/cache_aware_functional_tests_prctl.sh" -t all
}

# ---------------------------------------------------------------------------
# Part: hackbench throughput, CAS enabled
# ---------------------------------------------------------------------------
run_perf() {
    hr
    echo "PERFORMANCE: hackbench sweep (CAS enabled)"
    echo "groups: ${GROUPS_LIST}"
    echo "fds:    ${FDS_LIST}"
    echo "modes:  ${MODES_LIST}"
    echo "runs:   ${NUM_RUNS}   target_sec: ${TARGET_SEC}"
    hr

    rm -rf "${HB_DIR}/results/hackbench/${TESTNAME}"

    if [ ! -x "${HB_DIR}/rt-tests/hackbench" ]; then
        echo "Building hackbench..."
        make -C "${HB_DIR}/rt-tests" hackbench
    fi

    echo ""
    echo "### Calibrating per-config -l (CAS enabled) ###"
    LLC_ENABLE=1 "${HB_DIR}/launch_hackbench.sh" calibrate

    echo ""
    echo "### Running hackbench with CAS ENABLED (${TESTNAME}) ###"
    LLC_ENABLE=1 "${HB_DIR}/launch_hackbench.sh" run "${TESTNAME}"

}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo $0)"; exit 1
fi

hr
echo "CAS test  (mode: $CMD)"
echo "host:   $(hostname)"
echo "kernel: $(uname -r)"
echo "date:   $(date)"
echo "nproc:  $(nproc)"
hr

if [ ! -e "$CAS_ENABLE" ]; then
    echo "ERROR: $CAS_ENABLE not present - kernel lacks cache-aware scheduling"
    exit 1
fi

case "$CMD" in
    # functional smoke tests only, cache-aware scheduling enabled
    func)  run_func ;;
    # prctl functional tests only, cache-aware scheduling enabled
    prctl) run_prctl ;;
    # hackbench sweep only, cache-aware scheduling enabled
    perf)  run_perf ;;
    # everything: func, then prctl, then perf
    all)   run_func; run_prctl; run_perf ;;
    *)     usage ;;
esac

echo "Results saved to: ${RESULT_FILE}"
echo "Done."
