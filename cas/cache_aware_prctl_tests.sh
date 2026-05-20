#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Intel Corporation
#
# Functional tests for cache aware scheduling:
#
#  - the generic behaviour, without prctl(): the threads of a process (one
#    mm, one default cache group) are aggregated onto one LLC, depending on
#    the system-wide mode in llc_balancing/enabled (always/advise/never);
#
#  - the PR_SCHED_CACHE prctl(): the per-group ENABLE/DISABLE hint and how it
#    composes with the system-wide mode, and CREATE/SHARE_FROM to build cache
#    groups that differ from the default per-mm ones.
#
# Must run as root on a machine with at least two LLCs.

cd "$(dirname "$0")" 2>/dev/null || exit 1
SCRIPT_DIR="$PWD"
WORKER="$SCRIPT_DIR/cas_worker"
CTL="$SCRIPT_DIR/sched_cache_ctl"
LLC_DBG=/sys/kernel/debug/sched/llc_balancing

KSFT_SKIP=4

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
# MONITOR_SECS    : how long to wait for an expected convergence / spread
# HOLD_SECS       : how long tasks must stay spread when no aggregation is expected
# SAMPLE_INTERVAL : seconds between samples
# PASS_THRESHOLD  : consecutive samples needed to declare a state reached
MONITOR_SECS=${MONITOR_SECS:-60}
HOLD_SECS=${HOLD_SECS:-30}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}
PASS_THRESHOLD=${PASS_THRESHOLD:-2}

# ---------------------------------------------------------------------------
# Topology detection
# ---------------------------------------------------------------------------
# ONLINE_CPUS   : online CPU list, used to release affinity
# CPU_LLC[cpu]  : LLC id of each online CPU
# LLC_IDS       : unique LLC ids
# LLC_CPUS[id]  : comma-separated CPU list of each LLC
# LLC_SIZE      : CPUs in the first LLC (assumes uniform LLCs)
# ---------------------------------------------------------------------------
expand_cpulist() {
	local range
	for range in ${1//,/ }; do
		if [[ $range == *-* ]]; then
			seq "${range%-*}" "${range#*-}"
		else
			echo "$range"
		fi
	done
}

ONLINE_CPUS=$(cat /sys/devices/system/cpu/online)
declare -A CPU_LLC LLC_CPUS
for _cpu in $(expand_cpulist "$ONLINE_CPUS"); do
	_id=$(cat /sys/devices/system/cpu/cpu$_cpu/cache/index3/id 2>/dev/null) || continue
	CPU_LLC[$_cpu]=$_id
	LLC_CPUS[$_id]+="${LLC_CPUS[$_id]:+,}$_cpu"
done
LLC_IDS=$(printf '%s\n' "${CPU_LLC[@]}" | sort -un)
LLC_COUNT=$(echo $LLC_IDS | wc -w)
_first_llc=$(echo $LLC_IDS | awk '{print $1}')
_first_cpu=${LLC_CPUS[$_first_llc]%%,*}
LLC_SIZE=$(echo "${LLC_CPUS[$_first_llc]}" | tr ',' '\n' | grep -c .)

# NTHREADS: 70% of the cores of an LLC. invalid_llc_nr() refuses to aggregate
# a group once nr_running * cpu_smt_num_threads exceeds ~80% of the LLC's
# CPUs, i.e. ~80% of its cores, so one group of NTHREADS busy tasks fits.
SMT_THREADS=$(expand_cpulist "$(cat /sys/devices/system/cpu/cpu$_first_cpu/topology/thread_siblings_list)" | grep -c .)
NTHREADS=$(( LLC_SIZE / SMT_THREADS * 7 / 10 ))
[ "$NTHREADS" -lt 2 ] && NTHREADS=2

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
fadd() { awk -v a="$1" -v b="$2" 'BEGIN { print a + b }'; }
flt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

build() {
	local bin=$1 src=$2

	if gcc -O2 -W -Wall -pthread -o "$bin" "$src"; then
		return 0
	fi
	if [ -x "$bin" ]; then
		echo "[WARN] cannot build $(basename "$bin"); using existing binary"
		return 0
	fi
	echo "[ERROR] cannot build $(basename "$bin") and no prebuilt binary present" >&2
	return 1
}

# ---------------------------------------------------------------------------
# llc_balancing mode and parameter save/restore
# ---------------------------------------------------------------------------
LLC_PARAMS="aggr_tolerance epoch_period epoch_affinity_timeout overaggr_pct imb_pct"
declare -A LLC_ORIG

# "enabled" reads back as e.g. "[always] advise never"; print the active mode.
get_mode() {
	sed -n 's/.*\[\([a-z]*\)\].*/\1/p' "$LLC_DBG/enabled"
}

set_mode() {
	echo "$1" > "$LLC_DBG/enabled" 2>/dev/null && [ "$(get_mode)" = "$1" ]
}

save_llc_params() {
	local p
	LLC_ORIG_MODE=$(get_mode)
	for p in $LLC_PARAMS; do
		[ -r "$LLC_DBG/$p" ] && LLC_ORIG[$p]=$(cat "$LLC_DBG/$p")
	done
	echo "baseline llc_balancing: mode=$LLC_ORIG_MODE $(for p in $LLC_PARAMS; do
		printf '%s=%s ' "$p" "${LLC_ORIG[$p]}"; done)"
}

