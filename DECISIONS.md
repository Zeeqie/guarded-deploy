# Decisions

One line per decision: X over Y because...

- arm64 Lambda + ubuntu-24.04-arm runners over amd64 because my Mac is Apple Silicon: native builds everywhere, ~20% cheaper Lambda, no emulation. Trade-off: repo must stay public for free ARM runners.
- aws login (IAM user, console creds -> 15-min rotating creds) over IAM Identity Center because Identity Center requires AWS Organizations, which force-upgrades a Free plan account to Paid and voids the $100 credit. Same outcome: zero long-lived keys on my laptop.
- venv + pinned requirements.txt over Poetry/uv because fewer moving parts, the Lambda image installs requirements.txt directly, and Trivy scans pinned versions.
