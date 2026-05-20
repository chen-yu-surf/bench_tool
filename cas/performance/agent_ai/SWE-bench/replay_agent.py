#!/usr/bin/env python3
"""Replay recorded trajectories through mini-SWE-agent's own agent loop, with no LLM.

Unlike replay_trajs.py, this keeps mini-SWE-agent's real code path: the SWE-bench
batch runner (process_instance), ProgressTrackingAgent / DefaultAgent, tool-call
parsing, DockerEnvironment (docker run / docker exec), the submit check and the
trajectory / preds.json saving. Only LitellmModel._query(), the one place that
calls the LLM, is replaced: it hands back the LLM response saved in the
trajectory instead of calling litellm.completion().

Lives in the SWE-bench checkout next to swebench-setup-record.sh, which records the
trajectories into logs/inference/<run-id>. Run from the checkout; it re-runs itself
with .venv/bin/python (where mini-swe-agent is installed) when needed:

    ./replay_agent.py logs/inference/cpu-django --filter 10097 -j 32 --copies 32 -o /tmp/replay

The working set is the selected trajectories x --copies; wall_s is the time to run all of it.
By default only wall_s is printed (and warnings); -v shows mini's log, progress UI and the summary.
The full summary and per-replay data are always written to <output>/results.json.
"""

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERBOSE = bool({"-v", "--verbose"} & set(sys.argv[1:]))
if not VERBOSE:
    os.environ.setdefault("MSWEA_SILENT_STARTUP", "1")  # mini's version banner on import
try:
    import minisweagent  # noqa: F401
except ImportError:
    venv = HERE / ".venv"
    if (venv / "bin/python").exists() and Path(sys.prefix).resolve() != venv.resolve():
        os.execv(venv / "bin/python", [str(venv / "bin/python"), __file__, *sys.argv[1:]])
    sys.exit(f"mini-swe-agent is not installed here; run {HERE}/swebench-setup-record.sh first")

os.environ.setdefault("LITELLM_LOCAL_MODEL_COST_MAP", "True")  # no network fetch of the price table

import argparse
import concurrent.futures
import contextlib
import json
import logging
import re
import statistics
import threading
import time

import litellm
from rich.live import Live
from rich.logging import RichHandler

from minisweagent.environments.docker import DockerEnvironment
from minisweagent.exceptions import InterruptAgentFlow, LimitsExceeded
from minisweagent.models.litellm_model import LitellmModel, LitellmModelConfig
from minisweagent.run.benchmarks.swebench import process_instance
from minisweagent.run.benchmarks.utils.batch_progress import RunBatchProgressManager
from minisweagent.utils.log import add_file_handler, logger

_current = threading.local()  # per-worker-thread timing record of the replay in progress


class ReplayModelConfig(LitellmModelConfig):
    trajectory: Path
    """Recorded *.traj.json whose LLM responses are handed back in order."""
    think_time: float | None = 0.0
    """Seconds to sleep before each response; None = the recorded LLM latency."""


class ReplayModel(LitellmModel):
    """LitellmModel whose LLM call returns recorded responses instead of calling the API."""

    abort_exceptions = [*LitellmModel.abort_exceptions, InterruptAgentFlow]

    def __init__(self, **kwargs):
        super().__init__(config_class=ReplayModelConfig, **kwargs)
        messages = json.loads(self.config.trajectory.read_text())["messages"]
        self._responses = []
        last_ts = None
        for msg in messages:
            extra = msg.get("extra", {})
            if msg.get("role") == "assistant" and "response" in extra:
                latency = extra["timestamp"] - last_ts if last_ts and "timestamp" in extra else 0.0
                self._responses.append((extra["response"], max(latency, 0.0)))
            last_ts = extra.get("timestamp", last_ts)
        self._next = 0

    def _query(self, messages, **kwargs):
        if self._next >= len(self._responses):
            raise LimitsExceeded(
                {"role": "exit", "content": "ReplayExhausted",
                 "extra": {"exit_status": "ReplayExhausted", "submission": ""}}
            )
        response, latency = self._responses[self._next]
        self._next += 1
        delay = latency if self.config.think_time is None else self.config.think_time
        if delay:
            time.sleep(delay)
        return litellm.ModelResponse(**response)


