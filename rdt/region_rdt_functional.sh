#!/usr/bin/env bash
#
# region_rdt_functional.sh - Functional tests for Intel region-aware RDT.
#
# Covers the user-visible interfaces added by the region-aware RDT /
# ERDT MMIO series:
#
#   * /sys/fs/resctrl/info/MB/control_mode   (legacy <-> native switching)
#   * /sys/fs/resctrl/info/MB/schemata/...   (per-control property files)
#   * schemata format read/write in both modes
#       legacy : "MB:<dom>=<val>;..."
#       native : "MB_REGION<n>_{OPT,MIN,MAX}:<dom>=<val>;..."
#   * region-aware MBM  (mon_data/mon_L3_*/mbm_region<n>_bytes)
#   * region-aware MBA  (fine-grained value sweep measured via region MBM)
#   * MMIO-based CMT    (mon_data/mon_L3_*/llc_occupancy)
#
# The native MBA sweep walks the schemata value from the control minimum up
# in MBA_SWEEP_STEP increments to MBA_SWEEP_MAX (default 1, 5, 10 ... 50),
# where the bandwidth is expected to reach its peak, and checks that the
# measured MBM bandwidth scales monotonically with the value.
#
# The script is self contained: the memory workload is a small C program
# (modelled on tools/testing/selftests/resctrl/fill_buf.c) that is compiled
# at run time.
#
# Run ON the test machine as root:
#       sudo ./region_rdt_functional.sh
# or remotely:
#       scp region_rdt_functional.sh host: && ssh host 'sudo ./region_rdt_functional.sh'
#
# SPDX-License-Identifier: GPL-2.0

set -u

#############################################################################
# Tunables
#############################################################################
RESCTRL="${RESCTRL:-/sys/fs/resctrl}"
TESTGRP="${TESTGRP:-rdt_func_grp}"
MBM_WINDOW="${MBM_WINDOW:-5}"		# seconds of MBM accumulation
MBM_MIN_BYTES="${MBM_MIN_BYTES:-$((100 * 1024 * 1024))}"
LOAD_THREADS="${LOAD_THREADS:-8}"	# worker processes for MBM/MBA load
CMT_RUNS="${CMT_RUNS:-3}"
CMT_MAX_DIFF_PERCENT="${CMT_MAX_DIFF_PERCENT:-15}"
CMT_MAX_DIFF="${CMT_MAX_DIFF:-2000000}"
MBA_LOW="${MBA_LOW:-}"			# low throttle level, default = ctrl min
MBA_RATIO="${MBA_RATIO:-90}"		# throttled BW must be <= this % of max BW
MBA_STRICT="${MBA_STRICT:-0}"		# 1: MBA throttling effect is a hard failure
# Native (region-aware) MBA sweep: the hardware ramps from the minimum up to a
# saturation point well below the architectural maximum, so sweep finely over
# the ramp instead of jumping straight to the top of the range.
MBA_SWEEP_STEP="${MBA_SWEEP_STEP:-5}"	# step between native sweep points
MBA_SWEEP_MAX="${MBA_SWEEP_MAX:-50}"	# top of the native sweep (BW peaks here)
MBA_MONO_TOL="${MBA_MONO_TOL:-10}"	# % of peak BW tolerated as measurement noise
MBA_CORR="${MBA_CORR:-80}"		# min correlation (x100) of value vs bandwidth
MBA_SAT_PCT="${MBA_SAT_PCT:-95}"	# % of peak that counts as saturated
# Multi-controller native schemata writes are repeated this many times with
# identical content: a correct kernel must give the same answer every time.
NATIVE_WRITE_REPEAT="${NATIVE_WRITE_REPEAT:-3}"
SKIP_WORKLOAD="${SKIP_WORKLOAD:-0}"	# 1: only run interface/format tests
VERBOSE="${VERBOSE:-0}"

INFO="$RESCTRL/info"
WORKDIR=""
WORKER=""
WORKLOAD_OK=0
MON_OK=0
MON_SKIP_REASON=""
declare -a LOAD_PIDS=()

#############################################################################
# Result bookkeeping
#############################################################################
TC=0; NPASS=0; NFAIL=0; NSKIP=0; NWARN=0
declare -a FAILED=()

say()   { printf '# %s\n' "$*"; }
vsay()  { [ "$VERBOSE" = 1 ] && printf '#   %s\n' "$*"; return 0; }
ok()    { TC=$((TC+1)); NPASS=$((NPASS+1)); printf 'ok %d - %s\n' "$TC" "$1"; }
notok() { TC=$((TC+1)); NFAIL=$((NFAIL+1)); printf 'not ok %d - %s\n' "$TC" "$1"
	  [ $# -gt 1 ] && printf '#   %s\n' "$2"; FAILED+=("$1"); }
skip()  { TC=$((TC+1)); NSKIP=$((NSKIP+1)); printf 'ok %d - %s # SKIP %s\n' "$TC" "$1" "${2:-}"; }
warn()  { NWARN=$((NWARN+1)); printf '# WARN: %s\n' "$*"; }

check() { # <desc> <0|1 result> [detail]
	if [ "$2" = 0 ]; then ok "$1"; else notok "$1" "${3:-}"; fi
}

assert_eq() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1"
	else notok "$1" "expected '$2', got '$3'"; fi
}

#############################################################################
# resctrl helpers
#############################################################################
sch_file() { # [group]
	if [ -z "${1:-}" ]; then echo "$RESCTRL/schemata"; else echo "$RESCTRL/$1/schemata"; fi
}

sch_write() { # <group> <text>   (text may contain newlines)
	printf '%s\n' "$2" > "$(sch_file "$1")" 2>/dev/null
}

sch_line() { # <group> <ctrl-name> -> value list "0=255;1=255;..."
	awk -F: -v c="$2" '{
		n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n);
		if (n == c) { v=$2; gsub(/[ \t]/, "", v); print v }
	}' "$(sch_file "$1")"
}

sch_get() { # <group> <ctrl-name> <domain> -> value
	sch_line "$1" "$2" | awk -v d="$3" '{
		n = split($0, a, ";");
		for (i = 1; i <= n; i++) { split(a[i], b, "="); if (b[1] == d) print b[2] }
	}'
}

sch_names() { # -> all control names present in the schemata file
	awk -F: 'NF>1 { n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n); print n }' "$(sch_file "")"
}

sch_domains() { # <ctrl-name> -> domain ids, one per line
	sch_line "" "$1" | tr ';' '\n' | cut -d= -f1
}

ctrl_mode() { cat "$INFO/MB/control_mode" 2>/dev/null; }

set_mode() { # legacy|native
	printf '%s\n' "$1" > "$INFO/MB/control_mode" 2>/dev/null
}

mode_is() { # legacy|native
	case "$(ctrl_mode)" in
	"[legacy]"*) [ "$1" = legacy ] ;;
	*"[native]") [ "$1" = native ] ;;
	*) return 1 ;;
	esac
}

last_cmd() { cat "$INFO/last_cmd_status" 2>/dev/null; }

mon_domains() { # L3 monitor domain ids
	ls "$RESCTRL/mon_data" 2>/dev/null | sed -n 's/^mon_L3_0*\([0-9]\+\)$/\1/p' |
		sort -n | sed 's/^$/0/'
}

mon_file() { # <group> <domain> <file>
	printf '%s/%smon_data/mon_L3_%02d/%s' "$RESCTRL" \
		"${1:+$1/}" "$2" "$3"
}

mon_read() { # <group> <domain> <file> -> value (0 when unreadable)
	local f v; f="$(mon_file "$1" "$2" "$3")"
	if [ -r "$f" ]; then
		v="$(cat "$f" 2>/dev/null)"
	else
		v=""
	fi
	case "$v" in
	''|*[!0-9]*) echo 0; return 1 ;;
	esac
	echo "$v"
}

has_name() { # <ctrl name>  -> 0 if present in the default group schemata
	sch_names | grep -qx "$1"
}

all_names_present() { # <ctrl names...>
	local n
	for n in "$@"; do has_name "$n" || return 1; done
	return 0
}

#############################################################################
# Topology helpers
#############################################################################
declare -A DOM_CPU=()		# L3 domain id -> first cpu
declare -A DOM_CPUS=()		# L3 domain id -> space separated cpu list
declare -A REGION_NODE=()	# region id -> numa node (>=0) or "none"
L3_SIZE_KB=0
L3_WAYS=0

bytes_from_cache_size() { # "286720K" -> KB number
	local s="$1"
	case "$s" in
	*K) echo "${s%K}" ;;
	*M) echo $(( ${s%M} * 1024 )) ;;
	*) echo "$s" ;;
	esac
}

