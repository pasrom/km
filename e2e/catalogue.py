"""The phase 2 scenarios (concept catalogue ids): the rest of the deterministic catalogue. Same rules
as scenarios.py: each makes its own branch `e2e/<run id>/<id>` and pull request, and asserts on GitHub
state read by the API. A "CI red" assertion names the failed step and the finding, never only the
conclusion.

E27 runs right after E01 (the fork is behind main then), E17 after the pull request scenarios (it
leaves main with an accepted page linking to a demoted one, which every later pull request's CI would
report), then E24.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import oracle
from lib import Ctx, Fail, Record, now, waiting
from scenarios import (AI, CONTROL, MARKER, add_signed_page, approve_run, commit, contrib_branch, fork_ci,
                       gen_index, grep, km_ok, label_by, maint_branch, page, push_and_open, request_reviewer,
                       touch_claude_md, wait_guide, write)

VALIDATE = "validate frontmatter + gate + index completeness"
INDEX = "_index Documents list up to date"
NOTICES = r'##\[notice\]|approved run|^"'   # approve-fork-ci's notices and its quoted file names
LOWERED = "the approval level was lowered from human to ai in this pull request"


# --- helpers ------------------------------------------------------------------------------------
def finding(cat: str, rel: str, text: str) -> str:
    """A pattern for one row of `km validate`'s report: the category line, then `<rel> - <text>`."""
    return rf"\d+ x {re.escape(cat)}\b(?:.*\n)*?.*{re.escape(rel)} - {re.escape(text)}"


def expect_ci(ctx: Ctx, rec: Record, ci: dict, what: str, step: str | None = None,
              findings: tuple[str, ...] = ()) -> str:
    """Check the ci run: green (STEP None), or red with exactly STEP failed and every FINDINGS pattern in
    its log. Returns the log."""
    log = ctx.run_log(ci["id"]) if step or findings else ""
    if step is None:
        rec.check(what, ci["conclusion"] == "success", "success", f"{ci['conclusion']}: {grep(log, r'ERRORS|x ')}")
        return log
    failed = ctx.failed_steps(ci["id"])
    missing = [f for f in findings if not re.search(f, log)]
    rec.check(what, ci["conclusion"] == "failure" and failed == [step] and not missing,
              f"failure in step {step!r}, findings present",
              f"{ci['conclusion']}, failed steps {failed}, missing {missing}: "
              f"{grep(log, r' x |ERRORS|out of date')}")
    return log


def data_round(ctx: Ctx, rec: Record, d: Path, br: str, push: bool = False) -> dict:
    """Wait for ci on the clone's head (with PUSH, after pushing it to the PR's fork branch), approved by
    approve-fork-ci (the change touches no control file). Returns the completed ci run."""
    if push:
        ctx.push("C", d, ctx.cfg.fork, f"HEAD:refs/heads/{br}")
    ci, _ = fork_ci(ctx, rec, ctx.head("C", d), auto=True)
    return ci


def set_line(path: Path, key: str, value: str | None) -> None:
    """Set the frontmatter line `key: VALUE` of PATH (added at the end of the frontmatter when missing), or
    with VALUE None remove it (it must be there)."""
    text = path.read_text(encoding="utf-8")
    line = "" if value is None else f"{key}: {value}\n"
    text, k = re.subn(rf"(?m)^{re.escape(key)}:.*\n", line, text, count=1)
    if not k:
        if value is None:
            raise Fail(f"{path.name}: no line {key}:")
        head, sep, body = text.partition("\n---\n")       # the closing line of the frontmatter
        text = f"{head}\n{line.rstrip()}{sep}{body}"
    path.write_text(text, encoding="utf-8")


def edit_text(rec: Record, path: Path, old: str, new: str) -> None:
    """Replace OLD by NEW in PATH; OLD must be there (the seed's text)."""
    text = path.read_text(encoding="utf-8")
    rec.must(f"{path.name} holds {old!r}", old in text, "there", "there" if old in text else "not found")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def resign(ctx: Ctx, rec: Record, d: Path, rel: str, by: str, scope: str) -> None:
    """`km demote` in a commit of its own, then `km approve --by BY` in the next, as the sign-off asks."""
    km_ok(ctx, rec, d, "demote", rel)
    commit(ctx, "C", d, f"docs({scope}): send {Path(rel).name} back to review")
    km_ok(ctx, rec, d, "approve", rel, "--by", by)
    commit(ctx, "C", d, f"docs({scope}): approve {Path(rel).name} ({by})")


