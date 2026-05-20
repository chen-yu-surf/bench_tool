---
description: Build kernels at commit1 and commit2 as RPMs via dmr_compile.sh (same default .config, different LOCALVERSION), install and boot each on dmr_710, run the hackbench sweep on each (test_all.sh sweep, every run >= 30s, identical frozen -l calibrated to ~30s, turbo off, C-states > C1 off), then compare with launch_hackbench.sh compare.
argument-hint: <commit1> <commit2> [calibrate]
---

# hackbench comparison on dmr_710: commit1 vs commit2

User request / arguments: `$ARGUMENTS`

Usage: `/hackbench_dmr_710_compare <commit1> <commit2> [calibrate]`

- **By default, no calibration:** the test uses the saved per-config `-l` from
  `.claude/hackbench_dmr_710_compare/loops_30s.conf`.
- Calibrate only when the user asks for it (the `calibrate` argument, or words like "recalibrate"
  or "calibrate -l" in the request). In that case, run `calibrate_loops.sh` on BASE first, then
  save the new `-l` values as the default (see "Saved -l").

- commit1 is the BASE kernel and commit2 is the TEST kernel.
- Both kernels are built from the same default `.config` (the one in the tree). Only
  LOCALVERSION differs, so both RPMs can be installed side by side.
- The hackbench perf sweep runs on each kernel. Then
  `launch_hackbench.sh compare <commit1-result> <commit2-result>` produces the comparison.

## Standalone script (no LLM agent needed)

`bench_tool/cas/performance/hackbench/hackbench_dmr.sh` does the same flow as this skill, unattended:
```
bench_tool/cas/performance/hackbench/hackbench_dmr.sh [--calibrate] [--check] <commit1> <commit2>
```
It uses `cpu_check.sh`, `calibrate_loops.sh` and `loops_30s.conf` from its own directory. Results
go to `results_hackbench/<run>/` (`compare.txt`, `report.txt`, logs, and the raw result dirs).
`--check` runs only the pre-flight checks. `--no-reboot-if-running` (`-b`) skips the reboot
when HOST already runs that exact kernel and it wasn't just reinstalled. See `--help`. When the user just wants the comparison
and doesn't need step-by-step reporting, you may run the script (in the background) instead of
these steps.

## Overall flow: strictly sequential, driven from THIS machine

This skill runs on the local build machine. dmr_710 is only the test target. Each phase must
finish before the next one starts. The local machine waits at every reboot and every test run:

```
commit1: build (dmr_compile.sh) -> install RPM on dmr_710 -> reboot dmr_710 into it
         -> WAIT until dmr_710 is up, running the new kernel, and usable
         -> launch hackbench perf on dmr_710 -> WAIT until the test has finished
commit2: build (dmr_compile.sh) -> install RPM on dmr_710 -> reboot dmr_710 into it
         -> WAIT until dmr_710 is up, running the new kernel, and usable
         -> launch hackbench perf on dmr_710 -> WAIT until the test has finished
compare: launch_hackbench.sh compare <commit1-result> <commit2-result>
```

- Do not build commit2 before the commit1 test has finished. `dmr_compile.sh` deletes
  `~/*.rpm` on dmr_710 and the local tree gets checked out to commit2.
- Do not launch a test before the boot wait has confirmed the expected kernel is running.
- Do the waiting with local Bash wait loops started with `run_in_background: true`. The harness
  notifies you when the loop exits. Don't use foreground `sleep`, and don't poll by hand.
- Long tests run detached on dmr_710 (`nohup`, PID file), so an SSH drop or a local tool timeout
  does not kill them. The local loop only watches them.

## Facts about the environment

- Kernel source tree (local): `/home/chenyu/src/linux_prctl` (run everything from here).
- `./dmr_compile.sh` (untracked, in the tree root) does:
  `ssh dmr_710 rm -rf *.rpm; rm -rf rpmbuild/; make binrpm-pkg -j192 -s; scp rpmbuild/RPMS/x86_64/kernel-*.rpm dmr_710:~/`.
  It builds from the **current checkout + existing `.config`**. It does NOT install or reboot.
  This skill does those steps.
