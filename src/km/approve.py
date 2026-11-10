"""Sign review docs off: `status: accepted` plus `approved_by`, `approved_at` and `approved_digest`,
the digest of the content approved (see km.common.DIGEST_FIELDS).

Who may sign off is the doc's `approval` level (see km.common.approval_problem); a doc in
`status: review` can be approved, and an accepted one approved again, after a change to its content
(which `km validate` reports as a stale approval). Each doc is edited in place (those lines, no YAML
round-trip, like `km demote`) and then gated by `km validate`; a doc that fails is restored unchanged.

A doc whose `review_by` has already passed is refused unless `--review-by` sets a new date, or
the next `km demote` would take the approval straight back. A doc without one gets the default for its
type (`review_by_default` in the schema), counted from the approval date; a type without expiry gets none.

Run:  km approve [--root DIR] <doc.md>... --by WHO [--at YYYY-MM-DD] [--review-by YYYY-MM-DD]
"""
from __future__ import annotations

import argparse
import datetime
import sys

from km.common import (SERVED_STATUS, approval_problem, approved_digest, as_date, default_review_by,
                       review_by_days, review_by_default_problem, set_digest, set_fm_line)
from km.edit import edit_docs


def approve(docs: list[str], by: str, at: datetime.date, review_by: datetime.date | None) -> list[str]:
    """Sign the docs off together. Returns why each refused doc was refused."""
    def change(fm: dict, raw: str, body: str):
        if fm.get("status") not in ("review", SERVED_STATUS):
            return f"only a review or {SERVED_STATUS} doc can be approved (status: {fm.get('status')!r})"
        if fm.get("status") == SERVED_STATUS:
            if "approved_digest" not in fm:   # signed off before km recorded the content: keep that sign-off
                return set_digest(raw, fm, body), (
                    f"recorded the content approved_by {fm.get('approved_by')} signed off on {fm.get('approved_at')}, "
                    f"kept as the approval; if it changed since, `km demote` it and approve it after review")
            if str(fm["approved_digest"]) == approved_digest(fm, body):
                return "already approved for this content; approve it again after a change to its content"
        if why := approval_problem(fm, by):
            return why
        new_by, note, doctype = review_by, "", fm.get("type")
        if review_by is None:
            if fm.get("review_by"):   # kept, also on a type without expiry: remove it by hand to stop that
                due = as_date(fm.get("review_by"))
                if due is None:
                    return f"review_by {fm.get('review_by')!r} is not a YYYY-MM-DD date; pass --review-by"
                if due < max(at, datetime.date.today()):   # km demote compares with today
                    hint = "" if review_by_days(doctype) else f", or remove it: a {doctype} does not expire"
                    return f"review_by {due} has passed; pass --review-by with a new date{hint}"
            elif new_by := default_review_by(doctype, at):
                if new_by < datetime.date.today():
                    return f"the default review_by {new_by} for a {doctype} approved on {at} has passed; pass --review-by"
                note = f"; set review_by {new_by}, the default for a {doctype}"
        lines = [("status", SERVED_STATUS), ("approved_by", f'"{by}"'), ("approved_at", at.isoformat())]
        if new_by:
            lines.append(("review_by", new_by.isoformat()))
        for key, value in lines:
            raw = set_fm_line(raw, key, value)
        if fm.get("status") == SERVED_STATUS and fm.get("reviewed_by"):
            note += "; its reviewed_by entries are from before the change, drop those that did not see this text"
        return set_digest(raw, fm, body), f"accepted, approved_by {by} on {at.isoformat()}" + note
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
    if why := review_by_default_problem():
        ap.error(f"schema.local.yaml: {why}")
    if a.review_by and a.review_by < max(a.at, datetime.date.today()):
        ap.error(f"--review-by {a.review_by} is in the past; the next km demote would undo the approval")
    refused = approve(a.docs, a.by, a.at, a.review_by)
    for why in refused:
        print(f"approve: REFUSED {why}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