restore_llc_params() {
	local p
	for p in $LLC_PARAMS; do
		[ -n "${LLC_ORIG[$p]}" ] && echo "${LLC_ORIG[$p]}" > "$LLC_DBG/$p"
	done
	[ -n "$LLC_ORIG_MODE" ] && echo "$LLC_ORIG_MODE" > "$LLC_DBG/enabled"
	echo "llc_balancing baseline restored"
}

# ---------------------------------------------------------------------------
# Workload management
# ---------------------------------------------------------------------------
WORKER_PIDS=""

# start_worker NTHREADS: start a cas_worker; its pid is left in LAST_PID.
# Not to be called from a subshell, the worker would not be our child.
start_worker() {
	local n=$1 i

	"$WORKER" "$n" &
	LAST_PID=$!
	WORKER_PIDS="$WORKER_PIDS $LAST_PID"
	for i in $(seq 50); do
		[ "$(ls /proc/$LAST_PID/task 2>/dev/null | wc -l)" -gt "$n" ] && return 0
		sleep 0.1
	done
	echo "  [ERROR] cas_worker $LAST_PID did not start $n threads"
	return 1
}

stop_workers() {
	[ -z "$WORKER_PIDS" ] && return
	kill $WORKER_PIDS 2>/dev/null
	wait $WORKER_PIDS 2>/dev/null
	WORKER_PIDS=""
}

workers_alive() {
	local pid
	for pid in $WORKER_PIDS; do
		kill -0 "$pid" 2>/dev/null || return 1
	done
}

# worker_tids PID: the busy threads of a cas_worker, i.e. all but the main one.
worker_tids() {
	ls /proc/$1/task | grep -vx "$1"
}

# scatter TID...: pin the tasks round-robin over all LLCs, then release them,
# so every test starts from a placement spread over all LLCs.
scatter() {
	local llcs=($LLC_IDS) n=0 tid
	for tid; do
		taskset -p -c "${LLC_CPUS[${llcs[$((n % LLC_COUNT))]}]}" "$tid" > /dev/null 2>&1
		n=$(( n + 1 ))
	done
	sleep 0.05
	for tid; do
		taskset -p -c "$ONLINE_CPUS" "$tid" > /dev/null 2>&1
	done
}

