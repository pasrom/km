"""Demote stale served docs: an accepted (served) doc whose `review_by` has lapsed drops back to
`status: review` (its approval invalidated), so it leaves the served set automatically instead of
being served forever. This is the staleness mechanism the model needs; run it on a schedule in CI.
A type that does not expire (`review_by_default` null) is never demoted, whatever `review_by` it carries.

Dry-run by default (lists what would change, exit 1 if any); `--apply` rewrites the files. Either
names each doc's owner, who re-reviews it. A doc whose approval key it cannot find (quoted:
`"approved_by": x`) is demoted all the same, so it leaves the served set, but the key stays and the
run exits 1 after demoting the others: drop it by hand.

With docs named, it sends those accepted docs back to review now, whatever their date: their
approval and pre-reviews (`reviewed_by`) dropped, as `km repin` does; a key it cannot find (quoted)
stays, named, and the run exits 1. That is how a change to an
accepted doc is committed: the doc goes back to review in the same commit, and its approval follows
in a commit of its own (`km validate` reports a changed doc that is still accepted as approval-stale).

Run:  km demote [--root DIR] [--apply]
      km demote [--root DIR] <doc.md>...
"""
from __future__ import annotations

import argparse
import datetime
import sys

from km.common import (ROOT, SERVED_STATUS, approval_left, demote_raw, is_article, owners_of, read, review_by_default_problem,
                       review_due, send_back, split_frontmatter, tracked_md)
from km.edit import edit_sending_back, load_doc
from km.paths import write_text

TODAY = datetime.date.today()


def send_back_docs(docs: list[str]) -> int:
    """Send the named accepted docs back to review; a doc that is not accepted is refused. A doc
    left with a key to drop by hand fails the run, as with --apply."""
    def change(fm: dict, raw: str, _body: str):
        if fm.get("status") != SERVED_STATUS:
            return f"not {SERVED_STATUS} (status: {fm.get('status')!r}), nothing to send back"
        return send_back(fm, raw, "sent back")
    return edit_sending_back(docs, change, "demote")


def main() -> int:
    ap = argparse.ArgumentParser(prog="km demote", allow_abbrev=False)
    ap.add_argument("docs", nargs="*", help="accepted docs to send back to review now")
    ap.add_argument("--apply", action="store_true", help="demote the docs past review_by (without docs: dry-run)")
    a = ap.parse_args()
    if a.docs:
        if a.apply:
            ap.error("--apply goes without docs; named docs are always sent back")
        return send_back_docs(a.docs)
    if why := review_by_default_problem():   # a bad table would read as "nothing expires"
        ap.error(f"schema.local.yaml: {why}")
    apply = a.apply
    stale: list[str] = []
    stuck: list[str] = []
    partial = 0   # demoted, but an approval key is left for a person to drop
    for rel in tracked_md():
        if not is_article(rel):
            continue
        fm = split_frontmatter(read(rel))[0]
        if not fm or fm.get("status") != SERVED_STATUS:
            continue
        rb = review_due(fm)   # none for a type that does not expire
        if rb is None or rb >= TODAY:
            continue
        if isinstance(d := load_doc(rel, ROOT / rel), str):   # strict: written back, bytes must survive
            stuck.append(d)
            continue
        named = f"{rel} (owner: {', '.join(owners_of(fm)) or 'none'})"   # who re-reviews it
        if not apply:
            stale.append(named)
            continue
        # Edit the frontmatter block IN PLACE (only the status line, drop approval lines) so the
        # bot's diff stays reviewable as "just the demotion": no YAML round-trip, no reformat.
        new_fm = demote_raw(d.raw)
        if new_fm is None:
            stuck.append(f"{rel}: status line cannot be rewritten (or the block would no longer parse)")      # never report it as demoted
            continue
        left = approval_left(new_fm)
        stale.append(f"{named}: drop its {', '.join(left)} by hand" if left else named)
        partial += bool(left)
        write_text(ROOT / rel, new_fm + d.body)

    if stale:
        print(f"km demote: {'demoted' if apply else 'would demote'} {len(stale)} doc(s) past review_by:")
        for s in stale:
            print(f"  - {s}")
    if stuck:
        print("km demote: past review_by, but the doc cannot be rewritten; fix by hand:")
        for s in stuck:
            print(f"  - {s}")
    if partial:
        print(f"km demote: {partial} demoted doc(s) still carry an approval key km cannot find (quoted?); "
              f"drop it by hand")
    if not (stale or stuck):
        print("km demote: none overdue")
    return 1 if stuck or partial or (stale and not apply) else 0


if __name__ == "__main__":
    sys.exit(main())