class ReplayProgressManager(RunBatchProgressManager):
    """mini's progress UI keyed by worker thread, so concurrent copies of one bug get their own row."""

    @staticmethod
    def _key(instance_id: str) -> str:
        return f"{instance_id} [{threading.current_thread().name}]"

    def on_instance_start(self, instance_id):
        super().on_instance_start(self._key(instance_id))

    def update_instance_status(self, instance_id, message):
        super().update_instance_status(self._key(instance_id), message)

    def on_instance_end(self, instance_id, exit_status):
        super().on_instance_end(self._key(instance_id), exit_status)


class TimedDockerEnvironment(DockerEnvironment):
    """DockerEnvironment that also records how long container start and each command take."""

    def _start_container(self):
        t0 = time.monotonic()
        super()._start_container()
        if record := getattr(_current, "record", None):
            record["start_s"] = time.monotonic() - t0

    def execute(self, action, cwd="", *, timeout=None):
        t0 = time.monotonic()
        try:
            return super().execute(action, cwd, timeout=timeout)
        finally:
            if record := getattr(_current, "record", None):
                record["cmd_times"].append(time.monotonic() - t0)


def load_job(traj_path: Path, think_time: float | None) -> tuple[dict, dict]:
    """Build the SWE-bench instance and mini config that reproduce a recorded run."""
    traj = json.loads(traj_path.read_text())
    recorded = traj["info"]["config"]
    user_msg = next(m["content"] for m in traj["messages"] if m["role"] == "user")
    match = re.search(r"Consider the following PR description:\n(.*?)\n</pr_description>", user_msg, re.S)
    instance = {
        "instance_id": traj["instance_id"],
        "problem_statement": match.group(1) if match else user_msg,
        "image_name": recorded["environment"]["image"],
    }
    config = {
        "agent": recorded["agent"],
        "environment": {**recorded["environment"], "environment_class": f"{__name__}.TimedDockerEnvironment"},
        "model": {
            **recorded["model"],
            "model_class": f"{__name__}.ReplayModel",
            "trajectory": str(traj_path),
            "think_time": think_time,
            "cost_tracking": "ignore_errors",
        },
    }
    return instance, config


def run_one(instance: dict, output_dir: Path, config: dict, progress: RunBatchProgressManager, copy: int) -> dict:
    """mini's process_instance, plus timing."""
    _current.record = {"instance_id": instance["instance_id"], "copy": copy, "start_s": 0.0, "cmd_times": []}
    t0 = time.monotonic()
    try:
        process_instance(instance, output_dir, config, progress)
    finally:
        record, _current.record = _current.record, None
    record["total_s"] = time.monotonic() - t0
    record["exec_s"] = sum(record["cmd_times"])
    record["commands"] = len(record["cmd_times"])
    traj = output_dir / instance["instance_id"] / f"{instance['instance_id']}.traj.json"
    record["exit_status"] = json.loads(traj.read_text())["info"]["exit_status"] if traj.exists() else "NoTrajectory"
    return record


