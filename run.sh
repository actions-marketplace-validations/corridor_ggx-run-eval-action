#!/usr/bin/env bash
# Run GGX reports on the agents of a pull request and wait for the result.
# Inputs arrive as INPUT_* environment variables (see action.yml). Needs bash, curl and jq, which every
# GitHub-hosted runner has. Nothing here prints a secret: the API key and the token only go into files that are
# readable by this user and into the request headers of curl.
#
# The GitHub token of the workflow stays on the runner: it only reads the pull request here. GGX fetches the branch and
# writes the comment on the pull request with the GitHub connection of the user whose API key this is.
set -euo pipefail

: "${GITHUB_EVENT_NAME:?run this in a GitHub Actions workflow}"
: "${GITHUB_EVENT_PATH:?}"
: "${GITHUB_REPOSITORY:?}"
API="${GITHUB_API_URL:-https://api.github.com}"
GGX_URL="${INPUT_GGX_URL%/}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

log() { printf '%s\n' "$*" >&2; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# Header files keep the secrets out of the command line (and so out of `ps` and of error messages)
printf 'header = "x-api-key: %s"\nheader = "content-type: application/json"\n' "$INPUT_GGX_API_KEY" >"$WORK/ggx.curl"
printf 'header = "authorization: Bearer %s"\nheader = "accept: application/vnd.github+json"\nheader = "x-github-api-version: 2022-11-28"\n' \
  "$INPUT_GITHUB_TOKEN" >"$WORK/gh.curl"

ggx() { curl --silent --show-error --fail-with-body --max-time 120 --config "$WORK/ggx.curl" "$@"; }
gh_api() { curl --silent --show-error --fail-with-body --max-time 60 --config "$WORK/gh.curl" "$@"; }

# The comma or line separated names of an input, as a JSON array
names() { jq -Rn --arg v "$1" '$v | split("[,\n]"; null) | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'; }

# --- Which pull request, and which commit
EVENT="$GITHUB_EVENT_PATH"
case "$GITHUB_EVENT_NAME" in
  pull_request | pull_request_target)
    PR_NUMBER="$(jq -r '.pull_request.number' "$EVENT")"
    EVENT_KIND="pull_request"
    ;;
  issue_comment)
    jq -e '.issue.pull_request' "$EVENT" >/dev/null || fail "The comment is not on a pull request"
    PR_NUMBER="$(jq -r '.issue.number' "$EVENT")"
    EVENT_KIND="comment"
    ;;
  *)
    PR_NUMBER="${INPUT_PR_NUMBER:-}"
    EVENT_KIND="comment"
    [ -n "$PR_NUMBER" ] || fail "Event $GITHUB_EVENT_NAME has no pull request: pass the pr-number input"
    ;;
esac
# The payload of an issue comment has no head: read the pull request, which is also the freshest state
gh_api "$API/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" >"$WORK/pr.json" || {
  cat "$WORK/pr.json" >&2
  fail "Could not read pull request #$PR_NUMBER"
}
HEAD_SHA="$(jq -r '.head.sha' "$WORK/pr.json")"
HEAD_BRANCH="$(jq -r '.head.ref' "$WORK/pr.json")"
HEAD_REPO="$(jq -r '.head.repo.full_name // empty' "$WORK/pr.json")"
if [ "$HEAD_REPO" != "$GITHUB_REPOSITORY" ]; then
  log "::notice::Pull request #$PR_NUMBER comes from ${HEAD_REPO:-a deleted fork}. Only pull requests from branches of $GITHUB_REPOSITORY are evaluated."
  {
    echo "status=skipped"
    echo "run-ids=[]"
    echo "dashboard-urls=[]"
  } >>"${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# --- Which reports
TIER="${INPUT_TIER:-}"
if [ -z "$TIER" ] || [ "$TIER" = "auto" ]; then
  if [ "$EVENT_KIND" = "comment" ]; then TIER="full"; else TIER="default"; fi
fi
if [ "$TIER" = "full" ] && [ -n "${INPUT_FULL_REPORTS//[[:space:]]/}" ]; then
  REPORTS="$(names "$INPUT_FULL_REPORTS")"
else
  REPORTS="$(names "$INPUT_REPORTS")"
fi
[ "$(jq length <<<"$REPORTS")" -gt 0 ] || fail "No reports: set the reports input (and full-reports for the full tier)"