- `ssh dmr_710` works without a password. Root on dmr_710: `sudo su` (passwordless).
  Non-interactive form used below: `ssh dmr_710 'sudo su -c "<cmd>"'`.
- dmr_710 runs CentOS Stream 10 with systemd-boot (`bootctl`). Boot entry ids look like
  `<machine-id>-<kernelrelease>.conf`.
- Bench tool on dmr_710 lives at `~/bench_tool/cas` (hackbench binary already built
  in `~/bench_tool/cas/performance/hackbench/rt-tests`). The local copy is
  `bench_tool/cas`. The local copy is the source of truth.
- `test_all.sh perf` must run as root and needs `/sys/kernel/debug/sched/llc_balancing/enabled`.
  It always recalibrates `loops.conf` (`calibrate` then `run`). `compare` compares raw times, so
  **both kernels must use the same loops.conf**. Otherwise each kernel just calibrates to
  ~TARGET_SEC and the comparison is meaningless. This skill therefore drives
  `launch_hackbench.sh` directly with test_all.sh's sweep env (see "Test conditions").
- dmr_710 CPU: 160 CPUs, intel_pstate active, turbo locked off by firmware (writing
  `no_turbo=0` returns EPERM), cpufreq range 600-1300 MHz (base = max = 1.3 GHz), intel_idle states
  `POLL C1_LPI C2_LPI C3_LPI`.

## Step 0: Resolve the two commits

- Two commit arguments are required: `<commit1> <commit2>`, optionally followed by `calibrate`.
  If anything else is given, stop and show the usage line. Set `CALIBRATE=1` only when calibration
  was asked for, otherwise `CALIBRATE=0`, and store it in the env file.
- Check each with `git rev-parse --verify <c>^{commit}`. If either fails, stop and ask.
- Get each commit's subject for the report: `git log -1 --format='%h ("%s")' <c>`. Show both to
  the user before starting.
- Tags (used as LOCALVERSION suffixes and as hackbench result names):
  `TAG1=c1_$(git rev-parse --short=12 <commit1>)` and `TAG2=c2_$(git rev-parse --short=12 <commit2>)`.
- `RUN=hb_$(date +%Y%m%d_%H%M)`. Result names are `R1=${RUN}_${TAG1}` and `R2=${RUN}_${TAG2}`.
- Shell state doesn't persist between Bash calls. Write the variables to `/tmp/${RUN}.env`
  (RUN, TAG1, TAG2, R1, R2, ORIG, and later KREL1/KREL2) and `source` that file in every later
  command.

## Step 1: Pre-flight checks (local and remote)

1. `git status --porcelain -uno` must be empty (no modified tracked files). If not, stop and
   ask the user; never stash or discard their changes yourself.
2. Record the current position: `ORIG=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)`.
3. The default `.config` must exist. Save a pristine copy: `cp .config /tmp/${RUN}.config`.
   Both kernels are built from this copy.
4. `ssh dmr_710 uname -r` works. Record the currently running kernel (it is the fallback).
   Make sure no earlier hackbench/test_all.sh is still running there:
   `ssh dmr_710 pgrep -af 'test_all.sh|launch_hackbench.sh|hackbench'`. If one is, stop and ask.
5. Sync the bench scripts (local -> remote, never delete remote data):
   ```
   rsync -rc --exclude rt-tests --exclude results --exclude loops.conf \
         bench_tool/cas/ dmr_710:bench_tool/cas/
   ```
   If `~/bench_tool/cas/performance/hackbench/rt-tests/hackbench` is missing on the remote,
   run `prepare_hackbench.sh` there (as root) first.

## Step 2: Build, install, reboot, and wait until usable (commit1 now, commit2 in Step 4)

