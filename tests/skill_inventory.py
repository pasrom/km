"""The skill's core keeps its limits, and its dispatch table and reference files stay consistent.

The core SKILL.md: CORE_BYTES, a description of at most 1024 characters, every reference file
named by its full `${CLAUDE_SKILL_DIR}/reference/` path and every such path resolving, a contents
list in a reference file over CONTENTS_BYTES, no line over MAX_LINE characters in any Markdown file
under skills/, and a row in the dispatch table (the verb opening a code span or a quoted phrase) for
every `/km <verb>` the README or the skill's own files mention, `help` included.

    python3 tests/skill_inventory.py [--skill skills/km]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REF = "${CLAUDE_SKILL_DIR}/reference"
# The core must stay inside what a compaction re-attaches of a skill, its first 5,000 tokens, as a
# byte limit since CI has no tokenizer: 11,524 bytes measured 4,593 API tokens (one-turn haiku
# differential, 2026-11-07), 2.5 bytes per token for this file's mix of prose, code spans and a
# table, so 12,000 bytes is about 4,780 tokens, 4 percent under the budget. Re-measure the ratio if
# the file's character changes a lot.
CORE_BYTES = 12000
# The limits below were line counts (500 for the core, a contents list over 100 lines), which meant
# something while the Markdown was hard-wrapped near 100 columns; with one paragraph per line a file
# has as many lines as paragraphs. Measured on the hard-wrapped files (4777eb7), the reference files
# averaged 69 bytes a line and SKILL.md 76, so 500 lines were about 38,000 bytes, three times
# CORE_BYTES: the core's line limit never bound and goes without a replacement. The 100-line rule
# split the reference files into github-reads, pins-and-cites and queue (3,433 to 3,702 bytes,
# under) and setup, validate-and-gate, review-and-pr and brains (8,064 to 13,599 bytes, over); 6,000
# bytes keeps that split with room on both sides.
CONTENTS_BYTES = 6000
# Claude's Read tool cuts a line after 2,000 characters, so the rest of a longer paragraph is never
# seen. Characters, not bytes, since that is what it counts; 100 under it, so an edit that nears the
# cut fails here first. All of skills/, not only this skill's files.
MAX_LINE = 1900


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", default="skills/km")
    a = ap.parse_args()
    skill = Path(a.skill)
    refs = sorted((skill / "reference").glob("*.md"))
    files = {p.name if p.parent == skill else f"reference/{p.name}": p.read_text(encoding="utf-8") for p in [skill / "SKILL.md", *refs]}
    core = files["SKILL.md"]
    problems = []
    if (n := len(core.encode("utf-8"))) > CORE_BYTES:
        problems.append(f"SKILL.md is {n} bytes, limit {CORE_BYTES}: a byte proxy for the 5,000 tokens a compaction keeps of a "
                        f"skill (calibrated 2026-11-07 with a one-turn haiku differential, see CORE_BYTES); move text to a reference file")
    m = re.search(r"(?m)^description: >-\n((?:  .*\n)+)", core)
    desc = " ".join(m.group(1).split()) if m else ""
    if not desc or len(desc) > 1024:
        problems.append(f"description is {len(desc)} chars (limit 1024)")
    for ref in refs:
        text = files[f"reference/{ref.name}"]
        if f"`{REF}/{ref.name}`" not in core:
            problems.append(f"SKILL.md never names `{REF}/{ref.name}`")
        if (n := len(text.encode("utf-8"))) > CONTENTS_BYTES and not re.search(r"(?m)^## Contents$", text):
            problems.append(f"{ref.name} is {n} bytes, over {CONTENTS_BYTES}, and has no '## Contents' list")
    for md in sorted(skill.parent.rglob("*.md")):
        for no, line in enumerate(md.read_bytes().decode("utf-8").split("\n"), 1):   # at \n only, as the Read tool splits
            if len(line) > MAX_LINE:
                problems.append(f"{md.relative_to(skill.parent.parent)}:{no} is {len(line)} characters, limit {MAX_LINE}: "
                                f"the Read tool cuts lines at 2000; split the paragraph")
    for name, text in files.items():
        for hit in re.findall(r"\$\{CLAUDE_SKILL_DIR\}/reference/([\w-]+\.md)", text):
            if not (skill / "reference" / hit).is_file():
                problems.append(f"{name} points at a missing reference file: {hit}")
    table = re.search(r"(?ms)^\| Request.*?(?=^## )", core)
    table = table.group(0) if table else ""
    readme = (skill.parent.parent / "README.md").read_text(encoding="utf-8")
    for verb in sorted(set(re.findall(r"(?<![\w/])/km ([a-z][a-z-]*)", readme + "\n".join(files.values())))):
        if not re.search(rf"[`\"]{verb}\b", table):   # opening a code span or a quoted phrase, not as a word in another row's text
            problems.append(f"dispatch table has no row for /km {verb}")
    if "`help`" not in table:
        problems.append("dispatch table does not define `help`")

    for p in problems:
        print(f"  FAIL: {p}")
    print(f"skill inventory: {len(files)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