# --- E07: a hostile fork's PRs are never auto-approved -----------------------------------------
def not_approved(ctx: Ctx, rec: Record, head: str, notice: str, quoted: str | None, after: str | None = None) -> dict:
    """approve-fork-ci ran for HEAD (after AFTER), logged NOTICE (and QUOTED, JSON-quoted), approved
    nothing, and ci still waits. Returns the newest ci run."""
    ci = ctx.wait_run(head, "ci", "pull_request")
    ap = ctx.wait_run(head, "approve-fork-ci", "pull_request_target", after=after)
    rec.links["approve-fork-ci run"] = ap["html_url"]
    log = ctx.run_log(ap["id"])
    want = notice in log and (quoted is None or json.dumps(quoted) in log) and "approved run" not in log
    rec.check("approve-fork-ci approves nothing and says why", ap["conclusion"] == "success" and want,
              f"success, notice {notice!r}" + (f" naming {json.dumps(quoted)}" if quoted else ""),
              f"{ap['conclusion']}: {grep(log, NOTICES)}")
    time.sleep(15)
    runs = ctx.runs(head, "ci", "pull_request")
    rec.check("every ci run of the head still waits for a person", runs and all(waiting(r) for r in runs),
              "action_required", [f"{r['id']}: {r['status']}/{r.get('conclusion')}" for r in runs])
    return ci


def hostile(ctx: Ctx, rec: Record, files: dict[str, str], notice: str, quoted: str | None, title: str,
            symlink: tuple[str, str] | None = None, append: bool = False) -> None:
    """A fork PR writing FILES (with APPEND, added to the files there), and a SYMLINK (path, target)."""
    d, br = contrib_branch(ctx, rec)
    for rel, text in files.items():
        write(d, rel, ((d / rel).read_text(encoding="utf-8") if append else "") + text)
    if symlink:
        (d / symlink[0]).parent.mkdir(parents=True, exist_ok=True)
        os.symlink(symlink[1], d / symlink[0])
    commit(ctx, "C", d, f"chore: e2e {title}")
    _, head = push_and_open(ctx, rec, d, br, f"chore: {title} (fork)", "Invented e2e test data.")
    not_approved(ctx, rec, head, notice, quoted)


def e07_github(ctx: Ctx, rec: Record) -> None:
    hostile(ctx, rec, {".github/e2e-note.md": "A file under .github/. Invented.\n"}, CONTROL, ".github/e2e-note.md",
            "add a file under .github/")


def e07_schema(ctx: Ctx, rec: Record) -> None:
    hostile(ctx, rec, {"schema.local.yaml": "# an e2e line from a fork\n"}, CONTROL, "schema.local.yaml",
            "change schema.local.yaml at the top", append=True)


def e07_symlink(ctx: Ctx, rec: Record) -> None:
    hostile(ctx, rec, {}, "symlinks or submodules, not approved, a person approves", "product/e2e-link.md",
            "add a symlink named like a page", symlink=("product/e2e-link.md", "../process/how-we-work.md"))


def e07_scripts(ctx: Ctx, rec: Record) -> None:
    hostile(ctx, rec, {"scripts/e2e_tool.py": 'raise SystemExit("an e2e script under scripts/")\n'},
            CONTROL, "scripts/e2e_tool.py", "add a script under scripts/")


