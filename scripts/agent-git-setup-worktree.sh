#!/bin/bash
# Worktree-safe variant of agent-git-setup.sh.
#
# Same flow — mint a short-lived GitHub App installation token, configure
# git + gh to act as the named bot — but scoped so parallel Claude Code
# sessions in different worktrees of the same repo don't clobber each
# other's identity.
#
# Differences from agent-git-setup.sh:
#   - All `git config` writes use `--worktree`, so they land in
#     <main-repo>/.git/worktrees/<name>/config.worktree instead of the
#     shared .git/config. Requires `extensions.worktreeConfig=true` on the
#     repo (set once; see README).
#   - The remote URL is set per-worktree too (it's a shared key by default).
#   - gh is authenticated into a per-worktree `GH_CONFIG_DIR` at
#     <git-dir>/gh-config rather than the shared ~/.config/gh. The
#     companion `claude` shell wrapper (see README) points GH_CONFIG_DIR
#     at this same path before launching Claude Code, so tool subprocesses
#     inherit it and `gh` reads the per-worktree hosts.yml natively — no
#     PATH shim or env-var smuggling required.
#
# Usage: agent-git-setup-worktree.sh <agent-name> [/path/to/worktree]

set -euo pipefail

AGENT_NAME="${1:-}"
REPO_PATH="${2:-.}"

if [ -z "$AGENT_NAME" ]; then
  echo "Usage: $0 <agent-name> [repo-path]" >&2
  exit 1
fi

CONFIG_FILE="$HOME/.secrets/agents/${AGENT_NAME}.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "No config for agent '$AGENT_NAME' at $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

for var in APP_ID INSTALLATION_ID BOT_USER_ID APP_SLUG PRIVATE_KEY_PATH REPO_URL; do
  if [ -z "${!var:-}" ]; then
    echo "Missing $var in $CONFIG_FILE" >&2
    exit 1
  fi
done

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
  echo "Private key not found at $PRIVATE_KEY_PATH" >&2
  exit 1
fi

# Without extensions.worktreeConfig, `git config --worktree` silently falls
# back to writing the shared .git/config and we lose isolation. Fail loudly
# instead so the user enables it once and moves on.
if [ "$(git -C "$REPO_PATH" config --get extensions.worktreeConfig 2>/dev/null || true)" != "true" ]; then
  echo "extensions.worktreeConfig is not enabled for this repo." >&2
  echo "Run once from the main repo or any worktree:" >&2
  echo "  git -C $REPO_PATH config extensions.worktreeConfig true" >&2
  exit 1
fi

# Mint a JWT signed with the App's private key (10-min validity).
JWT=$(python3 - <<EOF
import jwt, time, pathlib
key = pathlib.Path("$PRIVATE_KEY_PATH").read_text()
now = int(time.time())
print(jwt.encode({"iat": now - 60, "exp": now + 600, "iss": "$APP_ID"}, key, algorithm="RS256"))
EOF
)

# Exchange the JWT for a fresh installation access token (~1-hour validity).
TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" \
  | jq -r .token)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to get installation token for $AGENT_NAME" >&2
  exit 1
fi

# Per-worktree git identity. Writes land in
# <main-repo>/.git/worktrees/<name>/config.worktree, not the shared config.
git -C "$REPO_PATH" config --worktree user.name "${APP_SLUG}[bot]"
git -C "$REPO_PATH" config --worktree user.email "${BOT_USER_ID}+${APP_SLUG}[bot]@users.noreply.github.com"

# remote.origin.url is shared by default; promote it to per-worktree so
# parallel sessions on the same repo can have independent remotes if needed.
git -C "$REPO_PATH" config --worktree remote.origin.url "$REPO_URL"

# Resolve the absolute git dir for this worktree (per-worktree directory under
# <main-repo>/.git/worktrees/<name>/), so the credential helper sits inside
# it rather than in the shared .git/.
GIT_DIR=$(git -C "$REPO_PATH" rev-parse --git-dir)
GIT_DIR=$(cd "$REPO_PATH" && cd "$GIT_DIR" && pwd)

HELPER_PATH="$GIT_DIR/agent-credential-helper.sh"
cat > "$HELPER_PATH" <<EOF
#!/bin/bash
if [ "\$1" = "get" ]; then
  echo "username=x-access-token"
  echo "password=$TOKEN"
fi
EOF
chmod 700 "$HELPER_PATH"
git -C "$REPO_PATH" config --worktree credential.helper "!$HELPER_PATH"

# Per-worktree gh auth via GH_CONFIG_DIR. Each worktree gets its own
# hosts.yml; gh reads it natively, no wrapper involved. The launch-time
# `claude` shell function (see README) is responsible for exporting
# GH_CONFIG_DIR to the same path before claude starts, so tool subprocesses
# inherit it.
GH_DIR="$GIT_DIR/gh-config"
mkdir -p "$GH_DIR"
chmod 700 "$GH_DIR"
printf '%s' "$TOKEN" | GH_CONFIG_DIR="$GH_DIR" gh auth login --with-token --hostname github.com

# Sanity-check that this Claude Code session was launched with a matching
# GH_CONFIG_DIR. If it wasn't, gh tool calls will read the user's own
# ~/.config/gh instead and silently go out under the wrong identity.
if [ "${GH_CONFIG_DIR:-}" != "$GH_DIR" ]; then
  echo "WARNING: GH_CONFIG_DIR in this Claude Code env is '${GH_CONFIG_DIR:-<unset>}'," >&2
  echo "         but the worktree's gh config lives at '$GH_DIR'." >&2
  echo "         gh tool calls will not use the bot identity until you" >&2
  echo "         relaunch claude with the shell wrapper from the README." >&2
fi

echo "Agent git identity configured (worktree-scoped): $AGENT_NAME (${APP_SLUG}[bot])"
