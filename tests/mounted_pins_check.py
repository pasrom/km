"""The commit selection and the resolve step of the bump-mounted-pins script a team brain gets
(src/km/templates/team/bump-mounted-pins.py), against a stand-in for the GitHub API.

    python3 tests/mounted_pins_check.py
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bump", REPO / "src/km/templates/team/bump-mounted-pins.py")
bump = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bump)
REAL_API = bump.api                    # the cases below replace bump.api with stand-ins

passed = failed = 0


def check(cond: bool, what: str, detail: object = "") -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok:   {what}")
    else:
        failed += 1
        print(f"  FAIL: {what} ({detail})")


def sha(name: str) -> str:
    """A 40-hex sha that shows its name: c1 -> c1c1c1..."""
    return (name.encode().hex() * 40)[:40]


class Fake:
    """One mounted repository: `commits` newest first, each `name` or `name:state`, where state is a
    comma list of conclusions, one per workflow, newest run first per workflow written `wf=a/b`
    (a the newest), each a push to `main` unless written `conclusion@ref`; no state: no run.
    `behind`: commits that are not ahead of the pin. `default`: the repository's default branch."""

    def __init__(self, commits: list[str], workflows: int = 1, behind: tuple[str, ...] = (), down: bool = False,
                 default: str = "main"):
        self.order, self.runs = [], {}
        for c in commits:
            name, _, state = c.partition(":")
            self.order.append(sha(name))
            runs = []
            for i, part in enumerate(filter(None, state.split(","))):
                wf, _, conc = part.rpartition("=")
                for x in conc.split("/"):
                    x, _, ref = x.partition("@")
                    runs.append({"workflow_id": wf or i, "conclusion": None if x == "running" else x, "head_branch": ref or "main"})
            self.runs[sha(name)] = runs
        self.workflows, self.behind, self.down = workflows, {sha(b) for b in behind}, down
        self.default = default
        self.branches: list[str | None] = []      # the branch each commit listing asked for, as sent

    def api(self, path: str, token: str, method: str = "GET", payload: dict | None = None):
        if self.down:
            raise bump.ApiError("HTTP 401", "Bad credentials")
        if path == "repos/o/r":
            return {"default_branch": self.default}
        if m := re.match(r"repos/o/r/commits\?(?:sha=([^&]+)&)?per_page=\d+$", path):
            self.branches.append(m.group(1))         # None: the default branch
            return [{"sha": s} for s in self.order]
        if m := re.match(r"repos/o/r/actions/runs\?head_sha=(\w+)(?:&branch=([^&]+))?&event=push", path):
            branch = m.group(2) and urllib.parse.unquote(m.group(2))     # no filter: runs of every ref
            return {"workflow_runs": [r for r in self.runs.get(m.group(1), []) if branch in (None, r["head_branch"])]}
        if path == "repos/o/r/actions/workflows?per_page=1":
            return {"total_count": self.workflows}
        if m := re.match(r"repos/o/r/compare/(\w+)\.\.\.(\w+)$", path):
            return {"status": "behind" if m.group(2) in self.behind else "ahead"}
        raise AssertionError(f"unexpected call {path}")


def pick(commits: list[str], pin: str | None, **kw) -> str:
    """The name of the commit chosen, 'none' when the pin stays, or 'error: ...'."""
    fake = Fake(commits, **kw)
    bump.api = fake.api
    try:
        got, _ = bump.newest_commit("o/r", "main", sha(pin) if pin else None, "t")
    except bump.ApiError as e:
        return f"error: {e.args[0]}"
    names = {sha(c.partition(":")[0]): c.partition(":")[0] for c in commits}
    return names.get(got, got) if got else "none"


