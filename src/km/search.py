"""`km search TERM...`: search the merged docs and the open pull requests of the brain and of every
mounted brain, and say per brain what was searched.

A question to a brain starts here, so that no brain's docs or open pull requests go unsearched
without saying so: each brain in scope gets a coverage line, `searched`, `PARTIAL` or `NOT SEARCHED`
with the reason, for its docs and for its pull requests. It is a floor, not the whole search: the
hits are where reading starts.

Docs: the tracked Markdown files of each brain's working tree (`git ls-files`), their text and their
paths, matched case-insensitively (str.casefold, so GRÖSSE finds Größe) on any term; a mount's hit is
cited `[<name>@<sha7>] <path>` at its checked-out commit. A mount that is not checked out or left
out here is NOT SEARCHED. Mounts are the .gitmodules paths under brains/ that HEAD holds as gitlinks
and whose every part is a plain name; any other entry is ignored and counted in a note.

Pull requests: the open ones of each brain's GitHub repository, their titles, bodies, changed paths
and added lines, read with gh. A brain copy's repository is its `upstream` remote, else its origin, or
the parent where origin is a fork: `km.fork` (written by km doctor and km sync) or this command's
cache says so, else one gh call asks; if that call fails the pull requests are NOT SEARCHED rather
than taken from a fork. Diffs are kept by head commit and base in km-search/ under the repository's
common git dir (shared by its worktrees), so an unchanged pull request is not fetched again; the
files of pull requests no longer open are removed. The whole pull request part has a time budget
(BUDGET); after a timeout, HTTP 403 or 429 the rest of that repository is left unread and named.
Comments are not searched.

Text from git, .gitmodules and GitHub is printed through cut(), and every hit line starts with
`docs `, `pr   ` or an indent, so none can pass for a coverage line.

Exit 0: hits, coverage complete; 1: no hits, coverage complete; 3: coverage incomplete (any NOT
SEARCHED, PARTIAL or --no-prs) or an internal error, with or without hits; 2: usage error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from km.paths import git, left_out, printable, repo_root, submodule_config
from km.remotes import SHA, first_line, gh_run, github_repo, json_lines, resolve_url, shown

CUT = 200                         # characters of any line from git or GitHub
LINES_PER_FILE = 3
LIST_TIMEOUT = 60                 # seconds for the paginated list of open pull requests
DIFF_TIMEOUT = 60
PROBE_TIMEOUT = 15
BUDGET = float(os.environ.get("KM_SEARCH_BUDGET") or 90)   # seconds for the whole pull request part
WORKERS = 8
FILES_CAP = 3000                  # GitHub lists at most this many files of a pull request
MAX_DOC = 4_000_000               # bytes of a doc read; a longer one is read that far
TMP_AGE = 3600                    # seconds after which a left-over .tmp- file in the cache is removed
NAME = re.compile(r"[A-Za-z0-9_.-]+")
FM = re.compile(r"\A﻿?---\r?\n(.*?)\r?\n---\s*$", re.S | re.M)
STATUS = re.compile(r"^status:\s*[\"']?([\w-]+)", re.M)
OLD = {"obsolete", "superseded"}
UNSAFE_CATEGORIES = {"Cc", "Cf", "Zl", "Zp"}


def cut(text: str) -> str:
    """Untrusted text fit for one output line, at most CUT characters: printable(), and every other
    control or format character (C1 controls such as NEL, the line and paragraph separators U+2028 and
    U+2029, bidi overrides), which a terminal or a model may read as a line break, becomes `?` too."""
    text = "".join("?" if unicodedata.category(c) in UNSAFE_CATEGORIES else c for c in printable(text.strip()))
    return text if len(text) <= CUT else text[:CUT - 3] + "..."


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def matches(text: str, terms: list[str]) -> bool:
    low = text.casefold()
    return any(t in low for t in terms)


@dataclass
class Brain:
    path: str                     # "." or the mount's path, as .gitmodules names it
    name: str                     # "." or the mount's path under brains/
    module: str = ""              # the submodule's name in .gitmodules ('' for the brain itself)
    in_scope: bool = True
    repo: tuple[str, str] | None = None
    docs: dict = field(default_factory=lambda: {"state": "not searched", "reason": "", "files": 0, "hits": []})
    prs: dict = field(default_factory=lambda: {"state": "not searched", "reason": "", "open": 0, "read": 0,
                                               "unread": [], "hits": []})
    note: str = ""                # a mount checked out at another commit than the brain pins
    pulls: list = field(default_factory=list)


# --- docs -------------------------------------------------------------------------------------------

def read_doc(path: Path) -> str | None:
    """A doc's text, or None where it is missing, unreadable or binary (a NUL byte)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_DOC)
    except OSError:
        return None
    return None if b"\0" in data else data.decode("utf-8", errors="replace")


