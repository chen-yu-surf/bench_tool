#!/usr/bin/env bash
#
# compile_and_run.sh <target-hostname>
#
# Build the kernel in the CURRENT source tree (using the existing .config) into
# binary RPM packages, upload them to <target-hostname>, install the kernel and
# kernel-devel packages, set a one-shot boot entry for the freshly built kernel,
# reboot the target into it, and wait until it comes back running the new kernel.
# When the target is back on the new kernel a notice is printed.
#
# The ONLY required argument is the target machine's SSH hostname, e.g. dmr_710.
# Everything else (kernel release, boot entry, RPM names) is derived automatically
# so the script is generic and not tied to any particular kernel version.
#
# Assumptions:
#   * The current directory / script directory is a configured kernel source tree.
#   * Passwordless SSH to <target-hostname> is set up.
#   * Passwordless sudo is available on <target-hostname>.
#   * The target uses systemd-boot (bootctl) for boot entry selection.
#
# Optional environment variables:
#   JOBS          parallel build jobs            (default: nproc)
#   BOOT_TIMEOUT  seconds to wait for reboot      (default: 1800)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <target-hostname>    (e.g. $0 dmr_710)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC_DIR"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-1800}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Determine the kernel release string for this build/config.
# ---------------------------------------------------------------------------
KREL="$(make -s kernelrelease)"
[[ -n "$KREL" ]] || die "could not determine kernel release (make kernelrelease)"
KVER_RPM="${KREL//-/_}"            # RPM version field replaces '-' with '_'
log "Target host : ${TARGET}"
log "Kernel rel. : ${KREL}"

# ---------------------------------------------------------------------------
# 2. Build the binary RPM packages.
# ---------------------------------------------------------------------------
log "Building kernel RPMs: make binrpm-pkg -j${JOBS}"
rm -rf rpmbuild
make binrpm-pkg -j"${JOBS}" -s

RPM_DIR="$(ls -d rpmbuild/RPMS/*/ 2>/dev/null | head -1)"
[[ -n "$RPM_DIR" && -d "$RPM_DIR" ]] || die "no RPM output dir under rpmbuild/RPMS"
log "RPMs built in ${RPM_DIR}"
ls -1 "${RPM_DIR}"kernel-*.rpm

# ---------------------------------------------------------------------------
# 3. Upload the RPMs to the target.
# ---------------------------------------------------------------------------
log "Uploading kernel RPMs to ${TARGET}:~/"
ssh "${TARGET}" 'rm -f ~/kernel-*.rpm'
scp "${RPM_DIR}"kernel-*.rpm "${TARGET}:~/"

# ---------------------------------------------------------------------------
# 4. Install the kernel (+ kernel-devel) on the target.
# ---------------------------------------------------------------------------
log "Installing kernel ${KREL} on ${TARGET}"
ssh "${TARGET}" bash -s -- "$KVER_RPM" <<'REMOTE'
set -euo pipefail
KVER_RPM="$1"
shopt -s nullglob
pkgs=( "$HOME"/kernel-"${KVER_RPM}"-*.rpm "$HOME"/kernel-devel-"${KVER_RPM}"-*.rpm )
if [[ ${#pkgs[@]} -eq 0 ]]; then
    echo "ERROR: no kernel RPMs matching ${KVER_RPM} in $HOME" >&2
    exit 1
fi
printf 'Installing: %s\n' "${pkgs[@]}"
sudo rpm -ivh --force "${pkgs[@]}"
REMOTE

# ---------------------------------------------------------------------------
# 5. Set a one-shot boot entry for the new kernel and reboot.
# ---------------------------------------------------------------------------
log "Setting one-shot boot entry for ${KREL} and rebooting ${TARGET}"
ssh "${TARGET}" bash -s -- "$KREL" <<'REMOTE' || true
set -uo pipefail
KREL="$1"
entry="$(sudo bootctl list 2>/dev/null \
            | awk '/^[[:space:]]*id:/ {print $2}' \
            | grep -F -- "-${KREL}.conf" | head -1)"
if [[ -z "$entry" ]]; then
    echo "ERROR: no systemd-boot entry found for ${KREL}" >&2
    exit 1
fi
echo "boot entry: ${entry}"
sudo bootctl set-oneshot "$entry"
echo "Rebooting now ..."
sudo systemctl reboot
REMOTE

# ---------------------------------------------------------------------------
# 6. Wait for the target to reboot and come back on the new kernel.
# ---------------------------------------------------------------------------
log "Waiting for ${TARGET} to reboot into ${KREL} (timeout ${BOOT_TIMEOUT}s)"
sleep 15   # let the machine actually begin shutting down before we poll
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while (( $(date +%s) < deadline )); do
    if running="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${TARGET}" 'uname -r' 2>/dev/null)"; then
        if [[ "$running" == "$KREL" ]]; then
            printf '\n\033[1;32m########################################################\033[0m\n'
            log "SUCCESS: ${TARGET} has booted the new kernel: ${running}"
            printf '\033[1;32m########################################################\033[0m\n'
            exit 0
        else
            warn "${TARGET} is up but running '${running}', expected '${KREL}'"
            exit 2
        fi
    fi
    sleep 10
done

die "timed out after ${BOOT_TIMEOUT}s waiting for ${TARGET} to boot ${KREL}"
