"""Sign review docs off: `status: accepted` plus `approved_by` and `approved_at`.

Who may sign off is the doc's `approval` level (see km.common.approval_problem); only a doc in
`status: review` can be approved. Each doc is edited in place (those three lines, no YAML round-trip,
like `km demote`) and then gated by `km validate`; a doc that fails is restored unchanged.

A doc whose `review_by` has already passed is refused unless `--review-by` sets a new date, or
the next `km demote` would take the approval straight back.

Run:  km approve [--root DIR] <doc.md>... --by WHO [--at YYYY-MM-DD] [--review-by YYYY-MM-DD]
"""
from __future__ import annotations

import argparse
import datetime
import sys

from km.common import SERVED_STATUS, approval_problem, set_fm_line
from km.edit import edit_docs


def approve(docs: list[str], by: str, at: datetime.date, review_by: datetime.date | None) -> list[str]:
    """Sign the docs off together. Returns why each refused doc was refused."""
    def change(fm: dict, raw: str):
        if fm.get("status") != "review":
            return f"only a review doc can be approved (status: {fm.get('status')!r})"
        if why := approval_problem(fm, by):
            return why
        if review_by is None:
            try:
                due = datetime.date.fromisoformat(str(fm.get("review_by"))[:10]) if fm.get("review_by") else None
            except ValueError:
                return f"review_by {fm.get('review_by')!r} is not a YYYY-MM-DD date; pass --review-by"
            if due and due < max(at, datetime.date.today()):   # km demote compares with today
                return f"review_by {due} has passed; pass --review-by with a new date"
        lines = [("status", SERVED_STATUS), ("approved_by", f'"{by}"'), ("approved_at", at.isoformat())]
        if review_by:
            lines.append(("review_by", review_by.isoformat()))
        for key, value in lines:
            raw = set_fm_line(raw, key, value)
        return raw, f"accepted, approved_by {by} on {at.isoformat()}"
    return edit_docs(docs, change, "approve")


def main() -> int:
    ap = argparse.ArgumentParser(prog="km approve")
    ap.add_argument("docs", nargs="+")
    ap.add_argument("--by", required=True, help="approver: initials, or ai:<model> where the doc is at level ai")
    ap.add_argument("--at", type=datetime.date.fromisoformat, default=datetime.date.today(),
                    help="approval date, YYYY-MM-DD")
    ap.add_argument("--review-by", type=datetime.date.fromisoformat, help="set a new review_by date")
    a = ap.parse_args()
    if not a.by.strip():
        ap.error("--by must name the approver")
    if a.review_by and a.review_by < max(a.at, datetime.date.today()):
        ap.error(f"--review-by {a.review_by} is in the past; the next km demote would undo the approval")
    refused = approve(a.docs, a.by, a.at, a.review_by)
    for why in refused:
        print(f"approve: REFUSED {why}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
