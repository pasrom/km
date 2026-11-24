"""Regenerate the '## Documents' list in every folder's _index.md from the docs in that folder,
plus a link to the _index.md of each direct subfolder, so a new subfolder is reachable from its
parent without anyone remembering to add it.

Everything above the '## Documents' heading (frontmatter + hand-written intro) is preserved; only
the list below it is rewritten deterministically, so parallel PRs never conflict on _index.md and
the list can never drift from the folder. `--check` exits non-zero if any _index would change
(for CI); with no flag it writes the updates. A folder with docs or a subfolder index to list but
no _index.md of its own fails `--check`; with no flag, in a brain where some tracked _index.md already
has that heading, the script creates the index from SCAFFOLDS (and its parent folders' where they lack
one too), fills its list and stages it. The scaffold holds nothing but the folder's path, so `km ready`
can tell an index this script created from one written by hand; a folder whose name is not plain
(SEGMENT) gets none and still fails the run, and so does one with anything in the way. The km-gen-index
pre-commit hook runs it at every commit, so a rewritten or created index fails the commit until it is
staged too (the hook stages nothing: on `git commit <paths>` that would land in a temporary index).

Run:  km gen-index [--root DIR] [--check]
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

from km.common import INDEX_SKIP, ROOT, SKIP, fm_text, folder_of, is_article, read, split_frontmatter, tracked_md
from km.paths import git, write_text

_MARK = re.compile(r"(?m)^## Documents[ \t]*$")
_NEXT_H2 = re.compile(r"(?m)^## ")
# a folder name the scaffold may carry: it lands in YAML, a heading and the parent's list unescaped
SEGMENT = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]*")
# The _index.md text `km gen-index` creates for a folder, filled from its path alone (no date, author or
# schema value), since `km ready` rebuilds it from the path without a checkout to tell a created index
# from one written by hand. Append-only: a new wording goes at the end, and an index an older km
# created still counts.
SCAFFOLDS = (
    '---\ntype: reference\ntitle: "{leaf}/"\ndescription: "Documents in {folder}/."\nstatus: draft\n'
    'tags: [index]\n---\n\n# {leaf}\n\n## Documents\n',
)


def scaffolds(idx_path: str) -> tuple[str, ...]:
    """Every text SCAFFOLDS gives the _index.md at `idx_path`, the current one last; none for the root
    index or a folder with a part that is not a plain name."""
    folder, _, name = idx_path.rpartition("/")
    if name != "_index.md" or not all(SEGMENT.fullmatch(p) for p in folder.split("/")):
        return ()
    return tuple(t.format(leaf=folder.rsplit("/", 1)[-1], folder=folder) for t in SCAFFOLDS)


def _entry(path: str, link: str, fallback: str) -> str:
    fm, raw, _ = split_frontmatter(read(path))
    # As written: YAML reads `title: 1.10` as 1.1 and km validate takes it; a block scalar has line
    # breaks, which would split the list entry.
    title, desc = (" ".join((fm_text(fm or {}, raw, k) or "").splitlines()) for k in ("title", "description"))
    title = (title or fallback).replace("[", " ").replace("]", " ")
    return f"- [{title}]({link})" + (f": {desc}" if desc else "")


def kept_parts(idx_text: str) -> tuple[str, str] | None:
    """What render keeps of an index: the text up to and with the '## Documents' heading, and from the
    next H2 on ('' when none); None without the heading."""
    mo = _MARK.search(idx_text)
    if not mo:
        return None
    nxt = _NEXT_H2.search(idx_text, mo.end())
    return idx_text[:mo.end()], idx_text[nxt.start():] if nxt else ""


def render(idx_text: str, docs: list[str], subs: list[str]) -> str | None:
    """Rewrite ONLY the '## Documents' section (matched as a whole-line H2), preserving the intro
    above it and any sections below it. `subs` are the _index.md files of direct subfolders,
    listed first. Returns None when there is no such heading, so a hand-curated index is left alone."""
    parts = kept_parts(idx_text)
    if parts is None:
        return None
    lines = []
    for s in sorted(subs):
        sub = s.rsplit("/", 2)[-2]
        lines.append(_entry(s, f"{sub}/_index.md", f"{sub}/"))
    for d in sorted(docs):
        lines.append(_entry(d, d.rsplit("/", 1)[-1], Path(d).stem.replace("-", " ").title()))
    block = "\n".join(lines) if lines else "_None yet._"
    head, tail = parts
    return head + "\n\n" + block + "\n" + ("\n" + tail if tail else "")


def _by_folder(files: set[str]) -> dict[str, tuple[str, list[str], list[str]]]:
    """Each folder with an _index.md or something to list: (its _index.md, its docs, its direct
    subfolders' indexes)."""
    members: dict[str, list[str]] = defaultdict(list)
    for p in files:
        members[folder_of(p)].append(p)
        if p.endswith("/_index.md"):   # a subfolder's index is also listed by its parent
            parent = folder_of(folder_of(p))
            if parent != "." or "_index.md" in files:   # the root map is optional
                members[parent].append(p)
    out = {}
    for folder, ms in members.items():
        idx = "_index.md" if folder == "." else f"{folder}/_index.md"
        docs = [m for m in ms if is_article(m)]
        subs = [m for m in ms if m.endswith("/_index.md") and m != idx]
        if docs or subs or idx in files:
            out[folder] = (idx, docs, subs)
    return out


def _ours(idx: str) -> bool:
    """Whether an untracked _index.md on disk is one gen-index wrote (a run that could not stage it):
    above its list exactly a scaffold for its path, read without following a symlink."""
    path = ROOT / idx
    if path.is_symlink() or not path.is_file():
        return False
    return kept_parts(path.read_text(encoding="utf-8", errors="replace")) in map(kept_parts, scaffolds(idx))


def regenerate(check: bool = False, create: bool = False, stage: bool = True) -> tuple[list[str], list[str], list[str]]:
    """Rewrite every _index.md whose '## Documents' list is out of date (with check, write nothing); with
    create, in a brain that already generates a list, first write SCAFFOLDS for a folder with something
    to list but no _index.md (its parents' too, which then have one to list), and with stage add it to
    git after its list is filled: (the indexes that changed, the folders with something to list still
    without an _index.md, the indexes created). It never writes where git still tracks the path (deleted
    in the work tree) or anything exists, a dangling symlink included, but takes back a scaffold an
    earlier run wrote and did not stage."""
    files = {p for p in tracked_md() if not p.startswith(SKIP) and not p.startswith(INDEX_SKIP)}
    by_folder = _by_folder(files)
    created: list[str] = []
    if create and not check and any(_MARK.search(read(p)) for p in files if p.rsplit("/", 1)[-1] == "_index.md"):
        gone = set(tracked_md(existing=False))      # tracked, deleted in the work tree: somebody's index
        while new := sorted(idx for idx, _, _ in by_folder.values() if idx not in files and idx not in gone
                            and scaffolds(idx) and (_ours(idx) or not os.path.lexists(ROOT / idx))):
            for idx in new:
                write_text(ROOT / idx, scaffolds(idx)[-1])
            files.update(new)
            created += new
            by_folder = _by_folder(files)

    changed: list[str] = []
    unindexed: list[str] = []
    for folder, (idx, docs, subs) in sorted(by_folder.items()):
        if idx not in files:
            unindexed.append(f"{folder}/")
            continue
        cur = read(idx)
        new = render(cur, docs, subs)
        if new is None:
            continue   # no '## Documents' section: a hand-curated index, leave it alone
        if new != cur:
            changed.append(idx)
            if not check:
                write_text(ROOT / idx, new)
    if stage and created and (res := git("add", "--", *created, cwd=ROOT)).returncode:
        sys.exit(f"km gen-index: could not stage {', '.join(created)}: {res.stderr.strip()}")
    return [c for c in changed if c not in created], unindexed, created


def main() -> int:
    ap = argparse.ArgumentParser(prog="km gen-index", allow_abbrev=False,
                                 description="Regenerate the '## Documents' list in every _index.md, creating a missing one.")
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if an _index.md would change")
    check = ap.parse_args().check
    # under pre-commit, staging would go to the hook's temporary index on a `git commit <paths>`: the
    # commit fails instead, as on a rewritten list, and the next run takes the scaffold back
    hook = bool(os.environ.get("PRE_COMMIT"))
    changed, unindexed, created = regenerate(check, create=True, stage=not hook)
    if created:
        print(f"km gen-index: created {'' if hook else 'and staged '}{len(created)}: {', '.join(created)}"
              f"{'; stage them and commit again' if hook else ''}; an intro above '## Documents' goes in a "
              f"pull request of its own, which a person merges")
    if check and changed:
        print("km gen-index: out of date, run `km gen-index`:")
        for c in changed:
            print(f"  - {c}")
    elif changed:      # run by pre-commit (it sets PRE_COMMIT), the commit fails on the rewrite
        again = "; stage them and commit again" if hook else ""
        print(f"km gen-index: updated {len(changed)}: {', '.join(changed)}{again}")
    elif not created:
        print("km gen-index: up to date")
    if unindexed:
        fix = ("`km gen-index` creates one for a folder with a plain name (A-Z, a-z, 0-9, '.', '_', '-') in "
               "a brain with a generated list, if nothing is in the way; write and stage any other by hand "
               "(frontmatter, intro, an empty '## Documents' heading)")
        print(f"km gen-index: these folders have docs or a subfolder index to list but no _index.md; {fix}:")
        for u in unindexed:
            print(f"  - {u}")
    return 1 if (check and changed) or unindexed or (hook and created) else 0


if __name__ == "__main__":
    sys.exit(main())