# ---------------------------------------------------------------------------
# Placement sampling
# ---------------------------------------------------------------------------
# sample TID...: look at where the running (state R) tasks are and set
#   S_TOTAL : number of running tasks
#   S_NR    : number of LLCs they occupy
#   S_TOP   : LLC with the most of them ("-" if none)
#   S_DIST  : "LLC<id>:<count> ..."
sample() {
	local tid f
	read -r S_TOTAL S_NR S_TOP S_DIST < <(
		for tid; do
			read -r -a f 2>/dev/null < /proc/$tid/stat || continue
			[ "${f[2]}" = R ] && echo "${CPU_LLC[${f[38]}]}"
		done | awk '
			{ n[$1]++; t++ }
			END {
				top = "-"
				for (l in n) {
					u++
					if (top == "-" || n[l] > n[top])
						top = l
					d = d sprintf("LLC%s:%d ", l, n[l])
				}
				printf "%d %d %s %s\n", t, u, top, d
			}')
}

# Predicates for poll_until. Each takes the task list(s) as string arguments,
# leaves a description of the sample in PRED_MSG and succeeds when the
# condition holds for this sample.

# All running tasks of the list sit on one LLC; the LLC is left in CONV_LLC.
pred_converged() {
	sample $1
	PRED_MSG="$S_DIST"
	CONV_LLC=$S_TOP
	[ "$S_TOTAL" -gt 0 ] && [ "$S_NR" -eq 1 ]
}

# The running tasks of the list occupy more than one LLC.
pred_spread() {
	sample $1
	PRED_MSG="$S_DIST"
	[ "$S_NR" -gt 1 ]
}

# Each of the two lists is converged, and on a different LLC from the other.
pred_two_groups() {
	local nr_a top_a dist_a

	sample $1
	nr_a=$S_NR top_a=$S_TOP dist_a=$S_DIST
	sample $2
	PRED_MSG="A: ${dist_a}| B: $S_DIST"
	[ "$nr_a" -eq 1 ] && [ "$S_NR" -eq 1 ] && [ "$top_a" != "$S_TOP" ]
}

# poll_until SECS PRED ARG...: sample every SAMPLE_INTERVAL until PRED holds
# for PASS_THRESHOLD consecutive samples. Returns 0 if it did, 1 on timeout
# and 2 if a worker died.
poll_until() {
	local secs=$1 pred=$2 elapsed=0 hits=0
	shift 2

	while flt "$elapsed" "$secs"; do
		sleep "$SAMPLE_INTERVAL"
		elapsed=$(fadd "$elapsed" "$SAMPLE_INTERVAL")

		if ! workers_alive; then
			echo "  [ERROR] a worker exited unexpectedly"
			return 2
		fi

		if "$pred" "$@"; then
			hits=$(( hits + 1 ))
		else
			hits=0
		fi
		echo "  t=${elapsed}s  $PRED_MSG [$hits/$PASS_THRESHOLD]"
		[ "$hits" -ge "$PASS_THRESHOLD" ] && return 0
	done
	return 1
}

# expect_converge TIDS: the tasks must end up on a single LLC.
expect_converge() {
	echo "Expecting convergence onto a single LLC within ${MONITOR_SECS}s..."
	if poll_until "$MONITOR_SECS" pred_converged "$1"; then
		echo "  => converged on LLC$CONV_LLC"
		return 0
	fi
	echo "  => did not converge"
	return 1
}

# expect_spread TIDS: the tasks must leave the single LLC they are on.
expect_spread() {
	echo "Expecting the tasks to spread over several LLCs within ${MONITOR_SECS}s..."
	if poll_until "$MONITOR_SECS" pred_spread "$1"; then
		echo "  => spread"
		return 0
	fi
	echo "  => did not spread"
	return 1
}

# expect_no_converge TIDS: the tasks must not aggregate onto one LLC for
# HOLD_SECS.
expect_no_converge() {
	echo "Expecting no aggregation for ${HOLD_SECS}s..."
	poll_until "$HOLD_SECS" pred_converged "$1"
	case $? in
	0) echo "  => aggregated although it should not have"; return 1 ;;
	1) echo "  => stayed spread"; return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# prctl helpers
# ---------------------------------------------------------------------------
ctl() {
	echo "  prctl: $*"
	"$CTL" "$@"
}

# expect_flag PID WANT: PR_SCHED_CACHE_GET_ENABLED on PID must report WANT.
expect_flag() {
	local v

	v=$("$CTL" get_enabled "$1") || return 1
	echo "  group flag of $1: $v"
	if [ "$((v))" -ne "$2" ]; then
		echo "  [FAIL] group flag is $v, want $2"
		return 1
	fi
}

# group_of TID...: all tasks must report the same, non-zero cookie, which is
# printed.
group_of() {
	local tid c first=""

	for tid; do
		c=$("$CTL" get "$tid") || return 1
		: "${first:=$c}"
		if [ "$c" != "$first" ]; then
			echo "  [FAIL] task $tid is in group $c, task $1 in $first" >&2
			return 1
		fi
	done
	if [ "$((first))" -eq 0 ]; then
		echo "  [FAIL] tasks have no cache group" >&2
		return 1
	fi
	echo "$first"
}

need_prctl() {
	if [ "$PRCTL_OK" != 1 ]; then
		echo "[SKIP] PR_SCHED_CACHE not supported by this kernel"
		return 1
	fi
}

