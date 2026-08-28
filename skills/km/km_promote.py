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

Usage: python3 scripts/km_promote.py <slug> <src> [--folder DIR] [--owner X] [--title T] [--replace]
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


def find_hits(slug: str, prefixes: set[str]):
    out = []
    for p in ROOT.rglob(f"{slug}.md"):
        if ".git" in p.parts:
            continue
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


def status_of(p: Path):
    fm, _ = split_fm(p.read_text(encoding="utf-8"))
    return fm.get("status")


def dump(fm: dict, body: str) -> str:
    return "---\n" + yaml.safe_dump(fm, sort_keys=False, allow_unicode=True) + "---\n\n" + body.strip() + "\n"


def run_gate(target: Path):
    for cmd in (["uv", "run", str(VP), str(target)], [sys.executable, str(VP), str(target)]):
        try:
            return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        except FileNotFoundError:
            continue
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("source")
    ap.add_argument("--folder", default="topics")
    ap.add_argument("--owner", default="RPA")
    ap.add_argument("--title", default=None)
    ap.add_argument("--replace", action="store_true")
    a = ap.parse_args()

    if not a.slug or a.slug != Path(a.slug).name:
        print(f"promote: REFUSED — slug must be a single path segment (no '/' or '..'), got {a.slug!r}")
        return 2

    body = Path(a.source).read_text(encoding="utf-8").strip()
    today = datetime.date.today().isoformat()
    review_by = (datetime.date.today() + datetime.timedelta(days=180)).isoformat()
    prefixes = submodule_prefixes()

    hits = find_hits(a.slug, prefixes)
    if len(hits) > 1:
        print(f"promote: REFUSED — slug '{a.slug}' collides across {len(hits)} files:")
        for h in hits:
            print(f"  - {h.relative_to(ROOT)}")
        return 2

    existing = hits[0] if hits else None
    if existing:
        st = status_of(existing)
        if st != "accepted":
            print(f"promote: REFUSED — target {existing.relative_to(ROOT)} is not served (status={st!r}).")
            return 2
        if not a.replace:
            print(f"promote: REFUSED — {existing.relative_to(ROOT)} exists. Re-run with --replace")
            print("         (that invalidates its approval and sets status: review).")
            return 2
        fm, _old = split_fm(existing.read_text(encoding="utf-8"))
        fm["status"] = "review"
        fm.pop("approved_by", None)
        fm.pop("approved_at", None)
        fm["timestamp"] = today
        target = existing
        action = "replaced existing served doc (approval invalidated -> status: review)"
    else:
        target = ROOT / a.folder / f"{a.slug}.md"
        title = a.title or a.slug.replace("-", " ").title()
        fm = {
            "type": "concept",
            "title": title,
            "timestamp": today,
            "author": a.owner,
            "status": "review",
            "tags": [a.slug],
            "owner": a.owner,
            "audience": "internal",
            "review_by": review_by,
        }
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
    print(f"pointer: replace the source note in your scratch with ->  see [{rel_target}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
