"""Whether a pull request's `km:ready` label counts for the review queue: `km ready REPO NUMBER [--head SHA]`.

The label counts when a person other than the pull request's author applied it last. Set by the
author (or the author's Claude, which acts with the author's login), or by a bot or an app (which
may act for the author), it counts when the pull request touches no control file and every doc it
changes is at approval level `ai` at its head, and at the base too where it was there (a level the
pull request lowered does not count): an AI review may then sign each one off, and CI (`km validate
--signoff-since`) checks that it was. Other files (an image, a PDF, a generator script next to a
page in a doc folder) do not stop it. A control file is one CI runs or reads, or one that steers an
agent, an editor or a hook on a contributor's machine (the rule above CONTROL_NAMES: any dot path,
any top-level file that is not a doc, agent instructions at any depth), on either side of a rename;
so is a changed submodule, and any symlink in the trees read. An `_index.md` that keeps
its path and changes only its `## Documents` list is left aside: `km gen-index` writes that list and
CI checks it (outside index_skip_prefixes, which gen-index skips).
Any other `_index.md` change, a new one included, is level human whatever its frontmatter says: km
validate checks no sign-off on an index. The levels are km's rule (common.approval_level) on each
doc's frontmatter, read from GitHub without checking the pull request out, with the brain's
approval_default, field aliases, skip_prefixes, index_skip_prefixes, exempt_files and
reserved_no_frontmatter from schema.local.yaml at the base commit. It judges the commits the first
read of the pull request names (the file list from comparing them, the trees of the head, the merge
base and the base, docs by blob id, base texts at the base commit) and reads the pull request and
its label events again at the end: a push, a base change or a label change meanwhile does not count.

Metadata, not authentication: it catches a self-granted label, not a determined author (a second
account, a person who labels without reading).

Fails closed: anything it cannot read or decide counts as level human. That is a failed or cut read
(the file list, a tree, the base schema, a doc), a doc without frontmatter or whose frontmatter does
not parse, holds a YAML anchor or merge key or is over the size limit, a removed doc or one moved out
of the docs or into them, a head other than `--head`, a label applied by a deleted account, and a
pull request that changes no doc.

Prints one line, `counts: ...` or `does not count: ...`, never a frontmatter value; a broken local
schema.local.yaml is such a line too. Exit 0 when the label counts, 1 when not, 2 on a usage error.
"""
from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import yaml

from km import common
from km.cites import fold
from km.common import (_FM, OVERLAY_NAMES, approval_default_of, approval_level, merged_schema, split_frontmatter,
                       under, was_doc, with_aliases)
from km.gen_index import kept_parts
from km.paths import printable
from km.remotes import gh_run

LABEL = "km:ready"
TIMEOUT = 30                     # seconds per GitHub call
MAX_FILES = 300                  # the compare API lists at most 300 files: that many may be cut
MAX_TEXT = 1_000_000             # bytes of a doc; a longer one counts as human
MAX_BLOCK = 65_536               # bytes of a frontmatter block
# a YAML anchor (an alias bomb) or a merge key, which the workflow review-request-guide leaves to CI too
UNSAFE = re.compile(r"(^|[^\w])&\S|(<<|\"<<\"|'<<')\s*(:|$)", re.M)
SHA = re.compile(r"[0-9a-f]{40,64}")
GHOST = "ghost"                  # the login GitHub shows for a deleted account
# Control files: a pull request touching one needs another person's label, whatever its docs' levels.
# They are what CI runs or reads and what steers an agent, an editor or a hook on a contributor's
# machine. Rather than a list of tools that grows with each new one, the rule is structural:
# - any path with a segment that starts with a dot: .github/ (workflows and their scripts), .gitmodules,
#   .pre-commit-config.yaml, .gitattributes, .claude/, .vscode/, .husky/, .envrc, .cursorrules and
#   every other tool's config, at any depth;
# - any file at the top of the repository that is not a doc: schema.local.yaml, Makefile, lefthook.yml,
#   mise.toml, CLAUDE.md, README.md; a brain keeps its pages in folders;
# - the agent instructions and conventions below at any depth, a doc or not: an agent reads them in
#   the folder it works in; and CODEOWNERS, which decides whose review GitHub asks for;
# - CONTROL_PATHS: what CI reads outside those (scripts/, where a brain from the copy-in days keeps the
#   km scripts its CI still runs, so any file there can shadow one of their imports; the dist/ that km
#   serve writes into without emptying it and CI uploads whole), and the gate's
#   forbidden_terms_file, which km validate reads;
# - a changed submodule (its pointer changes what a mount holds) and any symlink in the trees by_level
#   reads, changed or not: a link may point at a control file.
# Files in the doc folders (images, PDFs, a generator script in _media/) are not control files.
# The team workflow approve-fork-ci mirrors this rule in jq (tests/team_smoke.sh keeps the two in step).
# Matched on the path as cites.fold folds it (NFC, casefolded): a checkout on a case-insensitive file
# system opens claude.md as CLAUDE.md.
CONTROL_NAMES = {"claude.md", "claude.local.md", "agents.md", "agents.override.md", "agent.md", "gemini.md",
                 "conventions.md", "codeowners"}   # CODEOWNERS: GitHub reads it in docs/ and .github/ too