build_topology() {
	local cpu id n cpudir

	for cpudir in /sys/devices/system/cpu/cpu[0-9]*; do
		n="${cpudir##*/cpu}"
		id="$(cat "$cpudir/cache/index3/id" 2>/dev/null)" || continue
		[ -n "$id" ] || continue
		if [ -z "${DOM_CPU[$id]:-}" ]; then
			DOM_CPU[$id]="$n"
			DOM_CPUS[$id]="$n"
		else
			DOM_CPUS[$id]="${DOM_CPUS[$id]} $n"
		fi
	done

	cpu="${DOM_CPU[$(mon_domains | head -1)]:-0}"
	L3_SIZE_KB="$(bytes_from_cache_size \
		"$(cat /sys/devices/system/cpu/cpu"$cpu"/cache/index3/size 2>/dev/null)")"
	L3_WAYS="$(cat /sys/devices/system/cpu/cpu"$cpu"/cache/index3/ways_of_associativity 2>/dev/null)"

	# region -> NUMA node, from the ACPI MRRM table export
	local r rid node
	for r in /sys/firmware/acpi/memory_ranges/range*; do
		[ -d "$r" ] || continue
		rid="$(cat "$r/local_region_id" 2>/dev/null)"
		node="$(cat "$r/node" 2>/dev/null)"
		[ -n "$rid" ] || continue
		if [ -n "$node" ] && [ "$node" -ge 0 ] 2>/dev/null; then
			REGION_NODE[$rid]="$node"
		elif [ -z "${REGION_NODE[$rid]:-}" ]; then
			REGION_NODE[$rid]="none"
		fi
	done
}

#############################################################################
# Memory workload
#############################################################################
WORKER_SRC='
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <signal.h>

#define CL_SIZE 64
#define FILL_IDX_MULT 23

static volatile unsigned char sink;
static volatile sig_atomic_t stop_now;

static void on_sig(int s) { (void)s; stop_now = 1; }

static void cl_flush(void *p)
{
	asm volatile("clflush (%0)" : : "r"(p) : "memory");
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/*
 * usage: worker <buf_MiB> <seconds>
 * Streams reads over a buffer in a prefetch unfriendly order so that the
 * accesses miss L3 and reach memory, mirroring the resctrl selftest
 * fill_buf benchmark.
 */
int main(int argc, char **argv)
{
	size_t mib = (argc > 1) ? strtoul(argv[1], NULL, 0) : 128;
	double secs = (argc > 2) ? strtod(argv[2], NULL) : 5.0;
	size_t sz = mib * 1024UL * 1024UL;
	unsigned int size, i, idx = 0;
	unsigned char sum = 0;
	unsigned char *buf;
	double end;
	size_t o;

	signal(SIGTERM, on_sig);
	signal(SIGINT, on_sig);

	if (posix_memalign((void **)&buf, 4096, sz))
		return 1;

	for (o = 0; o < sz; o += CL_SIZE)
		buf[o] = (unsigned char)(o >> 6);
	for (o = 0; o < sz; o += CL_SIZE)
		cl_flush(&buf[o]);
	asm volatile("sfence" ::: "memory");

	size = (unsigned int)(sz / (CL_SIZE / 2));
	end = now() + secs;

	while (!stop_now) {
		for (i = 0; i < size; i++) {
			sum += buf[(size_t)idx * (CL_SIZE / 2)];
			idx += FILL_IDX_MULT;
			while (idx >= size)
				idx -= size;
		}
		if (secs > 0 && now() >= end)
			break;
	}

	sink = sum;
	return 0;
}
'

build_worker() {
	WORKDIR="$(mktemp -d /tmp/rdt_func.XXXXXX)" || return 1
	WORKER="$WORKDIR/rdt_worker"
	printf '%s' "$WORKER_SRC" > "$WORKDIR/rdt_worker.c"
	if ! gcc -O2 -o "$WORKER" "$WORKDIR/rdt_worker.c" >"$WORKDIR/cc.log" 2>&1; then
		say "failed to build memory workload:"
		sed 's/^/#   /' "$WORKDIR/cc.log"
		return 1
	fi
	return 0
}

start_load() { # <group> <cpu list> <numa node|none> <buf MiB> <seconds>
	local grp="$1" cpus="$2" node="$3" mib="$4" secs="$5" cpu
	local -a pre=()

	[ "$node" != none ] && command -v numactl >/dev/null 2>&1 &&
		pre=(numactl --membind="$node")

	LOAD_PIDS=()
	for cpu in $cpus; do
		(
			echo $BASHPID > "$RESCTRL/${grp:+$grp/}tasks" 2>/dev/null
			exec taskset -c "$cpu" "${pre[@]}" "$WORKER" "$mib" "$secs" \
				>/dev/null 2>&1
		) &
		LOAD_PIDS+=($!)
	done
}

stop_load() {
	local p
	for p in "${LOAD_PIDS[@]:-}"; do
		[ -n "$p" ] && kill -TERM "$p" 2>/dev/null
	done
	for p in "${LOAD_PIDS[@]:-}"; do
		[ -n "$p" ] && wait "$p" 2>/dev/null
	done
	LOAD_PIDS=()
}

# Sum a monitor event over all L3 domains (or one domain) for a group.
mon_sum() { # <group> <event file> [domain]
	local grp="$1" ev="$2" dom="${3:-}" d v total=0
	if [ -n "$dom" ]; then
		mon_read "$grp" "$dom" "$ev"
		return 0
	fi
	for d in $(mon_domains); do
		v="$(mon_read "$grp" "$d" "$ev")"
		total=$((total + v))
	done
	echo "$total"
}

# Measure bytes counted by <event> for <group> while a load runs.
measure_bw() { # <group> <event> <cpus> <node> <bufMiB> <window> [domain]
	local grp="$1" ev="$2" cpus="$3" node="$4" mib="$5" win="$6" dom="${7:-}"
	local before after

	start_load "$grp" "$cpus" "$node" "$mib" "$((win + 8))"
	sleep 2					# let every worker ramp up
	before="$(mon_sum "$grp" "$ev" "$dom")"
	sleep "$win"
	after="$(mon_sum "$grp" "$ev" "$dom")"
	stop_load

	echo $(( after - before ))
}

human_bw() { # <bytes> <seconds>
	awk -v b="$1" -v s="$2" 'BEGIN { printf "%.2f GB/s", b / s / 1e9 }'
}

# Some platforms expose llc_occupancy / mbm_*_bytes but always read back 0
# for a non-default RMID.  The workload driven checks cannot say anything
# useful there, so probe the counters once with a known good memory hog and
# skip (rather than fail) when nothing moves.
mon_sanity_check() {
	local dom cpus c n=0 mib ev occ before after delta

	MON_SKIP_REASON=""
	dom="$(mon_domains | head -1)"
	for c in ${DOM_CPUS[$dom]:-0}; do
		cpus="${cpus:+$cpus }$c"
		n=$(( n + 1 ))
		[ "$n" -ge 4 ] && break
	done
	mib=$(( L3_SIZE_KB / 1024 * 2 ))
	[ "$mib" -lt 64 ] && mib=64

	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null || {
		MON_SKIP_REASON="cannot create $TESTGRP"
		return 1
	}

	ev=""
	for c in mbm_total_bytes mbm_region0_bytes mbm_local_bytes; do
		if grep -qw "$c" "$INFO/L3_MON/mon_features" 2>/dev/null; then
			ev="$c"
			break
		fi
	done

	start_load "$TESTGRP" "$cpus" none "$mib" 14
	sleep 4
	before=0
	[ -n "$ev" ] && before="$(mon_sum "$TESTGRP" "$ev")"
	sleep 5
	occ=0
	grep -qw llc_occupancy "$INFO/L3_MON/mon_features" 2>/dev/null &&
		occ="$(mon_sum "$TESTGRP" llc_occupancy)"
	after=0
	[ -n "$ev" ] && after="$(mon_sum "$TESTGRP" "$ev")"
	stop_load
	rmdir "$RESCTRL/$TESTGRP" 2>/dev/null

	delta=$(( after - before ))
	say "monitoring probe: $n workers on domain $dom, ${mib}MiB each" \
		"-> llc_occupancy=$occ B, ${ev:-no MBM event}=+$delta B/5s"

	# A single worker streams well above 100 MiB/s of DRAM traffic, so a
	# working counter must show far more than this over 5 seconds.
	if [ "$delta" -ge $(( 100 * 1024 * 1024 )) ] ||
	   [ "$occ" -ge $(( L3_SIZE_KB * 1024 / 4 )) ]; then
		return 0
	fi

	MON_SKIP_REASON="platform reports no monitoring data for a non-default RMID (llc_occupancy=$occ, ${ev:-MBM}=+$delta over 5s under load)"
	return 1
}

#############################################################################
# Setup / teardown
#############################################################################
ORIG_MODE=""

cleanup() {
	stop_load
	[ -d "$RESCTRL/${TESTGRP}_b" ] && rmdir "$RESCTRL/${TESTGRP}_b" 2>/dev/null
	[ -d "$RESCTRL/$TESTGRP" ] && rmdir "$RESCTRL/$TESTGRP" 2>/dev/null
	if [ -n "$ORIG_MODE" ] && [ -w "$INFO/MB/control_mode" ]; then
		set_mode "$ORIG_MODE"
	fi
	# Restore defaults of the default group in whichever mode we end up in.
	restore_defaults
	[ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}

restore_defaults() {
	local name max line
	for name in $(sch_names); do
		case "$name" in
		MB|MB_REGION*)
			max="$(ctrl_prop "$name" max)"
			[ -n "$max" ] || continue
			;;
		L3|L2|L3CODE|L3DATA|L2CODE|L2DATA)
			max="$(cat "$INFO/${name}/cbm_mask" 2>/dev/null)"
			[ -n "$max" ] || continue
			;;
		*)
			continue
			;;
		esac
		line="$name:$(sch_domains "$name" | sed "s/\$/=$max/" | paste -sd';' -)"
		sch_write "" "$line"
	done
}

