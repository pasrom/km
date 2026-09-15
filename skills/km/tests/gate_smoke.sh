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
BASE_LOCAL=$'meta: {profile: smoke}\nauthor_default: RPA\ngate:\n  enabled: true\n  forbidden_terms_file: .gate-terms.txt\n  email_allowlist: [example.org]\n'
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

# B2: promoting a slug that also exists in a peer brain creates in the parent, never touches the peer
acc "$T/brains/peer/shared.md" internal "peer content"
python3 "$T/scripts/km_promote.py" "shared" "$T/src.txt" --folder bms --type note --author X >/dev/null 2>&1
grep -q 'status: accepted' "$T/brains/peer/shared.md" && ok "B2 peer-brain doc untouched" || no "B2 peer-brain doc untouched"

# P1: a source WITH frontmatter keeps its type, re-stamps the lifecycle, and does not double the header
printf -- '---\ntype: decision\ntitle: Src Title\ntimestamp: 2026-08-26\nauthor: Y\nstatus: draft\ntags: [t]\n---\ndecision body\n' > "$T/srcfm.md"
python3 "$T/scripts/km_promote.py" "promoted-dec" "$T/srcfm.md" --folder bms >/dev/null 2>&1
PF="$T/bms/promoted-dec.md"
{ grep -q '^type: decision' "$PF" && [ "$(grep -c '^---$' "$PF")" = "2" ] && grep -q '^status: review' "$PF"; } \
  && ok "promote carries source type + no double header" || no "promote carries source type + no double header"

# P2: a new doc without --folder is refused (no silent 'topics' default)
python3 "$T/scripts/km_promote.py" "no-folder" "$T/srcfm.md" >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/no-folder.md" ]; } && ok "new doc without --folder refused" || no "new doc without --folder refused"

# P3: --replace on a verbatim-block is refused (change only via supersede)
printf -- '---\ntype: verbatim-block\ntitle: VB\ntimestamp: 2026-08-26\nauthor: X\nstatus: accepted\nlanguage: en\nowner: X\naudience: internal\ntags: [t]\n---\nquote\n' > "$T/bms/vb.md"
python3 "$T/scripts/km_promote.py" "vb" "$T/srcfm.md" --folder bms --replace >/dev/null 2>&1
{ [ $? -eq 2 ] && grep -q '^status: accepted' "$T/bms/vb.md"; } && ok "verbatim-block replace refused" || no "verbatim-block replace refused"

# P4: author falls back to author_default (schema.local) when neither flag nor source provides one
printf 'plain body, no frontmatter\n' > "$T/plain.txt"
python3 "$T/scripts/km_promote.py" "def-author" "$T/plain.txt" --folder bms --type note >/dev/null 2>&1
grep -q '^author: RPA' "$T/bms/def-author.md" && ok "author_default fills a sourceless author" || no "author_default fills a sourceless author"

# P5: --stub-source leaves a VALID superseded redirect stub (gated), no duplicate
mkdir -p "$T/inbox"
printf -- '---\ntype: note\ntitle: Scratch\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nfull body\n' > "$T/inbox/scratch.md"
python3 "$T/scripts/km_promote.py" "moved-topic" "$T/inbox/scratch.md" --folder bms --stub-source >/dev/null 2>&1
python3 "$T/scripts/validate.py" "$T/inbox/scratch.md" >/dev/null 2>&1; stubrc=$?
{ [ -f "$T/bms/moved-topic.md" ] && grep -q '^status: superseded' "$T/inbox/scratch.md" && grep -q 'superseded_by: bms/moved-topic.md' "$T/inbox/scratch.md" && [ "$stubrc" = "0" ]; } \
  && ok "--stub-source: valid redirect stub, no duplicate" || no "--stub-source: valid redirect stub, no duplicate"

# P6: a verbatim-block source yields a schema-VALID stub (language/owner survive; the stub is gated)
printf -- '---\ntype: verbatim-block\ntitle: VBSrc\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\nlanguage: en\nowner: X\ntags: [t]\n---\nquote body\n' > "$T/inbox/vbsrc.md"
python3 "$T/scripts/km_promote.py" "vb-moved" "$T/inbox/vbsrc.md" --folder bms --stub-source >/dev/null 2>&1
python3 "$T/scripts/validate.py" "$T/inbox/vbsrc.md" >/dev/null 2>&1; vbrc=$?
{ [ -f "$T/bms/vb-moved.md" ] && grep -q '^status: superseded' "$T/inbox/vbsrc.md" && grep -q '^language: en' "$T/inbox/vbsrc.md" && [ "$vbrc" = "0" ]; } \
  && ok "verbatim-block stub keeps type_rules fields + validates" || no "verbatim-block stub keeps type_rules fields + validates"

