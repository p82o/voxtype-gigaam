#!/usr/bin/env bash
# Acceptance tests for the voxtype-gigaam stack.
# Usage: ./verify.sh [--skip-watchdog]
set -uo pipefail

SKIP_WATCHDOG=0
[ "${1:-}" = "--skip-watchdog" ] && SKIP_WATCHDOG=1

URL="http://127.0.0.1:8394"
PASS=0; FAIL=0

ok()  { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

check_unit() {
  if [ "$(systemctl --user is-active "$1" 2>/dev/null)" = "active" ]; then
    ok "$1 is active"
  else
    bad "$1 is NOT active"
  fi
}

check_health() {
  local body rc
  body=$(curl -sf -m 15 "$URL/health"); rc=$?
  if [ $rc -eq 0 ] && echo "$body" | grep -q '"status":"ok"'; then
    ok "/health -> $body"
  else
    bad "/health failed (rc=$rc, body=$body)"
  fi
}

# 1. units + health
check_unit gigaam-server.service
check_unit gigaam-watchdog.timer
check_health

# 2. deadlock regression: WAV just over 25 s must return 200 quickly, not hang
log25() {
  python3 - <<'EOF'
import wave, struct, math, random
w = wave.open('/tmp/test25s.wav','w')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b''.join(struct.pack('<h', int(12000*math.sin(i*0.05)*random.random())) for i in range(16000*25+50)))
w.close()
EOF
}
log25
t0=$(date +%s)
code=$(curl -s -m 40 -o /tmp/test25s_resp.json -w '%{http_code}' -F file=@/tmp/test25s.wav "$URL/v1/audio/transcriptions")
t1=$(date +%s); dt=$((t1 - t0))
if [ "$code" = "200" ] && [ "$dt" -le 35 ]; then
  ok "25s-audio regression: HTTP $code in ${dt}s (no deadlock)"
else
  bad "25s-audio regression: HTTP $code in ${dt}s"
fi

# 3. watchdog recovery
if [ "$SKIP_WATCHDOG" = 0 ]; then
  systemctl --user stop gigaam-server
  "$HOME/.local/bin/gigaam-watchdog.sh"
  # server needs a few seconds to load the model after restart
  rec=0
  for i in $(seq 1 30); do
    if curl -sf -m 5 "$URL/health" >/dev/null 2>&1; then rec=1; break; fi
    sleep 2
  done
  if [ "$rec" = 1 ] && [ "$(systemctl --user is-active gigaam-server)" = "active" ]; then
    ok "watchdog restarted a stopped server"
  else
    bad "watchdog did not recover the server"
  fi
else
  echo "SKIP watchdog test (--skip-watchdog)"
fi

# 4. real speech: the model authors' example.wav -> Eugene Onegin excerpt
EX=/tmp/gigaam_example.wav
if [ ! -s "$EX" ]; then
  curl -fsSL -m 60 -o "$EX" "https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/example.wav" \
    || echo "WARN: could not download example.wav (offline?) — skipping speech test"
fi
if [ -s "$EX" ]; then
  resp=$(curl -s -m 60 -F file=@"$EX" "$URL/v1/audio/transcriptions")
  if echo "$resp" | grep -q 'похвал\|лукоморья\|надеждой'; then
    ok "real speech recognized (Eugene Onegin excerpt)"
    echo "     $resp"
  else
    bad "real speech NOT recognized: $resp"
  fi
fi

# 5. end-to-end through voxtype (if voxtype present)
if command -v voxtype >/dev/null && [ -s "$EX" ]; then
  if vox_out=$(voxtype transcribe "$EX" 2>&1) && echo "$vox_out" | grep -q 'лукоморья\|похвал'; then
    if echo "$vox_out" | grep -q 'remote'; then
      ok "voxtype end-to-end via remote endpoint"
    else
      ok "voxtype end-to-end works (but did not log 'remote' — check config)"
    fi
    echo "     $(echo "$vox_out" | tail -n1)"
  else
    bad "voxtype transcribe failed: $vox_out"
  fi
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
