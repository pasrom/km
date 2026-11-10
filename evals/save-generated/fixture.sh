#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
brain "$PWD" EV
# a measurement export the note plots, outside git
mkdir -p "$PWD/export" && { echo "t_s,temp_c"; for t in 0 60 120 180 240 300 360 420 480 540 600; do echo "$t,$((25 + t / 20))"; done; } > "$PWD/export/run1.csv"
printf 'export/\n' >> "$PWD/.git/info/exclude"
# a brain set up before the rule: its CONVENTIONS.md does not have it, only the skill does
python3 - "$PWD/CONVENTIONS.md" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(re.sub(r"## Generated Files\n\n.*?\n\n", "", s, flags=re.S))
PY
grep -q "Generated Files" "$PWD/CONVENTIONS.md" && { echo "fixture: rule still in CONVENTIONS.md" >&2; exit 1; }
git -C "$PWD" "${G[@]}" commit -qam "docs: conventions before the generated-files rule"