# --- Which agents: changed, all, or module:attribute entries
AGENTS_INPUT="$(tr -d '[:space:]' <<<"$INPUT_AGENTS")"
CHANGED_FILES='[]'
case "$AGENTS_INPUT" in
  changed | "")
    AGENTS='"changed"'
    page=1
    : >"$WORK/files.txt"
    while :; do
      gh_api "$API/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files?per_page=100&page=$page" >"$WORK/page.json" ||
        fail "Could not list the files of pull request #$PR_NUMBER"
      jq -r '.[] | .filename, (.previous_filename // empty)' "$WORK/page.json" >>"$WORK/files.txt"
      [ "$(jq length "$WORK/page.json")" -eq 100 ] && [ "$page" -lt 30 ] || break
      page=$((page + 1))
    done
    CHANGED_FILES="$(jq -R . "$WORK/files.txt" | jq -s .)"
    ;;
  all) AGENTS='"all"' ;;
  *) AGENTS="$(names "$INPUT_AGENTS")" ;;
esac

# --- Start the runs
COMMENT=false
[ "${INPUT_COMMENT:-true}" = "true" ] && COMMENT=true
REPORT_DATA="${INPUT_REPORT_DATA:-}"
[ -n "$REPORT_DATA" ] || REPORT_DATA='{}'
jq -n \
  --arg repo "$GITHUB_REPOSITORY" --arg project "$INPUT_PROJECT" --arg sha "$HEAD_SHA" --arg branch "$HEAD_BRANCH" \
  --argjson pr "$PR_NUMBER" --arg event "$EVENT_KIND" --arg tier "$TIER" --argjson reports "$REPORTS" \
  --argjson agents "$AGENTS" --arg pythonPath "$INPUT_PYTHON_PATH" --argjson changed "$CHANGED_FILES" \
  --arg maxRows "$INPUT_MAX_ROWS" --argjson tables "$(names "$INPUT_DATA_TABLES")" \
  --argjson reportData "$REPORT_DATA" --arg definition "$INPUT_DATA_DEFINITION" --argjson comment "$COMMENT" '
  {
    repo: $repo, project: $project, headSha: $sha, headBranch: $branch, prNumber: $pr, event: $event, tier: $tier,
    reports: $reports, agents: $agents, pythonPath: $pythonPath, changedFiles: $changed,
    data: ({tableNames: $tables, reportData: $reportData} + (if $definition == "" then {} else {definition: $definition} end)),
    comment: $comment
  } + (if $maxRows == "" then {} else {maxRows: ($maxRows | tonumber)} end)' >"$WORK/request.json" ||
  fail "Could not build the request: check that report-data is a JSON object"

log "Starting $TIER reports on pull request #$PR_NUMBER at ${HEAD_SHA:0:7}"
if ! ggx --request POST --data @"$WORK/request.json" "$GGX_URL/api/v1/ci/runs" >"$WORK/start.json"; then
  jq -r '.message // .detail // .' "$WORK/start.json" 2>/dev/null >&2 || cat "$WORK/start.json" >&2
  fail "GGX did not start the evaluation"
fi
jq '.result' "$WORK/start.json" >"$WORK/started.json"
for note in $(jq -r '.skipped[]? | @base64' "$WORK/started.json"); do
  log "::notice::$(base64 --decode <<<"$note")"
done
RUN_IDS="$(jq -c '[.runs[].id]' "$WORK/started.json")"
COMMENT_URL="$(jq -r '.commentUrl // empty' "$WORK/started.json")"
COMMENT_ERROR="$(jq -r '.commentError // empty' "$WORK/started.json")"
if [ -n "$COMMENT_ERROR" ]; then
  log "::warning::GGX could not write the comment on the pull request: $COMMENT_ERROR. Check the GitHub connection of the GGX user."
fi
cp "$WORK/started.json" "$WORK/runs.json"

# --- The comment on the pull request is GGX's: it writes it when the runs start and edits it when they end
MARKER="<!-- ggx-eval tier=$TIER -->"

