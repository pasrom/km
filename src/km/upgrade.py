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
- A team brain gets the main-guard workflow, the approve-fork-ci workflow (only where ci.yml is km's,
  but for its pins and branch name, since it approves fork runs of that workflow), the bump-mounted-pins
  workflow and its script, the review-request-guide workflow, and the pre-commit hooks that refuse a commit on main and a push to main,
  whichever it lacks, km's km-gen-index hook in its km entry once the target release has it, and its
  km ci workflow gets the `workflow_dispatch` trigger, so a workflow that opens a pull request with
  GITHUB_TOKEN can run the check on it. The bump-mounted-pins workflow and script, approve-fork-ci,
  review-request-guide and main-guard are copies of km code: one that is still a version km shipped (its action pins aside) is replaced
  by this km's, one the brain changed is left with a note.
- Each accepted doc approved before km recorded what an approval covers (`approved_by` set, no
  `approved_digest`) gets the digest of its current content, once: when the brain moves from a km
  that did not check it to one that does. This takes the current text as the approved one, so
  review `git diff` before committing. From then on `km validate` reports a change to its content as
  a stale approval (see km.common), and a later upgrade records nothing. Where the pins moved past
  1.10.1 without km upgrade (Dependabot, `pre-commit autoupdate`), no upgrade crosses, and none
  records a digest: an approval typed by hand since looks the same, and the commit history and pin
  comments that could tell them apart are written by whoever pushes. An upgrade to a km whose ci runs
  the sign-off check lists those docs instead: each needs `km demote` and `km approve` once a pull
  request changes its content.
- The generated '## Documents' list of each _index.md is regenerated (km.gen_index), once: when the
  brain moves from a km at or below 1.11.0, which wrote a title as YAML reads it (`1.10` as 1.1,
  `false` as False), to a later one, which writes it as written, so the brain's
  `km gen-index --check` does not fail on the lists the old km wrote; a list stale for another reason
  is brought up to date too, and a folder with docs but no _index.md gets a note. A brain with no such
  list is left alone, its schema not read; `--force` back to an older km regenerates nothing. Like the
  digests it runs before the pins move, so a schema km cannot read stops the upgrade there and the run
  after the fix still does it.
- A team brain's km staleness workflow (one that pins km) whose checkout step sets no fetch-depth
  (km 1.3.0 and earlier wrote it so, and some brains dropped it) gets `fetch-depth: 0`: its run
  validates after demoting, and source pins need the full history. A checkout step this edit cannot
  handle gets a note instead; a staleness workflow of the brain's own is left as it is.
- A brain without a .gitattributes gets km's, so text files are LF on every platform; one whose
  own file sets no line ending gets a note.

A workflow the brain wrote itself only gets its pin moved. Prints what changed; review `git diff`
before committing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

import yaml

from km import KM_REF
from km.init import (AFC_TOO_OLD, GEN_INDEX, TEAM, ensure_lf, gen_index_hook, pin_values, safe_path, template,
                     with_gen_index, with_team_hooks)
from km.paths import git, repo_root, write_text
from km.pins import (SCHEMA_LINK, hook_rev, movable_refs, pin_target, read_pins, resolve, set_pins, set_schema_link,
                     version_key, workflow_files)

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
# The km files a team brain carries as copies (the bump-mounted-pins job holding the app token must
# not install km; the fixes of approve-fork-ci, review-request-guide and main-guard must reach every brain) ->
# shipped_hash of every version km shipped, the current one included (a test checks it): a copy that
# is still one of them is replaced by the current template, an edited one is left with a note.
SHIPPED = {
    "team/bump-mounted-pins.yml": {"c72b295b1ba76e65", "bb30b4db64fb033e"},
    "team/bump-mounted-pins.py": {"52f798d7ca2f7d32", "9dc066d86b74a44f"},
    "team/approve-fork-ci.yml": {"accf1785f4710b4e", "70ad9729fd426ebd", "e10d6138ae696efb", "5f87b231aff97388"},
    "team/review-request-guide.yml": {"e2a600682b732ddc", "1a0d3ea14f80d3e7"},
    "team/main-guard.yml": {"c2896be807a78e55", "80921af35464658e"},
}
# approve-fork-ci versions that approved data endings only: the later ones approve any file but control
# files, safe only beside km's ci and a km from 1.11.0 on, so upgrade does not widen one of these otherwise
ALLOWLIST_AFC = {"accf1785f4710b4e", "70ad9729fd426ebd"}
# ci_hash of every km team ci version: upgrade adds approve-fork-ci only where ci.yml is one of these, since
# a fork's approved run is safe only while ci runs nothing but km. A change to team/ci.yml adds its hash here.
KM_CI = {"4ab8b6e4f2ef1e22", "e97892ef9bb0d77f"}
DIGEST_AFTER = (1, 10, 1)   # the last km release that does not record or check approved_digest
INDEX_AFTER = (1, 11, 0)    # the last km release whose gen-index writes a title as YAML reads it (1.10 as 1.1)