ctrl_prop() { # <ctrl name> <prop>
	local base="$INFO/MB/schemata/MB"
	if [ "$1" = MB ]; then
		cat "$base/$2" 2>/dev/null
	else
		cat "$base/$1/$2" 2>/dev/null
	fi
}

require_root() {
	if [ "$(id -u)" != 0 ]; then
		say "must run as root"
		exit 4
	fi
}

mount_resctrl() {
	if mountpoint -q "$RESCTRL" 2>/dev/null || grep -q " $RESCTRL resctrl " /proc/mounts; then
		return 0
	fi
	mkdir -p "$RESCTRL"
	# NOTE: never 'umount -l' resctrl; a lazy unmount leaves the kernel
	# believing resctrl is still mounted and only a reboot recovers.
	mount -t resctrl resctrl "$RESCTRL" 2>/dev/null
}

#############################################################################
# Test sections
#############################################################################
declare -a MBA_CTRLS=()
declare -a MBA_REGIONS=()
HAVE_REGION_MBA=0
HAVE_REGION_MBM=0
declare -a MBM_REGIONS=()

discover() {
	local d n

	for d in "$INFO"/MB/schemata/MB/MB_REGION*; do
		[ -d "$d" ] || continue
		MBA_CTRLS+=("$(basename "$d")")
	done
	[ "${#MBA_CTRLS[@]}" -gt 0 ] && HAVE_REGION_MBA=1

	for n in "${MBA_CTRLS[@]:-}"; do
		case "$n" in
		MB_REGION*_OPT) MBA_REGIONS+=("$(echo "$n" | sed 's/MB_REGION\([0-9]*\)_.*/\1/')") ;;
		esac
	done

	for n in $(tr ' ' '\n' < "$INFO/L3_MON/mon_features" 2>/dev/null); do
		case "$n" in
		mbm_region*_bytes)
			HAVE_REGION_MBM=1
			MBM_REGIONS+=("$(echo "$n" | sed 's/mbm_region\([0-9]*\)_bytes/\1/')")
			;;
		esac
	done
}

#---------------------------------------------------------------------------
test_control_mode() {
	say "=== control_mode interface ==="

	if [ ! -e "$INFO/MB/control_mode" ]; then
		skip "info/MB/control_mode exists" "no region-aware MBA on this platform"
		return
	fi
	ok "info/MB/control_mode exists"

	case "$(ctrl_mode)" in
	"[legacy] native"|"legacy [native]") ok "control_mode reports a valid mode string" ;;
	*) notok "control_mode reports a valid mode string" "got '$(ctrl_mode)'" ;;
	esac

	set_mode bogus 2>/dev/null
	check "control_mode rejects an unknown mode" $(( $? == 0 ? 1 : 0 ))

	printf 'native' > "$INFO/MB/control_mode" 2>/dev/null
	check "control_mode rejects input without a trailing newline" $(( $? == 0 ? 1 : 0 ))

	set_mode native
	check "switch to native mode" $?
	check "control_mode shows native selected" $(mode_is native; echo $?)

	set_mode legacy
	check "switch to legacy mode" $?
	check "control_mode shows legacy selected" $(mode_is legacy; echo $?)

	if [ -e "$INFO/L3/control_mode" ]; then
		printf 'native\n' > "$INFO/L3/control_mode" 2>/dev/null
		check "control_mode of a non-MB resource rejects a switch" $(( $? == 0 ? 1 : 0 )) \
			"$(last_cmd)"
	fi
}

#---------------------------------------------------------------------------
test_ctrl_properties() {
	say "=== info/MB/schemata control property files ==="

	if [ "$HAVE_REGION_MBA" != 1 ]; then
		skip "region-aware MBA controls exported in info" "not supported"
		return
	fi
	ok "region-aware MBA controls exported: ${MBA_CTRLS[*]}"

	local c p min max
	for c in MB "${MBA_CTRLS[@]}"; do
		local missing=""
		for p in type unit min max resolution scale tolerance; do
			[ -n "$(ctrl_prop "$c" "$p")" ] || missing="$missing $p"
		done
		check "$c: all property files readable" \
			$([ -z "$missing" ]; echo $?) "missing:$missing"

		min="$(ctrl_prop "$c" min)"; max="$(ctrl_prop "$c" max)"
		check "$c: min ($min) < max ($max)" \
			$([ -n "$min" ] && [ -n "$max" ] && [ "$min" -lt "$max" ]; echo $?)
	done
}

