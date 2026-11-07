#!/usr/bin/env bash
# Smoke test for the skill: the core keeps its limits, no Markdown line is cut by the Read tool, and
# its pointers to the reference files resolve (tests/skill_inventory.py).
set -u
source "$(dirname "$0")/lib.sh"
cd "$REPO"
out="$(kmpy tests/skill_inventory.py 2>&1)"; rc=$?; echo "$out" | tail -1
[ "$rc" = 0 ] && ok "the core keeps its limits, every reference resolves, every /km verb has a dispatch row" || { echo "$out" | grep FAIL; no "skill inventory"; }
# the check bites: a copy of the skill without the review/approve row fails, though "review" stays in another row's text
C="$(mktemp -d)"; trap 'rm -rf "$C"' EXIT
mkdir -p "$C/skills" && cp -R skills/km "$C/skills/" && cp README.md "$C/"
grep -v '^| `review <doc>' skills/km/SKILL.md > "$C/skills/km/SKILL.md"
out="$(kmpy tests/skill_inventory.py --skill "$C/skills/km" 2>&1)"
{ grep -q "no row for /km approve" <<< "$out" && grep -q "no row for /km review" <<< "$out"; } \
  && ok "a verb whose row is gone fails, also one the README never names" || no "missing dispatch row ($out)"
# the size checks bite: a core over CORE_BYTES, a reference file over CONTENTS_BYTES without its
# contents list, and a line over MAX_LINE characters (a multi-byte one, so characters are counted)
cp skills/km/SKILL.md "$C/skills/km/SKILL.md" && printf 'x%.0s' $(seq 12001) >> "$C/skills/km/SKILL.md"
grep -v '^## Contents' skills/km/reference/brains.md > "$C/skills/km/reference/brains.md"
{ printf '\n'; printf 'x%.0s' $(seq 1901); printf '\n'; } >> "$C/skills/km/reference/queue.md"
{ printf '\n'; printf 'ü%.0s' $(seq 1000); printf '\n'; } >> "$C/skills/km/reference/github-reads.md"
out="$(kmpy tests/skill_inventory.py --skill "$C/skills/km" 2>&1)"
grep -q "SKILL.md is [0-9]* bytes, limit" <<< "$out" && ok "a core over CORE_BYTES fails" || no "core size ($out)"
grep -q "brains.md is [0-9]* bytes, over [0-9]*, and has no '## Contents' list" <<< "$out" \
  && ok "a large reference file without a contents list fails" || no "contents list ($out)"
{ grep -q "queue.md:[0-9]* is 1901 characters" <<< "$out" && ! grep -q "github-reads.md:[0-9]* is" <<< "$out"; } \
  && ok "a line over the limit fails, counted in characters" || no "line length ($out)"
summary skill_smoke