def record_digests() -> tuple[list[str], list[str]]:
    """Give each accepted doc that has an approver but no approved_digest the digest of its current
    content: (the docs given one, the docs left without one, with why). Left out is a doc whose
    content nobody approved yet: with uncommitted changes, or, where history has it, one that differs
    from the doc as committed with its last `approved_at` change (a shallow clone without that commit
    takes the text as it is). Imported here, not at the top: km.common reads the schema overlay,
    which this upgrade may have just renamed."""
    from km.common import ROOT, SERVED_STATUS, approved_digest, doc_at, git_md, is_article, set_digest, tracked_md
    from km.edit import load_doc
    if git_md() is None:
        return [], []                 # not a git work tree: no tracked docs to look at (tracked_md would exit)
    dirty = set(git("diff", "HEAD", "--name-only", "--relative", "-z", cwd=ROOT).stdout.split("\0"))

    def approved_then(rel: str) -> str | None:
        """The digest of the doc as committed when its approved_at line last changed, or None."""
        sha = git("log", "-1", "--format=%H", "-G", "^approved_at:", "--", rel, cwd=ROOT).stdout.strip()
        then = doc_at(sha, rel) if sha else None
        return approved_digest(*then) if then and then[0] is not None else None

    done, left = [], []
    for rel in filter(is_article, tracked_md()):
        if isinstance(d := load_doc(rel, ROOT / rel), str):
            continue                  # no frontmatter or not UTF-8: no approval to record, validate reports it
        if d.fm.get("status") == SERVED_STATUS and d.fm.get("approved_by") and "approved_digest" not in d.fm:
            if rel in dirty:
                left.append(f"{rel} (uncommitted changes)")
            elif (then := approved_then(rel)) and then != approved_digest(d.fm, d.body):
                left.append(f"{rel} (changed since its approval)")
            else:
                write_text(d.path, set_digest(d.raw, d.fm, d.body) + d.body)
                done.append(rel)
    return done, left


def undigested(root: Path) -> list[str]:
    """The accepted docs with an approver but no approved_digest, the ones record_digests looks at.
    Asked of git first (an approved_by line), so a brain without an approved doc is left alone, its
    schema not read; km.common is imported here for the reason record_digests gives."""
    if not (candidates := set(git("grep", "-lz", "-e", "^approved_by:", "--", "*.md", cwd=root).stdout.split("\0")) - {""}):
        return []
    from km.common import ROOT, SERVED_STATUS, is_article
    from km.edit import load_doc
    return sorted(rel for rel in filter(is_article, candidates) if (ROOT / rel).is_file()
                  and not isinstance(d := load_doc(rel, ROOT / rel), str) and d.fm.get("status") == SERVED_STATUS
                  and d.fm.get("approved_by") and "approved_digest" not in d.fm)


def regenerate_indexes(root: Path) -> tuple[list[str], list[str]]:
    """Rewrite the generated '## Documents' lists, which this km writes differently (a title as
    written, not as YAML reads it): (the _index.md files rewritten, the folders gen-index finds without
    one). A brain with no tracked _index.md holding such a list, or no git work tree, is left alone
    without reading its schema. km.gen_index is imported here for the reason record_digests gives."""
    listed = git("ls-files", "-z", "--", "_index.md", "*/_index.md", cwd=root)
    if listed.returncode or not any(re.search(r"(?m)^## Documents[ \t]*$", (root / p).read_text(encoding="utf-8", errors="replace"))
                                    for p in listed.stdout.split("\0") if p and (root / p).is_file()):
        return [], []
    from km.gen_index import regenerate
    return regenerate()


