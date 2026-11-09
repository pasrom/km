"""Demote stale served docs: an accepted (served) doc whose `review_by` has lapsed drops back to
`status: review` (its approval invalidated), so it leaves the served set automatically instead of
being served forever. This is the staleness mechanism the model needs; run it on a schedule in CI.

Dry-run by default (lists what would change, exit 1 if any); `--apply` rewrites the files.

With docs named, it sends those accepted docs back to review now, whatever their date: their
approval and pre-reviews (`reviewed_by`) dropped, as `km repin` does. That is how a change to an
accepted doc is committed: the doc goes back to review in the same commit, and its approval follows
in a commit of its own (`km validate` reports a changed doc that is still accepted as approval-stale).

Run:  km demote [--root DIR] [--apply]
      km demote [--root DIR] <doc.md>...
"""
from __future__ import annotations

import argparse
import datetime
import sys

from km.common import ROOT, SERVED_STATUS, as_date, demote_raw, is_article, read, send_back, split_frontmatter, tracked_md
from km.edit import edit_docs, load_doc
from km.paths import write_text

TODAY = datetime.date.today()


def send_back_docs(docs: list[str]) -> int:
    """Send the named accepted docs back to review; a doc that is not accepted is refused."""
    def change(fm: dict, raw: str, _body: str):
        if fm.get("status") != SERVED_STATUS:
            return f"not {SERVED_STATUS} (status: {fm.get('status')!r}), nothing to send back"
        return send_back(fm, raw, "sent back")
    refused = edit_docs(docs, change, "demote")
    for why in refused:
        print(f"demote: REFUSED {why}")
    return 1 if refused else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="km demote", allow_abbrev=False)
    ap.add_argument("docs", nargs="*", help="accepted docs to send back to review now")
    ap.add_argument("--apply", action="store_true", help="demote the docs past review_by (without docs: dry-run)")
    a = ap.parse_args()
    if a.docs:
        if a.apply:
            ap.error("--apply goes without docs; named docs are always sent back")
        return send_back_docs(a.docs)
    apply = a.apply
    stale: list[str] = []
    stuck: list[str] = []
    for rel in tracked_md():
        if not is_article(rel):
            continue
        fm = split_frontmatter(read(rel))[0]
        if not fm or fm.get("status") != SERVED_STATUS:
            continue
        rb = as_date(fm.get("review_by"))
        if rb is None or rb >= TODAY:
            continue
        if isinstance(d := load_doc(rel, ROOT / rel), str):   # strict: written back, bytes must survive
            stuck.append(d)
            continue
        if not apply:
            stale.append(rel)
            continue
        # Edit the frontmatter block IN PLACE (only the status line, drop approval lines) so the
        # bot's diff stays reviewable as "just the demotion": no YAML round-trip, no reformat.
        new_fm = demote_raw(d.raw)
        if new_fm is None:
            stuck.append(f"{rel}: status line cannot be rewritten")      # never report it as demoted
            continue
        stale.append(rel)
        write_text(ROOT / rel, new_fm + d.body)

    if stale:
        print(f"km demote: {'demoted' if apply else 'would demote'} {len(stale)} doc(s) past review_by:")
        for s in stale:
            print(f"  - {s}")
    if stuck:
        print("km demote: past review_by, but the doc cannot be rewritten; fix by hand:")
        for s in stuck:
            print(f"  - {s}")
    if not (stale or stuck):
        print("km demote: none overdue")
    return 1 if stuck or (stale and not apply) else 0


if __name__ == "__main__":
    sys.exit(main())
