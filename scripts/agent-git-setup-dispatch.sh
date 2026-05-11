#!/bin/bash
# Reads the tool-call JSON Claude Code passes on stdin, picks reviewer vs
# implementer based on the un-stripped command, and delegates to
# agent-git-setup.sh.
#
# Workaround: Claude Code's hook `if:` matchers strip leading VAR=value
# assignments before matching, so a hook can't tell reviewer-prefixed
# commands from implementer ones via `if:` alone. Reading stdin gives us
# the raw command.

set -euo pipefail

cmd=$(jq -r .tool_input.command)

if [[ "$cmd" == "CLAUDE_AGENT_NAME=reviewer "* ]]; then
  exec ~/.scripts/agent-git-setup.sh reviewer "$CLAUDE_PROJECT_DIR"
else
  exec ~/.scripts/agent-git-setup.sh implementer "$CLAUDE_PROJECT_DIR"
fi
