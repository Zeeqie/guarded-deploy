"""Summarise Checkpoint 3E trials from experiments/raw/trials/<NN>-<K>/.

Usage (repo root):  python3 -I experiments/analyze_trials.py [raw_dir]
Stdlib only, no network: the same raw files always give the same output.

Definitions (all from the raw files of one trial):
  lead time  (L)  = METRIC live_check_passed_at - merge commit committer time (git %cI, 1 s
                    resolution, set by GitHub at merge). Excludes PR CI/review time.
  rollback   (R)  = METRIC alias_reverted_at - METRIC live_check_failed_at
                    (cross-checked against the script's own METRIC rollback_duration_ms).
  exposure   (R)  = METRIC alias_reverted_at - METRIC alias_moved_at: how long the version
                    that failed its live check was taking traffic (includes the live-check
                    retry budget, 5 attempts x 2 s sleep).
A trial is kept only if it validates; every discarded trial is printed with its reason.
"""

import re
import sys
from datetime import datetime
from pathlib import Path
from statistics import median

RAW = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "raw" / "trials"


def read_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key] = value  # later lines win (e.g. status)
    return out


def metrics(log: str) -> dict[str, int]:
    return {k: int(v) for k, v in re.findall(r"^METRIC (\w+)=(\d+)$", log, re.M)}


def epoch_ms(iso: str) -> int:
    return round(datetime.fromisoformat(iso).timestamp() * 1000)


def evaluate(trial_dir: Path) -> tuple[dict, str | None]:
    env = read_env(trial_dir / "trial.env")
    row = {"trial": trial_dir.name, "kind": env.get("kind", "?"), "env": env}
    if env.get("status") != "ok":
        return row, f"status={env.get('status', 'missing')} {env.get('reason', '')}".strip()
    log_path = trial_dir / "deploy-sh.log"
    if not log_path.exists():
        return row, "no deploy-sh.log"
    log = log_path.read_text()
    m = metrics(log)
    if row["kind"] == "L":
        if "DEPLOY_OK" not in log or env.get("health_after") != env.get("merge_sha"):
            return row, "no DEPLOY_OK or /health != merge SHA"
        row["lead_ms"] = m["live_check_passed_at"] - epoch_ms(env["merge_committed"])
    elif row["kind"] == "R":
        if "ALIAS_REVERTED" not in log or env.get("live_after") != env.get("live_before"):
            return row, "no ALIAS_REVERTED or alias != PREV after the run"
        row["rollback_ms"] = m["alias_reverted_at"] - m["live_check_failed_at"]
        row["exposure_ms"] = m["alias_reverted_at"] - m["alias_moved_at"]
        if m.get("rollback_duration_ms") != row["rollback_ms"]:
            return row, "rollback_duration_ms disagrees with timestamps"
    else:
        return row, f"unknown kind {row['kind']}"
    return row, None


def summary(name: str, values: list[int]) -> str:
    if not values:
        return f"| {name} | 0 | - | - | - |"
    return (
        f"| {name} | {len(values)} | {median(values) / 1000:.3f} s | "
        f"{min(values) / 1000:.3f} s | {max(values) / 1000:.3f} s |"
    )


def main() -> None:
    kept, discarded = [], []
    for trial_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        row, reason = evaluate(trial_dir)
        (discarded if reason else kept).append((row, reason))

    header = ["Trial", "Kind", "Merge SHA", "CD run", "Live before → after"]
    header += ["Lead time", "Rollback", "Exposure"]
    print("| " + " | ".join(header) + " |")
    print("|---|---|---|---|---|---|---|---|")
    for row, _ in kept:
        env = row["env"]

        def fmt(key: str, r: dict = row) -> str:
            return f"{r[key] / 1000:.3f} s" if key in r else "-"

        print(
            f"| {row['trial']} | {row['kind']} | `{env['merge_sha'][:7]}` | {env['cd_run']} | "
            f"v{env['live_before']} → v{env['live_after']} | {fmt('lead_ms')} | "
            f"{fmt('rollback_ms')} | {fmt('exposure_ms')} |"
        )

    print("\n| Metric | n | median | min | max |")
    print("|---|---|---|---|---|")
    print(
        summary(
            "Lead time (merge commit → live check passed)",
            [r["lead_ms"] for r, _ in kept if "lead_ms" in r],
        )
    )
    print(
        summary(
            "Rollback time (LIVE_CHECK_FAILED → ALIAS_REVERTED)",
            [r["rollback_ms"] for r, _ in kept if "rollback_ms" in r],
        )
    )
    print(
        summary(
            "Exposure window (ALIAS_MOVED → ALIAS_REVERTED)",
            [r["exposure_ms"] for r, _ in kept if "exposure_ms" in r],
        )
    )

    print(f"\nDiscarded trials: {len(discarded)}")
    for row, reason in discarded:
        print(f"- {row['trial']}: {reason}")


if __name__ == "__main__":
    main()
