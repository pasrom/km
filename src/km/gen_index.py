# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Regenerate the '## Documents' list in every folder's _index.md from the docs in that folder,
plus a link to the _index.md of each direct subfolder, so a new subfolder is reachable from its
parent without anyone remembering to add it.

km-owned (team brains): copied in by `/km init --team`, refreshed by `/km upgrade`; do not edit a
brain's copy, change it in km.

Everything above the '## Documents' heading (frontmatter + hand-written intro) is preserved; only
the list below it is rewritten deterministically, so parallel PRs never conflict on _index.md and
the list can never drift from the folder. `--check` exits non-zero if any _index would change
(for CI); with no flag it writes the updates. A folder with docs or a subfolder index to list but
no _index.md of its own fails the run in both modes: that index is written by hand, then filled by
this script.

Run:  python3 scripts/gen_index.py [--check]
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

from team_common import INDEX_SKIP, ROOT, SKIP, folder_of, frontmatter, is_article, read, tracked_md

_MARK = re.compile(r"(?m)^## Documents[ \t]*$")
_NEXT_H2 = re.compile(r"(?m)^## ")


def _entry(path: str, link: str, fallback: str) -> str:
    fm = frontmatter(read(path))
    title = (fm.get("title") or fallback).replace("[", " ").replace("]", " ")
    desc = fm.get("description")
    return f"- [{title}]({link})" + (f": {desc}" if desc else "")


def render(idx_text: str, docs: list[str], subs: list[str]) -> str | None:
    """Rewrite ONLY the '## Documents' section (matched as a whole-line H2), preserving the intro
    above it and any sections below it. `subs` are the _index.md files of direct subfolders,
    listed first. Returns None when there is no such heading, so a hand-curated index is left alone."""
    mo = _MARK.search(idx_text)
    if not mo:
        return None
    lines = []
    for s in sorted(subs):
        sub = s.rsplit("/", 2)[-2]
        lines.append(_entry(s, f"{sub}/_index.md", f"{sub}/"))
    for d in sorted(docs):
        lines.append(_entry(d, d.rsplit("/", 1)[-1], Path(d).stem.replace("-", " ").title()))
    block = "\n".join(lines) if lines else "_None yet._"
    head = idx_text[:mo.end()]
    nxt = _NEXT_H2.search(idx_text, mo.end())
    tail = ("\n" + idx_text[nxt.start():]) if nxt else ""
    return head + "\n\n" + block + "\n" + tail


def main() -> int:
    check = "--check" in sys.argv[1:]
    files = {p for p in tracked_md() if not p.startswith(SKIP) and not p.startswith(INDEX_SKIP)}
    by_folder: dict[str, list[str]] = defaultdict(list)
    for p in files:
        by_folder[folder_of(p)].append(p)
        if p.endswith("/_index.md"):   # a subfolder's index is also listed by its parent
            parent = folder_of(folder_of(p))
            if parent != "." or "_index.md" in files:   # the root map is optional
                by_folder[parent].append(p)

    changed: list[str] = []
    unindexed: list[str] = []
    for folder, members in sorted(by_folder.items()):
        idx = "_index.md" if folder == "." else f"{folder}/_index.md"
        docs = [m for m in members if is_article(m)]
        subs = [m for m in members if m.endswith("/_index.md") and m != idx]
        if idx not in files:
            if docs or subs:
                unindexed.append(f"{folder}/")
            continue
        cur = read(idx)
        new = render(cur, docs, subs)
        if new is None:
            continue   # no '## Documents' section: a hand-curated index, leave it alone
        if new != cur:
            changed.append(idx)
            if not check:
                (ROOT / idx).write_text(new, encoding="utf-8")

    if check and changed:
        print("gen_index: out of date, run `python3 scripts/gen_index.py`:")
        for c in changed:
            print(f"  - {c}")
    elif changed:
        print(f"gen_index: updated {len(changed)}: {', '.join(changed)}")
    else:
        print("gen_index: up to date")
    if unindexed:
        print("gen_index: these folders have docs or a subfolder index to list but no _index.md; "
              "write one by hand (frontmatter, intro, an empty '## Documents' heading):")
        for u in unindexed:
            print(f"  - {u}")
    return 1 if (check and changed) or unindexed else 0


if __name__ == "__main__":
    sys.exit(main())
