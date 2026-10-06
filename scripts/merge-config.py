"""Merge ASR settings in place; retain the user's hotkey bytes and other settings."""
import hashlib
import re
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
original = path.read_bytes()
text = original.decode()
try:
    tomllib.loads(text)
except tomllib.TOMLDecodeError:
    raise SystemExit("Existing voxtype config is invalid") from None
settings = {
    "whisper": {
        "mode": '"remote"',
        "model": '"gigaam-v3-e2e-rnnt"',
        "remote_model": '"gigaam-v3-e2e-rnnt"',
        "remote_endpoint": '"http://127.0.0.1:8394"',
        "remote_timeout_secs": "60",
        "language": '"ru"',
    },
    "audio": {"max_duration_secs": "300"},
}

def section(text, name):
    return re.search(
        r"(?ms)^[ \t]*\[" + re.escape(name) + r"\][^\n]*(?:\n|$).*?(?=^[ \t]*\[|\Z)", text
    )

hotkey = section(text, "hotkey")
if hotkey is None:
    raise SystemExit("Existing [hotkey] section is required")
hotkey_bytes = hotkey.group(0).encode()
first = re.search(r"(?m)^[ \t]*\[", text)
top_end = first.start() if first else len(text)
top = text[:top_end]
pattern = r'(?m)^[ \t]*engine[ \t]*=.*$'
top = re.sub(pattern, 'engine = "whisper"', top) if re.search(pattern, top) else top + 'engine = "whisper"\n'
text = top + text[top_end:]
for name, values in settings.items():
    match = section(text, name)
    if match is None:
        # Insert before existing sections, preserving an EOF hotkey section too.
        first = re.search(r"(?m)^[ \t]*\[", text)
        text = text[:first.start()] + f"[{name}]\n" + text[first.start():]
        match = section(text, name)
    body = match.group(0)
    for key, value in values.items():
        pattern = r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=.*$"
        body = re.sub(pattern, f"{key} = {value}", body) if re.search(pattern, body) else body + ("" if body.endswith("\n") else "\n") + f"{key} = {value}\n"
    text = text[:match.start()] + body + text[match.end():]
if section(text, "hotkey").group(0).encode() != hotkey_bytes:
    raise SystemExit("Hotkey preservation check failed")
try:
    tomllib.loads(text)
except tomllib.TOMLDecodeError:
    raise SystemExit("Merged voxtype config is invalid") from None
if text.encode() != original:
    path.write_bytes(text.encode())
print(hashlib.sha256(hotkey_bytes).hexdigest())
