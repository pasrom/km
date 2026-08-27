#!/usr/bin/env bash
# Smoke test for the opt-in km gate + km_promote. Self-contained: builds a throwaway brain from
# the km scripts + schema.base.yaml and asserts key behaviour (incl. the fixes from PR #3 review).
# Run:  bash skills/km/tests/gate_smoke.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KM="$(dirname "$HERE")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/bms" "$T/sub" "$T/brains/peer" "$T/topics"
cp "$KM/validate.py" "$T/scripts/validate.py"
cp "$KM/km_promote.py" "$T/scripts/km_promote.py"
cp "$KM/schema.base.yaml" "$T/schema.base.yaml"
printf '[submodule "brains/peer"]\n  path = brains/peer\n  url = x\n' > "$T/.gitmodules"
printf 'PROJECT-BLUEBIRD\nACME_CORP\n' > "$T/.gate-terms.txt"
BASE_LOCAL=$'meta: {profile: smoke}\ngate:\n  enabled: true\n  forbidden_terms_file: .gate-terms.txt\n  email_allowlist: [example.org]\n'
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
V(){ python3 "$T/scripts/validate.py" "$@" >/dev/null 2>&1; }
acc(){ printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: %s\naudience: %s\ntags: [t]\nowner: X\napproved_by: X\napproved_at: 2026-08-26\n---\n%s\n' "${4:-accepted}" "$2" "$3" > "$1"; }

acc "$T/bms/a.md" internal "Kunde PROJECT-BLUEBIRD intern"
V "$T/bms/a.md" && ok "internal doc may name a customer" || no "internal doc may name a customer"

acc "$T/bms/b.md" customer "Kunde PROJECT-BLUEBIRD extern"
V "$T/bms/b.md" && no "customer-facing leak blocked" || ok "customer-facing leak blocked"

printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: review\naudience: internal\ntags: [t]\nowner: X\n---\nkey AKIAABCDEFGHIJKLMNOP\n' > "$T/bms/c.md"
V "$T/bms/c.md" && no "secret blocked (any status)" || ok "secret blocked (any status)"

printf -- '---\ntype: note\ntitle: w\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nwip\n' > "$T/bms/wip.md"
acc "$T/bms/d.md" internal "see [x](wip.md)"
V "$T/bms/d.md" && no "bergab (served->draft) blocked" || ok "bergab (served->draft) blocked"

# F4: secret in an EXEMPT file (README.md) is still caught
printf 'export AWS=AKIAABCDEFGHIJKLMNOP\n' > "$T/bms/README.md"
V "$T/bms/README.md" && no "secret in README (exempt) caught" || ok "secret in README (exempt) caught"

# F2: document-relative resolution wins over a same-named root file
acc "$T/dup.md" internal "root dup, accepted"
printf -- '---\ntype: note\ntitle: d\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsibling draft\n' > "$T/sub/dup.md"
acc "$T/sub/note.md" internal "see [x](dup.md)"
V "$T/sub/note.md" && no "F2 doc-relative wins (bergab on draft sibling)" || ok "F2 doc-relative wins (bergab on draft sibling)"

# F3: a term containing '_' still matches (term normalised like the text)
acc "$T/bms/f3.md" customer "vertrag mit ACME_CORP"
V "$T/bms/f3.md" && no "F3 underscore term matches" || ok "F3 underscore term matches"

# F5: an unknown gate key fails fast
printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n  forbiden_terms_file: .gate-terms.txt\n' > "$T/schema.local.yaml"
python3 "$T/scripts/validate.py" "$T/bms/a.md" 2>&1 | grep -q "unknown gate key" && ok "F5 unknown key fails fast" || no "F5 unknown key fails fast"

# F1: a configured-but-missing forbidden_terms_file is a WARNING, not silent
printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n  forbidden_terms_file: nope.txt\n' > "$T/schema.local.yaml"
python3 "$T/scripts/validate.py" "$T/bms/a.md" 2>&1 | grep -q "configured but not found" && ok "F1 missing terms file warns" || no "F1 missing terms file warns"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# B1: an escaping slug is refused, nothing written outside the repo
printf 'body\n' > "$T/src.txt"
python3 "$T/scripts/km_promote.py" "../../../../tmp/km-escape" "$T/src.txt" >/dev/null 2>&1
[ $? -eq 2 ] && [ ! -f /tmp/km-escape.md ] && ok "B1 slug escape refused" || no "B1 slug escape refused"

# B2: --replace does not clobber a doc inside a peer brain (submodule)
acc "$T/brains/peer/shared.md" internal "peer content"
python3 "$T/scripts/km_promote.py" "shared" "$T/src.txt" --replace >/dev/null 2>&1
grep -q 'status: accepted' "$T/brains/peer/shared.md" && ok "B2 peer-brain doc untouched" || no "B2 peer-brain doc untouched"

echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
