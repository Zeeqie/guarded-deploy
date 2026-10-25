# Index digest of public.ecr.aws/lambda/python:3.12 (multi-arch; Docker picks linux/arm64 on this host).
# Resolved with: docker buildx imagetools inspect public.ecr.aws/lambda/python:3.12
ARG BASE=public.ecr.aws/lambda/python:3.12@sha256:25aee9bac65f131c5d090d3e3a36ccf232d65cf3e6c1dbd0bffd43ca7ce34406

# --- build stage: install runtime deps only (no dev tools reach the final image) ---
FROM ${BASE} AS build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --target /deps

# --- final stage ---
FROM ${BASE}
COPY --from=build /deps ${LAMBDA_TASK_ROOT}
COPY app ${LAMBDA_TASK_ROOT}/app

# Stamped at build time so /health can report which release is live.
ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA}

USER 1000
CMD ["app.main.handler"]
