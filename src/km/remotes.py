"""What km doctor and km sync share: git and gh against a remote without prompts and with a time
limit, and which brain a copy is downstream of (its upstream). Runs without PyYAML, like doctor,
so it works on a computer that is only half set up.

The upstream of a brain copy is the remote named `upstream` where one exists; else, for a GitHub
origin that gh reports as a fork, the fork's parent; else origin itself (no fork). A fork's own
default branch on the host is then a second thing that can fall behind.
"""
from __future__ import annotations

import functools
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from km.paths import git, printable

TIMEOUT = 15                      # seconds per network call
OFFLINE = ("could not resolve host", "failed to connect", "connection timed out", "network is unreachable",
           "could not connect", "operation timed out", "connection refused", "no answer within")


def shown(url: str) -> str:
    """A URL fit to print: without a user or token in it (https://user:token@host/...), and without
    a character that could fake a line or a command (see printable)."""
    return printable(re.sub(r"(?<=://)[^/@]+@", "", url))


def remote(*args: str, cwd: Path, timeout: float = TIMEOUT) -> tuple[int, str, str]:
    """git against a remote, without prompts: a missing login fails at once instead of waiting for
    a password, a browser window or an editor's askpass box. English messages, so they can be told
    apart. (code, stdout, stderr); code -1 when it did not answer in time."""
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "GIT_ASKPASS": "",
           "SSH_ASKPASS": "", "SSH_ASKPASS_REQUIRE": "never", "LC_ALL": "C"}
    if "GIT_SSH_COMMAND" not in env and not _ssh_command(cwd):
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
    try:
        res = git("-c", "core.askPass=", "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10",
                  *args, cwd=cwd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, "", f"no answer within {timeout:g} s"
    return res.returncode, res.stdout, res.stderr


@functools.cache
def _ssh_command(cwd: Path) -> bool:
    """Whether the repository sets its own ssh command (core.sshCommand); looked up once per run."""
    return git("config", "--get", "core.sshCommand", cwd=cwd).returncode == 0


def no_network(err: str) -> bool:
    """Whether a remote's error says the network, not the login or the access, is the problem."""
    return any(s in err.lower() for s in OFFLINE)


LOGIN = ("could not read username", "could not read password", "authentication failed", "invalid username or password",
         "permission denied (publickey", "host key verification failed")
NOT_FOUND = ("repository not found", "' not found", "does not exist", "does not appear to be a git repository")   # "repository '<url>' not found"


def no_login(err: str) -> bool:
    """Whether a remote's error says this computer has no (working) login there, or does not know
    the host's key: something to set up here, not a question of read access."""
    return any(s in err.lower() for s in LOGIN)


def no_access(err: str) -> bool:
    """Whether a remote's error says the repository cannot be read with this computer's login: no
    login, or not found (what a host answers for a repository it hides from you). Not the network,
    and not a commit the remote lacks."""
    low = err.lower()
    return no_login(err) or any(s in low for s in NOT_FOUND)


def first_line(err: str) -> str:
    """The first line of a message, fit to print (it may quote a URL or path from the repository)."""
    return printable(next((ln.strip() for ln in err.splitlines() if ln.strip()), "no message"))


def gh_run(*args: str, timeout: float | None = None) -> subprocess.CompletedProcess[bytes] | None:
    """The GitHub CLI without prompts, with a time limit, its output as bytes; None when it did not
    answer or is not installed. The default timeout is TIMEOUT as it is at the call (a test lowers it)."""
    env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}
    try:
        return subprocess.run(["gh", *args], capture_output=True, stdin=subprocess.DEVNULL, env=env,
                              timeout=TIMEOUT if timeout is None else timeout)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def gh(*args: str) -> tuple[int, str]:
    """The GitHub CLI without prompts, with a time limit. (code, stdout); -1 when it did not answer
    or is not installed."""
    res = gh_run(*args)
    if res is None:
        return -1, ""
    return res.returncode, res.stdout.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n").strip()   # as text mode reads it


