"""Validate knowledge-base frontmatter against the km schema — a strict OKF v0.1 profile.

Part of the km package. Loads km's own `schema.base.yaml` (canonical) merged with the brain's
optional `schema.local.yaml` overlay (skip_prefixes / exempt_files / repo-only fields). A
`schema.base.yaml` left in the brain from the copy-in days is ignored with a warning; a legacy
`schema.yaml` serves as the overlay while there is no schema.local.yaml.

Two modes: whole repo (git ls-files, TRACKED .md only) or per-file args (pre-commit).
Exit code 0 if no errors, 1 otherwise. Warnings never fail the build.
Run:  km validate [--root DIR] [--signoff-since BASE] [FILE ...]

--signoff-since BASE (a pull request's check): every doc the branch adds or changes since its merge
base with BASE must be signed off before the merge (with FILEs, those of them). Retired passes, and
served with an approval that covers its content (a moved doc counts as itself); a doc a person must
sign off may stay in review once an AI pre-review is recorded (`reviewed_by`); anything else is a
`signoff` error. A doc whose status and approved content (the digest fields and body) match the
merge base is skipped, so a ripple edit to `related:` or `tags:` never asks for a new sign-off.

A served doc whose content changed since its approval (`approved_digest`, see km.common.DIGEST_FIELDS)
is `approval-stale`: an ERROR with the gate on (a team brain), a WARNING without it.

--- km GATE (opt-in, ADVISORY — a metadata lint, not an enforcement boundary) ---
When `schema.local.yaml` sets `gate.enabled: true`, extra checks run, keyed per concern:
  * secret   (ERROR)   AWS/GitHub keys, private-key headers in ANY tracked doc (incl. exempt/reserved,
                       excl. skip_prefixes) — a key needs no frontmatter
  * leak     (ERROR)   forbidden terms + external emails in a CUSTOMER-facing doc (audience==customer);
                       forbidden terms also in any doc under `term_scan_prefixes`; and, with
                       `project_prefix`, a project folder's name in any doc outside that folder
  * bergab   (ERROR)   a served doc (status==served_status) links to an unfinished (draft/review) doc;
                       a link to superseded/obsolete is a WARNING
  * freshness(WARNING) a served doc whose `review_by` is in the past is stale
Scans normalise NFKC + strip Unicode format chars (Cf) + emphasis. The LINK scan strips code fences;
the secret/leak scans see the whole document (stricter: a forbidden term inside a code sample still
fails). `forbidden_terms` may live inline or in a gitignored `forbidden_terms_file`; a configured-but-
missing file is a WARNING, not silent. Malformed OR unknown gate config fails fast with a clear message.
Gate off/absent = plain behaviour, unchanged. Config keys (optional): enabled, served_status
(default 'accepted'), customer_audience (default 'customer'), forbidden_terms (list),
forbidden_terms_file (path), email_allowlist (list), term_scan_prefixes (list), project_prefix (str),
project_code_pattern (regex). The path-scoped term scan and the project codes run in the text pre-pass
with the secrets, so they also see exempt and _index files; project codes are the tracked subfolders
of project_prefix (fully matching project_code_pattern, if set). Editable-metadata advisory check: catches honest
mistakes before commit, does NOT stop a determined author (that is the publish/release step's job).
"""
from __future__ import annotations

import argparse
import datetime
import re
import sys
import unicodedata
import urllib.parse
from collections import defaultdict
from pathlib import Path

import yaml

from km.common import APPROVAL_LEVELS, EXEMPT, approval_level, body_of, doc_at, OVERLAY, PIN, RETIRED_STATUS, ROOT, SCHEMA, approval_problem, approved_digest, unquoted_scalars, as_list, folder_of, fresh_run, md_named, pin_state, tracked_md
from km.cites import opaque as cite_opaque, problems as cite_problems, uncited
from km.paths import git
from km.pins import movable_refs
from km.common import BASE, PROBLEMS, review_by_days, review_by_default_problem, review_due
from km.common import RESERVED as RESERVED_NF
from km.common import SKIP as SKIP_PREFIXES

_repo_notices = [(n, f"{n} is ignored: km uses its own base schema (run `km upgrade`)")
                 for n in ("schema.base.yaml", "schema.yaml") if (ROOT / n).is_file() and ROOT / n != OVERLAY]
if OVERLAY.name == "schema.yaml":
    _repo_notices.append(("schema.yaml", "schema.yaml is read as the local overlay; `km upgrade` renames it to schema.local.yaml"))

# A schema problem that must stop a run is collected here at import and raised by main() after the
# arguments are parsed, so `km validate --help` answers whatever the schema holds: (what to print on
# stdout, the sys.exit argument); the first one wins, as when each exited at import.
_fatal: list[tuple[str, str | int]] = []

