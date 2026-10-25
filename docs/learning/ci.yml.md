# `.github/workflows/ci.yml` explained

Runs on every pull request to `main`: lint -> test -> security. Each job only starts if the previous one passed.

## Triggers, permissions, concurrency, env

| Lines | What it does | Why | What breaks without it |
|---|---|---|---|
| `on: pull_request: branches: [main]` | Run on PRs targeting main | Gate changes *before* they merge | Broken code reaches main |
| `on: workflow_dispatch` | Adds a manual "Run workflow" button | Re-run without a dummy commit | Only inconvenience |
| `permissions: contents: read` | Limits the auto-issued `GITHUB_TOKEN` to read-only | Least privilege: a compromised step can't push code or edit releases | Default token may be broader (repo setting dependent) |
| `concurrency.group: ci-<PR number or ref>` | One run per PR at a time | Same PR = same group | Parallel duplicate runs waste minutes |
| `cancel-in-progress: true` | New push cancels the older run on that PR | Superseded results are useless | Stale runs keep consuming runner time |
| `env.TRIVY_VERSION`, `TRIVY_SHA256` | Pins the scanner version and expected checksum of its tarball | Reproducible scans; tamper detection | A swapped binary would run unnoticed |

## Jobs

| Lines | What it does | Why | What breaks without it |
|---|---|---|---|
| `runs-on: ubuntu-24.04-arm` | Native arm64 runner | Matches the arm64 Lambda image (see DECISIONS.md); no emulation | Slow QEMU builds or an amd64 image that can't run on arm64 Lambda |
| `timeout-minutes` | Kills hung jobs | Cheap insurance against stuck runs | A hang burns the free minutes |
| `actions/checkout@<sha> # v7.0.1` | Clones the repo | Needed to have code. Full commit SHA, not a tag, because tags can be moved (this actually happened to trivy-action in March 2026) | Supply-chain risk if pinned to a movable tag |
| `persist-credentials: false` | Don't leave the token in `.git/config` | Later steps can't reuse it | A leaked token is easier to abuse |
| `actions/setup-python` with `cache: pip` | Installs Python 3.12 and caches pip downloads keyed on `requirements-dev.txt` | Same version as Lambda; faster installs | Wrong Python version; slower runs |
| `pip install -r requirements-dev.txt` | Installs the pinned lockfile | Same versions as local | Different versions than tested locally |
| `ruff check .` / `ruff format --check .` | Lint rules and formatting verification (no rewrite) | Cheap, fast feedback first | Style and bug-pattern issues merge |
| `needs: lint` / `needs: test` | Orders jobs | Fail fast, don't build images for code that doesn't lint or pass tests | Everything runs in parallel; wasted minutes on failures |
| `pytest` | Runs tests with moto; coverage gate comes from `fail_under = 80` in `pyproject.toml` | Behaviour + coverage regression guard | Untested changes merge |
| Install Trivy step | Downloads the release tarball, verifies the pinned sha256 with `sha256sum -c`, puts it on `PATH` | We use a pinned binary instead of `aquasecurity/trivy-action` after the March 2026 compromise (GHSA-69fq-xp46-6x23) | Third-party action code runs with our job's access |
| `docker build --build-arg GIT_SHA="$GIT_SHA" -t guarded-deploy:ci .` | Builds the default `prod` target | We scan exactly what we'd ship. SHA goes through `env:` rather than inline `${{ }}` in the script to avoid script injection | Scanning a different artifact than the deployed one |
| `trivy image ... --exit-code 1` | Scans OS packages + Python deps in the image; non-zero exit on HIGH/CRITICAL | Fails the job on serious CVEs | Vulnerable images deploy |
| `trivy fs --scanners vuln,secret,misconfig` | Scans lockfiles, leaked secrets, Dockerfile/IaC misconfig | Catches issues outside the image (and later Terraform) | Hardcoded secrets or insecure IaC merge |

## Interview questions this answers
- **"Why pin actions by SHA and Trivy by checksum?"** Tags are mutable; the March 2026 Trivy ecosystem compromise rewrote tags to malware. A SHA or checksum can't be silently swapped.
