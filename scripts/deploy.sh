#!/usr/bin/env bash
# Deploy one image to Lambda, gated by a pre-traffic smoke test and a post-traffic live
# check, with automatic rollback of alias "live". Explained in docs/learning/deploy.sh.md.
#
# Required env: FUNCTION_NAME, IMAGE_URI, GIT_SHA, API_URL (plus AWS creds + AWS_REGION).
# Optional env: ALIAS (default live), INJECT_LIVE_CHECK_FAILURE (default false).
# Needs GNU date (%N), curl, jq, aws CLI v2: i.e. the ubuntu runner, not stock macOS.
set -euo pipefail

: "${FUNCTION_NAME:?}" "${IMAGE_URI:?}" "${GIT_SHA:?}" "${API_URL:?}"
ALIAS="${ALIAS:-live}"
INJECT_LIVE_CHECK_FAILURE="${INJECT_LIVE_CHECK_FAILURE:-false}"
API_URL="${API_URL%/}" # $default stage URL ends in "/"; avoid "//health"

LIVE_CHECK_ATTEMPTS=5
LIVE_CHECK_SLEEP_SECONDS="${LIVE_CHECK_SLEEP_SECONDS:-2}" # tests set 0
WRONG_SHA="0000000000000000000000000000000000000000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_EVENT="${SCRIPT_DIR}/events/health.json"
WORK_DIR="$(mktemp -d)"

PREV=""
NEW=""
ALIAS_STATE="untouched" # untouched -> moved -> verified | reverted | rollback_failed
# Epoch-ms timestamps set by metric(); declared so they exist even if never reached.
METRIC_deploy_started_at=""
METRIC_live_check_failed_at=""
METRIC_alias_reverted_at=""
METRIC_live_check_passed_at=""

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }
epoch_ms() { date -u +%s%3N; }
metric() { # METRIC <name>_at=<epoch ms>  (grep "^METRIC" in the job log)
  local name="$1" value
  value="$(epoch_ms)"
  printf -v "METRIC_${name}" '%s' "$value"
  printf 'METRIC %s=%s\n' "$name" "$value"
}

alias_version() {
  aws lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" \
    --query FunctionVersion --output text
}

rollback() {
  log "ROLLBACK: moving alias ${ALIAS} back to version ${PREV}"
  aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" \
    --function-version "$PREV" --output text --query FunctionVersion >/dev/null
  local now
  now="$(alias_version)"
  if [[ "$now" != "$PREV" ]]; then
    ALIAS_STATE="rollback_failed" # stops on_exit from retrying; a human must look
    log "ROLLBACK_VERIFY_FAILED: alias ${ALIAS} is ${now}, expected ${PREV}"
    exit 2
  fi
  ALIAS_STATE="reverted"
  metric alias_reverted_at
  log "ALIAS_REVERTED: ${ALIAS} -> ${PREV} (verified with get-alias)"
  if [[ -n "${METRIC_live_check_failed_at:-}" ]]; then
    printf 'METRIC rollback_duration_ms=%s\n' \
      "$((METRIC_alias_reverted_at - METRIC_live_check_failed_at))"
  fi
}

on_exit() {
  local rc=$?
  # Safety net: any unexpected failure after traffic moved must not leave NEW live.
  if [[ "$rc" -ne 0 && "$ALIAS_STATE" == "moved" ]]; then
    log "UNEXPECTED_FAILURE (exit ${rc}) after alias move: rolling back"
    rollback || log "ROLLBACK_FAILED: check alias ${ALIAS} manually"
  fi
  rm -rf "$WORK_DIR"
  log "EXIT code=${rc} alias_state=${ALIAS_STATE} prev=${PREV:-?} new=${NEW:-?}"
  exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------------------
metric deploy_started_at
log "DEPLOY_START function=${FUNCTION_NAME} alias=${ALIAS} image=${IMAGE_URI##*/}"

# a. Where is traffic right now? This is the rollback target.
PREV="$(alias_version)"
log "PREV: alias ${ALIAS} -> version ${PREV}"

# g. Same SHA re-run: if live already runs this exact image, change nothing at all.
live_image="$(aws lambda get-function --function-name "$FUNCTION_NAME" --qualifier "$ALIAS" \
  --query Code.ImageUri --output text)"
if [[ "$live_image" == "$IMAGE_URI" ]]; then
  log "NO_CHANGE: alias ${ALIAS} (version ${PREV}) already runs ${IMAGE_URI##*/}"
  exit 0
fi

# b. Point $LATEST at the new image and publish an immutable version from it.
# Wait first: UpdateFunctionCode is rejected while a previous update is still in progress.
aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
NEW="$(aws lambda update-function-code --function-name "$FUNCTION_NAME" \
  --image-uri "$IMAGE_URI" --publish --query Version --output text)"
if [[ ! "$NEW" =~ ^[0-9]+$ ]]; then
  log "PUBLISH_FAILED: expected a numbered version, got '${NEW}'"
  exit 1
fi
log "PUBLISHED: version ${NEW}; waiting for it to be ready"
aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --qualifier "$NEW"
metric version_active_at
log "ACTIVE: version ${NEW}"

# g (second guard). Lambda doesn't publish a version if code+config are unchanged.
if [[ "$NEW" == "$PREV" ]]; then
  log "NO_CHANGE: alias ${ALIAS} already on version ${NEW}; nothing to deploy"
  exit 0
fi

# c. Pre-traffic smoke test: invoke version NEW directly; the public URL still serves PREV.
log "SMOKE_START: invoking version ${NEW} directly with ${SMOKE_EVENT##*/}"
invoke_meta="$(aws lambda invoke --function-name "$FUNCTION_NAME" --qualifier "$NEW" \
  --cli-binary-format raw-in-base64-out --payload "fileb://${SMOKE_EVENT}" \
  --output json "${WORK_DIR}/smoke.json")"