FIELDS = SCHEMA["fields"]
TYPE_RULES = SCHEMA.get("type_rules", {})
SOFT_RULES = SCHEMA.get("type_rules_soft", {})
def _status_rules(raw) -> dict[tuple[str, str], list]:
    """status_rules keys are `<status>_<requires|recommends|forbids>`; a key the brain adds must also
    name a status the schema knows. Anything else fails fast, so a typo never switches a rule off.
    km's own keys are exempt from the status check: a brain may rename its statuses."""
    known = set((FIELDS.get("status") or {}).get("enum") or [])
    own = set(BASE.get("status_rules") or {})
    out, bad = {}, []
    for key, fields in (raw or {}).items():
        st, _, kind = str(key).rpartition("_")
        if (not st or (known and key not in own and st not in known)
                or kind not in ("requires", "recommends", "forbids") or not isinstance(fields, list | None)):
            bad.append(str(key))
        elif fields is not None:      # left empty (every entry commented out): no rule, as km's own keep theirs
            out[(st, kind)] = fields
    if bad:
        _fatal.append(("", f"schema: status_rules key(s) {', '.join(bad)} must be <status>_<requires|recommends|forbids>: "
                           f"[fields], with a status from the schema"))
    return out


STATUS_RULES = _status_rules(SCHEMA.get("status_rules"))

# --- km gate config (opt-in) with fail-fast validation ---
_GATE_KEYS = {
    "enabled", "served_status", "customer_audience",
    "forbidden_terms", "forbidden_terms_file", "email_allowlist",
    "term_scan_prefixes", "project_prefix", "project_code_pattern",
}
_gate_raw = SCHEMA.get("gate")
_gate_cfg_errors: list[str] = []
_gate_notices: list[str] = []
GATE: dict = {}
GATE_ON = False
if _gate_raw is not None:
    if not isinstance(_gate_raw, dict):
        _gate_cfg_errors.append(f"gate: must be a mapping, got {type(_gate_raw).__name__}")
    else:
        GATE = _gate_raw
        for _k in GATE:
            if _k not in _GATE_KEYS:
                _gate_cfg_errors.append(f"unknown gate key {_k!r} (allowed: {', '.join(sorted(_GATE_KEYS))})")
        if "enabled" in GATE and not isinstance(GATE["enabled"], bool):
            _gate_cfg_errors.append("gate.enabled must be true/false")
        for _k in ("served_status", "customer_audience", "forbidden_terms_file", "project_prefix",
                   "project_code_pattern"):
            if _k in GATE and not isinstance(GATE[_k], str):
                _gate_cfg_errors.append(f"gate.{_k} must be a string")
        if isinstance(GATE.get("project_code_pattern"), str):
            try:
                re.compile(GATE["project_code_pattern"])
            except re.error as exc:
                _gate_cfg_errors.append(f"gate.project_code_pattern is not a valid regex: {exc}")
        for _k in ("forbidden_terms", "email_allowlist", "term_scan_prefixes"):
            if _k in GATE and not (isinstance(GATE[_k], list) and all(isinstance(x, str) for x in GATE[_k])):
                _gate_cfg_errors.append(f"gate.{_k} must be a list of strings (a missing '-' makes it a string)")
        GATE_ON = bool(GATE.get("enabled"))
if _gate_cfg_errors:
    _fatal.append(("gate config error(s) in schema.local.yaml:\n" + "".join(f"  - {_e}\n" for _e in _gate_cfg_errors), 1))
    GATE, GATE_ON = {}, False                           # what follows reads the gate at import

SERVED_STATUS = GATE.get("served_status", "accepted")
CUSTOMER_AUDIENCE = GATE.get("customer_audience", "customer")
EMAIL_ALLOWLIST = [d.lower() for d in (GATE.get("email_allowlist") or [])]
_ci_raw = SCHEMA.get("check_index", False)
if not isinstance(_ci_raw, bool):                       # fail-fast on a non-bool, matching gate.enabled
    _fatal.append(("", f"schema.local.yaml: check_index must be true or false, got {_ci_raw!r}"))
CHECK_INDEX = _ci_raw
if SCHEMA.get("approval_default", "human") not in APPROVAL_LEVELS:
    _fatal.append(("", f"schema.local.yaml: approval_default must be ai or human, got {SCHEMA.get('approval_default')!r}"))
if _rbd_why := review_by_default_problem():
    _fatal.append(("", f"schema.local.yaml: {_rbd_why}"))
_fatal.extend(("", _p) for _p in PROBLEMS)          # km.common's, raised here after the arguments, not by km.cli
PROBLEMS.clear()
_isp = SCHEMA.get("index_skip_prefixes") or []
if not (isinstance(_isp, list) and all(isinstance(x, str) for x in _isp)):
    _fatal.append(("", "schema.local.yaml: index_skip_prefixes must be a list of strings"))
    _isp = []
INDEX_SKIP_PREFIXES = tuple(_isp)                       # folders left out of the index lint but still valid link targets


