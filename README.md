# voxtype-gigaam

Agent-first installer that puts **GigaAM v3 e2e RNN-T** — state-of-the-art Russian ASR
with punctuation and text normalization — behind the **voxtype** push-to-talk voice-input
daemon on Linux.

Everything runs **locally on CPU** (no cloud, no GPU required): voxtype records the mic
and POSTs audio to a small local server (`127.0.0.1:8394`, OpenAI-compatible
`/v1/audio/transcriptions`) which runs GigaAM v3 and types the text for you.

Verified on **Arch-based Linux (CachyOS) under both niri and GNOME** (Wayland sessions),
voxtype 1.0.1, Python 3.14. Should work on any distro with systemd user sessions.

## Why GigaAM v3 e2e RNN-T

- SOTA Russian WER (avg **8.4%** across domains vs Whisper large-v3 ~25% — author benchmarks)
- Produces **punctuated, normalized** text directly (e2e model)
- Fast on CPU: **~20-24× realtime** (25 s of audio ≈ 1.2 s of inference)

## Architecture

```
PTT key (push-to-talk)
        │
        ▼
voxtype daemon ──HTTP POST /v1/audio/transcriptions──▶ gigaam-server (FastAPI, 127.0.0.1:8394)
        ▲                                                        │
        │                                              GigaAM v3 e2e RNN-T (CPU, torch)
        └──────────────── typed text ◀──────────────────────────┘
```

A watchdog timer (every 15 s) restarts the ASR server if it hangs or dies, so the
push-to-talk button never goes silently dead.

## Quick start

```bash
git clone https://github.com/p82o/voxtype-gigaam.git
cd voxtype-gigaam
./install.sh          # downloads model (~430 MB), builds venv, installs user units
./verify.sh           # acceptance tests
```

Then hold your push-to-talk key and speak Russian. That's it.

## Requirements

- Linux with a **systemd user session** (Wayland or X11)
- `python3` (≥ 3.10; tested on 3.14), `ffmpeg`, `curl`, `git`
- **voxtype** installed (push-to-talk daemon; on Arch: `voxtype-bin` from AUR / your repo)
- ~2 GB disk (venv ~1.6 GB + model 430 MB)
- **No root required** — everything is installed under `$HOME`

## What `install.sh` does

1. Downloads 4 model files from [ai-sage/GigaAM-v3 @ e2e_rnnt](https://huggingface.co/ai-sage/GigaAM-v3/tree/e2e_rnnt)
   into `~/.local/share/gigaam/model/` (skips files already present).
2. Creates `~/.local/share/gigaam/venv` with **pinned** versions:
   `torch==2.9.1 + torchaudio==2.9.1` (CPU wheels), `transformers==4.57.6`,
   plus runtime deps (`fastapi`, `uvicorn`, `pytorch-lightning`, `pyannote.audio`,
   `python-multipart`, …). Version pins are **load-bearing** — see Troubleshooting.
3. Copies `server.py` (OpenAI-compatible ASR server) to `~/.local/share/gigaam/`.
4. Installs and enables user units: `gigaam-server.service` (auto-restart on failure)
   and `gigaam-watchdog.timer` + `gigaam-watchdog.sh` (health-check → restart on hang).
5. Merges `voxtype-config.toml` into `~/.config/voxtype/config.toml`:
   switches voxtype to `mode = "remote"` with this server, sets `max_duration_secs = 300`,
   **and preserves your existing `[hotkey]` section untouched** (existing config is backed up).

Existing files are backed up as `*.bak.<timestamp>` before being overwritten. The script
is idempotent — safe to re-run.

## What changes on your system

| Path | What |
|---|---|
| `~/.local/share/gigaam/{model,venv,server.py}` | model, venv, server script |
| `~/.config/systemd/user/gigaam-server.service` | ASR server unit |
| `~/.config/systemd/user/gigaam-watchdog.{service,timer}`, `~/.local/bin/gigaam-watchdog.sh` | watchdog |
| `~/.config/voxtype/config.toml` | voxtype switched to remote mode (backup kept) |

Network use: model from Hugging Face, packages from PyPI, optional test wav from Sber CDN
(during `verify.sh`). The ASR server itself binds to `127.0.0.1` only and makes no calls.

## Verify

```bash
./verify.sh               # full acceptance suite
./verify.sh --skip-watchdog   # skip the watchdog-restart test
```

Checks: `/health`, the 25-second deadlock regression (audio just over 25 s — the exact
boundary where an older version deadlocked), watchdog recovery, real-speech transcription
(the model authors' `example.wav` → an excerpt from *Eugene Onegin*), and — if voxtype is
present — full end-to-end `voxtype transcribe` through the remote config.

## Rollback / uninstall

```bash
systemctl --user disable --now gigaam-watchdog.timer gigaam-server.service
rm ~/.config/systemd/user/gigaam-server.service \
   ~/.config/systemd/user/gigaam-watchdog.{service,timer} ~/.local/bin/gigaam-watchdog.sh
systemctl --user daemon-reload
cp ~/.config/voxtype/config.toml.bak.<timestamp> ~/.config/voxtype/config.toml   # restore prev config
systemctl --user restart voxtype
rm -rf ~/.local/share/gigaam
```

## Troubleshooting (short index)

Battle-tested notes with full details are in **[docs/notes-ru.md](docs/notes-ru.md)** (Russian).

| Symptom | Cause / fix |
|---|---|
| Server 200 OK but `{"text": ""}` on synthetic/espeak audio | Known model trait, not a bug — test with real speech (`verify.sh` does) |
| Transcriptions silently stop responding, unit still "active" | Old deadlock bug — make sure `server.py` is from this repo (`RLock` fix) |
| `Form data requires "python-multipart"` | `pip install python-multipart` in the venv |
| `Tensor on device cpu is not on the expected device meta` | transformers ≥ 5.x is incompatible — pin `transformers==4.57.6` |
| `ImportError: ... hydra, omegaconf, pyannote, sentencepiece` | install `hydra-core omegaconf sentencepiece pyannote.audio` |
| voxtype cuts recording at 25 s | raise `audio.max_duration_secs` (restart voxtype) |
| Mic noise in silence | ALSA capture/boost too hot — see notes-ru.md §3, persist with `pkexec alsactl store` |

## Agent guidance

If you are an AI agent deploying this for a user: read **[AGENTS.md](AGENTS.md)** first —
it contains preconditions, the exact procedure, acceptance criteria, do-nots, and rollback.

## Credits & license

- Model: [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) (MIT, Sber),
  paper: *GigaAM: Efficient Self-Supervised Learner for Speech Recognition* (InterSpeech 2025)
- Voice input daemon: [voxtype](https://github.com/wstcegg/voxtype)
- Code here: MIT — see [LICENSE](LICENSE)