def e07_base(ctx: Ctx, rec: Record) -> None:
    """Two PRs from one fork branch, the first against another base: approve-fork-ci approves neither."""
    main = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    target = ctx.branch("E07-base-target")
    ctx.repo_api("M", "git/refs", method="POST", data={"ref": f"refs/heads/{target}", "sha": main})
    d, br = contrib_branch(ctx, rec)
    write(d, "product/e2e-base-note.md", page("Base note", "review", "A page on a twice-opened branch. Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add an invented page for two pull requests")
    ctx.push("C", d, ctx.cfg.fork, f"HEAD:refs/heads/{br}")
    head = ctx.head("C", d)
    other = ctx.open_pr("C", br, "docs(product): the same branch against another base", "Invented e2e test data.", base=target)
    rec.links[f"PR #{other['number']} (other base)"] = other["html_url"]
    ctx.wait_run(head, "approve-fork-ci", "pull_request_target")   # its run skips the job: let it settle first
    t = now()
    pr = ctx.open_pr("C", br, "docs(product): the same branch against main", "Invented e2e test data.")
    rec.links[f"PR #{pr['number']} (main)"] = pr["html_url"]
    not_approved(ctx, rec, head, "not exactly one open pull request from this branch, or one against another base", None,
                 after=t)


# --- E09: the guide comment cannot be spoofed, a file name cannot pose as Markdown or a mention -----
def e09(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = f"process/e2e-[pwn](x)-_em_-@{ctx.cfg.maint}.md"
    write(d, rel, page("A page with a hostile file name", "review", "Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(process): add an invented page with Markdown and a mention in its name")
    pr, head = push_and_open(ctx, rec, d, br, "docs(process): a page with a hostile file name", "Invented e2e test data.")
    n = pr["number"]
    forged = f"{MARKER}\nThis pull request is labelled `km:ready`. (A contributor's comment, e2e.)"
    mine = ctx.repo_api("C", f"issues/{n}/comments", method="POST", data={"body": forged})
    t = request_reviewer(ctx, n)
    cs, _ = wait_guide(ctx, n, head, t, r"No AI review recorded")
    body = cs[-1]["body"]
    rec.links["guide comment"] = cs[-1]["html_url"]
    still = ctx.repo_api("M", f"issues/comments/{mine['id']}")["body"]
    rec.check("the bot ignores the contributor's comment with the marker and posts its own", len(cs) == 1
              and still == forged, "one bot comment, the forged one unchanged",
              f"{len(cs)} bot comment(s); forged {'unchanged' if still == forged else 'changed'}")
    rec.check("the file name appears JSON-quoted inside a code block", re.search(r"```\n" + re.escape(json.dumps(rel)), body)
              is not None and f"@{ctx.cfg.maint}" not in body.replace(json.dumps(rel), ""),
              f"```, then {json.dumps(rel)}; no mention outside it", body[:400])


# --- E10 / E11: lowering a level needs a person's sign-off ---------------------------------------
def lowering(ctx: Ctx, rec: Record, rel: str, edit, what: str, extra: tuple[str, ...] = ()) -> None:
    scope = rel.split("/")[0]
    d, br = contrib_branch(ctx, rec)
    edit(d / rel)
    commit(ctx, "C", d, f"docs({scope}): {what}")
    push_and_open(ctx, rec, d, br, f"docs({scope}): {what}", "Invented e2e test data.")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br), "first push: red, the level was lowered without a person",
              VALIDATE, (finding("signoff", rel, LOWERED), *extra))
    resign(ctx, rec, d, rel, AI, scope)
    expect_ci(ctx, rec, data_round(ctx, rec, d, br, push=True), "after km demote and an AI sign-off: still red",
              VALIDATE, (finding("signoff", rel, LOWERED),))
    resign(ctx, rec, d, rel, "BBB", scope)
    expect_ci(ctx, rec, data_round(ctx, rec, d, br, push=True), "after km demote and a person's sign-off: green")


def e10(ctx: Ctx, rec: Record) -> None:
    lowering(ctx, rec, "process/label-guide.md", lambda p: set_line(p, "approval", None),
             "drop approval: human from the label guide")


def e11(ctx: Ctx, rec: Record) -> None:
    rel = "projects/p9001/customer-manual.md"
    lowering(ctx, rec, rel, lambda p: set_line(p, "audience", "internal"), "make the customer manual internal",
             extra=(finding("approval-stale", rel, "content changed since approved_by"),))


# --- E12: a copied approval is no sign-off ---------------------------------------------------------
def e12(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    copy_ai, copy_human = "process/e2e-label-guide-copy.md", "projects/p9001/e2e-manual-copy.md"
    write(d, copy_ai, (d / "process/label-guide.md").read_text(encoding="utf-8"))
    set_line(d / copy_ai, "approval", None)
    write(d, copy_human, (d / "projects/p9001/customer-manual.md").read_text(encoding="utf-8"))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs: copy two person-approved pages")
    push_and_open(ctx, rec, d, br, "docs: copy two person-approved pages", "Invented e2e test data.")
    log = expect_ci(ctx, rec, data_round(ctx, rec, d, br), "red: a copy lowered to level ai keeps no person's approval",
                    VALIDATE, (finding("signoff", copy_ai, "is new and accepted at level ai with a person's approval no "
                                       "commit of this pull request gave it (copied with the doc?)"),))
    named = [ln.split("\t")[-1].strip() for ln in log.splitlines() if copy_human in ln]
    rec.notes.append(f"observed: a verbatim copy of the customer manual at level human, digest matching: "
                     f"{'findings ' + ' | '.join(named) if named else 'no finding (its copied approval passes)'}")


# --- E13: settings cannot hide a doc from the sign-off check ----------------------------------------
def e13(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "product/test-report.md"
    edit_text(rec, d / "schema.local.yaml", "skip_prefixes: [mounted/]", "skip_prefixes: [mounted/, product/test-report]")
    edit_text(rec, d / "schema.local.yaml", "accepted_requires: [owner, review_by]", "accepted_requires: [owner]")
    with (d / rel).open("a", encoding="utf-8") as f:
        f.write("\nA sentence added while the settings hide the page. Invented.\n")
    commit(ctx, "C", d, "chore: hide the test report from the checks and drop a status rule")
    _, head = push_and_open(ctx, rec, d, br, "chore: hide a page by settings (fork)", "Invented e2e test data.")
    ci = not_approved(ctx, rec, head, CONTROL, "schema.local.yaml")
    expect_ci(ctx, rec, approve_run(ctx, rec, ci["id"]), "red: the hidden doc and the weakened rule are both reported", VALIDATE, (
        finding("signoff", rel, "was checked at the merge base, and this pull request's skip_prefixes, exempt_files or "
                                "reserved_no_frontmatter leave it out"),
        finding("signoff", "schema.local.yaml", "status_rules (a rule dropped or a field removed from one) changed in "
                                                "this pull request, which decide what counts as signed off, and it also changes docs")))


# --- E16: an edited accepted page loses its approval ------------------------------------------------
def e16(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "process/how-we-work.md"
    with (d / rel).open("a", encoding="utf-8") as f:
        f.write("\nPull requests are small. Invented.\n")
    r = ctx.km(d, "validate", rel, role="C")   # what the pre-commit hook runs (the driver's git runs no hooks)
    out = r.stdout + r.stderr
    rec.check("locally, km validate on the file (the hook) refuses the edit", r.returncode != 0
              and re.search(finding("approval-stale", rel, "content changed since approved_by"), out),
              "exit != 0, approval-stale", f"exit {r.returncode}: {grep(out, r' x |approval-stale')}")
    commit(ctx, "C", d, "docs(process): edit the accepted how-we-work page without a demote")
    push_and_open(ctx, rec, d, br, "docs(process): edit an accepted page without a demote", "Invented e2e test data.")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br), "red with approval-stale for the page", VALIDATE,
              (finding("approval-stale", rel, "content changed since approved_by"),))
    resign(ctx, rec, d, rel, AI, "process")
    subjects = ctx.git("C", d, "log", "--format=%s", "-2").splitlines()
    rec.check("the approval is a commit of its own after the demote", subjects[0].startswith("docs(process): approve")
              and subjects[1].startswith("docs(process): send"), "approve, then demote before it", subjects)
    expect_ci(ctx, rec, data_round(ctx, rec, d, br, push=True), "after km demote and approve: green")


# --- E19: the owners roster on CI -------------------------------------------------------------------
def e19(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "product/e2e-zzz-page.md"
    write(d, rel, page("A page owned by someone off the roster", "review", "Invented.", owner="ZZZ"))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add a page owned by ZZZ")
    push_and_open(ctx, rec, d, br, "docs(product): a page owned by ZZZ", "Invented e2e test data.")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br), "red with owner-roster for the page", VALIDATE, (finding(
        "owner-roster", rel, "owner ZZZ is not in the owners roster of schema.local.yaml: reassign the doc to someone "
                             "on it in this pull request (`owner:`), or add them to the roster"),))


def e19_roster(ctx: Ctx, rec: Record) -> None:
    """M removes DDD from the roster: the page DDD owns turns red."""
    d, br = maint_branch(ctx, rec)
    edit_text(rec, d / "schema.local.yaml", "owners: [AAA, BBB, CCC, DDD]", "owners: [AAA, BBB, CCC]")
    head = commit(ctx, "M", d, "chore: drop DDD from the owners roster")
    push_and_open(ctx, rec, d, br, "chore: drop DDD from the owners roster", "Invented e2e test data.", role="M")
    ci = ctx.wait_run(head, "ci", "pull_request")
    rec.links["ci run"] = ci["html_url"]
    expect_ci(ctx, rec, ci, "red with owner-roster for the page DDD owns", VALIDATE, (finding(
        "owner-roster", "product/supplier-list.md", "owner DDD is not in the owners roster of schema.local.yaml"),))


# --- E21: the index must list a new page ----------------------------------------------------------
def e21(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "product/e2e-index-page.md"
    write(d, rel, page("A page the index does not list", "review", "Invented."))
    ctx.git("C", d, "add", "-A")            # km sees tracked files only; no km gen-index
    commit(ctx, "C", d, "docs(product): add a page without updating the index")
    km_ok(ctx, rec, d, "approve", rel, "--by", AI)
    commit(ctx, "C", d, f"docs(product): approve the page ({AI})")
    push_and_open(ctx, rec, d, br, "docs(product): a page the index does not list", "Invented e2e test data.")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br), "red in the index step: km gen-index: out of date", INDEX,
              (r"km gen-index: out of date",))
    km_ok(ctx, rec, d, "gen-index")
    commit(ctx, "C", d, "docs(product): list the new page in the index")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br, push=True), "after km gen-index: green")