# use_mode MODE: switch the system-wide mode, failing the test if impossible.
use_mode() {
	if ! set_mode "$1"; then
		echo "[SKIP] cannot switch llc_balancing to '$1'"
		return 1
	fi
	echo "llc_balancing mode: $(get_mode)"
}

# start_scattered NTHREADS: start a worker and scatter its threads; the pid is
# in LAST_PID and the busy threads in TIDS.
start_scattered() {
	start_worker "$1" || return 1
	TIDS=$(worker_tids "$LAST_PID")
	echo "Started cas_worker PID=$LAST_PID with $1 threads, scattering over $LLC_COUNT LLCs"
	scatter $TIDS
}

# ===========================================================================
# Generic cache aware scheduling, no prctl()
# ===========================================================================

# G1: in "always" mode the threads of a process converge onto one LLC.
test_always_agg() {
	use_mode always || return $KSFT_SKIP
	start_scattered "$NTHREADS" || return 1
	expect_converge "$TIDS"
}

# G2: in "never" mode the threads of a process stay spread.
test_never_spread() {
	use_mode never || return $KSFT_SKIP
	start_scattered "$NTHREADS" || return 1
	expect_no_converge "$TIDS"
}

# G3: in "advise" mode a process that never opted in through the prctl() is
# not aggregated: the group flag defaults to 0.
test_advise_default() {
	use_mode advise || return $KSFT_SKIP
	start_scattered "$NTHREADS" || return 1
	if [ "$PRCTL_OK" = 1 ]; then
		expect_flag "$LAST_PID" 0 || return 1
	fi
	expect_no_converge "$TIDS"
}

# G4: in "always" mode two processes each converge, onto different LLCs.
test_two_proc() {
	local tids1

	use_mode always || return $KSFT_SKIP
	echo "=== Phase 1: proc1 converges ==="
	start_scattered "$NTHREADS" || return 1
	tids1=$TIDS
	expect_converge "$tids1" || return 1

	echo "=== Phase 2: proc2 must settle on another LLC ==="
	start_scattered "$NTHREADS" || return 1
	echo "Expecting proc1 (A) and proc2 (B) on different LLCs within ${MONITOR_SECS}s..."
	poll_until "$MONITOR_SECS" pred_two_groups "$tids1" "$TIDS"
}

# G5: separate processes do not share a default cache group, so cooperating
# single-threaded processes are not aggregated together. This is the
# baseline that test_share_procs improves on with the prctl().
test_procs_default() {
	local i tids=""

	use_mode always || return $KSFT_SKIP
	for i in $(seq "$NTHREADS"); do
		start_worker 1 || return 1
		tids="$tids $(worker_tids "$LAST_PID")"
	done
	echo "Started $NTHREADS single-threaded cas_workers, scattering over $LLC_COUNT LLCs"
	scatter $tids
	expect_no_converge "$tids"
}

# ===========================================================================
# prctl(PR_SCHED_CACHE)
# ===========================================================================

# P1: in "advise" mode, ENABLE makes the process converge and DISABLE lets
# it spread again.
test_advise_enable() {
	need_prctl || return $KSFT_SKIP
	use_mode advise || return $KSFT_SKIP
	start_worker "$NTHREADS" || return 1
	TIDS=$(worker_tids "$LAST_PID")

	echo "=== Phase 1: ENABLE, expect aggregation ==="
	ctl enable "$LAST_PID" || return 1
	expect_flag "$LAST_PID" 1 || return 1
	echo "Scattering $NTHREADS threads over $LLC_COUNT LLCs"
	scatter $TIDS
	expect_converge "$TIDS" || return 1

	echo "=== Phase 2: DISABLE, expect the threads to spread out ==="
	ctl disable "$LAST_PID" || return 1
	expect_flag "$LAST_PID" 0 || return 1
	expect_spread "$TIDS"
}

# P2: "always" ignores the per-group DISABLE.
test_always_disable() {
	need_prctl || return $KSFT_SKIP
	use_mode always || return $KSFT_SKIP
	start_worker "$NTHREADS" || return 1
	TIDS=$(worker_tids "$LAST_PID")
	ctl disable "$LAST_PID" || return 1
	expect_flag "$LAST_PID" 0 || return 1
	echo "Scattering $NTHREADS threads over $LLC_COUNT LLCs"
	scatter $TIDS
	expect_converge "$TIDS"
}