#---------------------------------------------------------------------------
test_schemata_format() {
	say "=== schemata format in legacy / native mode ==="

	local doms_mb

	# ---- legacy mode -------------------------------------------------
	set_mode legacy
	check "legacy: MB line present" $([ -n "$(sch_line "" MB)" ]; echo $?)
	check "legacy: no MB_REGION line present" \
		$(sch_names | grep -q '^MB_REGION' && echo 1 || echo 0)

	doms_mb="$(sch_domains MB | paste -sd, -)"
	say "MB control domains: $doms_mb"

	local gran minbw d0 val
	gran="$(cat "$INFO/MB/bandwidth_gran" 2>/dev/null || echo 10)"
	minbw="$(cat "$INFO/MB/min_bandwidth" 2>/dev/null || echo 10)"
	d0="$(sch_domains MB | head -1)"
	val=$(( minbw + gran ))
	[ "$val" -gt 100 ] && val="$minbw"

	sch_write "" "MB:$d0=$val"
	check "legacy: write MB:$d0=$val accepted" $?
	assert_eq "legacy: MB:$d0 reads back $val" "$val" "$(sch_get "" MB "$d0")"

	if [ "$HAVE_REGION_MBA" = 1 ]; then
		sch_write "" "${MBA_CTRLS[0]}:$d0=1"
		check "legacy: region control '${MBA_CTRLS[0]}' is rejected" \
			$(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	fi

	sch_write "" "MB:$d0=100"

	if [ "$HAVE_REGION_MBA" != 1 ]; then
		skip "native mode schemata tests" "no region-aware MBA"
		return
	fi

	# ---- native mode -------------------------------------------------
	set_mode native
	check "native: all region controls present in schemata" \
		$(all_names_present "${MBA_CTRLS[@]}"; echo $?)
	check "native: legacy MB line is hidden" \
		$(has_name MB && echo 1 || echo 0)
	check "native: non-MB resources (L3) still shown" \
		$(has_name L3; echo $?)

	sch_write "" "MB:$d0=50"
	check "native: legacy 'MB' control is rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"

	local c min max mid doms line
	c="${MBA_CTRLS[0]}"
	min="$(ctrl_prop "$c" min)"; max="$(ctrl_prop "$c" max)"
	mid=$(( (min + max) / 2 ))
	doms="$(sch_domains "$c")"

	# single control, single domain
	sch_write "" "$c:$d0=$mid"
	check "native: write $c:$d0=$mid accepted" $?
	assert_eq "native: $c:$d0 reads back $mid" "$mid" "$(sch_get "" "$c" "$d0")"

	# single control, all domains
	line="$c:$(echo "$doms" | sed "s/\$/=$min/" | paste -sd';' -)"
	sch_write "" "$line"
	check "native: write $c for all domains accepted" $?
	local bad=0 d
	for d in $doms; do
		[ "$(sch_get "" "$c" "$d")" = "$min" ] || bad=1
	done
	check "native: $c reads back $min on every domain" "$bad"

	# several control lines in one write
	if [ "${#MBA_CTRLS[@]}" -gt 1 ]; then
		local c2="${MBA_CTRLS[1]}" m2
		m2="$(ctrl_prop "$c2" max)"
		sch_write "" "$c:$d0=$max
$c2:$d0=$m2"
		check "native: multi-line schemata write accepted" $?
		assert_eq "native: first line applied" "$max" "$(sch_get "" "$c" "$d0")"
		assert_eq "native: second line applied" "$m2" "$(sch_get "" "$c2" "$d0")"
	else
		skip "native: multi-line schemata write" "only one region control"
	fi

	# boundaries
	sch_write "" "$c:$d0=$min"
	check "native: minimum value $min accepted" $?
	assert_eq "native: minimum value reads back" "$min" "$(sch_get "" "$c" "$d0")"
	sch_write "" "$c:$d0=$max"
	check "native: maximum value $max accepted" $?
	assert_eq "native: maximum value reads back" "$max" "$(sch_get "" "$c" "$d0")"

	# invalid input
	sch_write "" "$c:$d0=$((max + 1))"
	check "native: value above max rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "$c:$d0=$((min - 1))"
	check "native: value below min rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "$c:$d0=abc"
	check "native: non-numeric value rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "$c:abc=$max"
	check "native: non-numeric domain rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "$c:$d0 $max"
	check "native: missing '=' rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "$c:9999=$max"
	check "native: unknown domain id rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"
	sch_write "" "MB_REGION99_OPT:$d0=$max"
	check "native: unknown control name rejected" $(( $? == 0 ? 1 : 0 )) "$(last_cmd)"

	check "native: last_cmd_status reports a reason" \
		$([ -n "$(last_cmd)" ]; echo $?)

	# values are not clobbered by a rejected write
	assert_eq "native: value preserved after rejected writes" "$max" "$(sch_get "" "$c" "$d0")"
}

#---------------------------------------------------------------------------
# Multi-controller native schemata writes.
#
# Covers the cases isolated by os_mmio_native_mba_repro.sh, which reported
# that combining several controllers of the *same* region in one write was
# rejected with EINVAL whenever MIN was involved (MIN+MAX, OPT+MIN+MAX),
# that the OPT+MIN result was not a pure function of the write's content
# (identical bytes failed once and succeeded later), and that one rejected
# write could wedge the MBA resource for other groups as well.
#
# All combinations below use in-range, self-consistent values
# (MIN <= OPT <= MAX), so every one of them must be accepted, must read
# back, and must behave identically on every repetition.
nat_ctrl() { # <region> <OPT|MIN|MAX> -> control name, or non-zero if absent
	local want="MB_REGION$1_$2" c
	for c in "${MBA_CTRLS[@]:-}"; do
		[ "$c" = "$want" ] && { echo "$want"; return 0; }
	done
	return 1
}

# Write the same content NATIVE_WRITE_REPEAT times and require that every
# attempt is accepted and that all attempts agree.
nat_write_case() { # <group> <label> <content>
	local grp="$1" label="$2" content="$3"
	local i ok_n=0 fail_n=0 reason=""

	vsay "$label content:"
	while IFS= read -r i; do vsay "    $i"; done <<< "$content"

	for (( i = 1; i <= NATIVE_WRITE_REPEAT; i++ )); do
		if sch_write "$grp" "$content"; then
			ok_n=$(( ok_n + 1 ))
		else
			fail_n=$(( fail_n + 1 ))
			[ -z "$reason" ] && reason="attempt $i: $(last_cmd)"
		fi
	done

	local acc=1 det=1
	[ "$fail_n" -eq 0 ] && acc=0
	{ [ "$ok_n" -eq 0 ] || [ "$fail_n" -eq 0 ]; } && det=0

	check "native write: $label accepted ($ok_n/$NATIVE_WRITE_REPEAT)" "$acc" "$reason"
	check "native write: $label is deterministic over $NATIVE_WRITE_REPEAT identical writes" \
		"$det" "same bytes: $ok_n accepted, $fail_n rejected"
	return "$acc"
}

# Verify every "<ctrl>:<dom>=<val>" line of a write actually took effect.
nat_verify() { # <group> <label> <content>
	local grp="$1" label="$2" bad=0 line name rest dom val got
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		name="${line%%:*}"
		rest="${line#*:}"
		dom="${rest%%=*}"
		val="${rest#*=}"
		got="$(sch_get "$grp" "$name" "$dom")"
		if [ "$got" != "$val" ]; then
			bad=1
			vsay "$name:$dom expected '$val', got '$got'"
		fi
	done <<< "$3"
	check "native write: $label values read back" "$bad"
}

test_native_multi_ctrl_write() {
	say "=== native multi-controller schemata writes ==="

	if [ "$HAVE_REGION_MBA" != 1 ]; then
		skip "native multi-controller writes" "no region-aware MBA"
		return
	fi

	set_mode native
	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null

	local r0="${MBA_REGIONS[0]}" c min max mid d0 content nl=$'\n'
	c="$(nat_ctrl "$r0" OPT || nat_ctrl "$r0" MAX)" || {
		skip "native multi-controller writes" "region $r0 exposes no controller"
		return
	}
	min="$(ctrl_prop "$c" min)"
	max="$(ctrl_prop "$c" max)"
	mid=$(( (min + max) / 2 ))
	d0="$(sch_domains "$c" | head -1)"
	say "region $r0, domain $d0, MIN=$min OPT=$mid MAX=$max, $NATIVE_WRITE_REPEAT writes per case"

	local have_opt=0 have_min=0 have_max=0
	nat_ctrl "$r0" OPT >/dev/null && have_opt=1
	nat_ctrl "$r0" MIN >/dev/null && have_min=1
	nat_ctrl "$r0" MAX >/dev/null && have_max=1

	# -- 1. single controller, single region -----------------------------
	content="$c:$d0=$max"
	nat_write_case "$TESTGRP" "single controller, one region" "$content" &&
		nat_verify "$TESTGRP" "single controller, one region" "$content"

	# -- 2. same controller type, every region, one write ----------------
	if [ "${#MBA_REGIONS[@]}" -gt 1 ]; then
		local r t="${c##*_}"
		content=""
		for r in "${MBA_REGIONS[@]}"; do
			nat_ctrl "$r" "$t" >/dev/null || continue
			content="${content:+$content$nl}MB_REGION${r}_${t}:$d0=$max"
		done
		nat_write_case "$TESTGRP" "single controller, all ${#MBA_REGIONS[@]} regions in one write" \
			"$content" &&
			nat_verify "$TESTGRP" "single controller, all regions" "$content"
	else
		skip "native write: single controller, all regions in one write" "only one region"
	fi

	# -- 3. OPT+MAX, same region -----------------------------------------
	if [ "$have_opt" = 1 ] && [ "$have_max" = 1 ]; then
		content="MB_REGION${r0}_OPT:$d0=$mid
MB_REGION${r0}_MAX:$d0=$max"
		nat_write_case "$TESTGRP" "OPT+MAX, same region" "$content" &&
			nat_verify "$TESTGRP" "OPT+MAX, same region" "$content"
	else
		skip "native write: OPT+MAX, same region" "region $r0 lacks OPT or MAX"
	fi

	# -- 4. MIN+MAX, same region (reported EINVAL) -----------------------
	if [ "$have_min" = 1 ] && [ "$have_max" = 1 ]; then
		content="MB_REGION${r0}_MIN:$d0=$min
MB_REGION${r0}_MAX:$d0=$max"
		nat_write_case "$TESTGRP" "MIN+MAX, same region" "$content" &&
			nat_verify "$TESTGRP" "MIN+MAX, same region" "$content"
	else
		skip "native write: MIN+MAX, same region" "region $r0 lacks MIN or MAX"
	fi

	# -- 5. OPT+MIN, same region (reported state-dependent) --------------
	if [ "$have_opt" = 1 ] && [ "$have_min" = 1 ]; then
		content="MB_REGION${r0}_OPT:$d0=$mid
MB_REGION${r0}_MIN:$d0=$min"
		nat_write_case "$TESTGRP" "OPT+MIN, same region" "$content" &&
			nat_verify "$TESTGRP" "OPT+MIN, same region" "$content"
	else
		skip "native write: OPT+MIN, same region" "region $r0 lacks OPT or MIN"
	fi

	# -- 6. OPT+MIN+MAX, same region, MIN <= OPT <= MAX ------------------
	if [ "$have_opt" = 1 ] && [ "$have_min" = 1 ] && [ "$have_max" = 1 ]; then
		content="MB_REGION${r0}_OPT:$d0=$mid
MB_REGION${r0}_MIN:$d0=$min
MB_REGION${r0}_MAX:$d0=$max"
		nat_write_case "$TESTGRP" "OPT+MIN+MAX, same region, MIN<=OPT<=MAX" "$content" &&
			nat_verify "$TESTGRP" "OPT+MIN+MAX, same region" "$content"

		# The same three controllers with every value identical: removes
		# any possible value-ordering explanation for a rejection.
		content="MB_REGION${r0}_OPT:$d0=$max
MB_REGION${r0}_MIN:$d0=$max
MB_REGION${r0}_MAX:$d0=$max"
		nat_write_case "$TESTGRP" "OPT+MIN+MAX, same region, all values equal" "$content" &&
			nat_verify "$TESTGRP" "OPT+MIN+MAX, all values equal" "$content"
	else
		skip "native write: OPT+MIN+MAX, same region" "region $r0 lacks OPT/MIN/MAX"
	fi

	# -- 7. every controller of every region in one write ----------------
	local n
	content=""
	for n in "${MBA_CTRLS[@]}"; do
		content="${content:+$content$nl}$n:$d0=$max"
	done
	nat_write_case "$TESTGRP" "all ${#MBA_CTRLS[@]} controllers in one write" "$content" &&
		nat_verify "$TESTGRP" "all controllers in one write" "$content"

	# -- 8. a single-controller write still works afterwards -------------
	# The report says one rejected multi-controller write left the MBA
	# resource wedged for subsequent writes, including simple ones.
	content="$c:$d0=$max"
	nat_write_case "$TESTGRP" "single controller again, after the combinations above" \
		"$content" &&
		nat_verify "$TESTGRP" "single controller again" "$content"

	# -- 9. a second, untouched group is unaffected ----------------------
	# The report says a different group's write started failing after the
	# first group's write was rejected.
	local other="${TESTGRP}_b"
	if mkdir -p "$RESCTRL/$other" 2>/dev/null; then
		content="$c:$d0=$max"
		nat_write_case "$other" "single controller in a second group ($other)" \
			"$content" &&
			nat_verify "$other" "single controller in a second group" "$content"
		rmdir "$RESCTRL/$other" 2>/dev/null
	else
		skip "native write: single controller in a second group" "cannot create $other"
	fi

	# -- 10. the reset pattern (one controller type, all domains) --------
	# This is the "plain reset" that was reported to start failing.
	local bad=0 t2
	for t2 in OPT MIN MAX; do
		nat_ctrl "$r0" "$t2" >/dev/null || continue
		mba_set_region "$TESTGRP" "$r0" "MB_REGION${r0}_${t2}" "$max" || bad=1
	done
	check "native write: reset pattern (one controller type at a time, all domains)" "$bad" \
		"$(last_cmd)"

	# -- informational: inverted values, behaviour is not specified ------
	if [ "$have_min" = 1 ] && [ "$have_max" = 1 ] && [ "$min" -ne "$max" ]; then
		if sch_write "$TESTGRP" "MB_REGION${r0}_MIN:$d0=$max
MB_REGION${r0}_MAX:$d0=$min"; then
			say "note: inverted MIN($max) > MAX($min) was ACCEPTED"
		else
			say "note: inverted MIN($max) > MAX($min) was rejected: $(last_cmd)"
		fi
	fi

	# restore
	for n in "${MBA_CTRLS[@]}"; do
		mba_set_region "$TESTGRP" "" "$n" "$max"
	done
}

#---------------------------------------------------------------------------
test_mode_switch_preserves() {
	say "=== control values across a control_mode switch ==="

	if [ "$HAVE_REGION_MBA" != 1 ]; then
		skip "mode switch value preservation" "no region-aware MBA"
		return
	fi

	local c d0 min max legacy_val
	c="${MBA_CTRLS[0]}"
	min="$(ctrl_prop "$c" min)"; max="$(ctrl_prop "$c" max)"
	d0="$(sch_domains "$c" | head -1)"

	set_mode native
	sch_write "" "$c:$d0=$min"
	set_mode legacy
	check "native -> legacy switch succeeds" $?
	check "legacy: region control hidden after switch" \
		$(sch_names | grep -q '^MB_REGION' && echo 1 || echo 0)

	legacy_val="$(sch_get "" MB "$d0")"
	check "legacy: MB value still readable after switch ($legacy_val)" \
		$([ -n "$legacy_val" ]; echo $?)

	set_mode native
	assert_eq "native: region control value survived the mode round-trip" \
		"$min" "$(sch_get "" "$c" "$d0")"

	sch_write "" "$c:$d0=$max"
}

#---------------------------------------------------------------------------
test_group_isolation() {
	say "=== per-group schemata ==="

	if [ "$HAVE_REGION_MBA" != 1 ]; then
		skip "per-group region schemata" "no region-aware MBA"
		return
	fi

	set_mode native
	rmdir "$RESCTRL/$TESTGRP" 2>/dev/null
	mkdir "$RESCTRL/$TESTGRP" 2>/dev/null
	check "create control group $TESTGRP" $?

	local c d0 min max
	c="${MBA_CTRLS[0]}"
	min="$(ctrl_prop "$c" min)"; max="$(ctrl_prop "$c" max)"
	d0="$(sch_domains "$c" | head -1)"

	sch_write "" "$c:$d0=$max"
	sch_write "$TESTGRP" "$c:$d0=$min"
	check "group: write $c:$d0=$min in $TESTGRP accepted" $?
	assert_eq "group: $TESTGRP sees $min" "$min" "$(sch_get "$TESTGRP" "$c" "$d0")"
	assert_eq "group: default group still sees $max" "$max" "$(sch_get "" "$c" "$d0")"

	check "group: schemata of $TESTGRP lists the same controls" \
		$(diff <(sch_names) <(awk -F: 'NF>1 { n=$1; gsub(/^[ \t]+|[ \t]+$/,"",n); print n }' \
			"$(sch_file "$TESTGRP")") >/dev/null; echo $?)

	sch_write "$TESTGRP" "$c:$d0=$max"
}

#---------------------------------------------------------------------------
test_mon_file_visibility() {
	say "=== mon_data file visibility vs control_mode ==="

	if [ "$HAVE_REGION_MBM" != 1 ]; then
		skip "region-aware MBM files" "no mbm_region<n>_bytes in mon_features"
		return
	fi
	ok "mon_features advertises region MBM events: region ${MBM_REGIONS[*]}"

	local d r bad

	set_mode native
	bad=0
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			[ -r "$(mon_file "" "$d" "mbm_region${r}_bytes")" ] || bad=1
		done
	done
	check "native: mbm_region<n>_bytes visible in every mon domain" "$bad"

	bad=0
	for d in $(mon_domains); do
		[ -e "$(mon_file "" "$d" mbm_total_bytes)" ] && bad=1
		[ -e "$(mon_file "" "$d" mbm_local_bytes)" ] && bad=1
	done
	check "native: legacy mbm_total/local_bytes hidden" "$bad"

	bad=0
	for d in $(mon_domains); do
		[ -r "$(mon_file "" "$d" llc_occupancy)" ] || bad=1
	done
	check "native: llc_occupancy visible in every mon domain" "$bad"

	set_mode legacy
	bad=0
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			[ -e "$(mon_file "" "$d" "mbm_region${r}_bytes")" ] && bad=1
		done
	done
	check "legacy: mbm_region<n>_bytes hidden" "$bad"
	check "legacy: mbm_total_bytes visible" \
		$([ -r "$(mon_file "" "$(mon_domains | head -1)" mbm_total_bytes)" ]; echo $?)

	# Same switching must apply inside a group created before the switch.
	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null
	set_mode native
	bad=0
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			[ -r "$(mon_file "$TESTGRP" "$d" "mbm_region${r}_bytes")" ] || bad=1
		done
	done
	check "native: region MBM files also switched inside group $TESTGRP" "$bad"
}

#---------------------------------------------------------------------------
test_mbm_counts() {
	say "=== region-aware MBM counting ==="

	if [ "$HAVE_REGION_MBM" != 1 ]; then
		skip "region MBM counting" "no region MBM"
		return
	fi
	if [ "$WORKLOAD_OK" != 1 ]; then
		skip "region MBM counting" "memory workload unavailable"
		return
	fi
	if [ "$MON_OK" != 1 ]; then
		skip "region MBM counting" "$MON_SKIP_REASON"
		return
	fi

	set_mode native
	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null

	local d r v bad=0
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			v="$(cat "$(mon_file "$TESTGRP" "$d" "mbm_region${r}_bytes")" 2>/dev/null)"
			case "$v" in
			''|*[!0-9]*) bad=1; vsay "dom $d region $r -> '$v'" ;;
			esac
		done
	done
	check "region MBM counters read as plain integers" "$bad"

	# Counters must never go backwards.
	local -A first=()
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			first[$d:$r]="$(mon_read "$TESTGRP" "$d" "mbm_region${r}_bytes")"
		done
	done
	sleep 1
	bad=0
	for d in $(mon_domains); do
		for r in "${MBM_REGIONS[@]}"; do
			v="$(mon_read "$TESTGRP" "$d" "mbm_region${r}_bytes")"
			[ "$v" -lt "${first[$d:$r]}" ] && bad=1
		done
	done
	check "region MBM counters are monotonically non-decreasing" "$bad"

	local dom cpus mib
	dom="$(mon_domains | head -1)"
	cpus="$(echo "${DOM_CPUS[$dom]}" | tr ' ' '\n' | head -"$LOAD_THREADS" | paste -sd' ' -)"
	mib=$(( L3_SIZE_KB / 1024 * 2 ))
	[ "$mib" -lt 128 ] && mib=128
	say "load: domain $dom, cpus [$cpus], ${mib}MiB/worker, ${MBM_WINDOW}s window"

	local node delta
	for r in "${MBM_REGIONS[@]}"; do
		node="${REGION_NODE[$r]:-none}"
		if [ "$node" = none ]; then
			# No online memory in this region: the counter must still be
			# readable and must stay (nearly) idle.
			delta="$(measure_bw "$TESTGRP" "mbm_region${r}_bytes" \
				"$(echo "$cpus" | cut -d' ' -f1)" none "$mib" 2 "$dom")"
			check "region $r (no online NUMA node): counter idle (delta=$delta)" \
				$([ "$delta" -lt "$MBM_MIN_BYTES" ]; echo $?)
			continue
		fi

		delta="$(measure_bw "$TESTGRP" "mbm_region${r}_bytes" "$cpus" "$node" \
			"$mib" "$MBM_WINDOW" "$dom")"
		say "region $r (node $node) domain $dom: $delta bytes -> $(human_bw "$delta" "$MBM_WINDOW")"
		check "region $r MBM counts traffic bound to node $node" \
			$([ "$delta" -ge "$MBM_MIN_BYTES" ]; echo $?) \
			"delta=$delta < $MBM_MIN_BYTES"
	done

	# Locality: the loaded domain must dominate.
	local busy=0 other=0 dd
	for r in "${MBM_REGIONS[@]}"; do
		node="${REGION_NODE[$r]:-none}"
		[ "$node" = none ] && continue
		start_load "$TESTGRP" "$cpus" "$node" "$mib" $(( MBM_WINDOW + 8 ))
		sleep 2
		declare -A B=()
		for dd in $(mon_domains); do B[$dd]="$(mon_read "$TESTGRP" "$dd" "mbm_region${r}_bytes")"; done
		sleep "$MBM_WINDOW"
		for dd in $(mon_domains); do
			v=$(( $(mon_read "$TESTGRP" "$dd" "mbm_region${r}_bytes") - ${B[$dd]} ))
			if [ "$dd" = "$dom" ]; then busy=$v; else other=$(( other + v )); fi
			vsay "region $r domain $dd delta=$v"
		done
		stop_load
		if [ "$busy" -gt $(( other * 2 )) ]; then
			ok "region $r: traffic attributed to the loaded L3 domain ($busy vs $other)"
		else
			warn "region $r: loaded domain $dom delta=$busy, other domains=$other"
			ok "region $r: per-domain attribution reported (see WARN)"
		fi
		break
	done

	# Legacy mode must keep counting with the legacy event.
	local any_node=none
	for r in "${MBM_REGIONS[@]}"; do
		if [ "${REGION_NODE[$r]:-none}" != none ]; then
			any_node="${REGION_NODE[$r]}"
			break
		fi
	done
	set_mode legacy
	delta="$(measure_bw "$TESTGRP" mbm_total_bytes "$cpus" "$any_node" \
		"$mib" "$MBM_WINDOW" "$dom")"
	say "legacy mbm_total_bytes domain $dom: $delta bytes -> $(human_bw "$delta" "$MBM_WINDOW")"
	check "legacy: mbm_total_bytes still counts after switching back" \
		$([ "$delta" -ge "$MBM_MIN_BYTES" ]; echo $?) "delta=$delta"
	set_mode native
}

