"""The automerge scenarios (AM-*): the shipped automerge workflow merges a fork PR whose docs are all at
level ai, with its author's own km:ready, and nothing else. They run with the repository variable
KM_AUTOMERGE=1, which run.py sets for this phase only (after the parallel scenarios, whose PRs it would
otherwise merge, and before E17) and removes again; the reset removes it too.

Each negative case fails exactly one condition (two for AM-ciwait, named below) and asserts the
bot's run completed, did not merge, and its comment names exactly that reason. The negatives run in
parallel; AM-ciyml and then AM-ok run after them, since each moves main and a run judging another PR at that
moment refuses ("changed while it was read"). A head moving between the bot's check and its merge is
not raced here (it cannot be timed without a hook in shipped code): tests/automerge_smoke.sh covers it,
and AM-ok asserts the merge happened at the head the bot judged.
"""
from __future__ import annotations

import json
import re
import time

from lib import ApiError, Ctx, Record, now
from scenarios import (add_signed_page, approve_run, commit, contrib_branch, fork_ci, gen_index, guide_comments, km_ok,
                       label_by, page, push_and_open, touch_claude_md, write)

VAR = "KM_AUTOMERGE"
MARKER = "<!-- km:automerge -->"
BOT = "github-actions[bot]"


def switch(ctx: Ctx, on: bool) -> None:
    """Set KM_AUTOMERGE=1 on the sandbox, or remove it."""
    try:
        ctx.repo_api("M", f"actions/variables/{VAR}", method="DELETE")
    except ApiError as e:
        if e.status != 404:
            raise
    if on:
        ctx.repo_api("M", "actions/variables", method="POST", data={"name": VAR, "value": "1"})


def bot_comment(ctx: Ctx, n: int) -> dict | None:
    own = guide_comments(ctx, n, MARKER)
    return own[0] if own else None


def reasons(body: str) -> list[str]:
    """The JSON-quoted reasons in the comment's code block."""
    m = re.search(r"```\n(.*?)\n```", body, re.S)
    return [json.loads(ln) for ln in m.group(1).splitlines()] if m else []


def outcome(ctx: Ctx, rec: Record, n: int, head: str, since: str) -> tuple[dict, dict | None]:
    """The automerge run the label started (completed), then the PR and the bot's comment."""
    run = ctx.wait_run(head, "automerge", "pull_request_target", after=since, timeout=900)
    rec.links[f"automerge run ({head[:7]})"] = run["html_url"]
    rec.check("the automerge run completes green (declining fails no check)", run["conclusion"] == "success",
              "success", run["conclusion"])
    pr = ctx.repo_api("M", f"pulls/{n}")
    c = ctx.poll("the bot's comment", lambda: bot_comment(ctx, n), 60, 5) if not pr["merged"] else bot_comment(ctx, n)
    if c:
        rec.links["automerge comment"] = c["html_url"]
    return pr, c


def body(head: str) -> str:
    return f"Invented e2e test data.\n\nLast reviewed: {head}\n"


def declined(ctx: Ctx, rec: Record, n: int, head: str, since: str, want: list[str]) -> None:
    """Not merged, and the comment's reasons match WANT (patterns), one each, nothing else."""
    pr, c = outcome(ctx, rec, n, head, since)
    got = reasons(c["body"]) if c else []
    rec.check("not merged", not pr["merged"] and pr["state"] == "open", "open, not merged", f"{pr['state']}, merged {pr['merged']}")
    rec.check("the bot's comment names exactly the expected reasons", len(got) == len(want)
              and all(any(re.search(w, g) for g in got) for w in want), want, got)


def green_ci(ctx: Ctx, rec: Record, head: str, run: dict | None = None) -> None:
    """ci on HEAD green: approved by approve-fork-ci, or, given the waiting RUN, approved by M."""
    ci = fork_ci(ctx, rec, head, auto=True)[0] if run is None else approve_run(ctx, rec, run["id"])
    rec.must("ci is green", ci["conclusion"] == "success", "success", ci["conclusion"])


