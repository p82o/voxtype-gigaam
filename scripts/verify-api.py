"""ASR acceptance: deterministic boundary audio, official speech, long speech."""
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import wave

URL = "http://127.0.0.1:8394"

def transcribe(data):
    boundary = "gigaam-acceptance-audio"
    payload = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="test.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
        + data + f"\r\n--{boundary}--\r\n".encode()
    )
    request = urllib.request.Request(URL + "/v1/audio/transcriptions", data=payload, headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    start = time.monotonic()
    with urllib.request.urlopen(request, timeout=40) as response:
        result = json.load(response)
    return result["text"], round(time.monotonic() - start, 3)

def wav_bytes(frames):
    result = io.BytesIO()
    with wave.open(result, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(frames)
    return result.getvalue()

try:
    results = {}
    boundary_audio = wav_bytes(b"".join(struct.pack("<h", int(6000 * math.sin(i * 0.05))) for i in range(16000 * 25 + 50)))
    sample = Path(sys.argv[1]).read_bytes()
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-f", "s16le", "-ac", "1", "-ar", "16000", "-"], capture_output=True, check=True).stdout
    long_audio = wav_bytes((pcm * (16000 * 60 * 2 // len(pcm) + 1))[:16000 * 60 * 2])
    for name, data in (("boundary_25s", boundary_audio), ("official_speech", sample), ("speech_60s", long_audio)):
        text, seconds = transcribe(data)
        if name != "boundary_25s" and not any(marker in text.lower() for marker in ("похвал", "лукоморья", "надеждой")):
            raise ValueError("Speech recognition check failed")
        if seconds > 35:
            raise ValueError("Inference exceeded acceptance timeout")
        results[name] = {"seconds": seconds, "text_sha256": hashlib.sha256(text.encode()).hexdigest()}
    # Invalid input must be rejected without returning inference errors or paths.
    for invalid, expected_status in ((b"", 400), (b"invalid audio", 500)):
        try:
            transcribe(invalid)
        except urllib.error.HTTPError as error:
            if error.code != expected_status:
                raise ValueError("Invalid audio was not rejected correctly") from None
            if expected_status == 500 and json.load(error) != {"detail": "transcription failed"}:
                raise ValueError("Inference error details were exposed")
        else:
            raise ValueError("Invalid audio was accepted")
    with urllib.request.urlopen(URL + "/health", timeout=15) as response:
        if json.load(response)["status"] != "ok":
            raise ValueError("Server did not recover after invalid audio")
    print(json.dumps(results, sort_keys=True))
except Exception as error:
    print("ASR acceptance failed:", type(error).__name__, file=sys.stderr)
    sys.exit(1)