# P3: "never" ignores the per-group ENABLE.
test_never_enable() {
	need_prctl || return $KSFT_SKIP
	use_mode never || return $KSFT_SKIP
	start_worker "$NTHREADS" || return 1
	TIDS=$(worker_tids "$LAST_PID")
	ctl enable "$LAST_PID" || return 1
	expect_flag "$LAST_PID" 1 || return 1
	echo "Scattering $NTHREADS threads over $LLC_COUNT LLCs"
	scatter $TIDS
	expect_no_converge "$TIDS"
}

# P4: single-threaded processes put into one cache group with CREATE and
# SHARE_FROM are aggregated together, which the default per-mm groups do
# not do (see test_procs_default).
test_share_procs() {
	local i pids="" tids="" first grp

	need_prctl || return $KSFT_SKIP
	use_mode always || return $KSFT_SKIP
	for i in $(seq "$NTHREADS"); do
		start_worker 1 || return 1
		pids="$pids $LAST_PID"
		tids="$tids $(worker_tids "$LAST_PID")"
	done
	first=$(echo $pids | awk '{print $1}')
	echo "Started $NTHREADS single-threaded cas_workers, scattering over $LLC_COUNT LLCs"
	scatter $tids

	echo "=== Phase 1: default per-process groups, expect no aggregation ==="
	expect_no_converge "$tids" || return 1

	echo "=== Phase 2: one group for all processes, expect aggregation ==="
	ctl create "$first" tgid || return 1
	for i in $pids; do
		[ "$i" = "$first" ] && continue
		"$CTL" share "$i" "$first" tgid || return 1
	done
	echo "  prctl: share <each pid> $first tgid"
	grp=$(group_of $tids) || return 1
	echo "  all $NTHREADS tasks are in group $grp"
	expect_converge "$tids"
}

# P5: the threads of one process split into two cache groups with PIDTYPE_PID
# CREATE/SHARE_FROM converge as two groups, onto different LLCs.
test_split_threads() {
	local all a="" b="" n=0 tid head_a head_b grp_a grp_b

	need_prctl || return $KSFT_SKIP
	use_mode always || return $KSFT_SKIP
	start_worker $(( NTHREADS * 2 )) || return 1
	all=$(worker_tids "$LAST_PID")
	for tid in $all; do
		if [ $(( n % 2 )) -eq 0 ]; then a="$a $tid"; else b="$b $tid"; fi
		n=$(( n + 1 ))
	done
	head_a=$(echo $a | awk '{print $1}')
	head_b=$(echo $b | awk '{print $1}')
	echo "Started cas_worker PID=$LAST_PID with $(( NTHREADS * 2 )) threads, split into A and B"

	ctl create "$head_a" pid || return 1
	ctl create "$head_b" pid || return 1
	for tid in $a; do
		[ "$tid" = "$head_a" ] || "$CTL" share "$tid" "$head_a" pid || return 1
	done
	for tid in $b; do
		[ "$tid" = "$head_b" ] || "$CTL" share "$tid" "$head_b" pid || return 1
	done
	echo "  prctl: share <each A tid> $head_a pid; share <each B tid> $head_b pid"
	grp_a=$(group_of $a) || return 1
	grp_b=$(group_of $b) || return 1
	echo "  group A: $grp_a  group B: $grp_b"
	if [ "$grp_a" = "$grp_b" ]; then
		echo "  [FAIL] A and B share a cache group"
		return 1
	fi

	echo "Scattering all threads over $LLC_COUNT LLCs"
	scatter $all
	echo "Expecting A and B each on a single, different LLC within ${MONITOR_SECS}s..."
	poll_until "$MONITOR_SECS" pred_two_groups "$a" "$b"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
GENERIC_TESTS="test_always_agg test_never_spread test_advise_default test_two_proc test_procs_default"
PRCTL_TESTS="test_advise_enable test_always_disable test_never_enable test_share_procs test_split_threads"

usage() {
	cat <<-EOF
	Usage: $0 [-t <test>|generic|prctl|all] [-l]

	Generic tests (no prctl):
	  test_always_agg      always: threads of a process converge onto one LLC
	  test_never_spread    never: threads stay spread
	  test_advise_default  advise: a process that did not opt in stays spread
	  test_two_proc        always: two processes settle on different LLCs
	  test_procs_default   always: single-threaded processes are not aggregated together

	prctl tests:
	  test_advise_enable   advise: ENABLE aggregates, DISABLE spreads again
	  test_always_disable  always: DISABLE is ignored, threads still converge
	  test_never_enable    never: ENABLE is ignored, threads stay spread
	  test_share_procs     CREATE+SHARE_FROM aggregates separate processes
	  test_split_threads   threads split into two groups converge on two LLCs

	Default is all. Environment overrides:
	  MONITOR_SECS=$MONITOR_SECS  HOLD_SECS=$HOLD_SECS  SAMPLE_INTERVAL=$SAMPLE_INTERVAL  PASS_THRESHOLD=$PASS_THRESHOLD
	EOF
	exit 1
}

TESTS=all
while getopts "t:lh" opt; do
	case $opt in
	t) TESTS="$OPTARG" ;;
	l) echo $GENERIC_TESTS $PRCTL_TESTS | tr ' ' '\n'; exit 0 ;;
	*) usage ;;
	esac
