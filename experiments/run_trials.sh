#!/usr/bin/env bash
# Checkpoint 3E trials (option A). Usage: experiments/run_trials.sh "L R L R ..." [first_n]
#
#   L = trivial PR, normal merge -> push-triggered CD deploys it   (one lead-time sample)
#   R = trivial PR, merge with "[skip ci]" -> confirm NO CD run started -> dispatch CD with
#       inject_live_check_failure=true on main -> alias moves to the new version, live check
#       is forced to fail, alias reverts to PREV                     (one rollback sample)
#
# Pre-checks before EVERY trial (abort on any surprise, never retry a failed trial):
#   AWS session valid; local main clean and == origin/main; no CD run queued/in progress and
#   the latest CD run concluded as the previous trial expected; live's image is among the 9
#   newest ECR images (this trial pushes 1 more, keep-last-10 must never evict live); live
#   /health version == the SHA we expect live to serve.
# Raw data per trial: $TRIALS_RAW_DIR/<NN>-<K>/, OUTSIDE the repo during the run (the clean-tree
# precheck would fail otherwise); copy to experiments/raw/trials/ afterwards. No account ID in it.
set -euo pipefail

PLAN="${1:?plan, e.g. \"L R L R L R L R L R L L L L L\"}"
FIRST_N="${2:-1}"
REPO="Zeeqie/guarded-deploy"
FN="guarded-deploy"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="${TRIALS_RAW_DIR:?set TRIALS_RAW_DIR to a directory outside the repo}"
STATE="${RAW}/expected_live_sha" # SHA live must serve before the next trial
cd "$ROOT"
case "$(cd "$(dirname "$RAW")" 2>/dev/null && pwd)/" in "${ROOT}/"*) echo "TRIALS_RAW_DIR must be outside the repo" >&2; exit 1 ;; esac

API_URL="$(gh variable get API_URL --repo "$REPO")"
API_URL="${API_URL%/}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" # never printed
mkdir -p "$RAW"

now() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"))'; }
log() { printf '%s [trial %s] %s\n' "$(now)" "${N:-?}" "$*"; }
die() {
  log "ABORT: $*"
  if [[ -n "${DIR:-}" ]]; then printf 'status=aborted\nreason=%s\n' "$*" >>"${DIR}/trial.env"; fi
  exit 1
}
health_version() { curl -sS --max-time 10 "${API_URL}/health" | jq -r .version; }
live_version() { aws lambda get-alias --function-name "$FN" --name live --query FunctionVersion --output text; }

# Poll a run until it completes (max $2 seconds); prints its conclusion.
wait_run() {
  local id="$1" max="$2" waited=0 status
  while :; do
    status="$(gh run view "$id" --repo "$REPO" --json status --jq .status)"
    [[ "$status" == "completed" ]] && break
    ((waited >= max)) && die "run $id still $status after ${max}s"
    sleep 10
    waited=$((waited + 10))
  done
  gh run view "$id" --repo "$REPO" --json conclusion --jq .conclusion
}

# First run of workflow $1 for commit $2 (and event $3), waiting up to $4 s for it to appear.
find_run() {
  local wf="$1" sha="$2" event="$3" max="$4" waited=0 id=""
  while [[ -z "$id" ]]; do
    id="$(gh run list --repo "$REPO" --workflow "$wf" --commit "$sha" --event "$event" \
      --json databaseId --jq '.[0].databaseId // empty')"
    [[ -n "$id" ]] && break
    ((waited >= max)) && return 1
    sleep 5
    waited=$((waited + 5))
  done
  echo "$id"
}