USES = re.compile(r"(?m)^([ \t]*(?:-[ \t]+)?uses:[ \t]*([^@\s]+)@)\S+.*$")   # 1: up to the @, 2: the action


def shipped_hash(text: str) -> str:
    """sha256 prefix of a shipped copy with its action refs masked: the brain's Dependabot moves
    those, and a moved pin is not an edit of the brain's own."""
    return hashlib.sha256(USES.sub(r"\1", text).encode()).hexdigest()[:16]


def _pinned_version(pin: str) -> tuple[int, ...] | None:
    """(7, 0, 1) for `<sha> # v7.0.1`, the version comment Dependabot keeps; None without one."""
    m = re.search(r"#\s*v?(\d+(?:\.\d+)*)\b", pin)
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def carry_pins(old: str, new: str) -> str:
    """`new` with the pin `old` gives an action where its version comment is newer than km's: the
    brain's Dependabot moved it past the template. Otherwise km's pin, which may be newer and which
    the new template may need."""
    pins = {m.group(2): m.group(0)[len(m.group(1)):] for m in USES.finditer(old)}

    def pin(m: re.Match) -> str:
        ours, theirs = m.group(0)[len(m.group(1)):], pins.get(m.group(2))
        newer = theirs and (a := _pinned_version(theirs)) and (b := _pinned_version(ours)) and a > b
        return m.group(1) + (theirs if newer else ours)
    return USES.sub(pin, new)


MARKER = re.compile(r"(?m)^(# Marks a team brain:.*\n)?team_brain:.*\n")