done

case "$TESTS" in
all)     TESTS="$GENERIC_TESTS $PRCTL_TESTS" ;;
generic) TESTS="$GENERIC_TESTS" ;;
prctl)   TESTS="$PRCTL_TESTS" ;;
*)
	for t in $TESTS; do
		[[ " $GENERIC_TESTS $PRCTL_TESTS " == *" $t "* ]] || { echo "Unknown test: $t"; usage; }
	done
	;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "[SKIP] must be run as root"
	exit $KSFT_SKIP
fi
if [ ! -w "$LLC_DBG/enabled" ] || [ -z "$(get_mode)" ]; then
	echo "[SKIP] $LLC_DBG/enabled missing or without always/advise/never modes"
	exit $KSFT_SKIP
fi
if [ "$LLC_COUNT" -lt 2 ]; then
	echo "[SKIP] need at least 2 LLCs, found $LLC_COUNT"
	exit $KSFT_SKIP
fi

echo "Detected $LLC_COUNT LLCs, $LLC_SIZE CPUs each, $SMT_THREADS threads per core (NTHREADS=$NTHREADS)"
for _id in $LLC_IDS; do
	echo "  LLC$_id: ${LLC_CPUS[$_id]}"
done

# With asymmetric core priorities (Intel ITMT, AMD preferred cores) the stock
# load balancer packs tasks onto the highest priority cores. If those sit in
# one LLC it aggregates small task counts there by itself, so the "no
# aggregation" tests fail and the "converge" tests pass vacuously.
if [ "$(cat /sys/kernel/debug/x86/sched_itmt_enabled 2>/dev/null)" = Y ] ||
   [ "$(cat /sys/devices/system/cpu/cpu*/cpufreq/amd_pstate_prefcore_ranking 2>/dev/null | sort -u | wc -l)" -gt 1 ]; then
	echo "[WARN] asymmetric core priorities (ITMT / AMD prefcore) detected: asym packing"
	echo "       may aggregate tasks independently of cache aware scheduling"
fi

build "$WORKER" "$SCRIPT_DIR/cas_worker.c" || exit 1
build "$CTL" "$SCRIPT_DIR/sched_cache_ctl.c" || exit 1

# A GET on ourselves succeeds whenever CONFIG_SCHED_CACHE provides the prctl.
PRCTL_OK=0
"$CTL" get 0 > /dev/null 2>&1 && PRCTL_OK=1
echo "PR_SCHED_CACHE prctl: $([ $PRCTL_OK = 1 ] && echo supported || echo not supported)"

if pgrep -x cas_worker > /dev/null 2>&1; then
	echo "Killing stale cas_worker processes..."
	pkill -x cas_worker
	sleep 0.5
fi

save_llc_params
trap 'stop_workers; restore_llc_params' EXIT
trap 'exit 130' INT TERM
echo ""

declare -A RESULT
for t in $TESTS; do
	echo "########################################"
	echo "# $t"
	echo "########################################"
	"$t"
	case $? in
	0) RESULT[$t]=PASS ;;
	"$KSFT_SKIP") RESULT[$t]=SKIP ;;
	*) RESULT[$t]=FAIL ;;
	esac
	stop_workers
	echo "$t: ${RESULT[$t]}"
	echo ""
done

echo "========================================"
nr_fail=0
for t in $TESTS; do
	printf '  %-22s %s\n' "$t" "${RESULT[$t]}"
	[ "${RESULT[$t]}" = FAIL ] && nr_fail=$(( nr_fail + 1 ))
done
echo "========================================"
[ "$nr_fail" -eq 0 ]
