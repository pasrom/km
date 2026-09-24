"""Where km looks: the brain it works on, and its own files."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
BASE_SCHEMA = PACKAGE / "schema.base.yaml"
TEMPLATES = PACKAGE / "templates"


def repo_root() -> Path:
    """The brain km works on: KM_ROOT if set (the CLI sets it from --root), else the git work tree
    containing the current directory, else the current directory."""
    env = os.environ.get("KM_ROOT")
    if env:
        return Path(env).resolve()
    res = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(res.stdout.strip()).resolve() if res.returncode == 0 else Path.cwd().resolve()
