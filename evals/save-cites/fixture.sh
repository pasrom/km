#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/brain.sh"
brain "$PWD" EV
# the synced copy of the library the note links into, outside git
mkdir -p "$PWD/library/Specs" && printf '%%PDF-1.7\nshunt datasheet, 380 A continuous\n' > "$PWD/library/Specs/shunt-datasheet.pdf"
printf 'library/\n' >> "$PWD/.git/info/exclude"
