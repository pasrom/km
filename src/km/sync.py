"""Keep a brain copy current: `km sync [--root DIR] [--quiet] [--offline] [--max-age AGE]`.

A copy of a brain goes stale: answers then come from old knowledge and new work starts on an old
base. km sync fetches the brain's upstream (see km.remotes: the remote `upstream`, else the parent
of a fork, else origin) and origin, then:

- fast-forwards the default branch when it is checked out, the working tree has no uncommitted
  changes (mounted brains do not count) and upstream only added to it;
- on a work branch, a detached HEAD, a dirty tree or a local default branch that diverged, changes
  nothing and says how far behind the branch is;
- brings a fork's default branch on the host along when that is a fast-forward too: `gh repo sync`
  for a fork gh confirmed; a plain push of upstream's commit only where gh is not installed, so
  the fork cannot be confirmed (git refuses a push that is not a fast-forward, and no option here
  forces one); nothing where gh says origin is no fork, or refuses to sync it;
- makes the mounted brains match what the brain pins: `git submodule update --init` for a mount
  that is missing or behind its pin; one with changes of its own, a branch checked out, or ahead
  of or diverged from its pin is left alone and reported. A pin never moves here; that is the
  host's automation (Dependabot) and a reviewed pull request.

A fork's parent that gh found is added once as the remote `upstream` (as `gh repo fork` does), so
the next run needs no gh and the fetched branch has a ref of its own.

Never a rebase, a reset, a force or a write into a dirty tree. One line per step as km doctor
prints them; --quiet prints only what changed (done) or needs attention (note, FAIL). Exit 0 when
nothing was to do or everything that could be done was done, a branch behind included; 1 when
something failed (a FAIL line: no origin, no repository, a fast-forward, push or mount that failed).
An unreachable remote is no failure: the run compares with the last fetch. --max-age skips the run
while the last one (the stamp km-sync in the git dir, touched also when the network was not
there) is younger, so a hook costs nothing in between. --no-init only reports a mount that is not
checked out, with the command that checks it out (a clone can take long; the hook passes it). What
gh said about origin (a fork, or not) is kept in the git config key km.fork, so later runs do not
ask again; `git config --unset km.fork` asks afresh. Runs without PyYAML.
"""
from __future__ import annotations

import argparse
import dataclasses
import re
import sys
import time
from pathlib import Path

from km.paths import ahead_behind, git, git_path, repo_root, rev, submodule_config
from km.remotes import Upstream, find_upstream, first_line, gh, no_network, remote, shown

FETCH_TIMEOUT = 30                # seconds per fetch; a brain is small, a stall is not waited out
CLONE_TIMEOUT = 120               # the first checkout of a mounted brain is a clone, with history
STAMP = "km-sync"                 # in the git dir: when the last sync tried the network, also when it failed
AGE = re.compile(r"^(\d+)\s*([smhd]?)$")
UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
HELP = """\
bring this copy of the brain up to its upstream (the remote `upstream`, else the parent of a fork,
else origin), by fast-forward only:
  - the default branch, when it is checked out and the tree has no uncommitted changes;
  - a fork's default branch on the host (gh repo sync; a plain push only without gh; never a force);
  - the mounted brains, to the commit the brain pins when they are behind it (a pin never moves here).
A work branch, a dirty tree or a branch that diverged is reported, never rebased or reset."""
quiet = False
failed = False


def say(status: str, what: str) -> None:
    """One line per step, as km doctor prints them; with --quiet only what changed or needs attention."""
    global failed
    failed = failed or status == "FAIL"
    if not quiet:
        print(f"  {status:<5} {what}")
    elif status in ("done", "note", "FAIL"):
        print(f"km sync: {what}")


def parse_age(text: str) -> float:
    m = AGE.match(text.strip().lower())
    if not m:
        raise argparse.ArgumentTypeError(f"{text!r}: give a number with s, m, h or d, such as 15m")
    return int(m.group(1)) * UNITS[m.group(2)]


