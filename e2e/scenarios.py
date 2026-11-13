"""The phase 1 scenarios (concept catalogue ids). Each takes the run context and its record, makes
its own branch `e2e/<run id>/<id>` and pull request, and asserts on GitHub state read by the API.

E01 changes main and runs first, E24 changes main and runs last; the rest are independent pull
requests and may run in parallel.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

from lib import ApiError, Ctx, Fail, Record, now

MARKER = "<!-- km:review-request-guide -->"
AI = "ai:e2e-cli"


# --- helpers ------------------------------------------------------------------------------------
def write(d: Path, rel: str, text: str) -> None:
    (d / rel).parent.mkdir(parents=True, exist_ok=True)
    (d / rel).write_text(text, encoding="utf-8")


def page(title: str, status: str, body: str, *, owner: str = "AAA", audience: str = "internal",
         extra: str = "", day: str = "2026-01-01") -> str:
    aud = f"audience: {audience}\n" if audience else ""
    return (f'---\ntype: note\ntitle: "{title}"\ntimestamp: {day}\nauthor: {owner}\nowner: {owner}\n'
            f"status: {status}\n{aud}language: en\ntags: [e2e]\n{extra}---\n\n{body}\n")


def commit(ctx: Ctx, role: str, d: Path, msg: str) -> str:
    ctx.git(role, d, "add", "-A")
    ctx.git(role, d, "commit", "-q", "-m", msg)
    return ctx.head(role, d)


def km_ok(ctx: Ctx, rec: Record, d: Path, *args: str) -> str:
    r = ctx.km(d, *args)
    rec.must(f"km {' '.join(args[:2])} exits 0", r.returncode == 0, "0", f"{r.returncode}: {(r.stdout + r.stderr)[-300:]}")
    return r.stdout


def gen_index(ctx: Ctx, rec: Record, d: Path) -> None:
    ctx.git("C", d, "add", "-A")            # km sees tracked files only
    km_ok(ctx, rec, d, "gen-index")


def contrib_branch(ctx: Ctx, rec: Record, sid: str | None = None) -> tuple[Path, str]:
    """A clone of C's fork with a new branch on the sandbox's current main."""
    sid = sid or rec.id
    d = ctx.clone("C", ctx.cfg.fork, ctx.dir / sid)
    ctx.git("C", d, "fetch", "-q", ctx.url(ctx.cfg.slug), "main")
    br = ctx.branch(sid)
    ctx.git("C", d, "checkout", "-q", "-b", br, "FETCH_HEAD")
    return d, br


def push_and_open(ctx: Ctx, rec: Record, d: Path, br: str, title: str, body: str, role: str = "C",
                  draft: bool = False) -> tuple[dict, str]:
    ctx.push(role, d, ctx.cfg.fork if role == "C" else ctx.cfg.slug, f"HEAD:refs/heads/{br}")
    head = ctx.head(role, d)
    pr = ctx.open_pr(role, br, title, body, draft=draft)
    rec.links[f"PR #{pr['number']}"] = pr["html_url"]
    return pr, head


def waiting(run: dict) -> bool:
    return run["status"] == "action_required" or run.get("conclusion") == "action_required"


def ci_final(ctx: Ctx, run_id: int, timeout: float = 480) -> dict:
    """The ci run once it ran (not merely waiting for approval) and completed."""
    def look():
        r = ctx.repo_api("M", f"actions/runs/{run_id}")
        return r if r["status"] == "completed" and r.get("conclusion") not in (None, "action_required") else None
    return ctx.poll(f"run {run_id} to run and complete", look, timeout)


def fork_ci(ctx: Ctx, rec: Record, head: str, *, auto: bool) -> tuple[dict, dict, str]:
    """Wait for the fork path: ci waiting for approval, approve-fork-ci done, ci run (AUTO: by the
    workflow; else still waiting). Returns (ci run as last read, approve-fork-ci run, its log)."""
    ci = ctx.wait_run(head, "ci", "pull_request")
    rec.links["ci run"] = ci["html_url"]
    ap = ctx.wait_run(head, "approve-fork-ci", "pull_request_target")
    rec.links["approve-fork-ci run"] = ap["html_url"]
    rec.check("approve-fork-ci succeeds", ap["conclusion"] == "success", "success", ap["conclusion"])
    log = ctx.run_log(ap["id"])
    if auto:
        rec.must("approve-fork-ci approved the ci run", f"approved run {ci['id']}" in log,
                  f"log line 'approved run {ci['id']}'", grep(log, r"approved run|##\[notice\]") or "(no such line)")
        ci = ci_final(ctx, ci["id"])
    return ci, ap, log


def grep(text: str, pattern: str) -> str:
    return " | ".join(ln.split("\t")[-1].strip() for ln in text.splitlines() if re.search(pattern, ln))[:400] \
        if text else ""


def ready(ctx: Ctx, rec: Record, n: int, head: str, d: Path, expect: int, pattern: str, what: str) -> None:
    """km ready on the PR at HEAD: exit EXPECT and a line matching PATTERN (label_by has waited for the
    label event to show)."""
    rc, out = ctx.km_ready(n, head, d)
    rec.check(what, rc == expect and re.search(pattern, out) is not None, f"exit {expect}, /{pattern}/", f"exit {rc}: {out}")


def label_by(ctx: Ctx, rec: Record, role: str, n: int) -> None:
    """Apply km:ready as ROLE and wait until the events show ROLE's label last (they lag)."""
    ctx.label(role, n)
    want = ctx.login(role)
    try:
        actor = ctx.poll("the km:ready label event", lambda: ctx.last_label_actor(n) == want and want, 120, 5)
    except Fail:
        actor = ctx.last_label_actor(n)
    rec.must(f"km:ready applied by {role}", actor == want, want, actor)


