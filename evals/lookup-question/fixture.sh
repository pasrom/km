#!/usr/bin/env bash
# A brain with one doc that holds a distinctive fact the prompt asks for.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
W="$PWD"
brain "$W" EV
doc "$W" inbox/pump-startup-delay.md "Coolant pump start-up delay" accepted \
  "The coolant pump starts 850 ms after the main contactor closes, so that the inrush of the pump never overlaps the precharge phase. Measured on the bench rig in January 2026."
git -C "$W" "${G[@]}" add -A && git -C "$W" "${G[@]}" commit -q -m "docs(inbox): pump start-up delay"
