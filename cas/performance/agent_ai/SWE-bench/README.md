# SWE-bench record + LLM-free replay in a nutshell

## How to run it

```bash
# copy`swebench-setup-record.sh` and `replay_agent.py` to SWE-bench directory, then.
export DEEPSEEK_API_KEY=sk-...          # or put it in ~/src/SWE-bench/.env after the clone
./swebench-setup-record.sh              # clones to ~/src/SWE-bench, sets up, records (~10 min, ~$0.16)
cd ~/src/SWE-bench
./replay_agent.py --filter 10097 -j $(nproc) --copies $(nproc) -o /tmp/replay-10097
# wall_s 16.9
```
Add -v / --verbose to get everything

## `swebench-setup-record.sh` (the SWE-bench steps)

1. Checks Docker, git, Python 3.10 or newer, and venv support.
2. Uses the SWE-bench checkout the script is in. If it isn't in one, it clones SWE-bench into `~/src/SWE-bench` (or `$SWE_BENCH`) and copies both scripts into it.
3. Creates `.venv` with SWE-bench, `mini-swe-agent==2.4.6` and `litellm==1.105.1`, the same versions as here.
4. Checks for the API key in the environment, `./.env` or `~/.config/mini-swe-agent/.env`. If it's missing, it stops and says where to put it.
5. Downloads the problem set from HuggingFace and pulls the Docker image of each selected bug. It selects bugs with mini's own filter and image-naming functions, so it pulls exactly what step 6 will use.
6. Records with `swebench infer`, which writes `logs/inference/<RUN_ID>/<bug>/<bug>.traj.json`.
7. Lists each recorded bug with its exit status and number of commands.
8. With `EVAL=1`, also grades the patches with `swebench eval`.

Settings are environment variables, and the defaults reproduce the cpu-django recording: `FILTER='django__.*' SLICE=0:12 WORKERS=4 RUN_ID=cpu-django MODEL=deepseek/deepseek-chat DATASET=verified`. Re-running is safe: bugs already recorded are skipped.

## `replay_agent.py` changes (the replay logic is unchanged)

- It works with plain `./replay_agent.py`, without the venv activated: if mini-swe-agent isn't importable, it re-runs itself with the `.venv/bin/python` next to it.
- The run directory now defaults to `logs/inference/cpu-django`.
- Quiet by default: it prints only `wall_s <seconds>`, plus a stderr `WARNING:` if any replay failed or ended with a different exit status than recorded. `-v` / `--verbose` shows mini's log, the progress UI and the JSON summary. `<out>/results.json` and `<out>/minisweagent.log` are always written.