def body_with_table(head_note: str, rows: list[tuple[str, str, str]]) -> str:
    table = "| Doc | Level | Sign-off |\n|---|---|---|\n" + "\n".join(f"| `{p}` | {lv} | {s} |" for p, lv, s in rows)
    return f"Invented e2e test data.\n\n{table}\n\n{head_note}\n"


def hook_km_revs(text: str) -> set[str]:
    """The rev of each km entry of a pre-commit config (an entry: from one `- ` at the repos level to the next)."""
    revs = set()
    for entry in re.split(r"(?m)^\s*-\s+(?=repo:)", text)[1:]:
        if re.match(r"repo:\s*['\"]?https://github\.com/pasrom/km(?:\.git)?/?['\"]?\s*(?:#.*)?$", entry.split("\n", 1)[0]):
            revs |= set(re.findall(r"(?m)^\s*rev:\s*['\"]?([\w.\-]+)", entry))
    return revs


# --- E01: upgrade from the baseline release to the candidate ----------------------------------
def e01(ctx: Ctx, rec: Record) -> None:
    d = ctx.clone("M", ctx.cfg.slug, ctx.dir / "E01")
    br = ctx.branch("E01")
    ctx.git("M", d, "checkout", "-q", "-b", br)
    version = ctx.km(d, "--version").stdout.strip()
    km_ok(ctx, rec, d, "upgrade")
    flows = "\n".join(p.read_text(encoding="utf-8") for p in (d / ".github" / "workflows").iterdir()
                      if p.suffix in (".yml", ".yaml"))
    flow_pins = set(re.findall(r"pasrom/km@([\w.\-]+)", flows))   # km.pins PIN
    hook_pins = hook_km_revs((d / ".pre-commit-config.yaml").read_text(encoding="utf-8"))
    rec.must("every km pin (workflows and pre-commit) moved to the candidate commit",
             flow_pins == hook_pins == {ctx.cfg.candidate}, ctx.cfg.candidate, f"workflows {sorted(flow_pins)}, hook {sorted(hook_pins)}")
    changed = ctx.git("M", d, "status", "--porcelain").split()
    rec.check("km upgrade replaced the shipped main-guard (changed in the candidate)",
              ".github/workflows/main-guard.yml" in changed, "main-guard.yml changed", changed)
    head = commit(ctx, "M", d, f"chore(km): upgrade to km {version}")
    pr, head = push_and_open(ctx, rec, d, br, f"chore(km): upgrade to km {version}",
                             "Upgrade of the e2e sandbox from the baseline release to the candidate.", role="M")
    n = pr["number"]
    ci = ctx.wait_run(head, "ci", "pull_request")
    rec.links["ci run (PR)"] = ci["html_url"]
    rec.must("ci on the upgrade PR is green", ci["conclusion"] == "success", "success", ci["conclusion"])
    log = ctx.run_log(ci["id"])
    rec.check("ci ran the candidate km as an Action", f"pasrom/km@{ctx.cfg.candidate}" in log,
              f"pasrom/km@{ctx.cfg.candidate[:7]} in the log", grep(log, r"pasrom/km@") or "(not found)")

    # free control-file case: the author's own label on a PR that changes .github/
    label_by(ctx, rec, "M", n)
    ready(ctx, rec, n, head, d, 1, r"^does not count: set by its author, and it changes \S+, a control file",
          "km ready: the author's label on a change to the workflows does not count (control file)")

    merged = ctx.repo_api("M", f"pulls/{n}/merge", method="PUT", data={"merge_method": "rebase"})
    main = merged["sha"]
    rec.notes.append(f"merged by rebase, main at {main[:7]}")
    push_ci = ctx.wait_run(main, "ci", "push")
    rec.links["ci run (main)"] = push_ci["html_url"]
    rec.check("ci on main after the merge is green", push_ci["conclusion"] == "success", "success", push_ci["conclusion"])
    arts = ctx.repo_api("M", f"actions/runs/{push_ci['id']}/artifacts")["artifacts"]
    rec.check("ci on main uploads the served bundle", any(a["name"] == "served-bundle" for a in arts),
              "artifact served-bundle", [a["name"] for a in arts])
    guard = ctx.wait_run(main, "main-guard", "push")
    rec.links["main-guard run"] = guard["html_url"]
    glog = ctx.run_log(guard["id"])
    rec.check("main-guard accepts the rebase merge", guard["conclusion"] == "success"
              and "every commit came from a merged pull request" in glog,
              "success, 'every commit came from a merged pull request'", f"{guard['conclusion']}: {grep(glog, 'merged pull request|direct push')}")

    # observe: a fresh candidate init against the upgraded tree, for the files km ships
    fresh = ctx.dir / "E01-fresh"
    r = ctx.km(ctx.dir, "init", str(fresh), "--team", "--name", "E2E-Brain", "--desc", "the e2e sandbox team",
               "--initials", "AAA", "--folder=process=x", "--folder=product=x", "--folder=projects=x")
    if r.returncode == 0:
        ctx.git("M", d, "fetch", "-q", "origin", "main")
        ctx.git("M", d, "checkout", "-q", "FETCH_HEAD")
        shipped = [p.relative_to(fresh).as_posix() for p in fresh.rglob("*") if p.is_file()
                   and (p.relative_to(fresh).parts[0] == ".github" or p.name in (".pre-commit-config.yaml", ".gitattributes"))]
        differ = sorted(p for p in shipped if not (d / p).is_file() or (d / p).read_bytes() != (fresh / p).read_bytes())
        rec.notes.append(f"observed: fresh candidate init vs upgraded tree, km-shipped files that differ: {differ or 'none'}")
    else:
        rec.notes.append(f"observed: fresh candidate init failed ({r.returncode}): {r.stderr[-200:]}")


