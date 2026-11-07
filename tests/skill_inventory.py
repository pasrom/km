"""Nothing of the skill got lost in the split of SKILL.md into a core and reference files.

The baseline is the SKILL.md before the split (tests/fixtures/skill-baseline.md, frozen). The
split moved text verbatim and only changed pointers: every change is an entry of REWRITES, so the
checker applies them to the baseline and then requires each baseline paragraph (blank-line
separated; a code fence counts as one paragraph) to be a substring of exactly one of the new
files. DUPLICATES lists the paragraphs that may appear more often, with why. REWORDED lists the
paragraphs a later commit tightened on purpose: each names what the new text must still hold.

Whatever mode, the atoms of the baseline must survive: every heading, every inline code span and
every sentence with a hard-rule word (never, always, STOP, only, refuse) is looked for in the union
of the new files, unless REWORDED_ATOMS names it with its replacement.

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
    ('(see "Keeping the copy current")', '(see "Keeping the copy current" in SKILL.md)'),
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
    ('(see "Running km")', '(see "Running km" in SKILL.md)'),
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
]
# paragraph prefix -> (how often it may appear, why); without an entry, as often as in the baseline
DUPLICATES: dict[str, tuple[int, str]] = {}
# paragraph prefix -> the substrings the tightened text must still hold (each in exactly one file)
REWORDED: dict[str, list[str]] = {}
# atom (heading, code span or rule sentence) -> what replaces it, or "" when it was folded into
# another atom that is still checked
REWORDED_ATOMS: dict[str, str] = {}
RULE_WORD = re.compile(r"\b(never|always|STOP|only|refuse[sd]?)\b")
# The core must stay inside what a compaction re-attaches of a skill, its first 5,000 tokens, as a
# byte limit since CI has no tokenizer: 11,524 bytes measured 4,593 API tokens (one-turn haiku
# differential, 2026-11-07), 2.5 bytes per token for this file's mix of prose, code spans and a
# table, so 12,000 bytes is about 4,780 tokens, 4 percent under the budget. Re-measure the ratio if
# the file's character changes a lot.
CORE_BYTES = 12000


def body(text: str) -> str:
    """The markdown after the frontmatter."""
    if text.startswith("---\n"):
        return text.split("\n---\n", 1)[1]
    return text


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


def sentences(par: str) -> list[str]:
    flat = " ".join(par.split())
    return [s.strip() for s in re.split(r"(?<=[.;:])\s+(?=[A-Z`*(])", flat) if s.strip()]


def atoms(text: str) -> list[str]:
    out = []
    for par in paragraphs(text):
        if par.lstrip().startswith("#"):
            out.append(par.strip())
            continue
        if par.lstrip().startswith("```"):
            continue
        out += re.findall(r"`[^`\n]+`", par)
        out += [s for s in sentences(par) if RULE_WORD.search(s)]
    return out


def flat(text: str) -> str:
    return " ".join(text.split())


def count(par: str, text: str) -> int:
    """How often `par` occurs in `text` as whole lines (a heading must not count inside a longer one)."""
    n, i = 0, 0
    while (i := text.find(par, i)) != -1:
        before, after = text[i - 1:i], text[i + len(par):i + len(par) + 1]
        n += (before in ("", "\n")) and (after in ("", "\n"))
        i += len(par)
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", default="skills/km")
    ap.add_argument("--baseline", default="tests/fixtures/skill-baseline.md")
    a = ap.parse_args()
    skill = Path(a.skill)
    files = {p.name if p.parent == skill else f"reference/{p.name}": p.read_text(encoding="utf-8")
             for p in [skill / "SKILL.md", *sorted((skill / "reference").glob("*.md"))]}
    base = body(Path(a.baseline).read_text(encoding="utf-8"))
    problems = []
    for old, new in REWRITES:
        if old not in base:
            problems.append(f"rewrite source not in the baseline (stale entry): {old!r}")
        base = base.replace(old, new)

    # 1. paragraph containment
    reworded = set()
    for par in paragraphs(base):
        key = next((k for k in REWORDED if par.startswith(k)), None)
        if key:
            reworded.add(key)
            for must in REWORDED[key]:
                if sum(t.count(must) for t in files.values()) != 1:
                    problems.append(f"tightened paragraph {key!r}: {must!r} not in exactly one file")
            continue
        n = sum(count(par, t) for t in files.values())
        want, why = next(((c, w) for k, (c, w) in DUPLICATES.items() if par.startswith(k)), (count(par, base), ""))
        if n != want:
            problems.append(f"paragraph found {n}x, expected {want}{' (' + why + ')' if why else ''}: "
                            f"{par[:90]!r}")
    for key in REWORDED:
        if key not in reworded:
            problems.append(f"REWORDED entry matches no baseline paragraph (stale): {key!r}")

    # 2. atoms
    union = "\n".join(files.values())
    union_flat = flat(union)
    for atom in atoms(base):
        if atom in REWORDED_ATOMS:
            new = REWORDED_ATOMS[atom]
            if new and new not in union and flat(new) not in union_flat:
                problems.append(f"replacement atom missing: {new!r}")
            continue
        if atom not in union and flat(atom) not in union_flat:
            problems.append(f"atom lost: {atom!r}")
    for atom in REWORDED_ATOMS:
        if atom not in atoms(base):
            problems.append(f"REWORDED_ATOMS entry is no baseline atom (stale): {atom!r}")

    # 3. structure
    core = files["SKILL.md"]
    if len(core.splitlines()) > 500:
        problems.append(f"SKILL.md has {len(core.splitlines())} lines, the docs say 500")
    if (n := len(core.encode("utf-8"))) > CORE_BYTES:
        problems.append(f"SKILL.md is {n} bytes, limit {CORE_BYTES}: a byte proxy for the 5,000 tokens a compaction keeps of a "
                        f"skill (calibrated 2026-11-07 with a one-turn haiku differential, see CORE_BYTES); move text to a reference file")
    m = re.search(r"(?m)^description: >-\n((?:  .*\n)+)", core)
    desc = " ".join(m.group(1).split()) if m else ""
    if not desc or len(desc) > 1024:
        problems.append(f"description is {len(desc)} chars (limit 1024)")
    for ref in sorted((skill / "reference").glob("*.md")):
        if f"`{REF}/`" not in core or f"`{ref.name}`" not in core:
            problems.append(f"SKILL.md never names {ref.name} (with the {REF}/ directory)")
        if len(ref.read_text(encoding="utf-8").splitlines()) > 100 and "## Contents" not in ref.read_text(encoding="utf-8"):
            problems.append(f"{ref.name} is over 100 lines and has no '## Contents' list")
    for name, text in files.items():
        for hit in re.findall(r"\$\{CLAUDE_SKILL_DIR\}/reference/([\w-]+\.md)", text):
            if not (skill / "reference" / hit).is_file():
                problems.append(f"{name} points at a missing reference file: {hit}")
        if "${CLAUDE_SKILL_DIR}/reference/" in text and re.search(r"reference\\|reference/\.\./", text):
            problems.append(f"{name}: reference path not plain forward-slash")

    table = re.search(r"(?ms)^\| Request.*?(?=^## )", core)
    table = table.group(0) if table else ""
    readme = (Path(a.skill).parent.parent / "README.md").read_text(encoding="utf-8")
    for verb in sorted({v for v in re.findall(r"(?<![\w/])/km ([a-z][a-z-]*)", readme + base)}):
        if not re.search(rf"`{verb}\b|\b{verb}\b", table):
            problems.append(f"dispatch table has no row for /km {verb}")
    for name in ("help",):
        if f"`{name}`" not in table:
            problems.append(f"dispatch table does not define `{name}`")

    for p in problems:
        print(f"  FAIL: {p}")
    print(f"skill inventory: {len(paragraphs(base))} paragraphs, {len(atoms(base))} atoms, "
          f"{len(files)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
