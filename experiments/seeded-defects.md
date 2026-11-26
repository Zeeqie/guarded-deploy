# Seeded defects + OIDC negative test (Checkpoint 3D, 2026-11-26)

Each defect was planted on its own branch from main `e5f63ad` to check whether the pipeline catches it, and at which stage. #1–#5 were never merged. #6 was merged on purpose, because only CD can catch it. All numbers come from the raw files in [`raw/seeded-defects/`](raw/seeded-defects/). The table below is the output of `python3 -I experiments/seeded_defects_table.py` (definitions in its docstring).

## Results

| # | Defect | Expected stage | PR | Run | Caught by | Push to red | Users affected |
|---|---|---|---|---|---|---|---|
| #1 | failing unit test | CI test / pytest | [PR](https://github.com/Zeeqie/guarded-deploy/pull/6) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45869092577) | CI `test` job, step "Run pytest" | 62 s | no (never merged) |
| #2 | coverage 73.08% < 80% | CI test / pytest coverage gate | [PR](https://github.com/Zeeqie/guarded-deploy/pull/7) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45869106368) | CI `test` job, step "Run pytest" | 61 s | no (never merged) |
| #3 | urllib3 2.5.0 (CVE-2025-66418 HIGH, +5) | CI security / Trivy | [PR](https://github.com/Zeeqie/guarded-deploy/pull/8) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45869116327) | CI `security` job, step "Trivy image scan" | 114 s | no (never merged) |
| #4 | IAM `Action = "*"` (code only) | CI security / Trivy misconfig | [PR](https://github.com/Zeeqie/guarded-deploy/pull/9) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45869128891) | NOT CAUGHT: all CI jobs green | 110 s to green | n/a (never merged) |
| #5 | random AWS-format key pair in app/ | GitHub push protection | none (push rejected) | none | GitHub push protection (GH013), before CI | 1.7 s | no (never reached GitHub) |
| #6 | image no longer bakes GIT_SHA (/health says dev) | CD pre-traffic smoke test | [PR](https://github.com/Zeeqie/guarded-deploy/pull/10) | [CD run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45869569858) | CD deploy.sh `SMOKE_FAIL` (CI was green) | 107 s (merge to red) | no: alias v3 before, v3 after |
| OIDC | dispatch on `experiment/oidc-negative-test` | STS AccessDenied | none | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/45870598270) | CD step "Assume deploy role via OIDC (no stored keys)": AccessDenied | 34 s | no (no credentials issued) |

Caught: 5/6 seeded defects

## What each defect was, and the evidence

| # | Change | Evidence (raw file) |
|---|---|---|
| 1 | `tests/test_seeded_defect_1.py` asserts `/health` status is `"healthy"` (it is `"ok"`) | `AssertionError: assert 'ok' == 'healthy'` (`defect-1-ci-failed-step.log`) |
| 2 | `app/stats.py`: 21 untested statements, no tests deleted | `Coverage failure: total of 73 is less than fail-under=80`, TOTAL 78 stmts / 21 missed (`defect-2-ci-failed-step.log`) |
| 3 | `urllib3==2.8.0` → `2.5.0` in both lockfiles (pip still resolves; tests passed on it) | Trivy image scan: `Total: 6 (HIGH: 6, CRITICAL: 0)`, e.g. **CVE-2025-66418** (HIGH, fixed 2.6.0). The image scan runs before the fs scan, so it caught it first (`defect-3-ci-failed-step.log`) |
| 4 | `aws_iam_role_policy` with `Action = "*"`, `Resource = "*"` on the deploy role. **Never planned or applied** (CI does not run Terraform) | All CI jobs green (`defect-4-ci-run.json`) |
| 5 | `app/seeded_defect_5.py` with a randomly generated, never-issued `AKIA…` key ID + 40-char secret (not the AWS docs EXAMPLE key) | `GH013 … GITHUB PUSH PROTECTION … Amazon AWS Access Key ID … Amazon AWS Secret Access Key` (`defect-5-push-rejected.txt`, unblock URLs redacted). Not bypassed |
| 6 | Dockerfile: dropped `ENV GIT_SHA=${GIT_SHA}` (ARG only exists at build time) | CI green; CD `SMOKE_RESULT: function_error=none status=200 version=dev` → `SMOKE_FAIL: version 4 not promoted; alias live untouched on 3` (`defect-6-deploy-sh.log`) |
| OIDC | `workflow_dispatch` of a branch copy of `cd.yml` with the `if: main` guard removed and every push/deploy step replaced by a hard fail (`oidc-negative-workflow.diff`) | `Not authorized to perform sts:AssumeRoleWithWebIdentity` × 12 (`oidc-negative-assume-step.log`). CloudTrail shows the rejected `sub` ending `ref:refs/heads/experiment/oidc-negative-test` (`oidc-negative-cloudtrail.txt`). Alias v5, 5 ECR images, 6 versions before and after. Account ID: 0 hits in 227 log lines |

## Findings

1. **#4 slipped through: Trivy 0.76.1 doesn't evaluate the IAM wildcard check (AWS-0057).** `trivy config --include-non-failures` on infra/ lists every IAM check it ran (password policy, root, S3, pass-role). AWS-0057 isn't one of them, whether the policy is an inline `jsonencode`, an `aws_iam_policy_document` statement, or an `aws_iam_policy` resource. Only code review would have stopped this. A deploy role with `Action = "*"` is the most damaging defect in this list. A stolen CD token would become account admin. Fix options are listed in the checkpoint report. None is implemented yet.
2. **Defense in depth worked where it existed.** #5 never reached GitHub (push protection), and ruff's bandit rule S105 and Trivy's secret scanner would both have caught it next (verified locally). #6 passed every static gate and was stopped by the pre-traffic smoke test, with zero user exposure.
3. **#6 recovery (fix forward):** revert PR [#11](https://github.com/Zeeqie/guarded-deploy/pull/11) → CD deployed v5. `curl /health` → `a26cb7b2f011e787f48a4c46243ed24f8ff169e7` = revert merge SHA (`defect-6-revert-deploy-sh.log`). Main was undeployable for about 6 min 20 s (bad merge committed 17:39:23Z → revert `DEPLOY_OK` 17:45:43Z), but live never ran the bad image.
4. **Side effects to know:** version 4 (the `dev` image) still exists as an unused published version, and its image is in ECR. ECR has 5 images (keep-last-10).