def fingerprint(text: str) -> str:
    """sha256 prefix of the text without comment and blank lines (km's header comments changed
    between versions, the content did not)."""
    content = "\n".join(ln.rstrip() for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#"))
    return hashlib.sha256(content.encode()).hexdigest()[:16]


def ci_hash(text: str) -> str | None:
    """sha256 prefix of a ci workflow as YAML reads it, so a comment changes nothing and nothing YAML
    runs can hide as one, with what may differ between brains running the same steps masked: the
    action refs (Dependabot moves them), the push branches (the default branch's name) and the
    workflow_dispatch trigger (upgrade adds it after this check). None when it is no workflow."""
    d = _parse(text)
    if not isinstance(d, dict):
        return None
    on = d.pop(True, d.pop("on", None))              # YAML 1.1 reads a bare `on` as true
    if isinstance(on, dict):
        on = {k: v for k, v in on.items() if k != "workflow_dispatch"}
        if isinstance(on.get("push"), dict) and "branches" in on["push"]:
            on["push"] = {**on["push"], "branches": "<default>"}
    d["on"] = on
    jobs = d.get("jobs")
    for job in jobs.values() if isinstance(jobs, dict) else ():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        for step in [job, *(steps if isinstance(steps, list) else ())]:   # a job may call a reusable workflow itself
            if isinstance(step, dict) and isinstance(step.get("uses"), str):
                step["uses"] = step["uses"].split("@")[0]
    try:
        return hashlib.sha256(json.dumps(d, sort_keys=True, default=str).encode()).hexdigest()[:16]
    except (TypeError, ValueError, RecursionError):    # mixed key types, an alias cycle: not km's
        return None


def _parse(text: str):
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError:
        return None


def with_dispatch(text: str) -> str | None:
    """The workflow with `workflow_dispatch:` added at the end of its `on:` block (unchanged when it
    has the trigger), or None when the edit cannot be made safely (a one-line `on:`, or a layout this
    edit does not handle): the result must parse to the same workflow with exactly that trigger added."""
    before = _parse(text)
    on = before.get(True, before.get("on")) if isinstance(before, dict) else None   # YAML 1.1 reads a bare `on` as true
    if isinstance(on, (dict, list, str)) and "workflow_dispatch" in on:
        return text
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    top = next((i for i, ln in enumerate(lines) if re.match(r"(on|['\"]on['\"]):\s*(#.*)?$", ln)), None)
    if top is None or not isinstance(on, dict):
        return None
    end, pad = top + 1, None             # the `on:` block ends before the next top-level line
    for i in range(top + 1, len(lines)):
        ln = lines[i]
        if ln.strip() and not ln[0].isspace():
            break
        if ln.strip() and not ln.lstrip().startswith("#"):
            pad = pad or ln[:len(ln) - len(ln.lstrip())]
            end = i + 1
    out = "".join(lines[:end]) + f"{pad}workflow_dispatch:\n" + "".join(lines[end:])
    key = True if True in before else "on"
    return out if pad and _parse(out) == {**before, key: {**on, "workflow_dispatch": None}} else None


# The base branch of a pull request, or the default branch on a dispatched run (a pull request a
# workflow opened); empty on a push, which needs no sign-off check. As in templates/team/ci.yml.
SIGNOFF_SINCE = (1, 12, 0)   # the first km release with `km validate --signoff-since`
SIGNOFF_BASE = "${{ github.base_ref || (github.event_name == 'workflow_dispatch' && github.event.repository.default_branch) || '' }}"


def _steps(d) -> list[dict]:
    """The steps of every job of a parsed workflow, whatever shape it has."""
    jobs = d.get("jobs") if isinstance(d, dict) else None
    return [s for job in (jobs.values() if isinstance(jobs, dict) else ()) if isinstance(job, dict)
            for s in (job.get("steps") if isinstance(job.get("steps"), list) else ()) if isinstance(s, dict)]


def with_signoff(text: str) -> str | None:
    """The workflow with its one `run: km validate` step also checking sign-offs on a pull request
    (unchanged when it does), or None when there is no single such step with no `env:` of its own,
    or the edit would change more than that step."""
    if re.search(r"(?m)^[^#\n]*--signoff-since", text):   # a comment that names it does not count
        return text
    lines = text.splitlines(keepends=True)
    hits = [(i, m) for i, ln in enumerate(lines) if (m := re.fullmatch(r"(\s*)(- )?run: km validate\s*", ln))]
    if len(hits) != 1:
        return None
    i, m = hits[0]
    pad = m.group(1) + ("  " if m.group(2) else "")
    run = 'run: km validate ${BASE:+--signoff-since "origin/$BASE"}\n'
    step = [f"{m.group(1)}{m.group(2) or ''}env:\n", f"{pad}  BASE: {SIGNOFF_BASE}\n", f"{pad}{run}"]
    out = "".join(lines[:i] + step + lines[i + 1:])
    old, new = _steps(_parse(text)), _steps(_parse(out))
    want = [{**s, "env": {"BASE": SIGNOFF_BASE}, "run": run.removeprefix("run: ").strip()} if s.get("run") == "km validate" and "env" not in s else s
            for s in old]
    return out if len(old) == len(new) and new == want and want != old else None


def with_full_history(text: str) -> str | None:
    """The staleness workflow with `fetch-depth: 0` given to its one actions/checkout step (unchanged when
    every checkout step sets a fetch-depth, or there is none), or None when the edit cannot be made safely
    (several checkout steps, a `with:` of its own, a layout this edit does not handle): the result must
    parse to the same workflow with exactly that input added."""
    before = _parse(text)
    steps = [s for s in _steps(before) if str(s.get("uses", "")).startswith("actions/checkout@")]
    if all(isinstance(s.get("with"), dict) and "fetch-depth" in s["with"] for s in steps):
        return text                             # set, or no checkout to give it to
    lines = text.splitlines(keepends=True)
    hits = [(i, m) for i, ln in enumerate(lines) if (m := re.match(r"(\s*)(- )?uses:\s*actions/checkout@", ln))]
    if len(hits) != 1 or len(steps) != 1 or "with" in steps[0]:
        return None
    i, m = hits[0]
    pad = m.group(1) + ("  " if m.group(2) else "")
    depth = next(ln.strip() for ln in template("team/staleness.yml", {}).splitlines()   # with the template's comment
                 if ln.strip().startswith("fetch-depth:"))
    out = "".join(lines[:i + 1] + [f"{pad}with:\n", f"{pad}  {depth}\n"] + lines[i + 1:])
    steps[0]["with"] = {"fetch-depth": 0}      # `before` now reads as the workflow should
    return out if _parse(out) == before else None


def main() -> int:
    ap = argparse.ArgumentParser(prog="km upgrade", description="Move a brain to this km version.")
    ap.add_argument("--force", action="store_true", help="also move a pin to a newer km back to this one")
    ap.add_argument("--pin", metavar="VERSION", default=KM_REF, help="the km release, or a km commit sha, to pin (default: this km, %(default)s)")
    a = ap.parse_args()
    root = repo_root()
    if not any((root / f).is_file() for f in ("CONVENTIONS.md", "schema.local.yaml", "schema.yaml")):
        sys.exit(f"km upgrade: {root} has no CONVENTIONS.md or schema file; not a km brain")
    target, commit = pin_target(a.pin)       # a commit: an unreleased km, its version read from it
    pins = read_pins(root)
    newer = sorted(f"{f} pins {p.version}" for f, ps in pins.items() for p in ps
                   if (k := version_key(p.version)) and k > (version_key(target) or ()))
    if newer and not a.force:
        sys.exit(f"km upgrade: the target is km {target}, but {'; '.join(newer)}. Update km, or pass --force.")
    rewrites = {rel: tpl for rel, (tpl, known) in OLD_COPIES.items()
                if (root / rel).is_file() and fingerprint((root / rel).read_text(encoding="utf-8")) in known}
    current = all(p.is_commit and p.version == target and (not commit or p.ref == commit) for ps in pins.values() for p in ps)
    def crosses(after: tuple[int, ...]) -> bool:
        """Whether this upgrade moves a pin at or below that release to a km past it (decided before the pins move)."""
        return (version_key(target) or ()) > after and any(
            (k := version_key(p.version)) and k <= after for ps in pins.values() for p in ps)
    digest_crossing, index_crossing = crosses(DIGEST_AFTER), crosses(INDEX_AFTER)
    if rewrites or not current:               # decided before any write, so a failed lookup changes nothing
        values = pin_values(target, commit)
    else:                                      # already on the release: still check it is the release's commit
        values = {"<KM_SHA>": sha, "<KM_VERSION>": target} if (sha := commit or (pins and resolve(target))) else {}
    stray = sorted({p.ref for ps in pins.values() for p in ps if values and p.ref != values["<KM_SHA>"]})

    done: list[str] = [f"a pin names km {target} but points at {r[:12]}, not its release commit; re-pinned"
                       for r in stray if current]
    local = root / "schema.local.yaml"
    # A team brain: the old team_brain marker, or a km workflow only `km init --team` writes.
    wf = root / ".github/workflows"
    ci_path = wf / "ci.yml"
    ci_text = ci_path.read_text(encoding="utf-8", errors="replace") if ci_path.is_file() else ""
    team = ((wf / "staleness.yml").is_file() or "pasrom/km" in ci_text
            or local.is_file() and bool(MARKER.search(local.read_text(encoding="utf-8"))))
    for rel, (tpl, known) in OLD_COPIES.items():
        p = root / rel
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        if rel in rewrites:
            write_text(p, template(tpl, values))
            done.append(f"rewrote {rel} (it was km's own, unchanged) to install km")
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
    signoff = False                           # whether km's ci workflow runs the sign-off check after this upgrade
    if team:
        km_ci = ".github/workflows/ci.yml" in rewrites or ci_hash(ci_text) in KM_CI   # km's, or km's copy-in rewritten to it
        for tpl in ("team/dependabot.yml", *SHIPPED):
            rel = TEAM[tpl]
            p = root / rel
            if tpl == "team/approve-fork-ci.yml" and not safe_path(target):   # an older km, a --force downgrade too
                why = f"km {target} {AFC_TOO_OLD}"
                if not p.exists():
                    done.append(f"did not add {rel}: {why}; km 1.11.0 or later has it")
                elif (h := shipped_hash(p.read_text(encoding="utf-8"))) in ALLOWLIST_AFC:
                    done.append(f"left {rel} at its data-only version: this km's version needs km 1.11.0 or later")
                    if not km_ci and ci_text:
                        done.append(f"{rel} lets a fork's ci run start unreviewed, but ci.yml is not km's unchanged one: "
                                    f"check that ci.yml runs nothing from the checkout but km, or remove {rel}")
                elif h in SHIPPED[tpl]:
                    p.unlink()
                    done.append(f"removed {rel}: {why}; a fork's ci run waits for a person again")
                else:
                    done.append(f"{rel} is the brain's own, and {why}: check that it approves data only, or remove it")
                continue
            if tpl == "team/approve-fork-ci.yml" and not km_ci:     # checked on every upgrade: ci.yml may change later
                if not p.exists():
                    ci_is = "ci.yml is not km's unchanged one" if ci_text else "there is no ci.yml"
                    done.append(f"did not add {rel}: it lets a fork's ci run start unreviewed, and {ci_is}; once ci.yml "
                                f"runs nothing from the checkout but km, copy it from km's src/km/templates/{tpl}")
                    continue
                if ci_text:                          # without a ci.yml it has no run to approve
                    done.append(f"{rel} lets a fork's ci run start unreviewed, but ci.yml is not km's unchanged one: "
                                f"check that ci.yml runs nothing from the checkout but km, or remove {rel}")
            new = template(tpl, {})
            if not p.exists():
                p.parent.mkdir(parents=True, exist_ok=True)
                write_text(p, new)
                done.append(f"added {rel}")
                if tpl == "team/bump-mounted-pins.yml" and (root / ".gitmodules").is_file():
                    done.append("this brain has mounts: before the workflow's first run, create the environment mounted-pins "
                                "restricted to main, or GitHub creates it open to every branch (setup in the workflow's header)")
                if tpl == "team/review-request-guide.yml":
                    done.append(f"{rel} does nothing until the repository variable KM_MAINTAINERS lists the maintainers' GitHub logins")
            elif tpl in SHIPPED and (copy := p.read_text(encoding="utf-8")) != new and (h := shipped_hash(copy)) != shipped_hash(new):
                if tpl == "team/approve-fork-ci.yml" and h in ALLOWLIST_AFC and not km_ci:
                    done.append(f"left {rel}: this km's version approves a fork's ci run for any file but control files "
                                f"(a script in a doc folder too), and ci.yml is not km's unchanged one")
                elif h in SHIPPED[tpl]:
                    write_text(p, carry_pins(copy, new))
                    done.append(f"updated {rel} to this km's version (it was an earlier one, unchanged but for its action pins, keeping those newer than km's)")
                else:
                    done.append(f"left {rel}: the brain changed it, so it gets no later fixes; "
                                f"compare it with km's src/km/templates/{tpl}")
        ci = str(Path(".github/workflows/ci.yml"))              # as read_pins names it, with the OS's separator
        if ci in pins and (got := with_dispatch(text := (root / ci).read_text(encoding="utf-8"))) != text:   # km's ci workflow
            if got is None:
                done.append(f"could not add the workflow_dispatch trigger to {ci}: add `workflow_dispatch:` under its `on:` "
                            f"by hand, so a pull request a workflow opens can run the check")
            else:
                write_text(root / ci, got)
                done.append(f"added the workflow_dispatch trigger to {ci}")
        signoff = ci in pins and (version_key(target) or ()) >= SIGNOFF_SINCE
        if signoff and (got := with_signoff(text := (root / ci).read_text(encoding="utf-8"))) != text:
            if got is None:
                signoff = False
                done.append(f"could not turn on the sign-off check in {ci}: change its `km validate` step as in km's "
                            f"templates/team/ci.yml by hand, so a pull request fails on a changed doc that is not signed off")
            else:
                write_text(root / ci, got)
                done.append(f"turned on the sign-off check in {ci}: a pull request now fails on a doc it changes that is "
                            f"not signed off (docs already on main are checked once a pull request changes their content)")
        rel = ".github/workflows/staleness.yml"                 # km's only (it pins km), as with ci.yml
        if str(Path(rel)) in pins and (got := with_full_history(text := (root / rel).read_text(encoding="utf-8"))) != text:
            if got is None:
                done.append(f"could not give the checkout step of {rel} `fetch-depth: 0`: add `with: {{fetch-depth: 0}}` "
                            f"to it by hand, so its run validates source pins against the full history")
            else:
                write_text(root / rel, got)
                done.append(f"gave the checkout step of {rel} `fetch-depth: 0`, so its run validates source pins")
        hook = root / ".pre-commit-config.yaml"
        if not hook.is_file():
            done.append(f"no {hook.name}: nothing refuses a commit on main or a push to main locally; `km init` writes one")
        elif (got := with_team_hooks(text := hook.read_text(encoding="utf-8"))) is None:
            done.append(f"could not add the hooks a team brain carries to {hook.name}: add `no-commit-to-branch` with `args: [--branch, main]` "
                        f"from https://github.com/pre-commit/pre-commit-hooks, km's `no-push-to-main` hook "
                        f"(templates/team/no-push-hook.yaml), `default_install_hook_types: [pre-commit, pre-push]` and "
                        f"`default_stages: [pre-commit]` by hand, whichever it lacks")
        elif got[0] != text:
            again = "; run `pre-commit install` again so git gets the pre-push hook" if "pre-push in default_install_hook_types" in got[1] else ""
            done.append(f"added {', '.join(got[1])} to {hook.name}{again}")
        if hook.is_file():
            new = text if got is None else got[0]
            # every km pin ends on the target, so the hook is named only where that release has it
            if not gen_index_hook(target) and f"id: {GEN_INDEX}" in new:     # --force back to a km without it
                done.append(f"{hook.name} names the {GEN_INDEX} hook, which km {target} lacks: remove it by hand, "
                            f"or pre-commit refuses every commit")
            elif gen_index_hook(target) and (gen := with_gen_index(new)) != new:
                if gen is None:
                    done.append(f"could not add km's {GEN_INDEX} hook to {hook.name}: add `- id: {GEN_INDEX}` under `km-validate` "
                                f"in its https://github.com/pasrom/km entry by hand, so a stale _index.md fails the commit, not CI")
                else:
                    new = gen
                    done.append(f"added the {GEN_INDEX} hook to {hook.name}: a stale _index.md now fails the commit, not CI")
            if new != text:
                write_text(hook, new)
    if note := ensure_lf(root):
        done.append(note)
    # once, when the brain crosses to a km that checks the digest: a later upgrade never takes text as approved,
    # since nothing it can read offline tells an approval from before digests from one typed by hand later
    if not digest_crossing and signoff and (unbound := undigested(root)):
        done.append(f"{len(unbound)} accepted doc(s) have approved_by but no digest, and this upgrade does not move the brain "
                    f"from a km at or below {'.'.join(map(str, DIGEST_AFTER))}, so km cannot tell their approval from one "
                    f"typed by hand and records none: {', '.join(unbound)}. Each passes the sign-off check until a pull "
                    f"request changes its content; that pull request then sends it back to review (`km demote <doc>`) "
                    f"and approves it after review (`km approve <doc> --by <approver>`)")
    if digest_crossing:
        signed, left = record_digests()
        if signed:
            done.append(f"recorded approved_digest for the current content of {len(signed)} accepted doc(s), taking "
                        f"that text as the approved one (check `git diff`): {', '.join(signed)}")
        if left:
            done.append(f"recorded no approved_digest for {', '.join(left)}: nobody approved that text; send each back to "
                        f"review (`km demote <doc>`) and approve it after review, or revert the change")
    # once, when the brain crosses to a km whose gen-index writes titles as written: its CI's
    # `km gen-index --check` would fail on the lists the old rules wrote
    if index_crossing:
        rewritten, unindexed = regenerate_indexes(root)
        if rewritten:
            done.append(f"regenerated the '## Documents' list of {', '.join(rewritten)}: km {target} writes a title as "
                        f"written, not as YAML reads it (1.10, not 1.1), and a list stale for another reason is brought "
                        f"up to date too; check `git diff`")
        if unindexed:
            done.append(f"{', '.join(unindexed)} hold docs but no _index.md, which `km gen-index --check` fails on: "
                        f"write one by hand (frontmatter, intro, an empty '## Documents' heading)")

    if values and (not current or stray):
        sha = values["<KM_SHA>"]
        done += [f"pinned {f} to km {target} ({sha[:12]})" for f in set_pins(root, sha, target)]
    if values and set_schema_link(root, values["<KM_SHA>"], target):   # also on a brain already on the release
        done.append(f"pointed the base-schema link in CONVENTIONS.md at km {target}")
    elif not values and (conv := root / "CONVENTIONS.md").is_file() and any(
            m.group(3) != target for m in SCHEMA_LINK.finditer(conv.read_text(encoding="utf-8"))):
        done.append(f"left the base-schema link in CONVENTIONS.md: km {target}'s commit could not be looked up")
    done += [f"{f} runs {what} from a movable ref: pin it by commit" for f, what in movable_refs(root)]
    for line in done or [f"already on km {target}"]:
        print(f"km upgrade: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