#---------------------------------------------------------------------------
# Pick the schemata values to sweep for a control: max, a midpoint rounded to
# the control's granularity, and the low level (default = the control's min).
mba_levels() { # <ctrl name> -> descending, de-duplicated list of values
	local min max step low mid out=""
	min="$(ctrl_prop "$1" min)"
	max="$(ctrl_prop "$1" max)"
	step="$(ctrl_prop "$1" tolerance)"
	case "$step" in ''|*[!0-9]*) step=1 ;; esac
	[ "$step" -lt 1 ] && step=1
	low="${MBA_LOW:-$min}"
	mid=$(( (low + (max - low) / 2) / step * step ))
	[ "$mid" -lt "$low" ] && mid="$low"
	[ "$mid" -gt "$max" ] && mid="$max"

	local v
	for v in "$max" "$mid" "$low"; do
		case " $out " in *" $v "*) continue ;; esac
		out="${out:+$out }$v"
	done
	echo "$out"
}

# Fine-grained ascending sweep for native region-aware MBA:
#   min, then every multiple of MBA_SWEEP_STEP up to MBA_SWEEP_MAX
# e.g. with step 5 and max 50: 1 5 10 15 20 25 30 35 40 45 50
mba_sweep_levels() { # <ctrl name> -> ascending, de-duplicated list of values
	local min max step top v out=""
	min="$(ctrl_prop "$1" min)"
	max="$(ctrl_prop "$1" max)"
	case "$min" in ''|*[!0-9]*) min=1 ;; esac
	case "$max" in ''|*[!0-9]*) max=$min ;; esac
	step="$MBA_SWEEP_STEP"
	case "$step" in ''|*[!0-9]*) step=5 ;; esac
	[ "$step" -lt 1 ] && step=1
	top="$MBA_SWEEP_MAX"
	case "$top" in ''|*[!0-9]*) top="$max" ;; esac
	[ "$top" -gt "$max" ] && top="$max"
	[ "$top" -lt "$min" ] && top="$max"

	for v in "${MBA_LOW:-$min}" $(seq "$step" "$step" "$top") "$top"; do
		[ "$v" -lt "$min" ] && continue
		[ "$v" -gt "$max" ] && continue
		case " $out " in *" $v "*) continue ;; esac
		out="${out:+$out }$v"
	done
	echo "$out"
}

