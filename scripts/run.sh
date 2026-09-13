#!/usr/bin/env bash
# run.sh — one lifecycle of the cloud coding environment cycle.
#
# boot (workspace from Release) → code-server + cloudflared tunnel → serve
# until idle or hard rail → snapshot + upload → dispatch successor → exit.
# Handover is idle-aware: it never interrupts an active coding session.
set -uo pipefail

REPO="xshadowvoidx1-rgb/code-247"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # absolute checkout path
WORK="/home/runner/code"
WS="$WORK/workspace"
API="https://api.github.com"
START="$(date +%s)"
HARDRAIL_AT=$((START + 5*3600 + 30*60))  # T+5h30 — force handover (GitHub 6h wall)
IDLE_HANDOVER_AFTER=$((30*60))           # idle this long → graceful handover
LAST_ACTIVE="$(date +%s)"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }

beacon() {
  local body msg_sha
  msg_sha="$(gh_api "$API/repos/$REPO/contents/status.txt" | jq -r '.sha // empty')"
  body="{\"message\":\"status beacon\",\"content\":\"$(printf '%s' "$1" | base64 -w0)\""
  [ -n "$msg_sha" ] && body="$body,\"sha\":\"$msg_sha\""
  body="$body}"
  gh_api -X PUT "$API/repos/$REPO/contents/status.txt" -d "$body" >/dev/null || true
}

mkdir -p "$WORK"
cd "$WORK"

# ------------------------------------------------------- 1. code-server
if ! command -v code-server >/dev/null 2>&1; then
  log "installing code-server"
  for i in 1 2 3; do
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone --prefix "$WORK/cs" && break
    log "install attempt $i failed"; sleep 10
  done
fi
CS="$WORK/cs/bin/code-server"
"$CS" --version | head -1 || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: code-server install failed"; exit 1; }
beacon "$(date -u +%H:%M:%S) UTC — code-server $($CS --version | head -1)"

# ------------------------------------------------- 2. Workspace (Release)
if [ ! -d "$WS" ]; then
  log "downloading workspace from Release 'workspace-snapshot'"
  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/workspace-snapshot")"
  ASSET_URL="$(echo "$REL_JSON" | jq -r '.assets[] | select(.name | test("ws-current")) | .url' | head -1)"
  mkdir -p "$WS"
  if [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ]; then
    curl -sL -H "Authorization: token $GH_PAT" -H "Accept: application/octet-stream" \
      -o "$WORK/ws.tar.gz" "$ASSET_URL"
    tar xzf "$WORK/ws.tar.gz" -C "$WS"
    rm -f "$WORK/ws.tar.gz"
    log "workspace restored: $(du -sh "$WS" | cut -f1)"
  else
    log "no snapshot asset — fresh workspace"
    mkdir -p "$WS/project"
    echo "# My cloud workspace" > "$WS/project/README.md"
    (cd "$WS/project" && git init -q 2>/dev/null || true)
  fi
  beacon "$(date -u +%H:%M:%S) UTC — workspace restored"
fi

# ------------------------------------------------------- 3. cloudflared
if [ ! -x "$WORK/cloudflared" ]; then
  curl -sfL -o "$WORK/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    && chmod +x "$WORK/cloudflared" \
    || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: cloudflared download failed"; exit 1; }
fi

# -------------------------------------------- 4. start code-server + tunnel
export PASSWORD="$CODE_PASSWORD"
mkdir -p "$WORK/cs-data" "$WORK/cs-config"
[ -d "$WS/cs-user-data" ] && { mkdir -p "$WORK/cs-data"; cp -r "$WS/cs-user-data/." "$WORK/cs-data/" 2>/dev/null || true; }
[ -d "$WS/cs-user-config" ] && cp -r "$WS/cs-user-config/." "$WORK/cs-config/" 2>/dev/null || true
# --config wants a FILE (passing the dir caused EISDIR crash); create it if absent
touch "$WORK/cs-config/config.yaml"

"$CS" --host 127.0.0.1 --port 8080 \
  --user-data-dir "$WORK/cs-data" --config "$WORK/cs-config/config.yaml" \
  --auth password > "$WORK/cs.log" 2>&1 &