CASES = [   # (what, commits newest first, pin, keyword args, expected)
    ("a green tip is taken", ["c2:success", "c1:success", "p:success"], "p", {}, "c2"),
    ("a bot tip on a green commit is taken", ["bot", "c1:success", "p:success"], "p", {}, "bot"),
    ("a bot tip directly on the pin is taken", ["bot", "p"], "p", {}, "bot"),
    ("a bot tip on a failed commit is refused, the green one below the failure is taken",
     ["bot", "c2:failure", "c1:success", "p"], "p", {}, "c1"),
    ("two bot commits on a failed commit are refused", ["bot2", "bot1", "c1:failure", "p"], "p", {}, "none"),
    ("an inner commit below a refused head stays refused", ["c2:failure", "inner", "p"], "p", {}, "none"),
    ("below a refused head and its inner commit, an older green commit is taken",
     ["c3:failure", "inner", "c1:success", "p"], "p", {}, "c1"),
    ("a candidate that is not ahead of the pin is skipped, not moved back",
     ["c2:success", "side:success", "p"], "p", {"behind": ("c2",)}, "side"),
    ("the newest run of a workflow counts: a success after a failure", ["c1:success/failure", "p"], "p", {}, "c1"),
    ("the newest run of a workflow counts: a failure after a success", ["c1:failure/success", "p"], "p", {}, "none"),
    ("a cancelled run refuses", ["c1:cancelled", "p"], "p", {}, "none"),
    ("a run still in progress refuses", ["c1:running", "p"], "p", {}, "none"),
    ("skipped and neutral runs count as green", ["c1:a=skipped,b=neutral", "p"], "p", {}, "c1"),
    ("one failed workflow of two refuses", ["c1:a=success,b=failure", "p"], "p", {}, "none"),
    ("a pin at the tip is up to date", ["p:success", "c0:success"], "p", {}, "none"),
    ("a pin beyond the window, a repository without workflows: its commits are green",
     ["c2", "c1"], "old", {"workflows": 0}, "c2"),
    ("a pin beyond the window, a repository with workflows and no runs: an error, not a guess",
     ["c2", "c1"], "old", {}, "error: no usable commit among the last 2 on main"),
    ("a pin beyond the window: a commit without runs inherits the nearest older run",
     ["bot", "c1:success"], "old", {}, "bot"),
    ("unpinned: the green tip is taken", ["c1:success"], None, {}, "c1"),
    ("unpinned, no run anywhere, workflows exist: an error", ["c1"], None, {}, "error: no usable commit among the last 1 on main"),
    ("a branch without commits is an error", [], "p", {}, "error: no commits on main"),
    ("a green run on a side branch is not CI of the tracked branch",
     ["m:running", "f:success@feature", "p:success"], "p", {}, "none"),
    ("a green run of a tag push does not hide a failed run of the branch", ["t:w=success@v1/failure", "p:success"], "p", {}, "none"),
]


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def resolve_cases(tmp: Path) -> None:
    """The resolve step in a brain with mounts: `good` moves, `new` (not pinned yet) gets its first pin,
    `bad` fails (401), `odd` gets an answer without the expected key, `else` is not on GitHub."""
    old = os.getcwd()
    os.environ["GITHUB_REPOSITORY"] = "Own/brain"
    try:
        empty = tmp / "empty"
        empty.mkdir()
        os.chdir(empty)
        git("init", "-q", cwd=empty)
        check(bump.submodules() == [], "without a .gitmodules there is nothing to move", bump.submodules())
        (empty / ".gitmodules").write_text("")
        check(bump.submodules() == [], "an empty .gitmodules (the last mount removed) is nothing to move, no crash", bump.submodules())

        b = tmp / "brain"
        b.mkdir()
        os.chdir(b)
        git("init", "-q", "-b", "main", cwd=b)
        (b / ".gitmodules").write_text(
            '[submodule "good"]\n\tpath = brains/good\n\turl = ../good.git\n\tignore = all\n'
            '[submodule "bad"]\n\tpath = brains/bad\n\turl = git@github.com:own/bad.git\n\tbranch = .\n'
            '[submodule "else"]\n\tpath = brains/else\n\turl = https://gitlab.com/x/else.git\n'
            '[submodule "new"]\n\tpath = brains/new\n\turl = ../new.git\n'
            '[submodule "new-again"]\n\tpath = brains/new-again\n\turl = ../new.git\n'
            '[submodule "odd"]\n\tpath = brains/odd\n\turl = ../odd.git\n\tbranch = main\n'
            '[submodule "other"]\n\tpath = brains/other\n\turl = ../../them/other.git\n')
        for path, pin in (("brains/good", "g0"), ("brains/bad", "b0"), ("brains/odd", "o0")):
            git("update-index", "--add", "--cacheinfo", f"160000,{sha(pin)},{path}", cwd=b)
        git("add", ".gitmodules", cwd=b)
        git("commit", "-q", "-m", "brain", cwd=b)
        subs = {s["name"]: s for s in bump.submodules()}
        check([subs["good"]["slug"], subs["bad"]["slug"], subs["bad"]["branch"], subs["good"]["branch"], subs["else"]["slug"], subs["other"]["slug"]]
              == ["Own/good", "own/bad", "main", None, None, "them/other"],
              "slugs: ../x is a sibling under the brain's owner, ../../o/x another owner's, ssh URLs parse, "
              "`branch = .` is main, no branch is the default branch, another host has none", subs)
        out = subprocess.run([sys.executable, str(REPO / "src/km/templates/team/bump-mounted-pins.py"), "--list-repos", "own"],
                             cwd=b, capture_output=True, text=True)
        check(out.stdout.strip() == "good,bad,new,odd", "--list-repos names the mounts of the owner, in any case", out.stdout + out.stderr)

        (b / ".gitmodules").write_text((b / ".gitmodules").read_text().split('[submodule "other"]')[0])
        git("add", ".gitmodules", cwd=b)
        git("commit", "-q", "-m", "drop other", cwd=b)
        fakes = {"Own/good": Fake(["g1:w=success@trunk/failure@main", "g0:success@trunk"], default="trunk"), "Own/new": Fake(["n1:success"])}

        def api(path, token, method="GET", payload=None):   # bad is refused, odd answers without workflow_runs
            slug = "/".join(path.split("/")[1:3])
            if slug == "Own/odd":
                return [{"sha": sha("o1")}, {"sha": sha("o0")}] if "/commits?" in path else {}
            if slug not in fakes:
                raise bump.ApiError("HTTP 401", "Bad credentials")
            return fakes[slug].api(path.replace(slug, "o/r", 1), token)
        bump.api = api
        msg, body = tmp / "msg", tmp / "body"
        rc = bump.resolve(SimpleNamespace(write=True, emit_message=str(msg), emit_body=str(body), hold_if_moved=None), "t")
        staged = dict(reversed(ln.split()[1:4:2]) for ln in git("ls-files", "-s", "brains", cwd=b).splitlines())
        text = body.read_text(encoding="utf-8")
        check(rc == 1, "a mount that cannot be resolved fails the run", rc)
        check(staged.get("brains/good") == sha("g1"), "the other mounts still move", staged)
        check(staged.get("brains/new") == sha("n1"), "a mount not pinned yet gets its first pin", staged)
        check(staged.get("brains/odd") == sha("o0") and "odd: KeyError" in text, "an unexpected answer fails that mount only", text)
        check(staged.get("brains/bad") == sha("b0"), "the failed mount stays at main's pin", staged)
        check(not re.search(r"[0-9a-f]{40}", text + msg.read_text(encoding="utf-8")) and f"`{sha('g1')[:8]}`" in text,
              "the body and the message carry short shas only", text)
        check("bad: HTTP 401" in text and "else: no path or no GitHub url" in text, "the body names what did not move", text)
        check("--keep-from" not in REPO.joinpath("src/km/templates/team/bump-mounted-pins.py").read_text(encoding="utf-8"),
              "nothing is carried over from the pull request branch", "")
        failed_diff = subprocess.run(["git", "diff", "--cached", "--quiet", "HEAD", "--", "brains/good"], cwd=b).returncode
        none_diff = subprocess.run(["git", "diff", "--cached", "--quiet", "--ignore-submodules=none", "HEAD", "--", "brains/good"], cwd=b).returncode
        check(failed_diff == 0 and none_diff == 1, "with `ignore = all` only --ignore-submodules=none sees the moved gitlink",
              (failed_diff, none_diff))
        def held(change: str) -> bool:
            """Build a bump commit on main changing `change` (path=pin), then main moves bad by hand;
            resolve with --hold-if-moved on that commit: True when it wrote nothing."""
            git("reset", "-q", "--hard", "HEAD", cwd=b)
            base = git("rev-parse", "HEAD", cwd=b)
            path, pin = change.split("=")
            git("update-index", "--add", "--cacheinfo", f"160000,{sha(pin)},{path}", cwd=b)
            git("commit", "-q", "-m", "bump", cwd=b)
            git("update-ref", "refs/bump/proposed", "HEAD", cwd=b)
            git("reset", "-q", "--hard", base, cwd=b)
            git("update-index", "--cacheinfo", f"160000,{sha('b5')},brains/bad", cwd=b)    # by hand on main
            git("commit", "-q", "-m", "by hand", cwd=b)
            msg.unlink(missing_ok=True)
            args = SimpleNamespace(write=True, emit_message=str(msg), emit_body=str(body), hold_if_moved="refs/bump/proposed")
            rc = bump.resolve(args, "t")
            git("reset", "-q", "--hard", base, cwd=b)
            return rc == 1 and not msg.exists()
        check(held("brains/bad=b1"), "a failing mount the open pull request moves: nothing is written", "")
        check(not held("brains/good=g1"), "a failing mount the pull request does not move (main moved it since) holds nothing back", "")
        check(set(fakes["Own/good"].branches) == {None}, "a mount without a branch line lists its default branch, and its runs count",
              fakes["Own/good"].branches)
    finally:
        os.chdir(old)


