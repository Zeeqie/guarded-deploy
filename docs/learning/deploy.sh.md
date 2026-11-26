# `scripts/deploy.sh` explained

One image in, one of three outcomes out:

| Outcome | Exit | Where `live` ends up | Key log lines |
|---|---|---|---|
| New version healthy | 0 | NEW | `SMOKE_PASS`, `ALIAS_MOVED`, `DEPLOY_OK` |
| Fails **before** traffic (smoke test) | 1 | PREV (never moved) | `SMOKE_FAIL` |
| Fails **after** traffic (live check) | 1 | PREV (moved back, verified) | `ALIAS_MOVED`, `LIVE_CHECK_FAILED`, `ALIAS_REVERTED` |
| Rollback itself failed | 2 | unknown → human | `ROLLBACK_VERIFY_FAILED` |
| Same SHA re-run | 0 | unchanged | `NO_CHANGE` |

```
get-alias live = PREV ─ live already runs IMAGE_URI? ─yes─> NO_CHANGE exit 0
update-function-code --publish = NEW ─ wait ─ NEW == PREV? ─yes─> NO_CHANGE exit 0
                                              │ no
invoke --qualifier NEW (pre-traffic) ─fail─> SMOKE_FAIL exit 1 (alias untouched)
                                              │ ok
update-alias live -> NEW ─> curl API_URL/health ─fail─> update-alias live -> PREV, verify, exit 1
                                              │ ok
                                           DEPLOY_OK exit 0
```

## Setup

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `set -euo pipefail` | Exit on any error, on unset variables, and on failure anywhere in a pipe | A deploy script must never "carry on" after a failed AWS call | e.g. a failed `get-alias` gives an empty PREV and rollback targets nothing | "What does `set -euo pipefail` do?" |
| `: "${FUNCTION_NAME:?}" …` | Fails immediately if a required input is missing | Fail before touching AWS, not halfway | Confusing errors mid-deploy | — |
| `API_URL="${API_URL%/}"` | Strips a trailing `/` | The `$default` stage URL ends in `/` | Requests to `//health` | — |
| `WRONG_SHA=000…0` | The value compared against during fault injection | A real SHA can never be all zeros | — | — |
| `WORK_DIR="$(mktemp -d)"` | Private temp dir for responses | No collisions; cleaned up on exit | Stray files on the runner | — |
| `ALIAS_STATE` | Tracks `untouched → moved → verified / reverted / rollback_failed` | The exit trap uses it to decide whether a rollback is needed | Can't tell if NEW is serving unverified | — |
| `ts()` → `date -u +%Y-%m-%dT%H:%M:%S.%3NZ` | UTC timestamp with milliseconds on every log line | Rollback timing is in the hundreds of ms; seconds are too coarse | Can't measure time-to-rollback | — |
| `metric()` → `METRIC <name>=<epoch ms>` | Machine-readable lines, also saved as `METRIC_<name>` variables | `grep ^METRIC` in the job log gives exact timestamps; the script also prints `rollback_duration_ms` and `deploy_duration_ms` | Timing claims would be guesses (rule: never invent metrics) | "How did you measure rollback time?" |

## Safety net: `trap on_exit EXIT`

| Line | What it does | Why | What breaks without it |
|---|---|---|---|
| `rc=$?` first | Captures the real exit code | Anything run before it would overwrite `$?` | Wrong exit status |
| `if rc != 0 && ALIAS_STATE == moved → rollback` | Any *unexpected* crash after the traffic shift reverts the alias | "Fail at any point: alias reverts to PREV" must hold even for bugs in this script | A crash after the alias move would leave untested code live |
| `rollback_failed` state | Set before `exit 2` | Stops the trap from retrying a rollback that just failed verification | Double rollback and messy logs |
| `rm -rf "$WORK_DIR"` + `EXIT code=… prev=… new=…` | Cleanup + one summary line | Every run ends with a greppable verdict | — |

## Steps