def signed_fork_pr(ctx: Ctx, rec: Record, *, control: bool = False, stale: bool = False, base: str = "main",
                   draft: bool = False, svg: bool = False) -> tuple[dict, str]:
    d, br = contrib_branch(ctx, rec)
    stem = f"e2e-{rec.id.lower()}"
    if control:
        touch_claude_md(d)
    add_signed_page(ctx, rec, d, stem, f"Merge bot page {stem}", "Invented.", svg=svg)
    reviewed = ctx.head("C", d)
    if stale:
        add_signed_page(ctx, rec, d, f"{stem}-more", f"Merge bot page {stem}-more", "Invented.")
    return push_and_open(ctx, rec, d, br, f"docs(product): merge bot case {rec.id}", body(reviewed), draft=draft, base=base)


def label_then_judge(ctx: Ctx, rec: Record, role: str, n: int, head: str, want: list[str]) -> None:
    t = now()
    label_by(ctx, rec, role, n)
    declined(ctx, rec, n, head, t, want)


# --- the positive case -------------------------------------------------------------------------
def am_ok(ctx: Ctx, rec: Record) -> None:
    pr, head = signed_fork_pr(ctx, rec, svg=True)     # with an SVG beside the page: media
    n = pr["number"]
    green_ci(ctx, rec, head)
    before = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    t = now()
    label_by(ctx, rec, "C", n)
    pr, c = outcome(ctx, rec, n, head, t)
    rec.must("the bot merged the PR", pr["merged"] and (pr.get("merged_by") or {}).get("login") == BOT,
             f"merged by {BOT}", f"merged {pr['merged']} by {(pr.get('merged_by') or {}).get('login')}")
    rec.check("its comment says merged at the head it judged", c is not None and f"Merged by the automerge workflow (rebase) at {head}" in c["body"],
              f"'Merged ... at {head[:7]}'", c and c["body"][:200])
    main = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    cmp = ctx.repo_api("M", f"compare/{before}...{main}")
    shas = [x["sha"] for x in cmp.get("commits", [])]
    rec.check("main moved by the PR's two commits, rebased (a rebase merge)", cmp.get("ahead_by") == 2 and cmp.get("behind_by") == 0,
              "2 ahead, 0 behind", f"{cmp.get('ahead_by')} ahead, {cmp.get('behind_by')} behind")
    # main-guard's rule: every pushed commit belongs to a merged pull request
    linked = {s: [p["number"] for p in ctx.repo_api("M", f"commits/{s}/pulls") if p.get("merged_at")] for s in shas}
    rec.check("each merged commit belongs to a merged pull request (what main-guard checks)",
              shas and all(n in v for v in linked.values()), f"#{n} for each", linked)
    time.sleep(60)                        # an absence: give a push run a minute to appear
    others = [f"{r['name']}/{r['event']}" for r in ctx.runs(main) if r["name"] in ("ci", "main-guard") and r["event"] == "push"]
    rec.notes.append(f"observed: push runs for the bot's merge {main[:7]}: {others or 'none'} "
                     "(a merge made with GITHUB_TOKEN starts no workflow)")
    rec.check("no main-guard run reports the bot's merge as a direct push",
              not [r for r in ctx.runs(main) if r["name"] == "main-guard" and r.get("conclusion") == "failure"],
              "no failing main-guard run", others)


# --- the negatives ------------------------------------------------------------------------------
def am_human(ctx: Ctx, rec: Record) -> None:
    """A customer page signed off by a person: M's label counts for km ready, not for the bot."""
    d, br = contrib_branch(ctx, rec)
    rel = "projects/p9001/e2e-am-guide.md"
    write(d, rel, page("Merge bot customer page", "review", "Invented.", audience="customer", owner="BBB",
                       extra="project: p9001\n"))
    gen_index(ctx, rec, d)
    commit(ctx, "C", d, "docs(p9001): add an invented customer page")
    km_ok(ctx, rec, d, "approve", rel, "--by", "BBB")
    head = commit(ctx, "C", d, "docs(p9001): approve the page (BBB)")
    pr, head = push_and_open(ctx, rec, d, br, "docs(p9001): merge bot case AM-human", body(head))
    green_ci(ctx, rec, head)
    label_then_judge(ctx, rec, "M", pr["number"], head, [rf"set by {re.escape(ctx.cfg.maint)}, and {re.escape(rel)} is at level human"])
    rc, out = ctx.km_ready(pr["number"], head, d)
    rec.check("km ready counts M's label (so only the bot's levels rule stops it)", rc == 0, "exit 0", f"exit {rc}: {out}")