# Validate a fine-grained ascending sweep: bandwidth must grow with the
# schemata value, must not go backwards, and must correlate with the value.
mba_check_scaling() { # <label> <levels asc...> -- <bytes...>
	local label="$1"; shift
	local -a lv=() bw=()
	local seen=0 a
	for a in "$@"; do
		if [ "$a" = -- ]; then seen=1; continue; fi
		if [ "$seen" = 0 ]; then lv+=("$a"); else bw+=("$a"); fi
	done

	local n="${#bw[@]}"
	if [ "$n" -lt 3 ]; then
		skip "$label: bandwidth scales with the schemata value" "only $n sweep points"
		return
	fi

	# Peak over the whole sweep, not just the last point.
	local i peak=0
	for (( i = 0; i < n; i++ )); do
		[ "${bw[$i]}" -gt "$peak" ] && peak="${bw[$i]}"
	done

	local pct sat=""
	for (( i = 0; i < n; i++ )); do
		pct=$(awk -v a="${bw[$i]}" -v b="$peak" \
			'BEGIN { printf "%d", (b > 0) ? a * 100 / b : 0 }')
		say "$(printf '%s: %4s -> %-12s %3d%% of peak' "$label" "${lv[$i]}" \
			"$(human_bw "${bw[$i]}" "$MBM_WINDOW")" "$pct")"
		[ -z "$sat" ] && [ "$pct" -ge "$MBA_SAT_PCT" ] && sat="${lv[$i]}"
	done

	# 1. The minimum value must throttle relative to the peak.
	local ratio
	ratio=$(awk -v a="${bw[0]}" -v b="$peak" \
		'BEGIN { printf "%d", (b > 0) ? a * 100 / b : 100 }')
	if [ "$ratio" -le "$MBA_RATIO" ]; then
		ok "$label: value ${lv[0]} gives ${ratio}% of peak bandwidth"
	elif [ "$MBA_STRICT" = 1 ]; then
		notok "$label: lowest value throttles" "ratio ${ratio}% > ${MBA_RATIO}%"
	else
		warn "$label: value ${lv[0]} gave ${ratio}% of peak bandwidth; the platform may not throttle at this level"
		skip "$label: lowest value throttles" "no measurable effect (ratio ${ratio}%)"
	fi

	# 2. Bandwidth must not drop as the value is raised (noise tolerated).
	local tol=$(( peak * MBA_MONO_TOL / 100 )) bad=0 prev cur
	for (( i = 1; i < n; i++ )); do
		prev="${bw[$(( i - 1 ))]}"; cur="${bw[$i]}"
		if [ "$cur" -lt $(( prev - tol )) ]; then
			bad=1
			vsay "$label: regression at ${lv[$i]}: $cur < $prev - $tol"
		fi
	done
	check "$label: bandwidth is non-decreasing from ${lv[0]} to ${lv[$(( n - 1 ))]}" "$bad"

	# 3. Bandwidth must track the schemata value (Pearson correlation x100).
	local corr
	corr=$(awk -v L="${lv[*]}" -v B="${bw[*]}" 'BEGIN {
		n = split(L, x, " "); split(B, y, " ")
		for (i = 1; i <= n; i++) { sx += x[i]; sy += y[i] }
		mx = sx / n; my = sy / n
		for (i = 1; i <= n; i++) {
			dx = x[i] - mx; dy = y[i] - my
			sxy += dx * dy; sxx += dx * dx; syy += dy * dy
		}
		printf "%d", (sxx > 0 && syy > 0) ? sxy / sqrt(sxx * syy) * 100 : 0
	}')
	check "$label: bandwidth correlates with the schemata value (r=0.${corr#-}, need >= 0.$MBA_CORR)" \
		$([ "$corr" -ge "$MBA_CORR" ]; echo $?)

	if [ -n "$sat" ]; then
		say "$label: bandwidth saturates (>= ${MBA_SAT_PCT}% of peak) at value $sat"
	else
		say "$label: bandwidth never reached ${MBA_SAT_PCT}% of peak within the sweep"
	fi
}

