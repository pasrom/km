"""Whether the automerge workflow may merge a pull request by itself: `km automerge OWNER/NAME NUMBER`.

A team brain's contributors have no write access; the maintainer merges. A pull request that needs no
person's judgement can land without one: the team workflow automerge (opt-in, the repository variable
KM_AUTOMERGE=1) asks this command and merges, by rebase and only at the head it judged, when every
condition holds:

- it is open, not a draft, and its base is the default branch, never changed since it was opened (a
  green ci may have run against another base);
- it is labelled `km:ready`, and the label counts on the levels path of `km ready` whoever set it: no
  control file changed and every changed doc at level `ai` at its head and base (km.ready, AI_ONLY), the
  base levels and schema.local.yaml read at the default branch's tip; and, narrower than the queue,
  every other changed file a media file (ready.MEDIA: images including SVG, PDF, CSV, TSV; an SVG is never rendered by CI or the bot): a script beside a page,
  a hook or a Makefile is for a person to merge. A label that counts only because another person set
  it, on a doc at level human or a control file, stays the maintainer's merge;
- the last `Last reviewed: <sha>` line of its body names the full head commit;
- the base's ci.yml runs the sign-off check (`km validate --signoff-since`), and on exactly the head
  commit (its check runs and commit statuses, not the pull request's checks, which follow a push) every
  check run of km's ci workflow passed, its sign-off job `validate` among them, and every other check
  passed or was skipped (a fork's ci run that waits for a person's approval is no check: the queue's
  rule, skills/km/reference/queue.md). Checks still pending other than ci are waited for (--wait); a
  pending ci is not, since its completion runs the workflow again. Of a check name, only its newest run
  in a check suite counts. The ci run is the pull request's own, not a dispatched one. The workflow's
  own runs (--self) are left out. The head carries the tip's ci.yml (the same blob), so its run used
  the ci.yml the tip has;
- no reviewer's latest review requests changes;
- nothing of the above moved while it was read (the pull request, its reviews and the default branch
  read again at the end; with --tip, the default branch is still at the commit the workflow read
  ci.yml at, the pin of the km it runs).

Fails closed: anything it cannot read or decide is a reason not to merge. Prints `merge` or `no merge`
with one line per failed condition; never a frontmatter value or a body line, only names through
paths.printable. Exit 0 to merge, 1 not, 2 on a usage error. --github-output FILE also appends the
workflow's step outputs (merge, labelled, head, tip and the pull request comment, base64).
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import urllib.parse

from km.paths import printable
from km.ready import LABEL, SHA, lines, raw, verdict

MARKER = "<!-- km:automerge -->"   # the workflow's own comment starts with it
CI_PATH = ".github/workflows/ci.yml"   # km's ci workflow, whose passing check a merge needs
CI_JOB = "validate"                    # its job that runs the sign-off check
LAST_REVIEWED = re.compile(r"(?m)^[ \t]*Last reviewed:(.*)$")
REVIEWED_SHA = re.compile(r"`?([0-9a-f]{40})`?")
SIGNOFF = re.compile(r"(?m)^[^#\n]*\bkm validate\b[^#\n]*--signoff-since")   # not in a comment
# timeline events of a base change (approve-fork-ci's jq lists the same)
BASE_CHANGES = '"base_ref_changed", "automatic_base_change_succeeded", "automatic_base_change_failed"'
EVERY = 15                         # seconds between two reads of pending checks


def one(*args: str) -> object | None:
    got = lines(*args)
    return got[0] if got and len(got) == 1 else None


def pull(repo: str, number: str) -> dict | None:
    pr = one("api", f"repos/{repo}/pulls/{number}", "--jq",
             "{state, merged, draft, base: .base.ref, head: .head.sha, labels: [.labels[].name], body} | tojson")
    return pr if isinstance(pr, dict) else None


def tip(repo: str, branch: str) -> str | None:
    sha = one("api", f"repos/{repo}/git/ref/heads/{urllib.parse.quote(branch)}", "--jq", ".object.sha | tojson")
    return sha if isinstance(sha, str) and SHA.fullmatch(sha) else None


def last_reviewed(body: str | None) -> str | None:
    """The full sha the last `Last reviewed:` line names; "" when that line names none, None without one."""
    found = LAST_REVIEWED.findall(body or "")
    if not found:
        return None
    m = REVIEWED_SHA.fullmatch(found[-1].strip().lower())
    return m.group(1) if m else ""


def requested_changes(repo: str, number: str) -> list[str] | None:
    """The reviewers whose latest approving, change-requesting or dismissed review requests changes (the
    workflow's act job repeats this rule in jq: keep the two in step)."""
    got = lines("api", "--paginate", f"repos/{repo}/pulls/{number}/reviews?per_page=100", "--jq",
                '.[] | {login: .user.login, state} | tojson')
    if got is None:
        return None
    last: dict[str, str] = {}
    for r in got:
        if isinstance(r, dict) and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            last[str(r.get("login"))] = r["state"]
    return sorted(who for who, st in last.items() if st == "CHANGES_REQUESTED")


def base_changed(repo: str, number: str) -> bool | None:
    got = lines("api", "--paginate", f"repos/{repo}/issues/{number}/timeline?per_page=100", "--jq",
                f".[] | select(.event | IN({BASE_CHANGES})) | .event | tojson")
    return None if got is None else bool(got)


def bucket(status: object, conclusion: object) -> str:
    """A check run's or a commit status's outcome: pass, skipping, pending or fail (anything else)."""
    if status in ("queued", "in_progress", "waiting", "requested", "pending", "expected") or conclusion is None:
        return "pending"
    return {"success": "pass", "skipped": "skipping", "neutral": "skipping"}.get(str(conclusion), "fail")


def checks(repo: str, sha: str, own: str) -> list[dict] | None:
    """The checks of exactly commit SHA, not of whatever the pull request's head is by then: its check
    runs with the workflow run each belongs to, only the newest of each name in a check suite (a
    re-run's pass replaces the failure before it in its own run; another run on the same commit, of
    another pull request, stays a row of its own), and its commit statuses, as {workflow, path, event,
    name, bucket}; the check runs of workflow OWN left out. None when a read fails."""
    runs = lines("api", "--paginate", f"repos/{repo}/commits/{sha}/check-runs?per_page=100", "--jq",
                 ".check_runs[] | {id, name, status, conclusion, suite: .check_suite.id, app: .app.slug} | tojson")
    flows = lines("api", "--paginate", f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100", "--jq",
                  ".workflow_runs[] | {suite: .check_suite_id, name, path, event} | tojson")
    status = lines("api", "--paginate", f"repos/{repo}/commits/{sha}/status?per_page=100", "--jq",
                   ".statuses[] | {context, state} | tojson")
    if runs is None or flows is None or status is None:
        return None
    suites = {f.get("suite"): f for f in flows if isinstance(f, dict)}
    newest: dict[tuple, tuple[int, dict]] = {}
    for r in runs:
        if not isinstance(r, dict) or not isinstance(r.get("id"), int):
            return None
        flow = (suites.get(r.get("suite")) or {}) if r.get("app") == "github-actions" else {"name": r.get("app")}
        row = {"workflow": flow.get("name") or "(an unlisted workflow run)", "path": flow.get("path"), "event": flow.get("event"),
               "name": r.get("name"),
               # an unlisted run (the listing lags) is waited for like a pending one
               "bucket": bucket(r.get("status"), r.get("conclusion")) if flow else "pending"}
        key = (r.get("app"), r.get("suite"), row["name"])
        if key not in newest or r["id"] > newest[key][0]:
            newest[key] = (r["id"], row)
    rows = [row for _, row in newest.values()]
    for st in status:
        if not isinstance(st, dict):
            return None
        state = st.get("state")
        rows.append({"workflow": "status", "path": None, "event": None, "name": st.get("context"),
                     "bucket": "pass" if state == "success" else "pending" if state == "pending" else "fail"})
    return [r for r in rows if not (r["path"] and r["workflow"] == own)]


def check_reasons(rows: list[dict]) -> list[str]:
    """The queue's rule, strictly: every check run of km's ci workflow passed and among them its sign-off
    job (`validate`); every other check passed or was skipped."""
    why = []
    ci = [r for r in rows if r["path"] == CI_PATH]
    if any(r["bucket"] == "pending" for r in ci):
        why.append("ci has not finished on the head (a pull request's ci run runs this check again when it completes)")
    elif not any(r["name"] == CI_JOB and r["bucket"] == "pass" for r in ci):
        why.append("no passing ci check on the head (a fork's ci run may wait for a person's approval)")
    elif bad := [r for r in ci if r["bucket"] != "pass"]:
        why += [f"the ci check {printable(str(r['name']))} is {r['bucket']}, not pass" for r in bad]
    for r in rows:
        if r["path"] != CI_PATH and r["bucket"] not in ("pass", "skipping"):
            name = printable(f"{r['workflow']}/{r['name'] or ''}")
            why.append(f"the check {name} is {r['bucket']}, not pass or skipping")
    return why


def settled_checks(repo: str, sha: str, own: str, wait: float) -> list[dict] | None:
    """The checks once none but ci's is pending, or after WAIT seconds; a pending ci is not waited for."""
    end = time.monotonic() + wait
    while True:
        rows = checks(repo, sha, own)
        pending = [r for r in rows or [] if r["bucket"] == "pending"]
        if not pending or any(r["path"] == CI_PATH for r in pending) or time.monotonic() + EVERY > end:
            return rows
        time.sleep(EVERY)


def decide(repo: str, number: str, own: str, wait: float, expect_tip: str | None = None) -> dict:
    """{merge, labelled, head, tip, reasons}: whether to merge, and every condition that does not hold.
    EXPECT_TIP: the default branch's commit the caller read its ci.yml at (the km it installed)."""
    out: dict = {"merge": False, "labelled": False, "head": "", "tip": "", "reasons": []}
    why = out["reasons"]
    default = one("api", f"repos/{repo}", "--jq", ".default_branch | tojson")
    pr = pull(repo, number)
    if not isinstance(default, str) or not default or pr is None:
        why.append("the pull request or the repository could not be read")
        return out
    if pr.get("state") != "open" or pr.get("merged"):
        why.append("it is not open")
        return out
    head = pr.get("head")
    if not (isinstance(head, str) and SHA.fullmatch(head)):
        why.append("its head commit could not be read")
        return out
    out["head"] = head
    out["labelled"] = LABEL in (pr.get("labels") or [])
    if not out["labelled"]:
        why.append(f"it is not labelled {LABEL}")
        return out
    if pr.get("draft") is not False:
        why.append("it is a draft")
    if pr.get("base") != default:
        why.append(f"its base is {printable(str(pr.get('base')))}, not the default branch {printable(default)}")
    t = tip(repo, default)
    out["tip"] = t or ""
    if expect_tip and t != expect_tip:
        why.append("the default branch moved after the workflow read its ci.yml")
    ci_yml = raw(repo, f"contents/.github/workflows/ci.yml?ref={t}")[0] if t else None
    if not t:
        why.append("the default branch could not be read")
    elif ci_yml is None:
        why.append("the default branch's ci.yml could not be read")
    elif not SIGNOFF.search(ci_yml):
        why.append("the default branch's ci.yml does not run the sign-off check (km validate --signoff-since)")
    changed = base_changed(repo, number)
    if changed is None:
        why.append("its timeline could not be read")
    elif changed:
        why.append("its base was changed after it was opened (ci may have passed against another base)")
    lr = last_reviewed(pr.get("body"))
    if lr is None:
        why.append("its body has no `Last reviewed:` line")
    elif lr == "":
        why.append("the last `Last reviewed:` line of its body names no full commit sha")
    elif lr != head.lower():
        why.append(f"Last reviewed {lr[:7]} is not the head {head[:7]}")
    # the base judged at the tip the workflow runs at; a pull request against another branch at its own
    if t:                                # without a tip: its own reason above, no merge
        counts, line = verdict(repo, number, head, ai_only=True, base=t if pr.get("base") == default else None)
        if not counts:
            why.append(f"the label does not count without a person: {line}")
    asked = requested_changes(repo, number)
    if asked is None:
        why.append("its reviews could not be read")
    elif asked:
        why.append(f"changes requested by {', '.join(printable(a) for a in asked)}")
    rows = settled_checks(repo, head, own, 0 if why else wait)   # already declined: no wait
    if rows is None:
        why.append("its checks could not be read")
    else:
        why += check_reasons(rows)
    # a pull request's ci run uses the ci.yml of the base it merged with then; a dispatched one, the branch's
    ci_runs = [r for r in rows or [] if r["path"] == CI_PATH and r["name"] == CI_JOB]
    if any(r["event"] != "pull_request" for r in ci_runs):
        why.append("a ci check on the head comes from a run that is not the pull request's (a dispatched run uses the branch's ci.yml)")
    # the head carries the tip's ci.yml (the same blob): the pull request changes no control file, so its
    # merge with any base since its branch point ran that ci.yml, not one the default branch has replaced
    if t:
        blobs = [one("api", f"repos/{repo}/contents/.github/workflows/ci.yml?ref={c}", "--jq", ".sha | tojson") for c in (t, head)]
        if not all(isinstance(b, str) and SHA.fullmatch(b) for b in blobs):
            why.append("the ci.yml of the default branch or of the head could not be read")
        elif blobs[0] != blobs[1]:
            why.append("ci.yml on the default branch differs from the head's: bring the branch up to date with it, "
                       "so ci runs the ci.yml the default branch has now")
    # the checks may have been waited for: the body and the reviews too are read again
    again = pull(repo, number)
    if again is None or tip(repo, default) != t \
            or any(again.get(k) != pr.get(k) for k in ("state", "draft", "base", "head", "body")) \
            or LABEL not in (again.get("labels") or []) or requested_changes(repo, number) != asked:
        why.append("the head, the base, the body, the reviews or the label changed while it was read")
    out["merge"] = not why
    return out


def comment(result: dict) -> str:
    """The pull request comment on a merge that does not happen: each reason quoted in a code block."""
    rows = "\n".join(json.dumps(r) for r in result["reasons"])
    return (f"{MARKER}\nNot merged by the automerge workflow. It merges a `{LABEL}` pull request by itself only "
            f"when every changed doc is at level ai and no control file changed, `Last reviewed` names the head, "
            f"ci passed and nothing else stops it. These do not hold at {result['head'][:7]}:\n\n"
            f"```\n{rows}\n```\n\n"
            f"It checks again when ci completes on a new push, when `{LABEL}` is applied again, or when the pull "
            f"request is marked ready for review. One that needs a person (a doc at level human, a control file) "
            f"waits for the maintainer's merge.")


def main() -> int:
    ap = argparse.ArgumentParser(prog="km automerge", allow_abbrev=False,
                                 description="Whether the automerge workflow may merge a pull request by itself.")
    ap.add_argument("repo", metavar="OWNER/NAME")
    ap.add_argument("number", metavar="NUMBER")
    ap.add_argument("--self", dest="own", default="automerge", metavar="WORKFLOW",
                    help="the name of the workflow that asks, whose own checks are left out (default automerge)")
    ap.add_argument("--wait", type=float, default=300, metavar="SECONDS",
                    help="how long to wait for pending checks other than ci (default 300)")
    ap.add_argument("--tip", metavar="SHA", help="the default branch's commit the caller read ci.yml at; another one is a reason")
    ap.add_argument("--github-output", metavar="FILE", help="append the workflow's step outputs to FILE")
    args = ap.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or not args.number.isdigit():
        ap.error("OWNER/NAME and a pull request NUMBER")
    result = decide(args.repo, args.number, args.own, args.wait, args.tip)
    print("merge" if result["merge"] else "no merge")
    for r in result["reasons"]:
        print(f"- {r}")
    if args.github_output:
        text = "" if result["merge"] else comment(result)
        with open(args.github_output, "a", encoding="utf-8") as f:
            f.write(f"merge={'1' if result['merge'] else ''}\nlabelled={'1' if result['labelled'] else ''}\n"
                    f"head={result['head']}\ntip={result['tip']}\n"
                    f"comment={base64.b64encode(text.encode()).decode()}\n")
    return 0 if result["merge"] else 1


if __name__ == "__main__":
    sys.exit(main())
