#!/usr/bin/env bash
# Resolve updates in Docker; audit the candidate locks before replacing them.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/.build/security"
docker build --pull --target tools --platform linux/amd64 -t voxtype-gigaam:tools "$REPO_DIR" \
  > "$REPO_DIR/.build/security/tools-build.log" 2>&1
TOOLS=$(docker image inspect --format '{{.Id}}' voxtype-gigaam:tools)
WORK=$(mktemp -d "$REPO_DIR/.build/update-lock.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
for name in requirements build-requirements audit-requirements; do
  cp "$REPO_DIR/$name.txt" "$WORK/$name.txt"
done
tool() {
  docker run --rm --read-only --tmpfs /tmp:rw,size=256m --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,src=$WORK,dst=/work" \
    --mount "type=bind,src=$REPO_DIR/scripts/audit-report.py,dst=/audit-report.py,readonly" \
    --mount "type=bind,src=$REPO_DIR/security/exceptions.json,dst=/exceptions.json,readonly" \
    "$TOOLS" "$@"
}
for name in requirements build-requirements audit-requirements; do
  extra=()
  [[ $name != requirements ]] || extra=(--index https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match --emit-index-url)
  tool uv --no-config --cache-dir /tmp/uv pip compile "/work/$name.txt" --upgrade \
    --python-version 3.14 --python-platform x86_64-manylinux_2_28 \
    --default-index https://pypi.org/simple --generate-hashes --no-header \
    --output-file "/work/$name.lock" "${extra[@]}" > "$WORK/$name.resolve.log" 2>&1
  tool python /audit-report.py prepare "/work/$name.lock" "/work/$name.audit.txt"
  scanner_status=0
  tool pip-audit --disable-pip --no-deps --strict --progress-spinner off --timeout 30 \
    --cache-dir /tmp/audit-cache -r "/work/$name.audit.txt" --format json -o "/work/$name.audit.json" \
    > "$WORK/$name.audit.log" 2>&1 || scanner_status=$?
  [[ $scanner_status -le 1 ]] || { echo 'Vulnerability service failed; locks unchanged' >&2; exit 2; }
  tool python /audit-report.py check pip "/work/$name.audit.json" /exceptions.json "/work/$name.policy.json" --expected "/work/$name.audit.txt"
done
for name in requirements build-requirements audit-requirements; do
  cp "$WORK/$name.lock" "$REPO_DIR/$name.lock"
done
echo 'Locks updated and audited. Review the diff, then run ./install.sh and ./verify.sh.'
