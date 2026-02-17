#!/usr/bin/env bash
# Quit all Forum Badge instances (by name and by process)
osascript -e 'quit app "Forum Badge"' 2>/dev/null || true
pkill -x ForumBadge 2>/dev/null || true
echo "Stopped Forum Badge (if it was running)."
echo "Press any key to close this window."
read -n 1 -s
