#!/usr/bin/env bash
# Installs GigaAM v3 e2e RNN-T as a local OpenAI-compatible ASR server
# and switches voxtype to it (remote mode). Idempotent; backs up overwritten files.
# Verified on Arch-based CachyOS (niri + GNOME), Python 3.14, voxtype 1.0.1.
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
GIGAAM_DIR="$HOME/.local/share/gigaam"
MODEL_DIR="$GIGAAM_DIR/model"
VENV_DIR="$GIGAAM_DIR/venv"
SYSTEMD_DIR="$HOME/.config/systemd/user"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

MODEL_BASE_URL="https://huggingface.co/ai-sage/GigaAM-v3/resolve/e2e_rnnt"

# ---------------------------------------------------------------- preconditions
command -v python3 >/dev/null || die "python3 not found"
command -v ffmpeg   >/dev/null || die "ffmpeg not found (required by model's load_audio)"
command -v curl     >/dev/null || die "curl not found"
command -v systemctl >/dev/null || die "systemctl not found (systemd user session required)"
python3 -m venv --help >/dev/null 2>&1 || die "python3-venv not available"
if ! command -v voxtype >/dev/null; then
  warn "voxtype not found — server will be installed, but voxtype config step will be skipped"
  warn "install voxtype first (push-to-talk daemon) and re-run this script to wire it up"
fi

# ---------------------------------------------------------------- 1. model files
log "Downloading model files (ai-sage/GigaAM-v3 @ e2e_rnnt) if missing..."
mkdir -p "$MODEL_DIR"
for f in config.json modeling_gigaam.py tokenizer.model pytorch_model.bin; do
  if [ -s "$MODEL_DIR/$f" ]; then
    echo "   present: $f"
  else
    echo "   fetching: $f"
    curl -fL --retry 3 --silent --show-error -o "$MODEL_DIR/$f" "$MODEL_BASE_URL/$f" \
      || die "failed to download $f"
  fi
done

# ---------------------------------------------------------------- 2. venv (pinned!)
if [ -x "$VENV_DIR/bin/python" ]; then
  log "venv already exists at $VENV_DIR (leaving as-is; delete it to force a rebuild)"
else
  log "Creating venv at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi
PIP="$VENV_DIR/bin/pip"

log "Installing pinned torch (CPU) + torchaudio..."
"$PIP" install --quiet torch==2.9.1 torchaudio==2.9.1 \
  --index-url https://download.pytorch.org/whl/cpu

log "Installing pinned transformers and runtime deps (this can take a few minutes)..."
"$PIP" install --quiet -r "$REPO_DIR/requirements.txt"

# ---------------------------------------------------------------- 3. server.py
log "Installing server.py ..."
install -m 644 "$REPO_DIR/server/server.py" "$GIGAAM_DIR/server.py"

# ---------------------------------------------------------------- 4. systemd units
log "Installing systemd user units ..."
mkdir -p "$SYSTEMD_DIR" "$HOME/.local/bin"
for u in gigaam-server.service gigaam-watchdog.service gigaam-watchdog.timer; do
  [ -f "$SYSTEMD_DIR/$u" ] && cp -a "$SYSTEMD_DIR/$u" "$SYSTEMD_DIR/$u.bak.$TS"
  install -m 644 "$REPO_DIR/systemd/$u" "$SYSTEMD_DIR/$u"
done
[ -f "$HOME/.local/bin/gigaam-watchdog.sh" ] && cp -a "$HOME/.local/bin/gigaam-watchdog.sh" "$HOME/.local/bin/gigaam-watchdog.sh.bak.$TS"
install -m 755 "$REPO_DIR/scripts/gigaam-watchdog.sh" "$HOME/.local/bin/gigaam-watchdog.sh"

systemctl --user daemon-reload
systemctl --user enable --now gigaam-server.service
systemctl --user enable --now gigaam-watchdog.timer

# ---------------------------------------------------------------- 5. wait for server
log "Waiting for gigaam-server to become healthy (model load ~5-15 s on first run)..."
ok=0
for i in $(seq 1 60); do
  if curl -sf -m 5 http://127.0.0.1:8394/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || {
  echo "--- last journal lines: ---"
  journalctl --user -u gigaam-server -n 30 --no-pager || true
  die "gigaam-server did not become healthy — see journal above"
}
curl -sf -m 5 http://127.0.0.1:8394/health; echo

# ---------------------------------------------------------------- 6. voxtype config
VXC="$HOME/.config/voxtype/config.toml"
if [ ! -f "$VXC" ]; then
  warn "$VXC not found — skipping voxtype config merge (install voxtype, then re-run)"
else
  log "Merging remote-mode settings into voxtype config (hotkey section is preserved)..."
  cp -a "$VXC" "$VXC.bak.$TS"
  python3 - "$VXC" "$REPO_DIR/config/voxtype-config.toml" <<'PYEOF'
import sys, re

target_path, template_path = sys.argv[1], sys.argv[2]
target = open(target_path).read()
tpl = open(template_path).read()

def sections(text):
    out, cur = {"__top__": []}, "__top__"
    for line in text.splitlines():
        m = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if m:
            cur = m.group(1); out.setdefault(cur, [])
        else:
            out[cur].append(line)
    return out

tgt, tpl_s = sections(target), sections(tpl)

NEVER_TOUCH = {"hotkey", "osd", "status"}  # user's keybindings/UI prefs stay theirs

for name, lines in tpl_s.items():
    if name == "__top__":
        continue  # top-level keys (engine) handled below
    if name in NEVER_TOUCH and name in tgt:
        continue  # user already has this section - leave it untouched
    body = "\n".join(lines).strip("\n")
    # replace whole section in target
    pattern = re.compile(r"^\[" + re.escape(name) + r"\]\s*$(?:\n(?!\[).*)*", re.M)
    if pattern.search(target):
        target = pattern.sub("[" + name + "]\n" + body, target, count=1)
    else:
        if not target.endswith("\n"):
            target += "\n"
        target += "\n[" + name + "]\n" + body + "\n"

# top-level keys from template
for line in tpl_s["__top__"]:
    m = re.match(r"^(\w+)\s*=", line.strip())
    if m:
        key = m.group(1)
        tpat = re.compile(r"^" + re.escape(key) + r"\s*=.*$", re.M)
        if tpat.search(target):
            target = tpat.sub(line.strip(), target, count=1)
        else:
            # insert among top-level keys only (before the first section header)
            lines = target.splitlines()
            first_sec = next((i for i, l in enumerate(lines) if re.match(r"^\s*\[", l)), len(lines))
            insert_at = first_sec
            # if there are existing top-level keys, append after the last of them
            for i in range(first_sec - 1, -1, -1):
                if re.match(r"^\w+\s*=", lines[i]):
                    insert_at = i + 1
                    break
            lines.insert(insert_at, line.strip())
            target = "\n".join(lines)

open(target_path, "w").write(target)
print("   merged OK")
PYEOF
  log "voxtype config updated (backup: $VXC.bak.$TS). Restarting voxtype..."
  systemctl --user restart voxtype || warn "could not restart voxtype.service — restart it manually"
  sleep 2
  systemctl --user is-active voxtype || warn "voxtype.service is not active — check journalctl --user -u voxtype"
fi

# ---------------------------------------------------------------- done
log "Install complete. Run ./verify.sh to run acceptance tests."
log "Then hold your push-to-talk key and speak Russian."
