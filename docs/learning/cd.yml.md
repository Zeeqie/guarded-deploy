# `.github/workflows/cd.yml` explained

Runs on every push to `main` (i.e. every merged PR). It builds the image once per commit, gates it with Trivy, pushes it to ECR, then hands off to [`scripts/deploy.sh`](deploy.sh.md), which does the smoke test, the traffic shift, and the rollback.

```
push to main ─> OIDC assume role ─> ECR login ─> tag exists? ──yes──────────────┐
                                                   │ no                         │
                                                   └> build ─> trivy ─> push ───┴─> deploy.sh
```

It deliberately does **not** run Terraform (that is applied from the laptop) and does **not** use a GitHub `environment:`.

## Triggers, permissions, concurrency, env

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `on: push: branches: [main]` | Run after every merge to main | Main is protected by CI, so only reviewed, green code gets here | Nothing deploys automatically | "What triggers a production deploy?" |
| `workflow_dispatch` + `inputs.inject_live_check_failure` (boolean, default false) | Manual "Run workflow" button with a fault-injection checkbox | Lets me prove the rollback path on demand without shipping a broken app | Rollback only ever runs during a real incident, i.e. untested | "How do you know your rollback actually works?" |
| `permissions: id-token: write` | Lets the job request a GitHub OIDC token | AWS STS exchanges that signed token for 1-hour role credentials | `configure-aws-credentials` can't get a token; no AWS access | "How does GitHub authenticate to AWS without stored keys?" |
| `permissions: contents: read` | Read-only `GITHUB_TOKEN` | Least privilege; the job never writes to the repo | Token might be broader than needed | — |
| `concurrency: group: cd-main` | At most one deploy runs at a time; the next one queues | Two deploys reading the same `PREV` and moving the same alias would race | Deploy A rolls back to a version deploy B already replaced | "How do you stop two deploys colliding?" |
| `cancel-in-progress: false` | A newer push waits instead of cancelling the running deploy | Cancelling between "alias moved" and "live check" leaves unverified code live with no rollback | Half-finished deploys | "Why not cancel superseded deploys like CI does?" |
| `env: AWS_REGION / FUNCTION_NAME / ECR_REPOSITORY` | Non-secret names in one place | Read by steps and by `deploy.sh` | Names duplicated and drifting | — |
| `env: TRIVY_VERSION / TRIVY_SHA256` | Same pinned scanner and checksum as `ci.yml` | What CI approved and what CD gates use the same scanner | CD could scan with a different version | — |

## The job

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `if: github.ref == 'refs/heads/main'` | Skips the job if dispatched from another branch | Clear skip instead of a confusing AccessDenied; the trust policy only accepts `ref:refs/heads/main` anyway | A red run with an STS error | "What stops a feature branch from deploying?" (answer: the trust policy; this line just makes it obvious) |
| no `environment:` key | — | An environment changes the OIDC `sub` to `repo:…:environment:<name>`, which the trust policy rejects | Every deploy fails at assume-role | "Why no GitHub environment?" |
| `runs-on: ubuntu-24.04-arm` | Native arm64 runner | Image is arm64 (Lambda arm64), built without emulation | Slow QEMU builds, or an amd64 image Lambda refuses | — |
| `timeout-minutes: 30` | Kills a hung run | Bounded runner minutes | A hang holds the `cd-main` queue | — |
| `actions/checkout@<sha> # v7.0.1`, `persist-credentials: false` | Clone the commit; no token left in `.git/config` | Same pinning rule as CI | — | — |
| "Tool versions" step | Prints aws, docker, jq, curl versions | Proves the runner has what `deploy.sh` needs instead of assuming | A missing tool shows up as a confusing failure later | — |
| `aws-actions/configure-aws-credentials@<sha> # v6.3.0` | OIDC token → `AssumeRoleWithWebIdentity` → exports temp creds for later steps | AWS-maintained, masks credentials in logs; no advisories when checked. v6.3.0 over v6.3.1 (released 1 day earlier, proxy-only fix) for soak time | No AWS credentials | "Where are your AWS keys?" (answer: there are none) |
| `role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}` | Role ARN comes from a repo **variable** | A role ARN is an identifier, not a credential; a variable keeps the account ID out of the code | Hardcoded account ID in a public repo | "Is the role ARN a secret?" |
| `role-session-name: cd-<run_id>-<attempt>` | Names the STS session | CloudTrail shows which workflow run did what | Generic session names in audit logs | "How would you trace an AWS change back to a pipeline run?" |
| `mask-aws-account-id: true` | Masks the account ID in logs | Public repo = public logs | Account ID visible to everyone | — |
| ECR login step | `get-caller-identity` → registry host; `get-login-password \| docker login --password-stdin` | aws CLI over a third-party login action. The password goes through a pipe, never an argument or log line. `::add-mask::` hides the account ID | Push fails: unauthenticated | "How does Docker authenticate to ECR?" |
| `image_uri=…:${GITHUB_SHA}` output | The full 40-char SHA is the tag | One commit = one immutable, traceable image | Ambiguous `:latest` deploys | "How do you map a running Lambda to a commit?" |
| "Does this SHA's image already exist?" | `describe-images --image-ids imageTag=<sha>` | Tags are IMMUTABLE, so re-running a deploy would fail at push; skip build/scan/push instead | Re-runs fail with `ImageTagAlreadyExistsException` | "Is your pipeline idempotent?" |
| `grep ImageNotFoundException` branch | Only "not found" means build; any other error fails | AccessDenied must not be read as "doesn't exist" | Hides permission errors | — |
| Install Trivy step | Tarball + `sha256sum -c` (same as CI) | Pinned binary instead of `aquasecurity/trivy-action` (GHSA-69fq-xp46-6x23) | Unverified scanner binary | — |
| `docker build --target prod --platform linux/arm64` | Builds the shipped stage for arm64 | `prod` has no RIE and runs as `USER 1000`; this is what CI scanned | Could ship the `local` stage | — |
| `--provenance=false --sbom=false` | Single-platform image manifest, no attestation index | Lambda rejects OCI image indexes / attestation manifests | `UpdateFunctionCode` fails: unsupported media type | "Why disable provenance?" |
| `--build-arg GIT_SHA="$GITHUB_SHA"` | Bakes the SHA into the image `ENV` | `/health` reports it; the smoke test and live check compare it | Can't prove which build is serving | — |
| `trivy image … --exit-code 1` before `docker push` | Blocks HIGH/CRITICAL vulns from reaching ECR | The registry only holds images that passed | A vulnerable image is pushed and deployed | "Where in the pipeline do you scan, and why there?" |
| `${{ … }}` only inside `env:` blocks | Values reach scripts as env vars | Avoids script injection from expression expansion inside `run:` | Untrusted text could become shell code | "What is GitHub Actions script injection?" |
| `INJECT_LIVE_CHECK_FAILURE: ${{ github.event_name == 'workflow_dispatch' && inputs.inject_live_check_failure }}` | `false` on push; checkbox value on manual runs | A push can never inject a fault | — | — |
| `API_URL: ${{ vars.API_URL }}` | Public base URL for the live check | The deploy role has no API Gateway read permission, so it can't look it up | Live check has nowhere to curl | — |
| `run: scripts/deploy.sh` | Smoke → alias → live check → rollback | Logic lives in a script that is shellchecked and tested offline | — | See [deploy.sh.md](deploy.sh.md) |

## Repo variables this workflow needs (set once, not secrets)

`AWS_DEPLOY_ROLE_ARN` (Terraform output `deploy_role_arn`) and `API_URL` (Terraform output `api_url`).