For commit `C` with tag `TAG` (store the resulting `KREL` as KREL1 / KREL2 in the env file):

1. `git checkout --detach <C>`
2. Restore the default config and set a unique LOCALVERSION:
   ```
   cp /tmp/${RUN}.config .config
   ./scripts/config --set-str LOCALVERSION "-${TAG}"
   make olddefconfig
   make -s include/config/kernel.release   # refresh: kernelrelease only reads this (stale) file
   KREL=$(make -s kernelrelease)        # e.g. 7.3.0-c1_d89e1d186ec9+
   ```
   `KREL` must contain `-${TAG}`. If it doesn't, stop.
   If dmr_710 already has exactly this kernel installed (`ssh dmr_710 rpm -q kernel-${KREL//-/_}`
   succeeds, and the tag contains this commit's sha, from an earlier run of this skill with the
   same `.config`), you may skip steps 3-4 and go straight to the reboot (step 5). Say so in the report.
3. **Build and upload.** Run `./dmr_compile.sh > /tmp/${RUN}_build_${TAG}.log 2>&1` with
   `run_in_background: true` and wait for the completion notification. When it is done, check
   the exit status and the log tail. Check that `rpmbuild/RPMS/x86_64/kernel-*${TAG}*.rpm` exist
   locally and that `ssh dmr_710 ls ~/kernel-*.rpm` lists them. On a build error, stop.
4. **Install** on dmr_710 (`KVER_RPM=${KREL//-/_}`):
   ```
   ssh dmr_710 "sudo su -c 'rpm -ivh --force ~chenyu/kernel-${KVER_RPM}-*.rpm ~chenyu/kernel-devel-${KVER_RPM}-*.rpm'"
   ```
   (If the glob doesn't match, run `ssh dmr_710 ls ~/*.rpm` and use the actual names.) Then
   check that the boot entry exists:
   `ssh dmr_710 "sudo su -c 'bootctl list'" | grep -F -- "-${KREL}.conf"`. If it's missing, stop.
5. **Reboot into the new kernel** (one-shot, so a broken kernel falls back to the default):
   ```
   ssh dmr_710 "sudo su -c 'bootctl set-oneshot <entry-id> && systemctl reboot'" || true
   ```
   (The ssh may exit non-zero because the connection drops. That is expected.)
6. **Wait until dmr_710 is back and usable.** Run this locally with `run_in_background: true`.
   Wait for its exit notification before doing anything else:
   ```
   source /tmp/<RUN>.env; KREL=<KREL of this commit>
   sleep 60                                   # let it actually go down first
   deadline=$((SECONDS + 1800))
   # (a) wait for sshd
   until r=$(ssh -o ConnectTimeout=5 -o BatchMode=yes dmr_710 uname -r 2>/dev/null); do
       (( SECONDS > deadline )) && { echo "TIMEOUT waiting for dmr_710"; exit 1; }
       sleep 15
   done
   echo "dmr_710 is up, running: $r"
   # (b) must be the newly built kernel
   [[ "$r" == "$KREL" ]] || { echo "WRONG KERNEL: got $r, expected $KREL"; exit 2; }
   # (c) wait for boot to settle (running or degraded both count as usable)
   until s=$(ssh -o ConnectTimeout=5 dmr_710 systemctl is-system-running 2>/dev/null || true);
         [[ "$s" == running || "$s" == degraded ]]; do
       (( SECONDS > deadline )) && { echo "TIMEOUT waiting for boot to settle ($s)"; exit 1; }
       sleep 10
   done
   # (d) the CAS debugfs knob must exist
   ssh dmr_710 "sudo su -c 'cat /sys/kernel/debug/sched/llc_balancing/enabled'" \
       || { echo "llc_balancing knob missing"; exit 3; }
   echo "READY: dmr_710 running $KREL (state: $s)"
   ```
   Continue only when it prints `READY`. Exit 1 (timeout) means dmr_710 never came back. Exit 2
   means it fell back to another kernel, so the new kernel probably failed to boot. Exit 3 means
   the kernel lacks CAS. In all three cases, stop and report to the user. Do not retry blindly,
   and do not run the test on the wrong kernel.

## Test conditions (identical for both kernels, enforced by the skill)

- **Sweep:** taken from the `export MODES_LIST/GROUPS_LIST/FDS_LIST=` lines in
  `bench_tool/cas/test_all.sh` (the single source of truth; the run scripts `eval` those lines on
  dmr_710). Currently that is modes `threads`, groups `1 2 4`, fds `1 2 4 20`:
  1 mode x 3 groups x 4 fds = **12 configs**. `NCFG` = #modes x #groups x #fds, so recompute it
  whenever test_all.sh changes. Each sub-test is
  `hackbench -g G --MODE --pipe -l LOOPS -s 100 -f FD`, `NUM_RUNS=3` runs per config, with
  `drop_caches` and a 1s sleep between runs, and `llc_balancing/enabled=1`.
- **`-l` per config (each config has its own dedicated `-l`):** sized so that a single run lasts
  >= 30s, as close to 30s as possible. Every run of the same config (all NUM_RUNS runs, on both
  kernels) uses that exact `-l`. After each kernel's run, every `*_runN.txt` is checked to be >= 30s.
  A run on a kernel that is faster than the calibration kernel can dip slightly below 30s. Report
  any such run explicitly with its time. Never re-calibrate per kernel.

### Saved -l (default: reuse, do not calibrate)

- Local, authoritative copy: `.claude/hackbench_dmr_710_compare/loops_30s.conf`, one line per
  config in the form `mode grp fd loops` (the format `launch_hackbench.sh run` reads). Next to it:
  - `loops_30s.conf.times`: the calibration run time of each config.
  - `loops_30s.conf.info`: the kernel, date, sweep, target, and CPU state of the calibration.
- Before each test, push it to dmr_710 as `$HB/loops_${RUN}.conf`. Check that it has exactly one line
  for every config of the current sweep (from test_all.sh) and no other lines. If the sweep has
  configs that aren't in the file, stop and tell the user. Suggest running with `calibrate`.
  Don't silently calibrate. (If the file has extra configs, build `loops_${RUN}.conf` from the
  matching lines only.)
