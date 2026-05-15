#!/bin/bash
# Claude Code Notification + Stop hook handler.
# Reads the hook payload (JSON on stdin) and shows a macOS notification with
# the worktree/repo root name as the subtitle, so notifications from parallel
# sessions in different worktrees don't get collapsed by Notification Center.

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')

case "$EVENT" in
  Stop)
    MSG=$(printf '%s' "$INPUT" | jq -r '.message // "Session finished"')
    ;;
  PermissionRequest)
    TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // "a command"')
    MSG="Permission needed: $TOOL"
    ;;
  *)
    MSG=$(printf '%s' "$INPUT" | jq -r '.message // "Claude needs your input"')
    ;;
esac

ROOT=""
if [ -n "$CWD" ]; then
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
fi
if [ -z "$ROOT" ]; then
  ROOT="$CWD"
fi
NAME=$(basename "$ROOT")
[ -z "$NAME" ] && NAME="Claude"

# Play sound directly — osascript's `sound name` is silently suppressed when
# the host app's notification settings have "Play sound" disabled.
afplay /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 &

export MSG NAME
osascript -e 'display notification (system attribute "MSG") with title "Claude Code" subtitle (system attribute "NAME")'