"""What every km command shares: the brain's root, the merged schema (km's own base overlaid by the
brain's schema.local.yaml; lists extend, dicts shallow-merge), frontmatter parsing, the tracked-file
list and what counts as an article. One loader for all commands, so none of them acts on a different
configuration than the validator checks; a broken schema file stops the run.
"""
from __future__ import annotations

import atexit
import datetime
import functools
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

from km.paths import BASE_SCHEMA, git, repo_root

ROOT = repo_root()


def _load(p: Path) -> dict | None:
    if not p.is_file():
        return None
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        sys.exit(f"{p.name}: invalid YAML: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"{p.name}: must be a mapping")
    return data


def _merge(base: dict, local: dict | None) -> dict:
    """The overlay on km's base. A base key the overlay leaves empty (YAML null: what remains when
    every entry under it is commented out) keeps the base value, at the top and one level down (a field).
    In `review_by_default` an entry's null is a value (the type does not expire), so it overrides."""
    out = dict(base)
    for k, v in (local or {}).items():
        cur = out.get(k)
        if v is None and k in out:
            continue
        if isinstance(v, list) and isinstance(cur, list):
            out[k] = cur + v
        elif isinstance(v, dict) and isinstance(cur, dict):
            keep_null = k == "review_by_default"
            out[k] = {**cur, **{kk: vv for kk, vv in v.items() if vv is not None or keep_null or kk not in cur}}
        else:
            out[k] = v
    return out


# The brain's overlay. A brain from before the overlay existed has only a legacy schema.yaml (km's
# schema plus its own additions); it overlays the base the same way until `km upgrade` renames it.
OVERLAY = ROOT / ("schema.local.yaml" if (ROOT / "schema.local.yaml").is_file() or not (ROOT / "schema.yaml").is_file()
                  else "schema.yaml")
def _specs(schema: dict) -> dict:
    """The merged schema with every field and type spec a mapping without empty keys: a field or type
    the overlay declares with no spec (`ticket:`) has an empty one, and a key left empty inside a spec
    (`enum:` with every value commented out) is absent."""
    for section in ("fields", "type_rules", "type_rules_soft"):
        if isinstance(specs := schema.get(section), dict):
            schema[section] = {name: {k: v for k, v in spec.items() if v is not None} if isinstance(spec, dict)
                               else {} if spec is None else spec for name, spec in specs.items()}
    return schema


BASE = _load(BASE_SCHEMA) or {}   # km's own schema, before the overlay
SCHEMA = _specs(_merge(BASE, _load(OVERLAY)))

EXEMPT = set(SCHEMA.get("exempt_files") or [])
RESERVED = set(SCHEMA.get("reserved_no_frontmatter") or [])
SKIP = tuple(SCHEMA.get("skip_prefixes") or [])
INDEX_SKIP = tuple(SCHEMA.get("index_skip_prefixes") or [])
_gate = SCHEMA.get("gate")
_gate = _gate if isinstance(_gate, dict) else {}   # a malformed gate is reported by `km validate`
SERVED_STATUS = _gate.get("served_status", "accepted")
RETIRED_STATUS = ("superseded", "obsolete")
CUSTOMER_AUDIENCE = _gate.get("customer_audience", "customer")

# Approval: an AI review alone may sign a doc off only at level `ai`: the doc's own `approval`, or
# where that is unset the brain's `approval_default`, and only on a doc marked `audience: internal`
# that is not a verbatim-block. A customer-facing doc, any other audience and a doc without one need
# a person (for everything else no audience counts as internal, as in `km serve`). An AI approver is
# written `approved_by: "ai:<model>"`. Metadata, not authentication: it catches slips, not a
# determined author.
APPROVAL_FIELDS = ("approved_by", "approved_at", "approved_digest")
APPROVAL_LEVELS = ("ai", "human")
INTERNAL_AUDIENCE = "internal"
APPROVAL_DEFAULT = "ai" if SCHEMA.get("approval_default") == "ai" else "human"   # a bad value is reported by `km validate`


# The review_by a sign-off sets on a doc that has none: days after it, per type (`review_by_default`,
# "*" for a type the table does not name); null means the type does not expire, so a doc of it needs
# no review_by. `km validate`, `km approve` and `km promote` refuse a bad table (review_by_default_problem).
def _days(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v > 0


def review_by_default_problem() -> str | None:
    """Why the merged `review_by_default` table is unusable, or None."""
    table = SCHEMA.get("review_by_default")
    types = (SCHEMA.get("fields", {}).get("type") or {}).get("enum")   # none: any type is allowed, so any key
    known = set(types or []) | set(BASE.get("review_by_default") or {})
    if not isinstance(table, dict) or any((types and k not in known) or not (v is None or _days(v))
                                          for k, v in table.items()):
        return f'review_by_default maps a type (or "*" for any other) to days > 0 or null, got {table!r}'
    return None


def review_by_days(doctype) -> int | None:
    """Days from sign-off to review_by for a doc of this type; None when the type does not expire."""
    table = SCHEMA.get("review_by_default")
    if not isinstance(table, dict):
        return None
    days = table.get(doctype, table.get("*")) if isinstance(doctype, str) else table.get("*")
    return days if _days(days) else None


def review_due(fm: dict) -> datetime.date | None:
    """The `review_by` that counts: none for a type that does not expire, so a date left on such a doc
    (older km gave every promoted type one) is ignored. Callers refuse a bad table first
    (review_by_default_problem), else every type would read as not expiring."""
    return as_date(fm.get("review_by")) if review_by_days(fm.get("type")) else None


def default_review_by(doctype, start: datetime.date) -> datetime.date | None:
    """The review_by a doc of this type gets when signed off (or promoted) on `start`; None: no expiry."""
    days = review_by_days(doctype)
    return start + datetime.timedelta(days=days) if days else None


def is_ai_approver(who) -> bool:
    """Signed off by AI alone: every approver (one, or a list) is `ai:<model>`; a person among them
    counts as a human sign-off."""
    ws = [str(w).strip().lower() for w in as_list(who) if w]
    return bool(ws) and all(w.startswith("ai:") for w in ws)


def _ai_parts(fm: dict) -> tuple[bool, bool, bool]:
    """(may: internal by default and not a verbatim-block, level ai: its own `approval` or the brain's
    default, explicit: `audience: internal` written out). An AI may sign off only when all three hold."""
    return (fm.get("audience", INTERNAL_AUDIENCE) == INTERNAL_AUDIENCE and fm.get("type") != "verbatim-block",
            (fm.get("approval") or APPROVAL_DEFAULT) == "ai", fm.get("audience") == INTERNAL_AUDIENCE)


def approval_level(fm: dict) -> str:
    """Who may sign the doc off: "ai" only for a doc marked `audience: internal` that is not a
    verbatim-block and is at level ai (its own `approval`, else the brain's default); else "human".
    The rule approval_problem enforces on an AI approver."""
    return "ai" if all(_ai_parts(fm)) else "human"


def as_date(v) -> datetime.date | None:
    """A date field (review_by, timestamp) as a date, whether YAML read it as a date, a datetime or a
    string; None when it is none of these."""
    try:
        return datetime.date.fromisoformat(str(v)[:10])
    except (ValueError, TypeError):
        return None


def approval_problem(fm: dict, approver=None) -> str | None:
    """Why `approver` (default: the doc's approved_by) may not sign this doc off, or None."""
    may, level_ai, explicit = _ai_parts(fm)
    if fm.get("approval") == "ai" and not may:
        return "'approval: ai' is only allowed on an internal doc that is not a verbatim-block"
    if not is_ai_approver(fm.get("approved_by") if approver is None else approver) or (may and level_ai and explicit):
        return None
    if not may:
        return "only an internal doc may take an AI approver, this one needs a human approver"
    if not level_ai:
        return "an AI approver needs 'approval: ai' or approval_default: ai"
    return "an AI approver needs 'audience: internal' set explicitly"


# An approval vouches for the content it saw: `km approve` records `approved_digest`, a digest of the
# body and of the frontmatter fields below, and `km validate` reports an accepted doc whose content
# no longer matches it. A field counts when changing it changes what the approver vouched for: what
# the doc says (title, description, type, valid_for, evidence, participants, resource, language,
# license) and whom it is served to (audience, claim_category). The rest is bookkeeping and never
# makes an approval stale: the lifecycle and sign-off fields (status, approved_*, approval,
# reviewed_by, review_by, timestamp, owner, author, origin), the links and pins that have their own
# checks (sources, translates and cites, which `km repin` sends back to review when their content
# moves; related, supersedes, superseded_by, contribution), classification (tags, project) and any
# field a brain adds in schema.local.yaml. A doc approved before km recorded the digest has none and
# is not checked; `km upgrade` records one for its current content.
DIGEST_FIELDS = ("type", "title", "description", "resource", "audience", "claim_category", "valid_for",
                 "evidence", "participants", "language", "license")


def plain(v):
    """A YAML value with every mapping key as a string, so keys of mixed types (a year next to a
    word, a date) sort; json.dumps(sort_keys=True) refuses them otherwise."""
    if isinstance(v, dict):
        return {str(k): plain(x) for k, x in v.items()}
    return [plain(x) for x in v] if isinstance(v, list) else v


def unquoted_scalars(fm: dict) -> list[str]:
    """The content fields holding an unquoted number or boolean: YAML reads `1.10` as 1.1 and `yes`
    as true, so the digest sees the value, not what was written (`1.10` to `1.1` is no change to
    it, quoting `yes` is). Quoted, the text is the value."""
    def typed(v) -> bool:
        if isinstance(v, dict):
            return any(map(typed, v.values()))
        return any(map(typed, v)) if isinstance(v, list) else isinstance(v, (bool, int, float))
    return [k for k in DIGEST_FIELDS if k in fm and typed(fm[k])]


def approved_digest(fm: dict, body: str) -> str:
    """The digest of a doc's approved content (see DIGEST_FIELDS): sha256 prefix of its content
    fields, as YAML read them, and its body, line endings (CRLF or a lone CR, which Python's universal
    newlines turn into LF on a read) and surrounding blank space aside."""
    fields = {k: plain(fm[k]) for k in DIGEST_FIELDS if k in fm}
    text = json.dumps(fields, sort_keys=True, ensure_ascii=False, default=str) + "\n" + body.replace("\r\n", "\n").replace("\r", "\n").strip()
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def set_digest(raw: str, fm: dict, body: str) -> str:
    """`raw` with `approved_digest` set to the digest of this content (quoted: all digits reads as a number)."""
    return set_fm_line(raw, "approved_digest", f'"{approved_digest(fm, body)}"')


PIN = re.compile(r"^(.+\.md)@([0-9a-fA-F]{7,40})$")   # a source pin: path.md@<commit or blob>


def as_list(value) -> list:
    """A frontmatter field that may hold one value or a list of them, as a list."""
    return value if isinstance(value, list) else [] if value is None else [value]


@functools.cache
def _objects() -> subprocess.Popen | None:
    """One `git cat-file --batch-check` that answers every object lookup of a run; None without git."""
    try:
        proc = subprocess.Popen(["git", "cat-file", "--batch-check"], cwd=ROOT, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                encoding=sys.getfilesystemencoding(), errors="surrogateescape")
    except OSError:   # no git, or no file descriptor left
        return None
    atexit.register(_close, proc)
    return proc


def _close(proc: subprocess.Popen) -> None:
    """End a cat-file (it stops at the end of its input) and free its pipes, also when it already exited."""
    for pipe in (proc.stdin, proc.stdout):
        try:
            pipe.close()
        except OSError:
            pass
    proc.wait()


def _drop_objects() -> None:
    if _objects.cache_info().currsize and (proc := _objects()):
        atexit.unregister(_close)
        _close(proc)
    _objects.cache_clear()


def fresh_run() -> None:
    """Forget what an earlier run in this process looked up: the file list, the index, the pins."""
    _drop_objects()
    for cached in (_ls_md, _md_index, md_named, unstaged, staged_blob, pinned_blob, _body):
        cached.cache_clear()


def _rev(spec: str) -> str:
    """The object `spec` names (`rev-parse --verify` semantics), or ''."""
    if "\n" in spec or (batch := _objects()) is None:
        return ""
    try:
        batch.stdin.write(spec + "\n")
        batch.stdin.flush()
        line = batch.stdout.readline()
    except OSError:   # BrokenPipeError: git exited on an earlier spec
        line = ""
    if not line:      # git exits on some specs (a path outside the repository): the next lookup starts a new one
        _drop_objects()
        return ""
    oid, _, rest = line.rstrip("\n").partition(" ")
    return oid if re.fullmatch(r"[0-9a-f]{40,64}", oid) and not rest.endswith("missing") else ""


@functools.cache
def unstaged() -> frozenset[str]:
    """Brain-relative paths whose work-tree edits are not staged: a pin sees the staged content."""
    return frozenset(filter(None, git("diff", "--name-only", "--relative", "-z", cwd=ROOT).stdout.split("\0")))


@functools.cache
def staged_blob(path: str) -> str:
    """The blob of a file as staged now (the index: what gets committed, after the repository's
    filters), or '' if it is not tracked. `path` is relative to the brain, which may sit below the
    repository's top level, or (as pins were written before) to the top level."""
    path = path.lstrip("/")
    return _rev(f":./{path}") or _rev(f":{path}")


@functools.cache
def pinned_blob(h: str, path: str) -> str:
    """The content a pin names: the hash as a blob, or the source's blob in the commit it names."""
    path = path.lstrip("/")
    return _rev(f"{h}^{{blob}}") or _rev(f"{h}:./{path}") or _rev(f"{h}:{path}")


@functools.cache
def _body(blob: str) -> str:
    text = git("cat-file", "blob", blob, cwd=ROOT).stdout.lstrip("\ufeff").replace("\r\n", "\n")
    return split_frontmatter(text)[2] if text.startswith("---") else text


def pin_state(pin: str) -> str:
    """'current', 'stale', 'unknown' (the pinned content is not in this clone's history) or
    'untracked' (the source is not). Only the body counts: a source whose frontmatter alone changed
    (approved, demoted, re-pinned) still matches its pins."""
    path, h = PIN.match(pin).groups()
    pinned = pinned_blob(h, path)
    if not pinned:
        return "unknown"
    current = staged_blob(path)
    if not current:
        return "untracked"
    return "current" if current == pinned or _body(current) == _body(pinned) else "stale"


def set_fm_line(raw: str, key: str, value: str) -> str:
    """Set `key: value` in a raw '---' frontmatter block in place: replace the line, or add it last."""
    line = f"{key}: {value}"
    new, n = re.subn(rf"(?m)^{re.escape(key)}:.*$", lambda _m: line, raw, count=1)
    return new if n else append_fm(raw, line)


def append_fm(raw: str, text: str) -> str:
    """`text` (one or more lines) added last to a raw '---' frontmatter block."""
    end = raw.rstrip("\n").rfind("\n---")
    return raw[:end] + "\n" + text + raw[end:]


def demote_raw(raw: str) -> str | None:
    """A served doc's raw '---' block back at `status: review`, its approval lines dropped; the status
    line edited in place, no YAML round-trip. None if no status line can be rewritten, or the block no
    longer parses afterwards. An approval key it cannot find (quoted, `approved_by : x`) stays: the
    doc leaves the served set all the same, which a stale doc must."""
    new, n = re.subn(rf"(?m)^status:[ \t]*['\"]?{re.escape(SERVED_STATUS)}['\"]?[ \t]*(#.*)?$", "status: review", raw)
    if n != 1:
        return None
    for key in APPROVAL_FIELDS:   # the whole entry: a block-list approved_by has its `- ` items on the lines below
        while (dropped := set_fm_block(new, key, "")) is not None:
            new = dropped
    return new if split_frontmatter(new)[0] is not None else None   # never write a block that no longer parses


def approval_left(raw: str) -> list[str]:
    """The approval keys a demoted '---' block still holds: those demote_raw cannot find (quoted)."""
    return [k for k in APPROVAL_FIELDS if k in frontmatter(raw)]


def sent_back_left(raw: str) -> list[str]:
    """The keys a sent-back '---' block still holds that send_back drops: approval keys and
    `reviewed_by` it cannot find (quoted)."""
    fm = frontmatter(raw)
    return [k for k in (*APPROVAL_FIELDS, "reviewed_by") if k in fm]


def send_back(fm: dict, raw: str, message: str):
    """A doc whose sources changed under its approval: a signed-off one goes back to `status: review`
    without its approval and pre-reviews (`reviewed_by`, which saw the old sources), to be approved
    again. A key it cannot find (quoted) stays and is named; the doc goes back to review all the
    same, as `km demote --apply` does. The refusal, or `(new_raw, message)` for `edit_docs`."""
    if fm.get("status") != SERVED_STATUS:
        return raw, message
    if (raw := demote_raw(raw)) is None:
        return "signed off, but its status line cannot be rewritten to review (or the block would no longer parse)"
    while (dropped := set_fm_block(raw, "reviewed_by", "")) is not None:   # every entry, as demote_raw does
        raw = dropped
    if left := sent_back_left(raw):   # unparsable: the gate refuses it
        return raw, message + f"; back to review, but drop its {', '.join(left)} by hand, then `km approve` after review"
    return raw, message + "; back to review without its approval, run `km approve` after review"


def scalar(value: str) -> str:
    """`value` as a YAML scalar: plain where YAML reads it back unchanged, else double-quoted."""
    try:
        if yaml.safe_load(f"k: {value}") == {"k": value}:
            return value
    except (yaml.YAMLError, ValueError):   # ValueError: a date YAML cannot build (2026-02-30)
        pass
    return json.dumps(value)


def set_fm_block(raw: str, key: str, text: str) -> str:
    """Replace the whole `key:` entry of a raw '---' frontmatter block, its value lines included (a
    block list, a folded scalar, blank or comment lines between them), with `text`, or drop it if
    `text` is empty; unlike set_fm_line this covers multi-line values. None if no line starts with
    `key:` (a quoted or spaced key this edit cannot find)."""
    lines = raw.split("\n")
    start = next((i for i, ln in enumerate(lines) if re.match(rf"{re.escape(key)}:(\s|$)", ln)), None)
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and lines[end] != "---" and lines[end][:1] in ("", " ", "\t", "-", "#"):
        end += 1
    while end > start + 1 and (not lines[end - 1].strip() or lines[end - 1].startswith("#")):
        end -= 1   # a trailing blank or comment line belongs to what follows
    return "\n".join(lines[:start] + (text.split("\n") if text else []) + lines[end:])


_FM = re.compile(r"^(---\n(.*?)\n---\n?)(.*)$", re.S)


def yaml_reason(exc: Exception, first_line: int = 1) -> str:
    """Why YAML refused a block, in one line: the problem, and where, with line numbers of the file
    when the block starts on line `first_line`; for a date YAML cannot build (ValueError) its text."""
    if isinstance(exc, yaml.MarkedYAMLError):
        at = lambda m: f" (line {m.line + first_line}, column {m.column + 1})" if m else ""
        parts = [f"{exc.context}{at(exc.context_mark)}" if exc.context else "",
                 f"{exc.problem}{at(exc.problem_mark)}" if exc.problem else ""]
        return "; ".join(p for p in parts if p) or "YAML error"
    return str(exc).strip() or type(exc).__name__


def split_frontmatter(text: str) -> tuple[dict | None, str, str]:
    """(frontmatter or None, the raw '---' block, body). No or unparsable block: (None, '', text)."""
    m = _FM.match(text)
    if not m:
        return None, "", text
    try:
        fm = yaml.safe_load(m.group(2)) or {}
    except (yaml.YAMLError, ValueError):   # ValueError: a date YAML cannot build (2026-02-30)
        return None, "", text
    return (fm if isinstance(fm, dict) else None), m.group(1), m.group(3)


def body_of(text: str) -> str:
    """The text after a '---' frontmatter block, the block not parsed; all of it if there is none."""
    m = _FM.match(text)
    return m.group(3) if m else text


def fm_text(fm: dict, raw: str, key: str) -> str | None:
    """A frontmatter field shown as text: None when unset or null; a scalar as written in the file
    (YAML reads `title: 1.10` as 1.1, `2026-11-10` as a date); anything else as str(). For display
    only: the digest and the checks keep the value YAML read."""
    v = fm.get(key)
    if v is None or isinstance(v, str):
        return v
    try:   # the parsed block parsed, so composing it does too; a guard all the same
        node = yaml.compose(_FM.match(raw).group(2), Loader=yaml.SafeLoader)
    except (yaml.YAMLError, AttributeError):
        return str(v)
    found = [vn.value for kn, vn in getattr(node, "value", []) if isinstance(vn, yaml.ScalarNode)
             and isinstance(kn, yaml.ScalarNode) and kn.value == key]
    return found[-1] if found else str(v)   # the last of a key given twice, as YAML reads it


def frontmatter(text: str) -> dict:
    return split_frontmatter(text)[0] or {}


def doc_at(rev: str, rel: str) -> tuple[dict | None, str] | None:
    """(frontmatter or None, body) of `rel` as committed in `rev`, or None where `rev` has no such file."""
    then = git("show", f"{rev}:./{rel}", cwd=ROOT)
    if then.returncode:
        return None
    fm, _, body = split_frontmatter(then.stdout.lstrip("\ufeff").replace("\r\n", "\n"))
    return fm, body


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")


@functools.cache
def _ls_md(others: bool = False) -> tuple[tuple[str, ...] | None, str]:
    """git's list of .md files, once per run (a path once, though a conflict lists it per stage), and
    git's error text; None for the list where git cannot list them."""
    res = git("ls-files", "-z", *(("--cached", "--others", "--exclude-standard") if others else ()), "--", "*.md", cwd=ROOT)
    if res.returncode != 0:
        return None, res.stderr.strip()
    return tuple(dict.fromkeys(p for p in res.stdout.split("\x00") if p)), ""


def git_md(others: bool = False) -> list[str] | None:
    """The .md files git lists in the brain, relative to it, once per run: the tracked ones (also
    those deleted but not yet staged), with others=True also the untracked ones .gitignore does not
    exclude. None where git cannot list them (not a git work tree, no git); unlike tracked_md this
    never exits."""
    files = _ls_md(others)[0]
    return None if files is None else list(files)


def tracked_md(existing: bool = True) -> list[str]:
    """The tracked .md files, listed by git once per run; with existing=False also those deleted but
    not yet staged. Outside a git work tree the run stops with git's error."""
    files, error = _ls_md(False)
    if files is None:
        sys.exit(f"git ls-files failed (not a git repo?): {error}")
    return [p for p in files if not existing or (ROOT / p).is_file()]


@functools.cache
def _md_index() -> dict[str, tuple[str, ...]]:
    """The .md files by file name, existing or not (md_named checks its hits on disk)."""
    if (listed := _ls_md(True)[0]) is not None:
        paths = list(listed)
    else:                                      # not a git work tree: the disk, .git left out
        paths = []
        for top, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d != ".git"]
            base = Path(top).relative_to(ROOT).as_posix()
            paths += [f if base == "." else f"{base}/{f}" for f in files if f.endswith(".md")]
    index: dict[str, list[str]] = {}
    for p in sorted(paths):
        index.setdefault(p.rsplit("/", 1)[-1], []).append(p)
    return {name: tuple(ps) for name, ps in index.items()}


@functools.cache
def md_named(name: str) -> tuple[str, ...]:
    """The brain-relative paths, sorted, of the .md files a link to the file name `name` (`x.md`) could
    mean: the files on disk that git tracks or would track, so a draft not yet `git add`ed counts (km
    gates a doc before it is staged) and a gitignored file (a scratch draft) does not; a tracked file
    deleted on disk does not either. In a brain that is not a git work tree: every .md on disk outside
    .git. Mounted brains are repositories of their own, git lists none of their files. The name is
    matched exactly, as text (`*`, `?`, `[` are no pattern) and case-exact, which is what a clone on
    a case-sensitive file system sees. Listed, and each name checked on disk, once per run."""
    return tuple(p for p in _md_index().get(name, ()) if (ROOT / p).is_file())


def is_article(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return not rel.startswith(SKIP) and name != "_index.md" and name not in EXEMPT and name not in RESERVED


def folder_of(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else "."


def submodule_prefixes() -> set[str]:
    """Where mounted brains live: brains/ and every path in .gitmodules."""
    prefixes = {"brains"}
    gm = ROOT / ".gitmodules"
    if gm.is_file():
        for ln in gm.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if ln.startswith("path"):
                prefixes.add(ln.split("=", 1)[1].strip().strip("/"))
    return prefixes


def under(rel: str, prefixes) -> bool:
    """Whether a path from the brain root is one of the prefixes or lies below one."""
    return any(rel == p or rel.startswith(p + "/") for p in prefixes)
