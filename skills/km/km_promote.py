#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""km promote — safe: gate before placing, never destroy content silently.

Vendored next to validate.py at `scripts/km_promote.py`. Moves a note into the brain as a
`status: review` doc, dedups by topic slug, and prints a pointer (paste back into personal
scratch instead of keeping a copy). Safety rules:
  * The slug must be a single path segment; the target is containment-checked (inside the repo,
    not inside a peer brain/submodule) BEFORE anything is written.
  * The candidate is gated in a temp file inside the repo, then atomically renamed onto the
    target on PASS; a failing promote writes nothing and never clobbers.
  * An existing served doc is NOT overwritten without --replace, and --replace INVALIDATES the
    approval (status -> review, approved_* dropped, timestamp bumped).
  * Slug collisions are a HARD STOP; a non-served target is refused; a peer-brain target is
    refused (correct a foreign brain via a PR against its own repo, never in the parent).
  * A verbatim-block is never --replace'd (change it only via supersede).
  * The source's own frontmatter is carried forward (type/title/author/tags/...); status, approval
    and supersede fields are dropped and re-stamped, so a source WITH frontmatter never yields a
    double header. A new doc needs --folder and a type+author (from --flags or the source).
  * author resolves --author > source frontmatter > author_default (schema.local.yaml).
  * --stub-source rewrites an IN-REPO source note into a superseded stub pointing at the promoted
    doc; the stub is built from the source's own frontmatter and gated the same way, skipped (source
    untouched) if it would be invalid. A source in another repo or a non-article (README/index/...)
    is left untouched. Runs only after the promote passes the gate.