# Validate a measured throttling curve: the lowest level must cut bandwidth,
# and bandwidth must not grow as the limit is lowered.
mba_check_curve() { # <label> <levels...> -- <bytes...>
	local label="$1"; shift
	local -a lv=() bw=()
	local seen=0 a
	for a in "$@"; do
		if [ "$a" = -- ]; then seen=1; continue; fi
		if [ "$seen" = 0 ]; then lv+=("$a"); else bw+=("$a"); fi
	done

	local n="${#bw[@]}" hi="${bw[0]}" lo="${bw[$(( ${#bw[@]} - 1 ))]}" ratio
	ratio=$(awk -v a="$lo" -v b="$hi" 'BEGIN { printf "%d", (b > 0) ? a * 100 / b : 100 }')

	if [ "$ratio" -le "$MBA_RATIO" ]; then
		ok "$label: value ${lv[$(( n - 1 ))]} gives ${ratio}% of the bandwidth of value ${lv[0]}"
	elif [ "$MBA_STRICT" = 1 ]; then
		notok "$label: throttling reduces bandwidth" "ratio ${ratio}% > ${MBA_RATIO}%"
	else
		warn "$label: value ${lv[$(( n - 1 ))]} gave ${ratio}% of unthrottled bandwidth; the platform may not throttle at this level (set MBA_LOW/MBA_STRICT to tighten)"
		skip "$label: throttling reduces bandwidth" "no measurable effect (ratio ${ratio}%)"
	fi

	[ "$n" -gt 2 ] || return 0
	local i bad=0 prev cur
	for (( i = 1; i < n; i++ )); do
		prev="${bw[$(( i - 1 ))]}"; cur="${bw[$i]}"
		[ "$cur" -gt $(( prev + prev / 10 )) ] && bad=1
	done
	check "$label: bandwidth is non-increasing across values ${lv[*]}" "$bad"
}

# First region that has online memory, or "none".
first_online_node() {
	local r
	for r in "${MBM_REGIONS[@]}"; do
		if [ "${REGION_NODE[$r]:-none}" != none ]; then
			echo "${REGION_NODE[$r]}"
			return 0
		fi
	done
	echo none
}

#---------------------------------------------------------------------------
test_mba_throttle_legacy() {
	say "=== legacy MBA throttling (MB schemata vs mbm_total_bytes) ==="

	if [ "$WORKLOAD_OK" != 1 ]; then
		skip "legacy MBA throttling" "memory workload unavailable"
		return
	fi
	if [ "$MON_OK" != 1 ]; then
		skip "legacy MBA throttling" "$MON_SKIP_REASON"
		return
	fi

	set_mode legacy
	if ! has_name MB; then
		skip "legacy MBA throttling" "no legacy MB control"
		return
	fi
	if ! grep -qw mbm_total_bytes "$INFO/L3_MON/mon_features" 2>/dev/null; then
		skip "legacy MBA throttling" "no mbm_total_bytes event"
		return
	fi

	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null

	local dom cpus mib node doms lvl bw
	dom="$(mon_domains | head -1)"
	cpus="$(echo "${DOM_CPUS[$dom]}" | tr ' ' '\n' | head -"$LOAD_THREADS" | paste -sd' ' -)"
	mib=$(( L3_SIZE_KB / 1024 * 2 ))
	[ "$mib" -lt 128 ] && mib=128
	node="$(first_online_node)"
	doms="$(sch_domains MB | paste -sd' ' -)"

	local -a levels=() bws=()
	read -r -a levels <<< "$(mba_levels MB)"
	say "legacy MB levels: ${levels[*]} (domain $dom, cpus [$cpus], node $node)"

	for lvl in "${levels[@]}"; do
		sch_write "$TESTGRP" "MB:$(echo "$doms" | tr ' ' '\n' | sed "s/\$/=$lvl/" | paste -sd';' -)"
		check "legacy: MB=$lvl programmed" $?
		assert_eq "legacy: MB:$dom reads back $lvl" "$lvl" "$(sch_get "$TESTGRP" MB "$dom")"
		bw="$(measure_bw "$TESTGRP" mbm_total_bytes "$cpus" "$node" \
			"$mib" "$MBM_WINDOW" "$dom")"
		bws+=("$bw")
		say "legacy: MB=$lvl -> $(human_bw "$bw" "$MBM_WINDOW")"
	done

	mba_check_curve "legacy MB" "${levels[@]}" -- "${bws[@]}"

	sch_write "$TESTGRP" "MB:$(echo "$doms" | tr ' ' '\n' |
		sed "s/\$/=$(ctrl_prop MB max)/" | paste -sd';' -)"
}