function_error="$(jq -r '.FunctionError // empty' <<<"$invoke_meta")"
smoke_status="$(jq -r '.statusCode // empty' "${WORK_DIR}/smoke.json" 2>/dev/null || true)"
smoke_version="$(jq -r '.body | fromjson | .version // empty' "${WORK_DIR}/smoke.json" \
  2>/dev/null || true)"
log "SMOKE_RESULT: function_error=${function_error:-none} status=${smoke_status:-?} version=${smoke_version:-?}"
if [[ -n "$function_error" || "$smoke_status" != "200" || "$smoke_version" != "$GIT_SHA" ]]; then
  metric smoke_failed_at
  log "SMOKE_FAIL: version ${NEW} not promoted; alias ${ALIAS} untouched on ${PREV}"
  exit 1
fi
metric smoke_passed_at
log "SMOKE_PASS: version ${NEW} reports ${GIT_SHA}"

# d. Shift traffic.
aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" \
  --function-version "$NEW" --output text --query FunctionVersion >/dev/null
ALIAS_STATE="moved"
metric alias_moved_at
log "ALIAS_MOVED: ${ALIAS} ${PREV} -> ${NEW}"

# e. Post-traffic live check through the real public path (API Gateway -> alias).
expected="$GIT_SHA"
if [[ "$INJECT_LIVE_CHECK_FAILURE" == "true" ]]; then
  expected="$WRONG_SHA"
  log "!!!!!!!! FAULT_INJECTION: live check will expect ${WRONG_SHA} so it MUST fail !!!!!!!!"
  log "!!!!!!!! FAULT_INJECTION: this run exists to prove automatic rollback works   !!!!!!!!"
fi

live_ok=false
for attempt in $(seq 1 "$LIVE_CHECK_ATTEMPTS"); do
  rm -f "${WORK_DIR}/live.json"
  code="$(curl -sS --max-time 5 -o "${WORK_DIR}/live.json" -w '%{http_code}' \
    "${API_URL}/health" || true)"
  live_version="$(jq -r '.version // empty' "${WORK_DIR}/live.json" 2>/dev/null || true)"
  log "LIVE_CHECK attempt=${attempt}/${LIVE_CHECK_ATTEMPTS} status=${code:-none} version=${live_version:-?} expected=${expected}"
  if [[ "$code" == "200" && "$live_version" == "$expected" ]]; then
    live_ok=true
    break
  fi
  if [[ "$attempt" -lt "$LIVE_CHECK_ATTEMPTS" ]]; then
    sleep "$LIVE_CHECK_SLEEP_SECONDS"
  fi
done

# f. Roll back on failure; the run goes red either way.
if [[ "$live_ok" != "true" ]]; then
  metric live_check_failed_at
  log "LIVE_CHECK_FAILED: rolling back"
  rollback
  exit 1
fi

ALIAS_STATE="verified"
metric live_check_passed_at
printf 'METRIC deploy_duration_ms=%s\n' "$((METRIC_live_check_passed_at - METRIC_deploy_started_at))"
log "DEPLOY_OK: ${ALIAS} -> version ${NEW} serving ${GIT_SHA}"