# --- E23: the merge-candidate checks of /km queue, against the oracle -------------------------------
def queue_pr(ctx: Ctx, rec: Record, sid: str, *, label: bool, control: bool = False, claim: bool = False,
             stale_review: bool = False) -> tuple[int, str]:
    """A fork PR with an AI-signed page (and a line in CLAUDE.md, a control file, when CONTROL); body with
    `Last reviewed:` (with STALE_REVIEW one more signed page follows the reviewed commit) and a km:ready
    claim when CLAIM; km:ready when LABEL, by C, or by M with CONTROL (so the label counts). Waits for ci
    (approved by approve-fork-ci, or left waiting with CONTROL)."""
    d, br = contrib_branch(ctx, rec, sid)
    stem = f"e2e-{sid.lower()}"
    if control:
        touch_claude_md(d)
    add_signed_page(ctx, rec, d, stem, f"Queue page {stem}", "Invented.")
    reviewed = ctx.head("C", d)
    if stale_review:                       # a commit after the reviewed one: the head moves on
        add_signed_page(ctx, rec, d, f"{stem}-more", f"Queue page {stem}-more", "Invented.")
    claimed = " Labels: km:ready (claimed in the body only)." if claim else ""
    pr, head = push_and_open(ctx, rec, d, br, f"docs(product): queue case {sid}",
                             f"Invented e2e test data.{claimed}\n\nLast reviewed: {reviewed}\n")
    n = pr["number"]
    if control:                            # held back for CLAUDE.md, the reason it waits
        ci = not_approved(ctx, rec, head, CONTROL, "CLAUDE.md")
    else:
        ci, _ = fork_ci(ctx, rec, head, auto=True)
    rec.notes.append(f"{sid}: PR #{n}, ci {ci['status']}/{ci.get('conclusion')}")
    if label:
        t = now()
        label_by(ctx, rec, "M" if control else "C", n)
        ctx.wait_run(head, "review-request-guide", "pull_request_target", after=t)   # the label's run: a check too
    return n, head