def status_of(text: str) -> str:
    m = FM.match(text[:65536])
    s = STATUS.search(m.group(1)) if m else None
    return s.group(1) if s else ""


def search_docs(b: Brain, root: Path, terms: list[str]) -> None:
    d = root if b.path == "." else root / b.path
    cite = ""
    if b.path != ".":
        if why := left_out(root, b.module):
            b.docs["reason"] = f"left out here: {why}"
            return
        if not (d / ".git").exists():     # an empty mount: git -C there would answer for the brain itself
            b.docs["reason"] = "not checked out; run km sync"
            return
        head = git("rev-parse", "HEAD", cwd=d).stdout.strip()
        pin = git("ls-tree", "HEAD", "--", b.path, cwd=root).stdout.split()
        pinned = pin[2] if len(pin) >= 3 and pin[1] == "commit" else ""
        if pinned and head and pinned != head:
            b.note = f"checked out at {head[:7]}, the brain pins {pinned[:7]}"
        cite = f"[{b.name}@{head[:7]}] "
    res = git("ls-files", "-z", "--", "*.md", cwd=d)    # never recurses into a mount (no --recurse-submodules)
    if res.returncode:
        b.docs["reason"] = f"git ls-files failed: {cut(first_line(res.stderr))}"
        return
    hits, n = [], 0
    for p in sorted(x for x in res.stdout.split("\0") if x):
        text = read_doc(d / p)
        if text is None:                  # tracked but missing here, unreadable or binary: not counted
            continue
        n += 1
        lines = [(i, ln.rstrip("\r")) for i, ln in enumerate(text.split("\n"), 1) if matches(ln, terms)]
        if lines or matches(p, terms):
            hits.append({"path": p, "cite": cite + p, "status": status_of(text), "path_match": matches(p, terms),
                         "lines": [{"line": i, "text": ln} for i, ln in lines[:LINES_PER_FILE]]})
    hits.sort(key=lambda h: h["status"] in OLD)     # stable: path order within each group
    b.docs.update(state="searched", files=n, hits=hits)


# --- which repository ---------------------------------------------------------------------------------

def gh_call(*args: str, timeout: float) -> tuple[bytes | None, str]:
    """(stdout, '') or (None, why it failed): `gh: HTTP <code>`, for 403 and 429 with gh's first line
    (a rate limit and a missing access read alike otherwise)."""
    if timeout <= 0:
        return None, "timed out"
    res = gh_run(*args, timeout=timeout)
    if res is None:
        return None, "gh not installed" if not shutil.which("gh") else "timed out"
    if res.returncode:
        err = res.stderr.decode("utf-8", errors="replace")
        m = re.search(r"\(HTTP (\d{3})\)", err)
        if m and m.group(1) in ("403", "429"):
            return None, f"gh: HTTP {m.group(1)} ({cut(first_line(err))})"
        return None, f"gh: HTTP {m.group(1)}" if m else f"gh: {cut(first_line(err))}"
    return res.stdout, ""


