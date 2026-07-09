# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Validate knowledge-base frontmatter against the km schema — a strict OKF v0.1 profile.

km-owned engine. Vendored into each brain at `scripts/validate.py` and refreshed via
`/km upgrade`. Loads `schema.base.yaml` (canonical) merged with an optional repo-local
`schema.local.yaml` overlay (skip_prefixes / exempt_files / repo-only fields). Falls back
to a single legacy `schema.yaml` for un-migrated repos.

Two modes: whole repo (git ls-files) or per-file args (pre-commit staged files).
Exit code 0 if no errors, 1 otherwise. Warnings never fail the build.
Run:  uv run scripts/validate.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str):
    p = ROOT / name
    return yaml.safe_load(p.read_text()) if p.is_file() else None


def _merge(base: dict, local: dict | None) -> dict:
    """Overlay local onto base: extend lists, shallow-merge dicts, override scalars."""
    out = dict(base)
    for k, v in (local or {}).items():
        cur = out.get(k)
        if isinstance(v, list) and isinstance(cur, list):
            out[k] = cur + v
        elif isinstance(v, dict) and isinstance(cur, dict):
            merged = dict(cur)
            merged.update(v)
            out[k] = merged
        else:
            out[k] = v
    return out


BASE = _load("schema.base.yaml")
if BASE is None:
    BASE = _load("schema.yaml")          # legacy single-file fallback
if BASE is None:
    sys.exit("no schema.base.yaml (or schema.yaml) at repo root")
SCHEMA = _merge(BASE, _load("schema.local.yaml"))

FIELDS = SCHEMA["fields"]
TYPE_RULES = SCHEMA.get("type_rules", {})
SOFT_RULES = SCHEMA.get("type_rules_soft", {})
STATUS_RULES = SCHEMA.get("status_rules", {})
EXEMPT = set(SCHEMA.get("exempt_files", []))
RESERVED_NF = set(SCHEMA.get("reserved_no_frontmatter", []))
SKIP_PREFIXES = tuple(SCHEMA.get("skip_prefixes", []))

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$")
PATH_AT_HASH = re.compile(r"^.+\.md@[0-9a-fA-F]{7,40}$")

errors: list[tuple[str, str, str]] = []    # (category, path, detail)
warnings: list[tuple[str, str, str]] = []


def is_validatable(p: str) -> bool:
    if not p or p.startswith(SKIP_PREFIXES):
        return False
    name = p.rsplit("/", 1)[-1]
    return name != "_index.md" and name not in EXEMPT


def targets() -> list[str]:
    """Files passed as args (e.g. pre-commit staged files) else the whole repo."""
    given = [a for a in sys.argv[1:] if not a.startswith("-")]
    if given:
        out = []
        for a in given:
            try:
                rel = str(Path(a).resolve().relative_to(ROOT))
            except ValueError:
                print(f"skip (outside repo): {a}", file=sys.stderr)
                continue
            if rel.endswith(".md") and is_validatable(rel) and (ROOT / rel).is_file():
                out.append(rel)
        return out
    res = subprocess.run(
        ["git", "ls-files", "-z", "*.md"], cwd=ROOT, capture_output=True, text=True
    )
    if res.returncode != 0:
        sys.exit(f"git ls-files failed (not a git repo?): {res.stderr.strip()}")
    return [p for p in res.stdout.split("\x00") if is_validatable(p)]


def frontmatter(text: str):
    if not text.startswith("---"):
        return None
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    try:
        return yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        return {"__error__": str(exc)}


def resolve_ref(rel: str, target: str) -> bool:
    target = target.split("@", 1)[0].strip()
    if not target.endswith(".md"):
        return True
    if (ROOT / target.lstrip("/")).exists():
        return True
    return ((ROOT / rel).parent / target).exists()


def blob_exists(pin: str) -> bool:
    """For a path.md@hash pin, verify the blob existed at that commit in git."""
    path, _, h = pin.partition("@")
    res = subprocess.run(
        ["git", "cat-file", "-e", f"{h}:{path.lstrip('/')}"],
        cwd=ROOT,
        capture_output=True,
    )
    return res.returncode == 0


