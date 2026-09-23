"""Shared helpers for the team-brain scripts (gen_index, demote_stale, build_served): the merged
schema, frontmatter parsing, the tracked-file list and what counts as an article.

km-owned (team brains): copied in by `/km init --team`, refreshed by `/km upgrade`; do not edit a
brain's copy, change it in km.

The schema is loaded and merged the way validate.py does it (base, or the legacy schema.yaml,
overlaid by schema.local.yaml; lists extend, dicts shallow-merge), and a broken file stops the run
the same way, so the scripts never act on a different configuration than the validator checks.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str) -> dict | None:
    p = ROOT / name
    if not p.is_file():
        return None
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        sys.exit(f"{name}: invalid YAML: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"{name}: must be a mapping")
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


_base = _load("schema.base.yaml") or _load("schema.yaml")
if _base is None:
    sys.exit("no schema.base.yaml (or schema.yaml) at repo root")
SCHEMA = _merge(_base, _load("schema.local.yaml"))

EXEMPT = set(SCHEMA.get("exempt_files") or [])
RESERVED = set(SCHEMA.get("reserved_no_frontmatter") or [])
SKIP = tuple(SCHEMA.get("skip_prefixes") or [])
INDEX_SKIP = tuple(SCHEMA.get("index_skip_prefixes") or [])
_gate = SCHEMA.get("gate") or {}
if not isinstance(_gate, dict):
    sys.exit("schema.local.yaml: gate must be a mapping")
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


def tracked_md() -> list[str]:
    res = subprocess.run(["git", "ls-files", "-z", "*.md"], cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"git ls-files failed: {res.stderr.strip()}")
    return [p for p in res.stdout.split("\x00") if p and (ROOT / p).is_file()]   # a deletion not yet staged is gone


def is_article(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return not rel.startswith(SKIP) and name != "_index.md" and name not in EXEMPT and name not in RESERVED


def folder_of(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else "."