class Resolver:
    """The GitHub repository whose open pull requests are a brain's: see the module doc."""

    def __init__(self, cache: Path):
        self.file = cache / "forks.json"
        try:
            self.forks = json.loads(self.file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.forks = {}
        if not isinstance(self.forks, dict):
            self.forks = {}

    def parent(self, origin: str, repo: tuple[str, str], fork_config: str = "") -> tuple[tuple[str, str] | None, str]:
        """(the repository to search, '') for a GitHub origin: its parent where it is a fork, else itself;
        (None, why) where that could not be asked."""
        if fork_config == f"false {origin}":
            return repo, ""
        key = "/".join(repo)
        if not isinstance(self.forks.get(key), str):
            out, why = gh_call("api", "--hostname", "github.com", f"repos/{key}", "--jq",
                               '[.fork, .parent.full_name // ""] | @tsv', timeout=PROBE_TIMEOUT)
            fork, _, parent = (out or b"").decode("utf-8", errors="replace").strip().partition("\t")
            if out is None or fork not in ("true", "false"):
                return None, f"could not ask whether {key} is a fork: {why or 'unreadable answer'}"
            self.forks[key] = parent if fork == "true" else ""
            write_atomic(self.file, json.dumps(self.forks, indent=1, sort_keys=True).encode("utf-8"))
        parent = self.forks[key]
        if not parent:
            return repo, ""
        owner, _, name = parent.partition("/")
        return ((owner, name), "") if NAME.fullmatch(owner) and NAME.fullmatch(name) else (None, "a fork whose parent has no plain name")

    def of_url(self, url: str, d: Path | None) -> tuple[tuple[str, str] | None, str, str]:
        """(repository, why not, its url for resolving a relative mount url) of a remote url; `d` is the
        repository it is the origin of, whose `km.fork` is read."""
        if not url:
            return None, "no origin remote", ""
        repo = github_repo(url)
        if repo is None:
            return None, f"not on github.com: {cut(shown(url))}", url
        if not all(NAME.fullmatch(x) for x in repo):
            return None, "not a GitHub repository name", url
        config = git("config", "--get", "km.fork", cwd=d).stdout.strip() if d else ""
        got, why = self.parent(url, repo, config)
        if got is None:
            return None, why, ""
        return got, "", url if got == repo else f"https://github.com/{got[0]}/{got[1]}.git"

    def of_dir(self, d: Path) -> tuple[tuple[str, str] | None, str, str]:
        """The same for a checked-out repository: its `upstream` remote if it has one, else its origin."""
        if up := git("remote", "get-url", "upstream", cwd=d).stdout.strip():
            repo = github_repo(up)
            if repo is None or not all(NAME.fullmatch(x) for x in repo):
                return None, f"not on github.com: {cut(shown(up))}", up
            return repo, "", up
        return self.of_url(git("remote", "get-url", "origin", cwd=d).stdout.strip(), d)


def find_repos(brains: list[Brain], root: Path, cache: Path) -> None:
    """Each brain's repository; a mount that is not checked out by its .gitmodules url, a relative one
    against the brain's own repository (its upstream: the parent of a fork, not the fork)."""
    resolver, own = Resolver(cache), None
    for b in brains:
        d = root / b.path if b.path != "." else root
        if b.path == "." or (d / ".git").exists():
            b.repo, why, _ = resolver.of_dir(d)
        else:
            url = submodule_config(root, "url").get(b.module, "")
            if url.startswith(("./", "../")):
                own = own or resolver.of_dir(root)
                url = resolve_url(url, own[2])
                if url.startswith(("./", "../")):
                    b.prs["reason"] = f"a relative .gitmodules url and the brain's own repository is unknown ({own[1]})"
                    continue
            b.repo, why, _ = resolver.of_url(url, None) if url else (None, "no url in .gitmodules", "")
        b.prs["reason"] = why


# --- pull requests ----------------------------------------------------------------------------------

def cache_file(cache: Path, repo: tuple[str, str], pr: dict) -> Path | None:
    head = pr.get("head")
    if not isinstance(head, str) or not SHA.fullmatch(head):
        return None
    base = hashlib.sha256(str(pr.get("base") or "").encode("utf-8")).hexdigest()[:12]
    return cache / f"{repo[0]}__{repo[1]}__{pr['number']}__{head}__{base}.diff"


def prune(cache: Path, repo: tuple[str, str], keep: set[Path]) -> None:
    """Remove the cached diffs of `repo` that no open pull request needs, and stale temporary files."""
    try:
        for f in cache.glob(f"{repo[0]}__{repo[1]}__*.diff"):
            if f not in keep:
                f.unlink(missing_ok=True)
        for f in cache.glob(".tmp-*"):
            if time.time() - f.stat().st_mtime > TMP_AGE:
                f.unlink(missing_ok=True)
    except OSError:
        pass


def write_atomic(path: Path, data: bytes) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except OSError:
        pass                      # a cache that cannot be written only costs a fetch next time


class Run:
    """The pull request part's deadline, and the repositories it stopped reading (timeout, 403, 429)."""

    def __init__(self, budget: float):
        self.deadline = time.monotonic() + budget
        self.stopped: dict[tuple[str, str], str] = {}
        self.lock = threading.Lock()

    def left(self, most: float) -> float:
        return min(most, self.deadline - time.monotonic())

    def stop(self, repo: tuple[str, str], why: str) -> None:
        with self.lock:
            self.stopped.setdefault(repo, why)


def list_pulls(b: Brain, run: Run) -> None:
    o, r = b.repo
    jq = ".[] | {number, title, body, user: .user.login, updated_at, draft, base: .base.ref, head: .head.sha} | tojson"
    out, why = gh_call("api", "--hostname", "github.com", "--paginate",
                       f"repos/{o}/{r}/pulls?state=open&per_page=100", "--jq", jq, timeout=run.left(LIST_TIMEOUT))
    pulls = json_lines(out.decode("utf-8", errors="replace")) if out is not None else None
    if pulls is None or not all(isinstance(p, dict) and isinstance(p.get("number"), int) for p in pulls):
        b.prs["reason"] = why or "unreadable answer from gh"
        return
    b.pulls = pulls
    b.prs.update(state="searched", open=len(pulls))


def fetch_diff(repo: tuple[str, str], pr: dict, cache: Path, run: Run) -> tuple[str | None, str]:
    """(the pull request's diff, '') or (None, why); (diff, why) where the diff is incomplete."""
    o, r = repo
    n = pr["number"]
    cached = cache_file(cache, repo, pr)
    if cached is not None:
        try:
            return cached.read_bytes().decode("utf-8", errors="replace"), ""
        except OSError:
            pass                  # not cached, or unreadable: fetched again
    if why := run.stopped.get(repo):
        return None, why
    out, why = gh_call("api", "--hostname", "github.com", "-H", "Accept: application/vnd.github.diff",
                       f"repos/{o}/{r}/pulls/{n}", timeout=run.left(DIFF_TIMEOUT))
    if out is None and why == "gh: HTTP 406":      # too large for a diff: its files one by one
        out, why = gh_call("api", "--hostname", "github.com", "--paginate", f"repos/{o}/{r}/pulls/{n}/files?per_page=100",
                           "--jq", ".[] | {filename, previous_filename, patch, changes} | tojson", timeout=run.left(DIFF_TIMEOUT))
        files = json_lines(out.decode("utf-8", errors="replace")) if out is not None else None
        if files is None or not all(isinstance(f, dict) for f in files):
            return None, f"diff too large, file list failed ({why or 'unreadable answer'})"
        parts, bare = [], 0
        for f in files:
            name, old = str(f.get("filename")), str(f.get("previous_filename") or f.get("filename"))
            parts += [f"diff --git a/{old} b/{name}", f"--- a/{old}", f"+++ b/{name}"]
            if isinstance(f.get("patch"), str):
                parts.append(f["patch"])
            elif isinstance(f.get("changes"), int) and f["changes"] > 0:
                bare += 1
        text = "\n".join(parts) + "\n"
        if len(files) >= FILES_CAP:
            return text, f"file list capped at {FILES_CAP}"
        if bare:
            return text, f"{plural(bare, 'file')} without a patch"
        out = text.encode("utf-8")
    if out is None:
        if why == "timed out" or why.startswith(("gh: HTTP 403", "gh: HTTP 429")):
            run.stop(repo, "timed out" if why == "timed out" else f"not read after {why}")
            return None, why if why == "timed out" else f"diff failed ({why})"
        return None, f"diff failed ({why})"
    if cached is not None:
        write_atomic(cached, out)
    return out.decode("utf-8", errors="replace"), ""


def unquote(name: str) -> str:
    """A path as git writes it in a diff header: as it is, or in double quotes with C escapes (an
    unusual name; non-ASCII bytes as octal)."""
    if len(name) < 2 or not (name.startswith('"') and name.endswith('"')):
        return name
    body, out, i = name[1:-1], bytearray(), 0
    simple = {"n": 10, "t": 9, '"': 34, "\\": 92, "a": 7, "b": 8, "f": 12, "r": 13, "v": 11}
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            if re.fullmatch(r"[0-7]{3}", body[i + 1:i + 4]):
                out.append(int(body[i + 1:i + 4], 8) & 0xFF)
                i += 4
            else:
                out.append(simple.get(body[i + 1], ord("?")))
                i += 2
            continue
        out += body[i].encode("utf-8")
        i += 1
    return out.decode("utf-8", errors="replace")


def side(path: str, prefix: str) -> str:
    """`path` without its `a/` or `b/` side prefix; '' for /dev/null."""
    path = unquote(path)
    return path[len(prefix):] if path.startswith(prefix) else ""


def header_paths(ln: str) -> list[str]:
    """The paths a diff header line names: `diff --git`, `rename from/to`, `copy from/to`, `---`,
    `+++` and `Binary files ... differ`, both sides."""
    if ln.startswith("diff --git "):
        rest = ln[len("diff --git "):]
        if rest.startswith('"'):
            m = re.match(r'("(?:[^"\\]|\\.)*")\s+(.*)$', rest)
            return [side(m.group(1), "a/"), side(m.group(2), "b/")] if m else []
        half = (len(rest) - 1) // 2             # `a/P b/P`: the common case, with spaces in P too
        if rest[:half].startswith("a/") and rest[half + 1:].startswith("b/") and rest[2:half] == rest[half + 3:]:
            return [rest[2:half]]
        a, _, b = rest.rpartition(" b/")
        return [side(a, "a/"), unquote(b)]
    for key in ("rename from ", "rename to ", "copy from ", "copy to "):
        if ln.startswith(key):
            return [unquote(ln[len(key):])]
    if ln.startswith("--- "):
        return [side(ln[4:].split("\t")[0], "a/")]
    if ln.startswith("+++ "):
        return [side(ln[4:].split("\t")[0], "b/")]
    if m := re.match(r"Binary files (.*) and (.*) differ$", ln):
        return [side(m.group(1), "a/"), side(m.group(2), "b/")]
    return []


def diff_hits(diff: str, terms: list[str]) -> list[dict]:
    """The matched changed paths and added lines of a diff, [{file, text}] (text '' for a path). Header
    lines count only before a file's first hunk: in a hunk a `+++ ` line is an added line."""
    hits, current, in_hunk, seen = [], "", False, set()
    for ln in diff.split("\n"):
        if in_hunk and not ln.startswith("diff --git "):
            if ln.startswith("+") and matches(ln[1:], terms):
                hits.append({"file": current, "text": ln[1:]})
            continue
        if ln.startswith("@@"):
            in_hunk = True
            continue
        in_hunk = False
        paths = [p for p in header_paths(ln) if p]
        if paths and ln.startswith(("diff --git ", "+++ ", "rename to ", "copy to ")):
            current = paths[-1]
        for p in paths:
            if p not in seen and matches(p, terms):
                seen.add(p)
                hits.append({"file": p, "text": ""})
    return hits


def search_prs(brains: list[Brain], terms: list[str], limit: int, cache: Path) -> None:
    run = Run(BUDGET)
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        listed = [b for b in brains if b.repo]
        list(pool.map(lambda b: list_pulls(b, run), listed))
        jobs = {}
        for b in listed:
            if b.prs["state"] != "searched":
                continue
            prune(cache, b.repo, {f for pr in b.pulls if (f := cache_file(cache, b.repo, pr))})
            for pr in b.pulls[:limit]:
                jobs[(id(b), pr["number"])] = pool.submit(fetch_diff, b.repo, pr, cache, run)
        for b in listed:
            if b.prs["state"] != "searched":
                continue
            over = 0
            for pr in b.pulls:
                text = f"{pr.get('title') or ''}\n{pr.get('body') or ''}"
                found = [{"file": None, "text": ""}] if matches(text, terms) else []
                job = jobs.get((id(b), pr["number"]))
                if job is None:
                    over += 1
                else:
                    diff, why = job.result()
                    if diff is not None:
                        b.prs["read"] += 1
                        found = diff_hits(diff, terms) + found
                    if why:
                        b.prs["unread"].append({"number": pr["number"], "why": why})
                if found:
                    b.prs["hits"].append({
                        "number": pr["number"], "title": str(pr.get("title") or ""), "author": str(pr.get("user") or ""),
                        "updated_at": str(pr.get("updated_at") or ""), "base": str(pr.get("base") or ""),
                        "draft": bool(pr.get("draft")), "matches": found})
            if over:
                b.prs["unread"].append({"number": None, "why": f"{over} over --limit"})
            if b.prs["unread"]:
                b.prs["state"] = "partial"


# --- output -----------------------------------------------------------------------------------------

def docs_cell(b: Brain) -> str:
    d = b.docs
    if d["state"] != "searched":
        return f"docs NOT SEARCHED ({d['reason']})"
    extra = f"; {b.note}" if b.note else ""
    return f"docs searched ({plural(d['files'], 'file')}, {plural(len(d['hits']), 'hit')}{extra})"


def prs_cell(b: Brain) -> str:
    p = b.prs
    if p["state"] == "not searched":
        return f"prs NOT SEARCHED ({p['reason']})"
    hits = plural(len(p["hits"]), "hit")
    if p["state"] == "searched":
        return f"prs searched ({p['open']} open, {hits})"
    unread = [u["why"] if u["number"] is None else f"#{u['number']} {u['why']}" for u in p["unread"]]
    if len(unread) > 5:
        unread = unread[:5] + [f"and {len(unread) - 5} more"]
    return f"prs PARTIAL ({p['read']} of {p['open']} read, {hits}; not read: {', '.join(unread)})"


def print_text(brains: list[Brain], raw_terms: list[str], max_hits: int, ignored: int) -> None:
    for b in brains:
        if not b.in_scope:
            continue
        hits = b.docs["hits"]
        for h in hits[:max_hits]:
            st = f"   ({cut(h['status'])})" if h["status"] else ""
            if not h["lines"]:
                print(f"docs  {cut(h['cite'])}   (path matches){st}")
            for ln in h["lines"]:
                print(f"docs  {cut(h['cite'])}:{ln['line']}: {cut(ln['text'])}{st}")
        if len(hits) > max_hits:
            print(f"docs  {cut(b.path)}: {len(hits) - max_hits} more files (--max-hits {max_hits})")
        if not b.repo:
            continue
        o, r = b.repo
        pr_hits = b.prs["hits"]
        for h in pr_hits[:max_hits]:
            draft = ", draft" if h["draft"] else ""
            print(f"pr    {o}/{r}#{h['number']} ({cut(h['author'])}, {cut(h['updated_at'][:10])}, base {cut(h['base'])}"
                  f"{draft}, not merged) {cut(h['title'])}")
            for m in h["matches"][:LINES_PER_FILE]:
                if m["file"] is None:
                    print("        (title/body)")
                elif not m["text"]:
                    print(f"        {cut(m['file'])} (path)")
                else:
                    print(f"        {cut(m['file'])}: +{cut(m['text'])}")
        if len(pr_hits) > max_hits:
            print(f"pr    {o}/{r}: {len(pr_hits) - max_hits} more pull requests (--max-hits {max_hits})")
    print(f"coverage (terms: {', '.join(cut(t) for t in raw_terms)}; PR comments not searched):")
    width = max(len(cut(b.path)) for b in brains) + 2
    for b in brains:
        if not b.in_scope:
            print(f"{cut(b.path):<{width}}not in scope (--brain {cut(b.name)})")
            continue
        print(f"{cut(b.path):<{width}}{docs_cell(b):<40} {prs_cell(b)}".rstrip())
    if ignored:
        print(f"note: {ignored} .gitmodules {'entry' if ignored == 1 else 'entries'} under brains/ ignored (not a gitlink in HEAD, or a path "
              "that is not plain names)")


def gaps(brains: list[Brain]) -> list[str]:
    out = []
    for b in brains:
        if b.in_scope:
            out += [f"{cut(b.path)} {part}" for part, st in (("docs", b.docs["state"]), ("prs", b.prs["state"]))
                    if st != "searched"]
    return out


# --- main -------------------------------------------------------------------------------------------

def mounts(root: Path) -> tuple[list[Brain], int]:
    """The mounted brains: .gitmodules paths under brains/ that HEAD holds as gitlinks (mode 160000)
    and whose every part is a plain name; and how many other entries under brains/ were ignored."""
    paths = {p: n for n, p in submodule_config(root, "path").items()} if (root / ".gitmodules").is_file() else {}
    under = {p: n for p, n in paths.items() if p.startswith("brains/")}
    links = set()
    if under:
        # the whole folder, not the .gitmodules paths: one leaving the repository (brains/../x) fails ls-tree
        for rec in git("ls-tree", "-r", "-z", "HEAD", "--", "brains", cwd=root).stdout.split("\0"):
            info, _, path = rec.partition("\t")
            if info.startswith("160000 "):
                links.add(path)
    found = []
    for path in sorted(under):
        parts = path.split("/")[1:]
        if path in links and parts and all(NAME.fullmatch(x) and x not in (".", "..") for x in parts):
            found.append(Brain(path=path, name="/".join(parts), module=under[path]))
    return found, len(under) - len(found)


def choose(brains: list[Brain], names: list[str], ap: argparse.ArgumentParser) -> None:
    """--brain: a mount's path under brains/ (sub/beta), its last part (beta) where that is unique, or `.`."""
    chosen = set()
    for n in names:
        exact = [b for b in brains if b.name == n.strip("/")]
        last = [b for b in brains if b.name.rsplit("/", 1)[-1] == n]
        got = exact or last
        if not got:
            ap.error(f"--brain {cut(n)}: no such mounted brain (known: {', '.join(cut(b.name) for b in brains)})")
        if len(got) > 1:
            ap.error(f"--brain {cut(n)} is ambiguous: {', '.join(cut(b.name) for b in got)}")
        chosen.add(id(got[0]))
    for b in brains:
        b.in_scope = id(b) in chosen


def search(args: argparse.Namespace, ap: argparse.ArgumentParser) -> int:
    root = repo_root()
    if git("rev-parse", "--git-dir", cwd=root).returncode:
        print(f"km search: {cut(str(root))} is not a git repository", file=sys.stderr)
        return 2
    common = Path(git("rev-parse", "--git-common-dir", cwd=root).stdout.strip())
    cache = (common if common.is_absolute() else root / common) / "km-search"
    found, ignored = mounts(root)
    brains = [Brain(path=".", name=".")] + found
    if args.brain:
        choose(brains, args.brain, ap)
    terms = [t.casefold() for t in args.terms]
    scope = [b for b in brains if b.in_scope]
    for b in scope:
        search_docs(b, root, terms)
    if args.no_prs:
        for b in scope:
            b.prs["reason"] = "--no-prs"
    else:
        find_repos(scope, root, cache)
        search_prs(scope, terms, args.limit, cache)
    for b in brains:
        if not b.in_scope:
            b.docs, b.prs = {"state": "not in scope"}, {"state": "not in scope"}
    missing = gaps(brains)
    total = sum(len(b.docs.get("hits", [])) + len(b.prs.get("hits", [])) for b in scope)
    complete = "coverage complete" + (" for the selected brains" if args.brain else "")
    if args.json:
        for b in scope:
            for part in (b.docs, b.prs):
                part["more"] = max(0, len(part["hits"]) - args.max_hits)
                part["hits"] = part["hits"][:args.max_hits]
        print(json.dumps({"terms": args.terms, "complete": not missing, "hits": total, "ignored_entries": ignored,
                          "brains": [{"path": b.path, "name": b.name, "repo": "/".join(b.repo) if b.repo else None,
                                      "note": b.note, "docs": b.docs, "prs": b.prs} for b in brains]},
                         ensure_ascii=True, indent=1))
    else:
        print_text(brains, args.terms, args.max_hits, ignored)
        print(f"result: {plural(total, 'hit')}; " + (complete if not missing else f"coverage INCOMPLETE: {', '.join(missing)}"))
    return 3 if missing else 0 if total else 1


def main() -> int:
    ap = argparse.ArgumentParser(prog="km search", allow_abbrev=False,
                                 description="Search the merged docs and the open pull requests of the brain and its "
                                             "mounted brains for any of the terms (case-insensitive fixed strings), "
                                             "and say per brain what was searched.")
    ap.add_argument("terms", nargs="*", metavar="TERM")
    ap.add_argument("--brain", action="append", default=[], metavar="NAME",
                    help="only this brain: a mount's path under brains/ (or its last part where unique), "
                         "or . for the brain itself (repeatable)")
    ap.add_argument("--no-prs", action="store_true", help="skip the open pull requests (coverage is then incomplete)")
    ap.add_argument("--limit", type=int, default=300, metavar="N", help="diffs read per brain (default 300)")
    ap.add_argument("--max-hits", type=int, default=20, metavar="N", help="files and pull requests listed per brain (default 20)")
    ap.add_argument("--json", action="store_true", help="the result as JSON")
    argv = sys.argv[1:]                # terms after `--` (one may start with a dash): Python 3.11's
    end = argv.index("--") if "--" in argv else len(argv)   # parse_intermixed_args mishandles `--`
    args = ap.parse_intermixed_args(argv[:end])
    args.terms += argv[end + 1:]
    if not args.terms or not all(t.strip() for t in args.terms):
        ap.error("at least one TERM, none of them empty")
    if any("\n" in t or "\r" in t for t in args.terms):
        ap.error("a TERM is one line: no line break in it")
    if args.limit < 0 or args.max_hits < 0:
        ap.error("--limit and --max-hits take a number of at least 0")
    try:
        return search(args, ap)
    except Exception as exc:          # never a 0 or 1 that reads as a complete search
        why = f"coverage INCOMPLETE (internal error: {type(exc).__name__})"
        print(json.dumps({"terms": args.terms, "complete": False, "error": type(exc).__name__}) if args.json
              else f"result: {why}")
        return 3


if __name__ == "__main__":
    sys.exit(main())
