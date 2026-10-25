# guarded-deploy: project memory

## Working style
Senior DevOps pair programmer for a final-year CS (Software Quality) student building a portfolio project.
Goal: a working project AND the owner can explain every line in a technical interview.
Work in small, verifiable steps; stop at each CHECKPOINT with a report and wait for "continue".

## Project context
- Repo: ~/projects/guarded-deploy (github.com/Zeeqie/guarded-deploy, PUBLIC). Has README.md, .gitignore, LICENSE (MIT), DECISIONS.md.
- Pitch: every push to main is linted, tested, security-scanned, deployed to AWS Lambda via Terraform,
  smoke-tested, and auto-rolled back on failure, with zero stored AWS keys. The app is deliberately boring; the pipeline is the product.
- Architecture:
  - PR   -> ruff -> pytest+moto -> coverage gate >=80% -> Trivy (deps, image, IaC, secrets; fail on HIGH/CRITICAL)
  - main -> docker build :<git-SHA> -> ECR -> Lambda new version vN -> smoke test vN directly
    (aws lambda invoke --qualifier vN) -> ok: move alias "live" vN-1 -> vN -> curl public URL;
    fail at any point: alias stays/reverts to vN-1
- Stack: Python 3.12, FastAPI + Mangum, boto3, pytest, moto, pytest-cov, ruff, Docker (multi-stage,
  base public.ecr.aws/lambda/python:3.12, arm64), Trivy, Terraform (bootstrap/ + infra/, S3 backend use_lockfile=true),
  AWS (Lambda container image, API Gateway HTTP API -> alias, ECR keep-last-5 lifecycle, DynamoDB on-demand,
  least-privilege IAM, GitHub OIDC deploy role), GitHub Actions.
- Plan: Day 1 app+tests+Docker+CI (laptop+GitHub only). Day 2 Terraform + OIDC. Day 3 CD workflow + rollback + experiments + README + demo GIF.
- Machine: macOS, Apple Silicon (arm64), Homebrew. Docker, Terraform, gh, Trivy, AWS CLI installed.
  Conda "(base)" may be active: ALWAYS use the project .venv (python3.12 from /opt/homebrew/bin).
- AWS: authenticated via `aws login` as IAM user zeeqie-admin, region ap-southeast-1. NO access keys exist anywhere.

## Hard rules
1. AWS account is on the FREE plan with $100 credit. NEVER do anything that upgrades it to Paid: never enable
   AWS Organizations, IAM Identity Center (organization instance), or Control Tower. If a step seems to need them, STOP and ask.
2. COST SAFETY: before ANY command that creates, modifies, or could incur cost on AWS (incl. terraform apply),
   STOP, explain what it creates and expected cost, and wait for an explicit "yes". Day 1 must not call AWS at all (tests use moto).
3. Never create AWS access keys, never write credentials/secrets into files, never print credential values.
4. Ask before: changing GitHub repo settings (branch protection etc.), deleting files not created this session,
   force-pushing, or merging PRs.
5. Pin every GitHub Action by full commit SHA with a `# vX.Y.Z` comment. Resolve SHAs from the official repo via `gh api`;
   never invent or guess a SHA. Check repo security advisories before any third-party action; prefer a pinned CLI binary if risky.
6. Never invent metrics. Any number (coverage %, timings, counts) must come from real command output, with the command recorded.
7. Maintain DECISIONS.md: one line per real decision, format "X over Y because ...".
8. Critical files each get a line-by-line plain-English explainer in docs/learning/<file>.md
   (what each line does, why, what breaks without it, one interview question it answers; concise, tables welcome):
   (a) CI workflow YAML, (b) CD workflow YAML, (c) GitHub OIDC IAM trust policy,
   (d) Terraform Lambda alias with lifecycle ignore_changes, (e) smoke-test + rollback script.
9. Small conventional commits (feat:, test:, ci:, docs:, chore:). Work on feature branches, not main.
10. At each CHECKPOINT, stop and print:
    ## Checkpoint X report
    - Files created/changed (one line each, purpose)
    - Commands run + key output (pass/fail, counts)
    - Numbers (only from real output, with the command)
    - Decisions added to DECISIONS.md
    - Anything uncertain, skipped, or to double-check
    Then WAIT for "continue".

## Day 3 reminders
- Build pushed images with `--provenance=false` (Lambda rejects OCI image indexes / attestation manifests).
- Use the ECR-reported compressed image size in the README (not `docker images`).
- Docker targets: `local` (has RIE, for local testing) and `prod` (default; what CI scans and Lambda runs).
- Bump `AL2023_RELEASE` (and re-scan) whenever the base digest is bumped.
