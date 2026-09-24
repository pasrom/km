"""What every km command shares: the brain's root, the merged schema (km's own base overlaid by the
brain's schema.local.yaml; lists extend, dicts shallow-merge), frontmatter parsing, the tracked-file
list and what counts as an article. One loader for all commands, so none of them acts on a different
configuration than the validator checks; a broken schema file stops the run.
"""
from __future__ import annotations

import functools
import re
import sys
from pathlib import Path

import yaml

from km.paths import BASE_SCHEMA, git, repo_root

ROOT = repo_root()


def _load(p: Path) -> dict | None:
    if not p.is_file():
        return None
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        sys.exit(f"{p.name}: invalid YAML: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"{p.name}: must be a mapping")
    return data


def _merge(base: dict, local: dict | None) -> dict:
    out = dict(base)
    for k, v in (local or {}).items():
        cur = out.get(k)
        if isinstance(v, list) and isinstance(cur, list):
            out[k] = cur + v
        elif isinstance(v, dict) and isinstance(cur, dict):
            out[k] = {**cur, **v}
        else:
            out[k] = v
    return out


# The brain's overlay. A brain from before the overlay existed has only a legacy schema.yaml (km's
# schema plus its own additions); it overlays the base the same way until `km upgrade` renames it.
OVERLAY = ROOT / ("schema.local.yaml" if (ROOT / "schema.local.yaml").is_file() or not (ROOT / "schema.yaml").is_file()
                  else "schema.yaml")
SCHEMA = _merge(_load(BASE_SCHEMA) or {}, _load(OVERLAY))

EXEMPT = set(SCHEMA.get("exempt_files") or [])
RESERVED = set(SCHEMA.get("reserved_no_frontmatter") or [])
SKIP = tuple(SCHEMA.get("skip_prefixes") or [])
INDEX_SKIP = tuple(SCHEMA.get("index_skip_prefixes") or [])
_gate = SCHEMA.get("gate")
_gate = _gate if isinstance(_gate, dict) else {}   # a malformed gate is reported by `km validate`
SERVED_STATUS = _gate.get("served_status", "accepted")
CUSTOMER_AUDIENCE = _gate.get("customer_audience", "customer")

_FM = re.compile(r"^(---\n(.*?)\n---\n?)(.*)$", re.S)


def split_frontmatter(text: str) -> tuple[dict | None, str, str]:
    """(frontmatter or None, the raw '---' block, body). No or unparsable block: (None, '', text)."""
    m = _FM.match(text)
    if not m:
        return None, "", text
    try:
        fm = yaml.safe_load(m.group(2)) or {}
    except yaml.YAMLError:
        return None, "", text
    return (fm if isinstance(fm, dict) else None), m.group(1), m.group(3)


def frontmatter(text: str) -> dict:
    return split_frontmatter(text)[0] or {}


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")


@functools.cache
def _ls_md() -> tuple[str, ...]:
    res = git("ls-files", "-z", "*.md", cwd=ROOT)
    if res.returncode != 0:
        sys.exit(f"git ls-files failed (not a git repo?): {res.stderr.strip()}")
    return tuple(p for p in res.stdout.split("\x00") if p)


def tracked_md(existing: bool = True) -> list[str]:
    """The tracked .md files, listed by git once per run; with existing=False also those deleted but
    not yet staged."""
    return [p for p in _ls_md() if not existing or (ROOT / p).is_file()]


def is_article(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return not rel.startswith(SKIP) and name != "_index.md" and name not in EXEMPT and name not in RESERVED


def folder_of(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else "."
