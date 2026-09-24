"""Bring a brain to the km you run: `km upgrade [--root DIR] [--force]`.

- Every km pin moves to this km's release (or --pin VERSION), by commit (see km.pins); a pin to a
  movable tag becomes a commit pin, and a commit that is not the release its comment names is
  re-pinned. A pin to a newer km is not moved back unless --force is given. The release commit is
  looked up before anything is written, and only when something needs it; a brain already on the
  release is still checked against it when the km repository can be reached.
- A brain from the copy-in days is converted:
  - its pre-commit config and its ci and staleness workflows are rewritten from the templates when
    their content is exactly one of km's earlier versions; one the brain changed is reported for a
    hand edit instead;
  - the km files it copied in (scripts/validate.py, km_promote.py, the team scripts,
    schema.base.yaml) are removed, each recognised by its km header. They were km-owned and
    overwritten by every upgrade, so edits to them were never kept. A script a remaining workflow
    still runs stays until that workflow is switched to the km command;
  - a legacy schema.yaml becomes schema.local.yaml, the overlay it already acts as;
  - a team brain gets the Dependabot config, and the obsolete `team_brain:` line goes.

A workflow the brain wrote itself only gets its pin moved. Prints what changed; review `git diff`
before committing.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import sys

from km import KM_REF
from km.init import pin_values, template
from km.paths import repo_root, write_text
from km.pins import hook_rev, movable_refs, read_pins, resolve, set_pins, version_key, workflow_files

COPIED = {                            # a file km copied in -> text only km's copy of it carries
    "scripts/validate.py": "Validate knowledge-base frontmatter against the km schema",
    "scripts/km_promote.py": "km promote — safe",
    "scripts/gen_index.py": "Regenerate the '## Documents' list",
    "scripts/demote_stale.py": "Demote stale served docs",
    "scripts/build_served.py": "Build the SERVED bundle",
    "scripts/team_common.py": "Shared helpers for the team-brain scripts",
    "schema.base.yaml": "CANONICAL frontmatter schema for /km",
}
# The km-owned workflows and hook brains were given before km was a package -> (template, the
# fingerprints of every version km wrote, including brains set up before this repository's history
# starts). A file is replaced only when it still is one of them; tests/fixtures/old-brain holds the last.
OLD_COPIES = {
    ".github/workflows/ci.yml": ("team/ci.yml", {"207217f3934befc7", "cb081b8a2bb942d5"}),
    ".github/workflows/staleness.yml": ("team/staleness.yml", {"e9768164f8a03461", "199bf98454e2f922", "fb3fcd7353e99cde"}),
    ".pre-commit-config.yaml": ("pre-commit-config.template.yaml", {"8ef7f1ea977e2308", "d6819c5f6e97baa1"}),
}
MARKER = re.compile(r"(?m)^(# Marks a team brain:.*\n)?team_brain:.*\n")


def fingerprint(text: str) -> str:
    """sha256 prefix of the text without comment and blank lines (km's header comments changed
    between versions, the content did not)."""
    content = "\n".join(ln.rstrip() for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#"))
    return hashlib.sha256(content.encode()).hexdigest()[:16]


def main() -> int:
    ap = argparse.ArgumentParser(prog="km upgrade", description="Move a brain to this km version.")
    ap.add_argument("--force", action="store_true", help="also move a pin to a newer km back to this one")
    ap.add_argument("--pin", metavar="VERSION", default=KM_REF, help="the km release to pin (default: this km, %(default)s)")
    a = ap.parse_args()
    root = repo_root()
    if not any((root / f).is_file() for f in ("CONVENTIONS.md", "schema.local.yaml", "schema.yaml")):
        sys.exit(f"km upgrade: {root} has no CONVENTIONS.md or schema file; not a km brain")
    target = a.pin
    pins = read_pins(root)
    newer = sorted(f"{f} pins {p.version}" for f, ps in pins.items() for p in ps
                   if (k := version_key(p.version)) and k > (version_key(target) or ()))
    if newer and not a.force:
        sys.exit(f"km upgrade: the target is km {target}, but {'; '.join(newer)}. Update km, or pass --force.")
    rewrites = {rel: tpl for rel, (tpl, known) in OLD_COPIES.items()
                if (root / rel).is_file() and fingerprint((root / rel).read_text(encoding="utf-8")) in known}
    current = all(p.is_commit and p.version == target for ps in pins.values() for p in ps)
    if rewrites or not current:               # decided before any write, so a failed lookup changes nothing
        values = pin_values(target)
    else:                                      # already on the release: still check it is the release's commit
        values = {"<KM_SHA>": sha, "<KM_VERSION>": target} if pins and (sha := resolve(target)) else {}
    stray = sorted({p.ref for ps in pins.values() for p in ps if values and p.ref != values["<KM_SHA>"]})

    done: list[str] = [f"a pin names km {target} but points at {r[:12]}, not its release commit; re-pinned"
                       for r in stray if current]
    local = root / "schema.local.yaml"
    team = local.is_file() and bool(MARKER.search(local.read_text(encoding="utf-8")))
    for rel, (tpl, known) in OLD_COPIES.items():
        p = root / rel
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        if rel in rewrites:
            write_text(p, template(tpl, values))
            done.append(f"rewrote {rel} (it was km's own, unchanged) to install km")
            team |= rel.startswith(".github/")
        elif rel == ".pre-commit-config.yaml" and "scripts/validate.py" in text:
            done.append(f"{rel} differs from km's old hook: replace its km hook by hand with "
                        f"`repo: https://github.com/pasrom/km`, `rev: {hook_rev(values.get('<KM_SHA>', '<commit of ' + target + '>'), target)}`, "
                        f"`id: km-validate`")

    still_run = {p.relative_to(root): [r for r in COPIED if r.startswith("scripts/") and r in p.read_text(encoding="utf-8")]
                 for p in workflow_files(root)}
    for rel, mark in COPIED.items():
        p = root / rel
        if not p.is_file():
            continue
        callers = [str(w) for w, runs in still_run.items() if rel in runs]
        if mark not in p.read_text(encoding="utf-8", errors="replace"):
            done.append(f"left {rel}: not km's copy")
        elif callers:
            done.append(f"kept {rel}: {', '.join(callers)} still runs it; switch that to the km command, then upgrade again")
        else:
            p.unlink()
            done.append(f"removed {rel}")
    scripts = root / "scripts"
    if scripts.is_dir() and all(p.name == "__pycache__" for p in scripts.iterdir()):
        shutil.rmtree(scripts)            # nothing of the brain's own was in there

    legacy = root / "schema.yaml"
    if legacy.is_file() and not local.exists():
        legacy.rename(local)
        done.append("renamed schema.yaml to schema.local.yaml: it overlays km's base schema; trim what the base defines")
    if local.is_file():
        text = local.read_text(encoding="utf-8")
        if (new := MARKER.sub("", text)) != text:
            write_text(local, new)
            done.append("dropped team_brain from schema.local.yaml (no longer used)")
    dependabot = root / ".github/dependabot.yml"
    if team and not dependabot.exists():
        dependabot.parent.mkdir(parents=True, exist_ok=True)
        write_text(dependabot, template("team/dependabot.yml", {}))
        done.append("added .github/dependabot.yml")

    if values and (not current or stray):
        sha = values["<KM_SHA>"]
        done += [f"pinned {f} to km {target} ({sha[:12]})" for f in set_pins(root, sha, target)]
    done += [f"{f} runs {what} from a movable ref: pin it by commit" for f, what in movable_refs(root)]
    for line in done or [f"already on km {target}"]:
        print(f"km upgrade: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
