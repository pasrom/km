"""Run the km e2e test against a sandbox team brain: `python3 e2e/run.py [options]`.

Preflight (refuses to write anywhere unless the identities and the sandbox are what the environment
names, and the maintainer's token cannot reach the repositories it must not), a lock, reset R1 (the
sandbox's main regenerated from the seed with Actions off), the scenarios, then Actions off again.
Writes report.json and report.md under $KM_E2E_WORKDIR/runs/<run id>/ (never into the repository).
See e2e/README.md.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
import re
import signal
import sys
import time
import traceback
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import catalogue as C2                     # noqa: E402
import merge_bot as MB                     # noqa: E402
import scenarios as S                      # noqa: E402
import seed                                # noqa: E402
from check_names import NAME               # noqa: E402
from lib import ApiError, Config, Ctx, Fail, Record, now   # noqa: E402

LOCK = "KM_E2E_LOCK"
MARKER = "KM_E2E_SANDBOX"
SLUG = re.compile(rf"{NAME}/{NAME}")
LABELS = ("km:ready", "km:needs-human", "km:blocked")
PARALLEL = [*S.PARALLEL, *C2.PARALLEL]
SCENARIOS = [S.FIRST, C2.AFTER_FIRST, *PARALLEL, *MB.ALL, *C2.TAIL, S.LAST]   # in the order a full run starts them


def say(msg: str) -> None:
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


# --- preflight ----------------------------------------------------------------------------------
def preflight(ctx: Ctx) -> list[str]:
    """Problems that stop the run (empty: go). Warnings are printed."""
    cfg, bad = ctx.cfg, []
    # before any call: the settings themselves (a typo here must not point the run at a real repository)
    if bad := [f"KM_E2E_MUST_NOT_REACH: {s!r} is not owner/repo" for s in cfg.must_not_reach if not SLUG.fullmatch(s)]:
        return bad
    if not (cfg.contrib_token_file or cfg.contrib_gh_dir):
        return ["set KM_E2E_CONTRIB_TOKEN_FILE (or, as a fallback, KM_E2E_CONTRIB_GH_CONFIG_DIR)"]
    tokens = {}
    for role in ("M", "C"):
        if tf := cfg.token_file(role):
            try:
                tokens[role] = tf.read_text().strip()
            except OSError as e:
                return [f"{role}'s token file cannot be read ({type(e).__name__})"]
    if not tokens["M"].startswith("github_pat_"):
        return ["M's token is not a fine-grained token (github_pat_...): it could reach more than the sandbox organisation"]
    if "C" in tokens and not tokens["C"].startswith("github_pat_"):
        say("warning: C's token is not fine-grained: it reaches every repository C can, so C's account itself "
            "must have no access beyond the sandbox (the 404 checks cover only KM_E2E_MUST_NOT_REACH)")
    if not cfg.contrib_token_file:
        say("warning: C has no token file; its git credentials come from `gh auth git-credential` under "
            "KM_E2E_CONTRIB_GH_CONFIG_DIR, which can fall back to another stored login (KM_E2E_CONTRIB_TOKEN_FILE avoids it)")
    for role, want in (("M", cfg.maint), ("C", cfg.contrib)):
        got = ctx.ident(role)[0]
        if got != want:
            bad.append(f"{role}: the token is {got}, the environment names {want}")
    for slug in cfg.must_not_reach:
        for role in ("M", "C"):
            st = ctx.status(role, f"repos/{slug}")
            if st != 404:
                bad.append(f"{role} reaches a repository it must not (HTTP {st} on one of KM_E2E_MUST_NOT_REACH)")
    try:
        repo = ctx.api("M", f"repos/{cfg.slug}")
    except ApiError as e:
        return bad + [f"cannot read the sandbox brain (HTTP {e.status})"]
    if repo["owner"]["login"] != cfg.org or repo["owner"]["type"] != "Organization":
        bad.append("the sandbox brain's owner is not the configured organisation")
    if not repo["private"]:
        bad.append("the sandbox brain is not private (the scenarios assume a private repository)")
    if not (repo.get("permissions") or {}).get("admin"):
        bad.append("M is not admin on the sandbox brain (reset and Actions switch need it)")
    try:                                   # the sandbox says it is one: a real brain never carries this
        marked = ctx.repo_api("M", f"actions/variables/{MARKER}")["value"] == "1"
    except ApiError:
        marked = False
    if not marked:
        bad.append(f"the repository variable {MARKER}=1 is not set on the sandbox brain (it marks a repository the run may reset)")
    try:
        fork = ctx.api("C", f"repos/{cfg.fork}")
        if (fork.get("parent") or {}).get("full_name") != cfg.slug:
            bad.append("C's repository of that name is not a fork of the sandbox brain")
    except ApiError as e:
        bad.append(f"C has no fork of the sandbox brain (HTTP {e.status})")
    role = ctx.repo_api("M", f"collaborators/{cfg.contrib}/permission").get("role_name")
    if role != "triage":
        bad.append(f"C's role on the sandbox brain is {role}, not triage (the scenarios label and request reviewers as C)")
    try:
        var = ctx.repo_api("M", "actions/variables/KM_MAINTAINERS")["value"]
        if cfg.maint.lower() not in var.lower().replace(",", " ").split():
            bad.append("KM_MAINTAINERS does not name M")
    except ApiError:
        bad.append("the repository variable KM_MAINTAINERS is not set")
    have = {lb["name"] for lb in ctx.repo_api("M", "labels?per_page=100")}
    if missing := [lb for lb in LABELS if lb not in have]:
        bad.append(f"labels missing: {missing}")
    try:
        usage = ctx.api("M", f"organizations/{cfg.org}/settings/billing/usage/summary")
        items = [i for i in usage.get("usageItems", []) if i.get("sku", "").startswith("actions_linux")
                 or i.get("product") == "actions"]
        say(f"billing usage summary: {json.dumps(items)[:300]}")
    except ApiError as e:
        say(f"warning: the Actions usage summary is not readable with M's token (HTTP {e.status}); "
            "check the allowance on the organisation's billing page")
    return bad


# --- lock ---------------------------------------------------------------------------------------
def take_lock(ctx: Ctx, steal: bool) -> None:
    try:
        held = ctx.repo_api("M", f"actions/variables/{LOCK}")["value"]
        if not steal:
            raise SystemExit(f"e2e: run {held} holds the sandbox ({LOCK}); --steal-lock takes it over")
        ctx.repo_api("M", f"actions/variables/{LOCK}", method="PATCH", data={"name": LOCK, "value": ctx.run_id})
    except ApiError as e:
        if e.status != 404:
            raise
        try:
            ctx.repo_api("M", "actions/variables", method="POST", data={"name": LOCK, "value": ctx.run_id})
        except ApiError as e2:            # another run created it since the read
            if e2.status in (409, 422):
                raise SystemExit(f"e2e: another run took the sandbox ({LOCK}) just now") from None
            raise


def holds_lock(ctx: Ctx) -> bool:
    try:
        return ctx.repo_api("M", f"actions/variables/{LOCK}")["value"] == ctx.run_id
    except ApiError:
        return False


def drop_lock(ctx: Ctx) -> None:
    try:
        if ctx.repo_api("M", f"actions/variables/{LOCK}")["value"] == ctx.run_id:
            ctx.repo_api("M", f"actions/variables/{LOCK}", method="DELETE")
    except ApiError:
        pass


# --- Actions switch and reset R1 ----------------------------------------------------------------
def actions(ctx: Ctx, on: bool) -> None:
    ctx.repo_api("M", "actions/permissions", method="PUT",
                 data={"enabled": True, "allowed_actions": "all"} if on else {"enabled": False})
    say(f"Actions {'on' if on else 'off'}")


def settle(ctx: Ctx, timeout: float = 420) -> None:
    """Wait (bounded) until no run of the sandbox brain is queued or in progress."""
    end = time.time() + timeout
    while time.time() < end:
        busy = sum(ctx.repo_api("M", f"actions/runs?status={s}&per_page=1")["total_count"] for s in ("queued", "in_progress"))
        if not busy:
            return
        time.sleep(15)
    say("warning: runs still busy; turning Actions off anyway")


def reset(ctx: Ctx) -> dict:
    """R1: Actions off, close PRs and issues, delete branches (sandbox and fork), force-push a freshly
    seeded main to both, tag it e2e-baseline/<run id>. Actions are switched on by the caller."""
    cfg = ctx.cfg
    actions(ctx, False)
    MB.switch(ctx, False)                 # the merge bot is on only for its own phase
    for kind in ("pulls", "issues"):
        for item in ctx.repo_api("M", f"{kind}?state=open&per_page=100"):
            if kind == "issues" and "pull_request" in item:
                continue
            ctx.repo_api("M", f"{kind}/{item['number']}", method="PATCH", data={"state": "closed"})
            say(f"closed {kind[:-1]} #{item['number']}")
    for role, slug in (("M", cfg.slug), ("C", cfg.fork)):
        for b in ctx.api(role, f"repos/{slug}/branches?per_page=100"):
            if b["name"] != "main":
                ctx.api(role, f"repos/{slug}/git/refs/heads/{b['name']}", method="DELETE")
                say(f"deleted branch {b['name']} in the {'sandbox' if role == 'M' else 'fork'}")
    mount = None
    if cfg.mount:
        head = ctx.api("M", f"repos/{cfg.org}/{cfg.mount}/commits/main")
        if not head["parents"]:
            raise SystemExit("e2e: the mount repository needs at least two commits (it is pinned one behind its head)")
        mount = (ctx.url(f"{cfg.org}/{cfg.mount}"), head["parents"][0]["sha"])   # one commit behind its head
    out = ctx.dir / "seed"
    say("seeding with the baseline km")
    main = seed.build(out, ctx.km_cmd(cfg.baseline), datetime.date.today(), mount)
    ctx.push("M", out, cfg.slug, "main:refs/heads/main", force=True)
    tag = f"e2e-baseline/{ctx.run_id}"
    ctx.git("M", out, "tag", tag)
    ctx.push("M", out, cfg.slug, f"refs/tags/{tag}")
    ctx.push("C", out, cfg.fork, "main:refs/heads/main", force=True)
    say(f"main reset to {main[:7]} (tag {tag}), fork synced")
    return {"main": main, "tag": tag, "mount_pin": mount[1] if mount else None}


# --- scenarios ------------------------------------------------------------------------------------
def run_one(ctx: Ctx, sid: str, fn, title: str) -> Record:
    rec = Record(sid, title)
    rec.started = time.time()
    say(f"{sid}: start")
    try:
        fn(ctx, rec)
        if rec.result == "pending":
            rec.result = grade(rec)
    except Fail as e:
        rec.result = "fail"
        rec.notes.append(f"stopped: {e}")
    except Exception as e:                  # a driver or infrastructure problem, not a km finding
        rec.result = "error"
        rec.notes.append(f"error: {type(e).__name__}: {e}")
        rec.notes.append("traceback: " + traceback.format_exc()[-1200:])
    rec.seconds = time.time() - rec.started
    for child in rec.children:
        if child.result == "pending":
            child.result = grade(child) if child.started else "skip"
            if not child.started:
                child.notes.append(f"not run: {rec.id} stopped before it")
    say(f"{sid}: {rec.result} ({rec.seconds:.0f} s)" + "".join(f"; {c.id}: {c.result}" for c in rec.children))
    return rec


def run_parallel(ctx: Ctx, todo: list, workers: int) -> list[Record]:
    """The scenarios TODO, WORKERS at a time; on a signal, no queued one starts and the running ones end."""
    recs: list[Record] = []
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futs = []
        try:
            for s in todo:
                futs.append(pool.submit(run_one, ctx, *s))
                time.sleep(3)              # spread PR creation (secondary rate limits)
            recs += [f.result() for f in futs]
        except BaseException:
            pool.shutdown(wait=True, cancel_futures=True)
            recs += [f.result() for f in futs if f.done() and not f.cancelled() and not f.exception()]
            raise
    return recs


def cleanup_steps(locked: bool, meta: dict, start: str) -> list[tuple[str, Callable[[Ctx], object], str]]:
    """What ends a run: (name, step, what to do if it fails). A run that does not hold the lock (it never
    got it, or another run took it over) leaves the sandbox, the lock included, as it is."""
    if not locked:
        return []
    return [("wait for runs", settle, "could not wait for the runs to finish"),
            ("Actions off", lambda c: actions(c, False), "could not switch Actions off: switch them off by hand"),
            ("drop the lock", drop_lock, f"could not drop the lock: delete the repository variable {LOCK} by hand"),
            ("count the minutes", lambda c: meta.update(zip(("runs", "jobs", "minutes"), c.billed_minutes(start))),
             "could not count the Actions minutes: the report has none")]


def grade(rec: Record) -> str:
    """pass only with at least one check, all ok, and nothing stopped it."""
    stopped = any(n.startswith("stopped") for n in rec.notes)
    return "pass" if rec.checks and all(c.ok for c in rec.checks) and not stopped else "fail"


def flat(recs: list[Record]) -> list[Record]:
    return [r for rec in recs for r in (rec, *rec.children)]


# --- report ---------------------------------------------------------------------------------------
def report(ctx: Ctx, meta: dict, recs: list[Record]) -> None:
    allr = flat(recs)
    data = {**meta, "scenarios": [dataclasses.asdict(r) | {"children": None} for r in allr]}
    (ctx.dir / "report.json").write_text(json.dumps(data, indent=2, default=str) + "\n", encoding="utf-8")
    lines = [f"# km e2e run {ctx.run_id}", "",
             f"- candidate km: {meta['candidate']}, baseline km: {meta['baseline']}",
             f"- sandbox: {ctx.cfg.slug}, baseline main {str(meta.get('reset', {}).get('main', '-'))[:7]}",
             f"- wall time: {meta['wall_seconds'] / 60:.1f} min; Actions: {meta.get('runs', '?')} runs, "
             f"{meta.get('jobs', '?')} jobs, about {meta.get('minutes', '?')} billed minutes (each job rounded up)",
             "", "| Scenario | Result | Seconds | What |", "|---|---|---|---|"]
    lines += [f"| {r.id} | {r.result} | {r.seconds:.0f} | {r.title} |" for r in allr]
    for r in allr:
        lines += ["", f"## {r.id}: {r.result}", "", r.title, ""]
        lines += [f"- {'ok' if c.ok else 'FAIL'}: {c.what}. Expected: {c.expected}. Observed: {c.observed}" for c in r.checks]
        lines += [f"- note: {n}" for n in r.notes if not n.startswith("traceback:")]
        lines += [f"- {k}: {v}" for k, v in r.links.items()]
    counts = {k: sum(r.result == k for r in allr) for k in ("pass", "fail", "error", "skip")}
    lines += ["", f"Summary: {counts}"]
    (ctx.dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    say(f"report: {ctx.dir / 'report.md'}; summary {counts}")


def main() -> int:
    ap = argparse.ArgumentParser(prog="run.py")
    ap.add_argument("--only", help="comma-separated scenario ids: only these run (E01 too: without it the rest runs on the baseline)")
    ap.add_argument("--skip-reset", action="store_true", help="run on the sandbox as it is")
    ap.add_argument("--run-id", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S-")
                    + os.urandom(2).hex(), help="unique per run: the lock and every branch name carry it")
    ap.add_argument("--workers", type=int, default=4, help="pull request scenarios run in parallel (default 4)")
    ap.add_argument("--steal-lock", action="store_true")
    ap.add_argument("--preflight", action="store_true", help="only the preflight")
    a = ap.parse_args()
    ctx = Ctx(Config.from_env(), a.run_id)
    try:
        return run(ctx, a)
    finally:
        ctx.close()


def run(ctx: Ctx, a: argparse.Namespace) -> int:
    t0, start = time.time(), now()
    ctx.started = start
    say(f"run {ctx.run_id}: sandbox {ctx.cfg.slug}, candidate {ctx.cfg.candidate[:7]}, baseline {ctx.cfg.baseline[:7]}")
    if bad := preflight(ctx):
        for b in bad:
            say(f"preflight: {b}")
        return 2
    say("preflight ok")
    if a.preflight:
        return 0
    only = set(a.only.split(",")) if a.only else None
    known = {s[0] for s in SCENARIOS}
    if only and (unknown := only - known):
        say(f"unknown scenario ids {sorted(unknown)}; known: {sorted(known)}")
        return 2
    if a.skip_reset:
        say("note: --skip-reset keeps main as the last run left it; after its E17 an accepted page links to a "
            "demoted one, so every pull request's ci is red")
    if only and S.FIRST[0] not in only and not a.skip_reset:
        say("note: without E01 the scenarios run on the baseline seed (its km pins), not on the candidate")
    pick = lambda sid: only is None or sid in only   # noqa: E731
    meta: dict = {"run_id": ctx.run_id, "candidate": ctx.cfg.candidate, "baseline": ctx.cfg.baseline, "started": start}
    recs: list[Record] = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # a kill runs the cleanup below, like Ctrl-C
    locked = False
    try:
        take_lock(ctx, a.steal_lock)
        locked = True                      # from here the sandbox is this run's to clean up
        if not a.skip_reset:
            meta["reset"] = reset(ctx)
        actions(ctx, True)
        if pick(S.FIRST[0]):
            recs.append(run_one(ctx, *S.FIRST))
            if recs[-1].result != "pass":
                say("E01 did not pass: the PR scenarios would run on the baseline; stopping")
                return 1
        if pick(C2.AFTER_FIRST[0]):           # it brings the fork up to main itself (km sync)
            recs.append(run_one(ctx, *C2.AFTER_FIRST))
        if recs:                           # main moved (E01) or the fork was set behind (E27): bring it along
            try:                           # a no-op after a working E27; the PR scenarios branch from main anyway
                S.sync_fork(ctx, recs[0])
            except ApiError as e:
                say(f"warning: the fork could not be synced with main (HTTP {e.status}); km doctor in the fork would say behind")
                recs[0].notes.append(f"fork sync failed: HTTP {e.status}")
        recs += run_parallel(ctx, [s for s in PARALLEL if pick(s[0])], a.workers)
        recs += MB.phase(ctx, lambda todo: run_parallel(ctx, todo, a.workers), pick)   # KM_AUTOMERGE on for these only; AM-ok moves main
        for s in (*C2.TAIL, S.LAST):       # these change main: one after another, E24 last
            if pick(s[0]):
                recs.append(run_one(ctx, *s))
    finally:                               # each step on its own: a failing one or a second signal skips no other
        if locked and not holds_lock(ctx):
            say(f"warning: {LOCK} no longer names this run (taken over with --steal-lock?): leaving the sandbox as it is")
            locked = False
        for _, step, if_failed in cleanup_steps(locked, meta, start):
            try:
                step(ctx)
            except BaseException as e:
                say(f"warning: {if_failed} ({type(e).__name__}: {e})")
        if locked:
            meta["wall_seconds"] = time.time() - t0
            try:
                report(ctx, meta, recs)
            except BaseException as e:
                say(f"warning: could not write the report ({type(e).__name__}: {e})")
    return 0 if all(r.result in ("pass", "skip") for r in flat(recs)) else 1

if __name__ == "__main__":
    sys.exit(main())
