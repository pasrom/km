"""Check that this computer is set up to work on a brain: `km doctor [--root DIR] [--offline]`.

Every expected value comes from the brain itself or from git's and Claude Code's own files, never
from km: the origin and the mounted brains (.gitmodules) it must reach, the km version it pins, and
the plugins its `.claude/settings.json` enables. One line per check; a failed one says how to fix
it. Network checks run without prompts and with a time limit, so a missing login fails instead of
hanging; --offline skips them. Exit 1 when a check failed.

Runs without PyYAML, so it works on a computer that is only half set up.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from km import KM_REF
from km.paths import git, repo_root
from km.pins import read_pins, version_key

TIMEOUT = 15                      # seconds per network check
OFFLINE = ("could not resolve host", "failed to connect", "connection timed out", "network is unreachable",
           "could not connect", "operation timed out", "connection refused", "no answer within")
UV_DOCS = "https://docs.astral.sh/uv/getting-started/installation/"
results: list[tuple[str, str, str]] = []


def report(status: str, what: str, fix: str = "") -> None:
    results.append((status, what, fix))


def as_dict(value) -> dict:
    """A JSON object, or {} for anything else a hand-edited file may hold there."""
    return value if isinstance(value, dict) else {}


def shown(url: str) -> str:
    """A URL fit to print: without a user or token in it (https://user:token@host/...)."""
    return re.sub(r"(?<=://)[^/@]+@", "", url)


def remote(*args: str, cwd: Path) -> tuple[int, str, str]:
    """git against a remote, without prompts: a missing login fails at once instead of waiting for
    a password, a browser window or an editor's askpass box. English messages, so they can be told
    apart. (code, stdout, stderr); code -1 when it did not answer in time."""
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "GIT_ASKPASS": "",
           "SSH_ASKPASS": "", "SSH_ASKPASS_REQUIRE": "never", "LC_ALL": "C"}
    if "GIT_SSH_COMMAND" not in env and git("config", "--get", "core.sshCommand", cwd=cwd).returncode:
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
    try:
        res = git("-c", "core.askPass=", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10",
                  *args, cwd=cwd, env=env, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return -1, "", f"no answer within {TIMEOUT} s"
    return res.returncode, res.stdout, res.stderr


def unreachable(name: str, url: str, err: str) -> None:
    """Report a remote that did not answer: offline, an unknown ssh host key, or no login / no access."""
    first = next((ln.strip() for ln in err.splitlines() if ln.strip()), "no message")
    if any(s in err.lower() for s in OFFLINE):
        report("FAIL", f"{name}: {shown(url)} cannot be reached ({first})",
               "check the network or VPN; --offline skips the network checks")
    elif "host key verification failed" in err.lower():
        report("FAIL", f"{name}: this computer does not know the host key of {shown(url)}",
               "connect once in a terminal (`git ls-remote` with that URL) and confirm the host key")
    else:
        report("FAIL", f"{name}: no access to {shown(url)} ({first})",
               "sign in to the host once (open the URL in a browser, or `git clone` it in a terminal "
               "and log in), and ask the owner for read access if that does not help")


def check_identity(root: Path) -> None:
    missing = [k for k in ("user.name", "user.email") if not git("config", "--get", k, cwd=root).stdout.strip()]
    if missing:
        report("FAIL", f"git does not know your {' and '.join(k.split('.')[1] for k in missing)}",
               " and ".join(f'`git config --global {k} "..."`' for k in missing)
               + "; use the email address of your account on the git host")
    else:
        report("ok", "git knows your name and email")


def check_uv() -> None:
    """km runs through uv; without it, on a Python 3.11+ with PyYAML. Neither: no km command but this
    one starts."""
    if shutil.which("uv"):
        report("ok", "uv is installed")
        return
    local = Path.home() / ".local" / "bin" / ("uv.exe" if os.name == "nt" else "uv")
    if local.is_file():
        report("FAIL", f"uv is installed in {local.parent} but that folder is not on the PATH",
               "close and reopen the app or terminal; if that does not help, add the folder to the PATH")
    elif importlib.util.find_spec("yaml") is None:
        report("FAIL", "uv is not installed, and this Python has no PyYAML: km cannot run", f"install uv: {UV_DOCS}")
    else:
        report("note", "uv is not installed; km runs on this Python and cannot run the km version a "
                       "brain pins when it differs", f"install uv: {UV_DOCS}")


def check_origin(root: Path, offline: bool) -> str:
    """Returns the origin URL, "" when there is none."""
    url = git("remote", "get-url", "origin", cwd=root).stdout.strip()
    if not url:
        report("FAIL", "the brain has no origin to pull from and push to",
               "clone the brain from its git host instead of copying the folder")
        return ""
    branch = git("symbolic-ref", "-q", "--short", "HEAD", cwd=root).stdout.strip()
    if offline:
        report("skip", f"origin {shown(url)} (offline)")
        return url
    code, out, err = remote("ls-remote", "origin", "HEAD", *([f"refs/heads/{branch}"] if branch else []), cwd=root)
    if code != 0:
        unreachable("origin", url, err)
        return url
    report("ok", f"origin {shown(url)} answers")
    if not branch:
        report("skip", "up to date: no branch checked out")
        return url
    theirs = next((sha for sha, _, ref in (ln.partition("\t") for ln in out.splitlines())
                   if ref == f"refs/heads/{branch}"), None)
    if theirs is None:
        report("skip", f"up to date: branch {branch} exists only here")
    elif git("merge-base", "--is-ancestor", theirs, "HEAD", cwd=root).returncode == 0:
        report("ok", f"branch {branch} has everything origin has")
    else:                             # behind, or diverged: a rebase onto origin's branch fixes both
        report("FAIL", f"branch {branch} lacks changes that are on origin",
               f"ask Claude to update the brain, or `git pull --rebase origin {branch}`")
    return url


def check_worktree(root: Path) -> None:
    changed = git("status", "--porcelain", "--ignore-submodules=all", cwd=root).stdout.splitlines()
    if changed:
        report("note", f"{len(changed)} changed or new file(s) not committed yet",
               "commit them, contribute them, or discard them; `git status` lists them")
    else:
        report("ok", "no uncommitted changes")


def submodule_config(root: Path, key: str) -> dict[str, str]:
    """{name: value} of submodule.<name>.<key> in .gitmodules; names may hold spaces and dots."""
    res = git("config", "-f", ".gitmodules", "-z", "--get-regexp", rf"^submodule\..*\.{key}$", cwd=root)
    pairs = (rec.partition("\n") for rec in res.stdout.split("\0") if rec)
    return {k[len("submodule."):-len(key) - 1]: v for k, _, v in pairs}


def resolve_url(url: str, origin: str) -> str:
    """A relative submodule URL (./x, ../x) resolved against origin, as git does; others unchanged."""
    if not url.startswith(("./", "../")) or not origin:
        return url
    base = origin.rstrip("/")
    for part in url.split("/"):
        if part == "..":
            base = base.rsplit("/", 1)[0] if "/" in base.split("://")[-1] else base.rsplit(":", 1)[0]
        elif part not in (".", ""):
            base = f"{base}/{part}"
    return base


def check_submodules(root: Path, origin: str, offline: bool) -> None:
    if not (root / ".gitmodules").is_file():
        return
    urls, paths = submodule_config(root, "url"), submodule_config(root, "path")
    if not urls:
        report("note", ".gitmodules lists no mounted brain git can read", "`git config -f .gitmodules --list` shows why")
    for name, url in urls.items():
        path = paths.get(name, name)
        # after `git submodule init` the brain's own config holds the URL in use, relative ones resolved
        url = git("config", "--get", f"submodule.{name}.url", cwd=root).stdout.strip() or resolve_url(url, origin)
        code, err = None, ""
        if not offline and not url.startswith(("./", "../")):
            code, _, err = remote("ls-remote", url, "HEAD", cwd=root)
        if code not in (None, 0):
            unreachable(f"mounted {path}", url, err)
        elif not (root / path / ".git").exists():
            report("note", f"mounted {path} is not checked out", f"`git submodule update --init \"{path}\"`")
        elif code == 0:
            report("ok", f"mounted {path} answers")
        else:
            report("skip", f"mounted {path}" + (" (offline)" if offline else " (not checked: no origin to resolve its URL)"))


def config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(env).expanduser() if env else Path.home() / ".claude"


def load_json(path: Path) -> dict:
    try:
        return as_dict(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return {}


def install_records(cfg: Path) -> dict:
    return as_dict(load_json(cfg / "plugins" / "installed_plugins.json").get("plugins"))


def check_km_version(root: Path) -> None:
    pins = read_pins(root)
    hook = pins.pop(".pre-commit-config.yaml", set())
    pinned = {p.version or str(p) for p in (set().union(*pins.values()) if pins else hook)}
    if not pinned:
        report("skip", f"km {KM_REF}: the brain pins no km version")
    elif pinned == {KM_REF}:
        report("ok", f"km {KM_REF} is the version the brain pins")
    elif all((version_key(v) or ()) > (version_key(KM_REF) or ()) for v in pinned):
        ids = sorted(p for p in install_records(config_dir()) if p.split("@")[0] == "km")
        how = f"`claude plugin update {ids[0]}`" if ids else "`/plugin` in Claude Code"
        report("FAIL", f"km {KM_REF} is older than the brain's {', '.join(sorted(map(str, pinned)))}",
               f"update the km plugin ({how}), then restart Claude; if no update is offered, "
               "ask the brain's maintainer")
    elif shutil.which("uv"):
        report("note", f"km {KM_REF}; the brain pins {', '.join(sorted(map(str, pinned)))}",
               "km runs the pinned version through uv; a maintainer moves the pins with `km upgrade`")
    else:
        report("note", f"km {KM_REF}; the brain pins {', '.join(sorted(map(str, pinned)))}, which km cannot "
                       "run without uv, so its results may differ from CI", f"install uv: {UV_DOCS}")


def installed(plugin: str, root: Path, cfg: Path) -> bool:
    """Installed for this brain: for the user, or for a project the brain lies in; or synced to the
    account by its organization (`<cfg>/plugins/synced/<bucket>/<name>[~gN]/`)."""
    entries = install_records(cfg).get(plugin, [])
    for e in entries if isinstance(entries, list) else [entries]:
        e = as_dict(e)
        project = e.get("projectPath")
        if e.get("scope", "user") == "user" or (isinstance(project, str) and project
                                                and Path(project).resolve() in (root, *root.parents)):
            return True
    name = plugin.split("@")[0]
    synced = cfg / "plugins" / "synced"
    return synced.is_dir() and any(d.is_dir() and d.name.split("~")[0] == name for d in synced.glob("*/*"))


def check_plugins(root: Path) -> None:
    settings = load_json(root / ".claude" / "settings.json")
    wanted = [p for p, on in as_dict(settings.get("enabledPlugins")).items() if on is True]
    if not wanted:
        return
    cfg = config_dir()
    known = load_json(cfg / "plugins" / "known_marketplaces.json")
    extra = as_dict(settings.get("extraKnownMarketplaces"))
    for plugin in wanted:
        if installed(plugin, root, cfg):
            report("ok", f"plugin {plugin} is installed")
            continue
        market = plugin.partition("@")[2]
        src = as_dict(as_dict(extra.get(market)).get("source"))
        where = src.get("repo") or src.get("url")     # not a "directory" source: a path on its author's computer
        add = f"`/plugin marketplace add {shown(where)}`, then " if market not in known and isinstance(where, str) else ""
        report("FAIL", f"plugin {plugin} is not installed", f"in Claude Code: {add}`/plugin install {plugin}`, "
               "or add it in the Claude app under Customize, Plugins; then restart Claude")


def main() -> int:
    ap = argparse.ArgumentParser(prog="km doctor", description="check that this computer is set up to work on a brain")
    ap.add_argument("--offline", action="store_true", help="skip the checks that need the network")
    args = ap.parse_args()
    root = repo_root()
    print(f"km doctor: {root}")
    if not shutil.which("git"):
        report("FAIL", "git is not installed", "install git: https://git-scm.com/downloads")
    elif git("rev-parse", "--is-inside-work-tree", cwd=root).stdout.strip() != "true":
        report("FAIL", f"{root} is not a git repository", "clone the brain with git and run km doctor inside it")
    else:
        check_identity(root)
        origin = check_origin(root, args.offline)
        check_worktree(root)
        check_submodules(root, origin, args.offline)
        check_km_version(root)
        check_plugins(root)
    check_uv()
    for status, what, fix in results:
        print(f"  {status:<5} {what}")
        if fix and status != "ok":
            print(f"        fix: {fix}")
    failed = sum(status == "FAIL" for status, _, _ in results)
    print(f"{failed} problem(s) to fix." if failed else "Everything needed is set up.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
