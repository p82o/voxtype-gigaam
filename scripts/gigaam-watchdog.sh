#!/usr/bin/env bash
# Docker handles exited processes; this timer also recovers hangs and manual stops.
set -euo pipefail
STACK_DIR="${GIGAAM_STACK_DIR:-$HOME/.local/share/gigaam/docker}"
URL=http://127.0.0.1:8394/health
CONTAINER=gigaam-asr

log() { logger -t gigaam-watchdog -- "$*"; }
compose() {
  timeout 60 env -u GIGAAM_IMAGE docker compose --project-directory "$STACK_DIR" \
    --env-file "$STACK_DIR/image.env" -f "$STACK_DIR/compose.yaml" "$@" \
    >/dev/null 2>&1
}
state() {
  timeout 15 docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{.State.StartedAt}} {{.State.Pid}}' "$CONTAINER" 2>/dev/null
}
wait_ready() {
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if curl -sf -m 5 "$URL" -o /dev/null 2>/dev/null; then return 0; fi
    sleep 2
  done
  log 'ASR did not become ready within 120 seconds'
  return 1
}

if ! timeout 15 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  log 'Docker is unavailable; retrying on the next timer tick'
  exit 1
fi
if ! snapshot=$(state); then
  log 'ASR container is missing; recreating from the installed image'
  compose up -d --no-build --pull never asr || { log 'Container creation failed'; exit 1; }
  wait_ready
  exit
fi
read -r project service status started pid <<< "$snapshot"
if [[ "$project" != voxtype-gigaam || "$service" != asr ]]; then
  log 'Container name belongs to another application; refusing recovery'
  exit 1
fi
case "$status" in
  restarting) exit 0 ;;
  exited|created)
    log 'ASR container is stopped; starting it'
    compose up -d --no-build --pull never asr || { log 'Container start failed'; exit 1; }
    wait_ready
    exit ;;
  running) ;;
  *) log 'Unexpected container state; retrying on the next timer tick'; exit 1 ;;
esac

if curl -sf -m 15 "$URL" -o /dev/null 2>/dev/null; then exit 0; fi
# Startup grace is separate from the inference/deadlock double-check.
started_epoch=$(date -d "$started" +%s)
if (( $(date +%s) - started_epoch < 120 )); then exit 0; fi
sleep 5
if curl -sf -m 15 "$URL" -o /dev/null 2>/dev/null; then exit 0; fi
# A Docker restart between the probes must not interrupt a fresh model load.
if [[ "$(state)" != "$snapshot" ]]; then exit 0; fi
log 'Health check failed twice; restarting the ASR container'
compose restart --timeout 15 asr || { log 'Container restart failed'; exit 1; }
wait_ready
