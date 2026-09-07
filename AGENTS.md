# AGENTS.md — deploy GigaAM v3 e2e RNN-T into voxtype (push-to-talk voice input)

**Audience:** AI coding/ops agents (Claude Code, Codex, Hermes, etc.) executing this task
autonomously on a user's Linux machine. This file contains the complete task card:
preconditions, procedure, acceptance criteria, hard do-nots, and rollback. If the
preconditions hold, run `./install.sh && ./verify.sh` and validate the criteria below.

## Preconditions (check first, abort if unmet)

```bash
command -v voxtype && voxtype --version        # voxtype installed (1.x)
systemctl --user is-active voxtype             # daemon running
command -v python3 ffmpeg curl git             # base tools
python3 -m venv --help >/dev/null              # venv available
```

- Linux with a systemd **user** session (verified on Arch-based CachyOS under niri and GNOME).
- Python ≥ 3.10 (tested on 3.14). torch 2.9.1 CPU wheels exist for 3.14; for other Pythons
  keep the same pins, pip resolves the wheel.
- voxtype config exists at `~/.config/voxtype/config.toml` with a working `[hotkey]`
  section the user already uses.

## What you are deploying

```
PTT key → voxtype daemon → POST /v1/audio/transcriptions → gigaam-server (FastAPI, 127.0.0.1:8394)
                                                            → GigaAM v3 e2e RNN-T (CPU)
```

Local-only ASR server replacing whisper large-v3 as voxtype's engine. No root needed;
everything under `$HOME`; no new network services exposed (binds 127.0.0.1).

## Procedure

Run:

```bash
./install.sh
./verify.sh            # add --skip-watchdog to skip the restart test
```

`install.sh` is idempotent and backs up anything it overwrites as `*.bak.<ts>`:
model → `~/.local/share/gigaam/model/`, venv → `~/.local/share/gigaam/venv/`,
server → `~/.local/share/gigaam/server.py` (from `server/`), user units + watchdog →
systemd user units (from `systemd/`, `scripts/`), voxtype config → merged
(remote mode, `max_duration_secs=300`, **hotkey preserved**).

`install.sh` does NOT restart the voxtype service. After a successful verify, do it:

```bash
systemctl --user restart voxtype && sleep 3 && systemctl --user is-active voxtype
```

## Acceptance criteria (all must hold)

1. `systemctl --user is-active gigaam-server` → `active`;
   `curl -sf -m 15 http://127.0.0.1:8394/health` → HTTP 200, `{"status":"ok",...}`.
2. Deadlock regression: 25.003 s 16 kHz mono WAV → HTTP 200 within ~10 s, no hang
   (`verify.sh` does this; the boundary 25 s is the historical deadlock trigger).
3. Watchdog recovers a stopped server (`verify.sh` unless `--skip-watchdog`).
4. Real speech recognized: the model authors' `example.wav` → text containing an
   excerpt of *Eugene Onegin* in Russian ("Ничьих не требуя похвал…"). Empty result on
   synthetic/espeak audio is a known model trait — do not chase it.
5. End-to-end: `voxtype transcribe <some wav>` logs
   `Using remote whisper transcription mode`, `endpoint=http://127.0.0.1:8394` and
   prints Russian text. voxtype daemon `active`, `voxtype status` → `idle`.
6. User's `[hotkey]` section in `~/.config/voxtype/config.toml` is byte-identical to
   the pre-install backup.

## Hard do-nots

- **Never change the `[hotkey]` section** of the voxtype config. The user's push-to-talk
  key may be nonstandard (e.g. `EVTEST_582`); the template in this repo (`F9`) is only
  a reference. Merge everything else, keep their hotkey.
- Do not "upgrade" pins. `transformers==4.57.6` and `torch==2.9.1` are verified and
  **load-bearing**: transformers ≥ 5 breaks model init (meta-device error), other torch
  versions are untested. Bumps need re-verification, see docs/notes-ru.md.
- Do not replace the watchdog. The 25 s/15 s double-check tuning guards against
  false restarts during active transcription; `/health` must stay lock-aware.
- Do not run the ASR server outside the systemd user units "to test" manually with
  other ports/paths — config drift is how this stack breaks.
- `pkexec`/root: only ever for `alsactl store` (mic level persistence), if the user asks.

## Known-good references (2026-09, CachyOS, niri+GNOME, Python 3.14)

- torch/torchaudio 2.9.1+cpu, transformers 4.57.6, tokenizers 0.22.2, huggingface-hub 0.36.2
- extra deps the model's remote code needs: hydra-core, omegaconf, sentencepiece,
  pyannote.audio, python-multipart
- full transcripts, pitfalls and mic-gain procedure: **docs/notes-ru.md**

## Failure playbook

| Failure | Action |
|---|---|
| `install.sh` fails on pip | Read the log tail; missing packages are usually the cause — add to `requirements.txt`, rerun |
| Model loads, but empty text everywhere | venv versions drifted — recreate venv with pins (see notes-ru.md §5) |
| Server hangs on >25 s audio | You are running an old `server.py` without the `RLock` fix — copy from this repo |
| voxtype still uses whisper | It didn't pick up the config — `systemctl --user restart voxtype`, check `voxtype transcribe` logs |
| User wants the old engine back | Rollback section of README.md / `config.toml.bak.*` |

## Rollback

```bash
systemctl --user disable --now gigaam-watchdog.timer gigaam-server.service
rm -f ~/.config/systemd/user/gigaam-server.service \
      ~/.config/systemd/user/gigaam-watchdog.service \
      ~/.config/systemd/user/gigaam-watchdog.timer ~/.local/bin/gigaam-watchdog.sh
systemctl --user daemon-reload
cp "$(ls -t ~/.config/voxtype/config.toml.bak.* | head -1)" ~/.config/voxtype/config.toml
systemctl --user restart voxtype
# optional: rm -rf ~/.local/share/gigaam
```
