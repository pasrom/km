# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Validate knowledge-base frontmatter against the km schema — a strict OKF v0.1 profile.

km-owned engine. Vendored into each brain at `scripts/validate.py` and refreshed via
`/km upgrade`. Loads `schema.base.yaml` (canonical) merged with an optional repo-local
`schema.local.yaml` overlay (skip_prefixes / exempt_files / repo-only fields). Falls back
to a single legacy `schema.yaml` for un-migrated repos.

Two modes: whole repo (git ls-files, TRACKED .md only) or per-file args (pre-commit).
Exit code 0 if no errors, 1 otherwise. Warnings never fail the build.
Run:  uv run scripts/validate.py

--- km GATE (opt-in, ADVISORY — a metadata lint, not an enforcement boundary) ---
When `schema.local.yaml` sets `gate.enabled: true`, extra checks run, keyed per concern:
  * secret   (ERROR)   AWS/GitHub keys, private-key headers in ANY tracked doc (incl. exempt/reserved,
                       excl. skip_prefixes) — a key needs no frontmatter
  * leak     (ERROR)   forbidden terms + external emails in a CUSTOMER-facing doc (audience==customer)
  * bergab   (ERROR)   a served doc (status==served_status) links to an unfinished (draft/review) doc;
                       a link to superseded/obsolete is a WARNING
  * freshness(WARNING) a served doc whose `review_by` is in the past is stale
Scans normalise NFKC + strip Unicode format chars (Cf) + emphasis. The LINK scan strips code fences;
the secret/leak scans see the whole document (stricter: a forbidden term inside a code sample still
fails). `forbidden_terms` may live inline or in a gitignored `forbidden_terms_file`; a configured-but-
missing file is a WARNING, not silent. Malformed OR unknown gate config fails fast with a clear message.
Gate off/absent = plain behaviour, unchanged. Config keys (optional): enabled, served_status
(default 'accepted'), customer_audience (default 'customer'), forbidden_terms (list),
forbidden_terms_file (path), email_allowlist (list). Editable-metadata advisory check: catches honest
mistakes before commit, does NOT stop a determined author (that is the publish/release step's job).
"""
from __future__ import annotations

import datetime
import re
import subprocess
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str):
    p = ROOT / name
    return yaml.safe_load(p.read_text()) if p.is_file() else None


def _merge(base: dict, local: dict | None) -> dict:
    """Overlay local onto base: extend lists, shallow-merge dicts, override scalars."""
    out = dict(base)
    for k, v in (local or {}).items():
        cur = out.get(k)
        if isinstance(v, list) and isinstance(cur, list):
            out[k] = cur + v
        elif isinstance(v, dict) and isinstance(cur, dict):
            merged = dict(cur)
            merged.update(v)
            out[k] = merged
        else:
            out[k] = v
    return out


BASE = _load("schema.base.yaml")
if BASE is None:
    BASE = _load("schema.yaml")          # legacy single-file fallback
if BASE is None:
    sys.exit("no schema.base.yaml (or schema.yaml) at repo root")
SCHEMA = _merge(BASE, _load("schema.local.yaml"))

FIELDS = SCHEMA["fields"]
TYPE_RULES = SCHEMA.get("type_rules", {})
SOFT_RULES = SCHEMA.get("type_rules_soft", {})
STATUS_RULES = SCHEMA.get("status_rules", {})
EXEMPT = set(SCHEMA.get("exempt_files", []))
RESERVED_NF = set(SCHEMA.get("reserved_no_frontmatter", []))
SKIP_PREFIXES = tuple(SCHEMA.get("skip_prefixes", []))

# --- km gate config (opt-in) with fail-fast validation ---
_GATE_KEYS = {
    "enabled", "served_status", "customer_audience",
    "forbidden_terms", "forbidden_terms_file", "email_allowlist",
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
        for _k in ("served_status", "customer_audience", "forbidden_terms_file"):
            if _k in GATE and not isinstance(GATE[_k], str):
                _gate_cfg_errors.append(f"gate.{_k} must be a string")
        for _k in ("forbidden_terms", "email_allowlist"):
            if _k in GATE and not (isinstance(GATE[_k], list) and all(isinstance(x, str) for x in GATE[_k])):
                _gate_cfg_errors.append(f"gate.{_k} must be a list of strings (a missing '-' makes it a string)")
        GATE_ON = bool(GATE.get("enabled"))
if _gate_cfg_errors:
    print("gate config error(s) in schema.local.yaml:")
    for _e in _gate_cfg_errors:
        print("  -", _e)
    sys.exit(1)

SERVED_STATUS = GATE.get("served_status", "accepted")
CUSTOMER_AUDIENCE = GATE.get("customer_audience", "customer")
EMAIL_ALLOWLIST = [d.lower() for d in (GATE.get("email_allowlist") or [])]


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
REFDEF = re.compile(r"(?m)^\s*\[[^\]]+\]:\s*(\S+)")
WIKI = re.compile(r"\[\[([^\]|]+)")
HREF = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""", re.I)
TODAY = datetime.date.today()

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$")
PATH_AT_HASH = re.compile(r"^.+\.md@[0-9a-fA-F]{7,40}$")

