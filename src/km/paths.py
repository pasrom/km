"""Where km looks: the brain it works on, and its own files."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
BASE_SCHEMA = PACKAGE / "schema.base.yaml"
TEMPLATES = PACKAGE / "templates"


def git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    """git, with its output read as UTF-8, the encoding git writes. Decoded with the system's code
    page instead (cp1252 on Windows), a file name with an umlaut comes back as one that does not exist."""
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, encoding="utf-8")


def repo_root() -> Path:
    """The brain km works on: KM_ROOT if set (the CLI sets it from --root), else the git work tree
    containing the current directory, else the current directory."""
    env = os.environ.get("KM_ROOT")
    if env:
        return Path(env).resolve()
    res = git("rev-parse", "--show-toplevel")
    return Path(res.stdout.strip()).resolve() if res.returncode == 0 else Path.cwd().resolve()