def e23(ctx: Ctx, rec: Record) -> None:
    kinds = {"ok": dict(label=True), "claim": dict(label=False, claim=True), "stale": dict(label=True, stale_review=True),
             "pending": dict(label=True, control=True)}
    with ThreadPoolExecutor(max_workers=len(kinds)) as pool:        # independent PRs: wait for their ci together
        futs = {k: pool.submit(queue_pr, ctx, rec, f"E23-{k}", **kw) for k, kw in kinds.items()}
        cases = {k: f.result() for k, f in futs.items()}
    # let every run of the four heads settle (a late one makes gh pr checks pending)
    ctx.poll("the runs of the queue PRs to settle", lambda: all(r["status"] == "completed" or waiting(r)
                                                               for _, h in cases.values() for r in ctx.runs(h)), 300, 10)
    d = ctx.clone("M", ctx.cfg.slug, ctx.dir / "E23-main")
    q = oracle.fetch(ctx, d, only={n for n, _ in cases.values()})
    (ctx.dir / "E23-oracle.json").write_text(json.dumps(q, indent=2, default=str) + "\n", encoding="utf-8")
    rows = {k: q["prs"].get(n) or {} for k, (n, _) in cases.items()}
    rec.notes.append("oracle: " + "; ".join(f"{k} #{cases[k][0]}: {v}" for k, v in rows.items()))
    ok, claim, stale, pending = rows["ok"], rows["claim"], rows["stale"], rows["pending"]
    rec.check("positive control: km:ready, Last reviewed = head, label counts, ci green: a merge candidate",
              ok.get("group") == "km:ready" and ok.get("candidate") is True, "km:ready, candidate", ok)
    rec.check("a km:ready claimed in the body only: no label group", claim.get("group") == "no label", "no label", claim)
    rec.check("Last reviewed not the head: not a merge candidate, that one reason", stale.get("group") == "km:ready"
              and len(stale.get("reasons", [])) == 1 and "is not the head" in stale["reasons"][0],
              "km:ready, one reason 'is not the head'", stale)
    rec.check("ci waiting for approval: not a merge candidate, that one reason", pending.get("group") == "km:ready"
              and pending.get("reasons") == ["no passing ci check (its run waits for a person's approval)"],
              "km:ready, one reason 'no passing ci check (its run waits ...)'", pending)
    chk = q["details"].get(cases["pending"][0], {}).get("checks", [])
    rec.notes.append(f"observed (why queue.md wants a passing ci row, not only gh's exit 0): `gh pr checks` on the PR "
                     f"whose ci waits for approval lists {[(c['workflow'], c['bucket']) for c in chk]}")
    # the docs groups of the seed (main has no doc change from a pull request): a self-check of the oracle
    docs = {g: sorted(p for ps in by.values() for p in ps) for g, by in q["docs"].items()}
    want = {"overdue": ["product/charging-note.md", "product/lamp-overview.md"],
            "needs a person": ["process/glossary.md", "projects/p9001/customer-faq.md"],
            "an AI review may sign off": ["product/lamp-summary.md"]}
    rec.check("docs groups match the seed", docs == want, want, docs)