precheck() {
  aws sts get-caller-identity >/dev/null || die "AWS session invalid (run aws login)"
  git fetch -q origin main
  [[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "local main != origin/main"
  local busy
  busy="$(gh run list --repo "$REPO" --workflow CD --limit 20 --json status \
    --jq '[.[]|select(.status!="completed")]|length')"
  [[ "$busy" == "0" ]] || die "$busy CD run(s) not completed"
  local last
  last="$(gh run list --repo "$REPO" --workflow CD --limit 1 --json conclusion --jq '.[0].conclusion')"
  [[ "$last" == "${EXPECT_LAST_CD:-success}" ]] || die "latest CD run concluded '$last', expected '${EXPECT_LAST_CD:-success}'"
  local tag newest9
  tag="$(aws lambda get-function --function-name "$FN" --qualifier live --query Code.ImageUri --output text)"
  tag="${tag##*:}"
  newest9="$(aws ecr describe-images --repository-name "$FN" \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0:9][].imageTags[0]' --output text)"
  grep -qw "$tag" <<<"$newest9" || die "live image ${tag:0:7} not among the 9 newest ECR images"
  local hv
  hv="$(health_version)"
  [[ "$hv" == "$(cat "$STATE")" ]] || die "live /health serves ${hv:0:7}, expected $(cut -c1-7 "$STATE")"
  LIVE_BEFORE="$(live_version)"
  log "precheck ok: live v${LIVE_BEFORE} serves ${hv:0:7}, its image is in ECR's newest 9"
}

trivial_pr() { # creates, CI-gates and merges a one-line PR; sets MERGE_SHA, MERGE_COMMITTED, PR_URL
  local kind="$1"
  local branch="trial/${N}-${kind}" subject
  git switch -q -c "$branch" main
  mkdir -p experiments/trials
  printf 'trial %s %s %s\n' "$N" "$kind" "$(now)" >>experiments/trials/log.txt
  git add experiments/trials/log.txt
  git commit -qm "chore: experiment trial ${N} (${kind})" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  git push -q -u origin "$branch" 2>/dev/null
  PR_URL="$(gh pr create --repo "$REPO" --base main --head "$branch" \
    --title "chore: experiment trial ${N} (${kind})" \
    --body $'Checkpoint 3E trial (one-line change to experiments/trials/log.txt).\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)' | tail -1)"
  local head ci
  head="$(git rev-parse HEAD)"
  ci="$(find_run CI "$head" pull_request 120)" || die "no CI run for PR head"
  [[ "$(wait_run "$ci" 900)" == "success" ]] || die "PR CI not green (run $ci)"
  if [[ "$kind" == "R" ]]; then
    subject="chore: experiment trial ${N} (R) [skip ci]"
  else
    subject="chore: experiment trial ${N} (L)"
  fi
  gh pr merge "$PR_URL" --repo "$REPO" --merge --delete-branch --subject "$subject" >/dev/null
  git switch -q main
  git pull -q --ff-only origin main
  git branch -D "$branch" >/dev/null 2>&1 || true
  MERGE_SHA="$(git rev-parse HEAD)"
  MERGE_COMMITTED="$(git log -1 --format=%cI "$MERGE_SHA")"
  [[ "$(git log -1 --format=%s "$MERGE_SHA")" == "$subject" ]] || die "merge commit subject mismatch"
  printf 'pr_url=%s\nci_run=%s\nmerge_sha=%s\nmerge_committed=%s\n' \
    "$PR_URL" "$ci" "$MERGE_SHA" "$MERGE_COMMITTED" >>"${DIR}/trial.env"
  log "merged ${MERGE_SHA:0:7} at ${MERGE_COMMITTED} (${PR_URL##*/})"
}

save_cd() { # $1 run id
  gh run view "$1" --repo "$REPO" --json databaseId,url,event,headSha,conclusion,createdAt,updatedAt,jobs \
    >"${DIR}/cd-run.json"
  gh run view "$1" --repo "$REPO" --log |
    awk -F'\t' 'index($2,"Deploy (smoke")==1{sub(/^\xef\xbb\xbf/,"",$3); sub(/^[0-9T:.\-]+Z /,"",$3); print $3}' |
    grep -E '^(METRIC|20[0-9]{2}-)' >"${DIR}/deploy-sh.log" || true
  if grep -rq "$ACCOUNT" "$DIR"; then die "account ID found in raw files"; fi
}

[[ -f "$STATE" ]] || health_version >"$STATE"
EXPECT_LAST_CD=success
N=$((FIRST_N - 1))
for KIND in $PLAN; do
  N=$((N + 1))
  NN="$(printf '%02d' "$N")"
  DIR="${RAW}/${NN}-${KIND}"
  [[ -e "$DIR" ]] && die "${DIR} already exists (never re-run a trial)"
  mkdir -p "$DIR"
  printf 'n=%s\nkind=%s\nstarted=%s\n' "$N" "$KIND" "$(now)" >"${DIR}/trial.env"
  precheck
  printf 'live_before=%s\n' "$LIVE_BEFORE" >>"${DIR}/trial.env"

  case "$KIND" in
  L)
    trivial_pr L
    cd_run="$(find_run CD "$MERGE_SHA" push 120)" || die "no push-triggered CD run for ${MERGE_SHA:0:7}"
    printf 'cd_run=%s\n' "$cd_run" >>"${DIR}/trial.env"
    concl="$(wait_run "$cd_run" 900)"
    save_cd "$cd_run"
    [[ "$concl" == "success" ]] || die "CD concluded $concl"
    grep -q "DEPLOY_OK" "${DIR}/deploy-sh.log" || die "no DEPLOY_OK"
    hv="$(health_version)"
    printf 'live_after=%s\nhealth_after=%s\n' "$(live_version)" "$hv" >>"${DIR}/trial.env"
    [[ "$hv" == "$MERGE_SHA" ]] || die "/health ${hv:0:7} != merge ${MERGE_SHA:0:7}"
    echo "$MERGE_SHA" >"$STATE"
    EXPECT_LAST_CD=success
    ;;
  R)
    trivial_pr R
    sleep 45 # give GitHub time to (not) start a push run
    if pushed="$(find_run CD "$MERGE_SHA" push 15)"; then
      die "[skip ci] merge DID trigger CD run ${pushed}"
    fi
    printf 'skip_ci_confirmed=no push-triggered CD run 60s after merge\n' >>"${DIR}/trial.env"
    log "[skip ci] confirmed: no push-triggered CD run for ${MERGE_SHA:0:7}"
    gh workflow run cd.yml --repo "$REPO" --ref main -f inject_live_check_failure=true
    cd_run="$(find_run CD "$MERGE_SHA" workflow_dispatch 120)" || die "dispatch run not found"
    printf 'cd_run=%s\n' "$cd_run" >>"${DIR}/trial.env"
    concl="$(wait_run "$cd_run" 900)"
    save_cd "$cd_run"
    [[ "$concl" == "failure" ]] || die "injected run concluded $concl (expected failure)"
    grep -q "ALIAS_REVERTED" "${DIR}/deploy-sh.log" || die "no ALIAS_REVERTED"
    grep -q "alias_state=reverted prev=${LIVE_BEFORE} " "${DIR}/deploy-sh.log" || die "EXIT line not reverted to ${LIVE_BEFORE}"
    la="$(live_version)"
    hv="$(health_version)"
    printf 'live_after=%s\nhealth_after=%s\n' "$la" "$hv" >>"${DIR}/trial.env"
    [[ "$la" == "$LIVE_BEFORE" ]] || die "alias v${la} != PREV v${LIVE_BEFORE}"
    [[ "$hv" == "$(cat "$STATE")" ]] || die "/health ${hv:0:7} != previous live"
    EXPECT_LAST_CD=failure # the injected run is red by design
    ;;
  *) die "unknown kind $KIND" ;;
  esac
  printf 'status=ok\nfinished=%s\n' "$(now)" >>"${DIR}/trial.env"
  log "trial ${NN}-${KIND} ok"
done
log "all trials done"
