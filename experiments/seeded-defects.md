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

Original pipeline: caught 5/6 seeded defects

### After the #4 fix (fix/iam-wildcard-gate)

| # | Defect | Expected stage | PR | Run | Caught by | Push to red | Users affected |
|---|---|---|---|---|---|---|---|
| #4-recheck-1 | #4 re-created, GD-0001 only | CI security / GD-0001 | [PR](https://github.com/Zeeqie/guarded-deploy/pull/14) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/46149226207) | NOT CAUGHT: all CI jobs green | 128 s to green | n/a (never merged) |
| #4-recheck-2 | #4 re-created, GD-0001 + text scan | CI test / IAM text scan | [PR](https://github.com/Zeeqie/guarded-deploy/pull/15) | [run](https://github.com/Zeeqie/guarded-deploy/actions/runs/46149564066) | CI `test` job, step "Run pytest" | 52 s | no (never merged) |

After fix: caught 6/6 seeded defects

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

1. **#4 slipped through the original pipeline (5/6), now fixed (6/6).**
   - *Why it slipped:* built-in AWS-0057 is `deprecated: true` and has **no rules** in checks bundle 2. It was re-added as an empty stub in [aquasecurity/trivy-checks@c292eb6](https://github.com/aquasecurity/trivy-checks/commit/c292eb6737e06dc21006cc508391b065cfd5601f) (2025-01-14, "add removed Go checks as deprecated"). Nothing else in Trivy checks for wildcard IAM actions.
   - *Fix attempt 1, a custom Rego check GD-0001 (`.trivy/checks/`):* it catches every fixture style, but it **missed the re-created defect in CI** (re-check 1). Bisecting showed that Trivy 0.76.1 keeps only **one inline `aws_iam_role_policy` per role** in its IAM model, so a second wildcard inline policy on the deploy role is invisible to every Trivy IAM check. No upstream issue found; not filed.
   - *Fix attempt 2, plus a stdlib text scan (`tests/test_iam_no_wildcards.py`):* it reads raw `.tf` text, so it can't share Trivy's model blind spot. Caught in the CI `test` job (re-check 2). Both gates stay: the text scan for anything written in the file, GD-0001 for evaluated policies (actions built from locals or variables).
   - Lesson: a scanner passing is evidence only for the cases you've proven it sees. Test the gate against the real code shape, not just a minimal fixture.
2. **Defense in depth worked where it existed.** #5 never reached GitHub (push protection), and ruff's bandit rule S105 and Trivy's secret scanner would both have caught it next (verified locally). #6 passed every static gate and was stopped by the pre-traffic smoke test, with zero user exposure.
3. **#6 recovery (fix forward):** revert PR [#11](https://github.com/Zeeqie/guarded-deploy/pull/11) → CD deployed v5. `curl /health` → `a26cb7b2f011e787f48a4c46243ed24f8ff169e7` = revert merge SHA (`defect-6-revert-deploy-sh.log`). Main was undeployable for about 6 min 20 s (bad merge committed 17:39:23Z → revert `DEPLOY_OK` 17:45:43Z), but live never ran the bad image.
4. **Side effects to know:** version 4 (the `dev` image) still exists as an unused published version, and its image is in ECR. ECR has 5 images (keep-last-10).