- **Calibration** (only when `CALIBRATE=1`) uses `calibrate_loops.sh` on the BASE kernel, with
  **single runs only** (no repetitions):
  1. **Probe:** grow `-l` from 10000 until one run takes >= 3s.
  2. **Scale:** set `-l` from that probe to aim at 30.9s (30 x 1.03), and run once.
  3. **Accept or retry:** accept if 30s <= t <= 33s. Otherwise rescale from the last run and try
     again, up to 8 tries. If no try landed in the window, keep the shortest try that was >= 30s.
     If none reached 30s, the config fails.

  The two-stage `launch_hackbench.sh calibrate` is NOT used: it isn't linear in `-l` on this
  machine (a 3s target once produced runs from 1.3s to 56s). After `CALIBRATE_OK`, copy
  `loops_${RUN}.conf{,.times,.info}` back to the local `loops_30s.conf{,.times,.info}`. These become
  the new default. Show the user the per-config `-l` and the calibration time.

- **CPU state:** turbo disabled (`intel_pstate/no_turbo=1`), cpuidle states deeper than C1 disabled
  (state index > 1; on dmr_710 that is `C2_LPI` and `C3_LPI`, with `POLL`/`C1_LPI` enabled), governor
  `performance`. **cpufreq min/max are not pinned. Do not set a fixed frequency.** On dmr_710 turbo
  is firmware-locked off and the max is the 1.3 GHz base. `cpu_check.sh apply` sets this before the
  test, and the wait loop runs `cpu_check.sh` on every poll during the test. Any `CPU_BAD` is a
  failure for that run.
