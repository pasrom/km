"""Demote stale served docs: an accepted (served) doc whose `review_by` has lapsed drops back to
`status: review` (its approval invalidated), so it leaves the served set automatically instead of
being served forever. This is the staleness mechanism the model needs; run it on a schedule in CI.

Dry-run by default (lists what would change, exit 1 if any); `--apply` rewrites the files.

Run:  km demote [--root DIR] [--apply]
"""
from __future__ import annotations

import datetime
import re
import sys

from km.common import ROOT, SERVED_STATUS, is_article, read, split_frontmatter, tracked_md

TODAY = datetime.date.today()


def as_date(v):
    try:
        return datetime.date.fromisoformat(str(v)[:10])
    except (ValueError, TypeError):
        return None


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    stale: list[str] = []
    stuck: list[str] = []
    for rel in tracked_md():
        if not is_article(rel):
            continue
        fm, raw, body = split_frontmatter(read(rel))
        if not fm or fm.get("status") != SERVED_STATUS:
            continue
        rb = as_date(fm.get("review_by"))
        if rb is None or rb >= TODAY:
            continue
        if not apply:
            stale.append(rel)
            continue
        # Edit the frontmatter block IN PLACE (only the status line, drop approval lines) so the
        # bot's diff stays reviewable as "just the demotion": no YAML round-trip, no reformat.
        new_fm, n = re.subn(rf"(?m)^status:[ \t]*['\"]?{re.escape(SERVED_STATUS)}['\"]?[ \t]*(#.*)?$",
                            "status: review", raw)
        if n != 1:
            stuck.append(rel)      # a status line this edit cannot rewrite: never report it as demoted
            continue
        stale.append(rel)
        new_fm = re.sub(r"(?m)^approved_(?:by|at):.*\n", "", new_fm)
        (ROOT / rel).write_text(new_fm + body, encoding="utf-8")

    if stale:
        print(f"km demote: {'demoted' if apply else 'would demote'} {len(stale)} doc(s) past review_by:")
        for s in stale:
            print(f"  - {s}")
    if stuck:
        print("km demote: past review_by, but the status line could not be rewritten; fix by hand:")
        for s in stuck:
            print(f"  - {s}")
    if not (stale or stuck):
        print("km demote: none overdue")
    return 1 if stuck or (stale and not apply) else 0


if __name__ == "__main__":
    sys.exit(main())
