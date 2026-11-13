"""What every role session is given inside its container: `agent_profile.py check`.

A session runs in a fresh container of the image built from e2e/container/ (README-agents.md). The
container holds no profile of the person's: its Claude Code config folder starts empty but for the
first-run marks and the trust record (claude_json), and its settings are managed settings
(/etc/claude-code/managed-settings.json, root-owned: the session user cannot change them, and they
apply whatever --setting-sources says). Claude Code logs in with the subscription token from
$KM_E2E_CLAUDE_TOKEN_FILE (default ~/.config/km-e2e/claude-oauth-token, a `claude setup-token`
token), handed to the container as an environment variable. `check` is the agent preflight's part
about the image and the token; the rest of the preflight runs inside a container (agent_run.py).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

IMAGE = "km-e2e-agent:1"                 # KM_E2E_IMAGE overrides
# every session's model (--model), so runs compare: a token-only login does not know the account's
# default and falls back to Claude Code's general one. KM_E2E_MODEL overrides.
MODEL = "claude-fable-5-2"
CONTAINER_DIR = Path(__file__).resolve().parent / "container"
# paths inside the container
HOME = "/home/node"                      # the session user's (uid 1000, `node` of the base image)
CONFIG = f"{HOME}/.claude"               # CLAUDE_CONFIG_DIR: fresh in every container
DONE = f"{HOME}/km-e2e-done.json"        # the Stop hook's file
WORK = "/work"
CLONE = f"{WORK}/clone"                  # the role's clone, copied in
INPUTS = f"{WORK}/inputs"                # a step's extra folders, copied in
STEP = "/opt/km-e2e"                     # wrappers, git config, hook, firewall input: root-owned
PLUGIN = "/opt/km"                       # the km plugin export, mounted read-only
GH_TOKEN = "/run/km-e2e/gh-token"        # the role's GitHub token file, mounted read-only
MANAGED = "/etc/claude-code/managed-settings.json"
SYSTEM_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

HOOK = """#!/bin/sh
# Stop hook of the km e2e sessions: the end of a turn, recorded for the driver.
[ -n "${KM_E2E_DONE_FILE:-}" ] || exit 0
cat > "$KM_E2E_DONE_FILE.tmp" && mv -f "$KM_E2E_DONE_FILE.tmp" "$KM_E2E_DONE_FILE"
"""
# the shell commands a role agent may run without asking (dontAsk denies everything else); the km
# skill's own commands, git and gh, and read-only helpers
BASH_ALLOW = ["km", "git", "gh", "cd", "jq", "uv", "uvx", "python3", "ls", "cat", "head", "tail", "grep", "sed", "awk",
              "wc", "diff", "cmp", "sort", "uniq", "cut", "tr", "find", "mktemp", "cp", "mv", "mkdir", "touch",
              "test", "echo", "printf", "pwd", "date", "basename", "dirname", "realpath", "true",
              "GIT_SEQUENCE_EDITOR=* git rebase"]
# no gh login, alias, extension or config commands (the role's gh wrapper refuses them as well)
BASH_DENY = ["gh auth token", "gh auth login", "gh auth logout", "gh auth refresh", "gh auth setup-git",
             "gh auth switch", "gh alias", "gh extension", "gh config", "git -c", "git config", "git remote"]
CLAUDE_TOKEN = "~/.config/km-e2e/claude-oauth-token"   # `claude setup-token`'s token
SESSIONS = "~/.config/km-e2e/sessions"   # the host's staging folders of a run (what is copied into a container)


def plugin_root(workdir: Path) -> Path:
    """Where each run exports km from the candidate commit, beside the workdir (mounted read-only)."""
    return workdir.parent / f"{workdir.name}-plugins"


def image() -> str:
    return os.environ.get("KM_E2E_IMAGE") or IMAGE


def model() -> str:
    return os.environ.get("KM_E2E_MODEL") or MODEL


def build_command() -> str:
    return f"docker build -t {image()} {CONTAINER_DIR}"


def image_version(name: str | None = None) -> str:
    """The Claude Code version the image was built with (its label); empty when the image is missing."""
    try:
        r = subprocess.run(["docker", "image", "inspect", "-f", '{{index .Config.Labels "km-e2e.claude-code"}}',
                            name or image()], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def settings() -> dict:
    """The managed settings of every session. Files: read and write only under /work (the clone, the
    step's inputs), read the km plugin; nothing else of the container to the file tools."""
    return {
        "autoMemoryEnabled": False,
        "disableClaudeAiConnectors": True,
        "syncClaudeAiSkills": False,
        "syncClaudeAiPlugins": False,
        "enabledPlugins": {},
        "includeCoAuthoredBy": False,
        # only these rules and this hook count: nothing a session writes into its config folder adds any
        "allowManagedPermissionRulesOnly": True,
        "allowManagedHooksOnly": True,
        "permissions": {
            "defaultMode": "dontAsk",
            # `Bash(git *)` also matches a bare `git` (a trailing ` *` that is the only wildcard)
            "allow": [*(f"Bash({c} *)" for c in BASH_ALLOW),
                      f"Read(/{WORK}/**)", f"Read(/{PLUGIN}/**)", f"Edit(/{WORK}/**)", f"Write(/{WORK}/**)", "Glob", "Grep",
                      "Agent", "Skill", "TodoWrite"],
            "deny": [*(f"Bash({c} *)" for c in BASH_DENY), f"Read(/{GH_TOKEN})", "Read(//run/**)",
                     *(f"{t}(/{d}/**)" for t in ("Edit", "Write") for d in (CONFIG, STEP, PLUGIN, "/etc")),
                     "WebFetch", "WebSearch"],
        },
        "hooks": {"Stop": [{"hooks": [{"type": "command", "command": f"{STEP}/done.sh"}]}]},
    }


def claude_json(version: str, trusted: list[str]) -> dict:
    """The config folder's .claude.json: the first-run screens marked as seen (onboarding with its theme
    picker, this version's release notes) and the workspace trust dialog accepted for TRUSTED, so an
    unattended session starts at the prompt. No login: the token comes from the environment."""
    return {"hasCompletedOnboarding": True, "theme": "dark", "officialMarketplaceAutoInstallAttempted": True,
            "hasSeenTasksHint": True, "lastOnboardingVersion": version, "lastReleaseNotesSeen": version,
            "projects": {p: {"hasTrustDialogAccepted": True} for p in trusted}}


def session_env(path_extra: list[str]) -> dict[str, str]:
    """The session's environment inside the container, the subscription token aside (it is passed by
    name from the driver's environment, never on a command line)."""
    return {"PATH": ":".join([*path_extra, SYSTEM_PATH]), "SHELL": "/bin/bash", "TERM": "xterm-256color",
            "LANG": "C.UTF-8", "COLUMNS": "200", "LINES": "60",
            "CLAUDE_CONFIG_DIR": CONFIG, "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1", "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": "1",
            "GH_CONFIG_DIR": f"{STEP}/gh-config", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
            "GIT_CONFIG_GLOBAL": f"{STEP}/gitconfig", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_SSH_COMMAND": "false", "KM_E2E_DONE_FILE": DONE}


def claude_token_file() -> Path:
    return Path(os.environ.get("KM_E2E_CLAUDE_TOKEN_FILE") or CLAUDE_TOKEN).expanduser()


def claude_token() -> str:
    try:
        return claude_token_file().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def token_command() -> str:
    return (f"run `claude setup-token`, copy the token it prints, then "
            f"`umask 077 && pbpaste > {claude_token_file()}`")


def check() -> list[str]:
    """Problems that stop agent scenarios before any container starts (empty: none)."""
    bad = []
    if not image_version():
        bad.append(f"no image {image()} (or it lacks its version label): {build_command()}")
    if not claude_token():
        return bad + [f"no subscription token in {claude_token_file()}: {token_command()}"]
    if (claude_token_file().stat().st_mode & 0o077) != 0:
        bad.append(f"{claude_token_file()} is readable by others: chmod 600 it")
    return bad


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    if cmd == "check":
        bad = check()
        for b in bad:
            print(f"agent: {b}")
        print("image and token ok" if not bad else f"{len(bad)} problem(s)")
        return 1 if bad else 0
    print("usage: agent_profile.py check", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