def _load_terms() -> list[str]:
    terms = list(GATE.get("forbidden_terms") or [])
    tf = GATE.get("forbidden_terms_file")
    if tf:
        p = ROOT / tf
        try:
            if p.is_file():
                terms += [
                    ln.strip()
                    for ln in p.read_text(encoding="utf-8").splitlines()
                    if ln.strip() and not ln.startswith("#")
                ]
            else:
                _gate_notices.append(f"forbidden_terms_file '{tf}' configured but not found; leak-term check disabled")
        except OSError as exc:
            _gate_notices.append(f"forbidden_terms_file '{tf}' not readable ({exc.__class__.__name__}); leak-term check disabled")
    return terms


FORBIDDEN_TERMS = _load_terms()


def _folder(s: str) -> str:
    """'bms' and 'bms/' both become 'bms/', so they match 'bms/...' and never 'bmsx/...'."""
    s = s.strip("/")
    return s + "/" if s else ""


TERM_SCAN_PREFIXES = tuple(f for f in map(_folder, GATE.get("term_scan_prefixes") or []) if f)
PROJECT_PREFIX = _folder(GATE.get("project_prefix") or "")


def _load_project_codes() -> list[str]:
    """Tracked subfolders of project_prefix, so a local-only folder never changes the result."""
    if not (GATE_ON and PROJECT_PREFIX):
        return []
    pat = re.compile(GATE.get("project_code_pattern") or ".*")
    subs = {p[len(PROJECT_PREFIX):].split("/", 1)[0] for p in tracked_md()
            if p.startswith(PROJECT_PREFIX) and "/" in p[len(PROJECT_PREFIX):]}
    return sorted(c for c in subs if pat.fullmatch(c))