#---------------------------------------------------------------------------
test_mba_throttle() {
	say "=== region-aware MBA throttling ==="

	if [ "$HAVE_REGION_MBA" != 1 ] || [ "$HAVE_REGION_MBM" != 1 ]; then
		skip "region MBA throttling" "needs both region MBA and region MBM"
		return
	fi
	if [ "$WORKLOAD_OK" != 1 ]; then
		skip "region MBA throttling" "memory workload unavailable"
		return
	fi
	if [ "$MON_OK" != 1 ]; then
		skip "region MBA throttling" "$MON_SKIP_REASON"
		return
	fi

	set_mode native
	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null

	local r node dom cpus mib max lvl bw
	dom="$(mon_domains | head -1)"
	cpus="$(echo "${DOM_CPUS[$dom]}" | tr ' ' '\n' | head -"$LOAD_THREADS" | paste -sd' ' -)"
	mib=$(( L3_SIZE_KB / 1024 * 2 ))
	[ "$mib" -lt 128 ] && mib=128

	for r in "${MBA_REGIONS[@]}"; do
		node="${REGION_NODE[$r]:-none}"
		if [ "$node" = none ]; then
			skip "region $r MBA throttling" "no online memory in region $r"
			continue
		fi

		# Program every exposed control of this region (OPT/MIN/MAX).
		local -a ctrls=()
		local c
		for c in "${MBA_CTRLS[@]}"; do
			case "$c" in MB_REGION${r}_*) ctrls+=("$c") ;; esac
		done
		max="$(ctrl_prop "${ctrls[0]}" max)"

		local -a levels=() bws=()
		read -r -a levels <<< "$(mba_sweep_levels "${ctrls[0]}")"
		say "region $r sweep: ${levels[*]} (controls ${ctrls[*]}, node $node, ${MBM_WINDOW}s each)"

		bws=()
		for lvl in "${levels[@]}"; do
			mba_set_region "$TESTGRP" "$r" "${ctrls[*]}" "$lvl"
			check "region $r: value $lvl programmed" $?
			assert_eq "region $r: ${ctrls[0]} reads back $lvl" "$lvl" \
				"$(sch_get "$TESTGRP" "${ctrls[0]}" "$dom")"
			bw="$(measure_bw "$TESTGRP" "mbm_region${r}_bytes" "$cpus" "$node" \
				"$mib" "$MBM_WINDOW" "$dom")"
			bws+=("$bw")
			vsay "region $r: ${ctrls[0]}=$lvl -> $(human_bw "$bw" "$MBM_WINDOW")"
		done

		mba_check_scaling "region $r MBA" "${levels[@]}" -- "${bws[@]}"

		mba_set_region "$TESTGRP" "$r" "${ctrls[*]}" "$max"
	done
}


mba_set_region() { # <group> <region> <ctrl list> <value>
	local grp="$1" region="$2" list="$3" val="$4" c lines=""
	local doms
	for c in $list; do
		doms="$(sch_domains "$c" | sed "s/\$/=$val/" | paste -sd';' -)"
		lines="${lines}${c}:${doms}"$'\n'
	done
	sch_write "$grp" "${lines%$'\n'}"
}

#---------------------------------------------------------------------------
test_cmt() {
	say "=== MMIO-based CMT (llc_occupancy) ==="

	if [ "$WORKLOAD_OK" != 1 ]; then
		skip "CMT occupancy" "memory workload unavailable"
		return
	fi
	if [ "$MON_OK" != 1 ]; then
		skip "CMT occupancy" "$MON_SKIP_REASON"
		return
	fi
	if ! grep -qw llc_occupancy "$INFO/L3_MON/mon_features" 2>/dev/null; then
		skip "CMT occupancy" "llc_occupancy not supported"
		return
	fi

	local dom cpu cbm_mask full_bits mib
	dom="$(mon_domains | head -1)"
	cpu="${DOM_CPU[$dom]}"
	cbm_mask="$(cat "$INFO/L3/cbm_mask")"
	full_bits=$(bit_count "$cbm_mask")
	mib=$(( L3_SIZE_KB / 1024 * 2 ))
	say "L3 domain $dom: size ${L3_SIZE_KB}K, $L3_WAYS ways, cbm_mask $cbm_mask, buffer ${mib}MiB"

	mkdir -p "$RESCTRL/$TESTGRP" 2>/dev/null

	# Keep L2 allocation of the test group small so that L3 occupancy is
	# dominated by the workload (same trick as the resctrl kselftest).
	local l2id l2min
	l2id="$(cat /sys/devices/system/cpu/cpu"$cpu"/cache/index2/id 2>/dev/null)"
	l2min="$(cat "$INFO/L2/min_cbm_bits" 2>/dev/null)"
	if [ -n "$l2id" ] && [ -n "$l2min" ]; then
		sch_write "$TESTGRP" "L2:$l2id=$(printf '%x' $(( (1 << l2min) - 1 )))"
	fi

	local bits mask compl occ_sum occ avg span diff pct i
	for bits in "$full_bits" $(( full_bits / 2 )); do
		[ "$bits" -ge 1 ] || continue
		mask="$(printf '%x' $(( (1 << bits) - 1 )))"
		# Keep the rest of the machine out of the ways under test when
		# the bitmask leaves room for it.
		compl=$(( 0x$cbm_mask & ~((1 << bits) - 1) ))
		if [ "$compl" -ne 0 ]; then
			sch_write "" "L3:$dom=$(printf '%x' "$compl")"
		fi
		sch_write "$TESTGRP" "L3:$dom=$mask"
		if [ "$(sch_get "$TESTGRP" L3 "$dom")" != "$mask" ]; then
			notok "CMT: program L3:$dom=$mask for $TESTGRP" "$(last_cmd)"
			continue
		fi
		ok "CMT: program L3:$dom=$mask ($bits ways) for $TESTGRP"

		occ_sum=0
		for i in $(seq 1 "$CMT_RUNS"); do
			start_load "$TESTGRP" "$cpu" none "$mib" 12
			sleep 6
			occ="$(mon_read "$TESTGRP" "$dom" llc_occupancy)"
			stop_load
			occ_sum=$(( occ_sum + occ ))
			vsay "run $i: llc_occupancy=$occ"
		done
		avg=$(( occ_sum / CMT_RUNS ))
		span=$(( L3_SIZE_KB * 1024 / full_bits * bits ))
		diff=$(( span - avg )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
		pct=$(awk -v d="$diff" -v s="$span" 'BEGIN { printf "%d", d * 100 / s }')
		say "CMT $bits/$full_bits ways: expected $span B, measured $avg B, diff ${pct}%"

		if [ "$pct" -le "$CMT_MAX_DIFF_PERCENT" ] || [ "$diff" -le "$CMT_MAX_DIFF" ]; then
			ok "CMT: occupancy of $bits ways within ${CMT_MAX_DIFF_PERCENT}% of the allocation"
		else
			notok "CMT: occupancy of $bits ways within ${CMT_MAX_DIFF_PERCENT}% of the allocation" \
				"expected $span, got $avg (${pct}%)"
		fi
	done

	sch_write "" "L3:$dom=$cbm_mask"
	sch_write "$TESTGRP" "L3:$dom=$cbm_mask"

	# An idle group must report a small occupancy.
	rmdir "$RESCTRL/$TESTGRP" 2>/dev/null
	mkdir "$RESCTRL/$TESTGRP" 2>/dev/null
	sleep 1
	occ="$(mon_sum "$TESTGRP" llc_occupancy)"
	check "CMT: freshly created group reports near-zero occupancy ($occ B)" \
		$([ "$occ" -lt $(( L3_SIZE_KB * 1024 / 10 )) ]; echo $?)
}

bit_count() { # <hex mask>
	local v=$(( 0x$1 )) n=0
	while [ "$v" -ne 0 ]; do n=$(( n + (v & 1) )); v=$(( v >> 1 )); done
	echo "$n"
}

#############################################################################
# Main
#############################################################################
main() {
	require_root

	if ! mount_resctrl; then
		say "resctrl could not be mounted at $RESCTRL"
		exit 4
	fi
	if [ ! -d "$INFO" ]; then
		say "no $INFO - resctrl not available"
		exit 4
	fi

	say "kernel: $(uname -r)"
	say "resctrl: $RESCTRL"

	ORIG_MODE=legacy
	mode_is native && ORIG_MODE=native
	trap cleanup EXIT INT TERM

	build_topology
	discover

	say "L3 mon domains: $(mon_domains | paste -sd, -)"
	say "region -> numa node:$(for r in "${!REGION_NODE[@]}"; do
		printf ' %s=%s' "$r" "${REGION_NODE[$r]}"; done)"

	if [ "$SKIP_WORKLOAD" = 1 ]; then
		say "workload tests disabled (SKIP_WORKLOAD=1)"
	elif command -v gcc >/dev/null 2>&1 && build_worker; then
		WORKLOAD_OK=1
		if mon_sanity_check; then
			MON_OK=1
		else
			say "$MON_SKIP_REASON"
			say "workload driven tests will be skipped"
		fi
	else
		say "gcc unavailable or workload build failed - workload tests skipped"
	fi

	test_control_mode
	test_ctrl_properties
	test_schemata_format
	test_native_multi_ctrl_write
	test_mode_switch_preserves
	test_group_isolation
	test_mon_file_visibility
	test_cmt
	test_mbm_counts
	test_mba_throttle
	test_mba_throttle_legacy

	printf '1..%d\n' "$TC"
	say "---------------------------------------------"
	say "passed: $NPASS  failed: $NFAIL  skipped: $NSKIP  warnings: $NWARN"
	if [ "$NFAIL" -gt 0 ]; then
		say "failures:"
		local f
		for f in "${FAILED[@]}"; do say "  - $f"; done
		exit 1
	fi
	exit 0
}

main "$@"
