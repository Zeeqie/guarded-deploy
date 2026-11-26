# Incidents

One entry per production-affecting or pipeline-blocking event. Times are UTC and come from real output; the command that produced them is noted.

## 2026-11-26: first CD run failed closed (OIDC `sub` mismatch)

**Impact: none.** The pipeline failed *before* getting any AWS credentials. Nothing was built, pushed, or deployed. `live` stayed on v1 (`aws lambda get-alias`), and `/health` kept returning 200 with the Day 2 bootstrap SHA throughout. Users were never exposed to a broken version.

**Timeline** (GitHub run 45826414969 via `gh run view --json`/`--log`; CloudTrail `lookup-events`)

| Time (UTC) | Event |
|---|---|
| 13:09:31 | PR #3 merged (merge commit `46df2c3`); CD run 45826414969 created |
| 13:09:41.678 | `configure-aws-credentials` attempt 1: "Not authorized to perform sts:AssumeRoleWithWebIdentity" |
| 13:11:07.935 | Attempt 12 failed: "reached max retries (12); giving up" |
| 13:11:10 | Run concluded `failure`; build, scan, push, and deploy steps all skipped |
| after 13:11 | Diagnosis (read-only): live trust policy vs. repo OIDC settings vs. CloudTrail |
| before 13:17:38 | Fix applied: `terraform apply` (1 in-place change, trust policy `sub`), confirmed with `aws iam get-role` |
| 13:17 | Run 45826414969 deleted (its log exposed the account ID, see below) |

**Root cause.** The repo has GitHub's **immutable OIDC subject** turned on (`gh api repos/Zeeqie/guarded-deploy/actions/oidc/customization/sub` → `"use_immutable_subject": true`), so the token's `sub` was:

```
repo:Zeeqie@260482962/guarded-deploy@1431477050:ref:refs/heads/main   <- sent (CloudTrail principalId, errorCode AccessDenied)
repo:Zeeqie/guarded-deploy:ref:refs/heads/main                        <- trust policy required
```

The Day 2 trust policy assumed the classic `sub` format without checking this repo's setting. `StringEquals` did exactly its job and rejected the mismatch.

**Fix.** The trust policy's `sub` is now the exact claim from CloudTrail, still `StringEquals`, with `aud` unchanged (`infra/github_oidc.tf`, variable `github_oidc_subject_repo`).

**Secondary finding: account ID in a public log.** The action echoes its `with:` inputs before `mask-aws-account-id` can take effect, and `role-to-assume` came from a repo *variable*, which is not masked. Fix: the role ARN moved to a repo **secret** (prints as `***`), and the failed run was deleted. Every later account-ID appearance (docker login/push, trivy, aws errors) comes after the mask is registered.

**Lessons**
- Check `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` before writing any OIDC trust policy; don't assume the default `sub` format.
- Failing closed works: a bad trust policy cost one red run and zero user impact. The pipeline never had credentials it shouldn't have had.
- CloudTrail records the *rejected* claim (`userIdentity.principalId` on the `AccessDenied` `AssumeRoleWithWebIdentity` event). That's the fastest way to debug OIDC, faster than guessing claim formats.
- Anything a step echoes before masking is public on a public repo. Identifiers that reveal the account go in secrets.
