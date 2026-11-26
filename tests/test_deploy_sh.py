"""Runs scripts/deploy.sh against fake aws/curl/date (tests/deploy_sh_fakes): no AWS calls.

Every scenario starts from the same state: alias "live" -> version 3 running OLD_SHA,
and $LATEST also on OLD_SHA. Each one asserts the exit code AND where "live" ends up,
because a deploy script that exits correctly but leaves traffic on the wrong version is
the bug we care about.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "deploy.sh"
FAKES = Path(__file__).resolve().parent / "deploy_sh_fakes"
OLD_SHA = "a" * 40
NEW_SHA = "b" * 40
BASH = shutil.which("bash")

SCENARIOS = {
    # name: (extra env, expected exit, expected final alias, log line that must appear)
    "happy": ({}, 0, "4", "DEPLOY_OK"),
    "same_sha": ({"SIM_NEW_SHA": OLD_SHA}, 0, "3", "NO_CHANGE"),
    "smoke_wrong_version": ({"SIM_SMOKE_VERSION": "dev"}, 1, "3", "SMOKE_FAIL"),
    "smoke_function_error": ({"SIM_FUNCTION_ERROR": "1"}, 1, "3", "SMOKE_FAIL"),
    "smoke_status_500": ({"SIM_SMOKE_STATUS": "500"}, 1, "3", "SMOKE_FAIL"),
    "inject_live_failure": ({"INJECT_LIVE_CHECK_FAILURE": "true"}, 1, "3", "ALIAS_REVERTED"),
    "rollback_verify_fails": (
        {"INJECT_LIVE_CHECK_FAILURE": "true", "SIM_ALIAS_STUCK": "1"},
        2,
        "4",
        "ROLLBACK_VERIFY_FAILED",
    ),
}


def _state(tmp_path: Path) -> Path:
    st = tmp_path / "state"
    st.mkdir()
    for name, value in {
        "alias": "3",
        "first_alias": "3",
        "ver": "3",
        "image": f"repo:{OLD_SHA}",
        "img_3": f"repo:{OLD_SHA}",
        "sha_3": OLD_SHA,
    }.items():
        (st / name).write_text(value + "\n")
    return st


def _run(tmp_path: Path, extra: dict[str, str]):
    st = _state(tmp_path)
    extra = dict(extra)
    sha = extra.pop("SIM_NEW_SHA", NEW_SHA)
    env = {
        **os.environ,
        **extra,
        "PATH": f"{FAKES}{os.pathsep}{os.environ['PATH']}",
        "SIM_STATE": str(st),
        "FUNCTION_NAME": "guarded-deploy",
        "IMAGE_URI": f"repo:{sha}",
        "GIT_SHA": sha,
        "API_URL": "https://example.invalid/",
        "LIVE_CHECK_SLEEP_SECONDS": "0",
    }
    # Fixed argv, no shell, script path from this repo: nothing untrusted reaches it.
    result = subprocess.run(  # noqa: S603
        [BASH, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60, check=False
    )
    return result, st


# Skip locally if a tool is missing, but never in CI (GitHub sets CI=true): a silently
# skipped rollback test would make a green run meaningless.
needs_tools = pytest.mark.skipif(
    not os.environ.get("CI") and any(shutil.which(t) is None for t in ("bash", "jq", "perl")),
    reason="needs bash, jq and perl",
)


@needs_tools
@pytest.mark.parametrize("name", SCENARIOS)
def test_deploy_scenario(name, tmp_path):
    extra, want_rc, want_alias, want_line = SCENARIOS[name]
    result, st = _run(tmp_path, extra)

    log = result.stdout
    assert result.returncode == want_rc, log + result.stderr
    assert (st / "alias").read_text().strip() == want_alias, log
    assert want_line in log, log
    assert f"EXIT code={want_rc}" in log
    assert "unexpected call" not in result.stderr
    # Every scenario must end via its planned path, never via the exit-trap safety net
    # (otherwise deleting the explicit rollback would go unnoticed).
    assert "UNEXPECTED_FAILURE" not in log, log


@needs_tools
def test_smoke_failure_never_calls_update_alias(tmp_path):
    """Pre-traffic failure must not touch the alias at all (not even move-and-revert)."""
    result, st = _run(tmp_path, {"SIM_SMOKE_VERSION": "dev"})

    assert result.returncode == 1
    assert "update-alias" not in (st / "calls").read_text()
