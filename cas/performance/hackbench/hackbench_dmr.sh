#!/bin/bash
#
# hackbench_dmr.sh: unattended hackbench A/B comparison of two kernel commits
#                   on a DMR test machine (default dmr_710).
#
# Run on the local build machine, inside (or with -s pointing at) the kernel
# source tree. For commit1 (BASE) and then commit2 (TEST), strictly in order:
#
#   build RPMs (dmr_compile.sh) -> install on HOST -> one-shot boot into it
#   -> wait until HOST is up on that kernel and usable -> set CPU state
#   -> [commit1 only, with --calibrate: calibrate -l]
#   -> run the hackbench sweep with the frozen -l -> wait for it to finish
#   -> verify the results
#
# then "launch_hackbench.sh compare <commit1> <commit2>", copy everything back,
# and write a short analysis. The local tree's checkout and .config are restored
# on exit, also on failure.
#
# Test conditions (identical on both kernels):
#   - sweep:    the "export MODES_LIST/GROUPS_LIST/FDS_LIST=" lines of
#               ../../test_all.sh
#   - -l:       one dedicated -l per config, from loops_30s.conf next to this
#               script (each single run >= 30s, close to 30s). Not recalibrated
#               unless --calibrate is given; then it is calibrated on commit1's
#               kernel with calibrate_loops.sh and saved as the new
#               loops_30s.conf.
#   - CPU:      turbo off, cpuidle states deeper than C1 off, governor
#               performance, cpufreq not pinned (cpu_check.sh apply), checked
#               again on every poll during the test.
#   - llc_balancing enabled, NUM_RUNS runs per config.
#
# The whole flow takes hours. Run it under tmux/screen or nohup, e.g.:
#   nohup bench_tool/cas/performance/hackbench/hackbench_dmr.sh <c1> <c2> > hb.log 2>&1 &
#
# Exit status: 0 = comparison done (warnings, e.g. runs < 30s, are in the
# report), non-zero = stopped on an error (see the log).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 [options] <commit1> <commit2>

  commit1 is the BASE kernel, commit2 the TEST kernel. Both are built from the
  source tree's current .config, with LOCALVERSION -c1_<sha> / -c2_<sha>.

Options:
  -c, --calibrate     recalibrate -l on the commit1 kernel and save it as
                      $SCRIPT_DIR/loops_30s.conf
                      (default: reuse the existing loops_30s.conf)
  -H, --host HOST     test machine (default: dmr_710)
  -s, --src DIR       kernel source tree (default: git toplevel of \$PWD)
  -n, --runs N        runs per config (default: 3)
  -m, --min-sec S     minimum seconds per single run (default: 30)
  -r, --rebuild       always rebuild/reinstall, even if HOST already has the
                      same kernel built from the same .config
  -b, --no-reboot-if-running
                      do not reboot HOST into a kernel it is already running
                      (only when that kernel was not just (re)installed); the
                      readiness and CPU-state checks still run. Default: always
                      reboot, so both kernels start from a fresh boot.
  -o, --out DIR       local output dir (default: <src>/results_hackbench/<run>)
  -k, --check         only run the pre-flight checks (local tree, commits,
                      sweep vs saved -l, ssh/sudo/bootctl on HOST) and print
                      the plan; build/boot/test nothing
  -h, --help          this help

Environment: JOBS (make -j, default nproc), BOOT_TIMEOUT (s, default 1800),
             POLL (s between progress checks, default 120)
EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
HOST=dmr_710
SRC=""
NUM_RUNS=3
MIN_SEC=30
CALIBRATE=0
REBUILD=0
REUSE_BOOT=0
CHECK=0
OUT=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--calibrate) CALIBRATE=1 ;;
        -H|--host)      HOST="${2:?}"; shift ;;
        -s|--src)       SRC="${2:?}"; shift ;;
        -n|--runs)      NUM_RUNS="${2:?}"; shift ;;
        -m|--min-sec)   MIN_SEC="${2:?}"; shift ;;
        -r|--rebuild)   REBUILD=1 ;;
        -b|--no-reboot-if-running) REUSE_BOOT=1 ;;
        -o|--out)       OUT="${2:?}"; shift ;;
        -k|--check)     CHECK=1 ;;
        -h|--help)      usage 0 ;;
        -*)             echo "unknown option: $1" >&2; usage 1 ;;
        *)              ARGS+=("$1") ;;
    esac
    shift
