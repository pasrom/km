"""The clean Claude Code profile every role agent runs in: `agent_profile.py setup|check|login-command`.

One profile (its own CLAUDE_CONFIG_DIR) serves all roles; the role comes from the token the launcher
puts into the session's environment. The profile holds settings and a Stop hook only: no user
CLAUDE.md, no memory, no MCP servers, no installed plugins (the launcher loads km from the candidate
checkout with --plugin-dir). `setup` writes it and never logs in; a person logs in once, interactively,
with the command `login-command` prints. `check` is the agent preflight's part about the profile.

Paths: the profile in $KM_E2E_CLAUDE_PROFILE (default ~/.config/km-e2e/claude-profile), the binary in
$KM_E2E_CLAUDE (default: the first `claude` on PATH that is not a terminal app's shim).
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_PROFILE = "~/.config/km-e2e/claude-profile"
MEMORY_FILES = ("CLAUDE.md", "CLAUDE.local.md")
# folders of a profile that add instructions, tools or agents; each must be absent or empty
EXTRAS = ("rules", "skills", "agents", "commands", "output-styles", "plugins")
PLUGIN_DATA = Path("plugins") / "data"     # a loaded plugin's own data folder (km's, from --plugin-dir): allowed


def extras(profile: Path) -> list[Path]:
    """The files in the profile's EXTRAS folders, the plugins' data folder left aside."""
    return sorted(f for n in EXTRAS for f in (profile / n).rglob("*")
                  if f.is_file() and not f.relative_to(profile).is_relative_to(PLUGIN_DATA))
HOOK = """#!/bin/sh
# Stop hook of the km e2e profile: the end of a turn, recorded for the driver (the hook's input names
# the transcript). Nothing happens outside a session the launcher started.
[ -n "${KM_E2E_DONE_FILE:-}" ] || exit 0
cat > "$KM_E2E_DONE_FILE.tmp" && mv -f "$KM_E2E_DONE_FILE.tmp" "$KM_E2E_DONE_FILE"
"""
# the shell commands a role agent may run without asking (dontAsk denies everything else); the km
# skill's own commands, git and gh, and read-only helpers
BASH_ALLOW = ["km", "git", "gh", "jq", "uv", "uvx", "python3", "ls", "cat", "head", "tail", "grep", "sed", "awk",
              "wc", "diff", "cmp", "sort", "uniq", "cut", "tr", "find", "mktemp", "cp", "mv", "mkdir", "touch",
              "test", "echo", "printf", "pwd", "date", "basename", "dirname", "realpath", "true",
              "GIT_SEQUENCE_EDITOR=* git rebase"]
# no credential stores, no gh login, alias, extension or config commands (the role's gh wrapper refuses
# them as well)
BASH_DENY = ["security", "gh auth token", "gh auth login", "gh auth logout", "gh auth refresh", "gh auth setup-git",
             "gh auth switch", "gh alias", "gh extension", "gh config", "git -c", "git config"]
CLAUDE_TOKEN = "~/.config/km-e2e/claude-oauth-token"   # `claude setup-token`'s token: sessions cannot use the keychain
SESSIONS = "~/.config/km-e2e/sessions"   # the role wrappers of a run (no session may read there)


def plugin_root(workdir: Path) -> Path:
    """Where each run exports km from the candidate commit, read-only, beside the workdir: sessions may
    read it, not write it."""
    return workdir.parent / f"{workdir.name}-plugins"


# a session's PATH: no folder in the home folder (its tools would be unreadable in the sandbox anyway)
SYSTEM_PATH = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def profile_dir() -> Path:
    return Path(os.environ.get("KM_E2E_CLAUDE_PROFILE") or DEFAULT_PROFILE).expanduser()


def is_shim(p: str) -> bool:
    return "cmux-cli-shims" in p or p.rstrip("/").endswith("/shims")


def clean_path() -> str:
    """PATH without terminal-app shims (one in front of `claude` runs a wrapper of its own)."""
    return os.pathsep.join(p for p in os.environ.get("PATH", "").split(os.pathsep) if p and not is_shim(p))


def claude_bin() -> str:
    if v := os.environ.get("KM_E2E_CLAUDE"):
        return str(Path(v).expanduser())
    found = shutil.which("claude", path=clean_path())
    if not found:
        raise SystemExit("e2e: no `claude` on PATH (set KM_E2E_CLAUDE)")
    return found


def base_env(profile: Path) -> dict[str, str]:
    """The environment every session of the profile starts from: an allowlist of the caller's
    variables, nothing else (no GitHub login, no API key, no proxy, no shell customisation)."""
    keep = ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR")
    env = {k: os.environ[k] for k in keep if os.environ.get(k)}
    env |= {"PATH": SYSTEM_PATH, "SHELL": "/bin/bash", "TERM": os.environ.get("TERM", "xterm-256color"),
            "CLAUDE_CONFIG_DIR": str(profile), "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1", "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": "1"}
    return env


def settings(workdir: Path, profile: Path) -> dict:
    """The profile's settings.json. Files: read and write only under the e2e workdir (clones, inputs),
    read the exported km plugin, no reads of the usual credential folders."""
    w = f"/{workdir.resolve()}"            # `//abs/path` is an absolute path in a permission rule
    km = f"/{plugin_root(workdir).resolve()}"
    home = Path.home()
    return {
        "autoMemoryEnabled": False,
        # a session loads CLAUDE.md from every folder above its working directory (and, observed, the
        # default profile's .claude/CLAUDE.md in the home folder): the ones above the workdir are excluded
        "claudeMdExcludes": [str(p) for p in memory_in_parents(workdir)],
        "disableClaudeAiConnectors": True,
        # no skills or plugins the claude.ai account syncs into the profile at login
        "syncClaudeAiSkills": False,
        "syncClaudeAiPlugins": False,
        "theme": "dark",
        "enabledPlugins": {},
        "includeCoAuthoredBy": False,
        "permissions": {
            "defaultMode": "dontAsk",
            # `Bash(git *)` also matches a bare `git` (a trailing ` *` that is the only wildcard)
            "allow": [*(f"Bash({c} *)" for c in BASH_ALLOW),
                      f"Read({w}/**)", f"Read({km}/**)", f"Edit({w}/**)", f"Write({w}/**)", "Glob", "Grep",
                      "Agent", "Skill", "TodoWrite"],
            "deny": [*(f"Bash({c} *)" for c in BASH_DENY),
                     *(f"Read(/{home / d}/**)" for d in (".ssh", ".config", ".claude", ".aws", ".gnupg", ".netrc",
                                                         "Library/Keychains")),
                     *(f"{t}(/{d.resolve()}/**)" for t in ("Edit", "Write")
                       for d in (profile, Path(SESSIONS).expanduser(), home / ".config")),
                     "WebFetch", "WebSearch"],
        },
        "hooks": {"Stop": [{"hooks": [{"type": "command", "command": str(profile / "hooks" / "done.sh")}]}]},
    }


def setup(profile: Path, workdir: Path) -> None:
    """Create or refresh the profile (settings and hook). Never logs in, never touches a login."""
    profile.mkdir(parents=True, exist_ok=True)
    profile.chmod(0o700)
    (profile / "hooks").mkdir(exist_ok=True)
    for f, text, mode in ((profile / "hooks" / "done.sh", HOOK, 0o500),
                          (profile / "settings.json", json.dumps(settings(workdir, profile), indent=2) + "\n", 0o400)):
        if f.exists():
            f.chmod(0o600)
        f.write_text(text, encoding="utf-8")
        f.chmod(mode)                      # read-only: a session must not change them (Fingerprint checks)
    for synced in ("skills", "plugins"):    # what a login synced before the settings above stopped it
        shutil.rmtree(profile / synced / "synced", ignore_errors=True)
    prime(profile)


class Fingerprint:
    """What a session must not change in the profile: settings.json, the Stop hook, and the parts of
    .claude.json that add tools or rights (MCP servers, allowed tools; not the trust records the launcher
    writes). Taken after the preflight, checked before every session."""

    def __init__(self, profile: Path):
        self.profile = profile
        self.value = self.digest()

    def digest(self) -> str:
        cj = claude_json(self.profile)
        fields = ("mcpServers", "allowedTools", "enabledMcpjsonServers")
        # a session adds an entry for its folder with these fields empty: only non-empty values count
        risky = {"mcpServers": cj.get("mcpServers") or None,
                 "projects": {k: e for k, v in (cj.get("projects") or {}).items()
                              if (e := {f: v[f] for f in fields if v.get(f)})}}
        h = hashlib.sha256(json.dumps(risky, sort_keys=True).encode())
        # settings and hook; any instruction file, memory, or extra folder content a session could plant
        files = [self.profile / f for f in ("settings.json", "settings.local.json", "hooks/done.sh", *MEMORY_FILES)]
        files += extras(self.profile)
        files += sorted(self.profile.glob("projects/*/memory/**/*"))
        for p in files:
            h.update(f"{p.relative_to(self.profile).as_posix()}\0".encode())
            h.update(p.read_bytes() if p.is_file() else b"-")
            h.update(str(p.stat().st_mode if p.exists() else 0).encode())
        return h.hexdigest()

    def verify(self) -> None:
        if self.digest() != self.value:
            raise SystemExit(f"e2e: the profile {self.profile} changed during the run: stopping")


def claude_json(profile: Path) -> dict:
    p = profile / ".claude.json"
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def update_claude_json(profile: Path, change) -> None:
    """Apply CHANGE to the profile's .claude.json in place, keeping everything else (the login)."""
    p = profile / ".claude.json"
    data = claude_json(profile)
    change(data)
    tmp = p.with_suffix(".json.km-e2e-tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(p)


def trust(profile: Path, *paths: Path) -> None:
    """Accept the workspace trust dialog for PATHS in advance (an unattended session cannot answer it)."""
    def change(data: dict) -> None:
        projects = data.setdefault("projects", {})
        for path in paths:
            projects.setdefault(str(path.resolve()), {})["hasTrustDialogAccepted"] = True
    update_claude_json(profile, change)


def claude_version() -> str:
    try:
        r = subprocess.run([claude_bin(), "--version"], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        return r.stdout.split()[0] if r.returncode == 0 and r.stdout.strip() else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def prime(profile: Path) -> None:
    """Mark the first-run screens as seen (onboarding with its theme picker, the release notes of this
    version) and the official marketplace's auto-install as tried, so an unattended session starts at the
    prompt. The login stays as it is."""
    version = claude_version()
    def change(data: dict) -> None:
        data.update({"hasCompletedOnboarding": True, "theme": data.get("theme") or "dark",
                     "officialMarketplaceAutoInstallAttempted": True, "hasSeenTasksHint": True})
        if version:
            data.update({"lastOnboardingVersion": version, "lastReleaseNotesSeen": version})
    update_claude_json(profile, change)


def claude_token_file() -> Path:
    return Path(os.environ.get("KM_E2E_CLAUDE_TOKEN_FILE") or CLAUDE_TOKEN).expanduser()


def claude_token() -> str:
    try:
        return claude_token_file().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def auth_status(profile: Path) -> dict:
    """`claude auth status` as a session sees it: the subscription token from its file in the
    environment (a session cannot reach the keychain)."""
    env = base_env(profile) | ({"CLAUDE_CODE_OAUTH_TOKEN": t} if (t := claude_token()) else {})
    try:
        r = subprocess.run([claude_bin(), "auth", "status", "--json"], env=env, capture_output=True,
                           text=True, stdin=subprocess.DEVNULL, timeout=60)
        return json.loads(r.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        return {"loggedIn": False, "error": type(e).__name__}


def memory_in_parents(workdir: Path) -> list[Path]:
    """Instruction files a session under WORKDIR could load from the folders above it."""
    found = []
    for d in workdir.resolve().parents:
        found += [f for n in MEMORY_FILES for f in (d / n, d / ".claude" / n) if f.is_file()]
    return found


def check(profile: Path, workdir: Path) -> list[str]:
    """Problems that stop agent scenarios (empty: the profile is clean and logged in)."""
    bad = []
    if not (profile / "settings.json").is_file():
        return [f"no profile at {profile}: run `python3 e2e/agent_profile.py setup`"]
    try:
        have = json.loads((profile / "settings.json").read_text(encoding="utf-8"))
    except ValueError:
        have = {}
    # equal to what setup writes: dontAsk, no memory, no connectors, no plugins, no env or key helper, and
    # every CLAUDE.md above the workdir excluded
    if have != settings(workdir, profile):
        bad.append("the profile's settings.json is not what setup writes: run `python3 e2e/agent_profile.py setup` again")
    if not os.access(profile / "hooks" / "done.sh", os.X_OK):
        bad.append("the profile's Stop hook is missing or not executable")
    bad += [f"the profile holds {n} (user instructions): remove it" for n in MEMORY_FILES if (profile / n).exists()]
    if found := extras(profile):
        bad.append(f"the profile holds {len(found)} file(s) in {sorted({f.relative_to(profile).parts[0] for f in found})}: remove them")
    if mem := list(profile.glob("projects/*/memory/*")):
        bad.append(f"the profile holds {len(mem)} memory file(s) under projects/*/memory: remove them")
    cj = claude_json(profile)
    servers = list(cj.get("mcpServers") or {}) + [s for pr in (cj.get("projects") or {}).values()
                                                  for s in (pr.get("mcpServers") or {})]
    if servers:
        bad.append(f"MCP servers are configured in the profile ({len(servers)}): remove them")
    if not claude_token():
        return bad + [f"no subscription token in {claude_token_file()}: {token_command(profile)}"]
    if (claude_token_file().stat().st_mode & 0o077) != 0:
        bad.append(f"{claude_token_file()} is readable by others: chmod 600 it")
    st = auth_status(profile)
    method = str(st.get("authMethod", ""))
    if not st.get("loggedIn"):
        bad.append(f"the subscription token in {claude_token_file()} does not log in: {token_command(profile)}")
    elif "api" in method.lower() or "console" in method.lower():
        bad.append(f"the login is {method}, not the subscription")
    return bad


def token_command(profile: Path) -> str:
    return (f"run `CLAUDE_CONFIG_DIR={profile} {claude_bin()} setup-token`, copy the token it prints, then "
            f"`umask 077 && pbpaste > {claude_token_file()}`")


def login_command(profile: Path) -> str:
    return f"CLAUDE_CONFIG_DIR={profile} {claude_bin()}"


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    profile = profile_dir()
    workdir = Path(os.environ.get("KM_E2E_WORKDIR", "~/.cache/km-e2e")).expanduser()
    if cmd == "setup":
        workdir.mkdir(parents=True, exist_ok=True)
        setup(profile, workdir)
        print(f"profile written: {profile}\nlog in once: {login_command(profile)}\n  then /login in that session, then /exit")
        return 0
    if cmd == "check":
        bad = check(profile, workdir)
        for b in bad:
            print(f"profile: {b}")
        print("profile ok" if not bad else f"{len(bad)} problem(s)")
        return 1 if bad else 0
    if cmd == "login-command":
        print(login_command(profile))
        return 0
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