CS_PID=$!

if [ -n "${TUNNEL_TOKEN:-}" ]; then
  # named tunnel — persistent URL, survives every VM swap
  TUNNEL_URL="https://codeserver.sryze.cc"
  "$WORK/cloudflared" tunnel run --token "$TUNNEL_TOKEN" --no-autoupdate \
    > "$WORK/tunnel.log" 2>&1 &
  CF_PID=$!
  for i in $(seq 1 24); do
    grep -q "Registered tunnel connection" "$WORK/tunnel.log" && break
    kill -0 "$CF_PID" 2>/dev/null || break
    sleep 5
  done
  if ! grep -q "Registered tunnel connection" "$WORK/tunnel.log"; then
    beacon "$(date -u +%H:%M:%S) UTC — FATAL: named tunnel did not connect
$(tail -c 1500 "$WORK/tunnel.log")"
    kill $CS_PID $CF_PID 2>/dev/null; exit 1
  fi
else
  # quick tunnel fallback — random URL per boot
  "$WORK/cloudflared" tunnel --url http://127.0.0.1:8080 --no-autoupdate > "$WORK/tunnel.log" 2>&1 &
  CF_PID=$!
  TUNNEL_URL=""
  for i in $(seq 1 24); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$WORK/tunnel.log" | head -1)"
    [ -n "$TUNNEL_URL" ] && break
    sleep 5
  done
  if [ -z "$TUNNEL_URL" ]; then
    beacon "$(date -u +%H:%M:%S) UTC — FATAL: no tunnel URL
$(tail -c 1500 "$WORK/tunnel.log")"
    kill $CS_PID $CF_PID 2>/dev/null; exit 1
  fi
fi
log "TUNNEL: $TUNNEL_URL"
beacon "$(date -u +%H:%M:%S) UTC — CODE SERVER UP
$TUNNEL_URL
(password is the CODE_PASSWORD secret — ask Jarvis or check your local _artifacts/code-password.txt)
code-server pid=$CS_PID cloudflared pid=$CF_PID"

# ------------------------------------------------- 5. serve + idle watcher
CMD_SHA_FILE="$WORK/.cmd_sha"
last_cmd_sha="$(cat "$CMD_SHA_FILE" 2>/dev/null || echo '')"

check_remote_console() {
  local json sha cmds line
  json="$(gh_api "$API/repos/$REPO/contents/console-command.txt" 2>/dev/null)"
  sha="$(echo "$json" | jq -r '.sha // empty')"
  [ -z "$sha" ] || [ "$sha" = "$last_cmd_sha" ] && return 0
  cmds="$(echo "$json" | jq -r '.content' | base64 -d 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    log "remote-console: $line"
    bash -c "$line"
    sleep 1
  done <<< "$cmds"
  echo "$sha" > "$CMD_SHA_FILE"
  last_cmd_sha="$sha"
  beacon "$(date -u +%H:%M:%S) UTC — remote-console executed:
$cmds"
}

check_handover_trigger() {
  local json sha
  json="$(gh_api "$API/repos/$REPO/contents/handover.txt" 2>/dev/null)"
  sha="$(echo "$json" | jq -r '.sha // empty')"
  [ -z "$sha" ] && return 1
  log "handover trigger file detected — consuming"
  beacon "$(date -u +%H:%M:%S) UTC — handover trigger received"
  gh_api -X DELETE "$API/repos/$REPO/contents/handover.txt" \
    -d "{\"message\":\"consume handover trigger\",\"sha\":\"$sha\"}" >/dev/null || true
  return 0
}

activity_check() {
  # any established connection to code-server, or any ssh/mosh session?
  if ss -tn 2>/dev/null | grep -q ':8080 .*ESTAB'; then LAST_ACTIVE="$(date +%s)"; return; fi
  if w -h 2>/dev/null | grep -q .; then LAST_ACTIVE="$(date +%s)"; return; fi
  true
}

while :; do
  now=$(date +%s)
  kill -0 "$CS_PID" 2>/dev/null || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: code-server died