def github_repo(url: str) -> tuple[str, str] | None:
    """(owner, name) of a github.com URL in https or ssh form, else None."""
    m = re.match(r"(?:https://(?:[^/@]+@)?github\.com/|(?:ssh://)?git@github\.com[:/])([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return (m.group(1), m.group(2)) if m else None


@dataclass(frozen=True)
class Upstream:
    """The brain a copy follows. `remote` names the git remote it is fetched from; None when it is
    so far only known by URL (a fork's parent, found through gh): km sync then adds it as the
    remote `upstream`, doctor only reads it. `fork` says how origin's default branch may be brought
    along: `owner/name` for a fork gh confirmed (gh repo sync), '' for a fork gh cannot see (not
    on GitHub, or gh is not installed: a plain push), None when origin is no fork, or gh cannot
    tell (not signed in, offline): then it is left alone."""
    remote: str | None
    url: str
    branch: str
    fork: str | None

    @property
    def ref(self) -> str:
        """The local ref that holds its default branch after a fetch."""
        return f"refs/remotes/{self.remote}/{self.branch}"


def default_branch(root: Path, name: str, url: str, offline: bool) -> str:
    """The default branch of a remote: what its HEAD ref here says (clone sets it for origin),
    else what the host says; "main" when neither can be known."""
    head = git("symbolic-ref", "-q", "--short", f"refs/remotes/{name}/HEAD", cwd=root).stdout.strip()
    if head.startswith(name + "/"):
        return head[len(name) + 1:]
    if not offline:
        _, out, _ = remote("ls-remote", "--symref", url, "HEAD", cwd=root)
        for ln in out.splitlines():
            if ln.startswith("ref: refs/heads/") and ln.rstrip().endswith("\tHEAD"):
                return ln[len("ref: refs/heads/"):].split("\t")[0]
    return "main"


FORK_KEY = "km.fork"              # git config: what gh last said about origin ("false" or owner/name), and for which origin


def find_upstream(root: Path, offline: bool = False, remember: bool = False) -> Upstream | None:
    """Which brain this copy follows; None without an origin. gh is asked only for a GitHub origin
    and not offline: whether origin is a fork, under which name, and of which parent. With
    `remember`, gh's answer is kept in the repository's git config (`km.fork`, with the origin URL
    it was given for, so a changed origin is asked again), so a copy that is no fork, or a fork
    whose parent is the remote `upstream` already, never asks again; `git config --unset km.fork`
    makes the next run ask gh afresh."""
    origin = git("remote", "get-url", "origin", cwd=root).stdout.strip()
    if not origin:
        return None
    repo = github_repo(origin)
    url = git("remote", "get-url", "upstream", cwd=root).stdout.strip()
    answer, _, for_origin = git("config", "--get", FORK_KEY, cwd=root).stdout.strip().partition(" ")
    known = answer if repo and for_origin == origin else ""
    parts, code = [], -1
    if repo and not offline and not (known == "false" or (known and url)):   # a known fork still needs its parent
        fields = ".fork, .full_name, .parent.default_branch, .parent.clone_url, .parent.ssh_url"
        code, out = gh("api", "--hostname", "github.com", f"repos/{'/'.join(repo)}", "--jq", f"[{fields}] | @tsv")
        parts = (out.split("\t") + [""] * 5)[:5] if code == 0 and out else []   # a non-fork's parent fields are empty
        if parts and remember:
            git("config", FORK_KEY, f"{parts[1] if parts[0] == 'true' else 'false'} {origin}", cwd=root)
    is_fork = parts[0] == "true" if parts else None            # None: gh could not tell
    fork = parts[1] if is_fork else "" if not repo or code == -1 else None
    if known and not parts:
        fork = None if known == "false" else known
    if url:
        return Upstream("upstream", url, default_branch(root, "upstream", url, offline), fork)
    if is_fork:
        _, full, branch, https, ssh = parts                    # full_name: the fork's current name, after a rename
        return Upstream(None, ssh if origin.startswith(("git@", "ssh://")) else https, branch, full)
    return Upstream("origin", origin, default_branch(root, "origin", origin, offline), None)
