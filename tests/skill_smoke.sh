#!/usr/bin/env bash
# Smoke test for the skill: the split of SKILL.md into a core and reference files lost nothing
# (tests/skill_inventory.py against the frozen pre-split SKILL.md), and the core keeps its limits.
set -u
source "$(dirname "$0")/lib.sh"
cd "$REPO"
out="$(kmpy tests/skill_inventory.py 2>&1)"; rc=$?; echo "$out" | tail -1
[ "$rc" = 0 ] && ok "every baseline paragraph and atom is in exactly one new file" || { echo "$out" | grep FAIL; no "skill inventory"; }
summary skill_smoke
