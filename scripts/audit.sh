#!/usr/bin/env bash
# Scan locks and optionally an image; scanner/network failures block installation.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$REPO_DIR/.build/security/reports"
IMAGE=""
if [[ $# -gt 0 ]]; then
  [[ $# == 2 && $1 == --image ]] || { echo 'Usage: audit.sh [--image IMAGE]' >&2; exit 2; }
  IMAGE=$2
fi
mkdir -p "$REPORT_DIR" "$REPO_DIR/.build/security/cache"
docker build --pull --target tools --platform linux/amd64 -t voxtype-gigaam:tools "$REPO_DIR" \
  > "$REPO_DIR/.build/security/tools-build.log" 2>&1 || { echo 'Audit tool build failed' >&2; exit 2; }
TOOLS=$(docker image inspect --format '{{.Id}}' voxtype-gigaam:tools)
tool() {
  docker run --rm --read-only --tmpfs /tmp:rw,size=256m --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,src=$REPO_DIR,dst=/repo,readonly" \
    --mount "type=bind,src=$REPORT_DIR,dst=/reports" "$TOOLS" "$@"
}
status=0
for lock in requirements.lock build-requirements.lock audit-requirements.lock; do
  tool python /repo/scripts/audit-report.py prepare "/repo/$lock" "/reports/$lock.txt"
  rm -f "$REPORT_DIR/$lock.json" "$REPORT_DIR/$lock.policy.json"
  scanner_status=0
  tool pip-audit --disable-pip --no-deps --strict --progress-spinner off --timeout 30 \
    --cache-dir /tmp/audit-cache -r "/reports/$lock.txt" --format json -o "/reports/$lock.json" \
    > "$REPORT_DIR/$lock.log" 2>&1 || scanner_status=$?
  [[ $scanner_status -le 1 ]] || { echo 'Python vulnerability service failed' >&2; exit 2; }
  tool python /repo/scripts/audit-report.py check pip "/reports/$lock.json" \
    /repo/security/exceptions.json "/reports/$lock.policy.json" --expected "/reports/$lock.txt" || status=1
done
if [[ -n "$IMAGE" ]]; then
  ARCHIVE=$(mktemp "$REPO_DIR/.build/security/image.XXXXXX.tar")
  trap 'rm -f "$ARCHIVE"' EXIT
  docker image save --output "$ARCHIVE" "$IMAGE"
  rm -f "$REPORT_DIR/image.json" "$REPORT_DIR/image.policy.json"
  docker run --rm --read-only --tmpfs /tmp:rw,size=2g --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,src=$ARCHIVE,dst=/image.tar,readonly" \
    --mount "type=bind,src=$REPO_DIR/.build/security/cache,dst=/cache" \
    --mount "type=bind,src=$REPORT_DIR,dst=/reports" \
    aquasec/trivy:0.75.0 image --cache-dir /cache --timeout 10m --scanners vuln \
    --format json --output /reports/image.json --input /image.tar \
    > "$REPORT_DIR/trivy.log" 2>&1 || { echo 'Image vulnerability service failed' >&2; exit 2; }
  tool python /repo/scripts/audit-report.py check trivy /reports/image.json \
    /repo/security/exceptions.json /reports/image.policy.json || status=1
fi
echo "Audit reports: $REPORT_DIR"
exit "$status"
