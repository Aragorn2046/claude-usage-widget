#!/bin/bash
# Syncs Claude credentials from WSL to Windows so the widget can read them.
# Runs in a loop every 30 seconds.
# Add to your .bashrc or run in background: nohup bash ~/Tools/claude-usage/sync-credentials.sh &

SRC="$HOME/.claude/.credentials.json"
WIN_USER=$(cmd.exe /C "echo %USERNAME%" 2>/dev/null | tr -d '\r')
DST="/mnt/c/Users/${WIN_USER}/.claude/.credentials.json"

while true; do
    if [ -f "$SRC" ]; then
        # Only copy if source is newer
        if [ "$SRC" -nt "$DST" ] 2>/dev/null || [ ! -f "$DST" ]; then
            cp "$SRC" "$DST" 2>/dev/null
        fi
    fi
    sleep 30
done
