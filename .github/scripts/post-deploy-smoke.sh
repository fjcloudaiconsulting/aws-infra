#!/usr/bin/env bash
# Post-deploy smoke (INFRA-114): after a push to clusters/platform/<namespace>/, wait until the public URL serves the
# backend tag the manifest names, wait for the frontend, run the app's own smoke script at that tag, and open, comment
# on or close ONE issue per namespace. Runs outside the cluster, through Cloudflare, like a user.
#
# Usage: post-deploy-smoke.sh <namespace>. Env: GH_TOKEN, GH_REPO, RUN_URL; SMOKE_USERNAME / SMOKE_PASSWORD for an
# app smoke that logs in. Optional: CLUSTERS_DIR (default clusters/platform), CONVERGE_SECONDS (900), POLL_SECONDS
# (15), SETTLE_SECONDS (150), FRONTEND_SECONDS (300), FRONTEND_GAP_SECONDS (10). Needs curl, gh, python3.
#
# Every failure after the usage check raises the alarm (fails INTO the alarm, like the backup probe); only a full
# pass closes it. No data-plane writes: the app smoke runs once (TBD: one login, which adds a session and an audit
# row, and one GET), never retried, so the smoke account never meets the login rate limit (10/min per IP).
# Never `set -x` here: the app smoke's environment holds the smoke password.
set -uo pipefail

ns="${1:-}"
case "$ns" in
  tbd-prod) base=https://app.thebetterdecision.com; health=/health; repo=tbd; app_smoke=scripts/smoke-test.sh ;;
  ziftbook-staging) base=https://dev.ziftbook.com; health=/api/healthz; repo=ziftbook; app_smoke="" ;;
  *) echo "usage: $0 tbd-prod|ziftbook-staging" >&2; exit 2 ;;
esac
DIR="${CLUSTERS_DIR:-clusters/platform}"
title="[post-deploy-smoke] $ns"
verdict=""
tag=""

check() {
  # The backend container's image only (the migrations init container and the scheduler have their own lines).
  tag="$(grep -hoE "ghcr\.io/fjcloudaiconsulting/$repo/backend:[^\"[:space:]]+" "$DIR/$ns/backend.yaml" 2>/dev/null \
         | sed 's#.*:##' | sort -u)"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { verdict="bad backend tag in $DIR/$ns/backend.yaml: '${tag//$'\n'/ }'"; return; }
  local want="${tag#v}" live="" i=0 ok=0 code deadline=$(( SECONDS + ${CONVERGE_SECONDS:-900} ))

  # 1. The new pods: Recreate with one replica, so once the reported version matches no old backend serves. A 5xx or
  # an HTML page in the Recreate gap is "not yet", never a failure; the cache-busting query keeps Cloudflare out.
  while :; do
    i=$((i + 1))
    live="$(curl -fsS --max-time 10 "$base$health?smoke=${RUN_ID:-local}-$i" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
    [[ "$live" == "$want" ]] && break
    (( SECONDS < deadline )) || { verdict="never converged (live ${live:-none}, expected $want)"; return; }
    sleep "${POLL_SECONDS:-15}"
  done
  echo "converged on $want after $i poll(s)"
  # Already serving the tag on the first poll: the push changed something else (a policy, a Secret, the frontend),
  # which Flux has not applied yet. Wait out its poll and apply, or the checks below test the old state.
  if (( i == 1 )); then echo "version unchanged, settling"; sleep "${SETTLE_SECONDS:-150}"; fi

  # 2. The frontend has no version and rolls out on its own: three consecutive 200s, 10 s apart.
  deadline=$(( SECONDS + ${FRONTEND_SECONDS:-300} ))
  while (( ok < 3 )); do
    code="$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 15 "$base/" 2>/dev/null)"
    if [[ "$code" == 200 ]]; then ok=$((ok + 1)); else ok=0; fi
    (( ok == 3 )) && break
    (( ok > 0 || SECONDS < deadline )) || { verdict="frontend GET / returned ${code:-nothing}"; return; }
    sleep "${FRONTEND_GAP_SECONDS:-10}"
  done
  echo "frontend GET / 200 x3"

  # 3. The app's own smoke, from the app repo at the deployed tag so it matches the release it tests. Saved to a file,
  # never piped into a shell, and run without GH_TOKEN.
  [[ -n "$app_smoke" ]] || return
  local f; f="$(mktemp)"
  gh api -H 'Accept: application/vnd.github.raw' "repos/fjcloudaiconsulting/$repo/contents/$app_smoke?ref=$tag" > "$f" \
    || { verdict="could not fetch $repo $app_smoke at $tag"; return; }
  SMOKE_BASE_URL="$base" env -u GH_TOKEN bash "$f" || verdict="app smoke failed ($repo $app_smoke at $tag)"
  rm -f "$f"
}

check

# Our own issue only: the repo is public, so match the exact title AND the Actions bot as author.
issues="$(gh issue list --state open --author app/github-actions --search "\"$title\" in:title" \
          --json number,title --jq '.[] | [.number, .title] | @tsv')" || { echo "issue lookup failed" >&2; exit 1; }
existing="$(awk -F'\t' -v t="$title" '$2 == t { print $1; exit }' <<<"$issues")"
if [[ -z "$verdict" ]]; then
  echo "post-deploy smoke passed for $ns $tag"
  [[ -z "$existing" ]] || gh issue close "$existing" --comment "Passed on $tag ($RUN_URL)." || exit 1
  exit 0
fi
echo "post-deploy smoke FAILED for $ns: $verdict" >&2
body="$(printf 'Post-deploy smoke for `%s` failed: %s\n\nRun: %s\n\nWhat to check: docs/runbooks.md, section "Post-deploy smoke".' \
        "$ns" "$verdict" "$RUN_URL")"
if [[ -n "$existing" ]]; then gh issue comment "$existing" --body "$body" || exit 1
else gh issue create --title "$title" --body "$body" || exit 1; fi
exit 1