INERT = {".gitkeep", ".ds_store"}    # dot files in a doc folder that nothing reads
CONTROL_PATHS = ("scripts", "dist")


def gh_text(*args: str) -> tuple[str | None, bool]:
    """(stdout of the GitHub CLI, or None when it failed, did not answer or is missing; whether it
    failed with HTTP 404, the one failure that says the file is not there)."""
    res = gh_run(*args, timeout=TIMEOUT)
    if res is None or res.returncode:
        return None, res is not None and b"(HTTP 404)" in res.stderr
    return res.stdout.decode("utf-8", errors="replace"), False


def raw(repo: str, path: str) -> tuple[str | None, bool]:
    return gh_text("api", "-H", "Accept: application/vnd.github.raw", f"repos/{repo}/{path}")


def lines(*args: str) -> list | None:
    """gh's output as one JSON value per line (`--jq '... | tojson'`), or None when the call failed or a
    line does not parse."""
    text = gh_text(*args)[0]
    if text is None:
        return None
    try:
        # "\n" only: jq leaves U+2028, U+2029 and U+0085 raw in a string, which splitlines() splits on
        return [json.loads(ln) for ln in text.split("\n") if ln.strip()]
    except ValueError:
        return None


def base_schema(repo: str, base: str) -> dict | None:
    """The brain's merged schema at the base commit (the overlay km reads there, as validate.schema_at):
    km's base schema alone where GitHub answers 404 for each overlay name; None where an overlay could
    not be read or is not a mapping, since its aliases and approval_default would then be unknown."""
    for name in OVERLAY_NAMES:
        text, missing = raw(repo, f"contents/{name}?ref={base}")
        if missing:
            continue
        if text is None:
            return None
        try:
            local = yaml.safe_load(text)
        except yaml.YAMLError:
            return None
        return merged_schema(local) if isinstance(local, dict) or local is None else None
    return merged_schema(None)


# a broken local schema.local.yaml is reported by main in its one line, not by km.cli (as km.validate does)
SCHEMA_BROKEN = common.PROBLEMS[0] if common.PROBLEMS else ""
common.PROBLEMS.clear()


def is_index(path: str) -> bool:
    return path.rsplit("/", 1)[-1] == "_index.md"


def is_doc(path: str, schema: dict) -> bool:
    """A doc, or a folder's _index.md outside skip_prefixes (judged by its own rule, see by_level)."""
    if is_index(path):
        return not path.startswith(tuple(x for x in (schema.get("skip_prefixes") or []) if isinstance(x, str)))
    return path.endswith(".md") and was_doc(path, schema)


def terms_file(schema: dict) -> str | None:
    """The gate's forbidden_terms_file, which km validate reads, folded as control() compares it."""
    gate = schema.get("gate")
    tf = gate.get("forbidden_terms_file") if isinstance(gate, dict) else None
    return posixpath.normpath(fold(tf)) if isinstance(tf, str) else None


def control(path: str, schema: dict, terms: str | None) -> bool:
    """Whether `path` is a control file (the rule above CONTROL_NAMES), judged on its name as a
    case-insensitive file system compares it; `terms` is the gate's forbidden_terms_file."""
    low = fold(path)
    parts = low.split("/")
    if len(parts) == 1:                  # a doc at the top is none if its name is exempt in another case (readme.md)
        exempt = {fold(n) for n in (schema.get("exempt_files") or []) if isinstance(n, str)}
        if low in exempt or not is_doc(path, schema):
            return True
    if parts[-1] in CONTROL_NAMES or under(low, CONTROL_PATHS) or low == terms:
        return True
    return any(p.startswith(".") for p in parts[:-1]) or parts[-1].startswith(".") and parts[-1] not in INERT


def kept(text: str | None) -> tuple[str, str] | None:
    """What `km gen-index` keeps of an _index.md (gen_index.kept_parts, on the text as it reads it), or
    None, so it is level human: without frontmatter (a BOM before it too) or the heading, with
    a carriage return (gen-index reads it away and may then find another heading), or with the heading
    it finds inside the frontmatter."""
    if text is None or "\r" in text or not (m := _FM.match(text)):
        return None
    parts = kept_parts(text)
    return parts if parts and len(parts[0]) > len(m.group(1)) else None