def am_control(ctx: Ctx, rec: Record) -> None:
    """An AI-level page and CLAUDE.md; ci approved by M and green; M's label: the control file stops it."""
    pr, head = signed_fork_pr(ctx, rec, control=True)
    green_ci(ctx, rec, head, run=fork_ci(ctx, rec, head, auto=False)[0])
    label_then_judge(ctx, rec, "M", pr["number"], head, [r"CLAUDE\.md, a control file"])


def am_stale(ctx: Ctx, rec: Record) -> None:
    pr, head = signed_fork_pr(ctx, rec, stale=True)
    green_ci(ctx, rec, head)
    label_then_judge(ctx, rec, "C", pr["number"], head, [r"^Last reviewed \w{7} is not the head"])


def am_cifail(ctx: Ctx, rec: Record) -> None:
    """An AI-level page left in review without its sign-off: ci red with a signoff finding."""
    d, br = contrib_branch(ctx, rec)
    write(d, "product/e2e-am-unsigned.md", page("Unsigned page", "review", "Invented."))
    gen_index(ctx, rec, d)
    head = commit(ctx, "C", d, "docs(product): add an invented page without its sign-off")
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): merge bot case AM-cifail", body(head))
    ci, _ = fork_ci(ctx, rec, head, auto=True)
    rec.must("ci is red", ci["conclusion"] == "failure", "failure", ci["conclusion"])
    label_then_judge(ctx, rec, "C", pr["number"], head, [r"^no passing ci check on the head"])


def am_ciwait(ctx: Ctx, rec: Record) -> None:
    """ci waits for a person's approval (a control file holds approve-fork-ci back); M's label. Two
    reasons: the control file, and no passing ci check."""
    pr, head = signed_fork_pr(ctx, rec, control=True)
    fork_ci(ctx, rec, head, auto=False)
    label_then_judge(ctx, rec, "M", pr["number"], head, [r"CLAUDE\.md, a control file", r"^no passing ci check on the head"])


def am_draft(ctx: Ctx, rec: Record) -> None:
    try:
        pr, head = signed_fork_pr(ctx, rec, draft=True)
    except ApiError as e:
        if e.status != 422 or "draft" not in e.body.lower():
            raise
        rec.result = "skip"
        rec.notes.append(f"a draft pull request cannot be opened here (HTTP {e.status}): {e.body[:200]}")
        return
    green_ci(ctx, rec, head)
    label_then_judge(ctx, rec, "C", pr["number"], head, [r"^it is a draft$"])


def am_base(ctx: Ctx, rec: Record) -> None:
    """A PR against another branch: approve-fork-ci leaves its run to a person, M approves, ci green."""
    main = ctx.repo_api("M", "git/ref/heads/main")["object"]["sha"]
    target = ctx.branch("AM-base-target")
    ctx.repo_api("M", "git/refs", method="POST", data={"ref": f"refs/heads/{target}", "sha": main})
    pr, head = signed_fork_pr(ctx, rec, base=target)
    ci = ctx.wait_run(head, "ci", "pull_request")      # approve-fork-ci skips a PR against another base
    rec.links[f"ci run ({head[:7]})"] = ci["html_url"]
    green_ci(ctx, rec, head, run=ci)
    label_then_judge(ctx, rec, "C", pr["number"], head, [rf"^its base is {re.escape(target)}, not the default branch main$"])