errors: list[tuple[str, str, str]] = []    # (category, path, detail)
warnings: list[tuple[str, str, str]] = []
for _n in _gate_notices:
    warnings.append(("gate-config", "schema.local.yaml", _n))


def is_validatable(p: str) -> bool:
    if not p or p.startswith(SKIP_PREFIXES):
        return False
    name = p.rsplit("/", 1)[-1]
    return name != "_index.md" and name not in EXEMPT


def _args() -> list[str]:
    return [a for a in sys.argv[1:] if not a.startswith("-")]


def targets() -> list[str]:
    """Files passed as args (e.g. pre-commit staged files) else the whole repo."""
    given = _args()
    if given:
        out = []
        for a in given:
            try:
                rel = str(Path(a).resolve().relative_to(ROOT))
            except ValueError:
                print(f"skip (outside repo): {a}", file=sys.stderr)
                continue
            if rel.endswith(".md") and is_validatable(rel) and (ROOT / rel).is_file():
                out.append(rel)
        return out
    res = subprocess.run(
        ["git", "ls-files", "-z", "*.md"], cwd=ROOT, capture_output=True, text=True
    )
    if res.returncode != 0:
        sys.exit(f"git ls-files failed (not a git repo?): {res.stderr.strip()}")
    return [p for p in res.stdout.split("\x00") if is_validatable(p)]


def secret_targets() -> list[str]:
    """Files to secret-scan: like targets() but WITHOUT the exempt/reserved/_index exclusion
    (a key needs no frontmatter), still honouring skip_prefixes."""
    given = _args()
    if given:
        out = []
        for a in given:
            try:
                rel = str(Path(a).resolve().relative_to(ROOT))
            except ValueError:
                continue
            if rel.endswith(".md") and not rel.startswith(SKIP_PREFIXES) and (ROOT / rel).is_file():
                out.append(rel)
        return out
    res = subprocess.run(
        ["git", "ls-files", "-z", "*.md"], cwd=ROOT, capture_output=True, text=True
    )
    if res.returncode != 0:
        return []
    return [p for p in res.stdout.split("\x00") if p and not p.startswith(SKIP_PREFIXES)]


def frontmatter(text: str):
    if not text.startswith("---"):
        return None
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    try:
        return yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        return {"__error__": str(exc)}


def resolve_ref(rel: str, target: str) -> bool:
    target = target.split("@", 1)[0].strip()
    if not target.endswith(".md"):
        return True
    if (ROOT / target.lstrip("/")).exists():
        return True
    return ((ROOT / rel).parent / target).exists()


def blob_exists(pin: str) -> bool:
    """For a path.md@hash pin, verify the blob existed at that commit in git."""
    path, _, h = pin.partition("@")
    res = subprocess.run(
        ["git", "cat-file", "-e", f"{h}:{path.lstrip('/')}"],
        cwd=ROOT,
        capture_output=True,
    )
    return res.returncode == 0


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
    nm = nm.strip()
    if not nm or "/" in nm or nm.endswith(".md"):
        return None
    hits = sorted(
        str(p.relative_to(ROOT))
        for p in ROOT.rglob(f"{nm}.md")
        if ".git" not in p.parts and not str(p.relative_to(ROOT)).startswith(SKIP_PREFIXES)
    )
    return hits[0] if hits else None


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Cf")   # strip all Unicode format chars
    return s.translate(HYPHENS)