def sync_fork(ctx: Ctx, rec: Record) -> None:
    """Bring C's fork main to the sandbox main (fast-forward after E01's merge)."""
    r = ctx.api("C", f"repos/{ctx.cfg.fork}/merge-upstream", method="POST", data={"branch": "main"})
    rec.notes.append(f"fork synced: {r.get('merge_type')}")


# --- E02: an internal AI-level page, the author's own km:ready (CLI stand-in for /km pr) --------
def e02(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "product/e2e-storage-note.md"
    write(d, rel, page("Storage note for the Lumen lamp", "review", "Store the lamp dry. Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add an invented storage note")
    km_ok(ctx, rec, d, "approve", rel, "--by", AI)
    head = commit(ctx, "C", d, f"docs(product): approve the storage note ({AI})")
    subjects = ctx.git("C", d, "log", "--format=%s", "-2").splitlines()
    rec.check("the sign-off is its own commit on top of the content", subjects[0].startswith("docs(product): approve")
              and "approve" not in subjects[1], "approve commit last, content commit before it", subjects)
    body = body_with_table(f"Last reviewed: {head}", [(rel, "ai", AI)])
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): add an invented storage note", body)
    n = pr["number"]
    ci, _, _ = fork_ci(ctx, rec, head, auto=True)
    rec.check("ci is green", ci["conclusion"] == "success", "success", ci["conclusion"])
    label_by(ctx, rec, "C", n)
    labels = [lb["name"] for lb in ctx.repo_api("M", f"issues/{n}/labels")]
    rec.check("exactly one label, km:ready", labels == ["km:ready"], ["km:ready"], labels)
    ready(ctx, rec, n, head, d, 0, r"^counts: set by its author, and no control file changed and all 1 changed docs are at level ai",
          "km ready: the author's label counts for an AI-level page")


# --- E03 / E04: a customer page needs a person's sign-off; the label rule both ways --------------
def e03(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "projects/p9001/e2e-care-guide.md"
    write(d, rel, page("Care guide for the Lumen lamp", "review", "Wipe the panel once a month. Invented.",
                       audience="customer", owner="BBB", extra="project: p9001\n"))
    gen_index(ctx, rec, d)
    e04 = Record("E04", "a person's sign-off makes the customer page green; whose km:ready counts")
    rec.children.append(e04)              # reported even when E03 stops before it (as not run)
    commit(ctx, "C", d, "docs(p9001): add an invented customer care guide in review")
    pr, head = push_and_open(ctx, rec, d, br, "docs(p9001): add a customer care guide (no review recorded)",
                             "Invented e2e test data: a customer page in review, no AI review, no sign-off.")
    n = pr["number"]
    ci, _, _ = fork_ci(ctx, rec, head, auto=True)
    log = ctx.run_log(ci["id"])
    rec.check("ci is red with a signoff finding for the page", ci["conclusion"] == "failure"
              and re.search(rf"signoff.*{re.escape(rel)}|{re.escape(rel)}.*is review, not signed off", log) is not None,
              f"failure, signoff finding naming {rel}", f"{ci['conclusion']}: {grep(log, r'signoff|ERRORS')}")
    ctx.label("C", n, name="km:needs-human")

    # E04: the person signs off on the branch, as its own commit; CI green
    e04.started = time.time()
    rec.notes.append("E04 continues on this pull request")
    try:
        km_ok(ctx, e04, d, "approve", rel, "--by", "BBB")
        head = commit(ctx, "C", d, "docs(p9001): approve the care guide (BBB)")
        ctx.push("C", d, ctx.cfg.fork, f"HEAD:refs/heads/{br}")
        e04.links[f"PR #{n}"] = pr["html_url"]
        ci, _, _ = fork_ci(ctx, e04, head, auto=True)
        e04.check("ci is green after the person's sign-off", ci["conclusion"] == "success", "success", ci["conclusion"])
        ctx.label("C", n, add=False, name="km:needs-human")
        label_by(ctx, e04, "C", n)
        ready(ctx, e04, n, head, d, 1, rf"^does not count: set by its author, and {re.escape(rel)} is at level human",
              "km ready: the author's label does not count for a human-level page")
        ctx.label("M", n, add=False)
        label_by(ctx, e04, "M", n)
        ready(ctx, e04, n, head, d, 0, rf"^counts: km:ready applied by {re.escape(ctx.cfg.maint)}, not the author",
              "km ready: another person's label counts")
    except Exception as e:                # recorded here, so E03's own result stays its own
        e04.notes.append(f"stopped: {type(e).__name__}: {e}")
    finally:
        e04.seconds = time.time() - e04.started


def e03b(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "projects/p9001/e2e-winter-tips.md"
    write(d, rel, page("Winter tips for the Lumen lamp", "review", "Clear snow off the panel. Invented.",
                       audience="customer", owner="BBB", extra=f'project: p9001\nreviewed_by: ["{AI} 2026-01-01 (e2e)"]\n'))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(p9001): add invented winter tips with an AI review on record")
    pr, head = push_and_open(ctx, rec, d, br, "docs(p9001): add winter tips (AI review recorded)",
                             "Invented e2e test data: a customer page in review with an AI review, waiting for a person.")
    ci, _, _ = fork_ci(ctx, rec, head, auto=True)
    rec.check("ci is green: the page waits for the person with its AI review on record", ci["conclusion"] == "success",
              "success", ci["conclusion"])


# --- E05 / E06: fork PRs, data only and with a script ------------------------------------------
def fork_page_with_media(ctx: Ctx, rec: Record, script: bool) -> tuple[Path, str, str]:
    d, br = contrib_branch(ctx, rec)
    stem = f"e2e-{'runtime' if script else 'outline'}"
    rel, media = f"product/{stem}.md", f"product/{stem}_media"
    write(d, f"{media}/figure.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>\n')
    body = f"![figure]({stem}_media/figure.svg)"
    if script:
        write(d, f"{media}/make_figure.py", 'print("writes figure.svg (invented)")\n')
        body += f"\n\nRegenerate with `python3 {stem}_media/make_figure.py`."
    write(d, rel, page("Lamp figure", "review", body))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add an invented page with a figure")
    km_ok(ctx, rec, d, "approve", rel, "--by", AI)
    commit(ctx, "C", d, f"docs(product): approve the figure page ({AI})")
    return d, br, f"{media}/make_figure.py"


def e05(ctx: Ctx, rec: Record) -> None:
    d, br, _ = fork_page_with_media(ctx, rec, script=False)
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): add a page with an SVG (fork, data only)", "Invented e2e test data.")
    ci, _, _ = fork_ci(ctx, rec, head, auto=True)
    rec.check("ci ran without a person, as attempt 2 by github-actions[bot]", ci["conclusion"] == "success"
              and ci["run_attempt"] >= 2 and ci["triggering_actor"]["login"] == "github-actions[bot]",
              "success, attempt >= 2, github-actions[bot]",
              f"{ci['conclusion']}, attempt {ci['run_attempt']}, {ci['triggering_actor']['login']}")
    label_by(ctx, rec, "C", pr["number"])
    ready(ctx, rec, pr["number"], head, d, 0, r"^counts: set by its author, and no control file changed",
          "km ready: an SVG beside the page no longer stops the author's label (1.17.0)")


def e06(ctx: Ctx, rec: Record) -> None:
    d, br, script = fork_page_with_media(ctx, rec, script=True)
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): add a page with a figure and its script (fork)", "Invented e2e test data.")
    ci, ap, log = fork_ci(ctx, rec, head, auto=False)
    rec.check("approve-fork-ci names the script and approves nothing",
              "files that are not data, not approved, a person approves" in log and json.dumps(script) in log,
              f"notice 'files that are not data' and {json.dumps(script)}", grep(log, r"##\[notice\]|approved run"))
    time.sleep(20)
    ci = ctx.repo_api("M", f"actions/runs/{ci['id']}")
    rec.must("ci still waits for a person", waiting(ci), "action_required", f"{ci['status']}/{ci.get('conclusion')}")
    ctx.repo_api("M", f"actions/runs/{ci['id']}/approve", method="POST")
    rec.notes.append(f"maintainer approved run {ci['id']} by API")
    ci = ci_final(ctx, ci["id"])
    rec.check("ci runs after the maintainer's approval and is green", ci["conclusion"] == "success", "success", ci["conclusion"])
    label_by(ctx, rec, "C", pr["number"])
    ready(ctx, rec, pr["number"], head, d, 0, r"^counts: set by its author, and no control file changed",
          "km ready: a generator script beside the page does not stop the author's label (1.17.0)")


def e05_ctl(ctx: Ctx, rec: Record) -> None:
    """A control file next to an AI-level page: approve-fork-ci passes CLAUDE.md as data (a Markdown
    file at the top), km ready refuses the author's label for it."""
    d, br = contrib_branch(ctx, rec, "E05-ctl")
    rel = "product/e2e-cleaning-note.md"
    write(d, rel, page("Cleaning note", "review", "Use a soft cloth. Invented."))
    with (d / "CLAUDE.md").open("a", encoding="utf-8") as f:
        f.write("\nInvented e2e line: a contributor's change to the agent instructions.\n")
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add a cleaning note and touch CLAUDE.md")
    km_ok(ctx, rec, d, "approve", rel, "--by", AI)
    commit(ctx, "C", d, f"docs(product): approve the cleaning note ({AI})")
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): add a note and change CLAUDE.md (fork)", "Invented e2e test data.")
    ci, _, _ = fork_ci(ctx, rec, head, auto=True)
    rec.check("ci (approved as data by approve-fork-ci) is green", ci["conclusion"] == "success", "success", ci["conclusion"])
    label_by(ctx, rec, "C", pr["number"])
    ready(ctx, rec, pr["number"], head, d, 1, r"^does not count: set by its author, and it changes CLAUDE\.md, a control file",
          "km ready: the author's label does not count with a control file changed")


# --- E08: the review-request guide comment -----------------------------------------------------
def guide_comments(ctx: Ctx, n: int) -> list[dict]:
    cs = ctx.repo_api("M", f"issues/{n}/comments?per_page=100")
    return [c for c in cs if c["user"]["login"] == "github-actions[bot]" and c["body"].startswith(MARKER)]


def wait_guide(ctx: Ctx, n: int, head: str, since: str, pattern: str) -> tuple[list[dict], dict]:
    run = ctx.wait_run(head, "review-request-guide", "pull_request_target", after=since)   # never waits for approval
    cs = ctx.poll(f"the guide comment to match /{pattern}/",
                  lambda: (c := guide_comments(ctx, n)) and re.search(pattern, c[-1]["body"]) and c, 120, 5)
    return cs, run


def request_reviewer(ctx: Ctx, n: int) -> str:
    t = now()
    ctx.repo_api("C", f"pulls/{n}/requested_reviewers", method="POST", data={"reviewers": [ctx.cfg.maint]})
    return t


def e08(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "process/e2e-guide-page.md"
    write(d, rel, page("Meeting rules", "review", "Meetings end on time. Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(process): add invented meeting rules in review")
    pr, head = push_and_open(ctx, rec, d, br, "docs(process): add meeting rules (no review yet)", "Invented e2e test data.")
    n = pr["number"]
    quoted = re.escape(json.dumps(rel))
    t = request_reviewer(ctx, n)
    cs, run = wait_guide(ctx, n, head, t, r"No AI review recorded")
    body = cs[-1]["body"]
    rec.links["guide comment"] = cs[-1]["html_url"]
    rec.check("first request: one comment by github-actions[bot] listing the page under both lists", len(cs) == 1
              and "No AI review recorded" in body and "No sign-off recorded" in body and re.search(quoted, body),
              f"1 comment, both lists, {json.dumps(rel)} quoted", f"{len(cs)} comment(s): {body[:300]!r}")
    ctx.repo_api("C", f"pulls/{n}/requested_reviewers", method="DELETE", data={"reviewers": [ctx.cfg.maint]})
    t = request_reviewer(ctx, n)
    ctx.wait_run(head, "review-request-guide", "pull_request_target", after=t)
    cs = guide_comments(ctx, n)
    rec.check("second request: still one comment", len(cs) == 1, 1, len(cs))
    t = now()
    label_by(ctx, rec, "C", n)
    cs, _ = wait_guide(ctx, n, head, t, r"This pull request is labelled `km:ready`")
    rec.check("label set: the comment says the PR is km:ready", len(cs) == 1, "1 comment, labelled text", cs[-1]["body"][:200])
    t = now()
    ctx.label("C", n, add=False)
    cs, _ = wait_guide(ctx, n, head, t, r"This pull request is no longer labelled `km:ready`")
    body = cs[-1]["body"]
    rec.check("label removed: 'no longer labelled' with the lists back", len(cs) == 1 and "No sign-off recorded" in body,
              "1 comment, 'no longer labelled', lists", body[:300])


def e08_draft(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec, "E08-draft")
    write(d, "process/e2e-draft-page.md", page("Draft page", "review", "A draft pull request. Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(process): add an invented page for a draft pull request")
    try:
        pr, head = push_and_open(ctx, rec, d, br, "docs(process): a draft pull request", "Invented e2e test data.", draft=True)
    except ApiError as e:
        rec.result = "skip"
        rec.notes.append(f"a draft pull request cannot be opened here (HTTP {e.status}): {e.body[:200]}")
        return
    n = pr["number"]
    t = request_reviewer(ctx, n)
    run = ctx.wait_run(head, "review-request-guide", "pull_request_target", after=t)
    log = ctx.run_log(run["id"])
    rec.check("draft: no comment", not guide_comments(ctx, n) and "a draft pull request" in log,
              "no comment, notice 'a draft pull request'", grep(log, r"##\[notice\]") or "(no notice)")


# --- E24: main-guard on a direct push and a force push (last) ----------------------------------
def e24(ctx: Ctx, rec: Record) -> None:
    d = ctx.clone("M", ctx.cfg.slug, ctx.dir / "E24")
    before = ctx.head("M", d)
    ctx.git("M", d, "commit", "-q", "--allow-empty", "-m", f"chore: e2e {ctx.run_id} direct push to main")
    sha = ctx.head("M", d)
    t = now()
    ctx.push("M", d, ctx.cfg.slug, "HEAD:refs/heads/main")
    guard = ctx.wait_run(sha, "main-guard", "push", timeout=600)
    rec.links["main-guard (direct push)"] = guard["html_url"]
    issue = find_guard_issue(ctx, t, sha)
    rec.check("direct push: main-guard red and an issue naming the commit", guard["conclusion"] == "failure" and issue is not None,
              f"failure, issue 'Direct push to main by {ctx.cfg.maint}' naming {sha[:7]}",
              f"{guard['conclusion']}, issue {issue and issue['html_url']}")
    if issue:
        rec.links["issue (direct push)"] = issue["html_url"]
    t = now()
    ctx.push("M", d, ctx.cfg.slug, f"{before}:refs/heads/main", force=True)
    guard = ctx.wait_run(before, "main-guard", "push", after=t, timeout=600)
    rec.links["main-guard (force push)"] = guard["html_url"]
    issue = find_guard_issue(ctx, t, "force push")
    rec.check("force push: main-guard red and an issue naming the force push", guard["conclusion"] == "failure" and issue is not None,
              "failure, issue body 'force push'", f"{guard['conclusion']}, issue {issue and issue['html_url']}")
    if issue:
        rec.links["issue (force push)"] = issue["html_url"]


def find_guard_issue(ctx: Ctx, since: str, needle: str) -> dict | None:
    def look():
        iss = ctx.repo_api("M", f"issues?state=all&since={since}&per_page=50")
        return next((i for i in iss if "pull_request" not in i and i["created_at"] >= since
                     and i["title"] == f"Direct push to main by {ctx.cfg.maint}" and needle in (i["body"] or "")), None)
    try:
        return ctx.poll("the main-guard issue", look, 120, 10)
    except Fail:
        return None


# id: (function, title); the order of PARALLEL is the order they start in
FIRST = ("E01", e01, "upgrade from the baseline release to the candidate by PR, rebase merge, main-guard")
PARALLEL = [
    ("E02", e02, "AI-level page with the author's own km:ready (CLI stand-in for /km pr)"),
    ("E03", e03, "customer page in review without an AI review: CI red with a signoff finding"),
    ("E03b", e03b, "customer page in review with an AI review on record: CI green, waits for a person"),
    ("E05", e05, "fork PR with a page and an SVG: approved as data, CI without a person, author label counts"),
    ("E05-ctl", e05_ctl, "fork PR with an AI-level page and CLAUDE.md: author label does not count"),
    ("E06", e06, "fork PR with a generator script: waits for a person, approved by API, author label counts"),
    ("E08", e08, "review-request guide: created once, updated, switched by the label"),
    ("E08-draft", e08_draft, "review-request guide is silent on a draft PR"),
]
LAST = ("E24", e24, "main-guard on a direct push and a force push to main")