# P7: a source whose basename equals the slug is NOT mistaken for the existing served doc
printf -- '---\ntype: note\ntitle: Foo\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nfoo body\n' > "$T/inbox/foo.md"
python3 "$T/scripts/km_promote.py" "foo" "$T/inbox/foo.md" --folder bms >/dev/null 2>&1
[ -f "$T/bms/foo.md" ] && ok "source basename == slug promotes (no self-dedup)" || no "source basename == slug promotes (no self-dedup)"

# P8: an exempt source (README.md) is promoted but NOT turned into a stub
printf 'clean readme body\n' > "$T/inbox/README.md"
python3 "$T/scripts/km_promote.py" "readme-x" "$T/inbox/README.md" --folder bms --type note --author X --stub-source >/dev/null 2>&1
{ [ -f "$T/bms/readme-x.md" ] && grep -q 'clean readme body' "$T/inbox/README.md" && ! grep -q '^status: superseded' "$T/inbox/README.md"; } \
  && ok "exempt source not turned into a stub" || no "exempt source not turned into a stub"

# P9: a non-string author_default is ignored (refuse, not author: [..])
printf 'meta: {profile: smoke}\nauthor_default: [A, B]\ngate: {enabled: true}\n' > "$T/schema.local.yaml"
printf 'plain body\n' > "$T/plain2.txt"
python3 "$T/scripts/km_promote.py" "nd-author" "$T/plain2.txt" --folder bms --type note >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/nd-author.md" ]; } && ok "non-string author_default refused" || no "non-string author_default refused"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# X1: cross-repo promote (source OUTSIDE the repo) requires --author (no silent author_default)
XSRC="$(mktemp -d)"
printf -- '---\ntype: note\ntitle: X\ntimestamp: 2026-08-26\nstatus: draft\ntags: [t]\nrelated: [foo.md]\nproject: p\n---\nplain body\n' > "$XSRC/x.md"
python3 "$T/scripts/km_promote.py" "xr-noauth" "$XSRC/x.md" --folder bms >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-noauth.md" ]; } && ok "cross-repo without --author refused" || no "cross-repo without --author refused"

# X2: cross-repo with --author strips source-repo refs (related/project) and sets --ticket
python3 "$T/scripts/km_promote.py" "xr-ok" "$XSRC/x.md" --folder bms --author MSO --ticket ABC-9 >/dev/null 2>&1
XF="$T/bms/xr-ok.md"
{ [ -f "$XF" ] && grep -q '^author: MSO' "$XF" && grep -q '^ticket: ABC-9' "$XF" && ! grep -q '^related:' "$XF" && ! grep -q '^project:' "$XF"; } \
  && ok "cross-repo strips refs + sets author/ticket" || no "cross-repo strips refs + sets author/ticket"

# X3: cross-repo with a body link into the source repo is refused
printf -- '---\ntype: note\ntitle: Y\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nsee [other](../other.md) and [[wiki-x]]\n' > "$XSRC/y.md"
python3 "$T/scripts/km_promote.py" "xr-link" "$XSRC/y.md" --folder bms --author MSO >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-link.md" ]; } && ok "cross-repo body link into source refused" || no "cross-repo body link into source refused"

# X4: a source INSIDE a mounted brain is cross-repo (needs --author), not in-repo
printf -- '---\ntype: note\ntitle: Z\ntimestamp: 2026-08-26\nstatus: draft\ntags: [t]\n---\nz\n' > "$T/brains/peer/z.md"
python3 "$T/scripts/km_promote.py" "xr-sub" "$T/brains/peer/z.md" --folder bms >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-sub.md" ]; } && ok "submodule source treated cross-repo (needs --author)" || no "submodule source treated cross-repo (needs --author)"

# X5: a code fence containing [[ is not a link -> not refused
printf -- '---\ntype: note\ntitle: F\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nshell:\n```bash\nif [[ -f x ]]; then echo hi; fi\n```\n' > "$XSRC/f.md"
python3 "$T/scripts/km_promote.py" "xr-fence" "$XSRC/f.md" --folder bms --author MSO >/dev/null 2>&1
[ -f "$T/bms/xr-fence.md" ] && ok "cross-repo: fenced [[ not treated as a link" || no "cross-repo: fenced [[ not treated as a link"

# X6: a body link that RESOLVES in the target is allowed (the one link kind a contributed doc should have)
printf 'x\n' > "$T/bms/exists.md"
printf -- '---\ntype: note\ntitle: L\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nsee [E](bms/exists.md)\n' > "$XSRC/l.md"
python3 "$T/scripts/km_promote.py" "xr-inlink" "$XSRC/l.md" --folder bms --author MSO >/dev/null 2>&1
[ -f "$T/bms/xr-inlink.md" ] && ok "cross-repo: in-target link allowed" || no "cross-repo: in-target link allowed"
rm -rf "$XSRC"

echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
