# Rollback + lead-time trials (Checkpoint 3E, 2026-11-28)

Option A from the 3E design. Every trial is a one-line PR to `experiments/trials/log.txt`, so every trial deploys a SHA that has never been deployed before:

- **L (lead time):** normal merge. The push-triggered CD run deploys it.
- **R (rollback):** merge with `[skip ci]` in the subject. The runner checks that no CD run started, then dispatches `cd.yml` with `inject_live_check_failure=true`. The alias moves to the new version, the live check is forced to fail, and the alias reverts to PREV.

Plan: `L R L R L R L R L R L L L L L` (10 L, 5 R, ending on L). Runner: [`run_trials.sh`](run_trials.sh). Analysis: `python3 -I experiments/analyze_trials.py`, which is stdlib only, reads [`raw/trials/`](raw/trials/), and gives the same output on every run.

## Definitions
| Metric | Start | End |
|---|---|---|
| Lead time (L) | merge commit committer time (`git log -1 --format=%cI`, set by GitHub at merge, 1 s resolution) | `METRIC live_check_passed_at` in that commit's CD run |
| Rollback time (R) | `METRIC live_check_failed_at` | `METRIC alias_reverted_at` (must equal the script's `rollback_duration_ms`) |
| Exposure window (R) | `METRIC alias_moved_at` | `METRIC alias_reverted_at` |

## Results

| Trial | Kind | Merge SHA | CD run | Live before → after | Lead time | Rollback | Exposure |
|---|---|---|---|---|---|---|---|
| 01-L | L | `3fb3d63` | 46151599685 | v8 → v9 | 106.175 s | - | - |
| 02-R | R | `df78884` | 46152047596 | v9 → v9 | - | 2.648 s | 14.399 s |
| 03-L | L | `8833cd9` | 46152454463 | v9 → v11 | 111.079 s | - | - |
| 04-R | R | `45a2937` | 46152944466 | v11 → v11 | - | 2.471 s | 13.881 s |
| 05-L | L | `3373f7b` | 46159061143 | v11 → v13 | 105.201 s | - | - |
| 06-R | R | `713d81c` | 46159552892 | v13 → v13 | - | 2.480 s | 13.948 s |
| 07-L | L | `99756c8` | 46159962711 | v13 → v15 | 104.803 s | - | - |
| 08-R | R | `e26ea02` | 46160437886 | v15 → v15 | - | 2.404 s | 13.920 s |
| 09-L | L | `8f19398` | 46160843687 | v15 → v17 | 108.819 s | - | - |
| 10-R | R | `0eeb504` | 46161325432 | v17 → v17 | - | 2.477 s | 13.980 s |
| 11-L | L | `5890b68` | 46161753953 | v17 → v19 | 107.514 s | - | - |
| 12-L | L | `6c812db` | 46162194014 | v19 → v20 | 112.288 s | - | - |
| 13-L | L | `0303420` | 46162605291 | v20 → v21 | 105.163 s | - | - |
| 14-L | L | `64519b0` | 46163042902 | v21 → v22 | 105.402 s | - | - |
| 15-L | L | `5ebfcab` | 46163469432 | v22 → v23 | 107.203 s | - | - |

| Metric | n | median | min | max |
|---|---|---|---|---|
| Lead time (merge commit → live check passed) | 10 | 106.689 s | 104.803 s | 112.288 s |
| Rollback time (LIVE_CHECK_FAILED → ALIAS_REVERTED) | 5 | 2.477 s | 2.404 s | 2.648 s |
| Exposure window (ALIAS_MOVED → ALIAS_REVERTED) | 5 | 13.948 s | 13.881 s | 14.399 s |

Discarded trials: 1
- 05-L-attempt1: status=aborted aborted: GitHub API timeout in precheck, no side effects

## How to read these numbers
- **Rollback ≈ 2.5 s is two aws CLI calls**: `update-alias` → PREV, then a verifying `get-alias`. Trial 06-R: ROLLBACK 15:24:40.630Z → ALIAS_REVERTED 15:24:43.110Z.
- **Exposure ≈ 14 s is mostly the detection budget, not the rollback.** 5 live-check attempts with 2 s sleeps take ≈ 11.5 s (06-R: ALIAS_MOVED 15:24:29.161Z → LIVE_CHECK_FAILED 15:24:40.629Z), plus the ≈ 2.5 s rollback. Cutting retries would shrink exposure but raise false rollbacks. The version under test was healthy (the failure was injected), so this measures the pipeline, not an outage.
- **Lead time ≈ 107 s covers merge → build → Trivy → push → publish → smoke → alias → live check.** It excludes PR CI, which ran before the merge. The start timestamp has 1 s resolution.
- n is small (10 and 5), from one runner type on one day. These are medians of this setup, not benchmarks.

## Deviations, all recorded
- **Trial 5, attempt 1 aborted** in its precheck: a GitHub API i/o timeout from the laptop, with no side effects (no branch, PR, push or dispatch; verified). It's kept as `raw/trials/05-L-attempt1/` and listed as discarded above. The runner was then hardened: read-only lookups retry up to 3 times (2/5/10 s, logged), writes are never retried, and an ERR trap records the failing line, command and exit code. It resumed at trial 5. Retries actually used afterwards: 0 (`grep -c RETRY raw/trials/runner-log-trials-05-15.txt`).
- **One non-trial merge between trials 4 and 5** ([PR #21](https://github.com/Zeeqie/guarded-deploy/pull/21), the runner change) was merged with `[skip ci]`, so nothing was deployed and live stayed on trial 4's PREV.
- **`[skip ci]` checked on all 5 R trials:** no push-triggered CD run for any R merge (`skip_ci_confirmed` in each `trial.env`).
- **Version numbers jump by 2 after each R**, because the version that failed its injected live check stays published but unused.

## Final state (after trial 15)
- Live v23 serves `5ebfcab` = main HEAD.
- **ECR: 23 images, so "≤ 10" is not met yet.** The keep-last-10 rule last ran at 2026-11-28T13:05:28Z (`aws ecr get-lifecycle-policy` → `lastEvaluatedAt`), before the trials, and ECR documents expiry as "within 24 hours". Live's image is the newest, so it's in no danger.
- AWS plan: FREE / ACTIVE, credits $159.997725 remaining, expires 2027-04-23 (`aws freetier get-account-plan-state`).
- Budget `guarded-deploy-5usd`: actual $0.002, forecast $0.002, all 3 notifications (actual 20%, actual 100%, forecast 100%) in state OK.