def pct(values: list[float], p: float) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, int(p / 100 * len(values)))] if values else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dirs", nargs="*", type=Path, default=[HERE / "logs/inference/cpu-django"],
                    help="Inference run directories holding */*.traj.json (default: logs/inference/cpu-django, "
                         "what swebench-setup-record.sh records)")
    ap.add_argument("-j", "--workers", type=int, default=8, help="Agents (containers) running at the same time")
    ap.add_argument("--copies", type=int, default=1, help="Replay every trajectory this many times")
    ap.add_argument("--filter", default="", help="Only replay instance ids matching this regex (re.search)")
    ap.add_argument("--think-time", default="0",
                    help="Seconds to sleep before each LLM response, or 'recorded' for the recorded LLM latency")
    ap.add_argument("-o", "--output", type=Path, required=True,
                    help="Directory for replayed trajectories, preds.json, mini log and results.json")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="Show mini's log, the progress UI and the summary (default: print only wall_s)")
    args = ap.parse_args()

    think_time = None if args.think_time == "recorded" else float(args.think_time)
    jobs = [load_job(p, think_time) for d in args.run_dirs for p in sorted(d.glob("*/*.traj.json"))
            if re.search(args.filter, p.parent.name)]
    if not jobs:
        sys.exit("no matching *.traj.json found")
    work = [(inst, cfg, c) for c in range(args.copies) for inst, cfg in jobs]
    recorded = {d.name: json.loads(next(d.glob("*.traj.json")).read_text())["info"]["exit_status"]
                for d in {Path(cfg["model"]["trajectory"]).parent for _, cfg in jobs}}
    if args.verbose:
        print(f"{len(jobs)} trajectories x {args.copies} copies = {len(work)} replays, {args.workers} at a time")

    args.output.mkdir(parents=True, exist_ok=True)
    add_file_handler(args.output / "minisweagent.log", print_path=args.verbose)  # the full log is always written
    if not args.verbose:
        for handler in logger.handlers:
            if isinstance(handler, RichHandler):  # mini's console log
                handler.setLevel(logging.WARNING)
    progress = ReplayProgressManager(len(work), args.output / f"exit_statuses_{time.time()}.yaml")
    results, failed, lock = [], 0, threading.Lock()

    def replay_safely(inst, cfg, output_dir, copy):
        nonlocal failed
        try:
            record = run_one(inst, output_dir, cfg, progress, copy)
        except Exception as e:  # noqa: BLE001 - report and keep the batch going
            print(f"replay failed: {e}", flush=True)
            with lock:
                failed += 1
            return
        with lock:
            results.append(record)

    t0 = time.monotonic()
    with Live(progress.render_group, refresh_per_second=4) if args.verbose else contextlib.nullcontext():
        with concurrent.futures.ThreadPoolExecutor(args.workers, thread_name_prefix="w") as pool:
            futures = [pool.submit(replay_safely, inst, cfg, args.output / f"copy-{c}", c) for inst, cfg, c in work]
            for fut in futures:
                fut.result()
    wall = time.monotonic() - t0

    cmds = [t for r in results for t in r["cmd_times"]]
    exit_statuses = {}
    for r in results:
        exit_statuses[r["exit_status"]] = exit_statuses.get(r["exit_status"], 0) + 1
    summary = {
        "replays": len(results),
        "failed": failed,
        "workers": args.workers,
        "wall_s": round(wall, 2),
        "replays_per_min": round(60 * len(results) / wall, 2) if wall else 0,
        "container_start_p50_s": round(pct([r["start_s"] for r in results], 50), 3),
        "container_start_p95_s": round(pct([r["start_s"] for r in results], 95), 3),
        "cmd_p50_s": round(pct(cmds, 50), 3),
        "cmd_p95_s": round(pct(cmds, 95), 3),
        "cmd_p99_s": round(pct(cmds, 99), 3),
        "cmd_mean_s": round(statistics.mean(cmds), 3) if cmds else 0,
        "exit_statuses": exit_statuses,
    }
    (args.output / "results.json").write_text(json.dumps({"summary": summary, "jobs": results}, indent=2))
    if args.verbose:
        print(json.dumps(summary, indent=2))
    else:
        print(f"wall_s {summary['wall_s']}")
    differ = sum(r["exit_status"] != recorded[r["instance_id"]] for r in results)
    if failed or differ:
        print(f"WARNING: {failed} replays failed, {differ} ended with a different exit status than recorded "
              f"(see {args.output}/results.json and minisweagent.log)", file=sys.stderr)


if __name__ == "__main__":
    main()
