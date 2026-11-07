#!/usr/bin/env python3
"""Move the gitlinks of the mounted repositories to the newest commit of their branch.

Written by `km init --team` for the bump-mounted-pins workflow. `km upgrade` replaces it while it is
a version km shipped, unchanged; once this repo edits it, it is this repo's and upgrade leaves it. Standard library only, so the job holding the app token installs nothing.

    python3 .github/scripts/bump-mounted-pins.py            # show what would change
    python3 .github/scripts/bump-mounted-pins.py --write    # move the gitlinks in the index
    python3 .github/scripts/bump-mounted-pins.py --list-repos OWNER        # mounted repositories of OWNER
    python3 .github/scripts/bump-mounted-pins.py --branch-prs BRANCH SHA   # pull requests of the branch
    BODY=... python3 .github/scripts/bump-mounted-pins.py --open-pr BRANCH

    --emit-message FILE  write a commit message for the change (only when something moves)
    --emit-body FILE     write a pull-request body for it (only when something moves)
    --hold-if-moved REF  write nothing when a submodule that fails is one REF's commit moves (the
                         open pull request's branch: its move would be lost over a passing failure)

Every submodule in .gitmodules is read at run time: its path, its repository (a GitHub URL, or a
URL relative to this repository's own, `../name.git` or `../../owner/name.git`) and its tracked
branch (`branch =`, `.` for main, else the mounted repository's default branch). Nothing is cloned; without a .gitmodules there is nothing to do. The new commit is set in the index with
`git update-index --add --cacheinfo 160000,<sha>,<path>`, so the working tree is not touched.

Which commit: walking back from the branch tip, the newest commit whose CI did not fail. Per
workflow the newest push run of that commit counts; a failed or still running one refuses the
commit. A commit with no push run at all (a workflow that commits with GITHUB_TOKEN starts no run)
inherits the state of the nearest older commit that has runs, or of the current pin, and is taken
only if that is green and no newer commit was refused. A pin never moves to a commit that is not
ahead of it.

Only the submodule name and the old and new short sha are reported: not every reader of this
repository reads the mounted ones, so no commit message, workflow name or compare link goes into
the log, the commit message or the pull request.

Access: resolving reads the mounted repositories with GH_PIN_TOKEN (read-only), or with the gh
CLI's token when it is unset. --branch-prs reads and --open-pr writes this repository with GH_TOKEN.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import pathlib
import re
import http.client
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

# One page of the commit list. Long enough that a pin left behind by a pull request open for weeks
# is still in it, so a commit without runs can inherit from it.
CANDIDATES = 100
SUBJECT = "chore(brains): move the mounted pins to the newest commits"


class ApiError(Exception):
    pass


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def api(path: str, token: str, method: str = "GET", payload: dict | None = None):
    """Call the GitHub REST API and return the decoded JSON (None for an empty answer)."""
    request = urllib.request.Request(
        f"https://api.github.com/{path}", method=method,
        data=json.dumps(payload).encode() if payload else None,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "bump-mounted-pins",
        })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        # 401, 403 and 404 are an expired token, a missing grant and a renamed repository: say
        # which, rather than reporting every failure the same way.
        raise ApiError(f"HTTP {error.code}", error.read().decode(errors="replace")) from None
    except (OSError, ValueError, http.client.HTTPException) as error:
        # no connection, a timeout, a dropped read, an answer that is not JSON: this mount fails
        raise ApiError(type(error).__name__) from None


def submodules() -> list[dict]:
    """name, path, slug and branch of every submodule in .gitmodules, in file order."""
    if not pathlib.Path(".gitmodules").is_file():
        return []
    found: dict[str, dict] = {}
    owner = os.environ.get("GITHUB_REPOSITORY", "").partition("/")[0]
    # exit 1: no such key, as in a .gitmodules left empty by removing the last mount
    listed = subprocess.run(["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.(path|url|branch)$"],
                            capture_output=True, text=True)
    if listed.returncode not in (0, 1):
        raise subprocess.CalledProcessError(listed.returncode, listed.args, listed.stdout, listed.stderr)
    for line in listed.stdout.splitlines():
        key, value = line.split(" ", 1)
        name, field = key[len("submodule."):].rsplit(".", 1)
        found.setdefault(name, {"name": name, "branch": None})[field] = value
    for entry in found.values():
        if entry["branch"] == ".":         # "the superproject's branch": main here
            entry["branch"] = "main"
        url = entry.get("url", "")
        m = re.search(r"github\.com[/:]([^/]+/[^/]+?)(?:\.git)?/?$", url)
        # ../name: a sibling of this repository, under the same owner; ../../owner/name: another owner
        sibling = re.fullmatch(r"\.\./([^/]+?)(?:\.git)?/?", url)
        other = re.fullmatch(r"\.\./\.\./([^/]+/[^/]+?)(?:\.git)?/?", url)
        entry["slug"] = (m.group(1) if m else other.group(1) if other
                         else f"{owner}/{sibling.group(1)}" if sibling and owner else None)
    return list(found.values())


def q(value: str) -> str:
    """A branch name as one query value."""
    return urllib.parse.quote(value, safe="")


def ci_state(slug: str, sha: str, branch: str, token: str) -> str:
    """"green", "red" (the newest push run of a workflow failed or is still running) or "none".
    Only runs of a push to `branch` count: a run on a side branch or a tag is not CI of this branch."""
    runs = api(f"repos/{slug}/actions/runs?head_sha={sha}&branch={q(branch)}&event=push&per_page=50", token)["workflow_runs"]
    newest: dict[int, dict] = {}
    for run in runs:                       # newest first, so the first run per workflow counts
        newest.setdefault(run["workflow_id"], run)
    if not newest:
        return "none"
    return "red" if any(r["conclusion"] not in ("success", "skipped", "neutral") for r in newest.values()) else "green"


def newest_commit(slug: str, branch: str | None, current: str | None, token: str) -> tuple[str | None, str]:
    """(sha, why) of the newest pinnable commit on `branch` (None: the default branch), sha None
    when the pin is up to date; raise ApiError when there is none."""
    commits = api(f"repos/{slug}/commits?{f'sha={q(branch)}&' if branch else ''}per_page={CANDIDATES}", token)
    # The default branch's name, for the runs, only when a run is looked up.
    tracked = (lambda: branch) if branch else functools.cache(lambda: api(f"repos/{slug}", token)["default_branch"])
    label = branch or "the default branch"
    if not commits:
        raise ApiError(f"no commits on {label}")
    tip = commits[0]["sha"]
    shas = [c["sha"] for c in commits]
    pin_in_window = current in shas
    if pin_in_window:
        shas = shas[:shas.index(current)]
        if not shas:
            return None, "up to date"
    # Below the window: the current pin was accepted when it was set; else looked up when needed.
    below = "green" if pin_in_window else None
    state = functools.cache(lambda sha: ci_state(slug, sha, tracked(), token))
    no_workflows = functools.cache(
        lambda: api(f"repos/{slug}/actions/workflows?per_page=1", token)["total_count"] == 0)

    def inherited(i: int) -> str:
        """A commit without a run of its own inherits the state of the nearest older commit that has
        one: a bot commit on top of a failed push sits on a tree CI never passed."""
        found = next((s for s in map(state, shas[i + 1:]) if s != "none"), None)
        if found or below:
            return found or below
        # The window ends before the pin. Without an older run to inherit from, only a repository
        # with no workflow at all counts as green.
        return "green" if no_workflows() else "none"

    # Nor is it taken below a refused commit: there sit the inner commits of the same push, which CI
    # never built on their own.
    refused = False
    for i, sha in enumerate(shas):
        own = state(sha)
        if own == "red" or own == "none" and (refused or inherited(i) != "green"):
            refused = True
            continue
        # The list is in date order, not ancestry order: a commit from a merged side branch can be
        # older than the pin. Skip it rather than move back.
        if current and api(f"repos/{slug}/compare/{current}...{sha}", token)["status"] != "ahead":
            continue
        return sha, "tip" if sha == tip else f"behind the tip {tip[:8]}, which was refused"
    if pin_in_window:
        return None, "no newer commit can be pinned"
    raise ApiError(f"no usable commit among the last {len(commits)} on {label}")


def gitlink(ref: str, path: str) -> str | None:
    """The commit `ref` pins at `path`, None when it pins none there."""
    entry = git("ls-tree", ref, "--", path).split()
    return entry[2] if entry and entry[0] == "160000" else None


def moves(ref: str, path: str) -> bool:
    """Does `ref`'s commit change the gitlink at `path`? Compared with its parent, the main it was
    built on, not with main now, which may have moved the mount since. True when that is unknown."""
    try:
        return gitlink(ref, path) != gitlink(f"{ref}^", path)
    except subprocess.CalledProcessError:
        return True


def resolve(args, token: str) -> int:
    report: list[str] = []
    moved: list[str] = []
    problems: list[str] = []
    held: list[str] = []                   # failed mounts the open pull request moves
    for sub in submodules():
        name, path = sub["name"], sub.get("path")
        current = None
        try:
            if not path or not sub["slug"]:
                raise ApiError("no path or no GitHub url in .gitmodules")
            current = gitlink("HEAD", path)
            sha, why = newest_commit(sub["slug"], sub["branch"], current, token)
        except (ApiError, KeyError, TypeError, subprocess.CalledProcessError) as error:
            # One mount that cannot be resolved, whatever the reason, does not hold back the others.
            why = error.args[0] if isinstance(error, ApiError) else f"{type(error).__name__}: {error}"
            problems.append(f"{name}: {why}")
            report.append(f"{name}: PROBLEM, {why}")
            # It stays at main's pin. Nothing is carried over from the pull request branch: anyone
            # who can push there could plant a pin the workflow would then commit as its own.
            if path and args.hold_if_moved and moves(args.hold_if_moved, path):
                held.append(name)
            continue
        was = current[:8] if current else "unpinned"
        if sha is None:
            report.append(f"{name}: {was} {why}")
            continue
        report.append(f"{name}: {was} -> {sha[:8]} ({why})")
        moved.append(f"| {name} | `{was}` | `{sha[:8]}` |")
        if args.write:
            git("update-index", "--add", "--cacheinfo", f"160000,{sha},{path}")   # --add: a mount not pinned yet
    print("\n".join(report))
    if held:
        # Pushing now would drop their proposed move over what may be a passing failure, and the
        # next run would put it back: nothing is written, the pull request stays as it is.
        print(f"The open pull request moves {', '.join(held)}, which could not be resolved: it is left as it is.")
        moved = []

    if moved and args.emit_message:
        pathlib.Path(args.emit_message).write_text(
            SUBJECT + "\n\n" + "\n".join(report) + "\n",
            encoding="utf-8")
    if moved and args.emit_body:
        pathlib.Path(args.emit_body).write_text(
            "Moves the mounted repositories to the newest commit of their tracked branch whose CI did not fail. Generated by the bump-mounted-pins workflow; the branch is regenerated on each run.\n\n"
            "| Submodule | From | To |\n|---|---|---|\n" + "\n".join(moved) + "\n\n"
            + ("Not moved:\n\n" + "\n".join(f"- {p}" for p in problems) + "\n\n" if problems else "")
            + "Only the short shas are listed on purpose: not every reader of this repository reads the mounted ones.\n",
            encoding="utf-8")
    if problems:
        print(f"{len(problems)} submodule(s) could not be resolved.", file=sys.stderr)
    return 1 if problems else 0


def list_repos(owner: str) -> int:
    """Print the names of the mounted repositories of `owner`, comma-separated."""
    print(",".join(dict.fromkeys(sub["slug"].split("/")[1] for sub in submodules()
                                 if sub["slug"] and sub["slug"].split("/")[0].lower() == owner.lower())))
    return 0


def branch_prs(repo: str, branch: str, token: str, state: str) -> list[dict]:
    return api(f"repos/{repo}/pulls?head={q(repo.split('/')[0] + ':' + branch)}&state={state}&per_page=100", token)


def report_branch_prs(branch: str, sha: str, token: str) -> int:
    """Print two words, true or false: is a pull request of the branch open, and has one, open or
    closed, `sha` as its head while `sha` is what this workflow pushes: one commit on main that
    changes the submodule gitlinks and nothing else. A branch someone pushed more onto is not taken
    as current, so the next push regenerates it."""
    repo = os.environ["GITHUB_REPOSITORY"]
    prs = branch_prs(repo, branch, token, "all")
    is_open = any(p["state"] == "open" for p in prs)
    seen = any(p["head"]["sha"] == sha for p in prs)
    if seen:
        diff = api(f"repos/{repo}/compare/main...{sha}", token)
        paths = {sub.get("path") for sub in submodules()}
        files = diff.get("files") or []          # none listed: not known to be gitlinks only
        seen = diff["ahead_by"] == 1 and bool(files) and all(f["filename"] in paths for f in files)
    print(str(is_open).lower(), str(seen).lower())
    return 0


def open_pr(args, token: str) -> int:
    """Open or update the pull request, dispatch ci.yml."""
    repo = os.environ["GITHUB_REPOSITORY"]
    body = os.environ["BODY"]
    open_prs = branch_prs(repo, args.open_pr, token, "open")
    if open_prs:
        # The branch moved, so the description moves with it; otherwise it keeps describing the
        # first day's pins.
        number = open_prs[0]["number"]
        api(f"repos/{repo}/pulls/{number}", token, "PATCH", {"body": body})
        print(f"Pull request #{number} updated.")
    else:
        created = api(f"repos/{repo}/pulls", token, "POST", {
            "title": SUBJECT,
            "head": args.open_pr, "base": "main", "body": body})
        print("opened", created["html_url"])

    # workflow_dispatch is the one trigger GITHUB_TOKEN may start, and a dispatched run on the branch
    # shows up on the pull request. km's ci.yml has the trigger; a ci.yml without it gets a 422, and
    # the pull request then shows no check.
    try:
        api(f"repos/{repo}/actions/workflows/ci.yml/dispatches", token, "POST", {"ref": args.open_pr})
        print("ci.yml dispatched on", args.open_pr)
    except ApiError as error:
        if "workflow_dispatch" not in (error.args[1:] or [""])[0]:
            raise
        print("::notice::ci.yml has no workflow_dispatch trigger, so it does not run on the pull request")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Move the mounted repositories' gitlinks forward.")
    ap.add_argument("--write", action="store_true", help="move the gitlinks in the index")
    ap.add_argument("--emit-message", metavar="FILE", help="write a commit message here")
    ap.add_argument("--emit-body", metavar="FILE", help="write a pull-request body here")
    ap.add_argument("--hold-if-moved", metavar="REF",
                    help="write nothing when a submodule that could not be resolved is one REF's head commit moves")
    ap.add_argument("--open-pr", metavar="BRANCH",
                    help="open or update the pull request for BRANCH, with the body in $BODY")
    ap.add_argument("--list-repos", metavar="OWNER", help="print OWNER's mounted repositories")
    ap.add_argument("--branch-prs", nargs=2, metavar=("BRANCH", "SHA"),
                    help="print whether BRANCH has an open pull request and one with head SHA")
    args = ap.parse_args()
    try:
        if args.open_pr:
            return open_pr(args, os.environ["GH_TOKEN"])
        if args.list_repos:
            return list_repos(args.list_repos)
        if args.branch_prs:
            return report_branch_prs(*args.branch_prs, os.environ["GH_TOKEN"])
        token = os.environ.get("GH_PIN_TOKEN") or git_token()
        return resolve(args, token)
    except ApiError as error:
        print(f"GitHub API: {' '.join(error.args)}", file=sys.stderr)
        return 1


def git_token() -> str:
    """The gh CLI's token, for a run on a workstation."""
    return subprocess.run(["gh", "auth", "token"], check=True, capture_output=True, text=True).stdout.strip()


if __name__ == "__main__":
    sys.exit(main())
