#!/bin/bash
# Mints a short-lived GitHub App installation token and configures git + gh
# to act as the named bot identity for the duration of the session.
#
# Usage: agent-git-setup.sh <agent-name> [/path/to/repo]
# Reads credentials from ~/.secrets/agents/<agent-name>.env

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

# Set the git identity so commits are authored by the bot.
git -C "$REPO_PATH" config user.name "${APP_SLUG}[bot]"
git -C "$REPO_PATH" config user.email "${BOT_USER_ID}+${APP_SLUG}[bot]@users.noreply.github.com"

# Reset the remote URL to a clean form (no token embedded — that lives in the helper).
git -C "$REPO_PATH" remote set-url origin "$REPO_URL"

# Resolve the absolute git dir (works for both regular repos and worktrees).
GIT_DIR=$(git -C "$REPO_PATH" rev-parse --git-dir)
GIT_DIR=$(cd "$REPO_PATH" && cd "$GIT_DIR" && pwd)

# Write a credential helper that injects the installation token on demand.
HELPER_PATH="$GIT_DIR/agent-credential-helper.sh"
cat > "$HELPER_PATH" <<EOF
#!/bin/bash
if [ "\$1" = "get" ]; then
  echo "username=x-access-token"
  echo "password=$TOKEN"
fi
EOF
chmod 700 "$HELPER_PATH"
git -C "$REPO_PATH" config credential.helper "!$HELPER_PATH"

# Authenticate gh CLI as this bot for the rest of the session.
echo "$TOKEN" | gh auth login --with-token

echo "Agent git identity configured: $AGENT_NAME (${APP_SLUG}[bot])"
