#!/bin/bash
# Restarts gigaam-server if /health (lock-aware) does not respond in time.
# Catches both dead process and inference deadlock (lock held forever).
URL=http://127.0.0.1:8394/health
if ! curl -sf -m 15 "$URL" -o /dev/null 2>/dev/null; then
    sleep 5
    if ! curl -sf -m 15 "$URL" -o /dev/null 2>/dev/null; then
        logger -t gigaam-watchdog "health check failed twice, restarting gigaam-server"
        systemctl --user restart gigaam-server.service
    fi
fi
