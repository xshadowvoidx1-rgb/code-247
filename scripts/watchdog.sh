#!/usr/bin/env bash
# watchdog.sh — heals the code-server chain if no run is active or queued.
set -uo pipefail

REPO="xshadowvoidx1-rgb/code-247"
API="https://api.github.com"
WF="code-server.yml"

gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }
log() { echo "[watchdog $(date -u +%H:%M:%S)] $*"; }

active=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=in_progress" | jq -r '.total_count')
queued=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=queued" | jq -r '.total_count')
if [ "${active:-0}" -gt 0 ] || [ "${queued:-0}" -gt 0 ]; then
  log "chain alive (active=$active queued=$queued) — nothing to do"
  exit 0
fi

log "no active server run — dispatching"
code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
  "$API/repos/$REPO/actions/workflows/$WF/dispatches" -d '{"ref":"main"}')
log "dispatch HTTP $code"
