"""List the brain's docs from their frontmatter, filtered: `km list [PATH...] [filters] [--json]`.

One row per doc, sorted by path: path, status, signoff, title by default (`--fields` picks others,
any frontmatter key; a list value is joined with commas). `signoff` is computed: who may sign the doc
off, `ai` only for an internal doc at level ai, as km approve decides; the frontmatter key `approval`
stays its own field. Filters combine (all must match):

  PATH...              docs at or below these folders or files
  --status S           status, repeatable (`--status review --status draft`)
  --type T, --audience A, --tag T, --owner O
  --signoff ai|human   who may sign the doc off
  --due DATE           review_by before DATE (YYYY-MM-DD), or `today`: overdue as km demote counts it
  --all                also folder indexes and files without frontmatter

PATH is taken from the current directory when it lies in the brain, else (or when only that exists)
from the brain root. A path that does not exist, or a mounted brain (list it with --root), is refused.
A doc whose frontmatter does not parse is skipped with a note.
Read-only, so it runs this km whatever km the brain pins: which files count as docs and the approval
rule are this km's, which may differ slightly from the pinned km's validate. `--json` prints a list of
objects with the chosen fields, for a script or an agent. Exit 1 when no doc matches, like grep.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
import unicodedata
from pathlib import Path

from km.common import (ROOT, SCHEMA, approval_level, as_list, is_article, plain, read, review_by_default_problem,
                       review_due, split_frontmatter, submodule_prefixes, tracked_md, under)

DEFAULT_FIELDS = ("path", "status", "signoff", "title")
COMPUTED = ("path", "signoff")


def value(fm: dict, rel: str, field: str):
    if field == "path":
        return rel
    if field == "signoff":
        return approval_level(fm)
    v = fm.get(field)
    return v.isoformat() if isinstance(v, datetime.date) else v


def shown(v) -> str:
    if v is None:
        return ""
    if isinstance(v, list):
        return ",".join(shown(x) for x in v)
    # one line per row; control characters (a terminal escape in a contributed title) shown as '?'
    return "".join("?" if unicodedata.category(ch) == "Cc" else ch for ch in " ".join(str(v).split()))


def day(text: str) -> datetime.date:
    try:
        return datetime.date.today() if text == "today" else datetime.date.fromisoformat(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD or today): {text}") from None


def brain_path(arg: str, ap: argparse.ArgumentParser) -> str:
    """A PATH argument as a path from the brain root ("" for the root itself): from the current
    directory when that lies in the brain, else from the root, and from the root also when only that
    path exists. Refused: outside the brain, nowhere, or a mounted brain."""
    root, here = ROOT.resolve(), Path.cwd().resolve()
    tries = [(here / arg).resolve()] if here.is_relative_to(root) else []
    tries.append((root / arg).resolve())
    full = next((t for t in tries if t.exists()), tries[0])
    if not full.is_relative_to(root):
        ap.error(f"{arg} is outside the brain")
    if not full.exists():
        ap.error(f"{arg}: no such file or folder in the brain")
    rel = full.relative_to(root).as_posix()
    # a mounted brain: below a .gitmodules path or brains/, or a folder with its own .git on the way
    repo = next((d for d in [full, *full.parents] if d != root and d.is_relative_to(root) and (d / ".git").exists()), None)
    mount = repo.relative_to(root).as_posix() if repo else next((m for m in submodule_prefixes() if under(rel, [m])), None)
    if mount == "brains":                          # brains/ holds the mounts: brains/<name>
        mount = "/".join(rel.split("/")[:2]) if "/" in rel else "brains/<name>"
    if mount:
        ap.error(f"{arg} lies in a mounted brain with its own files: `km list --root {mount}`")
    return "" if rel == "." else rel


def main() -> int:
    ap = argparse.ArgumentParser(prog="km list", description="list the brain's docs from their frontmatter")
    ap.add_argument("paths", nargs="*", metavar="PATH", help="folders or files, from the current folder or the brain root")
    ap.add_argument("--status", action="append", default=[])
    ap.add_argument("--type", action="append", default=[])
    ap.add_argument("--audience", action="append", default=[])
    ap.add_argument("--tag", action="append", default=[])
    ap.add_argument("--owner", action="append", default=[])
    ap.add_argument("--signoff", choices=("ai", "human"), help="who may sign the doc off")
    ap.add_argument("--due", type=day, metavar="DATE", help="review_by before DATE, or `today` (overdue)")
    ap.add_argument("--fields", default=",".join(DEFAULT_FIELDS), help="comma-separated (default: %(default)s)")
    ap.add_argument("--all", action="store_true", help="also folder indexes and files without frontmatter")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.due and (why := review_by_default_problem()):   # a bad table would read as "nothing expires"
        ap.error(f"schema.local.yaml: {why}")
    fields = [f.strip() for f in a.fields.split(",") if f.strip()]
    if not fields:
        ap.error("--fields names no field")
    prefixes = [brain_path(p.replace("\\", "/"), ap) for p in a.paths]
    prefixes = [] if "" in prefixes else prefixes
    tracked = sorted(tracked_md())
    # on a case-insensitive file system a folder typed in other letter case exists: use git's spelling
    prefixes = [next((t[:len(p)] for t in tracked if under(t.lower(), [p.lower()])), p) for p in prefixes]

    rows, broken = [], []
    for rel in tracked:
        if (prefixes and not under(rel, prefixes)) or not (a.all or is_article(rel)):
            continue
        text = read(rel)
        parsed = split_frontmatter(text)[0]
        if parsed is None and text.startswith("---"):
            broken.append(rel)
        fm = parsed or {}
        if not fm and not a.all:
            continue
        due = review_due(fm)   # none for a type that does not expire, as km demote counts it
        if ((a.status and fm.get("status") not in a.status)
                or (a.type and fm.get("type") not in a.type)
                or (a.audience and fm.get("audience") not in a.audience)
                or (a.owner and not set(a.owner) & {str(o) for o in as_list(fm.get("owner"))})
                or (a.tag and not set(a.tag) & {str(t) for t in as_list(fm.get("tags"))})
                or (a.signoff and approval_level(fm) != a.signoff)
                or (a.due and (due is None or due >= a.due))):
            continue
        rows.append({f: value(fm, rel, f) for f in fields})

    if broken:
        print(f"km list: {len(broken)} doc(s) whose frontmatter does not parse, e.g. {broken[0]}, "
              + ("listed without fields" if a.all else "left out") + " (`km validate` says why)", file=sys.stderr)
    known = set(SCHEMA.get("fields") or {})
    if rows and (unknown := [f for f in fields if f not in COMPUTED and f not in known
                             and all(r[f] is None for r in rows)]):
        print(f"km list: no listed doc has {', '.join(unknown)}, and the schema does not know it (a typo?)", file=sys.stderr)
    if a.json:
        # ASCII: survives any console encoding; plain: a mapping key YAML reads as a date, as its text
        print(json.dumps(plain(rows), indent=1, default=str))
        return 0 if rows else 1
    if not rows:
        print("km list: no doc matches", file=sys.stderr)
        return 1
    table = [[shown(r[f]) for f in fields] for r in rows]
    widths = [max(len(f), *(len(t[i]) for t in table)) for i, f in enumerate(fields)]
    for line in [list(fields), *table]:             # the last column is not padded
        print("  ".join(c.ljust(w) for c, w in zip(line[:-1], widths)) + ("  " if len(line) > 1 else "") + line[-1])
    print(f"{len(rows)} doc(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
