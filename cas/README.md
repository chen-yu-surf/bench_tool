# Cache-Aware Scheduler Test Cases

### Kernel Interface
The feature is controlled via debugfs:
```
/sys/kernel/debug/sched/llc_balancing/
├── enabled                 # 0=off, 1=on
├── aggr_tolerance          # 0-100: how aggressively tasks are aggregated
├── epoch_period            # epoch duration in ms
├── epoch_affinity_timeout  # timeout before affinity is re-evaluated
├── overaggr_pct            # over-aggregation percentage threshold
└── imb_pct                 # imbalance percentage threshold
```

## Build
```bash
cd scheduler/
make
```
This compiles `test_llc_agg` — a multi-threaded workload (by default 70% of the
cores of an LLC, rebuilt by the test script; threads share a
4MB array that fits in LLC) used by all functional tests.

### Run individual test cases
```bash
./cache_aware_function_tests.sh -t test_llc_agg
./cache_aware_function_tests.sh -t test_llc_reselect
./cache_aware_function_tests.sh -t test_two_proc
```

### Environment Overrides
```bash
MONITOR_SECS=120 ./cache_aware_function_tests.sh -t test_llc_agg   # longer observation window
SAMPLE_INTERVAL=2 ./cache_aware_function_tests.sh -t test_two_proc  # slower polling
```

## Test Case Summary
| ID | Test | Description |
|----|------|-------------|
| F1 | test_llc_agg | Workers converge onto a single LLC; stay spread when feature is disabled |
| F2 | test_llc_reselect | Process re-converges onto a new LLC when preferred one is saturated |
| F3 | test_two_proc | Two processes settle onto different LLCs |

## Generic and prctl tests
`cache_aware_prctl_tests.sh` covers the generic aggregation under the three
system-wide modes of `llc_balancing/enabled` (`always`/`advise`/`never`), and
the `PR_SCHED_CACHE` prctl(). It needs root and at least two LLCs, and builds
two helpers:

- `cas_worker [nthreads]` - the test_llc_agg workload with a runtime thread count
- `sched_cache_ctl` - command line wrapper around prctl(PR_SCHED_CACHE), e.g.
  `sched_cache_ctl share <dst-pid> <src-pid> tgid`

```bash
./cache_aware_prctl_tests.sh                 # all tests
./cache_aware_prctl_tests.sh -t generic      # or: -t prctl, -t test_share_procs
./cache_aware_prctl_tests.sh -l              # list tests
HOLD_SECS=60 ./cache_aware_prctl_tests.sh -t test_never_spread
```

| ID | Test | Description |
|----|------|-------------|
| G1 | test_always_agg | always: threads of a process converge onto one LLC |
| G2 | test_never_spread | never: threads stay spread |
| G3 | test_advise_default | advise: a process that did not opt in stays spread (group flag 0) |
| G4 | test_two_proc | always: two processes settle onto different LLCs |
| G5 | test_procs_default | always: single-threaded processes are not aggregated together |
| P1 | test_advise_enable | advise: ENABLE aggregates, DISABLE lets the threads spread again |
| P2 | test_always_disable | always: DISABLE is ignored, threads still converge |
| P3 | test_never_enable | never: ENABLE is ignored, threads stay spread |
| P4 | test_share_procs | CREATE + SHARE_FROM (tgid) aggregates separate processes |
| P5 | test_split_threads | threads split into two groups (pid scope) converge onto two LLCs |