# --- E25: a verbatim block needs a person; a typed approval binds nothing ---------------------------
def e25(ctx: Ctx, rec: Record) -> None:
    d, br = contrib_branch(ctx, rec)
    rel = "product/e2e-quote.md"
    write(d, rel, page("A quoted datasheet sentence", "review", "The lamp is invented.").replace("type: note",
                                                                                                "type: verbatim-block"))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add an invented verbatim block in review")
    r = ctx.km(d, "approve", rel, "--by", AI, role="C")
    rec.check("km approve --by ai refuses a verbatim block", r.returncode != 0 and not ctx.git("C", d, "status", "--porcelain"),
              "exit != 0, nothing changed", f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-200:]}")
    p = d / rel
    set_line(p, "status", "accepted")
    set_line(p, "approved_by", "CCC")
    set_line(p, "approved_at", str(datetime.date.today()))
    commit(ctx, "C", d, "docs(product): type an approval by hand")
    push_and_open(ctx, rec, d, br, "docs(product): a verbatim block with a typed approval", "Invented e2e test data.")
    expect_ci(ctx, rec, data_round(ctx, rec, d, br), "red: a typed approval without digest binds nothing", VALIDATE,
              (finding("signoff", rel, "is accepted without approved_digest, so no approval is bound to this text"),))


# --- E27: km doctor and km sync against a real fork (right after E01) -----------------------------
def e27(ctx: Ctx, rec: Record) -> None:
    up = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    fork = ctx.api("C", f"repos/{ctx.cfg.fork}/git/ref/heads/main")["object"]["sha"]
    d = ctx.clone("C", ctx.cfg.fork, ctx.dir / rec.id)
    if fork == up:                         # E01 did not move main: put the fork one commit behind
        ctx.git("C", d, "fetch", "-q", ctx.url(ctx.cfg.slug), "main")
        ctx.push("C", d, ctx.cfg.fork, "FETCH_HEAD~1:refs/heads/main", force=True)
        ctx.git("C", d, "reset", "-q", "--hard", "FETCH_HEAD~1")
        rec.notes.append("main had not moved: the fork was set one commit behind")
    # km sync writes to the fork through `gh repo sync`, outside the driver's guard: only from a clone of the fork
    origin = ctx.git("C", d, "remote", "get-url", "origin").strip()
    rec.must("the clone's origin is C's fork", origin == ctx.url(ctx.cfg.fork), ctx.url(ctx.cfg.fork), origin)
    r = ctx.km(d, "doctor", role="C")
    out = r.stdout + r.stderr
    rec.check("km doctor reports the fork behind", re.search(r"FAIL.*your fork's main lacks changes that are on the upstream brain", out),
              "FAIL: your fork's main lacks changes", grep(out, r"fork|upstream") or out[-300:])
    r = ctx.km(d, "sync", role="C")
    out = r.stdout + r.stderr
    fork = ctx.api("C", f"repos/{ctx.cfg.fork}/git/ref/heads/main")["object"]["sha"]
    clone = ctx.head("C", d)
    rec.check("km sync fast-forwards the fork on the host and the clone", r.returncode == 0 and fork == up == clone,
              f"exit 0, fork and clone at {up[:7]}", f"exit {r.returncode}, fork {fork[:7]}, clone {clone[:7]}: {out.strip()[-300:]}")
    r = ctx.km(d, "doctor", role="C")
    out = r.stdout + r.stderr
    rec.check("km doctor then finds the fork current", re.search(r"ok.*your fork's main has everything upstream has", out),
              "ok: your fork's main has everything upstream has", grep(out, r"fork|upstream") or out[-300:])