def am_script(ctx: Ctx, rec: Record) -> None:
    """A page with a generator script beside it (E06's case): km ready counts C's label, the bot does not
    merge it (narrower than the queue: only media files beside the docs)."""
    d, br = contrib_branch(ctx, rec)
    add_signed_page(ctx, rec, d, "e2e-am-script", "Merge bot page with a script", "Invented.", script=True)
    head = ctx.head("C", d)
    pr, head = push_and_open(ctx, rec, d, br, "docs(product): merge bot case AM-script", body(head))
    green_ci(ctx, rec, head)
    label_then_judge(ctx, rec, "C", pr["number"], head, [r"e2e-am-script_media/make_figure\.py, neither a doc nor a media file: a person merges"])
    rc, out = ctx.km_ready(pr["number"], head, d)
    rec.check("km ready counts C's label (only the bot is narrower)", rc == 0, "exit 0", f"exit {rc}: {out}")


def am_ciyml(ctx: Ctx, rec: Record) -> None:
    """ci passes on C's PR, then M lands a change to ci.yml on main: the bot does not trust the older run."""
    pr, head = signed_fork_pr(ctx, rec)
    green_ci(ctx, rec, head)
    d = ctx.clone("M", ctx.cfg.slug, ctx.dir / "AM-ciyml-main")   # the contributor's clone has rec.id's folder
    br = ctx.branch("AM-ciyml-main")
    ctx.git("M", d, "checkout", "-q", "-b", br)
    flow = d / ".github" / "workflows" / "ci.yml"
    flow.write_text(flow.read_text(encoding="utf-8") + "# e2e: a line on main after the PR's ci run\n", encoding="utf-8")
    mhead = commit(ctx, "M", d, "ci: an e2e comment in ci.yml")
    mpr, mhead = push_and_open(ctx, rec, d, br, "ci: an e2e comment in ci.yml", "Invented e2e change.", role="M")
    ci = ctx.wait_run(mhead, "ci", "pull_request")
    rec.must("ci on M's change is green", ci["conclusion"] == "success", "success", ci["conclusion"])
    ctx.repo_api("M", f"pulls/{mpr['number']}/merge", method="PUT", data={"merge_method": "rebase"})
    rec.notes.append(f"M merged #{mpr['number']} (ci.yml) after the PR's ci run")
    label_then_judge(ctx, rec, "C", pr["number"], head, [r"^ci\.yml on the default branch differs from the head's"])


NEGATIVE = [
    ("AM-script", am_script, "merge bot: a generator script beside the page is not merged (km ready counts it)"),
    ("AM-human", am_human, "merge bot: a human-level page with the maintainer's label is not merged"),
    ("AM-control", am_control, "merge bot: a control file with the maintainer's label is not merged"),
    ("AM-stale", am_stale, "merge bot: a stale Last reviewed is not merged"),
    ("AM-cifail", am_cifail, "merge bot: a red ci is not merged"),
    ("AM-ciwait", am_ciwait, "merge bot: a fork ci waiting for approval is not merged"),
    ("AM-draft", am_draft, "merge bot: a draft is not merged"),
    ("AM-base", am_base, "merge bot: a PR against another base is not merged"),
]
# after the parallel negatives (it moves main, which a run judging another PR would refuse), before AM-ok
SERIAL = ("AM-ciyml", am_ciyml, "merge bot: ci.yml changed on main after the PR's ci run: not merged")
POSITIVE = ("AM-ok", am_ok, "merge bot: an AI-level fork PR with an SVG beside the page and the author's own km:ready is merged by rebase")
ALL = [*NEGATIVE, SERIAL, POSITIVE]


def phase(ctx: Ctx, parallel, pick) -> list[Record]:
    """KM_AUTOMERGE on, the negatives in parallel (PARALLEL runs a list of scenarios), then AM-ciyml and
    AM-ok, which move main, one after the other; KM_AUTOMERGE off again whatever happens."""
    batches = [[s for s in NEGATIVE if pick(s[0])], *([s] for s in (SERIAL, POSITIVE) if pick(s[0]))]
    if not any(batches):
        return []
    switch(ctx, True)
    try:
        return [rec for batch in batches if batch for rec in parallel(batch)]
    finally:
        switch(ctx, False)
