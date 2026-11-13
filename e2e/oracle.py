"""The queue oracle: what `/km queue` must list for a brain, computed without a model from GitHub state
and km's own answers, following skills/km/reference/queue.md.

`classify_prs` and `classify_docs` are pure (tested in tests/e2e_smoke.sh); `fetch` reads the inputs:
the open pull requests, `km ready` and `gh pr checks` for the `km:ready` ones, and `km list --json` on a
checkout of the default branch. What cannot be checked raises NotChecked: it never becomes a verdict.
"""
from __future__ import annotations

import datetime
import json
import re
from pathlib import Path

from lib import waiting

STALE_DAYS = 14
LAST_REVIEWED = re.compile(r"(?m)^[ \t]*Last reviewed:(.*)$")
SHA = re.compile(r"`?([0-9a-f]{40})`?")
CI = "ci"                           # the workflow whose check a merge needs


class NotChecked(Exception):
    """An input of the oracle could not be read: the oracle gives no verdict."""


def last_reviewed(body: str | None) -> str | None:
    """What the last `Last reviewed:` line of a PR body names: a full commit sha (lower case), "" when that
    line is malformed (it still is the last line, so the PR is not ready), None without such a line."""
    found = LAST_REVIEWED.findall(body or "")
    if not found:
        return None
    m = SHA.fullmatch(found[-1].strip().lower())
    return m.group(1) if m else ""


def pr_group(pr: dict, now: datetime.datetime) -> str:
    """The first group that fits (queue.md step 2): drafts; bots; stale unless km:ready; km:blocked;
    km:needs-human; km:ready; another km: label; no km: label. Only real labels count."""
    labels = set(pr["labels"])
    updated = datetime.datetime.fromisoformat(pr["updated_at"].replace("Z", "+00:00"))
    if pr["draft"]:
        return "drafts"
    if pr["is_bot"]:
        return "bots"
    if now - updated > datetime.timedelta(days=STALE_DAYS) and "km:ready" not in labels:
        return "stale"
    for lb in ("km:blocked", "km:needs-human", "km:ready"):
        if lb in labels:
            return lb
    return "other km:" if any(lb.startswith("km:") for lb in labels) else "no label"


def candidate_reasons(pr: dict, default: str, body: str, ready: tuple[int, str], checks: list[dict],
                      ci_waiting: bool = False) -> list[str]:
    """Why a km:ready PR is not a merge candidate (empty: it is one), per queue.md: base, the last `Last
    reviewed:` line equal to the full head sha, the label counts (READY: `km ready`'s exit 0 or 1 and its
    line), checks pass (CHECKS: `gh pr checks --json name,workflow,bucket`). One condition more than
    queue.md: a passing check of the ci workflow must be there, since `gh pr checks` lists no check for a
    ci run that waits for approval and then passes (observed). CI_WAITING (a ci run of the head waits for
    approval) only names the cause."""
    if ready[0] not in (0, 1):
        raise NotChecked(f"km ready exited {ready[0]}: {ready[1]}")
    why = []
    if pr["base"] != default:
        why.append(f"base is {pr['base']}, not {default} (stacked)")
    lr = last_reviewed(body)
    if lr is None:
        why.append("no `Last reviewed:` line in the body")
    elif lr == "":
        why.append("the last `Last reviewed:` line names no full commit sha")
    elif lr != pr["head"].lower():
        why.append(f"Last reviewed {lr[:7]} is not the head {pr['head'][:7]}")
    if ready[0] == 1:
        why.append(f"label does not count: {ready[1]}")
    buckets = {c["bucket"] for c in checks}
    if "pending" in buckets:
        why.append("checks pending")
    if buckets & {"fail", "cancel"}:
        why.append("a check fails")
    if not any(c["workflow"] == CI and c["bucket"] == "pass" for c in checks):
        why.append("no passing ci check" + (" (its run waits for a person's approval)" if ci_waiting else ""))
    return why


def classify_prs(prs: list[dict], default: str, now: datetime.datetime, details: dict[int, dict]) -> dict[int, dict]:
    """Per PR number: its group and, for km:ready, whether it is a merge candidate with the reasons.
    DETAILS[number] holds ready, checks and ci_waiting for the km:ready PRs (see fetch)."""
    out = {}
    for pr in prs:
        g = pr_group(pr, now)
        row: dict = {"group": g, "stacked": pr["base"] != default}
        if g == "km:ready":
            if pr["number"] not in details:
                raise NotChecked(f"#{pr['number']}: no km ready or checks read")
            d = details[pr["number"]]
            row["reasons"] = candidate_reasons(pr, default, pr["body"], d["ready"], d["checks"], d.get("ci_waiting", False))
            row["candidate"] = not row["reasons"]
        out[pr["number"]] = row
    return out