def _strip_code(s: str) -> str:
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


# --- secret pre-pass: a key/token must never be committed to ANY tracked doc ---
if GATE_ON:
    for _sf in secret_targets():
        _stext = _norm((ROOT / _sf).read_text(encoding="utf-8-sig", errors="replace"))
        for _snm, _spat in SECRET_PATTERNS.items():
            for _smm in _spat.finditer(_stext):
                errors.append((f"gate-secret:{_snm}", _sf, f"match {_redact(_smm.group(0))}"))

_target_list = targets()
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
            vals = fm[field] if isinstance(fm[field], list) else [fm[field]]
            for v in vals:
                if not v:
                    continue
                if not PATH_AT_HASH.match(str(v)):
                    warnings.append((f"pin:{field}", rel, f"{v!r} not path.md@hash"))
                elif not blob_exists(str(v)):
                    warnings.append((f"pin:{field}", rel, f"{v!r} not in git history"))
        if field in fm and spec.get("ref"):
            vals = fm[field] if isinstance(fm[field], list) else [fm[field]]
            for v in vals:
                if v and not resolve_ref(rel, str(v)):
                    warnings.append((f"ref:{field}", rel, f"missing target {v}"))

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
    if st == "superseded":
        for r in STATUS_RULES.get("superseded_requires", []):
            if r not in fm:
                errors.append(("status-rule", rel, f"superseded requires '{r}'"))
    if st == "obsolete":
        for r in STATUS_RULES.get("obsolete_forbids", []):
            if r in fm:
                warnings.append(("status-rule", rel, f"obsolete should not set '{r}'"))
    if st == "accepted":
        for r in STATUS_RULES.get("accepted_recommends", []):
            if r not in fm:
                warnings.append(("status-soft", rel, f"accepted should record '{r}'"))

    # --- km GATE (opt-in, advisory) — leak / bergab / freshness (secrets are a separate pass) ---
    if GATE_ON:
        served = fm.get("status") == SERVED_STATUS
        customer = fm.get("audience") == CUSTOMER_AUDIENCE
        if customer:
            scan = _norm(text).replace("*", "").replace("_", "").lower()
            for _term in FORBIDDEN_TERMS:
                needle = _norm(_term).replace("*", "").replace("_", "").lower()
                if needle and needle in scan:
                    errors.append(("gate-leak:term", rel, f"forbidden term {_redact(_term)}"))
            for _mm in EMAIL.finditer(_norm(text)):
                if _mm.group(0).rsplit("@", 1)[-1].lower() not in EMAIL_ALLOWLIST:
                    errors.append(("gate-leak:email", rel, f"external email {_redact(_mm.group(0))}"))
        if served:
            _refs = fm.get("related") or []
            _refs = _refs if isinstance(_refs, list) else [_refs]
            for _tgt in list(link_targets(text)) + [str(x) for x in _refs]:
                _tp = resolve_path(rel, str(_tgt)) or resolve_slug(str(_tgt))
                if not _tp or _tp == rel or _tp.startswith(SKIP_PREFIXES):
                    continue
                _st2 = doc_status(_tp)
                if _st2 in ("draft", "review"):
                    errors.append(("gate-bergab", rel, f"served doc links to unfinished ({_st2}) {_tp}"))
                elif _st2 in ("superseded", "obsolete"):
                    warnings.append(("gate-bergab-old", rel, f"served doc links to {_st2} {_tp}"))
            _rb = fm.get("review_by")
            if _rb:
                try:
                    if datetime.date.fromisoformat(str(_rb)[:10]) < TODAY:
                        warnings.append(("gate-stale", rel, f"review_by {_rb} is in the past"))
                except (ValueError, TypeError):
                    pass


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


report("ERRORS", errors)
report("WARNINGS", warnings)
print()
if GATE_ON and _args() and not (_target_list or secret_targets()):
    print("no validatable .md matched the given paths", file=sys.stderr)
    sys.exit(2)
sys.exit(1 if errors else 0)
