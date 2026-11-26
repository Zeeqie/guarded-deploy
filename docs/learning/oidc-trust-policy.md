# GitHub OIDC trust policy explained (`infra/github_oidc.tf`)

GitHub Actions gets **temporary** AWS credentials with no stored keys. On each run, GitHub signs a short-lived JWT describing the job (repo, branch, ...). AWS STS checks the signature and the claims against this trust policy, then returns ~1-hour credentials for the deploy role.

```
GitHub job --(signed JWT: aud, sub=repo:Zeeqie/guarded-deploy:ref:refs/heads/main)--> STS
STS: signature valid? aud ok? sub ok? --> temporary creds for guarded-deploy-github-deploy
```

## The identity provider

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `url = "https://token.actions.githubusercontent.com"` | Registers GitHub's token issuer with IAM | AWS only trusts JWTs from issuers it knows | `AssumeRoleWithWebIdentity` fails: unknown provider | "How does AWS know a token really came from GitHub?" |
| `client_id_list = ["sts.amazonaws.com"]` | Accepted audience(s) for tokens from this issuer | `aws-actions/configure-aws-credentials` requests tokens with `aud=sts.amazonaws.com` | Tokens rejected: audience mismatch | — |
| `thumbprint_list` omitted | No TLS cert pin stored | IAM verifies this IdP against its library of trusted root CAs; thumbprints are a fallback. Optional in provider 6.74.0 (checked with `terraform providers schema`) | Nothing; a pinned thumbprint goes stale when GitHub rotates certs | "Do you still need an OIDC thumbprint?" |

## The trust policy (who may assume the role)

| Line | What it does | Why | What breaks without it | Interview question it answers |
|---|---|---|---|---|
| `actions = ["sts:AssumeRoleWithWebIdentity"]` | The only way to assume this role is with a web-identity (OIDC) token | No IAM user or access key can use this role | — | "Why OIDC instead of access keys in GitHub secrets?" |
| `principals { type = "Federated", identifiers = [provider ARN] }` | Only tokens from *this* registered GitHub provider count | Ties trust to GitHub's issuer, not "anyone" | Policy is invalid without a principal | — |
| `StringEquals ...:aud = "sts.amazonaws.com"` | Token must be minted for AWS STS | Stops tokens minted for another service being replayed here | Weaker: any GitHub token audience could work | — |
| `StringEquals ...:sub = "repo:Zeeqie/guarded-deploy:ref:refs/heads/main"` | Token must come from **this repo, main branch** | The `sub` claim is what scopes trust. GitHub's issuer is shared by *every* GitHub repo | **Critical:** without it, any GitHub repo in the world could assume this role | "What is the most common OIDC misconfiguration?" (a missing or wildcard `sub`) |
| `StringEquals`, not `StringLike` | Exact match, no wildcards | `repo:Zeeqie/*` or `ref:*` would also allow PR branches and forks of the trust | Feature branches or PRs could deploy | "How would you let PR jobs plan but not deploy?" (separate read-only role with its own `sub`) |
| `max_session_duration = 3600` | Credentials last at most 1 hour | A deploy takes minutes; less lifetime means less value if leaked | Default is also 1h; set explicitly as documentation | — |

**Gotcha:** if the CD job uses a GitHub `environment:`, the `sub` becomes `repo:Zeeqie/guarded-deploy:environment:<name>` and this policy rejects it. Change `sub` to match.

## Deploy role permissions (what the role may do)

| Statement | Resource | Why this scope |
|---|---|---|
| `ecr:GetAuthorizationToken` | `"*"` | AWS does not support resource-level permissions for this action: `"*"` is the only valid value. It only returns a registry login; push/pull rights come from the next statement |
| ECR push/pull + `DescribeImages` | this repo ARN only | Push layers and the image; `DescribeImages` lets the pipeline check if tag `<sha>` exists first (tags are IMMUTABLE, so a re-push would fail) |
| Lambda `UpdateFunctionCode`, `PublishVersion`, `GetFunction`, `GetAlias`, `UpdateAlias`, `InvokeFunction`, `ListVersionsByFunction` | this function ARN + `:*` (its versions and alias) | Exactly the deploy → smoke test → promote/rollback loop. No `iam:*`, no wildcard actions, no other functions |
