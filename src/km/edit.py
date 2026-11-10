"""Edit docs in place and gate them with `km validate`, restoring any that fail."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

from km.common import ROOT, SERVED_STATUS, SKIP, frontmatter, sent_back_left, split_frontmatter
from km.paths import write_text


ARGS_MAX = 8000   # characters of paths in one gate command line, well below Windows' 32K limit


def run_gate(*targets: Path):
    """`km validate` on these files, in a child process: km reads its root and schema once, at import."""
    return subprocess.run([sys.executable, "-P", "-m", "km", "validate", "--root", str(ROOT), *map(str, targets)],
                          cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace",
                          env={**os.environ, "PYTHONIOENCODING": "utf-8"})   # the child writes UTF-8 too


class Loaded(NamedTuple):
    path: Path
    rel: str
    old: bytes   # restored byte for byte if the gate fails (a BOM included)
    fm: dict
    raw: str
    body: str


def not_a_doc(doc: str, path: Path) -> str:
    """Why a doc argument is not a doc of this brain (outside it, under skip_prefixes, missing),
    or '' when it is one."""
    try:
        rel = path.relative_to(ROOT).as_posix()
    except ValueError:
        return f"{doc}: outside the brain"
    if rel.startswith(SKIP):
        return f"{rel}: under skip_prefixes (a mounted brain or excluded folder), change it in its own repo"
    if not path.is_file():
        return f"{rel}: no such file"
    return ""


def load_doc(doc: str, path: Path) -> Loaded | str:
    """Read a doc of this brain for an in-place edit. Returns it, or why it cannot be edited."""
    if why := not_a_doc(doc, path):
        return why
    rel = path.relative_to(ROOT).as_posix()
    old = path.read_bytes()
    try:
        text = old.decode("utf-8-sig").replace("\r\n", "\n")   # strict decode (written back); CRLF like read()
    except UnicodeDecodeError:
        return f"{rel}: not UTF-8"
    fm, raw, body = split_frontmatter(text)
    if fm is None:
        return f"{rel}: no frontmatter"
    return Loaded(path, rel, old, fm, raw, body)


def edit_docs(docs: list[str], change, prog: str) -> list[str]:
    """Edit the docs' frontmatter in place, then gate them with `km validate`. `change(fm, raw, body)`
    returns the refusal as a string, or `(new_raw, message)`: the raw '---' block to write and what
    `prog` prints after the doc's path once it passed. All docs are written before the gate runs, so
    docs linking to each other pass together; a doc that fails is restored byte for byte, which can
    fail another, until none fails. Returns why each refused doc was refused."""
    refused, edits, seen = [], [], set()
    for doc in docs:
        path = Path(doc).resolve()
        if path in seen:
            continue   # a doc named twice is handled once
        seen.add(path)
        d = load_doc(doc, path)
        if isinstance(d, str):
            refused.append(d)
            continue
        res = change(d.fm, d.raw, d.body)
        if isinstance(res, str):
            refused.append(f"{d.rel}: {res}")
        elif res[0] == d.raw:
            print(f"{prog}: {d.rel} {res[1]}")
        else:
            edits.append((d, *res))
    pending = {}   # written but not yet confirmed: restored if anything goes wrong on the way
    try:
        for d, raw, message in edits:
            pending[d.path] = d, message
            write_text(d.path, raw + d.body)
        while pending:
            together = len(pending) > 1 and sum(len(str(p)) + 1 for p in pending) < ARGS_MAX
            if together and (whole := run_gate(*pending)).returncode == 0:
                break                     # one run while all pass; alone, to find which ones to restore
            failed = [(d, gate) for d, _ in pending.values() if (gate := run_gate(d.path)).returncode != 0]
            if not failed and not together:
                break
            for d, gate in failed or [(d, whole) for d, _ in pending.values()]:   # fail only together: none passes
                d.path.write_bytes(d.old)
                del pending[d.path]
                refused.append(f"{d.rel}: km validate fails after the change, left unchanged:\n{gate.stdout.rstrip()}")
        accepted, pending = list(pending.values()), {}
    finally:
        for d, _ in pending.values():
            try:
                d.path.write_bytes(d.old)
            except OSError as e:
                print(f"{prog}: could not restore {d.rel}: {e}", file=sys.stderr)
    for d, message in accepted:
        print(f"{prog}: {d.rel} {message}")
    return refused


def edit_sending_back(docs: list[str], change, prog: str) -> int:
    """edit_docs for an edit that may send an accepted doc back to review (km.common.send_back):
    prints why each refused doc was refused, and how many docs it sent back still carry a key km
    cannot find (quoted) for a person to drop. Such a doc is written all the same, so it leaves the
    served set, but the run fails, as `km demote --apply` does. The exit code: 1 if either, else 0."""
    left: set[str] = set()   # the blocks written back to review with a key left in

    def sending(fm: dict, raw: str, body: str):
        res = change(fm, raw, body)
        if (not isinstance(res, str) and fm.get("status") == SERVED_STATUS and sent_back_left(res[0])
                and frontmatter(res[0]).get("status") != SERVED_STATUS):   # not a relabel that keeps it accepted
            left.add(res[0])
        return res
    refused = edit_docs(docs, sending, prog)
    for why in refused:
        print(f"{prog}: REFUSED {why}")
    # counted from what is on disk now: a doc the gate refused was restored, still accepted
    partial = sum(not isinstance(d := load_doc(p, p), str) and d.raw in left
                  for p in {Path(doc).resolve() for doc in docs}) if left else 0
    if partial:
        print(f"km {prog}: {partial} doc(s) sent back still carry a key km cannot find (quoted?); drop it by hand")
    return 1 if refused or partial else 0