def api_errors() -> None:
    """An answer that is not JSON, or a connection dropped mid-read, fails the call as ApiError (one
    mount), not with a traceback that stops every mount."""
    import http.client
    import io
    real = bump.urllib.request.urlopen
    for what, answer in (("an answer that is not JSON", lambda *a, **k: io.BytesIO(b"<html>")),
                         ("a connection dropped mid-read", lambda *a, **k: (_ for _ in ()).throw(http.client.RemoteDisconnected("x")))):
        bump.urllib.request.urlopen = answer
        try:
            REAL_API("repos/o/r", "t")
            got = "no error"
        except bump.ApiError as e:
            got = "ApiError"
        except Exception as e:                                     # noqa: BLE001
            got = type(e).__name__
        finally:
            bump.urllib.request.urlopen = real
        check(got == "ApiError", f"{what} is an ApiError", got)


def branch_head_cases(tmp: Path) -> None:
    """--branch-prs takes a head a pull request was opened for as current only while it is one
    commit on main that changes gitlinks and nothing else; branch names are sent quoted."""
    import contextlib
    import io
    old, old_repo, old_api = os.getcwd(), os.environ.get("GITHUB_REPOSITORY"), bump.api
    os.environ["GITHUB_REPOSITORY"] = "own/brain"
    os.chdir(tmp)
    (tmp / ".gitmodules").write_text('[submodule "m"]\n\tpath = brains/m\n\turl = ../m.git\n')
    try:
        for what, ahead, files, want in (
                ("a head that only moves gitlinks is current", 1, ["brains/m"], "true true"),
                ("a head that also changes another file is regenerated", 1, ["brains/m", "README.md"], "true false"),
                ("a branch with a commit pushed below the head is regenerated", 2, ["brains/m"], "true false"),
                ("a compare answer without its files is not taken as gitlinks only", 1, [], "true false")):
            calls = []

            def api(path, token, method="GET", payload=None):
                calls.append(path)
                if path.startswith("repos/own/brain/pulls?"):
                    return [{"state": "open", "head": {"sha": "h"}}]
                if path == "repos/own/brain/compare/main...h":
                    return {"ahead_by": ahead, "files": [{"filename": f} for f in files]}
                raise AssertionError(path)
            bump.api = api
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                bump.report_branch_prs("chore/bump-mounted-pins", "h", "t")
            check(out.getvalue().split() == want.split(), what, out.getvalue())
        check("head=own%3Achore%2Fbump-mounted-pins&" in calls[0], "the branch is sent quoted", calls[0])
        fake = Fake(["c1:success@rel/1.x", "p:success@rel/1.x"])
        bump.api = fake.api
        got, _ = bump.newest_commit("o/r", "rel/1.x", sha("p"), "t")
        check(got == sha("c1") and fake.branches == ["rel%2F1.x"], "a branch name with a slash is sent quoted and its runs count",
              (got, fake.branches))
    finally:
        os.chdir(old)
        bump.api = old_api
        if old_repo is None:
            os.environ.pop("GITHUB_REPOSITORY", None)
        else:
            os.environ["GITHUB_REPOSITORY"] = old_repo


def main() -> int:
    for what, commits, pin, kw, want in CASES:
        got = pick(commits, pin, **kw)
        check(got == want, what, f"got {got}, want {want}")
    api_errors()
    with tempfile.TemporaryDirectory() as tmp:
        resolve_cases(Path(tmp))
    with tempfile.TemporaryDirectory() as tmp:
        branch_head_cases(Path(tmp))
    print(f"mounted_pins: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
