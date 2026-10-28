"""What every km command shares: the brain's root, the merged schema (km's own base overlaid by the
brain's schema.local.yaml; lists extend, dicts shallow-merge), frontmatter parsing, the tracked-file
list and what counts as an article. One loader for all commands, so none of them acts on a different
configuration than the validator checks; a broken schema file stops the run.
"""
from __future__ import annotations

import atexit
import functools
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
    out = dict(base)
    for k, v in (local or {}).items():
        cur = out.get(k)
        if isinstance(v, list) and isinstance(cur, list):
            out[k] = cur + v
        elif isinstance(v, dict) and isinstance(cur, dict):
            out[k] = {**cur, **v}
        else:
            out[k] = v
    return out


# The brain's overlay. A brain from before the overlay existed has only a legacy schema.yaml (km's
# schema plus its own additions); it overlays the base the same way until `km upgrade` renames it.
OVERLAY = ROOT / ("schema.local.yaml" if (ROOT / "schema.local.yaml").is_file() or not (ROOT / "schema.yaml").is_file()
                  else "schema.yaml")
SCHEMA = _merge(_load(BASE_SCHEMA) or {}, _load(OVERLAY))

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
APPROVAL_FIELDS = ("approved_by", "approved_at")
APPROVAL_LEVELS = ("ai", "human")
INTERNAL_AUDIENCE = "internal"
APPROVAL_DEFAULT = "ai" if SCHEMA.get("approval_default") == "ai" else "human"   # a bad value is reported by `km validate`


def is_ai_approver(who) -> bool:
    """Signed off by AI alone: every approver (one, or a list) is `ai:<model>`; a person among them
    counts as a human sign-off."""
    ws = [str(w).strip().lower() for w in as_list(who) if w]
    return bool(ws) and all(w.startswith("ai:") for w in ws)


def approval_problem(fm: dict, approver=None) -> str | None:
    """Why `approver` (default: the doc's approved_by) may not sign this doc off, or None."""
    may = fm.get("audience", INTERNAL_AUDIENCE) == INTERNAL_AUDIENCE and fm.get("type") != "verbatim-block"
    if fm.get("approval") == "ai" and not may:
        return "'approval: ai' is only allowed on an internal doc that is not a verbatim-block"
    level = (fm.get("approval") or APPROVAL_DEFAULT) if may else "human"
    if not is_ai_approver(fm.get("approved_by") if approver is None else approver):
        return None
    if level != "ai":
        return ("only an internal doc may take an AI approver, this one needs a human approver" if not may
                else "an AI approver needs 'approval: ai' or approval_default: ai")
    if fm.get("audience") != INTERNAL_AUDIENCE:
        return "an AI approver needs 'audience: internal' set explicitly"
    return None


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
    for cached in (_ls_md, unstaged, staged_blob, pinned_blob, _body):
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
    if n:
        return new
    end = raw.rstrip("\n").rfind("\n---")
    return raw[:end] + "\n" + line + raw[end:]


def demote_raw(raw: str) -> str | None:
    """A served doc's raw '---' block back at `status: review`, its approval lines dropped; the status
    line edited in place, no YAML round-trip. None if no status line can be rewritten."""
    new, n = re.subn(rf"(?m)^status:[ \t]*['\"]?{re.escape(SERVED_STATUS)}['\"]?[ \t]*(#.*)?$", "status: review", raw)
    return re.sub(r"(?m)^approved_(?:by|at):.*\n", "", new) if n == 1 else None


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


def split_frontmatter(text: str) -> tuple[dict | None, str, str]:
    """(frontmatter or None, the raw '---' block, body). No or unparsable block: (None, '', text)."""
    m = _FM.match(text)
    if not m:
        return None, "", text
    try:
        fm = yaml.safe_load(m.group(2)) or {}
    except yaml.YAMLError:
        return None, "", text
    return (fm if isinstance(fm, dict) else None), m.group(1), m.group(3)


def frontmatter(text: str) -> dict:
    return split_frontmatter(text)[0] or {}


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")


@functools.cache
def _ls_md() -> tuple[str, ...]:
    res = git("ls-files", "-z", "*.md", cwd=ROOT)
    if res.returncode != 0:
        sys.exit(f"git ls-files failed (not a git repo?): {res.stderr.strip()}")
    return tuple(p for p in res.stdout.split("\x00") if p)


def tracked_md(existing: bool = True) -> list[str]:
    """The tracked .md files, listed by git once per run; with existing=False also those deleted but
    not yet staged."""
    return [p for p in _ls_md() if not existing or (ROOT / p).is_file()]


def is_article(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return not rel.startswith(SKIP) and name != "_index.md" and name not in EXEMPT and name not in RESERVED


def folder_of(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else "."