def commits(n: int) -> str:
    return f"{n} commit{'' if n == 1 else 's'}"


def upstream_remote(root: Path, up: Upstream) -> Upstream:
    """The upstream as a named remote: a parent gh found becomes the remote `upstream`, so later
    runs need no gh and its branch has a ref here."""
    if up.remote is not None:
        return up
    res = git("remote", "add", "upstream", up.url, cwd=root)
    if res.returncode != 0:
        say("FAIL", f"could not add the remote upstream for {shown(up.url)}: {first_line(res.stderr)}")
        return up
    say("done", f"added the remote upstream, the fork's parent: {shown(up.url)}")
    return dataclasses.replace(up, remote="upstream")


def remember_head(root: Path, up: Upstream) -> None:
    """Set the remote's HEAD ref to its default branch once it is fetched, so later runs (and km
    doctor) need not ask the host which branch that is."""
    if not git("symbolic-ref", "-q", f"refs/remotes/{up.remote}/HEAD", cwd=root).stdout.strip():
        git("remote", "set-head", up.remote, up.branch, cwd=root)


def fetch(root: Path, up: Upstream, offline: bool) -> tuple[Upstream, str, str, bool, str]:
    """Fetch origin and the upstream, unless offline. (the upstream, its default branch re-read when
    the host renamed it; its default-branch commit; the fork's default-branch commit as origin has
    it; whether the network was there; why the upstream's commit is the last fetched one rather
    than the host's, '' when it is the host's). A remote that did not answer is reported, and the
    last fetch stands in, which every later line says."""
    reached, stale = not offline, "offline" if offline else ""
    if not offline:
        code, _, err = remote("fetch", "--prune", "--no-recurse-submodules", "origin", cwd=root, timeout=FETCH_TIMEOUT)
        if code != 0:
            say("skip", f"origin cannot be reached ({first_line(err)}); comparing with the last fetch")
            reached = False
            if up.remote == "origin" or no_network(err):
                stale = f"fetch failed: {first_line(err)}"
        if up.remote != "origin" and (reached or not no_network(err)):   # no network: do not wait for the upstream too
            code, _, err = remote("fetch", "--prune", "--no-recurse-submodules", up.remote, cwd=root, timeout=FETCH_TIMEOUT)
            if code != 0:
                say("skip", f"upstream {shown(up.url)} cannot be reached ({first_line(err)}); comparing with the last fetch")
                reached, stale = False, f"fetch failed: {first_line(err)}"
        if reached and not rev(root, up.ref):     # the branch is gone from the host: renamed, so ask again
            remote("remote", "set-head", up.remote, "--auto", cwd=root)
            head = git("symbolic-ref", "-q", "--short", f"refs/remotes/{up.remote}/HEAD", cwd=root).stdout.strip()
            if head.startswith(up.remote + "/"):
                up = dataclasses.replace(up, branch=head[len(up.remote) + 1:])
    return up, rev(root, up.ref), rev(root, f"refs/remotes/origin/{up.branch}"), reached, stale


