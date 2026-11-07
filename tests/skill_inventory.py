"""Nothing of the skill got lost in the split of SKILL.md into a core and reference files.

The baseline is the SKILL.md before the split (tests/fixtures/skill-baseline.md, frozen). The
split moved text verbatim and only changed pointers: every change is an entry of REWRITES, so the
checker applies them to the baseline and then requires each baseline paragraph (blank-line
separated; a code fence counts as one paragraph) to occur in the new files as often as in the
baseline, as whole lines. REWRAPPED lists the paragraphs a later commit re-wrapped or split with
the wording untouched: those must occur once with whitespace normalised.

Whatever the paragraphs, the atoms of the baseline must survive: every heading, every inline code
span and every sentence with a hard-rule word (never, always, STOP, only, refuse) is looked for in
the union of the new files. Then the core's own limits: 500 lines and CORE_BYTES, a description of at most 1024
characters, every reference file named by its full `${CLAUDE_SKILL_DIR}/reference/` path and every
such path resolving, a contents list in a reference file over 100 lines, and a row in the dispatch
table for every `/km <verb>` the README and the baseline mention, `help` included.

    python3 tests/skill_inventory.py [--skill skills/km] [--baseline tests/fixtures/skill-baseline.md]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REF = "${CLAUDE_SKILL_DIR}/reference"
# (old text, new text): the pointer changes the split made, applied to the baseline. Each must hit.
REWRITES: list[tuple[str, str]] = [
    ('as in "Reading GitHub through\nMCP".', f'as in "Reading GitHub through\nMCP" (`{REF}/github-reads.md`).'),
    ('(see "Keeping the copy current")', f'(see "Running km and keeping the copy current" in `{REF}/setup.md`)'),
    ('(see "Open pull requests")', f'(see "Open pull requests" in `{REF}/github-reads.md`)'),
    ('1. The gh check in "GitHub access" (Setup); abort if it fails.',
     '1. The gh check in "GitHub access" (SKILL.md); abort if it fails.'),
    ('1. The gh check in "GitHub access" (Setup). Choose', '1. The gh check in "GitHub access" (SKILL.md). Choose'),
    ('the Ripple update rules (see "Ripple update" below). Commit there per "Writing content".',
     'the Ripple update rules (see "Ripple update" in SKILL.md). Commit there per "Writing content" (SKILL.md).'),
    ('5. Prepare the PR (`/km pr` steps 1–4), then push',
     f'5. Prepare the PR (`/km pr` steps 1–4, `{REF}/review-and-pr.md`), then push'),
    ('7. Prepare the PR (`/km pr` steps 1–4), push and open it',
     f'7. Prepare the PR (`/km pr` steps 1–4, `{REF}/review-and-pr.md`), push and open it'),
    ('the throwaway-clone `brain fix` flow above; the submodule is untouched.',
     f'the throwaway-clone `brain fix` flow (`{REF}/brains.md`); the submodule is untouched.'),
    ('→ `contribute @<name>` below: the throwaway-clone', f'→ `contribute @<name>` (`{REF}/brains.md`): the throwaway-clone'),
    ('(see "Running km")', f'(see "Running km and keeping the copy current" in `{REF}/setup.md`)'),
    ('cited per "Citation format".', 'cited per "Citation format" (SKILL.md).'),
    ('(see "Source pins" below)', f'(see "Source pins" in `{REF}/pins-and-cites.md`)'),
    ('(see "Approval" below)', f'(see "Approval" in `{REF}/review-and-pr.md`)'),
    ('(hard rule under "Contributing content")', f'(hard rule under "Contributing content" in `{REF}/brains.md`)'),
    ('resolve as in "Routing", brains only', 'resolve as in "Routing" (SKILL.md), brains only'),
    ('offer `/km review`, run on a new branch.', f'offer `/km review` (`{REF}/review-and-pr.md`), run on a new branch.'),
    ('2. **Open PRs.** `<repo>` as in "Open pull requests" step 1,',
     f'2. **Open PRs.** `<repo>` as in "Open pull requests" step 1 (`{REF}/github-reads.md`),'),
    ('the MCP read per "GitHub access" (no minimal output)', 'the MCP read per "GitHub access" (SKILL.md; no minimal output)'),
    ('(see "Citation format" above)', '(see "Citation format" below)'),       # the rules moved to the top
    ('**Running km.** `bin/km` next to this SKILL.md runs km', '**Running km.** `${CLAUDE_SKILL_DIR}/bin/km` (next to SKILL.md) runs km'),
    ('post nothing, as in "GitHub access": give the user', 'post nothing, as in "GitHub access" (SKILL.md): give the user'),
    # the pre-push hook of this release: the first push of a fresh team brain needs --no-verify once
    ("5. Tell the user what km does not do: create the repo (private), push `main`, give the team **read**",
     "5. Tell the user what km does not do: create the repo (private), push `main` (after `pre-commit install` the\n"
     "   pre-push hook refuses a push to `main`: the first push of the fresh brain takes `--no-verify`, once), give the team **read**"),
]
# paragraph prefixes whose text is unchanged but re-wrapped or split into several paragraphs
REWRAPPED: list[str] = [
    "When a doc cites a SharePoint or OneDrive file, record it under `cites:`",   # one wall of text, now four paragraphs
    "Set `check_index: true` at the top of `schema.local.yaml`",                  # one wall of text, now three paragraphs
]
RULE_WORD = re.compile(r"\b(never|always|STOP|only|refuse[sd]?)\b")
# The core must stay inside what a compaction re-attaches of a skill, its first 5,000 tokens, as a
# byte limit since CI has no tokenizer: 11,524 bytes measured 4,593 API tokens (one-turn haiku
# differential, 2026-11-07), 2.5 bytes per token for this file's mix of prose, code spans and a
# table, so 12,000 bytes is about 4,780 tokens, 4 percent under the budget. Re-measure the ratio if
# the file's character changes a lot.
CORE_BYTES = 12000


def body(text: str) -> str:
    """The markdown after the frontmatter."""
    return text.split("\n---\n", 1)[1] if text.startswith("---\n") else text


def paragraphs(text: str) -> list[str]:
    """Blank-line separated blocks; a fenced code block (with any blank lines inside) is one block."""
    out, cur, fence = [], [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        if not line.strip() and not fence:
            if cur:
                out.append("\n".join(cur))
            cur = []
        else:
            cur.append(line)
    if cur:
        out.append("\n".join(cur))
    return out


def atoms(pars: list[str]) -> list[str]:
    """Headings, inline code spans and rule sentences of the paragraphs."""
    out = []
    for par in pars:
        if par.lstrip().startswith("#"):
            out.append(par.strip())
        elif not par.lstrip().startswith("```"):
            out += re.findall(r"`[^`\n]+`", par)
            out += [s for s in re.split(r"(?<=[.;:])\s+(?=[A-Z`*(])", flat(par)) if RULE_WORD.search(s)]
    return out


def flat(text: str) -> str:
    return " ".join(text.split())


def count(par: str, text: str) -> int:
    """How often `par` occurs in `text` as whole lines (a heading must not count inside a longer one)."""
    return ("\n" + text + "\n").count("\n" + par + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", default="skills/km")
    ap.add_argument("--baseline", default="tests/fixtures/skill-baseline.md")
    a = ap.parse_args()
    skill = Path(a.skill)
    refs = sorted((skill / "reference").glob("*.md"))
    files = {p.name if p.parent == skill else f"reference/{p.name}": p.read_text(encoding="utf-8") for p in [skill / "SKILL.md", *refs]}
    core, union = files["SKILL.md"], "\n".join(files.values())
    union_flat = flat(union)
    base = body(Path(a.baseline).read_text(encoding="utf-8"))
    problems = []
    for old, new in REWRITES:
        if old not in base:
            problems.append(f"rewrite source not in the baseline (stale entry): {old!r}")
        base = base.replace(old, new)
    base_pars = paragraphs(base)

    # 1. paragraph containment
    rewrapped = set()
    for par in base_pars:
        if key := next((k for k in REWRAPPED if par.startswith(k)), None):
            rewrapped.add(key)
            if union_flat.count(flat(par)) != 1:
                problems.append(f"re-wrapped paragraph not found once with whitespace normalised: {par[:90]!r}")
        elif (n := count(par, union)) != (want := count(par, base)):
            problems.append(f"paragraph found {n}x, expected {want}: {par[:90]!r}")
    for key in REWRAPPED:
        if key not in rewrapped:
            problems.append(f"REWRAPPED entry matches no baseline paragraph (stale): {key!r}")

    # 2. atoms
    base_atoms = atoms(base_pars)
    problems += [f"atom lost: {atom!r}" for atom in base_atoms if flat(atom) not in union_flat]

    # 3. the core's limits
    if len(core.splitlines()) > 500:
        problems.append(f"SKILL.md has {len(core.splitlines())} lines, limit 500")
    if (n := len(core.encode("utf-8"))) > CORE_BYTES:
        problems.append(f"SKILL.md is {n} bytes, limit {CORE_BYTES}: a byte proxy for the 5,000 tokens a compaction keeps of a "
                        f"skill (calibrated 2026-11-07 with a one-turn haiku differential, see CORE_BYTES); move text to a reference file")
    m = re.search(r"(?m)^description: >-\n((?:  .*\n)+)", core)
    desc = " ".join(m.group(1).split()) if m else ""
    if not desc or len(desc) > 1024:
        problems.append(f"description is {len(desc)} chars (limit 1024)")
    for ref in refs:
        if f"`{REF}/{ref.name}`" not in core:
            problems.append(f"SKILL.md never names `{REF}/{ref.name}`")
        if len(files[f"reference/{ref.name}"].splitlines()) > 100 and "## Contents" not in files[f"reference/{ref.name}"]:
            problems.append(f"{ref.name} is over 100 lines and has no '## Contents' list")
    for name, text in files.items():
        for hit in re.findall(r"\$\{CLAUDE_SKILL_DIR\}/reference/([\w-]+\.md)", text):
            if not (skill / "reference" / hit).is_file():
                problems.append(f"{name} points at a missing reference file: {hit}")
    table = re.search(r"(?ms)^\| Request.*?(?=^## )", core)
    table = table.group(0) if table else ""
    readme = (skill.parent.parent / "README.md").read_text(encoding="utf-8")
    for verb in sorted(set(re.findall(r"(?<![\w/])/km ([a-z][a-z-]*)", readme + base))):
        if not re.search(rf"`{verb}\b|\b{verb}\b", table):
            problems.append(f"dispatch table has no row for /km {verb}")
    if "`help`" not in table:
        problems.append("dispatch table does not define `help`")

    for p in problems:
        print(f"  FAIL: {p}")
    print(f"skill inventory: {len(base_pars)} paragraphs, {len(base_atoms)} atoms, {len(files)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