done
[ ${#ARGS[@]} -eq 2 ] || usage 1
C1_ARG="${ARGS[0]}"
C2_ARG="${ARGS[1]}"

JOBS="${JOBS:-$(nproc)}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-1800}"
POLL="${POLL:-120}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;32m[%s] ==>\033[0m %s\n' "$(date '+%F %T')" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[%s] [warn]\033[0m %s\n' "$(date '+%F %T')" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31m[%s] [error]\033[0m %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }
WARNINGS=()

rsh()   { "${SSH[@]}" "$HOST" "$@"; }                     # as the login user
rroot() { "${SSH[@]}" "$HOST" "sudo su -c 'bash -s'"; }   # as root, script on stdin

# ---------------------------------------------------------------------------
# Pre-flight (local)
# ---------------------------------------------------------------------------
if [ -z "$SRC" ]; then
    SRC="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git tree; use -s <kernel-src>"
fi
SRC="$(cd "$SRC" && pwd)" || die "bad source dir"
cd "$SRC" || die "cannot cd to $SRC"
[ -f Makefile ] && [ -f .config ] || die "$SRC is not a configured kernel tree (.config missing)"
[ -x ./scripts/config ] || die "scripts/config missing in $SRC"
[ -z "$(git status --porcelain -uno)" ] || die "tracked files are modified in $SRC; commit or stash them first"

for f in "$CAS_DIR/test_all.sh" "$SCRIPT_DIR/launch_hackbench.sh" \
         "$SCRIPT_DIR/cpu_check.sh" "$SCRIPT_DIR/calibrate_loops.sh"; do
    [ -f "$f" ] || die "missing $f"
done
LOOPS_SAVED="$SCRIPT_DIR/loops_${MIN_SEC}s.conf"
[ "$CALIBRATE" -eq 1 ] || [ -s "$LOOPS_SAVED" ] || \
    die "no saved -l ($LOOPS_SAVED); run with --calibrate first"

C1=$(git rev-parse --verify "${C1_ARG}^{commit}" 2>/dev/null) || die "unknown commit: $C1_ARG"
C2=$(git rev-parse --verify "${C2_ARG}^{commit}" 2>/dev/null) || die "unknown commit: $C2_ARG"
S1=$(git log -1 --format='%h ("%s")' "$C1")
S2=$(git log -1 --format='%h ("%s")' "$C2")
TAG1=c1_$(git rev-parse --short=12 "$C1")
TAG2=c2_$(git rev-parse --short=12 "$C2")
RUN=hb_$(date +%Y%m%d_%H%M%S)
R1=${RUN}_${TAG1}
R2=${RUN}_${TAG2}
[ "$CHECK" -eq 1 ] && OUT=$(mktemp -d /tmp/hackbench_dmr_check.XXXXXX)
OUT="${OUT:-$SRC/results_hackbench/$RUN}"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)"

# Everything from here on also goes to $OUT/hackbench_dmr.log.
exec > >(tee -a "$OUT/hackbench_dmr.log") 2>&1

# Sweep: the active export lines of test_all.sh (also used verbatim remotely).
SWEEP_EXPORTS="$(grep -E '^export (MODES|GROUPS|FDS)_LIST=' "$CAS_DIR/test_all.sh")"
eval "$SWEEP_EXPORTS"
read -r -a MODES <<< "${MODES_LIST:-}"
read -r -a GRPS  <<< "${GROUPS_LIST:-}"
read -r -a FDS   <<< "${FDS_LIST:-}"
NCFG=$(( ${#MODES[@]} * ${#GRPS[@]} * ${#FDS[@]} ))
[ "$NCFG" -gt 0 ] || die "empty sweep in $CAS_DIR/test_all.sh"
SWEEP="modes=[$MODES_LIST] groups=[$GROUPS_LIST] fds=[$FDS_LIST]"

# Restore the local tree on any exit.
ORIG=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
CONFIG_SAVE="$OUT/default.config"
cp .config "$CONFIG_SAVE"
cleanup() {
    cd "$SRC" || return
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$ORIG")" ] || ! git symbolic-ref -q HEAD >/dev/null; then
        git checkout -q "$ORIG" 2>/dev/null || echo "WARNING: could not check out $ORIG again" >&2
    fi
    cp "$CONFIG_SAVE" .config
    make -s include/config/kernel.release >/dev/null 2>&1
}
trap cleanup EXIT
trap 'die "interrupted"' INT TERM

log "hackbench A/B on $HOST, run $RUN"
info "BASE commit1: $S1  -> LOCALVERSION -$TAG1"
info "TEST commit2: $S2  -> LOCALVERSION -$TAG2"
info "sweep:        $SWEEP ($NCFG configs) x $NUM_RUNS runs, each run >= ${MIN_SEC}s"
info "-l:           $([ "$CALIBRATE" -eq 1 ] && echo "calibrate on commit1 kernel" || echo "saved $LOOPS_SAVED")"
info "output:       $OUT"

# ---------------------------------------------------------------------------
# Pre-flight (remote)
# ---------------------------------------------------------------------------
RHOME=$(rsh 'echo $HOME') || die "cannot ssh to $HOST"
RCAS="$RHOME/bench_tool/cas"
RHB="$RCAS/performance/hackbench"
info "$HOST is running $(rsh uname -r), bench dir $RHB"
busy=$(rsh 'ps -eo pid,cmd | grep -E "[l]aunch_hackbench|[r]t-tests/hackbench|[c]alibrate_loops"')
[ -z "$busy" ] || die "hackbench is already running on $HOST:"$'\n'"$busy"
rroot <<< 'bootctl list >/dev/null' || die "$HOST: sudo/bootctl not usable"

if [ "$CHECK" -eq 1 ]; then
    for c in "$C1:$TAG1" "$C2:$TAG2"; do
        krel="$(make -s kernelversion)-${c#*:}+"
        kv=${krel//-/_}
        if rsh "rpm -q kernel-$kv >/dev/null 2>&1"; then st="installed on $HOST"; else st="not installed, will build"; fi
        [ "$REUSE_BOOT" -eq 1 ] && [ "$(rsh uname -r)" = "$krel" ] && st="$st, running now: no reboot if .config matches"
        info "kernel ${c#*:}: ~$krel ($st)"
    done
fi

if [ "$CHECK" -eq 0 ]; then
    log "Syncing $CAS_DIR to $HOST:$RCAS"
    rsync -rc --exclude rt-tests --exclude results --exclude loops.conf \
          "$CAS_DIR/" "$HOST:$RCAS/" || die "rsync failed"
fi
rsh "test -x $RHB/rt-tests/hackbench" || {
    [ "$CHECK" -eq 1 ] && die "hackbench binary missing on $HOST ($RHB/rt-tests/hackbench)"
    log "Building hackbench on $HOST"
    rroot <<< "cd $RHB && ./prepare_hackbench.sh" || die "prepare_hackbench.sh failed"
}

# ---------------------------------------------------------------------------
# -l for every config of the sweep
# ---------------------------------------------------------------------------
LOOPS_RUN="$OUT/loops_${RUN}.conf"
if [ "$CALIBRATE" -eq 0 ]; then
    : > "$LOOPS_RUN"
    missing=()
    for m in "${MODES[@]}"; do for g in "${GRPS[@]}"; do for f in "${FDS[@]}"; do
        line=$(awk -v m="$m" -v g="$g" -v f="$f" '$1 == m && $2 == g && $3 == f' "$LOOPS_SAVED")
        n=$(printf '%s' "$line" | grep -c .)
        if [ "$n" -eq 1 ]; then
            echo "$line" >> "$LOOPS_RUN"
        else
            missing+=("$m g$g f$f ($n entries)")
        fi
    done; done; done
    [ ${#missing[@]} -eq 0 ] || die "$LOOPS_SAVED does not match the sweep: ${missing[*]}; run with --calibrate"
    info "using saved -l for all $NCFG configs (calibrated on: $(sed -n 's/^kernel: *//p' "$LOOPS_SAVED.info" 2>/dev/null))"
fi
if [ "$CHECK" -eq 1 ]; then
    [ "$CALIBRATE" -eq 0 ] && awk '{printf "      %-7s g%-2s f%-2s -l %s\n", $1, $2, $3, $4}' "$LOOPS_RUN"
    log "Pre-flight OK (--check: nothing built, booted or run)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Kernel: build, install, boot, wait until usable
# ---------------------------------------------------------------------------
prepare_kernel() {   # <commit> <tag> -> sets KREL
    local commit="$1" tag="$2" kver entry
    log "Preparing kernel for $(git log -1 --format='%h' "$commit") (-$tag)"
    git checkout -q --detach "$commit" || die "git checkout $commit failed"
    cp "$CONFIG_SAVE" .config
    ./scripts/config --set-str LOCALVERSION "-$tag"
    make -s olddefconfig || die "make olddefconfig failed"
    make -s include/config/kernel.release || die "cannot generate kernel.release"
    KREL=$(make -s kernelrelease)
    [[ "$KREL" == *"-$tag"* ]] || die "kernelrelease '$KREL' does not contain -$tag"
    kver=${KREL//-/_}
    info "kernel release $KREL"

    local same=0
    if [ "$REBUILD" -eq 0 ] && rsh "rpm -q kernel-$kver >/dev/null 2>&1 && test -f /boot/config-$KREL"; then
        if diff -q <(grep -E '^(CONFIG_|# CONFIG_)' .config) \
                   <(rsh "grep -E '^(CONFIG_|# CONFIG_)' /boot/config-$KREL") >/dev/null; then
            same=1
        fi
    fi
    if [ "$same" -eq 1 ]; then
        info "$HOST already has $KREL built from the same .config; skipping build/install"
    else
        log "Building RPMs for $KREL"
        local blog="$OUT/build_$tag.log"
        if [ "$HOST" = dmr_710 ] && [ -x ./dmr_compile.sh ]; then
            ./dmr_compile.sh > "$blog" 2>&1 || { tail -30 "$blog"; die "dmr_compile.sh failed (see $blog)"; }
        else
            { rsh 'rm -f ~/kernel-*.rpm' && rm -rf rpmbuild && make binrpm-pkg -j"$JOBS" -s &&
              scp rpmbuild/RPMS/x86_64/kernel-*.rpm "$HOST:~/"; } > "$blog" 2>&1 ||
                { tail -30 "$blog"; die "build/upload failed (see $blog)"; }
        fi
        ls rpmbuild/RPMS/x86_64/kernel-"$kver"-*.rpm >/dev/null 2>&1 || die "no RPM for $KREL in rpmbuild/"
        rsh "ls ~/kernel-$kver-*.rpm >/dev/null" || die "RPM for $KREL not uploaded to $HOST"

        log "Installing $KREL on $HOST"
        rroot <<EOF || die "rpm install failed"
set -e
rpm -ivh --force $RHOME/kernel-$kver-*.rpm $RHOME/kernel-devel-$kver-*.rpm
EOF
    fi

    # Already running exactly this kernel, and it was not reinstalled just now:
    # optionally test on the current boot instead of rebooting.
    if [ "$REUSE_BOOT" -eq 1 ] && [ "$same" -eq 1 ] && [ "$(rsh uname -r)" = "$KREL" ]; then
        log "$HOST is already running $KREL; not rebooting (--no-reboot-if-running)"
        info "uptime: $(rsh uptime)"
        BOOT_MODE="reused existing boot"
        wait_ready "$KREL" noreboot
        return
    fi
    BOOT_MODE="fresh boot"

    entry=$(rroot <<< 'bootctl list' 2>/dev/null | awk '/^[[:space:]]*id:/ {print $2}' | grep -F -- "-$KREL.conf" | head -1)
    [ -n "$entry" ] || die "no systemd-boot entry for $KREL on $HOST"

    log "One-shot boot into $entry and reboot $HOST"
    rroot <<EOF || true
bootctl set-oneshot '$entry' && systemctl reboot
EOF
    wait_ready "$KREL"
}

wait_ready() {   # <krel> [noreboot]
    local krel="$1" r s deadline=$((SECONDS + BOOT_TIMEOUT))
    if [ "${2:-}" = noreboot ]; then
        log "Checking that $HOST is usable on $krel"
    else
        log "Waiting for $HOST to come back on $krel (timeout ${BOOT_TIMEOUT}s)"
        sleep 60
    fi
    until r=$(rsh uname -r 2>/dev/null); do
        (( SECONDS > deadline )) && die "timeout: $HOST did not come back"
        sleep 15
    done
    [ "$r" = "$krel" ] || die "$HOST booted '$r', expected '$krel' (new kernel failed to boot?)"
    until s=$(rsh systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ]; do
        (( SECONDS > deadline )) && die "timeout: $HOST boot did not settle ($s)"
        sleep 10
    done
    rroot <<< 'test -e /sys/kernel/debug/sched/llc_balancing/enabled' || die "$krel has no llc_balancing knob"
    info "READY: $HOST running $krel ($s)"
}

# ---------------------------------------------------------------------------
# Remote test phases
# ---------------------------------------------------------------------------
start_remote() {   # <name> ; script body on stdin -> sets RPID
    local name="$1"
    { echo '#!/bin/bash'; echo 'set -u'; cat; } | rsh "cat > /tmp/$name.sh && chmod +x /tmp/$name.sh" ||
        die "cannot write /tmp/$name.sh on $HOST"
    rroot <<EOF || die "cannot start /tmp/$name.sh on $HOST"
cd /tmp; nohup /tmp/$name.sh > /tmp/$name.log 2>&1 < /dev/null & echo \$! > /tmp/$name.pid
EOF
    sleep 3
    RPID=$(rsh "cat /tmp/$name.pid") || die "no pid for $name"
    info "started /tmp/$name.sh on $HOST (pid $RPID, log /tmp/$name.log)"
}

wait_remote() {   # <name> <pid>: wait until done; check the CPU state on every poll
    local name="$1" pid="$2" out last=""
    local mon="$OUT/$name.cpumon"
    : > "$mon"
    while :; do
        if out=$(rsh "test -d /proc/$pid && echo RUNNING || echo FINISHED; sudo su -c '$RHB/cpu_check.sh'; tail -1 /tmp/$name.log" 2>/dev/null); then
            echo "$out" | grep '^CPU_' >> "$mon"
            echo "$out" | grep -q '^CPU_BAD' && warn "$name: $(echo "$out" | grep '^CPU_BAD')"
            [ "$(echo "$out" | head -1)" = FINISHED ] && break
            local cur; cur=$(echo "$out" | tail -1)
            [ "$cur" != "$last" ] && info "$name: $cur"
            last=$cur
        fi
        sleep "$POLL"
    done
    scp -q "$HOST:/tmp/$name.log" "$OUT/" || warn "could not fetch /tmp/$name.log"
    info "$name finished; cpu checks: $(grep -c CPU_OK "$mon") ok, $(grep -c CPU_BAD "$mon") bad"
    grep -q '^ALL_DONE' "$OUT/$name.log" || { tail -20 "$OUT/$name.log"; die "$name did not complete"; }
    grep -q '^CPU_BAD' "$OUT/$name.log" "$mon" && die "$name: CPU state was wrong during the test"
    return 0
}

calibrate_remote() {
    local name="${RUN}_calibrate"
    log "Calibrating -l on $KREL (single runs, >= ${MIN_SEC}s, close to ${MIN_SEC}s)"
    start_remote "$name" <<EOF
cd $RHB
$SWEEP_EXPORTS
export LLC_ENABLE=1
echo 1 > /sys/kernel/debug/sched/llc_balancing/enabled
./cpu_check.sh apply || exit 1
MIN_SEC=$MIN_SEC ./calibrate_loops.sh \$PWD loops_${RUN}.conf || exit 1
{
  echo "kernel:  \$(uname -r)"
  echo "date:    \$(date '+%F %T')"
  echo "sweep:   modes=[\$MODES_LIST] groups=[\$GROUPS_LIST] fds=[\$FDS_LIST]"
  echo "target:  MIN_SEC=$MIN_SEC AIM=1.03 MAX_OVER=1.10 (single run per step)"
  echo "llc_balancing: \$(cat /sys/kernel/debug/sched/llc_balancing/enabled)"
  echo "cpu:     \$(./cpu_check.sh)"
} > loops_${RUN}.conf.info
./cpu_check.sh || exit 1
echo ALL_DONE
EOF
    wait_remote "$name" "$RPID"
    grep -q CALIBRATE_OK "$OUT/$name.log" || die "calibration incomplete (see $OUT/$name.log)"
    scp -q "$HOST:$RHB/loops_${RUN}.conf" "$LOOPS_RUN" || die "cannot fetch calibrated loops"
    scp -q "$HOST:$RHB/loops_${RUN}.conf.times" "$LOOPS_RUN.times"
    scp -q "$HOST:$RHB/loops_${RUN}.conf.info" "$LOOPS_RUN.info"
    [ "$(grep -c . "$LOOPS_RUN")" -eq "$NCFG" ] || die "calibration produced $(grep -c . "$LOOPS_RUN") of $NCFG configs"
    # Save as the new default -l (keep the previous one).
    if [ -f "$LOOPS_SAVED" ]; then
        for ext in "" .times .info .log; do
            [ -f "$LOOPS_SAVED$ext" ] && cp "$LOOPS_SAVED$ext" "$LOOPS_SAVED$ext.bak_$RUN"
        done
    fi
    cp "$LOOPS_RUN" "$LOOPS_SAVED"
    cp "$LOOPS_RUN.times" "$LOOPS_SAVED.times"
    cp "$LOOPS_RUN.info" "$LOOPS_SAVED.info"
    cp "$OUT/$name.log" "$LOOPS_SAVED.log"
    info "new -l saved to $LOOPS_SAVED (previous kept as *.bak_$RUN):"
    awk '{printf "      %-7s g%-2s f%-2s -l %-10s %8ss\n", $1, $2, $3, $4, $5}' "$LOOPS_RUN.times"
}

run_remote() {   # <result-name>
    local name="$1"
    log "Running hackbench sweep '$name' on $KREL"
    scp -q "$LOOPS_RUN" "$HOST:$RHB/loops_${RUN}.conf" || die "cannot push loops"
    start_remote "$name" <<EOF
cd $RHB
$SWEEP_EXPORTS
echo "sweep: modes=[\$MODES_LIST] groups=[\$GROUPS_LIST] fds=[\$FDS_LIST]"
export NUM_RUNS=$NUM_RUNS LLC_ENABLE=1
./cpu_check.sh apply || exit 1
cp loops_${RUN}.conf loops.conf && cmp loops.conf loops_${RUN}.conf || exit 1
rm -rf results/hackbench/$name
./launch_hackbench.sh run $name
./cpu_check.sh
echo ALL_DONE
EOF
    wait_remote "$name" "$RPID"
    verify_results "$name"
}

verify_results() {   # <result-name>
    local name="$1" d="$RHB/results/hackbench/$1" nsum stats total failed short
    nsum=$(rsh "ls $d/*.summary 2>/dev/null | wc -l")
    [ "$nsum" -eq "$NCFG" ] || die "$name: $nsum summaries, expected $NCFG"
    rsh "cmp -s $d/loops.conf $RHB/loops_${RUN}.conf" || die "$name: loops.conf differs from the frozen -l"
    stats=$(rsh "awk -F, -v m=$MIN_SEC 'NR > 1 { n++; if (\$8 != 0 || \$6 == \"NA\") f++; else if (\$6 < m) s++ }
                 END { print n+0, f+0, s+0 }' $d/raw_results.csv") || die "$name: no raw_results.csv"
    read -r total failed short <<< "$stats"
    info "$name: $total runs, $failed failed, $short shorter than ${MIN_SEC}s"
    [ "$total" -eq $((NCFG * NUM_RUNS)) ] || die "$name: $total runs, expected $((NCFG * NUM_RUNS))"
    [ "$failed" -eq 0 ] || die "$name: $failed hackbench runs failed"
    if [ "$short" -gt 0 ]; then
        warn "$name: $short runs shorter than ${MIN_SEC}s:"
        rsh "awk -F, -v m=$MIN_SEC 'NR > 1 && \$6 < m' $d/raw_results.csv" | sed 's/^/      /'
    fi
}

# ---------------------------------------------------------------------------
# Main flow: strictly sequential
# ---------------------------------------------------------------------------
prepare_kernel "$C1" "$TAG1"; KREL1=$KREL; BOOT1=$BOOT_MODE
[ "$CALIBRATE" -eq 1 ] && calibrate_remote
run_remote "$R1"

prepare_kernel "$C2" "$TAG2"; KREL2=$KREL; BOOT2=$BOOT_MODE
run_remote "$R2"

# Back to the user's checkout as soon as no more builds are needed.
cleanup

# ---------------------------------------------------------------------------
# Compare, collect, analyse
# ---------------------------------------------------------------------------
log "Comparing $R1 (BASE) vs $R2 (TEST)"
rsh "cd $RHB && ./launch_hackbench.sh compare $R1 $R2" > "$OUT/compare.txt" || die "compare failed"
cat "$OUT/compare.txt"

log "Copying results to $OUT"
scp -qr "$HOST:$RHB/results/hackbench/$R1" "$HOST:$RHB/results/hackbench/$R2" "$OUT/" ||
    warn "could not copy all result dirs"

{
    echo "hackbench A/B report ($RUN, host $HOST)"
    echo "BASE commit1: $S1   kernel $KREL1 ($BOOT1)"
    echo "TEST commit2: $S2   kernel $KREL2 ($BOOT2)"
    echo "sweep: $SWEEP, $NUM_RUNS runs/config, each run >= ${MIN_SEC}s target"
    echo "-l: $([ "$CALIBRATE" -eq 1 ] && echo "calibrated on $KREL1 in this run" || echo "saved $(basename "$LOOPS_SAVED") ($(sed -n 's/^kernel: *//p' "$LOOPS_SAVED.info" 2>/dev/null))")"
    echo
    echo "Significance: |DIFF%| > 2 x combined stderr% (sqrt(se_base^2 + se_test^2))"
    awk -F'|' '/^(process|threads)/ {
        split($2, a, "/"); split($3, b, "/")
        sb = a[2]; st = b[2]; d = $4
        gsub(/[% ]/, "", sb); gsub(/[% ]/, "", st); gsub(/[% ]/, "", d)
        c = sqrt(sb * sb + st * st); k = (c > 0) ? d / c : 0
        cls = (k > 2) ? "IMPROVED (significant)" : (k < -2) ? "REGRESSED (significant)" : "noise"
        printf "  %-16s diff=%8.2f%%  comb_stderr=%6.2f%%  %s\n", $1, d, c, cls
        n++; if (k > 2) up++; if (k < -2) dn++
        lb += log(a[1]); lt += log(b[1])
    } END {
        printf "\n  configs=%d  significant improvements=%d  significant regressions=%d\n", n, up, dn
        printf "  geomean time TEST/BASE = %.4f (< 1 means TEST is faster)\n", exp((lt - lb) / n)
    }' "$OUT/compare.txt"
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo
        echo "Warnings:"
        printf '  - %s\n' "${WARNINGS[@]}"
    fi
    echo
    echo "$HOST is left on $KREL2; its next reboot returns to the default boot entry (one-shot)."
} > "$OUT/report.txt"

log "Report"
cat "$OUT/report.txt"
log "Done. All files in $OUT"
exit 0
