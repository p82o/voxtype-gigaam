#!/usr/bin/env bash
# Verify the upstream source archive and the native checkpoint/tokenizer.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_DIR/.build/model-native"
REVISION=$(cat "$REPO_DIR/model/revision.txt")
mkdir -p "$DEST"
SOURCE="$REPO_DIR/.build/gigaam.tar.gz"
if ! (cd "$REPO_DIR/.build" && sha256sum --check --status "$REPO_DIR/model/source.SHA256SUMS") 2>/dev/null; then
  curl -q -fL --retry 3 --silent --show-error \
    "https://api.github.com/repos/salute-developers/GigaAM/tarball/$REVISION" -o "$SOURCE.part"
  read -r expected _ < "$REPO_DIR/model/source.SHA256SUMS"
  printf '%s  %s\n' "$expected" "$SOURCE.part" | sha256sum --check --status
  mv "$SOURCE.part" "$SOURCE"
fi
while read -r hash file; do
  if printf '%s  %s\n' "$hash" "$DEST/$file" | sha256sum --check --status 2>/dev/null; then
    continue
  fi
  curl -q -fL --retry 3 --silent --show-error \
    "https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/$file" \
    -o "$DEST/$file.part"
  printf '%s  %s\n' "$hash" "$DEST/$file.part" | sha256sum --check --status
  mv "$DEST/$file.part" "$DEST/$file"
done < "$REPO_DIR/model/SHA256SUMS"
(cd "$DEST" && sha256sum --check --status "$REPO_DIR/model/SHA256SUMS")
echo 'Model checksums verified.'