def sync_branch(root: Path, up: Upstream, theirs: str, stale: str) -> None:
    """Fast-forward the checked-out default branch to upstream's, or say why not. With `stale`,
    upstream's commit is the last fetched one, and every line says so."""
    where = f"the last fetched {up.remote} {up.branch} ({stale})" if stale else f"{up.remote} {up.branch}"
    branch = git("symbolic-ref", "-q", "--short", "HEAD", cwd=root).stdout.strip()
    head = rev(root, "HEAD")
    what = f"branch {branch}" if branch else "the detached HEAD"
    if (counts := ahead_behind(root, head, theirs) if head else None) is None:
        say("skip", f"{what} cannot be compared with {where} (nothing checked out?)")
        return
    ahead, behind = counts
    if not behind:
        say("ok", f"{what} has everything {where} has")
    elif not branch:
        say("note", f"{what} is {commits(behind)} behind {where}; `git switch {up.branch}` when you are ready")
    elif branch != up.branch:
        say("note", f"{what} is {commits(behind)} behind {where}; rebase it when you are ready")
    elif ahead:
        say("note", f"{branch} has {commits(ahead)} of its own and is {commits(behind)} behind {where}; "
                    f"rebase it when you are ready (`git rebase {up.remote}/{up.branch}`)")
    elif changed := git("status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all", cwd=root).stdout.splitlines():
        say("note", f"{branch} is {commits(behind)} behind {where}; commit or stash the {len(changed)} changed "
                    "file(s) first, then run km sync again")
    elif (res := git("merge", "--ff-only", "--no-edit", theirs, cwd=root)).returncode != 0:
        say("FAIL", f"{branch} could not be fast-forwarded: {first_line(res.stderr) or first_line(res.stdout)}")
    else:
        say("done", f"{branch} fast-forwarded {commits(behind)} to {where} ({head[:7]} -> {theirs[:7]})")


def sync_fork(root: Path, up: Upstream, theirs: str, mine: str, net: bool, stale: str = "") -> None:
    """Bring the fork's default branch on the host up to upstream's when that is a fast-forward."""
    where = f"your fork's {up.branch}"
    upstream = f"the last fetched upstream ({stale})" if stale else "upstream"
    if not mine:
        say("skip", f"{where}: not fetched yet")
        return
    if (counts := ahead_behind(root, mine, theirs)) is None:
        say("skip", f"{where} cannot be compared with upstream (not fetched)")
        return
    ahead, behind = counts
    if not behind:
        say("ok", f"{where} has everything {upstream} has")
    elif ahead:
        say("note", f"{where} and {upstream} {up.branch} have diverged: nothing done, that would need a force; "
                    "bring the fork's own commits in as a pull request, then sync again")
    elif not net:
        say("note", f"{where} is {commits(behind)} behind {upstream}; run km sync with the network to update it")
    elif up.fork and (code := gh("repo", "sync", up.fork, "--branch", up.branch)[0]) == 0:
        say("done", f"{where} updated on the host by {commits(behind)} (gh repo sync)")
    elif up.fork and code != -1:                    # gh is there and refused: it knows the fork, a push would not
        say("FAIL", f"{where} is {commits(behind)} behind upstream and gh could not sync it; `gh repo sync {up.fork}` says why")
    elif (res := remote("push", "origin", f"{theirs}:refs/heads/{up.branch}", cwd=root, timeout=FETCH_TIMEOUT))[0] != 0:
        say("FAIL", f"{where} is {commits(behind)} behind upstream and could not be pushed ({first_line(res[2])})")
    else:
        say("done", f"{where} updated on the host by {commits(behind)} (pushed upstream's commit)")