- **Same code path on both kernels:** BASE and TEST both run `launch_hackbench.sh run` with the
  same frozen loops.conf and the same env. Only when `CALIBRATE=1` does BASE also run
  `calibrate_loops.sh` first. `test_all.sh perf` is not used for the measured runs, because it always recalibrates.

Helper scripts (in this repo, copied to dmr_710 `/tmp/` before each test):
- `.claude/hackbench_dmr_710_compare/cpu_check.sh [apply]`: prints `CPU_OK ...` or `CPU_BAD ...`
  (with turbo, governor, idle state on/off, scaling range, and MHz min/avg/max) and exits 0/1.
- `.claude/hackbench_dmr_710_compare/calibrate_loops.sh <hb-dir> <out.conf>`: reads the sweep from
  `MODES_LIST/GROUPS_LIST/FDS_LIST`, writes `<out.conf>` and `<out.conf>.times`, and prints
  `CALIBRATE_OK` or `CALIBRATE_INCOMPLETE`.

Common remote paths: `HB=~chenyu/bench_tool/cas/performance/hackbench`, and results go to
`$HB/results/hackbench/<name>/`.

## Step 3: hackbench on the commit1 (BASE) kernel: [calibrate `-l`], run, and wait

1. **Prepare the CPU and helpers:**
   ```
   scp -q .claude/hackbench_dmr_710_compare/*.sh dmr_710:/tmp/
   ssh dmr_710 "sudo su -c '/tmp/cpu_check.sh apply'"      # must print CPU_OK, else stop
   ```
2. **Get the `-l` values:**
   - `CALIBRATE=0` (default): push the saved loops and check them against the sweep:
     ```
     scp -q .claude/hackbench_dmr_710_compare/loops_30s.conf dmr_710:bench_tool/cas/performance/hackbench/loops_${RUN}.conf
     ```
     The check (every sweep config is present exactly once) is described under "Saved -l".
   - `CALIBRATE=1`: the BASE script below calibrates into `loops_${RUN}.conf` itself.

   **Launch** detached, in one script so it survives SSH drops. With `CALIBRATE=0`, leave out
   the two `calibrate` lines:
   ```
   ssh dmr_710 "cat > /tmp/${R1}.sh" <<EOS
   #!/bin/bash
   set -u
   cd ~chenyu/bench_tool/cas/performance/hackbench
   eval "\$(grep -E '^export (MODES|GROUPS|FDS)_LIST=' ~chenyu/bench_tool/cas/test_all.sh)"
   echo "sweep: modes=[\$MODES_LIST] groups=[\$GROUPS_LIST] fds=[\$FDS_LIST]"
   export NUM_RUNS=3 LLC_ENABLE=1
   /tmp/cpu_check.sh apply
   echo "### calibrate -l (single runs, >= 30s, close to 30s)"              # CALIBRATE=1 only
   MIN_SEC=30 /tmp/calibrate_loops.sh \$PWD loops_${RUN}.conf || exit 1    # CALIBRATE=1 only
   test -s loops_${RUN}.conf || exit 1
   cp loops_${RUN}.conf loops.conf
   /tmp/cpu_check.sh || exit 1
   echo "### run ${R1}"; rm -rf results/hackbench/${R1}
   ./launch_hackbench.sh run ${R1}
   /tmp/cpu_check.sh
   echo "ALL_DONE"
   EOS
   ssh dmr_710 "chmod +x /tmp/${R1}.sh; sudo su -c 'cd /tmp; nohup /tmp/${R1}.sh > /tmp/${R1}.log 2>&1 < /dev/null & echo \$! > /tmp/${R1}.pid'"
   ssh dmr_710 "cat /tmp/${R1}.pid; sleep 5; tail -5 /tmp/${R1}.log"    # confirm it started
   ```
   Use `;` (not `&&`) before the backgrounded command. With `cd ... && cmd > log &`, bash forks a
   subshell for the whole `&&` list, and that subshell keeps ssh's stdout open. The launch ssh then
   hangs until the test ends, and `$!` is that subshell's PID rather than the test's.
