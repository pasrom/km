#!/usr/bin/env bash
# Non-ASCII file names where the encoding is not UTF-8 (Windows: cp1252): km must find them, report
# them without crashing and write LF. CI runs it on Windows; team_smoke.sh runs it under every
# Windows-like environment the machine has.
# Run:  bash tests/encoding_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
U="$(mktemp -d)"
trap 'rm -rf "$U"' EXIT
G(){ git -C "$U" -c user.name=t -c user.email=t@t -c core.autocrlf=false "$@"; }
run(){ out="$(km "$1" --root "$U" "${@:2}" 2>&1 | tr -d '\r')"; }    # Windows prints CRLF

G init -q; mkdir -p "$U/notes"; echo "# conv" > "$U/CONVENTIONS.md"
printf 'check_index: true\n' > "$U/schema.local.yaml"
printf -- '---\ntype: reference\ntitle: "Notes"\ntimestamp: 2026-01-01\nauthor: X\nstatus: draft\ntags: [t]\n---\n\n## Documents\n' > "$U/notes/_index.md"
printf -- '---\ntype: note\ntitle: "Künstler"\ntimestamp: 2026-01-01\nauthor: X\nstatus: draft\ntags: [t]\n---\nx\n' > "$U/notes/künstler.md"
printf -- '---\ntitle: "no type"\n---\nx\n' > "$U/notes/őrült.md"      # an error to report, with a character cp1252 lacks
G add -A; G commit -qm init

run gen-index
{ ! out_has Traceback && grep -q "(künstler.md)" "$U/notes/_index.md" && ! grep -q $'\r' "$U/notes/_index.md"; } \
  && ok "gen-index lists a non-ASCII file name and writes LF" || no "gen-index with non-ASCII names ($out)"
G add -A; G commit -qm index
run gen-index --check
out_has "up to date" && ok "gen-index --check: up to date" || no "gen-index --check ($out)"
run validate
{ ! out_has Traceback && out_has "required field 'type' absent" && out_has "^ERRORS: [1-9]"; } \
  && ok "validate finds and reports non-ASCII file names" || no "validate with non-ASCII names ($out)"
[ -z "$(G status --porcelain)" ] && ok "km left the work tree as committed" || no "km changed the work tree: $(G status --porcelain)"
summary encoding-smoke
