"""Where km looks: the brain it works on, and its own files."""
from __future__ import annotations

import functools
import os
import re
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
BASE_SCHEMA = PACKAGE / "schema.base.yaml"
TEMPLATES = PACKAGE / "templates"


def git(*args: str, cwd: Path | None = None, env: dict[str, str] | None = None,
        timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    """git, with its output decoded the way Python decodes file names, so each name it lists opens
    the file it names: UTF-8 on Windows and macOS, the locale's encoding on Linux. With the system's
    code page instead (cp1252 on Windows), a name with an umlaut named no file. Bytes that do not
    decode (a git message in another encoding, an odd name) are kept, not a crash. Without git
    installed it fails like a missing command (127) instead of raising."""
    try:
        return subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, stdin=subprocess.DEVNULL,
                              encoding=sys.getfilesystemencoding(), errors="surrogateescape", timeout=timeout)
    except FileNotFoundError:
        return subprocess.CompletedProcess(["git", *args], 127, "", "git is not installed")


def sets_no_eol(repo: Path) -> bool:
    """Whether the repository's attributes leave the line ending of text files to each computer."""
    res = git("check-attr", "eol", "--", "any.md", cwd=repo)
    return res.returncode == 0 and res.stdout.strip().endswith(": unspecified")


def write_text(path: Path, text: str) -> None:
    """Every file km writes: UTF-8 with LF, the bytes the repo holds, also where the default is a code
    page and CRLF (Windows)."""
    path.write_text(text, encoding="utf-8", newline="\n")


def git_path(root: Path, name: str) -> Path:
    """A file in the repository's git dir (the worktree's own, where .git is a file)."""
    p = Path(git("rev-parse", "--git-path", name, cwd=root).stdout.strip())
    return p if p.is_absolute() else root / p


def rev(root: Path, spec: str) -> str:
    """The commit `spec` names, or '' when it names none here."""
    return git("rev-parse", "-q", "--verify", f"{spec}^{{commit}}", cwd=root).stdout.strip()


@functools.cache
def ahead_behind(root: Path, mine: str, theirs: str) -> tuple[int, int] | None:
    """(commits only mine has, commits only theirs has); None when one of them is not in this
    repository. (0, 0): the same content; (0, n): mine can fast-forward; (n, 0): mine has
    everything theirs has; both: diverged."""
    out = git("rev-list", "--left-right", "--count", f"{mine}...{theirs}", cwd=root).stdout.split()
    return (int(out[0]), int(out[1])) if len(out) == 2 and all(x.isdigit() for x in out) else None


def submodule_config(root: Path, key: str) -> dict[str, str]:
    """{name: value} of submodule.<name>.<key> in .gitmodules; names may hold spaces and dots."""
    res = git("config", "-f", ".gitmodules", "-z", "--get-regexp", rf"^submodule\..*\.{key}$", cwd=root)
    pairs = (rec.partition("\n") for rec in res.stdout.split("\0") if rec)
    return {k[len("submodule."):-len(key) - 1]: v for k, _, v in pairs}


_SAFE_ARG = re.compile(r"[A-Za-z0-9._/][A-Za-z0-9._/ -]*")


def printable(value: str) -> str:
    """A name or path from the repository, fit to print in a line km writes: control characters
    (a `\\n` in git config is a newline) and backticks, which could fake a line or a command in
    the output, become `?`."""
    return re.sub(r"[\x00-\x1f\x7f`]", "?", value)

def command(template: str, **values: str) -> str:
    """A command for a fix line, in backticks, with each value from the repository (a mount's name or
    path, which whoever edits .gitmodules chooses) in double quotes; "" when a value holds anything
    beyond letters, digits, `._/ -` (or starts with `-`), so no line km prints runs a name such as
    `$(...)` when copied into a shell."""
    if not all(_SAFE_ARG.fullmatch(v) for v in values.values()):
        return ""
    return "`" + template.format(**{k: f'"{v}"' for k, v in values.items()}) + "`"


def left_out(root: Path, name: str) -> str:
    """Why this computer leaves the mount `name` out on purpose, "" when it does not: its
    `submodule.<name>.update` is none, or it is set inactive. `git submodule update --checkout` and
    a named path would check it out anyway, so km does not ask git to."""
    if git("config", "--get", f"submodule.{name}.update", cwd=root).stdout.strip() == "none":
        return "update = none"
    if git("config", "--type=bool", "--get", f"submodule.{name}.active", cwd=root).stdout.strip() == "false":
        return "inactive"
    return ""


def repo_root() -> Path:
    """The brain km works on: KM_ROOT if set (the CLI sets it from --root), else the git work tree
    containing the current directory, else the current directory."""
    env = os.environ.get("KM_ROOT")
    if env:
        return Path(env).resolve()
    res = git("rev-parse", "--show-toplevel")
    return Path(res.stdout.strip()).resolve() if res.returncode == 0 else Path.cwd().resolve()


def skip_mount(name: str) -> str:
    """How to leave the mount `name` out on this computer: the command, where its name is safe to print."""
    return command("git config {key} none", key=f"submodule.{name}.update") or "set its `update` to none in the brain's git config"