PROJECT_CODES = _load_project_codes()
SECRET_PATTERNS = {
    "aws-key": re.compile(r"AKIA[0-9A-Z]{16}"),
    "aws-secret": re.compile(r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['\"]?[A-Za-z0-9/+]{40}"),
    "gh-token": re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    "gh-pat": re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    "private-key": re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
HYPHENS = {0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2013: "-", 0x2014: "-"}
INLINE = re.compile(r"\]\(<?([^)>]+)>?\)")
REFDEF = re.compile(r"(?m)^\s*\[(?!\^)[^\]]+\]:\s*(<[^>]*>|\S+)")   # (?!\^) skips footnotes; <...> keeps a spaced target
WIKI = re.compile(r"\[\[([^\]|]+)")
HREF = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""", re.I)
TODAY = datetime.date.today()

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$")

errors: list[tuple[str, str, str]] = []    # (category, path, detail); filled by main()
warnings: list[tuple[str, str, str]] = []


def is_validatable(p: str) -> bool:
    if not p or p.startswith(SKIP_PREFIXES):
        return False
    name = p.rsplit("/", 1)[-1]
    return name != "_index.md" and name not in EXEMPT


def targets(given: list[str]) -> list[str]:
    """The FILEs given (e.g. pre-commit staged files) else the whole repo."""
    if given:
        out = []
        for a in given:
            try:
                rel = Path(a).resolve().relative_to(ROOT).as_posix()
            except ValueError:
                print(f"skip (outside repo): {a}", file=sys.stderr)
                continue
            if rel.endswith(".md") and is_validatable(rel) and (ROOT / rel).is_file():
                out.append(rel)
        return out
    return [p for p in tracked_md() if is_validatable(p)]


def secret_targets(given: list[str]) -> list[str]:
    """Files to secret-scan: like targets() but WITHOUT the exempt/reserved/_index exclusion
    (a key needs no frontmatter), still honouring skip_prefixes."""
    if given:
        out = []
        for a in given:
            try:
                rel = Path(a).resolve().relative_to(ROOT).as_posix()
            except ValueError:
                continue
            if rel.endswith(".md") and not rel.startswith(SKIP_PREFIXES) and (ROOT / rel).is_file():
                out.append(rel)
        return out
    return [p for p in tracked_md() if not p.startswith(SKIP_PREFIXES)]


def frontmatter(text: str):
    if not text.startswith("---"):
        return None
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    try:
        return yaml.safe_load(m.group(1)) or {}
    except (yaml.YAMLError, ValueError) as exc:   # ValueError: a date YAML cannot build (2026-02-30)
        return {"__error__": str(exc)}


def resolve_ref(rel: str, target: str) -> bool:
    target = target.split("@", 1)[0].strip()
    if not target.endswith(".md"):
        return True
    if (ROOT / target.lstrip("/")).exists():
        return True
    return ((ROOT / rel).parent / target).exists()


PIN_PROBLEMS = {
    "unknown": "not in this clone's git history (a shallow clone, a rewritten commit, a renamed "
               "source); check the doc against {path}, then `km repin`",
    "untracked": "{path} is not tracked",
    "stale": "{path} changed since the pin; re-review, then `km repin`",
}


def pin_problem(field: str, pin: str) -> tuple[str, str] | None:
    """What is wrong with a path.md@hash source pin, as a warning (category, detail), or None.

    The hash names the source's own blob, or a commit that holds the source; a blob depends only on
    the file's content, so it survives a rebase or squash merge that rewrites the commit. The pinned
    content is compared with the source as staged (see km.common.pin_state)."""
    path = PIN.match(pin).group(1)
    if (old := doc_status(path.lstrip("/"))) in RETIRED_STATUS:   # before stale: repin would pin the retired text
        return "pin:old", f"{pin!r}: the source is {old}; point the doc at what replaced it"
    state = pin_state(pin)
    if state == "current":
        return None
    detail = f"{pin!r}: " + PIN_PROBLEMS[state].format(path=path)
    return ("pin:stale" if state == "stale" else f"pin:{field}"), detail


# --- gate helpers ---
_status_cache: dict[str, str | None] = {}


def doc_status(target_rel: str) -> str | None:
    if target_rel in _status_cache:
        return _status_cache[target_rel]
    p = ROOT / target_rel
    st = None
    if p.is_file():
        fm2 = frontmatter(p.read_text(encoding="utf-8-sig", errors="replace"))
        if isinstance(fm2, dict):
            st = fm2.get("status")
    _status_cache[target_rel] = st
    return st


def resolve_path(rel: str, target: str) -> str | None:
    """Resolve a link/ref target to a repo-CONTAINED .md path, or None. Document-relative is
    tried FIRST (Markdown semantics), then repo-root-relative; both are containment-checked so
    `../escape.md` is never trusted as in-repo."""
    parts = target.split()
    target = (parts[0] if parts else "").split("@", 1)[0].split("#", 1)[0].strip()
    if not target or not target.endswith(".md"):
        return None
    for cand in (((ROOT / rel).parent / target), (ROOT / target.lstrip("/"))):
        try:
            rp = cand.resolve()
            rp.relative_to(ROOT)
            if rp.is_file():
                return str(rp.relative_to(ROOT))
        except (ValueError, OSError):
            continue
    return None


def resolve_slug(nm: str) -> str | None:
    """A bare [[slug]]: the first, in sorted order and outside skip_prefixes, of the files named
    `slug.md` that km.common.md_named finds (exact name, no glob; a gitignored draft is none).
    Links written as paths (resolve_path, doc_status) read the disk, gitignored files included."""
    nm = nm.strip()
    if not nm or "/" in nm or nm.endswith(".md"):
        return None
    return next((p for p in md_named(f"{nm}.md") if not p.startswith(SKIP_PREFIXES)), None)


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Cf")   # strip all Unicode format chars
    return s.translate(HYPHENS)


def _squash(s: str) -> str:
    """Already-normalised text as the term scans compare it: emphasis stripped, lower case."""
    return s.replace("*", "").replace("_", "").lower()


def _fold(s: str) -> str:
    return _squash(_norm(s))


_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})")
_OPENS_BLOCK = re.compile(r"\s*(?:[-*+]|\d+[.)])\s|\[\^[^\]]+\]:|(?: {4}|\t)")   # list item, footnote, nested


def _strip_blocks(s: str) -> str:
    """Fenced (``` or ~~~, closed by the same character, at least as long) and indented code blocks
    blanked, line by line. An indented block must follow a blank line whose text before is neither a
    list item, a footnote nor indented: there it is that item's next paragraph, whose links count.
    Used for the cite:missing scan; the link checks keep `_strip_code` as it was."""
    out, blank, last, fence, code = [], True, "", "", False
    for ln in s.split("\n"):
        if fence:
            m = _FENCE.match(ln)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not ln[m.end():].strip():
                fence = ""
            out.append("")
            continue
        if (m := _FENCE.match(ln)) and not code:
            fence = m.group(1)
            out.append("")
            continue
        empty, indented = not ln.strip(), ln.startswith(("    ", "\t"))
        code = (code and (indented or empty)) or (indented and blank and not _OPENS_BLOCK.match(last))
        out.append("" if code else ln)
        if not code and not empty:
            last = ln
        blank = empty
    return "\n".join(out)


def _strip_code(s: str) -> str:
    s = re.sub(r"<!--.*?-->", " ", s, flags=re.S)   # HTML comments are not links
    s = re.sub(r"```.*?```", " ", s, flags=re.S)
    return re.sub(r"`[^`]*`", " ", s)


def _redact(s: str) -> str:
    s = s.strip()
    return s[:2] + "…" + s[-2:] if len(s) > 6 else "…"


def link_targets(text: str):
    body = _strip_code(text)
    for pat in (INLINE, REFDEF, WIKI, HREF):
        for m in pat.finditer(body):
            yield m.group(1)


_TITLE = re.compile(r'^(\S.*?)\s+("[^"]*"|\'[^\']*\')\s*$')   # strip a quoted title (either quote may nest in the other)
_SCHEME = re.compile(r"^[a-z][a-z0-9+.\-]*:", re.I)        # any URL scheme (http:, mailto:, ftp:, ...)


def _join_repo(base: str, target: str) -> str | None:
    """Join a repo-relative link target onto `base` dir, collapse '.'/'..', reject escapes above
    ROOT. Returns a normalized repo-relative path (no leading slash) or None."""
    segs: list[str] = []
    for seg in (f"{base}/{target}" if base else target).split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not segs:
                return None
            segs.pop()
        else:
            segs.append(seg)
    return "/".join(segs) or None


def check_index_tree() -> None:
    """Opt-in (check_index: true): navigation lint on `_index.md` files, reported as WARNINGS
    (`_index.md` is otherwise excluded from article validation):
      * index-missing    a folder holds CONTENT docs, or a subfolder with an `_index.md`, but has
                         no `_index.md` of its own
      * index-incomplete an `_index.md` fails to link a content doc in its own folder, or the
                         `_index.md` of a direct subfolder
      * index-dead-link  an `_index.md` links a `.md` that is not a tracked repo file
    'Content docs' = real articles only (excludes `_index.md`, exempt files, and index.md/log.md
    — the same notion is_validatable() uses). The dead-link scan runs on EVERY `_index.md`,
    including a navigation hub whose folder has no direct docs. Link targets resolve against the
    FULL git-TRACKED file set (not disk), so results are clone-stable and case-exact and a link
    into a skip_prefixes folder is not dead; a relative target resolves document-relative first
    then repo-root, an absolute /path at the root only; angle brackets, a quoted title and a
    #fragment are stripped and %-escapes decoded first. A bare [[slug]] that is no tracked path
    falls back to the gate's lookup by name (resolve_slug); a doc of the index's own folder is always found as a path first, so that never
    changes what an index is credited with. Each `_index.md` covers its own folder: its
    docs plus the `_index.md` of each direct subfolder, so every folder is reachable from the one
    above it. The root `_index.md` is optional; where it exists it must link the top-level folders
    that have an index. `skip_prefixes`
    folders and `index_skip_prefixes` folders are not linted (the latter is the index-only opt-out,
    leaving article validation on). Whole-repo only: skipped on per-file (pre-commit) runs."""
    tracked = set(tracked_md(existing=False))                       # existence oracle: ALL tracked .md
    walk = {p for p in tracked                                      # only these folders are linted
            if not p.startswith(SKIP_PREFIXES) and not p.startswith(INDEX_SKIP_PREFIXES)}

    def _resolve(base: str, raw: str) -> tuple[str | None, str]:
        """(tracked repo path or None, cleaned target for reporting). Existence is checked against
        the FULL tracked set, so a link into a skip_prefixes folder is NOT a dead link."""
        t = str(raw).strip()
        if t.startswith("<") and t.endswith(">"):
            t = t[1:-1].strip()
        mt = _TITLE.match(t)                       # drop a quoted markdown title (not a bare space)
        if mt:
            t = mt.group(1).strip()
        t = urllib.parse.unquote(t.split("#", 1)[0].strip())
        if not t or _SCHEME.match(t):
            return None, ""                        # external / non-repo target: never a dead *repo* link
        probe = t if t.endswith(".md") else t + ".md"
        if probe.startswith("/"):
            cands = (_join_repo("", probe.lstrip("/")),)              # absolute: root only
        else:
            cands = (_join_repo(base, probe), _join_repo("", probe))  # doc-relative first, then root
        for cand in cands:
            if cand and cand in tracked:
                return cand, t
        if not t.endswith(".md") and "/" not in t:                   # bare [[slug]]: by name, as the gate resolves it
            return resolve_slug(t), t
        return None, (t if t.endswith(".md") else "")                # unresolved slug/wiki: not a *.md dead link

    by_folder: dict[str, list[str]] = defaultdict(list)
    for p in walk:
        by_folder[folder_of(p)].append(p)
        if p.endswith("/_index.md"):                                # a subfolder is reached through its index
            parent = folder_of(folder_of(p))
            if parent != "." or "_index.md" in walk:                 # the root map is optional
                by_folder[parent].append(p)
    for folder, members in sorted(by_folder.items()):
        base = "" if folder == "." else folder
        idx = "_index.md" if folder == "." else f"{folder}/_index.md"
        docs = [m for m in members if is_validatable(m) and m.rsplit("/", 1)[-1] not in RESERVED_NF
                or m.endswith("/_index.md") and m != idx]
        if idx not in walk:
            if docs:
                warnings.append(("index-missing", f"{folder}/", f"folder has {len(docs)} doc(s) or subfolder index(es) but no _index.md"))
            continue
        idx_path = ROOT / idx
        if not idx_path.is_file():                 # tracked but absent from the worktree (staged deletion)
            warnings.append(("index-missing", f"{folder}/", "_index.md is tracked but absent from the worktree"))
            continue
        linked: set[str] = set()
        dead: set[str] = set()                     # dedup identical dead targets
        for _tgt in link_targets(idx_path.read_text(encoding="utf-8-sig", errors="replace")):
            _tp, _clean = _resolve(base, _tgt)
            if _tp:
                linked.add(_tp)
            elif _clean.endswith(".md"):
                dead.add(_clean)
        for _dl in sorted(dead):
            warnings.append(("index-dead-link", idx, f"links missing {_dl}"))
        for _d in sorted(set(docs) - linked):
            warnings.append(("index-incomplete", idx, f"does not link {_d}"))


TERM_NEEDLES = [(t, n) for t in FORBIDDEN_TERMS if (n := _fold(t))]
def _code_text(normed: str) -> str:
    """Like _squash, but '_' separates words: a code in `acme01_log.md` must still stand alone."""
    return normed.replace("*", "").replace("_", " ").lower()


CODE_NEEDLES = [(c, n, re.compile(rf"(?<![a-z0-9]){re.escape(n)}(?![a-z0-9])"))
                for c in PROJECT_CODES if (n := _code_text(_norm(c)).strip())]


def _term_errors(rel: str, scan: str) -> list[tuple[str, str, str]]:
    return [("gate-leak:term", rel, f"forbidden term {_redact(t)}") for t, n in TERM_NEEDLES if n in scan]


def changed_since(base: str) -> tuple[str, dict[str, str | None]] | None:
    """(merge base, {doc the branch adds or changes: its path at the merge base, None for a new one})
    for the merge base with `base`; a moved doc keeps its old path. None when git cannot name it."""
    found = git("merge-base", base, "HEAD", cwd=ROOT)
    if found.returncode:
        return None
    mb = found.stdout.strip()
    diff = git("diff", "-z", "--name-status", "-M", "--diff-filter=d", "--relative", mb, "HEAD", "--", "*.md", cwd=ROOT)
    if diff.returncode:
        return None
    out, parts = {}, diff.stdout.split("\0")
    while len(parts) > 1:
        status, parts = parts[0], parts[1:]
        if status[:1] in "RC":                      # rename or copy: old path, then new path
            out[parts[1]], parts = parts[0], parts[2:]
        else:
            out[parts[0]], parts = (None if status == "A" else parts[0]), parts[1:]
    return mb, out


def signoff_problem(fm: dict, body: str, then: tuple[dict | None, str] | None) -> str | None:
    """Why a changed doc may not be merged yet (`then`: its frontmatter and body at the merge base), or None."""
    st = fm.get("status")
    if st in RETIRED_STATUS:
        return None
    old = then[0] if then and then[0] is not None else None
    same = old is not None and old.get("status") == st and approved_digest(old, then[1]) == approved_digest(fm, body)
    if same:
        return None                                  # only bookkeeping fields changed: no new sign-off due
    if st == SERVED_STATUS:
        if not fm.get("approved_by"):
            return f"is {st} without approved_by: sign it off with `km approve`, never by setting the status by hand"
        if (dg := fm.get("approved_digest")) is not None:   # the content the approval saw; with the gate on approval-stale reports it
            covered = GATE_ON or str(dg) == approved_digest(fm, body)
        else:                                        # approved before km recorded a digest: a new approval in this PR covers it
            covered = old is None or any(old.get(k) != fm.get(k) for k in ("status", "approved_by", "approved_at"))
        return None if covered else ("changed since its sign-off: `km demote` it in this commit, then `km approve` it "
                                     "after review in a commit of its own")
    level = approval_level(fm)
    if st == "review" and level == "human" and as_list(fm.get("reviewed_by")):
        return None                                  # waits for the person, with the AI review on record
    how = ("`/km review`, then `km approve --by ai:<model>` in a commit of its own" if level == "ai"
           else "`/km review` recorded in `reviewed_by`, then a person's `km approve`")
    if st != "review":
        how = f"finish it and set `status: review`, then {how}"
    return f"is {st or 'without a status'}, not signed off: {how}"

def report(title: str, items: list[tuple[str, str, str]]) -> None:
    print(f"\n{title}: {len(items)}")
    by_cat: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for cat, rel, detail in items:
        by_cat[cat].append((rel, detail))
    for cat, rows in sorted(by_cat.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(rows):>4} x {cat}")
        for rel, detail in rows[:4]:
            print(f"          {rel} - {detail}")
        if len(rows) > 4:
            print(f"          ... +{len(rows) - 4} more")


def main() -> int:
    ap = argparse.ArgumentParser(prog="km validate", allow_abbrev=False,
                                 description="Validate the brain's docs; with FILEs only those (pre-commit).")
    ap.add_argument("files", nargs="*", metavar="FILE", help="files to check (others are skipped); none: the whole repo")
    ap.add_argument("--signoff-since", metavar="BASE",
                    help="also require a sign-off on every doc changed since the merge base with BASE (a pull request's check)")
    args = ap.parse_args()
    given = args.files
    if _fatal:
        print(_fatal[0][0], end="")
        sys.exit(_fatal[0][1])
    mb, changed = None, {}
    if args.signoff_since:
        mb, changed = changed_since(args.signoff_since) or (None, None)
    if changed is None:
        print(f"km validate: no merge base with {args.signoff_since} (fetch it, or check out the full history)", file=sys.stderr)
        return 2
    fresh_run()
    errors.clear()
    warnings.clear()
    _status_cache.clear()
    warnings.extend(("gate-config", "schema.local.yaml", _n) for _n in _gate_notices)
    warnings.extend(("km", _f, _n) for _f, _n in _repo_notices)
    # --- text pre-pass over ANY tracked doc (frontmatter or not): secrets, and the path-keyed leak
    # scans (terms under term_scan_prefixes, project codes outside their own folder) ---
    if GATE_ON:
        for _sf in secret_targets(given):
            _stext = _norm((ROOT / _sf).read_text(encoding="utf-8-sig", errors="replace"))
            for _snm, _spat in SECRET_PATTERNS.items():
                for _smm in _spat.finditer(_stext):
                    errors.append((f"gate-secret:{_snm}", _sf, f"match {_redact(_smm.group(0))}"))
            _scoped = _sf.startswith(TERM_SCAN_PREFIXES)
            if not (_scoped or CODE_NEEDLES):
                continue
            if _scoped:
                errors.extend(_term_errors(_sf, _squash(_stext)))
            _rest = _sf[len(PROJECT_PREFIX):] if PROJECT_PREFIX and _sf.startswith(PROJECT_PREFIX) else None
            if _rest is not None and "/" not in _rest:
                continue                              # a hub file such as projects/_index.md lists every code
            _own = _rest.split("/", 1)[0] if _rest else None
            _scan = _code_text(_stext)
            for _c, _n, _rx in CODE_NEEDLES:
                if _c != _own and _n in _scan and _rx.search(_scan):   # substring first: the regex is slow
                    errors.append(("gate-leak:code", _sf, f"project code {_redact(_c)} outside its own folder"))

    _target_list = targets(given)
    for rel in _target_list:
        name = rel.rsplit("/", 1)[-1]
        text = (ROOT / rel).read_text(encoding="utf-8-sig", errors="replace")
        fm = frontmatter(text)

        if name in RESERVED_NF:
            if fm is not None:
                errors.append(("reserved-file", rel, f"'{name}' must have no frontmatter"))
            continue
        if fm is None:
            errors.append(("no-frontmatter", rel, "missing YAML frontmatter"))
            continue
        if isinstance(fm, dict) and "__error__" in fm:
            errors.append(("unparseable", rel, fm["__error__"]))
            continue
        if not isinstance(fm, dict):
            errors.append(("non-mapping", rel, "frontmatter is not a key:value mapping"))
            continue

        body = body_of(text)
        # the digest as km approve computes it: before the aliases below change the frontmatter
        digest = approved_digest(fm, body) if fm.get("approved_digest") else None
        if rel in changed and (_why := signoff_problem(fm, body, changed[rel] and doc_at(mb, changed[rel]))):
            errors.append(("signoff", rel, _why))
        # apply field aliases declared in the schema (e.g. date -> timestamp)
        for _field, _spec in FIELDS.items():
            _alias = _spec.get("alias")
            if _alias and _field not in fm and _alias in fm:
                fm[_field] = fm[_alias]

        for field, spec in FIELDS.items():
            if spec.get("required") and field not in fm:
                errors.append((f"missing:{field}", rel, f"required field '{field}' absent"))
            if field in fm and "enum" in spec and fm[field] not in spec["enum"]:
                errors.append((f"enum:{field}", rel, f"{field}={fm[field]!r}"))
            if field in fm and spec.get("type") == "list" and not isinstance(fm[field], list):
                errors.append((f"type:{field}", rel, f"{field} must be a list"))
            if field in fm and spec.get("format") == "iso8601" and not ISO.match(str(fm[field])):
                warnings.append((f"iso8601:{field}", rel, f"{field}={fm[field]!r}"))
            if field in fm and spec.get("format") == "path_at_hash":
                for v in as_list(fm[field]):
                    if not v:
                        continue
                    if not PIN.match(str(v)):
                        warnings.append((f"pin:{field}", rel, f"{v!r} not path.md@hash"))
                    elif fm.get("status") not in RETIRED_STATUS and (_why := pin_problem(field, str(v))):
                        warnings.append((_why[0], rel, _why[1]))
            if field in fm and spec.get("format") == "url_digest" and isinstance(fm[field], list):
                errors.extend(("cite:format", rel, p) for p in cite_problems(fm[field]))
            if field in fm and spec.get("ref"):
                for v in as_list(fm[field]):
                    if v and not resolve_ref(rel, str(v)):
                        warnings.append((f"ref:{field}", rel, f"missing target {v}"))

        if fm.get("status") not in RETIRED_STATUS:   # a SharePoint/OneDrive link should be pinned too
            for _url in uncited(body, fm, lambda b: _strip_code(_strip_blocks(b))):
                warnings.append(("cite:missing", rel, f"links {_url}, a sharing or viewer link that names the file by "
                                 f"a token: link the file's path URL instead and cite that (`km cite add`)" if cite_opaque(_url)
                                 else f"links {_url} with no cites: entry (`km cite add`)"))

        t = fm.get("type")
        rule = TYPE_RULES.get(t, {}) if isinstance(t, str) else {}
        for req in rule.get("require", []):
            if req not in fm:
                errors.append((f"type-rule:{t}", rel, f"type '{t}' requires '{req}'"))
        soft = SOFT_RULES.get(t, {}) if isinstance(t, str) else {}
        for rec in soft.get("recommend", []):
            if rec not in fm:
                warnings.append((f"soft:{t}", rel, f"type '{t}' should have '{rec}'"))

        st = fm.get("status")
        for (_st, _kind), _fields in STATUS_RULES.items():
            if _st != st:
                continue
            for r in _fields:
                # review_by is the one field whose need depends on the type: one that does not expire has none
                if _kind == "requires" and r not in fm and (r != "review_by" or review_by_days(t)):
                    errors.append(("status-rule", rel, f"{st} requires '{r}'"))
                elif _kind == "forbids" and r in fm:
                    warnings.append(("status-rule", rel, f"{st} should not set '{r}'"))
                elif _kind == "recommends" and r not in fm:
                    warnings.append(("status-soft", rel, f"{st} should record '{r}'"))
        # an ai: approver counts only on a signed-off doc; a contradicting `approval` always does
        _why = approval_problem(fm, None if st == SERVED_STATUS else "")
        if _why:
            errors.append(("approval", rel, _why))
        # an approval vouches for the content it saw; a doc approved before the digest existed has none
        if st == SERVED_STATUS and (_dg := fm.get("approved_digest")) and str(_dg) != digest:
            (errors if GATE_ON else warnings).append((
                "approval-stale", rel, f"content changed since approved_by {fm.get('approved_by')} signed it off on "
                f"{fm.get('approved_at')}: send it back to review in the same commit (`km demote {rel}`), then approve "
                f"it after review in a commit of its own (`km approve {rel} --by <approver>`); or revert the change"))
        if st == SERVED_STATUS and (_typed := unquoted_scalars(fm)):
            warnings.append(("approval-quote", rel, f"{', '.join(_typed)} holds an unquoted number or yes/no, which YAML "
                             f"changes (1.10 reads as 1.1): quote it, so the approval covers the text as written"))

        # --- km GATE (opt-in, advisory) — leak / bergab / freshness (secrets are a separate pass) ---
        if GATE_ON:
            served = fm.get("status") == SERVED_STATUS
            customer = fm.get("audience") == CUSTOMER_AUDIENCE
            if customer:
                normed = _norm(text)
                if not rel.startswith(TERM_SCAN_PREFIXES):   # else the pre-pass already scanned it
                    errors.extend(_term_errors(rel, _squash(normed)))
                for _mm in EMAIL.finditer(normed):
                    if _mm.group(0).rsplit("@", 1)[-1].lower() not in EMAIL_ALLOWLIST:
                        errors.append(("gate-leak:email", rel, f"external email {_redact(_mm.group(0))}"))
            if served:
                _refs = as_list(fm.get("related"))
                for _tgt in list(link_targets(text)) + [str(x) for x in _refs]:
                    _tp = resolve_path(rel, str(_tgt)) or resolve_slug(str(_tgt))
                    if not _tp or _tp == rel or _tp.startswith(SKIP_PREFIXES):
                        continue
                    _st2 = doc_status(_tp)
                    if _st2 in ("draft", "review"):
                        errors.append(("gate-bergab", rel, f"served doc links to unfinished ({_st2}) {_tp}"))
                    elif _st2 in RETIRED_STATUS:
                        warnings.append(("gate-bergab-old", rel, f"served doc links to {_st2} {_tp}"))
                if (_due := review_due(fm)) and _due < TODAY:   # none for a type that does not expire
                    warnings.append(("gate-stale", rel, f"review_by {fm.get('review_by')} is in the past"))


    if CHECK_INDEX and not given:   # whole-repo lint only; skip on per-file (pre-commit) runs
        check_index_tree()
    if not given:                    # code the brain runs from a movable ref instead of a commit (see km.pins)
        for _f, _what in movable_refs(ROOT):
            warnings.append(("movable-ref", _f, f"runs {_what}, a ref that can be moved; pin it by commit "
                                                f"(`km upgrade` does it for km)"))

    report("ERRORS", errors)
    report("WARNINGS", warnings)
    print()
    if GATE_ON and given and not (_target_list or secret_targets(given)):
        print("no validatable .md matched the given paths", file=sys.stderr)
        return 2
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
