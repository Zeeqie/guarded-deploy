# Decisions

One line per decision: X over Y because...

- arm64 Lambda + ubuntu-24.04-arm runners over amd64 because my Mac is Apple Silicon: native builds everywhere, ~20% cheaper Lambda, no emulation. Trade-off: repo must stay public for free ARM runners.
- aws login (IAM user, console creds -> 15-min rotating creds) over IAM Identity Center because Identity Center requires AWS Organizations, which force-upgrades a Free plan account to Paid and voids the $100 credit. Same outcome: zero long-lived keys on my laptop.
- venv + pinned requirements.txt over Poetry/uv because fewer moving parts, the Lambda image installs requirements.txt directly, and Trivy scans pinned versions.
- pip-tools compiled lockfiles over direct-only pins because Trivy fs only sees versions written in requirements.txt, so transitive CVEs (e.g. starlette) would be invisible; hashes deferred to keep Day 1 simple.
- Multi-stage build with `pip install --target` over a single-stage image because only runtime deps (requirements.txt) land in the final image; dev tools and pip cache never ship.
- Base image pinned by multi-arch index digest over the floating :3.12 tag because rebuilds are reproducible and Trivy results are attributable to a known base; trade-off: we must bump the digest to receive AWS base patches.
- `USER 1000` in the Dockerfile over leaving root because Trivy flags root images (DS002) and least privilege is the right default. In real Lambda the platform runs the function as its own unprivileged sandbox user regardless (I have not verified in AWS docs whether it honours USER; files are world-readable so either works), so USER only matters for local/RIE runs.
