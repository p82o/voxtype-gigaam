#!/usr/bin/env bash
# Build a CPU image with refreshed base packages; preserve the user's hotkey.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$HOME/.local/share/gigaam/docker"
SYSTEMD_DIR="$HOME/.config/systemd/user"
VXC="$HOME/.config/voxtype/config.toml"
log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in docker curl systemctl sha256sum timeout; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
[[ $(uname -m) == x86_64 ]] || die 'This lock supports Linux amd64 only'
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable or inaccessible'
docker compose version >/dev/null 2>&1 || die 'Docker Compose is required'
systemctl --user show-environment >/dev/null 2>&1 || die 'A systemd user session is required'
command -v voxtype >/dev/null || die 'Install voxtype first'
[[ -f "$VXC" ]] || die 'Existing voxtype config is required'
if docker inspect gigaam-asr >/dev/null 2>&1; then
  owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' gigaam-asr)
  [[ "$owner" == voxtype-gigaam ]] || die 'gigaam-asr belongs to another application'
fi

log 'Preparing checksum-verified model files...'
bash "$REPO_DIR/scripts/prepare-model.sh"
log 'Building ASR image with refreshed base packages (the existing ASR stays running)...'
mkdir -p "$REPO_DIR/.build"
if ! docker build --pull --no-cache-filter runtime-os --platform linux/amd64 -t voxtype-gigaam:local "$REPO_DIR" >"$REPO_DIR/.build/build.log" 2>&1; then
  die 'Image build failed; diagnostic log: .build/build.log'
fi
IMAGE=$(docker image inspect --format '{{.Id}}' voxtype-gigaam:local)
log 'Auditing dependencies and the built image before switching ASR...'
bash "$REPO_DIR/scripts/audit.sh" --image "$IMAGE" || die 'Security audit failed; the existing ASR is unchanged'
# Smoke-load only; no listener or alternate ASR server is started.
if ! docker run --rm --network none --read-only --tmpfs /tmp:rw,size=256m \
  "$IMAGE" python -c 'import server; assert server.model._device.type == "cpu"' \
  >"$REPO_DIR/.build/model-load.log" 2>&1; then
  die 'Offline model load failed; diagnostic log: .build/model-load.log'
fi

mkdir -p "$STACK_DIR" "$SYSTEMD_DIR" "$HOME/.local/bin"

systemctl --user stop gigaam-watchdog.timer gigaam-watchdog.service 2>/dev/null || true
systemctl --user disable --now gigaam-server.service >/dev/null 2>&1 || true
install -m 644 "$REPO_DIR/compose.yaml" "$STACK_DIR/compose.yaml"
printf 'GIGAAM_IMAGE=%s\n' "$IMAGE" > "$STACK_DIR/image.env"
compose() {
  env -u GIGAAM_IMAGE docker compose --project-directory "$STACK_DIR" --env-file "$STACK_DIR/image.env" \
    -f "$STACK_DIR/compose.yaml" "$@" >/dev/null 2>&1
}
log 'Starting ASR container on 127.0.0.1:8394...'
compose up -d --no-build --pull never --wait --wait-timeout 120 asr
# Run the config merger with the image's Python, not the host interpreter.
docker run --rm -i --network none --read-only --tmpfs /tmp:rw,size=16m --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$VXC,dst=/config.toml" "$IMAGE" python - /config.toml \
  < "$REPO_DIR/scripts/merge-config.py" > "$STACK_DIR/hotkey.sha256"
for unit in gigaam-watchdog.service gigaam-watchdog.timer; do
  install -m 644 "$REPO_DIR/systemd/$unit" "$SYSTEMD_DIR/$unit"
done
install -m 755 "$REPO_DIR/scripts/gigaam-watchdog.sh" "$HOME/.local/bin/gigaam-watchdog.sh"
systemctl --user daemon-reload
systemctl --user enable --now gigaam-watchdog.timer
systemctl --user restart voxtype
systemctl --user is-active --quiet voxtype
log "Installed image: $IMAGE"
log 'Run ./verify.sh for acceptance tests.'
