"""Pin each source of a doc to its current content: every entry of a pinned field (`sources`,
`translates`) whose source changed since its pin, or that has no hash yet, is rewritten as
`path.md@<blob>`, the source's blob as staged now, abbreviated. Pins that still match are left alone.

A blob pin depends only on the file's content, so unlike a commit pin it survives a rebase or squash
merge. Run it when a doc is written, and after re-reviewing it when `km validate` reports a stale
pin. An approval vouches for the sources it saw: a signed-off doc whose pins change goes back to
`status: review` without its approval and pre-reviews (`reviewed_by`), to be approved again. Only
the pinned fields are rewritten, as plain YAML; the doc is then gated by `km validate` and restored unchanged if that fails.

With `--cites`, it re-pins the external files the doc cites instead (`cites:`, see km.cites): each
entry whose local copy (`--file URL=PATH`, or mapped with `--dir LOCAL=URLPREFIX`) now hashes
differently gets the new sha256 and today's date, and loses its version label and ctag, which named
the old content; entries that match, or have no copy, keep theirs. A copy km cannot tell for sure
(unreadable, names that differ only in case) is refused. A signed-off doc goes back to review the
same way.

Run:  km repin [--root DIR] <doc.md>...
      km repin [--root DIR] --cites <doc.md>... (--file URL=PATH ... | --dir LOCAL=URLPREFIX ...)
"""
from __future__ import annotations

import argparse
import datetime
import posixpath
import sys

from km.common import PIN, SCHEMA, as_list, pin_state, scalar, send_back, set_fm_block, staged_blob, unstaged
from km.cites import Copies, add_copy_args, copies_from, editable, read_copies, write
from km.edit import edit_docs

ABBREV = 12   # hex digits of a written pin: unambiguous in any brain, short enough to read
PINNED = [f for f, spec in SCHEMA["fields"].items() if spec.get("format") == "path_at_hash"]


def change(fm: dict, raw: str):
    """Re-pin one doc's frontmatter: the refusal, or `(new_raw, message)` for `edit_docs`."""
    before, changed, missing, uncompared, seen = raw, [], [], [], set()
    for field in PINNED:
        values = [v for v in as_list(fm.get(field)) if v]   # an empty entry, as validate skips it
        if not values:
            continue
        pins, before_field = [], len(changed)
        for v in values:
            m = PIN.match(str(v))
            src = (m.group(1) if m else str(v)).strip()
            seen.add(posixpath.normpath(src.lstrip("/")))   # as `git diff --relative` names it
            state = pin_state(str(v)) if m else None
            if state == "current":
                pins.append(str(v))
                continue
            if state == "unknown":
                uncompared.append(src)
            blob = staged_blob(src) if src.endswith(".md") else ""
            if not blob:
                missing.append(src)
                continue
            pins.append(f"{src}@{blob[:ABBREV]}")
            changed.append(src)
        if len(changed) == before_field:
            continue                    # every pin of this field is current: leave its lines alone
        text = ("\n".join([f"{field}:", *(f"- {scalar(p)}" for p in pins)])
                if isinstance(fm.get(field), list) else f"{field}: {scalar(pins[0])}")
        if (raw := set_fm_block(raw, field, text)) is None:
            return f"cannot find the `{field}:` line to rewrite"
    if missing:
        return f"not a tracked .md file, cannot pin: {', '.join(missing)}"
    dirty = sorted(seen & unstaged())
    note = f"; {', '.join(dirty)} has edits not staged yet, pinned as staged (`git add` it, then repin)" if dirty else ""
    if not changed:
        return before, "already pins the current content" + note
    message = f"pins the current content of {', '.join(changed)}" + note
    if uncompared:
        message += f"; could not compare {', '.join(uncompared)} with the old pin (not in this clone's history)"
    return send_back(fm, raw, message)


def change_cites(copies: Copies, today: datetime.date):
    """Re-pin the cited files that changed, against their local copies: `change` for `edit_docs`."""
    def change(fm: dict, raw: str):
        if isinstance(items := editable(fm), str):
            return items
        changed, unclear, labelled, uncopied = [], [], [], []
        for e in items:
            r = read_copies(e, copies)
            if r.missing:
                uncopied.append(f"{e['url']} ({r.why})")
                continue
            if not r.digest:   # unreadable or ambiguous: never guess
                unclear.append(f"{e['url']}: {r.why}")
                continue
            if e["sha256"].lower() == r.digest:
                continue
            digest, path = r.digest, r.copy
            if e.pop("version", None) is not None:   # the label and ctag named the old content
                labelled.append(e["url"])
            e.pop("ctag", None)
            e["sha256"], e["retrieved"] = digest, today
            changed.append(f"{e['url']} (from {path})")
        if unclear:
            return f"cannot tell which local copy is the cited file, pass it with --file URL=PATH: {'; '.join(unclear)}"
        note = f"; not compared: {', '.join(uncopied)}" if uncopied else ""
        if not changed:
            return raw, ("already cites the content of its local copies" if len(uncopied) < len(items)
                         else "compared nothing") + note
        message = f"cites the current content of {', '.join(changed)}" + note
        if labelled:
            message += f"; dropped the old version label of {', '.join(labelled)}, set it again with `km cite add --version`"
        return write(fm, raw, items, message, changed=True)
    return change


def main() -> int:
    ap = argparse.ArgumentParser(prog="km repin", allow_abbrev=False)   # cli's version gate sees exact options
    ap.add_argument("docs", nargs="+")
    ap.add_argument("--cites", action="store_true", help="re-pin the cited external files (cites:) against local copies")
    add_copy_args(ap)
    a = ap.parse_args()
    if a.cites != bool(a.file or a.dir):
        ap.error("--cites needs --file URL=PATH or --dir LOCAL=URLPREFIX" if a.cites else "--file and --dir go with --cites")
    if a.cites:
        if isinstance(copies := copies_from(a), str):
            ap.error(copies)
        refused = edit_docs(a.docs, change_cites(copies, datetime.date.today()), "repin")
        for url in sorted(set(copies.files) - copies.used):
            print(f"repin: no doc given cites {url}", file=sys.stderr)
        if hint := copies.hint():
            print(f"repin: {hint}", file=sys.stderr)
    else:
        refused = edit_docs(a.docs, change, "repin")
    for why in refused:
        print(f"repin: REFUSED {why}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