def level(text: str | None, schema: dict) -> str:
    """The approval level of a doc's text under `schema`: human for anything that cannot be read safely."""
    if text is None or len(text.encode("utf-8")) > MAX_TEXT:
        return "human"
    text = text.lstrip("﻿").replace("\r\n", "\n")
    m = _FM.match(text)                             # the block split_frontmatter parses
    if not m or len(m.group(2).encode("utf-8")) > MAX_BLOCK or UNSAFE.search(m.group(2)):
        return "human"
    fm = split_frontmatter(text)[0]
    if not isinstance(fm, dict):
        return "human"
    return approval_level(with_aliases(fm, schema), approval_default_of(schema))


def label_events(repo: str, number: str) -> list | None:
    """Who applied the label, each time: login, actor type and whether through an app, oldest first; also
    an unlabeled event, so a label removed meanwhile changes the list."""
    return lines("api", "--paginate", f"repos/{repo}/issues/{number}/events", "--jq",
                 f'.[] | select((.event == "labeled" or .event == "unlabeled") and .label.name == "{LABEL}")'
                 ' | {event, login: .actor.login, type: .actor.type, app: (.performed_via_github_app != null)} | tojson')


def verdict(repo: str, number: str, head: str | None) -> tuple[bool, str]:
    pr = lines("api", f"repos/{repo}/pulls/{number}", "--jq",   # the fields used, no more to parse
               "{user: {login: .user.login}, head: {sha: .head.sha}, base: {sha: .base.sha}, changed_files} | tojson")
    if not pr or not isinstance(pr[0], dict):
        return False, "could not read the pull request"
    pr = pr[0]
    author = str((pr.get("user") or {}).get("login") or "")
    events = label_events(repo, number)
    last = events[-1] if events else None
    if not isinstance(last, dict) or last.get("event") != "labeled":
        return False, f"no {LABEL} label event could be read"
    actor = str(last.get("login") or "")
    who, author = actor.lower(), author.lower()
    if not (who and author) or GHOST in (who, author):   # nobody can tell who it was
        return False, "the label's actor or the pull request's author is unknown"
    # a bot or an app acts for whoever runs it, maybe the author: judged like the author's own label
    automated = last.get("type") == "Bot" or last.get("app") or who.endswith("[bot]")
    if who != author and not automated:
        return True, f"{LABEL} applied by {printable(actor)}, not the author"
    counts, why = by_level(repo, number, head, pr, events)
    return counts, f"set by {'a bot or app' if automated else 'its author'}, and {why}"


def tree_links(repo: str, sha: str) -> dict | None:
    """The symlinks and submodules in the tree of a commit, {path: mode}, or None where the tree could
    not be read in full (the API cuts a large one)."""
    got = lines("api", f"repos/{repo}/git/trees/{sha}?recursive=1", "--jq",
                '{truncated, links: [.tree[] | select(.mode == "120000" or .mode == "160000") | [.path, .mode]]} | tojson')
    if not got or not isinstance(got[0], dict) or got[0].get("truncated") is not False \
            or not isinstance(got[0].get("links"), list) or not all(isinstance(x, list) and len(x) == 2 for x in got[0]["links"]):
        return None
    return {str(p): str(m) for p, m in got[0]["links"]}