# --- E28: which ci.yml a fork's pull_request run uses -------------------------------------------
def e28(ctx: Ctx, rec: Record) -> None:
    """A fork branch cut from a main commit whose ci.yml pins another km (before E01's upgrade), changing
    only a doc: the run's job log shows which ci.yml ran, the merge commit's (main's) or the fork head's."""
    flow = ".github/workflows/ci.yml"
    d, br = contrib_branch(ctx, rec)
    main = ctx.head("C", d)
    changed = ctx.git("C", d, "log", "-1", "--format=%H", "HEAD", "--", flow).strip()
    old = f"{changed}~1"
    pins = {rev: set(re.findall(r"pasrom/km@([0-9a-f]{40})", ctx.git("C", d, "show", f"{rev}:{flow}", check=False)))
            for rev in (main, old)}
    rec.must("an older main commit whose ci.yml pins another km (E01 ran)", pins[old] and pins[old] != pins[main],
             "two different pins", {k[:12]: sorted(v) for k, v in pins.items()})
    ctx.git("C", d, "checkout", "-q", "-B", br, old)
    write(d, "product/e2e-old-base.md", page("A page from an old base", "review", "Invented."))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(product): add an invented page on an old base")
    km_ok(ctx, rec, d, "approve", "product/e2e-old-base.md", "--by", AI)
    commit(ctx, "C", d, f"docs(product): approve the page ({AI})")
    push_and_open(ctx, rec, d, br, "docs(product): a page on a branch cut from an older main", "Invented e2e test data.")
    ci = data_round(ctx, rec, d, br)
    log = ctx.run_log(ci["id"])
    used = set(re.findall(r"Download action repository 'pasrom/km@([0-9a-f]{40})'", log))
    head_pin, main_pin = sorted(pins[old]), sorted(pins[main])
    rec.notes.append(f"observed: ci run {ci['id']} (head {ci['head_sha'][:7]}) downloaded km {sorted(u[:12] for u in used)}; "
                     f"main's ci.yml pins {[p[:12] for p in main_pin]}, the fork head's {[p[:12] for p in head_pin]}")
    rec.check("the fork's pull_request run uses the merge commit's ci.yml (main's), not the fork head's",
              used == pins[main], f"km {main_pin[0][:12]} (main's ci.yml)", f"km {sorted(u[:12] for u in used)}")


