# Index digest of public.ecr.aws/lambda/python:3.12 (multi-arch; Docker picks linux/arm64 on this host).
# Resolved with: docker buildx imagetools inspect public.ecr.aws/lambda/python:3.12
ARG BASE=public.ecr.aws/lambda/python:3.12@sha256:25aee9bac65f131c5d090d3e3a36ccf232d65cf3e6c1dbd0bffd43ca7ce34406
# AL2023 repos are frozen per release; pinning --releasever keeps the patched OS reproducible.
ARG AL2023_RELEASE=2023.12.20261026

# --- build stage: install runtime deps only (no dev tools reach the final image) ---
FROM ${BASE} AS build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --target /deps

# --- patched base: AWS base image + OS security updates from one exact AL2023 release ---
FROM ${BASE} AS patched
ARG AL2023_RELEASE
RUN dnf -y upgrade --refresh --releasever=${AL2023_RELEASE} \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# --- local: app on the Lambda base with the Runtime Interface Emulator, for local testing ---
FROM patched AS local
COPY --from=build /deps ${LAMBDA_TASK_ROOT}
COPY app ${LAMBDA_TASK_ROOT}/app

# Stamped at build time so /health can report which release is live.
ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA}

CMD ["app.main.handler"]

# --- prod (default target): what CI scans and what gets deployed ---
FROM local AS prod
# Real Lambda never runs the emulator; scan exactly what we ship.
RUN rm -f /usr/local/bin/aws-lambda-rie
USER 1000
