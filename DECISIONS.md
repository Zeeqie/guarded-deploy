# Decisions

One line per decision: X over Y because...

- arm64 Lambda + ubuntu-24.04-arm runners over amd64 because my Mac is Apple Silicon: native builds everywhere, ~20% cheaper Lambda, no emulation. Trade-off: repo must stay public for free ARM runners.
- aws login (IAM user, console creds -> 15-min rotating creds) over IAM Identity Center because Identity Center requires AWS Organizations, which force-upgrades a Free plan account to Paid and voids the $100 credit. Same outcome: zero long-lived keys on my laptop.
- venv + pinned requirements.txt over Poetry/uv because fewer moving parts, the Lambda image installs requirements.txt directly, and Trivy scans pinned versions.
- pip-tools compiled lockfiles over direct-only pins because Trivy fs only sees versions written in requirements.txt, so transitive CVEs (e.g. starlette) would be invisible; hashes deferred to keep Day 1 simple.
- Multi-stage build with `pip install --target` over a single-stage image because only runtime deps (requirements.txt) land in the final image; dev tools and pip cache never ship.
- Base image pinned by multi-arch index digest over the floating :3.12 tag because rebuilds are reproducible and Trivy results are attributable to a known base; trade-off: we must bump the digest to receive AWS base patches.
- `USER 1000` in the prod stage over leaving root because Trivy flags root images (DS002) and least privilege is the right default. Verified: Lambda docs say it runs functions as "a default Linux user with least-privileged permissions" and that "you don't need to specify a USER in your Dockerfile", but the files must be readable by that user (https://docs.aws.amazon.com/lambda/latest/dg/images-create.html). Unverified: whether Lambda honours or ignores the Dockerfile USER at runtime; the docs don't say, so USER here mainly affects local runs.
- Strip RIE from the prod image over ignoring its CVE because real Lambda never runs it; scan exactly what we ship.
- `dnf upgrade --releasever=<exact AL2023 release>` in the image over shipping the AWS base as-is because the pinned base had 43 HIGH OS CVEs (curl, libcap, openssl, pcre2, rpm) already fixed in a later AL2023 release (2023.12.20261026 -> 0 HIGH; 2023.12.20261021 still left 13). Trade-off: we diverge from AWS's exact tested base and the image is ~11.7 MB bigger (inspect.Size), but it is patched and reproducible because the release version is pinned, not "latest".