def by_level(repo: str, number: str, head: str | None, pr: dict, events: list) -> tuple[bool, str]:
    """Whether a label its author, a bot or an app set counts: no control file changed, every changed
    doc at level ai."""
    sha, base = (pr.get("head") or {}).get("sha"), (pr.get("base") or {}).get("sha")
    if head and sha != head:
        return False, "the head moved"
    if not (isinstance(sha, str) and SHA.fullmatch(sha) and isinstance(base, str) and SHA.fullmatch(base)):
        return False, "the head or base commit could not be read"
    # the commits read now, not the live pull request: a push during the reads is caught at the end
    cmp = lines("api", f"repos/{repo}/compare/{base}...{sha}?per_page=1", "--jq",
                "{mb: .merge_base_commit.sha, files: [.files[] | {filename, previous_filename, status, sha}]} | tojson")
    files, mb = (cmp[0].get("files"), cmp[0].get("mb")) if cmp and isinstance(cmp[0], dict) else (None, None)
    if not isinstance(files, list) or len(files) != pr.get("changed_files") or len(files) >= MAX_FILES:
        return False, "its file list could not be read in full"
    schema = base_schema(repo, base)
    if schema is None:
        return False, "schema.local.yaml at the base could not be read"
    index_skip = tuple(x for x in (schema.get("index_skip_prefixes") or []) if isinstance(x, str))   # gen-index skips them
    terms = terms_file(schema)
    docs, paths = [], set()                         # first every check without a read, then the reads
    for f in files:
        path, status = str(f.get("filename") or ""), f.get("status")
        old = str(f.get("previous_filename") or path)
        paths |= {path, old}
        if bad := next((p for p in (path, old) if control(p, schema, terms)), None):
            return False, f"it changes {printable(bad)}, a control file"
        doc_now, doc_then = is_doc(path, schema), is_doc(old, schema)
        if not (doc_now or doc_then):
            if is_index(path) or is_index(old):     # an index km does not judge (under skip_prefixes)
                return False, f"it changes {printable(path)}, an index outside the docs"
            continue                                # a file next to the pages: an image, a script, data
        if doc_now != doc_then:
            return False, f"it moves {printable(old)} to {printable(path)}, " \
                          f"{'into' if doc_now else 'out of'} the docs"
        if status == "removed":
            return False, f"it removes {printable(path)}"
        if (is_index(path) or is_index(old)) and old != path:
            return False, f"it moves {printable(old)} to {printable(path)}, and a moved index counts as level human"
        if is_index(path) and path.startswith(index_skip):
            return False, f"{printable(path)} is an index under index_skip_prefixes, whose list nothing checks: level human"
        docs.append((path, f.get("sha"), None if status == "added" else old))
    if not docs:
        return False, "it changes no doc"
    def texts(doc):                                 # (at the head, at the base or "" where it was not)
        _, blob, old = doc
        head_text = raw(repo, f"git/blobs/{blob}")[0] if isinstance(blob, str) and SHA.fullmatch(blob) else None
        return head_text, "" if old is None else raw(repo, f"contents/{urllib.parse.quote(old)}?ref={base}")[0]
    with ThreadPoolExecutor(max_workers=8) as pool:
        # the trees of the two sides compare diffs (the head and the merge base) and of the base the
        # pull request merges into, which may hold a link the merge base does not
        modes = [pool.submit(tree_links, repo, c) for c in (sha, mb, base)] if isinstance(mb, str) and SHA.fullmatch(mb) else []
        read = list(pool.map(texts, docs))
    links = [m.result() for m in modes]
    if not links or None in links:
        return False, "the trees of its commits could not be read in full"
    if bad := sorted(paths & {p for t in links for p in t}):
        return False, f"it changes {printable(bad[0])}, a symlink or submodule"
    # any symlink, changed or not, in any of the trees: what it points at may be a control file. A
    # mount (submodule) that does not change holds no file of this brain.
    if bad := sorted({p for t in links for p, m in t.items() if m == "120000"}):
        return False, f"the brain holds the symlink {printable(bad[0])}, which may stand for a control file"
    n = 0
    for (path, _, old), (now, then) in zip(docs, read):
        if is_index(path):
            if (k := kept(now)) is not None and k == kept(then):
                continue                            # only the generated list changed; `km gen-index --check` in CI
            return False, f"{printable(path)} is an index changed beyond its list, which counts as level human"
        if (lv := level(now, schema)) != "ai" or (old and level(then, schema) != "ai"):
            return False, f"{printable(path)} is at level human" + (" at the base" if lv == "ai" else "")
        n += 1
    if not n:
        return False, "it changes no doc"
    again = lines("api", f"repos/{repo}/pulls/{number}", "--jq", "[.head.sha, .base.sha] | tojson")
    if again != [[sha, base]]:
        return False, "the head or base moved while it was read"
    if label_events(repo, number) != events:
        return False, f"the {LABEL} label changed while it was read"
    return True, f"no control file changed and all {n} changed docs are at level ai"


def main() -> int:
    ap = argparse.ArgumentParser(prog="km ready", allow_abbrev=False,
                                 description=f"Whether a pull request's {LABEL} label counts (the review queue).")
    ap.add_argument("repo", metavar="OWNER/NAME")
    ap.add_argument("number", metavar="NUMBER")
    ap.add_argument("--head", metavar="SHA", help="the head commit the queue saw; another head does not count")
    args = ap.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or not args.number.isdigit():
        ap.error("OWNER/NAME and a pull request NUMBER")
    if SCHEMA_BROKEN:
        counts, why = False, f"the local schema is broken: {printable(SCHEMA_BROKEN.splitlines()[0])}"
    else:
        counts, why = verdict(args.repo, args.number, args.head)
    print(f"{'counts' if counts else 'does not count'}: {why}")
    return 0 if counts else 1


if __name__ == "__main__":
    sys.exit(main())