Usage: python3 scripts/km_promote.py <slug> <src> --folder DIR [--type T] [--title T] [--author A] [--owner O] [--replace] [--stub-source]
"""
import argparse
import datetime
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
VP = ROOT / "scripts" / "validate.py"


def submodule_prefixes() -> set[str]:
    prefixes = {"brains"}
    gm = ROOT / ".gitmodules"
    if gm.is_file():
        for ln in gm.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if ln.startswith("path"):
                prefixes.add(ln.split("=", 1)[1].strip().strip("/"))
    return prefixes


def in_submodule(rel_str: str, prefixes: set[str]) -> bool:
    return any(rel_str == p or rel_str.startswith(p + "/") for p in prefixes)


def find_hits(slug: str, prefixes: set[str], exclude: Path | None = None):
    out = []
    for p in ROOT.rglob(f"{slug}.md"):
        if ".git" in p.parts:
            continue
        if exclude is not None and p.resolve() == exclude:
            continue   # the source note is never the doc it dedups against
        rel = str(p.relative_to(ROOT))
        if in_submodule(rel, prefixes):
            continue
        out.append(p)
    return sorted(out)


def split_fm(txt: str):
    if txt.startswith("---"):
        end = txt.find("\n---", 3)
        if end != -1:
            fm = yaml.safe_load(txt[3:end]) or {}
            return (fm if isinstance(fm, dict) else {}), txt[end + 4:].lstrip("\n")
    return {}, txt


def dump(fm: dict, body: str) -> str:
    return "---\n" + yaml.safe_dump(fm, sort_keys=False, allow_unicode=True) + "---\n\n" + body.strip() + "\n"


def type_enum() -> set[str] | None:
    """Allowed `type` values from the merged schema, or None if unreadable (the gate still backstops)."""
    vals: set[str] = set()
    for name in ("schema.base.yaml", "schema.local.yaml"):
        p = ROOT / name
        if not p.is_file():
            continue
        try:
            data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue
        enum = ((data.get("fields") or {}).get("type") or {}).get("enum")
        if isinstance(enum, list):
            vals.update(str(v) for v in enum)
    return vals or None


def cfg(key: str):
    """A top-level key from the merged schema (schema.local overrides schema.base), or None."""
    for name in ("schema.local.yaml", "schema.base.yaml"):
        p = ROOT / name
        if not p.is_file():
            continue
        try:
            data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue
        if isinstance(data, dict) and key in data:
            return data[key]
    return None


def run_gate(target: Path):
    for cmd in (["uv", "run", str(VP), str(target)], [sys.executable, str(VP), str(target)]):
        try:
            return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        except FileNotFoundError:
            continue
    return None


_NOT_STUBBABLE = {"README.md", "CLAUDE.md", "CONVENTIONS.md", "SKILL.md", "index.md", "log.md", "_index.md"}


def _stub_source(src: Path, target_rel: str, prefixes: set[str], src_fm: dict, ident: dict, today: str) -> None:
    """After a successful promote, rewrite an IN-REPO source note into a superseded redirect stub.
    Built from the source's OWN frontmatter (so type_rules-required fields survive) with `ident` as
    the fallback for a source that had none, then GATED the same way the target is (tmp + validate +
    atomic replace) and skipped with a printed reason if it would be invalid. A source outside the
    repo, inside a submodule, exempt/reserved/non-md, or already superseded/obsolete is left
    untouched. The promote has already succeeded, so any stub problem is a warning, never an exit."""
    if not src.name.endswith(".md") or src.name in _NOT_STUBBABLE:
        print(f"stub: source {src.name} is exempt/reserved/non-md; left untouched.")
        return
    try:
        src_rel = str(src.resolve().relative_to(ROOT))
    except ValueError:
        print(f"stub: source is outside this repo ({src}); stub it in its own repo.")
        return
    if in_submodule(src_rel, prefixes):
        print(f"stub: source {src_rel} is inside a peer brain/submodule; not touched.")
        return
    if src_rel == target_rel:
        return
    if src_fm.get("status") in ("superseded", "obsolete"):
        print(f"stub: source {src_rel} is already {src_fm['status']}; not re-stubbed.")
        return
    stub = {k: v for k, v in src_fm.items()
            if k not in ("status", "approved_by", "approved_at", "supersedes", "superseded_by", "audience", "review_by")}
    stub.setdefault("type", ident.get("type"))
    stub.setdefault("title", ident.get("title"))
    stub.setdefault("author", ident.get("author"))
    stub.setdefault("tags", ident.get("tags") or [src.stem])
    stub["timestamp"] = today
    stub["status"] = "superseded"
    stub["superseded_by"] = target_rel
    tmp = src.parent / (src.stem + ".stub-tmp.md")
    try:
        tmp.write_text(dump(stub, f"Moved to the served brain. See [{target_rel}]({target_rel})."), encoding="utf-8")
        r = run_gate(tmp)
        if not (r and r.returncode == 0):
            tmp.unlink(missing_ok=True)
            print("stub: SKIPPED — the stub would fail the gate; promote OK, source left untouched:")
            if r:
                print(r.stdout)
            return
        tmp.replace(src)   # atomic; the source is never left half-written
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        print(f"stub: could not rewrite source ({exc.__class__.__name__}); promote OK, source left untouched.")
        return
    print(f"stub: {src_rel} -> superseded, superseded_by: {target_rel}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Promote a scratch note into the brain as a status: review doc.")
    ap.add_argument("slug")
    ap.add_argument("source")
    ap.add_argument("--folder", default=None, help="target folder (required when creating a new doc)")
    ap.add_argument("--type", dest="doctype", default=None, help="doc type (else taken from the source frontmatter)")
    ap.add_argument("--title", default=None, help="title override (else source frontmatter, else the slug)")
    ap.add_argument("--author", default=None, help="author (else taken from the source frontmatter)")
    ap.add_argument("--owner", default=None, help="owner for staleness (optional)")
    ap.add_argument("--replace", action="store_true")
    ap.add_argument("--stub-source", action="store_true", help="rewrite an in-repo source note into a superseded stub pointing at the promoted doc")
    a = ap.parse_args()

    if not a.slug or a.slug != Path(a.slug).name:
        print(f"promote: REFUSED — slug must be a single path segment (no '/' or '..'), got {a.slug!r}")
        return 2

    src_fm, body = split_fm(Path(a.source).read_text(encoding="utf-8"))   # strip source frontmatter -> no doubling
    body = body.strip()
    today = datetime.date.today().isoformat()
    review_by = (datetime.date.today() + datetime.timedelta(days=180)).isoformat()
    prefixes = submodule_prefixes()
    src_resolved = Path(a.source).resolve()

    hits = find_hits(a.slug, prefixes, exclude=src_resolved)   # the source is never its own "existing doc"
    if len(hits) > 1:
        print(f"promote: REFUSED — slug '{a.slug}' collides across {len(hits)} files:")
        for h in hits:
            print(f"  - {h.relative_to(ROOT)}")
        return 2

    existing = hits[0] if hits else None
    if existing:
        ex_fm, _old = split_fm(existing.read_text(encoding="utf-8"))
        if ex_fm.get("type") == "verbatim-block":
            print(f"promote: REFUSED — {existing.relative_to(ROOT)} is a verbatim-block; change it only via supersede, not --replace.")
            return 2
        if ex_fm.get("status") != "accepted":
            print(f"promote: REFUSED — target {existing.relative_to(ROOT)} is not served (status={ex_fm.get('status')!r}).")
            return 2
        if not a.replace:
            print(f"promote: REFUSED — {existing.relative_to(ROOT)} exists. Re-run with --replace")
            print("         (that invalidates its approval and sets status: review).")
            return 2
        fm = ex_fm
        fm["status"] = "review"
        fm.pop("approved_by", None)
        fm.pop("approved_at", None)
        fm["timestamp"] = today
        target = existing
        ident = {"type": src_fm.get("type"), "title": src_fm.get("title"),
                 "author": src_fm.get("author"), "tags": src_fm.get("tags")}
        action = "replaced existing served doc (approval invalidated -> status: review)"
    else:
        if not a.folder:
            print("promote: REFUSED — a new doc needs --folder DIR (there is no default).")
            return 2
        doctype = a.doctype or src_fm.get("type")
        if not doctype:
            print("promote: REFUSED — no type; pass --type or give the source frontmatter a type.")
            return 2
        allowed = type_enum()
        if allowed and doctype not in allowed:
            print(f"promote: REFUSED — type {doctype!r} not in the schema enum ({', '.join(sorted(allowed))}).")
            return 2
        _ad = cfg("author_default")
        author = a.author or src_fm.get("author") or (_ad if isinstance(_ad, str) and _ad.strip() else None)
        if not author:
            print("promote: REFUSED — no author; pass --author, give the source an author, or set a string author_default in schema.local.yaml.")
            return 2
        title = a.title or src_fm.get("title") or a.slug.replace("-", " ").title()
        target = ROOT / a.folder / f"{a.slug}.md"
        # carry the source's own frontmatter, dropping provenance that must not survive a promote
        fm = {k: v for k, v in src_fm.items()
              if k not in ("status", "approved_by", "approved_at", "superseded_by", "supersedes")}
        fm["type"] = doctype
        fm["title"] = title
        fm["timestamp"] = today
        fm["author"] = author
        fm["status"] = "review"
        fm.setdefault("tags", [a.slug])
        if a.owner:
            fm["owner"] = a.owner
        fm.setdefault("audience", "internal")
        fm.setdefault("review_by", review_by)
        ident = {"type": doctype, "title": title, "author": author, "tags": fm.get("tags")}
        action = "created new doc (status: review — submitted, not yet approved)"

    # containment: the target must live inside the repo and NOT inside a peer brain/submodule,
    # checked BEFORE any write (so a crafted slug/--folder can never escape the repo).
    try:
        rel_target = str(target.resolve().relative_to(ROOT))
    except ValueError:
        print(f"promote: REFUSED — target escapes the repository: {target}")
        return 2
    if in_submodule(rel_target, prefixes):
        print(f"promote: REFUSED — target {rel_target} is inside a peer brain/submodule.")
        print("         Correct a foreign brain via a PR against its own repo, never in the parent.")
        return 2
    if target.resolve() == src_resolved:
        print("promote: REFUSED — source and target are the same file.")
        return 2

    content = dump(fm, body)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.parent / (target.stem + ".promote-tmp.md")
    tmp.write_text(content, encoding="utf-8")
    r = run_gate(tmp)
    if not (r and r.returncode == 0):
        tmp.unlink(missing_ok=True)
        print("promote: REFUSED — candidate fails the gate, nothing written:")
        if r:
            print(r.stdout)
        return 1
    tmp.replace(target)  # atomic; never leaves a truncated target on interruption

    print(f"promote: {action}")
    print(f"         -> {rel_target}  (gate PASS)")
    if a.stub_source:
        _stub_source(Path(a.source), rel_target, prefixes, src_fm, ident, today)
    else:
        print(f"pointer: replace the source note in your scratch with ->  see [{rel_target}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