for rel in targets():
    name = rel.rsplit("/", 1)[-1]
    text = (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")
    fm = frontmatter(text)

    if name in RESERVED_NF:
        if fm is not None:
            errors.append(("reserved-file", rel, f"'{name}' must have no frontmatter"))
        continue
    if fm is None:
        errors.append(("no-frontmatter", rel, "missing YAML frontmatter"))
        continue
    if isinstance(fm, dict) and "__error__" in fm:
        errors.append(("unparseable", rel, fm["__error__"]))
        continue
    if not isinstance(fm, dict):
        errors.append(("non-mapping", rel, "frontmatter is not a key:value mapping"))
        continue

    # apply field aliases declared in the schema (e.g. date -> timestamp)
    for _field, _spec in FIELDS.items():
        _alias = _spec.get("alias")
        if _alias and _field not in fm and _alias in fm:
            fm[_field] = fm[_alias]

    for field, spec in FIELDS.items():
        if spec.get("required") and field not in fm:
            errors.append((f"missing:{field}", rel, f"required field '{field}' absent"))
        if field in fm and "enum" in spec and fm[field] not in spec["enum"]:
            errors.append((f"enum:{field}", rel, f"{field}={fm[field]!r}"))
        if field in fm and spec.get("type") == "list" and not isinstance(fm[field], list):
            errors.append((f"type:{field}", rel, f"{field} must be a list"))
        if field in fm and spec.get("format") == "iso8601" and not ISO.match(str(fm[field])):
            warnings.append((f"iso8601:{field}", rel, f"{field}={fm[field]!r}"))
        if field in fm and spec.get("format") == "path_at_hash":
            vals = fm[field] if isinstance(fm[field], list) else [fm[field]]
            for v in vals:
                if not v:
                    continue
                if not PATH_AT_HASH.match(str(v)):
                    warnings.append((f"pin:{field}", rel, f"{v!r} not path.md@hash"))
                elif not blob_exists(str(v)):
                    warnings.append((f"pin:{field}", rel, f"{v!r} not in git history"))
        if field in fm and spec.get("ref"):
            vals = fm[field] if isinstance(fm[field], list) else [fm[field]]
            for v in vals:
                if v and not resolve_ref(rel, str(v)):
                    warnings.append((f"ref:{field}", rel, f"missing target {v}"))

    t = fm.get("type")
    rule = TYPE_RULES.get(t, {}) if isinstance(t, str) else {}
    for req in rule.get("require", []):
        if req not in fm:
            errors.append((f"type-rule:{t}", rel, f"type '{t}' requires '{req}'"))
    soft = SOFT_RULES.get(t, {}) if isinstance(t, str) else {}
    for rec in soft.get("recommend", []):
        if rec not in fm:
            warnings.append((f"soft:{t}", rel, f"type '{t}' should have '{rec}'"))

    st = fm.get("status")
    if st == "superseded":
        for r in STATUS_RULES.get("superseded_requires", []):
            if r not in fm:
                errors.append(("status-rule", rel, f"superseded requires '{r}'"))
    if st == "obsolete":
        for r in STATUS_RULES.get("obsolete_forbids", []):
            if r in fm:
                warnings.append(("status-rule", rel, f"obsolete should not set '{r}'"))
    if st == "accepted":
        for r in STATUS_RULES.get("accepted_recommends", []):
            if r not in fm:
                warnings.append(("status-soft", rel, f"accepted should record '{r}'"))


def report(title: str, items: list[tuple[str, str, str]]) -> None:
    print(f"\n{title}: {len(items)}")
    by_cat: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for cat, rel, detail in items:
        by_cat[cat].append((rel, detail))
    for cat, rows in sorted(by_cat.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(rows):>4} x {cat}")
        for rel, detail in rows[:4]:
            print(f"          {rel} - {detail}")
        if len(rows) > 4:
            print(f"          ... +{len(rows) - 4} more")


report("ERRORS", errors)
report("WARNINGS", warnings)
print()
sys.exit(1 if errors else 0)
