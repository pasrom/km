#!/usr/bin/env bash
# A brain with a doc and a summary that pins it under sources: without a hash yet.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
W="$PWD"
brain "$W" EV
doc "$W" inbox/thermal-derating.md "Thermal derating curve" accepted "Above 45 degrees Celsius the charge current is reduced by 2 percent per degree."
printf -- '---\ntitle: Derating summary\ntype: summary\nstatus: draft\nauthor: EV\ndate: 2026-01-20\ntags: [eval]\nsources:\n  - inbox/thermal-derating.md\n---\n\n# Derating summary\n\nCharge current drops 2 percent per degree above 45 degrees Celsius.\n' > "$W/inbox/summary.md"
git -C "$W" "${G[@]}" add -A && git -C "$W" "${G[@]}" commit -q -m "docs(inbox): derating and its summary"
