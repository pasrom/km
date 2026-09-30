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
from pathlib import Path

from km.common import ROOT, SERVED_STATUS, approval_problem, set_fm_line, split_frontmatter
from km.paths import write_text
from km.promote import run_gate


def approve_one(doc: str, by: str, at: datetime.date, review_by: datetime.date | None) -> str | None:
    """Sign one doc off. Returns why it was refused, or None."""
    path = Path(doc).resolve()
    try:
        rel = path.relative_to(ROOT).as_posix()
    except ValueError:
        return f"{doc}: outside the brain"
    if not path.is_file():
        return f"{rel}: no such file"
    old = path.read_bytes()   # restored byte for byte if the gate fails (a BOM included)
    text = old.decode("utf-8-sig").replace("\r\n", "\n")   # strict decode (written back); CRLF like read()
    fm, raw, body = split_frontmatter(text)
    if fm is None:
        return f"{rel}: no frontmatter"
    if fm.get("status") != "review":
        return f"{rel}: only a review doc can be approved (status: {fm.get('status')!r})"
    why = approval_problem(fm, by)
    if why:
        return f"{rel}: {why}"
    if review_by is None:
        try:
            due = datetime.date.fromisoformat(str(fm.get("review_by"))[:10]) if fm.get("review_by") else None
        except ValueError:
            return f"{rel}: review_by {fm.get('review_by')!r} is not a YYYY-MM-DD date; pass --review-by"
        if due and due < max(at, datetime.date.today()):   # km demote compares with today
            return f"{rel}: review_by {due} has passed; pass --review-by with a new date"
    lines = [("status", SERVED_STATUS), ("approved_by", f'"{by}"'), ("approved_at", at.isoformat())]
    if review_by:
        lines.append(("review_by", review_by.isoformat()))
    for key, value in lines:
        raw = set_fm_line(raw, key, value)
    write_text(path, raw + body)
    gate = run_gate(path)
    if gate.returncode != 0:
        path.write_bytes(old)
        return f"{rel}: km validate fails after the change, left unchanged:\n{gate.stdout.rstrip()}"
    print(f"approve: {rel} accepted, approved_by {by} on {at.isoformat()}")
    return None


def main() -> int:
    ap = argparse.ArgumentParser(prog="km approve")
    ap.add_argument("docs", nargs="+")
    ap.add_argument("--by", required=True, help="approver: initials, or ai:<model> where the doc says approval: ai")
    ap.add_argument("--at", type=datetime.date.fromisoformat, default=datetime.date.today(),
                    help="approval date, YYYY-MM-DD")
    ap.add_argument("--review-by", type=datetime.date.fromisoformat, help="set a new review_by date")
    a = ap.parse_args()
    if not a.by.strip():
        ap.error("--by must name the approver")
    if a.review_by and a.review_by < max(a.at, datetime.date.today()):
        ap.error(f"--review-by {a.review_by} is in the past; the next km demote would undo the approval")
    refused = [why for doc in a.docs if (why := approve_one(doc, a.by, a.at, a.review_by))]
    for why in refused:
        print(f"approve: REFUSED {why}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