3. **Wait for it to finish, checking the CPU state during the test.** Run this locally with
   `run_in_background: true` and wait for its exit notification. BASE takes about NCFG x 3 x 31s (about
   20 min for 12 configs), plus about NCFG x ~3 x 31s more (about 15-20 min) when `CALIBRATE=1`. Tell the user it is running, then wait.
   ```
   R=<R1>; pid=$(ssh dmr_710 cat /tmp/$R.pid); mon=/tmp/$R.cpumon
   while :; do
       if out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes dmr_710 \
                "test -d /proc/$pid && echo RUNNING || echo FINISHED; sudo su -c /tmp/cpu_check.sh" 2>/dev/null); then
           echo "$out" | grep CPU_ >> $mon
           [[ "$(echo "$out" | head -1)" == FINISHED ]] && break
       fi
       sleep 120
   done
   echo "cpu checks: $(grep -c CPU_OK $mon) ok, $(grep -c CPU_BAD $mon) bad"; grep CPU_BAD $mon
   ssh dmr_710 "tail -8 /tmp/$R.log"
   ```
4. **Check the result.** All of these must hold, otherwise stop and report:
   - The log contains `Results saved to:` and `ALL_DONE` (and `CALIBRATE_OK` when `CALIBRATE=1`), and no `CPU_BAD`
     appears (in the log or in `$mon`).
   - There are NCFG `.summary` files (12 currently), each with `n=3`, and the log's `sweep:` line
     matches test_all.sh.
   - Every single run succeeded and lasted at least 30s (from `raw_results.csv`, one line per run):
     ```
     ssh dmr_710 "awk -F, 'NR > 1 { n++; if (\$8 != 0 || \$6 == "NA") f++; else if (\$6 < 30) { print; s++ } }
       END { print n \" runs, \" f+0 \" failed, \" s+0 \" shorter than 30s\" }' \
       ~/bench_tool/cas/performance/hackbench/results/hackbench/${R1}/raw_results.csv"
     ```
   - `loops.conf` in the result dir equals `loops_${RUN}.conf`, so the run used the frozen `-l`.
   Keep `loops_${RUN}.conf` (the frozen loops) and `/tmp/${R1}.log`. When `CALIBRATE=1`, save the new
   `-l` locally as described under "Saved -l" and show it to the user.
5. Tell the user that commit1 is done, then move to Step 4.

## Step 4: Build, install, reboot, and wait for the commit2 kernel

Only after Step 3 is complete: repeat Step 2 with `<commit2>`, `TAG2`, and `KREL2`, including
the full wait-until-usable loop and its `READY` check.

## Step 5: hackbench on the commit2 (TEST) kernel: same frozen loops, run, and wait

1. Same as Step 3.1 (copy the helpers, `cpu_check.sh apply` must print `CPU_OK`).
2. Launch detached with the **same env and the frozen loops** (no calibration):
   ```
   ssh dmr_710 "cat > /tmp/${R2}.sh" <<EOS
   #!/bin/bash
   set -u
   cd ~chenyu/bench_tool/cas/performance/hackbench
   eval "\$(grep -E '^export (MODES|GROUPS|FDS)_LIST=' ~chenyu/bench_tool/cas/test_all.sh)"
   echo "sweep: modes=[\$MODES_LIST] groups=[\$GROUPS_LIST] fds=[\$FDS_LIST]"
   export NUM_RUNS=3 LLC_ENABLE=1
   /tmp/cpu_check.sh apply
   cp loops_${RUN}.conf loops.conf && cmp loops.conf loops_${RUN}.conf || exit 1
   /tmp/cpu_check.sh || exit 1
   echo "### run ${R2}"; rm -rf results/hackbench/${R2}
   ./launch_hackbench.sh run ${R2}
   /tmp/cpu_check.sh
   echo "ALL_DONE"
   EOS
   ssh dmr_710 "chmod +x /tmp/${R2}.sh; sudo su -c 'cd /tmp; nohup /tmp/${R2}.sh > /tmp/${R2}.log 2>&1 < /dev/null & echo \$! > /tmp/${R2}.pid'"
   ```
   Check that the exported sweep values match `bench_tool/cas/test_all.sh` and Step 3's script.
   If the user overrode NUM_RUNS, it must be the same on both kernels.
