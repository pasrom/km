"""What km doctor shares with other commands: git and gh against a remote without prompts and with
a time limit. Runs without PyYAML, like doctor, so it works on a computer that is only half set up.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from km.paths import git

TIMEOUT = 15                      # seconds per network call
OFFLINE = ("could not resolve host", "failed to connect", "connection timed out", "network is unreachable",
           "could not connect", "operation timed out", "connection refused", "no answer within")


def shown(url: str) -> str:
    """A URL fit to print: without a user or token in it (https://user:token@host/...)."""
    return re.sub(r"(?<=://)[^/@]+@", "", url)


def remote(*args: str, cwd: Path, timeout: float = TIMEOUT) -> tuple[int, str, str]:
    """git against a remote, without prompts: a missing login fails at once instead of waiting for
    a password, a browser window or an editor's askpass box. English messages, so they can be told
    apart. (code, stdout, stderr); code -1 when it did not answer in time."""
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "GIT_ASKPASS": "",
           "SSH_ASKPASS": "", "SSH_ASKPASS_REQUIRE": "never", "LC_ALL": "C"}
    if "GIT_SSH_COMMAND" not in env and git("config", "--get", "core.sshCommand", cwd=cwd).returncode:
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
    try:
        res = git("-c", "core.askPass=", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10",
                  *args, cwd=cwd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, "", f"no answer within {timeout:g} s"
    return res.returncode, res.stdout, res.stderr


def no_network(err: str) -> bool:
    """Whether a remote's error says the network, not the login or the access, is the problem."""
    return any(s in err.lower() for s in OFFLINE)


def first_line(err: str) -> str:
    return next((ln.strip() for ln in err.splitlines() if ln.strip()), "no message")


def gh(*args: str, timeout: float = TIMEOUT) -> tuple[int, str]:
    """The GitHub CLI without prompts, with a time limit. (code, stdout); -1 when it did not answer."""
    env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}
    try:
        res = subprocess.run(["gh", *args], capture_output=True, stdin=subprocess.DEVNULL, text=True, encoding="utf-8",
                             env=env, timeout=timeout)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return -1, ""
    return res.returncode, res.stdout.strip()


def github_repo(url: str) -> tuple[str, str] | None:
    """(owner, name) of a github.com URL in https or ssh form, else None."""
    m = re.match(r"(?:https://(?:[^/@]+@)?github\.com/|(?:ssh://)?git@github\.com[:/])([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return (m.group(1), m.group(2)) if m else None
