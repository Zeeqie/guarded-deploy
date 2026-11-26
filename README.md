# guarded-deploy

## Limitations

- ECR keeps the 10 most recently pushed images. Failed deploys count too, so manual rollback is safe up to 9 versions back only if every pushed image went live. Automatic rollback is always 1 step (to the previous live version).
- `AL2023_RELEASE` in the Dockerfile must be bumped by hand (and the image re-scanned) to pick up OS security patches.