| Step | Line(s) | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|---|
| a | `get-alias … --query FunctionVersion` → `PREV` | Records which version serves traffic now | That is the rollback target, captured **before** anything changes | Rollback wouldn't know where to go | "What does your rollback roll back *to*?" |
| g | `get-function --qualifier live --query Code.ImageUri` == `IMAGE_URI` → `NO_CHANGE`, exit 0 | If live already runs this exact image (a re-run of a deployed SHA), touch nothing | Doesn't depend on what `update-function-code --publish` returns for unchanged code, which the docs don't state | Re-runs would update `$LATEST` and invoke for nothing | "Is your deploy idempotent?" |
| b | `wait function-updated-v2` (before) | Waits for any in-flight update on `$LATEST` | `UpdateFunctionCode` is rejected while an update is in progress | `ResourceConflictException` on back-to-back deploys | — |
| b | `update-function-code --image-uri … --publish --query Version` → `NEW` | Points `$LATEST` at the new image and publishes an immutable numbered version | The alias points at versions, never `$LATEST` | — | "What's the difference between `$LATEST` and a published version?" |
| b | `[[ "$NEW" =~ ^[0-9]+$ ]]` | Rejects anything that isn't a version number | Never smoke-test or route to `$LATEST` by mistake | Silent misrouting | — |
| b | `wait function-updated-v2`, then `wait function-active-v2 --qualifier NEW` | Real waiters from `aws lambda wait help`. Both poll **GetFunction**, which the deploy role is allowed | `published-version-active` / `function-updated` poll `GetFunctionConfiguration`, which the least-privilege role does **not** have | Invoking a Pending version fails; using the wrong waiter → AccessDenied | "How do you know a Lambda version is ready?" |
| g | `NEW == PREV` → `NO_CHANGE`, exit 0 (second guard) | "Lambda doesn't publish a version if the function's configuration and code haven't changed since the last version" (`aws lambda publish-version help`) | Belt and braces if the first guard is bypassed | A live-check failure would "roll back" to the same version | — |
| c | `invoke --qualifier NEW --payload fileb://events/health.json` | Calls version NEW **directly** with an API Gateway HTTP API v2 `GET /health` event | Tests the new code in real Lambda **before** any user traffic reaches it | Broken builds go live and rely on rollback | "What's a pre-traffic hook?" |
| c | `--cli-binary-format raw-in-base64-out` | Sends the JSON file as-is | CLI v2 otherwise expects base64 payloads | Invalid payload error | — |
| c | `FunctionError` check + `statusCode == 200` + `body.version == GIT_SHA` | Three conditions: no crash, healthy, and *the right build* | `200` alone could come from an old image | False pass | "Why check the version, not just the status?" |
| c | `SMOKE_FAIL` → exit 1 | The alias was never moved, so nothing to undo | — | — | — |
| d | `update-alias live → NEW`, `ALIAS_STATE=moved`, `ALIAS_MOVED` | Atomic traffic shift: every new request hits NEW | Instant cutover (no gradual weights; one user, one function) | — | "How is traffic switched without downtime?" |
| e | `curl -sS --max-time 5 … ${API_URL}/health`, 5 attempts × 2 s | Checks the **real public path**: API Gateway → alias → NEW | Catches what a direct invoke can't (route, permission on the alias, gateway integration) | A version that works on direct invoke but not through the URL stays live | "Why test twice?" |
| e | Requires `200` and `version == expected` | Same proof as the smoke test, end to end | — | — | — |
| e | `INJECT_LIVE_CHECK_FAILURE=true` → `expected=WRONG_SHA`, `!!!!!!!! FAULT_INJECTION` lines | Makes a healthy deploy *look* broken so the rollback runs for real | Proves the rollback path in production conditions, loudly labelled so nobody mistakes it for an incident | — | "How do you test a rollback?" |
| f | `LIVE_CHECK_FAILED` → `rollback` | `update-alias live → PREV`, then `get-alias` must equal PREV, then `ALIAS_REVERTED` | Don't trust the write: read it back | Rollback "succeeds" without being verified | "How do you know the rollback worked?" |
| f | `exit 1` after a successful rollback | The run goes red even though users are safe again | A failed deploy must be visible | Failures hidden behind green runs | — |
| — | `METRIC rollback_duration_ms` | `alias_reverted_at − live_check_failed_at` | Time from detection to verified revert | — | "How fast is your rollback?" (quote it from a real log) |

## Rollback depth limit

Automatic rollback is always exactly **one step** (to PREV). Manual rollback is safe only to versions whose image is still in ECR. The lifecycle policy keeps the 5 newest images by push time, so that means at most **4 versions back** (see DECISIONS.md). Images from failed deploys use up those 5 slots too.

## Tested offline

All paths were run against fake `aws`/`curl`/`date` shims (no AWS calls): happy path, same-SHA no-op, smoke wrong version, smoke `FunctionError`, injected live-check failure with a verified revert, and a revert that fails verification (exit 2, no retry).
