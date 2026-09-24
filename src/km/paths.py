"""Where km looks: the brain it works on, and its own files."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
BASE_SCHEMA = PACKAGE / "schema.base.yaml"
TEMPLATES = PACKAGE / "templates"


def git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    """git, with its output decoded the way Python decodes file names, so each name it lists opens
    the file it names: UTF-8 on Windows and macOS, the locale's encoding on Linux. With the system's
    code page instead (cp1252 on Windows), a name with an umlaut named no file. Bytes that do not
    decode (a git message in another encoding, an odd name) are kept, not a crash."""
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True,
                          encoding=sys.getfilesystemencoding(), errors="surrogateescape")


def write_text(path: Path, text: str) -> None:
    """Every file km writes: UTF-8 with LF, the bytes the repo holds, also where the default is a code
    page and CRLF (Windows)."""
    path.write_text(text, encoding="utf-8", newline="\n")


def repo_root() -> Path:
    """The brain km works on: KM_ROOT if set (the CLI sets it from --root), else the git work tree
    containing the current directory, else the current directory."""
    env = os.environ.get("KM_ROOT")
    if env:
        return Path(env).resolve()
    res = git("rev-parse", "--show-toplevel")
    return Path(res.stdout.strip()).resolve() if res.returncode == 0 else Path.cwd().resolve()
