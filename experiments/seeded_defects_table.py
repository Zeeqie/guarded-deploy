"""Rebuild the seeded-defects results table from experiments/raw/seeded-defects/.

Usage (from the repo root):  python3 -I experiments/seeded_defects_table.py
Stdlib only, no network, no AWS: every number comes from files committed next to it.

"Push to red" definitions:
  #1-#4  push_done (local UTC clock right after `git push` returned) -> completedAt of
         the first CI job whose conclusion is failure (GitHub run JSON).
  #5     push_started -> push_done of the rejected `git push` (push protection).
  #6     merge commit committer time (git %cI, 1 s resolution) -> METRIC smoke_failed_at.
  OIDC   run createdAt -> completedAt of the failed assume-role step.
"""

import json
import re
from datetime import UTC, datetime
from pathlib import Path

RAW = Path(__file__).resolve().parent / "raw" / "seeded-defects"
REPO = "https://github.com/Zeeqie/guarded-deploy"


def ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def env(n: int) -> dict[str, str]:
    lines = (RAW / f"defect-{n}.env").read_text().splitlines()
    return dict(line.split("=", 1) for line in lines if "=" in line)


def run(name: str) -> dict:
    return json.loads((RAW / name).read_text())


def metric(log: str, name: str) -> datetime:
    ms = int(re.search(rf"^METRIC {name}=(\d+)$", log, re.M).group(1))
    return datetime.fromtimestamp(ms / 1000, tz=UTC)


def ci_row(n: int, defect: str, expected: str) -> list[str]:
    e, r = env(n), run(f"defect-{n}-ci-run.json")
    failed = [j for j in r["jobs"] if j["conclusion"] == "failure"]
    if not failed:
        return [
            f"#{n}",
            defect,
            expected,
            f"[PR]({e['pr_url']})",
            f"[run]({r['url']})",
            "NOT CAUGHT: all CI jobs green",
            f"{(ts(r['updatedAt']) - ts(e['push_done'])).total_seconds():.0f} s to green",
            "n/a (never merged)",
        ]
    job = failed[0]
    step = next(s["name"] for s in job["steps"] if s["conclusion"] == "failure")
    secs = (ts(job["completedAt"]) - ts(e["push_done"])).total_seconds()
    return [
        f"#{n}",
        defect,
        expected,
        f"[PR]({e['pr_url']})",
        f"[run]({r['url']})",
        f'CI `{job["name"]}` job, step "{step}"',
        f"{secs:.0f} s",
        "no (never merged)",
    ]


def main() -> None:
    rows = [
        ci_row(1, "failing unit test", "CI test / pytest"),
        ci_row(2, "coverage 73.08% < 80%", "CI test / pytest coverage gate"),
        ci_row(3, "urllib3 2.5.0 (CVE-2025-66418 HIGH, +5)", "CI security / Trivy"),
        ci_row(4, 'IAM `Action = "*"` (code only)', "CI security / Trivy misconfig"),
    ]
    e5 = env(5)
    secs5 = (ts(e5["push_done"]) - ts(e5["push_started"])).total_seconds()
    rows.append(
        [
            "#5",
            "random AWS-format key pair in app/",
            "GitHub push protection",
            "none (push rejected)",
            "none",
            "GitHub push protection (GH013), before CI",
            f"{secs5:.1f} s",
            "no (never reached GitHub)",
        ]
    )

    e6, r6 = env(6), run("defect-6-cd-run.json")
    log6 = (RAW / "defect-6-deploy-sh.log").read_text()
    secs6 = (metric(log6, "smoke_failed_at") - ts(e6["merge_committed"])).total_seconds()
    rows.append(
        [
            "#6",
            "image no longer bakes GIT_SHA (/health says dev)",
            "CD pre-traffic smoke test",
            f"[PR]({REPO}/pull/10)",
            f"[CD run]({r6['url']})",
            "CD deploy.sh `SMOKE_FAIL` (CI was green)",
            f"{secs6:.0f} s (merge to red)",
            f"no: alias v{e6['alias_before']} before, v{e6['alias_after']} after",
        ]
    )

    o = run("oidc-negative-run.json")
    step = next(s for j in o["jobs"] for s in j["steps"] if s["conclusion"] == "failure")
    secs_o = (ts(step["completedAt"]) - ts(o["createdAt"])).total_seconds()
    rows.append(
        [
            "OIDC",
            f"dispatch on `{o['headBranch']}`",
            "STS AccessDenied",
            "none",
            f"[run]({o['url']})",
            f'CD step "{step["name"]}": AccessDenied',
            f"{secs_o:.0f} s",
            "no (no credentials issued)",
        ]
    )

    head = [
        "#",
        "Defect",
        "Expected stage",
        "PR",
        "Run",
        "Caught by",
        "Push to red",
        "Users affected",
    ]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for row in rows:
        print("| " + " | ".join(row) + " |")
    caught = sum(1 for row in rows[:6] if not row[5].startswith("NOT CAUGHT"))
    print(f"\nCaught: {caught}/6 seeded defects")


if __name__ == "__main__":
    main()