# --- E17: staleness demotes the lapsed pages (after the pull requests, before E24) ------------------
def e17(ctx: Ctx, rec: Record) -> None:
    before = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    t = now()
    ctx.repo_api("M", "actions/workflows/staleness.yml/dispatches", method="POST", data={"ref": "main"})
    run = ctx.wait_run(before, "staleness", "workflow_dispatch", after=t, timeout=600)
    rec.links["staleness run"] = run["html_url"]
    done = time.time()
    expect_ci(ctx, rec, run, "the run is red only in 'validate after demotion', with the dangling link of how-we-work",
              "validate after demotion", (finding("gate-bergab", "process/how-we-work.md",
                                                  "served doc links to unfinished (review) product/charging-note.md"),))
    head = ctx.repo_api("M", "commits/main")
    cmp = ctx.repo_api("M", f"compare/{before}...{head['sha']}")
    files = sorted(f["filename"] for f in cmp.get("files", []))
    rec.check("one commit on main by brain-ci demoting exactly the two lapsed pages",
              cmp["ahead_by"] == 1 and head["commit"]["author"]["name"] == "brain-ci"
              and head["commit"]["message"] == "chore(ci): demote stale accepted docs to review (review_by lapsed)"
              and files == ["product/charging-note.md", "product/lamp-overview.md"],
              "1 commit by brain-ci, lamp-overview and charging-note",
              f"{cmp['ahead_by']} commit(s) by {head['commit']['author']['name']}: {head['commit']['message']!r}, {files}")
    for rel in ("product/charging-note.md", "product/lamp-overview.md"):
        r = ctx.gh("M", "api", "-H", "Accept: application/vnd.github.raw", f"repos/{ctx.cfg.slug}/contents/{rel}?ref={head['sha']}")
        fm = r.stdout.split("\n---\n", 1)[0]
        rec.check(f"{rel} is in review without approval", "\nstatus: review" in fm and "approved_by" not in fm,
                  "status: review, no approved_by", fm[-300:])
    dest = ctx.dir / "E17-bundle"
    r = ctx.gh("M", "run", "download", str(run["id"]), "-R", ctx.cfg.slug, "-n", "served-bundle", "-D", str(dest))
    names = sorted(json.loads(ln)["path"] for f in dest.glob("*.jsonl") for ln in f.read_text(encoding="utf-8").splitlines()
                   if ln.strip()) if dest.is_dir() else []
    rec.check("the served bundle leaves the demoted pages out (and keeps the old decision)", r.returncode == 0
              and any(n.endswith("battery-choice.md") for n in names)
              and not any(n.endswith(("lamp-overview.md", "charging-note.md")) for n in names),
              "battery-choice.md in, lamp-overview.md and charging-note.md out",
              f"exit {r.returncode}: {names if names else r.stderr[-200:]}")
    time.sleep(max(0.0, 60 - (time.time() - done)))   # an absence: give a run a minute from the push to appear
    others = [f"{r['name']}/{r['event']}" for r in ctx.runs(head["sha"]) if r["name"] in ("ci", "main-guard")]
    rec.check("the push by GITHUB_TOKEN starts no ci and no main-guard run", not others, "none", others)


# id, function, title. AFTER_FIRST runs right after E01, PARALLEL with scenarios.PARALLEL, TAIL before E24
AFTER_FIRST = ("E27", e27, "km doctor reports the fork behind, km sync fast-forwards it (host and clone)")
PARALLEL = [
    ("E07-github", e07_github, "fork PR with a file under .github/: not auto-approved"),
    ("E07-schema", e07_schema, "fork PR changing schema.local.yaml at the top: not auto-approved"),
    ("E07-symlink", e07_symlink, "fork PR with a symlink named like a page: not auto-approved"),
    ("E07-scripts", e07_scripts, "fork PR with a script under scripts/: not auto-approved"),
    ("E07-base", e07_base, "two PRs from one fork branch, one against another base: not auto-approved"),
    ("E09", e09, "the guide comment ignores a forged marker comment; a hostile file name stays quoted"),
    ("E10", e10, "removing approval: human: red, still red after an AI sign-off, green after a person's"),
    ("E11", e11, "customer page made internal: red, still red after an AI sign-off, green after a person's"),
    ("E12", e12, "a copied person's approval at level ai is red; a verbatim copy at level human observed"),
    ("E13", e13, "skip_prefixes hiding a changed doc and a dropped status rule: not auto-approved, red"),
    ("E16", e16, "an edited accepted page: refused locally, red with approval-stale, green after demote and approve"),
    ("E19", e19, "a page owned by someone off the roster: red with owner-roster"),
    ("E19-roster", e19_roster, "the maintainer drops a roster entry: the page that owner holds turns red"),
    ("E21", e21, "a page missing from the index: red in the index step, green after km gen-index"),
    ("E23", e23, "queue oracle: merge candidate, body claim, stale Last reviewed, waiting ci"),
    ("E28", e28, "a fork branch cut from an older main: which ci.yml its pull_request run uses"),
    ("E25", e25, "a verbatim block: km approve --by ai refuses, a typed approval is red"),
]
TAIL = [("E17", e17, "staleness demotes the lapsed pages, pushes past main-guard, rebuilds the bundle, reports the link")]