def sync_mounts(root: Path, net: bool, init: bool) -> None:
    """Every mounted brain at the commit the brain pins; one with changes of its own is left alone.
    Without `init` a mount that is not checked out is only named, with the command."""
    paths = list(submodule_config(root, "path").values()) if (root / ".gitmodules").is_file() else []
    if not paths:
        return
    pinned = {}                                   # mount -> the commit the brain pins: `160000 commit <sha>\t<path>`
    for rec in git("ls-tree", "-z", "HEAD", "--", *paths, cwd=root).stdout.split("\0"):
        info, _, path = rec.partition("\t")
        if info.startswith("160000 "):
            pinned[path] = info.split()[-1]
    for path, sha in pinned.items():
        sub = root / path
        there = (sub / ".git").exists()
        name = path.split("/")[-1]
        if there and git("status", "--porcelain", cwd=sub).stdout.strip():
            say("note", f"mounted {path} skipped: it has changes of its own (`brain reset {name}`)")
            continue
        if there and (branch := git("symbolic-ref", "-q", "--short", "HEAD", cwd=sub).stdout.strip()):
            say("note", f"mounted {path} skipped: it has the branch {branch} checked out (`brain reset {name}`)")
            continue
        head = rev(sub, "HEAD") if there else ""
        if head == sha:
            say("ok", f"mounted {path} is at the commit the brain pins")
            continue
        if head and (counts := ahead_behind(sub, head, sha)) and counts[0]:
            say("note", f"mounted {path} is {'ahead of' if not counts[1] else 'diverged from'} the commit the brain pins; "
                        f"left as it is: `brain reset {name}` puts it back, a pull request moves the pin")
            continue
        if not there and not init:
            say("note", f"mounted {path} is not checked out; `git submodule update --init --checkout \"{path}\"` "
                        "in the brain, or km sync without --no-init")
        elif not net:
            say("skip", f"mounted {path} is not at the commit the brain pins (offline)")
        elif (res := remote("submodule", "update", "--init", "--checkout", "--", path, cwd=root,
                            timeout=FETCH_TIMEOUT if there else CLONE_TIMEOUT))[0] != 0 or rev(sub, "HEAD") != sha:
            say("FAIL", f"mounted {path} could not be checked out ({first_line(res[2]) or 'not at the pin afterwards'}); "
                        f"`git submodule update --init --checkout \"{path}\"` in the brain shows more")
        else:
            say("done", f"mounted {path} checked out at the commit the brain pins ({sha[:7]})")


def main() -> int:
    global quiet
    ap = argparse.ArgumentParser(prog="km sync", formatter_class=argparse.RawDescriptionHelpFormatter, description=HELP,
                                 epilog="exit 0: nothing to do, or done, a branch behind included; 1: something failed "
                                        "(a FAIL line). An unreachable remote is no failure: the last fetch stands in. "
                                        "gh's answer whether origin is a fork is kept in git config km.fork "
                                        "(`git config --unset km.fork` asks again).")
    ap.add_argument("--quiet", action="store_true", help="print only what changed or needs attention")
    ap.add_argument("--offline", action="store_true", help="no network: compare with what was fetched last")
    ap.add_argument("--max-age", type=parse_age, metavar="AGE",
                    help="do nothing while the last sync is younger than AGE (15m, 1h, 90s)")
    ap.add_argument("--no-init", action="store_true", help="only name a mounted brain that is not checked out, do not clone it")
    args = ap.parse_args()
    quiet = args.quiet
    root = repo_root()
    if git("rev-parse", "--is-inside-work-tree", cwd=root).stdout.strip() != "true":
        say("FAIL", f"{root} is not a git repository")
        return 1
    stamp = git_path(root, STAMP)
    if args.max_age is not None and stamp.is_file() and (age := time.time() - stamp.stat().st_mtime) < args.max_age:
        if not quiet:
            print(f"km sync: synced {int(age // 60)} min ago, nothing done (--max-age)")
        return 0
    if not quiet:
        print(f"km sync: {root}")
    if above := git("rev-parse", "--show-superproject-working-tree", cwd=root).stdout.strip():
        say("skip", f"this is a brain mounted in {above}; km sync there keeps it at the commit that brain pins")
        return 0
    tried = stamp.touch if not args.offline else (lambda: None)   # a run that got as far as the network counts as a try
    up = find_upstream(root, args.offline, remember=True)
    if up is None:
        tried()
        say("skip", "no origin: nothing to sync from yet")
        return 0
    if not args.offline:                           # offline, gh is not asked, so the upstream is a remote already
        up = upstream_remote(root, up)
        if up.remote is None:
            tried()
            return 1
    up, theirs, mine, net, stale = fetch(root, up, args.offline)
    tried()                                        # after the fetch: a run cut short is not a sync
    if theirs:
        remember_head(root, up)
        sync_branch(root, up, theirs, stale)
        if up.fork is not None:
            sync_fork(root, up, theirs, mine, net, stale)
    else:
        say("skip", f"{up.remote} {up.branch}: nothing to compare with (not fetched)")
    sync_mounts(root, net, not args.no_init)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