def classify_docs(listed: list[dict], overdue: list[str]) -> dict[str, dict[str, list[str]]]:
    """Docs groups of queue.md step 1, each by owner (a list owner: under each; `no owner` last):
    overdue (the paths `km list --due today` gave), needs a person (review, signoff human), an AI
    review may sign off (review, signoff ai)."""
    groups: dict[str, list[dict]] = {"overdue": [], "needs a person": [], "an AI review may sign off": []}
    due = set(overdue)
    for d in listed:
        if d["path"] in due:
            groups["overdue"].append(d)
        elif d.get("status") == "review":
            if d.get("signoff") not in ("ai", "human"):
                raise NotChecked(f"{d['path']}: signoff {d.get('signoff')!r} is neither ai nor human")
            groups["needs a person" if d["signoff"] == "human" else "an AI review may sign off"].append(d)
    out = {}
    for g, docs in groups.items():
        by: dict[str, list[str]] = {}
        for d in docs:
            raw = d.get("owner")          # as km's owners_of: a list gives one owner per item, a text one owner
            owners = [str(o).strip() for o in (raw if isinstance(raw, list) else [raw]) if o and str(o).strip()] \
                or ["no owner"]
            for o in owners:
                by.setdefault(o, []).append(d["path"])
        out[g] = {o: sorted(by[o]) for o in sorted(by, key=lambda o: (o == "no owner", o))}
    return out


def norm_pr(p: dict) -> dict:
    """A REST pulls item as the fields classify_prs reads."""
    return {"number": p["number"],
            "is_bot": p["user"].get("type") == "Bot" or p["user"]["login"].endswith("[bot]"),
            "labels": [lb["name"] for lb in p["labels"]], "updated_at": p["updated_at"], "draft": bool(p.get("draft")),
            "base": p["base"]["ref"], "head": p["head"]["sha"], "body": p.get("body") or ""}


def fetch(ctx, checkout: Path, only: set[int] | None = None) -> dict:
    """The oracle for the sandbox brain now: {"prs": classify_prs(...), "docs": classify_docs(...)}, for the
    open PRs numbered ONLY (all open PRs without it). CHECKOUT is a clone of the default branch (km list
    and km ready run there)."""
    slug = ctx.cfg.slug
    default = ctx.api("M", f"repos/{slug}")["default_branch"]
    prs, page = [], 1
    while True:
        got = ctx.api("M", f"repos/{slug}/pulls?state=open&per_page=100&page={page}")
        prs += [norm_pr(p) for p in got if only is None or p["number"] in only]
        if len(got) < 100:
            break
        page += 1
    now = datetime.datetime.now(datetime.timezone.utc)
    details = {}
    for pr in prs:
        if pr_group(pr, now) != "km:ready":
            continue
        rc, out = ctx.km_ready(pr["number"], pr["head"], checkout)
        details[pr["number"]] = {"ready": (rc, out.splitlines()[-1] if out else ""),
                                 "checks": pr_checks(ctx, pr["number"]),
                                 "ci_waiting": any(waiting(r) for r in ctx.runs(pr["head"], CI))}
    listed = km_list(ctx, checkout, "--status", "review", "--status", "accepted",
                     "--fields", "path,status,signoff,review_by,owner")
    overdue = [d["path"] for d in km_list(ctx, checkout, "--status", "accepted", "--due", "today", "--fields", "path")]
    return {"prs": classify_prs(prs, default, now, details), "docs": classify_docs(listed, overdue), "details": details}


def pr_checks(ctx, n: int) -> list[dict]:
    """`gh pr checks` of PR N as rows {name, workflow, bucket}; as C, since a fine-grained token without the
    checks permission cannot read the status rollup. "no checks reported" is no rows; anything else that
    is no JSON list raises NotChecked."""
    r = ctx.gh("C", "pr", "checks", str(n), "-R", ctx.cfg.slug, "--json", "name,workflow,bucket")
    try:
        rows = json.loads(r.stdout)
        if isinstance(rows, list):
            return rows
    except ValueError:
        pass
    if "no checks reported" in r.stderr:
        return []
    raise NotChecked(f"gh pr checks #{n} exited {r.returncode}: {(r.stdout + r.stderr).strip()[:200]}")


def km_list(ctx, checkout: Path, *args: str) -> list[dict]:
    """`km list ... --json`: exit 0 with rows, or exit 1 with none; anything else raises NotChecked."""
    r = ctx.km(checkout, "list", *args, "--json")
    try:
        rows = json.loads(r.stdout) if r.stdout.strip() else None
    except ValueError:
        rows = None
    if r.returncode == 0 and isinstance(rows, list) or r.returncode == 1 and rows in ([], None):
        return rows or []
    raise NotChecked(f"km list {' '.join(args)} exited {r.returncode}: {(r.stdout + r.stderr).strip()[:200]}")
