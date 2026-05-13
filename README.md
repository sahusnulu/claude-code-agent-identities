# Claude Agents - Per-Agent GitHub Identities

A pattern for giving each Claude Code subagent (implementer, reviewer, etc.) its own GitHub App identity, so commits, PRs, and review comments are attributed to a distinct bot account instead of all blurring into one user.

Inspired by [Each AI agent gets its own GitHub identity](https://dev.to/agent_paaru/each-ai-agent-gets-its-own-github-identity-how-we-gave-every-bot-its-own-bot-commit-signature-1197).

---

## Why

If a single Claude Code project uses multiple subagents or different sessions (say one that writes code and another that reviews it) every commit, push, PR, and comment goes out under whatever your `git config user.email` happens to be. You lose the ability to tell at a glance which agent did what.

Giving each agent its own GitHub App identity fixes that. Commits show up authored by `myagent-implementer[bot]`, review comments by `myagent-reviewer[bot]`, and etc. Each can be setup with a distinct avatar, a distinct API token, and a distinct permission scope.

This repo documents how to set it up. It assumes you're using [Claude Code](https://claude.com/claude-code) and roughly the orchestrator-plus-subagents workflow (ex. one agent implements, another reviews, the orchestrator handles git).

---

## What you end up with

```
~/.secrets/
├── agents/
│   ├── implementer.env       # APP_ID, INSTALLATION_ID, etc. for the implementer bot
│   └── reviewer.env          # same, for the reviewer bot
└── keys/
    ├── implementer.pem       # GitHub App private key for implementer
    └── reviewer.pem          # same, for reviewer

~/.scripts/
├── agent-git-setup.sh           # mints an installation token, configures git + gh
├── agent-git-setup-dispatch.sh  # picks identity based on CLAUDE_AGENT_NAME prefix
├── agent-git-setup-worktree.sh  # worktree-scoped variant; see "parallel worktrees" section
└── agent-gh                     # per-call gh wrapper used by the worktree variant

<your-repo>/.claude/
├── settings.json             # PreToolUse hooks that invoke the setup scripts
└── agents/
    ├── implementer.md        # subagent definitions
    └── reviewer.md
```

The directory layout in this repo mirrors the production layout above, so each file you'll find here sits at the same path it goes in your real project:

| In this repo | Goes to |
|---|---|
| `.claude/settings.json` | `<your-repo>/.claude/settings.json` |
| `.claude/agents/implementer.md` | `<your-repo>/.claude/agents/implementer.md` |
| `.claude/agents/reviewer.md` | `<your-repo>/.claude/agents/reviewer.md` |
| `scripts/agent-git-setup.sh` | `~/.scripts/agent-git-setup.sh` |
| `scripts/agent-git-setup-dispatch.sh` | `~/.scripts/agent-git-setup-dispatch.sh` |
| `scripts/agent-git-setup-worktree.sh` | `~/.scripts/agent-git-setup-worktree.sh` (only if running [parallel sessions across worktrees](#running-parallel-claude-code-sessions-across-worktrees)) |
| `scripts/agent-gh` | `~/.scripts/agent-gh` (only if running [parallel sessions across worktrees](#running-parallel-claude-code-sessions-across-worktrees)) |
| `agent-envs/implementer.env.example` | `~/.secrets/agents/implementer.env` (drop the `.example` suffix, fill in real values) |
| `agent-envs/reviewer.env.example` | `~/.secrets/agents/reviewer.env` |

The subagent `.md` files have `<your-project>` placeholders for the build root, language, and module layout. Fill those in when you copy.

`~/.secrets/` and `~/.scripts/` are conventions, you can put them anywhere. If you change them, update the hook `command:` paths in `.claude/settings.json` to match.

When the orchestrator runs `git commit`, a Claude Code `PreToolUse` hook fires `agent-git-setup.sh implementer`, which mints a fresh installation token from the App's private key, writes a credential helper, and points `git`/`gh` at the implementer identity. The commit goes out as `implementer[bot]`.

For commands that aren't bound to a single agent (review comments, issue comments, etc.) the hook fires `agent-git-setup-dispatch.sh` instead. The dispatch script reads the raw command off stdin and picks the identity based on a `CLAUDE_AGENT_NAME=<agent>` prefix (ex. `CLAUDE_AGENT_NAME=reviewer gh pr comment ...`), falling back to implementer when no prefix is set. **If you run three or more agents, dispatch is where most of your wiring lives**. See [Wire up the setup scripts](#wire-up-the-setup-scripts) for how to extend it.

---

## Prerequisites

- A GitHub account (personal or org) where you can create GitHub Apps.
- `gh` CLI installed and authenticated as yourself (the App tokens replace this per-command).
- `jq`, `curl`, `python3` with the `pyjwt` package (`pip install pyjwt`).
- A Claude Code project you want to wire this into.

---

## One-time setup, per agent identity

You repeat steps 1-4 once per bot you want (ex. once for the implementer, once for the reviewer).

### 1. Create the GitHub App

1. **GitHub → Settings → Developer Settings → GitHub Apps → New GitHub App**
2. **App name:** `myagent-implementer` (or whatever - must be unique on GitHub)
3. **Homepage URL:** anything works; the repo URL is fine
4. **Webhook:** uncheck "Active" - agents don't need incoming webhooks
5. **Repository permissions:** grant only what the agent needs:
    - **Contents:** Read & Write - for commits and pushes
    - **Pull requests:** Read & Write - for opening PRs and posting review comments
    - **Issues:** Read & Write - if your agents comment on issues
    - **Metadata:** Read - always required
6. **Where can this app be installed?** → "Only on this account"
7. Click **Create GitHub App**. Note the **App ID** shown near the top of the settings page.
8. Scroll to **Private keys** → **Generate a private key**. A `.pem` file downloads.

### 2. Install the App on your repo

1. From the App settings page, click **Install App** in the left sidebar.
2. Choose your account / org → **Only select repositories** → pick the repo.
3. After install, the URL becomes `.../settings/installations/12345678`. The trailing number is your **Installation ID** - note it down.

### 3. Look up the bot user ID

The bot's numeric user ID isn't shown in the UI. Fetch it from the API:

```bash
curl -s https://api.github.com/users/myagent-implementer%5Bbot%5D | jq .id
```

`%5B` and `%5D` are URL-encoded `[` and `]` - bot usernames on GitHub include the literal `[bot]` suffix. The number returned is your **BOT_USER_ID**. This is what GitHub uses to attach the bot's avatar and profile to commits.

### 4. Place the credentials on disk

Move the downloaded `.pem` file to `~/.secrets/keys/` and lock it down:

```bash
mkdir -p ~/.secrets/keys ~/.secrets/agents
mv ~/Downloads/myagent-implementer.*.private-key.pem ~/.secrets/keys/implementer.pem
chmod 600 ~/.secrets/keys/implementer.pem
```

Create `~/.secrets/agents/implementer.env`:

```bash
# GitHub App: myagent-implementer
APP_ID="123456"
INSTALLATION_ID="78901234"
BOT_USER_ID="56789012"
APP_SLUG="myagent-implementer"
PRIVATE_KEY_PATH="$HOME/.secrets/keys/implementer.pem"
REPO_URL="https://github.com/your-org/your-repo.git"
```

```bash
chmod 600 ~/.secrets/agents/implementer.env
```

The `APP_SLUG` is the URL-friendly form of the App name - confirm by visiting `https://github.com/apps/<slug>`. Bot accounts on GitHub append `[bot]`, so commits will be authored by `myagent-implementer[bot]`.

Repeat steps 1–4 for the reviewer (or any other agent), saving as `reviewer.env` and `reviewer.pem`.

---

## Wire up the setup scripts

Copy the two scripts from this repo's `scripts/` directory into `~/.scripts/`:

```bash
mkdir -p ~/.scripts
cp scripts/agent-git-setup.sh ~/.scripts/
cp scripts/agent-git-setup-dispatch.sh ~/.scripts/
chmod +x ~/.scripts/agent-git-setup*.sh
```

What they do:

- **`agent-git-setup.sh <agent-name> [<repo-path>]`** - sources `~/.secrets/agents/<agent-name>.env`, mints a JWT from the private key, exchanges it for a fresh installation token, configures `git` `user.name`/`user.email`, writes a per-repo credential helper that injects the token, and runs `gh auth login --with-token` so `gh` calls also use the bot identity.
- **`agent-git-setup-dispatch.sh`** - reads the tool-call JSON Claude Code passes on stdin, looks at the un-stripped command, and invokes `agent-git-setup.sh` with `reviewer` if the command starts with `CLAUDE_AGENT_NAME=reviewer`, otherwise `implementer`. This exists because Claude Code strips leading `VAR=value` assignments before evaluating hook `if:` matchers, so a hook can't otherwise tell the two apart.

### Extending dispatch to more agents

If you add a third agent (say, `docwriter`), the dispatch script needs a new branch. The shape:

```bash
#!/bin/bash
set -euo pipefail

cmd=$(jq -r .tool_input.command)

case "$cmd" in
  "CLAUDE_AGENT_NAME=reviewer "*)   agent="reviewer"  ;;
  "CLAUDE_AGENT_NAME=docwriter "*)  agent="docwriter" ;;  # ← add new agents here
  *)                                agent="implementer" ;; # default when no prefix
esac

exec ~/.scripts/agent-git-setup.sh "$agent" "$CLAUDE_PROJECT_DIR"
```

Each new agent also needs:
- Its own `.env` and `.pem` under `~/.secrets/` (repeat the [one-time setup](#one-time-setup-per-agent-identity) steps).
- A `.claude/agents/<name>.md` definition that reminds the agent to prefix its `gh` commands with `CLAUDE_AGENT_NAME=<name>`.
- Matching `permissions.allow` entries in `.claude/settings.json` (see the next section).

---

## Wire up Claude Code hooks

Add the hook block from `.claude/settings.json` in this repo to your project's `.claude/settings.json`. The relevant pieces:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "if": "Bash(git commit*)",     "command": "~/.scripts/agent-git-setup.sh implementer $CLAUDE_PROJECT_DIR" },
          { "type": "command", "if": "Bash(git push*)",       "command": "~/.scripts/agent-git-setup.sh implementer $CLAUDE_PROJECT_DIR" },
          { "type": "command", "if": "Bash(gh pr create*)",   "command": "~/.scripts/agent-git-setup.sh implementer $CLAUDE_PROJECT_DIR" },
          { "type": "command", "if": "Bash(gh pr comment*)",  "command": "~/.scripts/agent-git-setup-dispatch.sh" },
          { "type": "command", "if": "Bash(gh pr review*)",   "command": "~/.scripts/agent-git-setup-dispatch.sh" },
          { "type": "command", "if": "Bash(gh issue comment*)", "command": "~/.scripts/agent-git-setup-dispatch.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "cd $CLAUDE_PROJECT_DIR && GITDIR=$(git rev-parse --git-dir) && git config --unset user.name 2>/dev/null; git config --unset user.email 2>/dev/null; git config --unset credential.helper 2>/dev/null; rm -f \"$GITDIR/agent-credential-helper.sh\"; git remote set-url origin https://github.com/your-org/your-repo.git; gh auth logout --hostname github.com 2>/dev/null"
        }
      }
    ]
  }
}
```

You'll also want matching entries in `permissions.allow` so the reviewer-prefixed `gh` commands aren't blocked. In the same `.claude/settings.json`:

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(CLAUDE_AGENT_NAME=reviewer gh pr comment*)",
      "Bash(CLAUDE_AGENT_NAME=reviewer gh pr review*)",
      "Bash(CLAUDE_AGENT_NAME=reviewer gh issue comment*)"
      // ...your other allow entries
    ]
  },
  "hooks": {
    // ...the hook block above
  }
}
```

> **Adding more agents?** Each new prefix × command-shape combo needs its own `permissions.allow` entry (ex. `Bash(CLAUDE_AGENT_NAME=docwriter gh issue comment*)`), or Claude will prompt for permission on every call. If a new agent also needs commit/push privileges of its own (rather than always running through dispatch), add dedicated `PreToolUse` hooks for those command shapes too. Or convert the implementer-bound hooks above to use `agent-git-setup-dispatch.sh` so the prefix decides identity for those as well.

The `Stop` hook tears down the bot identity at the end of every Claude Code session - both the `git` config and the `gh auth logout --hostname github.com` call ensure your normal `git` and `gh` operations don't keep going out as the bot.

> **Caveat:** the `gh auth logout` leaves your `gh` CLI fully unauthenticated, not switched back to you. Run `gh auth login` after a session if you need to make `gh` calls under your own identity. The worktree-safe variant (below) avoids this by never touching global `gh` config in the first place.

---

## How agents invoke their identity

- **Implementer-bound commands** (commits, pushes, PR creation): no prefix needed - implementer is the default.
- **Reviewer-bound commands** (review comments, issue comments): prefix with `CLAUDE_AGENT_NAME=reviewer`:

  ```bash
  CLAUDE_AGENT_NAME=reviewer gh pr comment 42 --body "LGTM"
  ```

> The `CLAUDE_AGENT_NAME=<name>` prefix convention above is the **basic-mode** mechanism. In the [worktree variant](#running-parallel-claude-code-sessions-across-worktrees), `gh` calls instead go through `~/.scripts/agent-gh <name> ...`; the agent name is the wrapper's first argument and identity is resolved per call, so no prefix-routed hook is needed for `gh`. Both modes still use the `CLAUDE_AGENT_NAME=` prefix for hook-routed `git` commands (commits/pushes) when dispatch is wired in.

### Where to remind the agent to prefix

The prefix has to come from the agent itself - the hook reads it, it doesn't add it. So the instruction has to live somewhere the agent reads at the start of every session. You have two homes for it:

- **Subagent definitions** (`.claude/agents/<name>.md`) - appended to the agent's system prompt when *that specific subagent* is spawned. The reviewer in this repo carries its own prefix reminder this way (see the **PR comments** section of `.claude/agents/reviewer.md`).
- **`CLAUDE.md`** at the project root - loaded into every session's context: orchestrator, subagents, agent-team teammates, agent-team leads. Use this for any prefix that an agent *without* the matching subagent body appended might still need to run.

#### Two agents (implementer + one prefixed agent)

The default in this repo. The subagent definition is enough - the orchestrator delegates reviewer work to the reviewer subagent, and the reviewer's own body carries the prefix reminder. CLAUDE.md isn't required.

#### Three or more agent identities

Two things change once you have more than one prefixed agent:

1. **Each agent gets the prefix reminder in its own subagent `.md`.** Don't try to centralize it into a shared subagent - agents only see their own definition.
2. **CLAUDE.md becomes load-bearing.** The orchestrator (and any agent-team lead) has no subagent body appended to its context, so if it ever runs a prefixed command directly - ex. posting a docwriter-style summary on a PR without delegating - it has no way to learn the convention except from CLAUDE.md.

A mapping table reads cleaner than prose at this point:

```markdown
## Bot identities

This repo wires per-agent GitHub App identities through a `PreToolUse` hook. When you run a `gh` command, prefix it with the role you're acting as so the hook routes the call to the right bot:

| Action                                | Prefix                                |
|---------------------------------------|---------------------------------------|
| Commits, pushes, PR creation          | _(none - implementer is the default)_ |
| Review comments, PR reviews           | `CLAUDE_AGENT_NAME=reviewer`          |
| Docs / changelog comments             | `CLAUDE_AGENT_NAME=docwriter`         |

Example: `CLAUDE_AGENT_NAME=reviewer gh pr comment <n> --body "..."`. Without a prefix, commands go out under the implementer identity.
```

Keep the per-agent reminders in their subagent `.md` files too - CLAUDE.md is the catch-all, the subagent definitions are the role-specific reinforcement.

---

## Verify it works

`PreToolUse` hooks only fire on tool calls that Claude Code itself makes - running these commands from your own terminal won't trigger anything. Have Claude execute them from inside a session in your project:

```bash
# Claude runs this → PreToolUse hook fires → commit goes out as implementer[bot]
git commit --allow-empty -m "test: verify implementer identity"

# After the orchestrator opens a PR, ask Claude to run:
CLAUDE_AGENT_NAME=reviewer gh pr comment <pr> --body "test"
# Comment should appear authored by myagent-reviewer[bot] in the GitHub UI.
```

You can verify the result from anywhere - `git log` and the GitHub UI don't need to be inside a session:

```bash
git log -1 --format='%an <%ae>'
# → myagent-implementer[bot] <56789012+myagent-implementer[bot]@users.noreply.github.com>
```

If the commit author is still you, the hook didn't fire - check that `.claude/settings.json` is in the project root, that Claude (not you) ran the `git commit`, and that the `if:` matchers match your exact command shape.

---

## Running parallel Claude Code sessions across worktrees

If you've used [`git worktree`](https://git-scm.com/docs/git-worktree) to keep multiple branches checked out at once - say one worktree per ticket - you may want to run a separate Claude Code session in each, with its own implementer/reviewer pair. **The basic setup above won't safely support that**, and the failure mode is silent. Read this section before you try it.

### Why the default setup races

Git worktrees aren't fully isolated from each other. A worktree's `.git` is a *file* pointing at `<main-repo>/.git/worktrees/<name>/`, and several config-related operations resolve back to the **main repo's** shared `.git/config`:

- `git config user.name` / `user.email` - shared.
- `git config credential.helper` - shared. Each session's setup overwrites the previous helper path.
- `git remote set-url origin` - shared.

On top of that, `gh auth login --with-token` writes `~/.config/gh/hosts.yml`, which is global to your machine - two sessions logging in clobber each other's tokens.

And the `Stop` hook unsets all of those when any one session ends, which yanks the rug out from under any other session still running.

Net effect: two parallel sessions in different worktrees of the same repo will intermittently commit under the wrong identity, fail authentication mid-push, or have one session's cleanup break the other's setup.

### Setup for parallel worktree usage

Do these steps **once per main repo**, before launching parallel sessions:

#### 1. Enable per-worktree git config

Run this once, from the main repo (or from any existing worktree - they all share the same `.git/config`):

```bash
git config extensions.worktreeConfig true
```

The flag itself lives in the **shared** `.git/config`, so setting it once turns the feature on for every worktree of the repo - including ones you haven't created yet. New worktrees made via `git worktree add` or `claude -w <branch>` automatically inherit the setting; you don't need to re-enable it inside each worktree.

What the flag does: it makes `git config --worktree <key> <value>` write to `<main-repo>/.git/worktrees/<name>/config.worktree` instead of the shared `.git/config`. From this point on, you can scope `user.name`, `user.email`, `credential.helper`, and `remote.origin.url` per worktree, and the values stay isolated even though the *enable* switch is shared.

#### 2. Use the worktree-safe setup script

Copy `scripts/agent-git-setup-worktree.sh` into `~/.scripts/` and point your hook commands at it in place of `agent-git-setup.sh`:

```bash
cp scripts/agent-git-setup-worktree.sh ~/.scripts/
chmod +x ~/.scripts/agent-git-setup-worktree.sh
```

```jsonc
{ "type": "command", "if": "Bash(git commit*)", "command": "~/.scripts/agent-git-setup-worktree.sh implementer $CLAUDE_PROJECT_DIR" }
```

The differences from `agent-git-setup.sh`:

- All `git config` calls become `git config --worktree`, so `user.name`, `user.email`, `credential.helper`, and `remote.origin.url` land in `<main-repo>/.git/worktrees/<name>/config.worktree` instead of the shared `.git/config`.
- The credential helper is written into the worktree's per-worktree git dir (already per-worktree in the basic script; no change in behavior, just clarified by the per-worktree config keys above).
- `gh` auth is not touched by this script; `gh` calls in worktree mode go through the `agent-gh` wrapper installed in step 3.

#### 3. Use the `agent-gh` wrapper for `gh` calls

`gh` auth state is global by default (`~/.config/gh/hosts.yml`), so parallel worktree sessions can't safely share it. Rather than try to scope a per-worktree config dir into every tool subprocess via env-var plumbing, the worktree variant takes the opposite approach: a tiny per-call wrapper that mints a fresh installation token on each invocation and execs `gh` with `GH_TOKEN` set. No persistent `gh` state and no `Stop`-hook teardown.

Install it once:

```bash
cp scripts/agent-gh ~/.scripts/
chmod +x ~/.scripts/agent-gh
```

Agents invoke it explicitly, with the agent name as the first argument:

```bash
~/.scripts/agent-gh reviewer    pr comment 42 --body "LGTM"
~/.scripts/agent-gh implementer pr create  --title "..." --body "..."
~/.scripts/agent-gh implementer auth status
```

> **Cost:** each call mints a fresh JWT and exchanges it for an installation token over the GitHub API, roughly **300–500ms of network overhead per invocation**. For interactive comment/review flows this is invisible; for a script that calls `gh` in a tight loop, batch the work into a single call or cache `GH_TOKEN` for the loop's lifetime.

Update `.claude/settings.json` for worktree mode in two ways:

1. **Permissions**: replace the basic-mode `Bash(CLAUDE_AGENT_NAME=… gh …*)` entries with the wrapper form:

   ```jsonc
   {
     "permissions": {
       "allow": [
         "Bash(~/.scripts/agent-gh reviewer pr comment*)",
         "Bash(~/.scripts/agent-gh reviewer pr review*)",
         "Bash(~/.scripts/agent-gh reviewer issue comment*)",
         "Bash(~/.scripts/agent-gh implementer pr create*)"
         // ...same shape for any other agent + gh subcommand pair
       ]
     }
   }
   ```

2. **Hooks**: the basic-mode `gh pr create*` / `gh pr comment*` / `gh pr review*` / `gh issue comment*` `PreToolUse` hooks are no longer needed. The wrapper resolves identity per call, so there's nothing for a hook to set up. Keep the `git commit*` and `git push*` hooks pointing at `agent-git-setup-worktree.sh`; drop the `gh`-shaped ones entirely.

The wrapper also reads its config from `~/.secrets/agents/<name>.env` (same files the setup scripts use), so no extra credential plumbing is required; install the wrapper, copy the permissions, and any agent already wired for basic mode will work.

#### 4. Drop or scope the Stop hook

The default Stop hook unsets shared config keys. Either:

- **Remove it entirely** when you're using the worktree-safe script; cleanup matters less because nothing leaks across worktrees, and the worktree's `config.worktree` will simply be overwritten next session.
- **Or scope it**: change every `git config --unset <key>` to `git config --unset --worktree <key>`, drop the `git remote set-url` line (since the remote URL is now per-worktree too), and drop the `gh auth logout` line (the worktree variant never touches global gh config; the `agent-gh` wrapper passes `GH_TOKEN` per-process and leaves nothing on disk).

#### 5. Verify isolation

```bash
# In worktree A:
git worktree add ../my-repo-a feature-a
cd ../my-repo-a
~/.scripts/agent-git-setup-worktree.sh implementer .
git config --worktree user.name   # → implementer[bot]

# In worktree B (separate terminal / Claude Code session):
git worktree add ../my-repo-b feature-b
cd ../my-repo-b
~/.scripts/agent-git-setup-worktree.sh implementer .
git config --worktree user.name   # → implementer[bot]

# Back in worktree A:
git config --worktree user.name   # → still implementer[bot], unaffected

# Confirm gh identity routing too: the wrapper mints a fresh token and
# reports the bot account it was issued for:
~/.scripts/agent-gh implementer auth status   # → Logged in to github.com as myagent-implementer[bot]
```

If both worktrees report the right git identity and `agent-gh implementer auth status` reports the implementer bot, you're isolated end-to-end. `gh` calls in worktree mode no longer touch shared state, so there's no `hosts.yml` to inspect; each call brings its own token and exits.

### Multi-agent git routing in worktree mode

If your worktree-mode setup has three or more agents that all commit (not just one implementer), you'll want the same prefix-based dispatch the basic mode uses for `git commit*` / `git push*`; otherwise every commit goes out as `implementer[bot]` regardless of who ran it. The basic-mode README sketches this under [Extending dispatch to more agents](#extending-dispatch-to-more-agents).

To reuse it in worktree mode, copy `agent-git-setup-dispatch.sh` into `~/.scripts/` and change the final `exec` line to point at the worktree variant (one-line change):

```diff
-exec ~/.scripts/agent-git-setup.sh "$agent" "$CLAUDE_PROJECT_DIR"
+exec ~/.scripts/agent-git-setup-worktree.sh "$agent" "$CLAUDE_PROJECT_DIR"
```

Then wire the `git commit*` / `git push*` hooks at the dispatch script instead of at the worktree setup script directly. Treat this as a future-enhancement hint, not a default; most worktree-mode users have one committing agent and don't need it.

### Same identity vs. different identities across worktrees

A reasonable instinct is "give each worktree its own bot identity to avoid collisions." It doesn't actually help: the races are about **shared file paths**, not about the values being written. Different identities just means the racing writes have different values, which is strictly worse than idempotent same-value writes. The worktree-config refactor above is the real fix; identity choice is a separate, cosmetic decision.

---

## Using this with Claude Code agent teams

> **Status: untested.** This section is a hazard map and a sketch of how the setup would need to change, not a working configuration. If you try it, expect to debug. See the [agent teams docs](https://code.claude.com/docs/en/agent-teams) for the underlying feature.

[Agent teams](https://code.claude.com/docs/en/agent-teams) (currently experimental, gated by `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) spawn multiple full Claude Code sessions - a lead plus N teammates - that all run **in the same working directory** by default. Each teammate's `PreToolUse` hooks fire normally, and you can spawn a teammate using a subagent type, so on paper this setup transfers over: an `implementer` teammate's `git commit` would fire the hook, the dispatch script would route on `CLAUDE_AGENT_NAME=…`, and commits would be attributed correctly.

In practice it doesn't, for the same reason parallel worktrees don't: **multiple concurrent sessions write to the same shared state**.

### Why agent teams break the basic setup

Same shared-state races as [parallel worktrees](#why-the-default-setup-races) - but worse, because teammates don't get separate working directories either. Every teammate's hook writes the same `<repo>/.git/config`, the same global `~/.config/gh/hosts.yml`, and any one teammate's `Stop` hook tears down the bot config for everyone still running.

Race window: if the implementer teammate's hook sets the implementer identity, then the reviewer teammate's hook overwrites it a millisecond later, then the implementer teammate's `git commit` runs - the commit goes out as `reviewer[bot]`. With three or more teammates committing concurrently it's more or less guaranteed to happen.

### What still works without modification

- **Sequential subagents inside a single Claude Code session** (the orchestrator + implementer/reviewer pattern this README is built around) - no changes needed.
- **A team where only the lead does git/gh** - teammates research and report back; only the lead commits/pushes/comments. The setup is single-session-equivalent in that case.
- **A team using the worktree-safe variant where each teammate runs in its own worktree** - this requires manual coordination (you spawn each teammate yourself with `claude -w <branch>` rather than via the team-creation flow), so it isn't really "agent teams" in the automated sense, but it does isolate properly.

### What would need to change to support concurrent teammates safely

The fundamental fix is to stop writing identity to shared, persistent state. Two directions, neither implemented or tested:

1. **Per-session, env-var-only credentials.** Rewrite `agent-git-setup.sh` to never touch `.git/config` or `gh auth login`. Instead, mint the token and expose identity via env vars: `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` (which override `.git/config` per-process) and `GH_TOKEN` (which overrides `gh hosts.yml` per-process). The open question is plumbing those env vars into the tool call's environment from a `PreToolUse` hook - hook subprocesses don't share env with the parent. The likely shape is a small `git`/`gh` wrapper on `PATH` that reads per-PID credentials from a temp file the hook wrote, plus `git -c credential.helper='!f() { echo password=$GH_TOKEN; }; f' push` to inject the push token without writing a helper file.

2. **Worktree-per-teammate, automated.** Have the lead spawn each teammate inside its own worktree (ex. via a custom skill or wrapper around team creation). Reuses the worktree-safe script unchanged. Closer to working today, but requires coordinating `git worktree add` with team-spawn.

Approach 1 is the cleanest target architecturally - no shared state means no races and no `Stop` hook teardown problem - but it's also the larger rewrite. Approach 2 is closer to a script-and-glue change.

### Where to put the prefix reminder when using agent teams

See [Where to remind the agent to prefix](#where-to-remind-the-agent-to-prefix) for the general guidance. The CLAUDE.md placement is **mandatory** for agent teams - the lead has no subagent definition appended to its context, and per the [agent teams docs](https://code.claude.com/docs/en/agent-teams), CLAUDE.md is the only place a prefix instruction will reach it.

> **Bottom line:** until the per-session-credential rewrite (or worktree-per-teammate automation) lands, treat this setup as **incompatible with parallel-committing agent teams**. Teams where only the lead writes, or teams running sequentially, will work. Anything else risks silent identity mix-ups in your git history.

---

## Security notes

- `.pem` files are equivalent to long-lived passwords for the bot. `chmod 600`, never commit, never share.
- Scope each App's repository permissions to the minimum it needs. An implementer that doesn't need to merge PRs shouldn't have permission to.
- The `.pem` and the installation tokens minted from it are different things, with very different blast radii if leaked:
  - **Installation tokens** are what `agent-git-setup.sh` produces - short-lived (~1 hour) OAuth-style access tokens that GitHub issues in exchange for a JWT signed by the `.pem`. If one leaks (logs, shell history, a stale env var), an attacker has at most an hour before it expires on its own.
  - **The `.pem`** is the App's private key. It can mint fresh installation tokens indefinitely. If it leaks, an attacker keeps full bot access until you go into the App settings and revoke the key - there's no automatic expiry.
  - Treat the `.pem` like a long-lived password (which is why `chmod 600` and "never commit" matter); treat a leaked token as urgent but self-healing.
- The credential helper script written into `.git/agent-credential-helper.sh` echoes the token to stdout. It's `chmod 700` and lives only inside `.git/`, but be aware it exists.
