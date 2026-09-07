import logging
import os
import sys
import tempfile
import threading

MODEL_DIR = os.path.expanduser("~/.local/share/gigaam/model")
sys.path.insert(0, MODEL_DIR)

import torch  # noqa: E402
from transformers import AutoModel  # noqa: E402
from fastapi import FastAPI, File, Form, HTTPException, UploadFile  # noqa: E402
import uvicorn  # noqa: E402

SAMPLE_RATE = 16000
MAX_SHORT = 25 * SAMPLE_RATE
CHUNK = 22 * SAMPLE_RATE
PORT = 8394

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gigaam-server")

log.info("loading GigaAM v3 e2e RNN-T from %s ...", MODEL_DIR)
model = AutoModel.from_pretrained(
    MODEL_DIR, trust_remote_code=True, local_files_only=True
)
model.eval()
torch.set_grad_enabled(False)
_lock = threading.RLock()
log.info("model ready")

from modeling_gigaam import load_audio  # noqa: E402

app = FastAPI(title="gigaam-asr", docs_url=None, redoc_url=None)


def _transcribe_path(path: str) -> str:
    wav = load_audio(path)
    n = wav.shape[-1]
    if n == 0:
        return ""
    inner = model.model
    if n <= MAX_SHORT:
        return inner.transcribe(path).strip()
    parts = []
    with _lock:
        for start in range(0, n, CHUNK):
            chunk = wav[start : start + CHUNK]
            w = chunk.unsqueeze(0).to(inner._device).to(inner._dtype)
            length = torch.full([1], w.shape[-1], device=inner._device)
            enc, enc_len = inner.forward(w, length)
            parts.append(inner.decoding.decode(inner.head, enc, enc_len)[0])
    return " ".join(p.strip() for p in parts if p.strip()).strip()


@app.get("/health")
def health():
    with _lock:
        return {"status": "ok", "model": "gigaam-v3-e2e-rnnt"}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model_name: str = Form(default=None),
    language: str = Form(default=None),
    response_format: str = Form(default="json"),
):
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio payload")
    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    try:
        tmp.write(data)
        tmp.close()
        with _lock:
            text = _transcribe_path(tmp.name)
    except HTTPException:
        raise
    except Exception as exc:
        log.exception("transcription failed")
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
    log.info("transcribed %d bytes -> %r", len(data), text[:80])
    return {"text": text}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
