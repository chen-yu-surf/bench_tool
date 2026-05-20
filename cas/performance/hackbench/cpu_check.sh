#!/bin/bash
#
# cpu_check.sh [apply]
#
# Run as root on the test machine. Check (and with "apply", first set) the CPU
# state required for the hackbench runs, on every online CPU:
#   - turbo disabled              (intel_pstate/no_turbo == 1, or cpufreq/boost == 0)
#   - cpufreq governor            == performance
#   - cpuidle states deeper than C1 disabled (state index > 1, i.e. beyond POLL/C1)
#   - cpuidle POLL and C1 left enabled
# cpufreq min/max are deliberately NOT touched.
#
# Prints one summary line starting with CPU_OK or CPU_BAD and exits 0 / 1.
set -u

apply() {
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null
    done
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null
    fi
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/; do
        idx=$(basename "$s" | sed 's/state//')
        if [ "$idx" -gt 1 ]; then
            echo 1 > "${s}disable" 2>/dev/null
        else
            echo 0 > "${s}disable" 2>/dev/null
        fi
    done
}

[ "${1:-}" = apply ] && apply

bad=()

if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    turbo="no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
    [ "$turbo" = "no_turbo=1" ] || bad+=("turbo enabled ($turbo)")
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    turbo="boost=$(cat /sys/devices/system/cpu/cpufreq/boost)"
    [ "$turbo" = "boost=0" ] || bad+=("turbo enabled ($turbo)")
else
    turbo="unknown"
    bad+=("no turbo control found")
fi

ncpu=0 ngov=0 nidle=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -f "$c/online" ] && [ "$(cat "$c/online")" = 0 ] && continue
    ncpu=$((ncpu + 1))
    gov=$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)
    [ "$gov" = performance ] || ngov=$((ngov + 1))
    for s in "$c"/cpuidle/state*; do
        idx=${s##*state}
        d=$(cat "$s/disable")
        if [ "$idx" -gt 1 ] && [ "$d" != 1 ]; then
            nidle=$((nidle + 1))
        elif [ "$idx" -le 1 ] && [ "$d" != 0 ]; then
            nidle=$((nidle + 1))
        fi
    done
done
[ "$ngov" -eq 0 ] || bad+=("$ngov cpus not on performance governor")
[ "$nidle" -eq 0 ] || bad+=("$nidle cpuidle states with wrong disable setting")

c0=/sys/devices/system/cpu/cpu0
states=$(for s in "$c0"/cpuidle/state*; do printf '%s:%s ' "$(cat "$s/name")" \
         "$([ "$(cat "$s/disable")" = 1 ] && echo off || echo on)"; done)
freq=$(awk '/cpu MHz/ {n++; s += $4; if (min == "" || $4 < min) min = $4; if ($4 > max) max = $4}
            END {printf "MHz min/avg/max=%.0f/%.0f/%.0f", min, s / n, max}' /proc/cpuinfo)
info="$(date '+%F %T') cpus=$ncpu $turbo gov=$(cat "$c0/cpufreq/scaling_governor") idle=[${states% }] \
scaling=$(( $(cat "$c0/cpufreq/scaling_min_freq") / 1000 ))-$(( $(cat "$c0/cpufreq/scaling_max_freq") / 1000 ))MHz $freq"

if [ ${#bad[@]} -eq 0 ]; then
    echo "CPU_OK $info"
    exit 0
fi
echo "CPU_BAD $info :: $(IFS=';'; echo "${bad[*]}")"
exit 1