3. **Wait** with the same background loop as Step 3.3 (`R=<R2>`). It takes about NCFG x 3 x ~31s (about 20 min for 12 configs).
4. **Check** as in Step 3.4 (except there is no `CALIBRATE_OK` here): `ALL_DONE`, no `CPU_BAD`, the same
   `sweep:` line as BASE, NCFG summaries with `n=3`, every run >= 30s. If any TEST run is under 30s (TEST faster than the margin
   allowed), report those configs explicitly. Don't silently accept them.

### Result files (written by `launch_hackbench.sh run` into `$HB/results/hackbench/<name>/`)

| file | content |
|---|---|
| `<mode>_g<G>_f<FD>_run<N>.txt` | raw hackbench output of run N (task count, messages, `Time:`) |
| `<mode>_g<G>_f<FD>.summary` | `mean= stderr= pct_stderr= n= min= max= loops= times=t1,t2,t3` (`compare` reads fields 2 and 4) |
| `raw_results.csv` | one line per run: `mode,groups,fds,loops,run,time_s,wall_s,rc,start` |
| `loops.conf` | the exact `-l` of every config used for this result set |
| `env.txt` | name, start/end, num_runs, command, host, kernel, cmdline, nproc, llc_balancing, governor, no_turbo, scaling range, cpuidle on/off |

## Step 6: Compare

```
ssh dmr_710 "cd ~/bench_tool/cas/performance/hackbench && \
  ./launch_hackbench.sh compare ${R1} ${R2}" | tee /tmp/${RUN}_compare.txt
```
(`compare` does not need root. If the results dir is root-owned and unreadable, use `sudo su -c`.)

Copy the results back locally:
`mkdir -p results_hackbench/${RUN} && scp -r dmr_710:bench_tool/cas/performance/hackbench/results/hackbench/{${R1},${R2}} dmr_710:/tmp/${RUN}_*.log results_hackbench/${RUN}/ && cp /tmp/${RUN}_compare.txt results_hackbench/${RUN}/`
(if root-owned, `sudo su -c 'chmod -R a+r ...'` first).

## Step 7: Restore local tree and report

1. `git checkout "$ORIG"` and `cp /tmp/${RUN}.config .config` (restore the default config and
   its original LOCALVERSION).
2. Leave dmr_710 on whatever it booted. The one-shot entry means its next reboot returns to
   the default kernel. Tell the user that.
3. Report:
   - commit1 / commit2 with subjects, and the `uname -r` each was tested on.
   - The full `compare` table verbatim (BASE = commit1, TEST = commit2; positive DIFF% means
     commit2 is faster). Then summarize: the biggest improvements and regressions, and which
     differences are within noise (|DIFF%| smaller than about the stderr% of the two sides).
     Do not call noise-level changes wins or losses.
   - Result names and locations (remote and local).

## Rules

- Strictly sequential: build -> install -> reboot -> wait until usable -> test -> wait for the
  test to finish, for commit1 and then commit2. Never overlap phases.
- Never modify, stash, or reset the user's tracked changes. Never push.
- Never `bootctl set-default` or remove kernels on dmr_710 without asking.
- If any step fails (build error, boot timeout, boot into the wrong kernel, missing llc_balancing
  knob, hackbench error, short summary count, CPU_BAD, CALIBRATE_INCOMPLETE), stop. Report the exact error output and do not
  continue. If it fails before Step 7, still restore the local checkout and `.config`.
- Keep the user informed at each milestone (built, booted, commit1 test started/done, commit2
  test started/done) because the whole flow takes hours.
