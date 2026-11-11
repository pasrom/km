"""Sign review docs off: `status: accepted` plus `approved_by`, `approved_at` and `approved_digest`,
the digest of the content approved (see km.common.DIGEST_FIELDS).

Who may sign off is the doc's `approval` level (see km.common.approval_problem); a doc in
`status: review` can be approved, and an accepted one approved again, after a change to its content
(which `km validate` reports as a stale approval) or where it has no `approved_digest`. The approval
written is always that of `--by`: an `approved_by` already in the doc without a digest is replaced,
never kept, since nothing shows who typed it or which text it saw (km 1.12.0 and earlier kept it;
`km upgrade` alone records a digest for an approval from before km recorded them). Each doc is
edited in place (those lines, no YAML round-trip, like `km demote`) and then gated by `km validate`;
a doc that fails is restored unchanged.

A doc whose `review_by` has already passed is refused unless `--review-by` sets a new date (a type without
expiry ignores its `review_by` and refuses `--review-by`), or
the next `km demote` would take the approval straight back. A doc without one gets the default for its
type (`review_by_default` in the schema), counted from the approval date; a type without expiry gets none,
and a `review_by` it already carries is left in place and ignored.

Run:  km approve [--root DIR] <doc.md>... --by WHO [--at YYYY-MM-DD] [--review-by YYYY-MM-DD]
"""
from __future__ import annotations

import argparse
import datetime
import sys

from km.common import (SERVED_STATUS, approval_problem, approved_digest, as_date, default_review_by,
                       review_by_days, review_by_default_problem, review_due, set_digest, set_fm_line)
from km.edit import edit_docs


def approve(docs: list[str], by: str, at: datetime.date, review_by: datetime.date | None) -> list[str]:
    """Sign the docs off together. Returns why each refused doc was refused."""
    def change(fm: dict, raw: str, body: str):
        if fm.get("status") not in ("review", SERVED_STATUS):
            return f"only a review or {SERVED_STATUS} doc can be approved (status: {fm.get('status')!r})"
        if fm.get("status") == SERVED_STATUS and str(fm.get("approved_digest")) == approved_digest(fm, body):
            return "already approved for this content; approve it again after a change to its content"
        if why := approval_problem(fm, by):
            return why
        new_by, note, doctype = review_by, "", fm.get("type")
        if review_by and not review_by_days(doctype):
            return (f"a {doctype} does not expire, --review-by would be ignored; "
                    f"give the type days in review_by_default (schema.local.yaml) to make it expire")
        if review_by is None:
            if fm.get("review_by"):   # kept; on a type without expiry it is left alone and never counts
                if as_date(fm.get("review_by")) is None:
                    return f"review_by {fm.get('review_by')!r} is not a YYYY-MM-DD date; pass --review-by"
                if (due := review_due(fm)) and due < max(at, datetime.date.today()):   # km demote compares with today
                    return f"review_by {due} has passed; pass --review-by with a new date"
            elif new_by := default_review_by(doctype, at):
                if new_by < datetime.date.today():
                    return f"the default review_by {new_by} for a {doctype} approved on {at} has passed; pass --review-by"
                note = f"; set review_by {new_by}, the default for a {doctype}"
        lines = [("status", SERVED_STATUS), ("approved_by", f'"{by}"'), ("approved_at", at.isoformat())]
        if new_by:
            lines.append(("review_by", new_by.isoformat()))
        for key, value in lines:
            raw = set_fm_line(raw, key, value)
        if fm.get("status") == SERVED_STATUS and fm.get("approved_by") and "approved_digest" not in fm:
            note += f"; it replaces approved_by {fm['approved_by']}, which recorded no approved_digest"
        if fm.get("status") == SERVED_STATUS and "approved_digest" in fm and fm.get("reviewed_by"):   # a stale one
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
