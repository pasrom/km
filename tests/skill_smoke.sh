#!/usr/bin/env bash
# Smoke test for the skill: the core keeps its limits and its pointers to the reference files resolve
# (tests/skill_inventory.py).
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
summary skill_smoke
