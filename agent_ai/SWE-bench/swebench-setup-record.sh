#!/usr/bin/env bash
# Set up SWE-bench and record LLM trajectories for replay_agent.py, on this machine:
#   1. check prerequisites, 2. get a SWE-bench checkout (clone it if this script isn't in one),
#   3. create .venv with SWE-bench + the pinned mini-swe-agent / litellm, 4. check the LLM API key,
#   5. get the problem set (HuggingFace dataset) and pull the Docker image of every selected bug,
#   6. record: `swebench infer` runs the LLM agent; every bug's dialog and commands are saved in
#      logs/inference/<RUN_ID>/<bug>/<bug>.traj.json, 7. list what was recorded,
#   8. (EVAL=1) grade the LLM's patches with `swebench eval`.
# Safe to re-run: the checkout, venv and images are reused, and bugs already recorded are skipped.
#
#   ./swebench-setup-record.sh
#   FILTER='django__.*' SLICE=0:12 WORKERS=4 RUN_ID=cpu-django ./swebench-setup-record.sh   # the defaults
#   SWE_BENCH=/path/to/SWE-bench MODEL=deepseek/deepseek-chat ./swebench-setup-record.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DATASET=${DATASET:-verified}                     # alias (verified, lite, full, ...) or HuggingFace id
MODEL=${MODEL:-deepseek/deepseek-chat}           # as litellm spells it
API_KEY_VAR=${API_KEY_VAR-DEEPSEEK_API_KEY}      # env var the model's provider reads; empty = don't check
RUN_ID=${RUN_ID:-cpu-django}                     # output: logs/inference/<RUN_ID>
FILTER=${FILTER:-django__.*}                     # instance-id regex (re.match), as mini's --filter
SLICE=${SLICE:-0:12}                             # slice of the filtered bugs, as mini's --slice
WORKERS=${WORKERS:-4}                            # bugs recorded in parallel
EVAL=${EVAL:-0}                                  # 1 = also grade the patches (runs the official tests)
MINI_VERSION=2.4.6                               # same agent code as the original recording
LITELLM_VERSION=1.105.1

die() { echo "ERROR: $*" >&2; exit 1; }
unset ALL_PROXY all_proxy                        # httpx (pip, HuggingFace, litellm) rejects socks:// proxies

echo "== 1. prerequisites"
docker info >/dev/null 2>&1 || die "docker is not usable by $(whoami) (install Docker, add user to the docker group, re-login)"
command -v git >/dev/null || die "git is required"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "python3 >= 3.10 required"
python3 -c 'import venv, ensurepip' 2>/dev/null || die "python3 venv missing (Debian/Ubuntu: sudo apt install python3-venv)"
df -h "$(docker info --format '{{.DockerRootDir}}')" 2>/dev/null | tail -1 || true

echo "== 2. SWE-bench checkout"
if [ -z "${SWE_BENCH:-}" ]; then
    if grep -qs '^name = "swebench"' "$HERE/pyproject.toml"; then SWE_BENCH=$HERE; else SWE_BENCH=$HOME/src/SWE-bench; fi
fi
[ -d "$SWE_BENCH/.git" ] || git clone https://github.com/SWE-bench/SWE-bench.git "$SWE_BENCH"
SWE_BENCH=$(cd "$SWE_BENCH" && pwd)
if [ "$SWE_BENCH" != "$HERE" ]; then             # keep both scripts next to .venv and logs/
    cp "$0" "$SWE_BENCH/swebench-setup-record.sh"
    [ -f "$HERE/replay_agent.py" ] && cp "$HERE/replay_agent.py" "$SWE_BENCH/"
fi
cd "$SWE_BENCH"
echo "$SWE_BENCH at $(git rev-parse --short HEAD)"

echo "== 3. python env (.venv)"
[ -x .venv/bin/python ] || python3 -m venv .venv
.venv/bin/pip install -q -e . "mini-swe-agent==$MINI_VERSION" "litellm==$LITELLM_VERSION"
.venv/bin/python -c 'import minisweagent; print("mini-swe-agent", minisweagent.__version__)' 2>/dev/null | tail -1

echo "== 4. API key"
if [ -n "$API_KEY_VAR" ]; then
    # swebench infer loads ./.env, mini loads ~/.config/mini-swe-agent/.env
    [ -n "${!API_KEY_VAR:-}" ] || grep -qsE "^(export +)?$API_KEY_VAR=." .env "$HOME/.config/mini-swe-agent/.env" ||
        die "$API_KEY_VAR is not set; export it, or add a line '$API_KEY_VAR=...' to $SWE_BENCH/.env"
    echo "$API_KEY_VAR found"
fi

echo "== 5. problem set ($DATASET, filter '$FILTER', slice '$SLICE') and Docker images"
# the same selection and image names mini uses in step 6 (lines tagged IMAGE: importing mini prints a banner)
mapfile -t images < <(.venv/bin/python -I - "$DATASET" "$FILTER" "$SLICE" <<'EOF' | sed -n 's/^IMAGE //p'
import sys
from datasets import load_dataset
from minisweagent.run.benchmarks.swebench import filter_instances, get_swebench_docker_image_name
from swebench.cli._datasets import resolve_dataset
dataset, filter_spec, slice_spec = sys.argv[1:]
instances = filter_instances(list(load_dataset(resolve_dataset(dataset), split="test")),
                             filter_spec=filter_spec, slice_spec=slice_spec)
for inst in instances:
    print(inst["instance_id"], get_swebench_docker_image_name(inst), file=sys.stderr)
    print("IMAGE", get_swebench_docker_image_name(inst))
EOF
)
[ "${#images[@]}" -gt 0 ] || die "no bugs match filter '$FILTER' slice '$SLICE'"
for image in "${images[@]}"; do                  # pull first, so step 6 doesn't wait on (or time) downloads
    docker image inspect "$image" >/dev/null 2>&1 && continue
    echo "pulling $image"
    docker pull -q "$image" >/dev/null
done
echo "${#images[@]} bugs, all images present"

echo "== 6. record with the LLM ($MODEL, $WORKERS at a time)"
.venv/bin/swebench infer "$DATASET" -m "$MODEL" --run-id "$RUN_ID" --filter "$FILTER" --slice "$SLICE" -w "$WORKERS"

echo "== 7. recorded trajectories (logs/inference/$RUN_ID)"
.venv/bin/python -I - "logs/inference/$RUN_ID" <<'EOF'
import json, pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).glob("*/*.traj.json")):
    t = json.loads(p.read_text())
    n = sum(len(m.get("extra", {}).get("actions", [])) for m in t["messages"] if m["role"] == "assistant")
    print(f"{t['instance_id']:30} {t['info']['exit_status']:16} {n:4} commands")
EOF

if [ "$EVAL" = 1 ]; then
    echo "== 8. grade the patches"
    .venv/bin/swebench eval "$DATASET" -p "logs/inference/$RUN_ID/preds.json" --run-id "$RUN_ID"
fi

cat <<EOF

Recorded. Replay without the LLM (run from $SWE_BENCH):
  ./replay_agent.py logs/inference/$RUN_ID -j \$(nproc) --copies \$(nproc) -o /tmp/replay-$RUN_ID
EOF
