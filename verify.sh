#!/usr/bin/env bash
# Acceptance tests. The full suite temporarily stops/freezes only our ASR container.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$HOME/.local/share/gigaam/docker"
SKIP_WATCHDOG=0
[[ "${1:-}" != --skip-watchdog ]] || SKIP_WATCHDOG=1
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
fail() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "PASS $*"; }
compose() {
  env -u GIGAAM_IMAGE docker compose --project-directory "$STACK_DIR" --env-file "$STACK_DIR/image.env" \
    -f "$STACK_DIR/compose.yaml" "$@" >/dev/null 2>&1
}
wait_ready() {
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if curl -sf -m 5 http://127.0.0.1:8394/health >/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}
systemctl --user is-active --quiet gigaam-watchdog.timer || fail 'watchdog timer is inactive'
systemctl --user is-active --quiet voxtype || fail 'voxtype is inactive'
[[ $(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' gigaam-asr) == voxtype-gigaam ]] || fail 'container ownership'
if systemctl --user is-active --quiet gigaam-server.service; then fail 'legacy ASR service is still active'; fi
[[ $(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' gigaam-asr) == always ]] || fail 'restart policy'
[[ $(docker inspect --format '{{(index (index .NetworkSettings.Ports "8394/tcp") 0).HostIp}}' gigaam-asr) == 127.0.0.1 ]] || fail 'port is not loopback-only'
[[ $(docker inspect --format '{{.Config.User}}' gigaam-asr) == 10001:10001 ]] || fail 'container runs as an unexpected user'
wait_ready || fail 'health endpoint'
ok 'Docker state, restart policy, loopback port, non-root user and health'
docker exec -i gigaam-asr python - "$(cat "$REPO_DIR/model/revision.txt")" <<'PY' || fail 'native runtime dependencies/source'
import importlib.metadata
import importlib.util
from pathlib import Path
import shutil
import sys
assert sys.version_info[:2] == (3, 14)
assert shutil.which("uv") is None
assert importlib.util.find_spec("transformers") is None
assert importlib.util.find_spec("gigaam") is not None
torch = importlib.metadata.version("torch")
assert torch.endswith("+cpu") and torch == importlib.metadata.version("torchaudio")
assert Path("/opt/upstream/revision.txt").read_text().strip() == sys.argv[1]
PY
ok 'Python 3.14, matching CPU torch/torchaudio, native GigaAM revision, no uv/Transformers'

if [[ "$SKIP_WATCHDOG" == 0 ]]; then
  # Pause the timer to make the interventions deterministic; restore it on exit.
  systemctl --user stop gigaam-watchdog.timer gigaam-watchdog.service
  cleanup() {
    docker kill --signal CONT gigaam-asr >/dev/null 2>&1 || true
    compose up -d --no-build --pull never asr || true
    systemctl --user start gigaam-watchdog.timer || true
    rm -rf "$TMP_DIR"
  }
  old=$(docker inspect --format '{{.State.StartedAt}}' gigaam-asr)
  docker exec gigaam-asr python -c 'import os,signal; os.kill(1,signal.SIGTERM)' >/dev/null 2>&1 || true
  sleep 2
  wait_ready || fail 'Docker did not recover a terminated ASR process'
  [[ $(docker inspect --format '{{.State.StartedAt}}' gigaam-asr) != "$old" ]] || fail 'ASR did not restart'
  ok 'Docker recovered a terminated ASR process'
  compose stop --timeout 15 asr
  systemctl --user start gigaam-watchdog.service
  wait_ready || fail 'watchdog did not recover a stopped container'
  ok 'watchdog recovered a stopped container'
  compose down
  systemctl --user start gigaam-watchdog.service
  wait_ready || fail 'watchdog did not recreate a missing container'
  ok 'watchdog recreated a missing container without building or pulling'
  # Let startup grace expire before simulating an inference/event-loop hang.
  # Poll time rather than freezing a newly loading model.
  sleep 1
  started=$(date -d "$(docker inspect --format '{{.State.StartedAt}}' gigaam-asr)" +%s)
  while (( $(date +%s) - started < 120 )); do sleep 5; done
  old=$(docker inspect --format '{{.State.StartedAt}}' gigaam-asr)
  docker kill --signal STOP gigaam-asr >/dev/null
  systemctl --user start gigaam-watchdog.service
  wait_ready || fail 'watchdog did not recover a frozen process'
  [[ $(docker inspect --format '{{.State.StartedAt}}' gigaam-asr) != "$old" ]] || fail 'frozen container did not restart'
  ok 'watchdog recovered a frozen process after the double health check'
  systemctl --user start gigaam-watchdog.timer
fi

EX="$REPO_DIR/.build/example.wav"
mkdir -p "$REPO_DIR/.build"
if [[ ! -s "$EX" ]]; then
  curl -fsSL --max-time 60 -o "$EX" https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/example.wav || fail 'official sample download'
fi
docker exec -i gigaam-asr python -c 'import pathlib,sys; pathlib.Path("/tmp/gigaam-example.wav").write_bytes(sys.stdin.buffer.read())' < "$EX"
docker exec -i gigaam-asr python - /tmp/gigaam-example.wav < "$REPO_DIR/scripts/verify-api.py" > "$TMP_DIR/results.json" || fail 'ASR regression/speech tests'
cat "$TMP_DIR/results.json"
ok '25.003s regression, official speech, 60s speech, invalid input rejection and recovery'
if voxtype transcribe "$EX" > "$TMP_DIR/voxtype.txt" 2>&1 && grep -Eq 'похвал|лукоморья|надеждой' "$TMP_DIR/voxtype.txt"; then
  ok 'voxtype end-to-end speech recognition'
else fail 'voxtype end-to-end'; fi
# Compare the hotkey against its installation fingerprint, without a config copy.
docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$HOME/.config/voxtype/config.toml,dst=/current,readonly" \
  --mount "type=bind,src=$STACK_DIR/hotkey.sha256,dst=/hotkey.sha256,readonly" \
  "$(docker inspect --format '{{.Image}}' gigaam-asr)" python -c '
import hashlib,pathlib,re,tomllib
pattern=rb"(?ms)^[ \t]*\[hotkey\][^\n]*(?:\n|$).*?(?=^[ \t]*\[|\Z)"
current=pathlib.Path("/current").read_bytes()
expected=pathlib.Path("/hotkey.sha256").read_text().strip()
assert hashlib.sha256(re.search(pattern,current).group()).hexdigest()==expected
c=tomllib.loads(current.decode()); assert c["whisper"]["mode"]=="remote"
assert c["whisper"]["remote_endpoint"]=="http://127.0.0.1:8394"
' || fail 'hotkey/config preservation'
ok 'hotkey is byte-identical; voxtype uses the expected remote endpoint'
