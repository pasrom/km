#!/usr/bin/env bash
# A brain on a branch that adds one doc; main is the base.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
W="$PWD"
brain "$W" EV
git -C "$W" "${G[@]}" switch -q -c docs/thermal-derating
doc "$W" inbox/thermal-derating.md "Thermal derating curve" review "Above 45 degrees Celsius the charge current is reduced by 2 percent per degree."
git -C "$W" "${G[@]}" add -A && git -C "$W" "${G[@]}" commit -q -m "docs(inbox): thermal derating"