$(tail -c 1500 "$WORK/cs.log")"; exit 3; }
  kill -0 "$CF_PID" 2>/dev/null || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: tunnel died
$(tail -c 1500 "$WORK/tunnel.log")"; exit 3; }
  activity_check
  IDLE=$(( now - LAST_ACTIVE ))
  check_remote_console
  check_handover_trigger && { log "remote handover triggered"; break; }
  [ "$now" -ge "$HARDRAIL_AT" ] && { log "HARD RAIL — forcing handover"; beacon "$(date -u +%H:%M:%S) UTC — hard rail reached, forcing handover"; break; }
  [ "$IDLE" -ge "$IDLE_HANDOVER_AFTER" ] && { log "idle ${IDLE}s — graceful handover"; beacon "$(date -u +%H:%M:%S) UTC — idle ${IDLE}s, starting graceful handover"; break; }
  sleep 20
done

# ------------------------------------------------------------- 6. Handover
handover() {
  log "handover: snapshotting workspace (editor still up)"
  # persist code-server user data (settings, extensions live in ~/.local)
  mkdir -p "$WS/cs-user-data" "$WS/cs-user-config"
  cp -r "$WORK/cs-data/." "$WS/cs-user-data/" 2>/dev/null || true
  cp -r "$WORK/cs-config/." "$WS/cs-user-config/" 2>/dev/null || true
  rm -f "$WORK/ws-current.tar.gz"
  tar czf "$WORK/ws-current.tar.gz" --exclude='*/node_modules' --exclude='*/.git/objects/pack/tmp*' -C "$WS" .
  log "snapshot size: $(du -sh "$WORK/ws-current.tar.gz" | cut -f1)"
  beacon "$(date -u +%H:%M:%S) UTC — snapshot built $(du -sh "$WORK/ws-current.tar.gz" | cut -f1), rotating release"

  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/workspace-snapshot")"
  REL_ID="$(echo "$REL_JSON" | jq -r '.id')"
  if [ -z "$REL_ID" ] || [ "$REL_ID" = "null" ]; then
    # first-ever snapshot: create the release
    REL_JSON="$(gh_api -X POST "$API/repos/$REPO/releases" -d '{"tag_name":"workspace-snapshot","name":"workspace-snapshot"}')"
    REL_ID="$(echo "$REL_JSON" | jq -r '.id')"
  fi
  for aid in $(echo "$REL_JSON" | jq -r '.assets[] | select(.name=="ws-prev.tar.gz") | .id'); do
    gh_api -X DELETE "$API/repos/$REPO/releases/assets/$aid"
  done
  for aid in $(echo "$REL_JSON" | jq -r '.assets[] | select(.name=="ws-current.tar.gz") | .id'); do
    gh_api -X PATCH "$API/repos/$REPO/releases/assets/$aid" -d '{"name":"ws-prev.tar.gz"}'
  done
  UP=$(curl -s -X POST \
    -H "Authorization: token $GH_PAT" -H "Content-Type: application/octet-stream" \
    --data-binary @"$WORK/ws-current.tar.gz" \
    "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=ws-current.tar.gz")
  echo "$UP" | jq -r '.state, .size' >/dev/null || { beacon "$(date -u +%H:%M:%S) UTC — upload response unclear: $(echo "$UP" | head -c 300)"; }

  kill $CS_PID $CF_PID 2>/dev/null
  sleep 3
  kill -9 $CS_PID $CF_PID 2>/dev/null

  log "handover: dispatching successor"
  for i in 1 2 3; do
    code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
      "$API/repos/$REPO/actions/workflows/code-server.yml/dispatches" -d '{"ref":"main"}')
    [ "$code" = "204" ] && { log "successor dispatched"; beacon "$(date -u +%H:%M:%S) UTC — cycle complete, successor dispatched"; return 0; }
    log "dispatch attempt $i failed (HTTP $code)"; sleep 10
  done
  beacon "$(date -u +%H:%M:%S) UTC — dispatch failed, watchdog will heal"
  return 1
}

handover
log "cycle complete, exiting"