render() {
  # The comment, from $WORK/runs.json
  jq -r --arg marker "$MARKER" --arg sha "$HEAD_SHA" --arg tier "$TIER" '
    def icon: if .status == "COMPLETED" then "✅" elif (.status == "FAILED" or .status == "STOPPED") then "❌" else "⏳" end;
    def cell: gsub("\\|"; "\\|") | gsub("\n"; " ");
    $marker + "\n### GGX evaluation (" + $tier + ")\n\n" +
    "Commit `" + $sha[0:7] + "`\n\n" +
    "| Agent | Status | Records | Reports | Results |\n|---|---|---|---|---|\n" +
    ([.runs[] |
      "| " + (.agentName | cell) + " | " + icon + " " + .status + " | " +
      (if .recordsPassed == null then "-" else ((.recordsPassed | tostring) + " passed, " + ((.recordsFailed // 0) | tostring) + " failed") end) +
      " | " + (.reports | map(cell) | join(", ")) + " | [Open in GGX](" + .dashboardUrl + ") |"] | join("\n")) +
    ([.runs[] | select((.metrics | length) > 0) |
      "\n\n**" + (.agentName | cell) + "**\n\n| Metric | Value | Status |\n|---|---|---|\n" +
      ([.metrics[] | "| " + (.label | cell) + " | " + (.value // "-") + " | " + .status + " |"] | join("\n"))] | join("")) +
    (if ([.runs[] | select(.reused)] | length) > 0 then "\n\n_Reused the run already started for this commit._" else "" end)
  ' "$WORK/runs.json"
}

set_status() {
  [ "${INPUT_COMMIT_STATUS:-false}" = "true" ] || return 0
  local state="$1" description="$2"
  jq -n --arg state "$state" --arg description "$description" --arg context "ggx/$TIER" \
    --arg url "$(jq -r '.runs[0].dashboardUrl' "$WORK/runs.json")" \
    '{state: $state, description: $description, context: $context, target_url: $url}' >"$WORK/status.json"
  gh_api --request POST --data @"$WORK/status.json" "$API/repos/$GITHUB_REPOSITORY/statuses/$HEAD_SHA" >/dev/null ||
    log "::warning::Could not set the commit status (does the workflow have statuses: write?)"
}

set_status pending "GGX is evaluating the pull request"

# --- Wait for the runs
DEADLINE=$((SECONDS + ${INPUT_TIMEOUT_MINUTES:-30} * 60))
INTERVAL="${INPUT_POLL_INTERVAL_SECONDS:-15}"
TIMED_OUT=false
while :; do
  pending=0
  : >"$WORK/polled.jsonl"
  for id in $(jq -r '.runs[].id' "$WORK/runs.json"); do
    if ggx "$GGX_URL/api/v1/ci/runs/$id" >"$WORK/run.json"; then
      jq -c '.result' "$WORK/run.json" >>"$WORK/polled.jsonl"
    else
      log "::warning::Could not read run $id; trying again"
      jq -c --argjson id "$id" '.runs[] | select(.id == $id)' "$WORK/runs.json" >>"$WORK/polled.jsonl"
    fi
  done
  jq -s --slurpfile old "$WORK/runs.json" '{runs: ., skipped: $old[0].skipped}' "$WORK/polled.jsonl" >"$WORK/runs.next.json"
  mv "$WORK/runs.next.json" "$WORK/runs.json"
  pending="$(jq '[.runs[] | select(.finished | not)] | length' "$WORK/runs.json")"
  [ "$pending" -eq 0 ] && break
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    TIMED_OUT=true
    break
  fi
  sleep "$INTERVAL"
done

# --- The result
if [ "$TIMED_OUT" = true ]; then
  RESULT="timeout"
elif [ "$(jq '[.runs[] | select(.passed | not)] | length' "$WORK/runs.json")" -eq 0 ]; then
  RESULT="completed"
else
  RESULT="failed"
fi
case "$RESULT" in
  completed) set_status success "GGX evaluation completed" ;;
  timeout) set_status error "GGX evaluation did not finish in time" ;;
  *) set_status failure "GGX evaluation failed" ;;
esac

{
  echo "status=$RESULT"
  echo "run-ids=$RUN_IDS"
  echo "dashboard-urls=$(jq -c '[.runs[].dashboardUrl]' "$WORK/runs.json")"
  echo "comment-url=${COMMENT_URL}"
  echo "summary<<GGX_SUMMARY_EOF"
  render
  echo "GGX_SUMMARY_EOF"
} >>"${GITHUB_OUTPUT:-/dev/null}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then render >>"$GITHUB_STEP_SUMMARY"; fi

[ -z "$COMMENT_URL" ] || log "Comment on the pull request: $COMMENT_URL"
log "Result: $RESULT"
if [ "$RESULT" != "completed" ] && [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then
  exit 1
fi
