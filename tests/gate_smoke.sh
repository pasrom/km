#!/usr/bin/env bash
# Smoke test for the opt-in km gate + km promote. Self-contained: builds a throwaway brain from
# the km package and asserts key behaviour (incl. the fixes from PR #3 review).
# Run:  bash tests/gate_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bms" "$T/sub" "$T/brains/peer" "$T/topics"
printf '[submodule "brains/peer"]\n  path = brains/peer\n  url = x\n' > "$T/.gitmodules"
printf 'PROJECT-BLUEBIRD\nACME_CORP\n' > "$T/.gate-terms.txt"
BASE_LOCAL=$'meta: {profile: smoke}\nauthor_default: RPA\ngate:\n  enabled: true\n  forbidden_terms_file: .gate-terms.txt\n  email_allowlist: [example.org]\n'
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

V(){ km validate --root "$T" "$@" >/dev/null 2>&1; }
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
km validate --root "$T" "$T/bms/a.md" 2>&1 | grep -q "unknown gate key" && ok "F5 unknown key fails fast" || no "F5 unknown key fails fast"

# F1: a configured-but-missing forbidden_terms_file is a WARNING, not silent
printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n  forbidden_terms_file: nope.txt\n' > "$T/schema.local.yaml"
km validate --root "$T" "$T/bms/a.md" 2>&1 | grep -q "configured but not found" && ok "F1 missing terms file warns" || no "F1 missing terms file warns"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# B1: an escaping slug is refused, nothing written outside the repo
printf 'body\n' > "$T/src.txt"
km promote --root "$T" "../../../../tmp/km-escape" "$T/src.txt" >/dev/null 2>&1
[ $? -eq 2 ] && [ ! -f /tmp/km-escape.md ] && ok "B1 slug escape refused" || no "B1 slug escape refused"

# B2: promoting a slug that also exists in a peer brain creates in the parent, never touches the peer
acc "$T/brains/peer/shared.md" internal "peer content"
km promote --root "$T" "shared" "$T/src.txt" --folder bms --type note --author X >/dev/null 2>&1
grep -q 'status: accepted' "$T/brains/peer/shared.md" && ok "B2 peer-brain doc untouched" || no "B2 peer-brain doc untouched"

# P1: a source WITH frontmatter keeps its type, re-stamps the lifecycle, and does not double the header
printf -- '---\ntype: decision\ntitle: Src Title\ntimestamp: 2026-08-26\nauthor: Y\nstatus: draft\ntags: [t]\n---\ndecision body\n' > "$T/srcfm.md"
# a source whose frontmatter does not parse (an impossible date, a YAML error) is refused, not a crash
for bad in 'timestamp: 2026-02-30' 'title: [unclosed'; do
  printf -- '---\ntype: note\n%s\n---\nbody\n' "$bad" > "$T/badfm.md"
  out="$(km promote --root "$T" "bad-fm" "$T/badfm.md" --folder bms 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && grep -q "REFUSED .*frontmatter of .*badfm.md does not parse" <<< "$out" && ! grep -q Traceback <<< "$out" \
    && [ ! -e "$T/bms/bad-fm.md" ]; } && ok "promote refuses a source whose frontmatter does not parse (${bad%%:*})" \
    || no "promote bad frontmatter ${bad%%:*} (rc=$rc: $out)"
done
rm -f "$T/badfm.md"
out="$(printf -- '---\ntype: note\ntitle: [unclosed\n---\nb\n' > "$T/badfm.md"; km promote --root "$T" bad-fm "$T/badfm.md" --folder bms 2>&1)"
grep -q "does not parse: while parsing a flow sequence (line 3, column [0-9]*).*(line [0-9]*, column" <<< "$out" \
  && ok "the refusal names the YAML problem, where it opened and where it failed, in file lines" || no "yaml mark ($out)"
# an existing doc in the brain with a broken date: --replace refuses and blames that doc, not the note
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-02-30\nauthor: X\nstatus: accepted\ntags: [t]\n---\nold\n' > "$T/bms/brokentarget.md"
printf -- 'new body\n' > "$T/newnote.txt"
out="$(km promote --root "$T" brokentarget "$T/newnote.txt" --replace 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && grep -q "frontmatter of bms/brokentarget.md does not parse.*doc in the brain is broken" <<< "$out" \
  && grep -q '^old$' "$T/bms/brokentarget.md"; } && ok "promote --replace refuses a broken target and names it" || no "broken target (rc=$rc: $out)"
rm -f "$T/bms/brokentarget.md" "$T/newnote.txt"
# km promote stub on a note with a broken date: its own prefix and exit code
printf -- '---\ntype: note\ntimestamp: 2026-02-30\n---\nb\n' > "$T/badfm.md"
out="$(cd "$T" && km promote stub badfm.md --to bms/x.md 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && grep -q "^stub: the frontmatter of badfm.md does not parse" <<< "$out" && ! grep -q Traceback <<< "$out"; } \
  && ok "promote stub refuses a broken note with its own prefix and exit 1" || no "stub broken (rc=$rc: $out)"
rm -f "$T/badfm.md"
# fences the old reader accepted: an empty block, trailing spaces on the fences
printf -- '---\n---\nempty fm body\n' > "$T/emptyfm.md"
km promote --root "$T" empty-fm "$T/emptyfm.md" --folder bms --type note --author X >/dev/null 2>&1
{ [ "$(grep -c '^---$' "$T/bms/empty-fm.md")" = 2 ] && grep -q '^empty fm body$' "$T/bms/empty-fm.md"; } \
  && ok "promote takes an empty frontmatter block as none, no stray fences" || no "empty block ($(cat "$T/bms/empty-fm.md" 2>&1))"
printf -- '--- \ntype: decision\ntitle: Spaced\nauthor: Y\n--- \nspaced body\n' > "$T/spaced.md"
km promote --root "$T" spaced-fm "$T/spaced.md" --folder bms >/dev/null 2>&1
{ grep -q '^type: decision' "$T/bms/spaced-fm.md" && ! grep -q 'title: Spaced' <(tail -n +2 "$T/bms/spaced-fm.md" | sed '1,/^---$/d'); } \
  && ok "promote reads fences with trailing spaces" || no "spaced fences ($(cat "$T/bms/spaced-fm.md" 2>&1))"
# a list block, a non-UTF-8 note and a missing note are refused, not a traceback
printf -- '---\n- a\n---\nb\n' > "$T/listfm.md"; printf '\377\376 latin\n' > "$T/latin.md"
for f in listfm.md latin.md nosuch.md; do
  out="$(km promote --root "$T" "x-${f%.md}" "$T/$f" --folder bms --type note --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && grep -q REFUSED <<< "$out" && ! grep -q Traceback <<< "$out" && [ ! -e "$T/bms/x-${f%.md}.md" ]; } \
    && ok "promote refuses $f cleanly" || no "refuse $f (rc=$rc: $out)"
done
rm -f "$T/emptyfm.md" "$T/spaced.md" "$T/listfm.md" "$T/latin.md"
# a note saved on Windows (byte order mark, CRLF) keeps its frontmatter: no doubled header
printf '\357\273\277---\r\ntype: decision\r\ntitle: Win\r\ntimestamp: 2026-08-26\r\nauthor: Y\r\nstatus: draft\r\ntags: [t]\r\n---\r\nwin body\r\n' > "$T/win.md"
km promote --root "$T" win-note "$T/win.md" --folder bms >/dev/null 2>&1
{ grep -q '^type: decision' "$T/bms/win-note.md" && [ "$(grep -c '^---$' "$T/bms/win-note.md")" = 2 ] && ! grep -q 'title: Win' <(sed -n '/^---$/,/^---$/!p' "$T/bms/win-note.md" | tail -n +2); } \
  && ok "promote reads a note with a BOM and CRLF like any other" || no "bom crlf ($(cat "$T/bms/win-note.md"))"
km promote --root "$T" "promoted-dec" "$T/srcfm.md" --folder bms >/dev/null 2>&1
PF="$T/bms/promoted-dec.md"
{ grep -q '^type: decision' "$PF" && [ "$(grep -c '^---$' "$PF")" = "2" ] && grep -q '^status: review' "$PF"; } \
  && ok "promote carries source type + no double header" || no "promote carries source type + no double header"

# P2: a new doc without --folder is refused (no silent 'topics' default)
km promote --root "$T" "no-folder" "$T/srcfm.md" >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/no-folder.md" ]; } && ok "new doc without --folder refused" || no "new doc without --folder refused"

# P3: --replace on a verbatim-block is refused (change only via supersede)
printf -- '---\ntype: verbatim-block\ntitle: VB\ntimestamp: 2026-08-26\nauthor: X\nstatus: accepted\nlanguage: en\nowner: X\naudience: internal\ntags: [t]\n---\nquote\n' > "$T/bms/vb.md"
km promote --root "$T" "vb" "$T/srcfm.md" --folder bms --replace >/dev/null 2>&1
{ [ $? -eq 2 ] && grep -q '^status: accepted' "$T/bms/vb.md"; } && ok "verbatim-block replace refused" || no "verbatim-block replace refused"

# P4: author falls back to author_default (schema.local) when neither flag nor source provides one
printf 'plain body, no frontmatter\n' > "$T/plain.txt"
km promote --root "$T" "def-author" "$T/plain.txt" --folder bms --type note >/dev/null 2>&1
grep -q '^author: RPA' "$T/bms/def-author.md" && ok "author_default fills a sourceless author" || no "author_default fills a sourceless author"

# P5: --stub-source leaves a VALID superseded redirect stub (gated), no duplicate
mkdir -p "$T/inbox"
printf -- '---\ntype: note\ntitle: Scratch\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nfull body\n' > "$T/inbox/scratch.md"
km promote --root "$T" "moved-topic" "$T/inbox/scratch.md" --folder bms --stub-source >/dev/null 2>&1
km validate --root "$T" "$T/inbox/scratch.md" >/dev/null 2>&1; stubrc=$?
{ [ -f "$T/bms/moved-topic.md" ] && grep -q '^status: superseded' "$T/inbox/scratch.md" && grep -q 'superseded_by: bms/moved-topic.md' "$T/inbox/scratch.md" && [ "$stubrc" = "0" ]; } \
  && ok "--stub-source: valid redirect stub, no duplicate" || no "--stub-source: valid redirect stub, no duplicate"

# P6: a verbatim-block source yields a schema-VALID stub (language/owner survive; the stub is gated)
printf -- '---\ntype: verbatim-block\ntitle: VBSrc\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\nlanguage: en\nowner: X\ntags: [t]\n---\nquote body\n' > "$T/inbox/vbsrc.md"
km promote --root "$T" "vb-moved" "$T/inbox/vbsrc.md" --folder bms --stub-source >/dev/null 2>&1
km validate --root "$T" "$T/inbox/vbsrc.md" >/dev/null 2>&1; vbrc=$?
{ [ -f "$T/bms/vb-moved.md" ] && grep -q '^status: superseded' "$T/inbox/vbsrc.md" && grep -q '^language: en' "$T/inbox/vbsrc.md" && [ "$vbrc" = "0" ]; } \
  && ok "verbatim-block stub keeps type_rules fields + validates" || no "verbatim-block stub keeps type_rules fields + validates"

# P7: a source whose basename equals the slug is NOT mistaken for the existing served doc
printf -- '---\ntype: note\ntitle: Foo\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nfoo body\n' > "$T/inbox/foo.md"
km promote --root "$T" "foo" "$T/inbox/foo.md" --folder bms >/dev/null 2>&1
[ -f "$T/bms/foo.md" ] && ok "source basename == slug promotes (no self-dedup)" || no "source basename == slug promotes (no self-dedup)"

# P8: an exempt source (README.md) is promoted but NOT turned into a stub
printf 'clean readme body\n' > "$T/inbox/README.md"
km promote --root "$T" "readme-x" "$T/inbox/README.md" --folder bms --type note --author X --stub-source >/dev/null 2>&1
{ [ -f "$T/bms/readme-x.md" ] && grep -q 'clean readme body' "$T/inbox/README.md" && ! grep -q '^status: superseded' "$T/inbox/README.md"; } \
  && ok "exempt source not turned into a stub" || no "exempt source not turned into a stub"

# P9: a non-string author_default is ignored (refuse, not author: [..])
printf 'meta: {profile: smoke}\nauthor_default: [A, B]\ngate: {enabled: true}\n' > "$T/schema.local.yaml"
printf 'plain body\n' > "$T/plain2.txt"
km promote --root "$T" "nd-author" "$T/plain2.txt" --folder bms --type note >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/nd-author.md" ]; } && ok "non-string author_default refused" || no "non-string author_default refused"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# X1: cross-repo promote (source OUTSIDE the repo) requires --author (no silent author_default)
XSRC="$(mktemp -d)"
printf -- '---\ntype: note\ntitle: X\ntimestamp: 2026-08-26\nstatus: draft\ntags: [t]\nrelated: [foo.md]\nproject: p\n---\nplain body\n' > "$XSRC/x.md"
km promote --root "$T" "xr-noauth" "$XSRC/x.md" --folder bms >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-noauth.md" ]; } && ok "cross-repo without --author refused" || no "cross-repo without --author refused"

# X2: cross-repo with --author strips source-repo refs (related/project) and sets --ticket
km promote --root "$T" "xr-ok" "$XSRC/x.md" --folder bms --author MSO --ticket ABC-9 >/dev/null 2>&1
XF="$T/bms/xr-ok.md"
{ [ -f "$XF" ] && grep -q '^author: MSO' "$XF" && grep -q '^ticket: ABC-9' "$XF" && ! grep -q '^related:' "$XF" && ! grep -q '^project:' "$XF"; } \
  && ok "cross-repo strips refs + sets author/ticket" || no "cross-repo strips refs + sets author/ticket"

# X3: cross-repo with a body link into the source repo is refused
printf -- '---\ntype: note\ntitle: Y\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nsee [other](../other.md) and [[wiki-x]]\n' > "$XSRC/y.md"
km promote --root "$T" "xr-link" "$XSRC/y.md" --folder bms --author MSO >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-link.md" ]; } && ok "cross-repo body link into source refused" || no "cross-repo body link into source refused"

# X4: a source INSIDE a mounted brain is cross-repo (needs --author), not in-repo
printf -- '---\ntype: note\ntitle: Z\ntimestamp: 2026-08-26\nstatus: draft\ntags: [t]\n---\nz\n' > "$T/brains/peer/z.md"
km promote --root "$T" "xr-sub" "$T/brains/peer/z.md" --folder bms >/dev/null 2>&1
{ [ $? -eq 2 ] && [ ! -f "$T/bms/xr-sub.md" ]; } && ok "submodule source treated cross-repo (needs --author)" || no "submodule source treated cross-repo (needs --author)"

# X5: a code fence containing [[ is not a link -> not refused
printf -- '---\ntype: note\ntitle: F\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nshell:\n```bash\nif [[ -f x ]]; then echo hi; fi\n```\n' > "$XSRC/f.md"
km promote --root "$T" "xr-fence" "$XSRC/f.md" --folder bms --author MSO >/dev/null 2>&1
[ -f "$T/bms/xr-fence.md" ] && ok "cross-repo: fenced [[ not treated as a link" || no "cross-repo: fenced [[ not treated as a link"

# X6: a body link that RESOLVES in the target is allowed (the one link kind a contributed doc should have)
printf 'x\n' > "$T/bms/exists.md"
printf -- '---\ntype: note\ntitle: L\ntimestamp: 2026-08-26\nauthor: MSO\nstatus: draft\ntags: [t]\n---\nsee [E](bms/exists.md)\n' > "$XSRC/l.md"
km promote --root "$T" "xr-inlink" "$XSRC/l.md" --folder bms --author MSO >/dev/null 2>&1
[ -f "$T/bms/xr-inlink.md" ] && ok "cross-repo: in-target link allowed" || no "cross-repo: in-target link allowed"
rm -rf "$XSRC"

# Pending-contribution marker: never carried by a promote; `stub` drops it; validate flags a leftover
printf -- '---\ntype: note\ntitle: Pending\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\ncontribution: "org/team-brain#7"\n---\nfull body\n' > "$T/inbox/pending.md"
km promote --root "$T" "pending-topic" "$T/inbox/pending.md" --folder bms >/dev/null 2>&1
{ [ -f "$T/bms/pending-topic.md" ] && ! grep -q '^contribution:' "$T/bms/pending-topic.md"; } \
  && ok "promote never carries a contribution marker" || no "promote never carries a contribution marker"
km promote --root "$T" stub "$T/inbox/pending.md" --to bms/pending-topic.md >/dev/null 2>&1; strc=$?
{ [ "$strc" = 0 ] && grep -q '^status: superseded' "$T/inbox/pending.md" && grep -q '^superseded_by: bms/pending-topic.md' "$T/inbox/pending.md" \
  && ! grep -q '^contribution:' "$T/inbox/pending.md"; } && ok "stub: gated redirect stub, marker dropped" || no "stub: gated redirect stub, marker dropped (rc=$strc)"
km promote --root "$T" stub "$T/inbox/missing.md" --to bms/x.md >/dev/null 2>&1 && no "stub: a missing source fails" || ok "stub: a missing source fails"
printf -- '---\ntype: note\ntitle: Left\ntimestamp: 2026-08-26\nauthor: X\nstatus: superseded\nsuperseded_by: bms/pending-topic.md\ntags: [t]\ncontribution: "org/team-brain#7"\n---\nx\n' > "$T/inbox/left.md"
km validate --root "$T" "$T/inbox/left.md" 2>&1 | grep -q "superseded should not set 'contribution'" \
  && ok "validate warns on a superseded doc still carrying the marker" || no "validate warns on a superseded doc still carrying the marker"

# Term scope: term_scan_prefixes scans a folder's docs whatever their audience; others stay as before
gate(){ printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n%b' "$1" > "$T/schema.local.yaml"; }
errs(){ km validate --root "$T" "$@" 2>&1; }
gate '  forbidden_terms_file: .gate-terms.txt\n  term_scan_prefixes: [bms]\n'
mkdir -p "$T/bmsx"
acc "$T/bms/ts1.md" internal "Kunde PROJECT-BLUEBIRD intern"
V "$T/bms/ts1.md" && no "term_scan_prefixes: internal doc in a scanned folder blocked" || ok "term_scan_prefixes: internal doc in a scanned folder blocked"
acc "$T/topics/ts2.md" internal "Kunde PROJECT-BLUEBIRD intern"
V "$T/topics/ts2.md" && ok "term_scan_prefixes: an unscanned folder still passes" || no "term_scan_prefixes: an unscanned folder still passes"
acc "$T/bmsx/ts3.md" internal "Kunde PROJECT-BLUEBIRD intern"
V "$T/bmsx/ts3.md" && ok "term_scan_prefixes: 'bms' does not match 'bmsx/'" || no "term_scan_prefixes: 'bms' does not match 'bmsx/'"
printf '# bms\nKunde PROJECT-BLUEBIRD\n' > "$T/bms/README.md"
V "$T/bms/README.md" && no "term_scan_prefixes: an exempt file in the folder is scanned too" || ok "term_scan_prefixes: an exempt file in the folder is scanned too"
acc "$T/bms/ts4.md" customer "Kunde PROJECT-BLUEBIRD extern"
[ "$(errs "$T/bms/ts4.md" | grep -c 'forbidden term')" = 1 ] && ok "term_scan_prefixes: a customer doc there is reported once" || no "term_scan_prefixes: a customer doc there is reported once"
rm -f "$T/bms/README.md"

# Project codes: tracked subfolder names under project_prefix must not appear outside their folder
git -C "$T" init -q
mkdir -p "$T/projects/acme01" "$T/projects/zeta02" "$T/projects/cra" "$T/projects/ghost09"
acc "$T/projects/acme01/pc2.md" internal "acme01 status note"
acc "$T/projects/zeta02/pc3.md" internal "same fault as acme01"
acc "$T/projects/cra/pc6.md" internal "cra reading notes"
printf -- '---\ndescription: projects\n---\n# projects\n\n## Documents\n\n- [acme01](acme01/_index.md)\n' > "$T/projects/_index.md"
git -C "$T" add projects                     # ghost09 has no tracked file: not a code
gate '  project_prefix: projects/\n'
acc "$T/bms/pc1.md" internal "found on the ACME01 bench"
V "$T/bms/pc1.md" && no "project_prefix: a code in a neutral doc blocked" || ok "project_prefix: a code in a neutral doc blocked"
V "$T/projects/acme01/pc2.md" && ok "project_prefix: a code in its own folder passes" || no "project_prefix: a code in its own folder passes"
V "$T/projects/zeta02/pc3.md" && no "project_prefix: another project's code blocked" || ok "project_prefix: another project's code blocked"
V "$T/projects/_index.md" && ok "project_prefix: the hub index listing every code passes" || no "project_prefix: the hub index listing every code passes"
printf -- '---\ndescription: b\n---\n# bms\nsee acme01\n' > "$T/bms/_index.md"
V "$T/bms/_index.md" && no "project_prefix: a code in another folder's _index.md blocked" || ok "project_prefix: a code in another folder's _index.md blocked"
rm -f "$T/bms/_index.md"
acc "$T/bms/pc7.md" internal "see [log](ACME01_bench_log.md)"
V "$T/bms/pc7.md" && no "project_prefix: a code joined by '_' in a file name blocked" || ok "project_prefix: a code joined by '_' in a file name blocked"
acc "$T/bms/pc8.md" internal "run log_acme01 again"
V "$T/bms/pc8.md" && no "project_prefix: a code after '_' blocked" || ok "project_prefix: a code after '_' blocked"
printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: review\naudience: internal\ntags: [t]\nrelated: [projects/acme01/pc2.md]\n---\nneutral body\n' > "$T/bms/pc9.md"
V "$T/bms/pc9.md" && no "project_prefix: a related: path into a project folder counts" || ok "project_prefix: a related: path into a project folder counts"
acc "$T/bms/pc4.md" internal "part acme012 and xacme01 and ghost09 are not codes"
V "$T/bms/pc4.md" && ok "project_prefix: whole tracked codes only" || no "project_prefix: whole tracked codes only"
errs "$T/bms/pc1.md" | grep -q "acme01" && no "project_prefix: the code is redacted in the report" || ok "project_prefix: the code is redacted in the report"
acc "$T/bms/pc5.md" internal "relevant under the CRA"
V "$T/bms/pc5.md" && no "project_prefix: without a pattern every subfolder is a code" || ok "project_prefix: without a pattern every subfolder is a code"
gate '  project_prefix: projects/\n  project_code_pattern: "[a-z]+[0-9]+"\n'
V "$T/bms/pc5.md" && ok "project_code_pattern: a topic folder is not a code" || no "project_code_pattern: a topic folder is not a code"
V "$T/bms/pc1.md" && no "project_code_pattern: a matching code is still blocked" || ok "project_code_pattern: a matching code is still blocked"
gate '  project_prefix: projects/\n  project_code_pattern: "[a-z+"\n'
errs "$T/bms/pc1.md" | grep -q "project_code_pattern is not a valid regex" && ok "project_code_pattern: a bad regex fails fast" || no "project_code_pattern: a bad regex fails fast"
gate '  project_prefix: [projects]\n'
errs "$T/bms/pc1.md" | grep -q "gate.project_prefix must be a string" && ok "project_prefix: a non-string fails fast" || no "project_prefix: a non-string fails fast"
gate '  term_scan_prefixes: bms\n'
errs "$T/bms/pc1.md" | grep -q "gate.term_scan_prefixes must be a list" && ok "term_scan_prefixes: a non-list fails fast" || no "term_scan_prefixes: a non-list fails fast"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"
rm -rf "$T/projects" "$T/bmsx" "$T/topics/ts2.md" "$T/.git"

# AI approval: an ai: approver needs approval: ai; customer docs and verbatim-blocks need a human
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"
mkdir -p "$T/ap"
doc(){ # doc FILE STATUS "extra frontmatter lines"; TYPE=, AUD= override, AUD= / RB= / OWN= (empty) drop the field
  local rb="${RB-2027-01-01}" aud="${AUD-internal}" own="${OWN-X}"
  printf -- '---\ntype: %s\ntitle: t\ntimestamp: 2026-09-30\nauthor: X\nstatus: %s\n%blanguage: en\ntags: [t]\n%b%b%b---\nbody\n' \
    "${TYPE:-concept}" "$2" "${aud:+audience: $aud\n}" "${own:+owner: $own\n}" "${rb:+review_by: $rb\n}" "${3:-}" > "$1"; }
doc "$T/ap/a1.md" accepted 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/a1.md" && no "approval: an ai: approver without approval: ai fails" || ok "approval: an ai: approver without approval: ai fails"
doc "$T/ap/a2.md" accepted 'approval: ai\napproved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/a2.md" && ok "approval: ai lets an ai: approver sign off" || no "approval: ai lets an ai: approver sign off"
AUD=customer doc "$T/ap/a3.md" accepted 'approval: ai\napproved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/a3.md" && no "approval: a customer doc never takes an ai: approver" || ok "approval: a customer doc never takes an ai: approver"
AUD=customer doc "$T/ap/a4.md" review 'approval: ai\n'
V "$T/ap/a4.md" && no "approval: 'approval: ai' on a customer doc is an error" || ok "approval: 'approval: ai' on a customer doc is an error"
TYPE=verbatim-block doc "$T/ap/a5.md" review 'approval: ai\n'
V "$T/ap/a5.md" && no "approval: 'approval: ai' on a verbatim-block is an error" || ok "approval: 'approval: ai' on a verbatim-block is an error"
doc "$T/ap/a6.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
V "$T/ap/a6.md" && ok "approval: a human approver passes at the default level" || no "approval: a human approver passes at the default level"
doc "$T/ap/a7.md" review 'approval: maybe\n'
V "$T/ap/a7.md" && no "approval: an unknown level fails the enum" || ok "approval: an unknown level fails the enum"
AUD= doc "$T/ap/a10.md" accepted 'approval: ai\napproved_by: "RPA"\napproved_at: 2026-09-30\n'
V "$T/ap/a10.md" && ok "approval: a doc without an audience counts as internal" || no "approval: a doc without an audience counts as internal"
AUD= doc "$T/ap/a11.md" accepted 'approval: ai\napproved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
km validate --root "$T" "$T/ap/a11.md" 2>&1 | grep -q "needs 'audience: internal' set explicitly" \
  && ok "approval: an AI approver needs the audience spelled out" || no "approval: an AI approver needs the audience spelled out"
AUD=customer doc "$T/ap/a12.md" accepted 'approved_by: ["ai:model-x"]\napproved_at: 2026-09-30\n'
V "$T/ap/a12.md" && no "approval: an AI approver in a list is still an AI approver" || ok "approval: an AI approver in a list is still an AI approver"
AUD=customer doc "$T/ap/a13.md" accepted 'approved_by: [RPA, "ai:model-x"]\napproved_at: 2026-09-30\n'
V "$T/ap/a13.md" && ok "approval: a person co-signing with an AI is a human sign-off" || no "approval: a person co-signing with an AI is a human sign-off"
# approval_default: ai puts internal docs at level ai; customer docs, verbatim-blocks and an explicit human stay human
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'approval_default: ai\n' >> "$T/schema.local.yaml"
V "$T/ap/a1.md" && ok "approval_default: ai lets an internal doc take an ai: approver" || no "approval_default: ai lets an internal doc take an ai: approver"
AUD=customer doc "$T/ap/d1.md" accepted 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/d1.md" && no "approval_default: a customer doc still needs a human" || ok "approval_default: a customer doc still needs a human"
TYPE=verbatim-block doc "$T/ap/d2.md" accepted 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/d2.md" && no "approval_default: a verbatim-block still needs a human" || ok "approval_default: a verbatim-block still needs a human"
doc "$T/ap/d3.md" accepted 'approval: human\napproved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/d3.md" && no "approval_default: 'approval: human' overrides it" || ok "approval_default: 'approval: human' overrides it"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'approval_default: ai\nfields:\n  audience:\n    enum: [internal, customer, partner]\n' >> "$T/schema.local.yaml"
AUD=partner doc "$T/ap/d5.md" accepted 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
V "$T/ap/d5.md" && no "approval_default: any audience other than internal needs a human" || ok "approval_default: any audience other than internal needs a human"
AUD=partner doc "$T/ap/d6.md" review 'approval: ai\n'
V "$T/ap/d6.md" && no "approval: 'approval: ai' on another audience is an error" || ok "approval: 'approval: ai' on another audience is an error"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'approval_default: ai\n' >> "$T/schema.local.yaml"
doc "$T/ap/d4.md" review ''
km approve --root "$T" "$T/ap/d4.md" --by ai:model-x --at 2026-09-30 >/dev/null 2>&1 && grep -q '^status: accepted$' "$T/ap/d4.md" \
  && ok "approve: approval_default: ai signs an internal doc off by ai:" || no "approve: approval_default: ai signs an internal doc off by ai:"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'approval_default: maybe\n' >> "$T/schema.local.yaml"
km validate --root "$T" "$T/ap/a6.md" 2>&1 | grep -q "approval_default must be ai or human" && ok "approval_default: an unknown value fails fast" || no "approval_default: an unknown value fails fast"
out="$(km validate --root "$T" --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "usage: km validate" && ! out_has "approval_default"; } \
  && ok "approval_default: an unknown value still lets validate --help answer" || no "validate --help with a bad approval_default ($rc: $out)"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  accepted_requires: [review_by]\n' >> "$T/schema.local.yaml"
RB= doc "$T/ap/a8.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
V "$T/ap/a8.md" && no "accepted_requires: a missing field fails" || ok "accepted_requires: a missing field fails"
V "$T/ap/a6.md" && ok "accepted_requires: a doc with the field passes" || no "accepted_requires: a doc with the field passes"
printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n  served_status: published\nfields:\n  status:\n    enum: [draft, review, published, superseded, obsolete]\n' > "$T/schema.local.yaml"
doc "$T/ap/a9.md" published 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
km validate --root "$T" "$T/ap/a9.md" 2>&1 | grep -q "an AI approver needs 'approval: ai'" && ok "approval: the rule follows a renamed served status" || no "approval: the rule follows a renamed served status"
doc "$T/ap/rpub.md" published 'approved_by: RPA\napproved_at: 2026-09-30\n'
mkdir -p "$T/inbox"; printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\n---\nnew text\n' > "$T/inbox/rpub.md"
out="$(km promote --root "$T" rpub "$T/inbox/rpub.md" --replace 2>&1)"
{ grep -q '^status: review' "$T/ap/rpub.md" && grep -q '^new text$' "$T/ap/rpub.md"; } \
  && ok "promote --replace: a doc at a renamed served status is replaced" || no "promote --replace: renamed served status ($out)"
rm -f "$T/ap/rpub.md" "$T/inbox/rpub.md"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  acepted_require: [owner]\n' >> "$T/schema.local.yaml"
km validate --root "$T" "$T/ap/a6.md" 2>&1 | grep -q "must be <status>_<requires|recommends|forbids>" && ok "status_rules: a malformed key fails fast" || no "status_rules: a malformed key fails fast"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  acepted_requires: [owner]\n' >> "$T/schema.local.yaml"
km validate --root "$T" "$T/ap/a6.md" 2>&1 | grep -q "with a status from the schema" && ok "status_rules: a misspelled status fails fast" || no "status_rules: a misspelled status fails fast"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  accepted_requires: [review_by]\n' >> "$T/schema.local.yaml"

# km approve: sets status/approved_by/approved_at, refuses what the rule forbids, restores on a failed gate
doc "$T/ap/p1.md" review 'approval: ai\n'
km approve --root "$T" "$T/ap/p1.md" --by ai:model-x --at 2026-09-30 >/dev/null 2>&1
{ grep -q '^status: accepted$' "$T/ap/p1.md" && grep -q '^approved_by: "ai:model-x"$' "$T/ap/p1.md" && grep -q '^approved_at: 2026-09-30$' "$T/ap/p1.md" && V "$T/ap/p1.md"; } \
  && ok "approve: an ai doc is signed off by ai:" || no "approve: an ai doc is signed off by ai:"
doc "$T/ap/p2.md" review ''; cp "$T/ap/p2.md" "$T/p2.bak"
out="$(km approve --root "$T" "$T/ap/p2.md" --by ai:model-x 2>&1)"
out_has "needs 'approval: ai'" && ! out_has "km validate fails" && cmp -s "$T/ap/p2.md" "$T/p2.bak" \
  && ok "approve: ai: refused before writing at the default level" || no "approve: ai: refused before writing at the default level"
AUD= doc "$T/ap/p5.md" review 'approval: ai\n'; cp "$T/ap/p5.md" "$T/p5.bak"
km approve --root "$T" "$T/ap/p5.md" --by ai:model-x 2>&1 | grep -q "audience: internal" && cmp -s "$T/ap/p5.md" "$T/p5.bak" \
  && ok "approve: ai: refused on a doc without an audience" || no "approve: ai: refused on a doc without an audience"
mkdir -p "$T/vendor"; doc "$T/vendor/x.md" review ''; cp "$T/vendor/x.md" "$T/x.bak"
printf 'skip_prefixes: [vendor/]\n' >> "$T/schema.local.yaml"
out="$(km approve --root "$T" "$T/vendor/x.md" --by RPA 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "skip_prefixes" && cmp -s "$T/vendor/x.md" "$T/x.bak"; } \
  && ok "approve: refuses a doc under skip_prefixes" || no "approve: refuses a doc under skip_prefixes ($rc: $out)"
rbd(){ printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  accepted_requires: [owner, review_by]\n%b' "${1:-}" >> "$T/schema.local.yaml"; }
rbd; rm -rf "$T/vendor"
# an overlay key left empty (every entry under it commented out) keeps km's base value, not None
ovl(){ printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf "$1" >> "$T/schema.local.yaml"; }
ovl 'skip_prefixes:\n  # - vendor/\n'; doc "$T/brains/peer/p.md" review ''; cp "$T/brains/peer/p.md" "$T/peer.bak"
out="$(km approve --root "$T" "$T/brains/peer/p.md" --by RPA 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "skip_prefixes" && cmp -s "$T/brains/peer/p.md" "$T/peer.bak"; } \
  && ok "overlay: an empty skip_prefixes keeps brains/ skipped" || no "overlay: empty skip_prefixes ($rc: $out)"
rm -f "$T/brains/peer/p.md" "$T/peer.bak"
ovl 'exempt_files:\n  # - NOTES.md\n'; printf '# readme\n' > "$T/ap/README.md"
out="$(errs "$T/ap/README.md")"; rc=$?
[ "$rc" = 0 ] && ok "overlay: an empty exempt_files keeps README.md exempt" || no "overlay: empty exempt_files ($rc: $out)"
rm -f "$T/ap/README.md"
for o in 'fields:\n' 'type_rules:\n' 'fields:\n  ticket:\n' 'type_rules:\n  concept:\n' 'type_rules_soft:\n  concept:\n' \
         'fields:\n  status:\n    enum:\n' 'type_rules:\n  concept:\n    require:\n' 'status_rules:\n  accepted_requires:\n'; do
  ovl "$o"; out="$(errs "$T/ap/a6.md")"; rc=$?
  [ "$rc" = 0 ] && ok "overlay: '${o//\\n/ }' validates" || no "overlay: '${o//\\n/ }' ($rc: $out)"
done
ovl 'status_rules:\n  acepted_requires:\n'; out="$(errs "$T/ap/a6.md")"; rc=$?
{ [ "$rc" = 1 ] && out_has "status_rules key(s) acepted_requires"; } \
  && ok "overlay: a mistyped status_rules key fails fast, left empty too" || no "overlay: empty mistyped status_rules key ($rc: $out)"
ovl 'fields:\n  status:\n'; doc "$T/ap/o1.md" bogus ''
out="$(errs "$T/ap/o1.md")"; rc=$?
{ [ "$rc" = 1 ] && ! out_has Traceback; } && ok "overlay: a field left empty keeps its base spec" || no "overlay: empty field spec ($rc: $out)"
rm -f "$T/ap/o1.md"
rbd
AUD=customer doc "$T/ap/p3.md" review ''
km approve --root "$T" "$T/ap/p3.md" --by ai:model-x 2>&1 | grep -q "needs a human approver" \
  && ok "approve: ai: refused on a customer doc" || no "approve: ai: refused on a customer doc"
km approve --root "$T" "$T/ap/p2.md" --by RPA >/dev/null 2>&1 && grep -q '^approved_by: "RPA"$' "$T/ap/p2.md" \
  && ok "approve: a human signs off a default doc" || no "approve: a human signs off a default doc"
doc "$T/ap/p4.md" draft ''
km approve --root "$T" "$T/ap/p4.md" --by RPA 2>&1 | grep -q "only a review or accepted doc" && grep -q '^status: draft$' "$T/ap/p4.md" \
  && ok "approve: a draft is refused" || no "approve: a draft is refused"
OWN= doc "$T/ap/p5.md" review ''; cp "$T/ap/p5.md" "$T/p5.bak"
km approve --root "$T" "$T/ap/p5.md" --by RPA 2>&1 | grep -q "km validate fails" && cmp -s "$T/ap/p5.md" "$T/p5.bak" \
  && ok "approve: a doc failing the gate after the change is restored" || no "approve: a doc failing the gate after the change is restored"
km approve --root "$T" "$T/ap/p2.md" --by RPA --at 30.09.2026 >/dev/null 2>&1; [ $? -eq 2 ] && ok "approve: a bad --at is refused" || no "approve: a bad --at is refused"
RB=2020-01-01 doc "$T/ap/p6.md" review ''
km approve --root "$T" "$T/ap/p6.md" --by RPA --at 2026-09-30 2>&1 | grep -q "review_by 2020-01-01 has passed" && grep -q '^status: review$' "$T/ap/p6.md" \
  && ok "approve: a past review_by is refused" || no "approve: a past review_by is refused"
km approve --root "$T" "$T/ap/p6.md" --by RPA --at 2026-09-30 --review-by 2027-06-30 >/dev/null 2>&1 && grep -q '^review_by: 2027-06-30$' "$T/ap/p6.md" && grep -q '^status: accepted$' "$T/ap/p6.md" \
  && ok "approve: --review-by renews the date" || no "approve: --review-by renews the date"
RB=2026-06-01 doc "$T/ap/p8.md" review ''
km approve --root "$T" "$T/ap/p8.md" --by RPA --at 2026-01-01 2>&1 | grep -q "has passed" && grep -q '^status: review$' "$T/ap/p8.md" \
  && ok "approve: a backdated --at does not get round a past review_by" || no "approve: a backdated --at does not get round a past review_by"
km approve --root "$T" "$T/ap/p8.md" --by RPA --review-by 2020-01-01 >/dev/null 2>&1; [ $? -eq 2 ] && grep -q '^status: review$' "$T/ap/p8.md" \
  && ok "approve: a past --review-by is refused" || no "approve: a past --review-by is refused"
RB=soon doc "$T/ap/p10.md" review ''
km approve --root "$T" "$T/ap/p10.md" --by RPA 2>&1 | grep -q "is not a YYYY-MM-DD date" && grep -q '^status: review$' "$T/ap/p10.md" \
  && ok "approve: an unreadable review_by is refused" || no "approve: an unreadable review_by is refused"
doc "$T/ap/p9.md" review ''; python3 -c "import sys;p=sys.argv[1];b=open(p,'rb').read();open(p,'wb').write(b.replace(b'\n',b'\r\n'))" "$T/ap/p9.md"
km approve --root "$T" "$T/ap/p9.md" --by RPA >/dev/null 2>&1 && grep -q '^status: accepted' "$T/ap/p9.md" \
  && ok "approve: a CRLF doc is approved" || no "approve: a CRLF doc is approved"
printf '\xff\xfe---\n' > "$T/ap/bin.md"; cp "$T/ap/bin.md" "$T/bin.bak"; out="$(km approve --root "$T" "$T/ap/bin.md" --by RPA 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "not UTF-8" && ! out_has "Traceback" && cmp -s "$T/ap/bin.md" "$T/bin.bak"; } \
  && ok "approve: a doc that is not UTF-8 is refused" || no "approve: a doc that is not UTF-8 is refused ($rc: $out)"
rm -f "$T/ap/bin.md" "$T/bin.bak"
OWN= doc "$T/ap/p7.md" review ''; { printf '\357\273\277'; cat "$T/ap/p7.md"; } > "$T/p7.tmp" && mv "$T/p7.tmp" "$T/ap/p7.md"; cp "$T/ap/p7.md" "$T/p7.bak"
km approve --root "$T" "$T/ap/p7.md" --by RPA 2>&1 | grep -q "km validate fails" && cmp -s "$T/ap/p7.md" "$T/p7.bak" \
  && ok "approve: a refused doc keeps its bytes, BOM included" || no "approve: a refused doc keeps its bytes, BOM included"
# docs that link to each other: one call gates them together; a doc that fails takes back the one linking to it
lk(){ doc "$1" review "${3:-}"; printf '[other](%s)\n' "$2" >> "$1"; }
lk "$T/ap/l1.md" l2.md; lk "$T/ap/l2.md" l1.md
km approve --root "$T" "$T/ap/l1.md" --by RPA >/dev/null 2>&1; grep -q '^status: review$' "$T/ap/l1.md" \
  && ok "approve: alone, a doc linking to a review doc is refused" || no "approve: alone, a doc linking to a review doc is refused"
km approve --root "$T" "$T/ap/l1.md" "$T/ap/l2.md" --by RPA >/dev/null 2>&1 && grep -q '^status: accepted$' "$T/ap/l1.md" && grep -q '^status: accepted$' "$T/ap/l2.md" \
  && ok "approve: docs linking to each other are signed off together" || no "approve: docs linking to each other are signed off together"
lk "$T/ap/l3.md" l4.md; OWN= lk "$T/ap/l4.md" l3.md; cp "$T/ap/l3.md" "$T/l3.bak"; cp "$T/ap/l4.md" "$T/l4.bak"
out="$(km approve --root "$T" "$T/ap/l3.md" "$T/ap/l4.md" --by RPA 2>&1)"
out_has "REFUSED ap/l4.md" && out_has "REFUSED ap/l3.md" && cmp -s "$T/ap/l3.md" "$T/l3.bak" && cmp -s "$T/ap/l4.md" "$T/l4.bak" \
  && ok "approve: a doc that fails takes back the one linking to it" || no "approve: a doc that fails takes back the one linking to it"
doc "$T/ap/d1.md" review ''; doc "$T/ap/d2.md" draft ''
out="$(km approve --root "$T" "$T/ap/d1.md" "$T/ap/../ap/d1.md" "$T/ap/d2.md" "$T/ap/d2.md" --by RPA 2>&1)"
[ "$(grep -c 'ap/d1.md accepted' <<< "$out")" = 1 ] && [ "$(grep -c 'REFUSED ap/d2.md' <<< "$out")" = 1 ] && grep -q '^status: accepted$' "$T/ap/d1.md" \
  && ok "approve: a doc named twice is handled once" || no "approve: a doc named twice is handled once"
lk "$T/ap/l5.md" l6.md; lk "$T/ap/l6.md" l5.md; cp "$T/ap/l5.md" "$T/l5.bak"; cp "$T/ap/l6.md" "$T/l6.bak"
KM_ROOT="$T" kmpy -c 'import sys, datetime, km.approve as a, km.edit as e
def stop(*paths): raise KeyboardInterrupt
e.run_gate = stop
try: a.approve(sys.argv[1:], "RPA", datetime.date(2026, 9, 30), None)
except KeyboardInterrupt: pass' "$T/ap/l5.md" "$T/ap/l6.md" >/dev/null 2>&1
cmp -s "$T/ap/l5.md" "$T/l5.bak" && cmp -s "$T/ap/l6.md" "$T/l6.bak" \
  && ok "approve: an interrupted approve leaves every doc unchanged" || no "approve: an interrupted approve leaves every doc unchanged"
out="$(KM_ROOT="$T" kmpy -c 'import sys, datetime, km.approve as a, km.edit as e
calls, gate = [], e.run_gate
def count(*paths): calls.append(len(paths)); return gate(*paths)
e.run_gate = count
a.approve(sys.argv[1:], "RPA", datetime.date(2026, 9, 30), None); print("gate runs:", *calls)' "$T/ap/l5.md" "$T/ap/l6.md" 2>&1)"
out_has "gate runs: 2$" && ok "approve: docs that pass are gated in one validate run" || no "approve: one gate run ($out)"
# the gate's child process runs from the brain: a km package or a yaml.py there must not stand in for km or PyYAML
mkdir -p "$T/km" && printf 'open(%s, "w").write("km")\nraise SystemExit(0)\n' "'$T/shadowed'" > "$T/km/__main__.py" && : > "$T/km/__init__.py"
printf 'open(%s, "w").write("yaml")\nraise SystemExit(0)\n' "'$T/shadowed'" > "$T/yaml.py"
RB=2099-01-01 TYPE=note doc "$T/ap/sh1.md" review ''
out="$(km approve --root "$T" "$T/ap/sh1.md" --by RPA 2>&1)"
{ [ ! -e "$T/shadowed" ] && grep -q '^status: accepted$' "$T/ap/sh1.md"; } \
  && ok "approve: the gate's child process does not run a km package or yaml.py from the brain" || no "gate child shadowed ($(cat "$T/shadowed" 2>/dev/null): $out)"
rm -rf "$T/km" "$T/yaml.py" "$T/shadowed"
# review_by_default: approve and promote set the type's review_by on a doc without one; null = no expiry
read -r D30 D182 D365 <<< "$(kmpy -c 'import datetime as d; t = d.date.today(); print(*(t + d.timedelta(days=n) for n in (30, 182, 365)))')"
rbd
RB= doc "$T/ap/r1.md" review ''; RB= TYPE=note doc "$T/ap/r2.md" review ''
out="$(km approve --root "$T" "$T/ap/r1.md" "$T/ap/r2.md" --by RPA 2>&1)"
{ grep -q "^review_by: $D365$" "$T/ap/r1.md" && grep -q "^review_by: $D182$" "$T/ap/r2.md" && out_has "set review_by $D365, the default for a concept" \
  && out_has "set review_by $D182, the default for a note" && V "$T/ap/r1.md" "$T/ap/r2.md"; } \
  && ok "approve: sets review_by from the type's default, and says so" || no "approve: per-type review_by ($out)"
RB=2099-01-01 TYPE=note doc "$T/ap/r3.md" review ''
out="$(km approve --root "$T" "$T/ap/r3.md" --by RPA 2>&1)"
{ grep -q '^review_by: 2099-01-01$' "$T/ap/r3.md" && grep -q '^status: accepted$' "$T/ap/r3.md" && ! out_has "set review_by"; } \
  && ok "approve: keeps an existing review_by" || no "approve: keeps an existing review_by ($out)"
RB= TYPE=decision doc "$T/ap/r4.md" review ''; RB= TYPE=transcript doc "$T/ap/r5.md" review 'participants: [X]\n'
out="$(km approve --root "$T" "$T/ap/r4.md" "$T/ap/r5.md" --by RPA 2>&1)"
{ grep -q '^status: accepted$' "$T/ap/r4.md" && grep -q '^status: accepted$' "$T/ap/r5.md" && ! grep -q review_by "$T/ap/r4.md" "$T/ap/r5.md" \
  && V "$T/ap/r4.md" "$T/ap/r5.md"; } \
  && ok "approve: a decision or transcript gets no review_by, and accepted_requires: review_by passes" || no "approve: no-expiry types ($out)"
RB=2099-01-01 TYPE=decision doc "$T/ap/r6.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
V "$T/ap/r6.md" && ok "validate: a decision that has a review_by keeps it" || no "validate: a decision with a review_by"
RB= doc "$T/ap/r7.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
errs "$T/ap/r7.md" | grep -q "accepted requires 'review_by'" && ok "validate: an accepted concept still needs review_by" || no "validate: concept still needs review_by"
rbd 'review_by_default:\n  note: 30\n  decision: 365\n'
RB= TYPE=note doc "$T/ap/r8.md" review ''; RB= TYPE=decision doc "$T/ap/r9.md" review ''; RB= doc "$T/ap/r10.md" review ''
km approve --root "$T" "$T/ap/r8.md" "$T/ap/r9.md" "$T/ap/r10.md" --by RPA >/dev/null 2>&1
{ grep -q "^review_by: $D30$" "$T/ap/r8.md" && grep -q "^review_by: $D365$" "$T/ap/r9.md" && grep -q "^review_by: $D365$" "$T/ap/r10.md"; } \
  && ok "review_by_default: schema.local.yaml overrides single types, the rest keep km's" || no "review_by_default: override"
V "$T/ap/r4.md" && no "review_by_default: a decision given an expiry needs review_by again" || ok "review_by_default: a decision given an expiry needs review_by again"
rbd 'fields:\n  type:\n    enum: [note, concept, decision, transcript, artifact, summary, reference, verbatim-block, howto]\n'
RB= TYPE=howto doc "$T/ap/r11.md" review ''
km approve --root "$T" "$T/ap/r11.md" --by RPA >/dev/null 2>&1 && grep -q "^review_by: $D182$" "$T/ap/r11.md" \
  && ok "review_by_default: a brain-local type falls back to \"*\" (182 days)" || no "review_by_default: unknown type fallback"
rbd 'fields:\n  type:\n    enum: [note, concept, decision, transcript, artifact, summary, reference, verbatim-block, howto]\nreview_by_default:\n  howto: null\n'
RB= TYPE=howto doc "$T/ap/r12.md" review ''
km approve --root "$T" "$T/ap/r12.md" --by RPA >/dev/null 2>&1 && ! grep -q review_by "$T/ap/r12.md" && V "$T/ap/r12.md" \
  && ok "review_by_default: a brain-local type set to null does not expire" || no "review_by_default: brain-local type null"
rbd 'review_by_default:\n  note: null\n'
RB= TYPE=note doc "$T/ap/r12b.md" review ''
km approve --root "$T" "$T/ap/r12b.md" --by RPA >/dev/null 2>&1 && ! grep -q review_by "$T/ap/r12b.md" && V "$T/ap/r12b.md" \
  && ok "review_by_default: null on one of km's types overrides it: no expiry" || no "review_by_default: km type set to null"
for bad in 'review_by_default:\n  referenc: 365\n' 'review_by_default:\n  note: 0\n' 'review_by_default:\n  note: "6 months"\n' 'review_by_default: 182\n'; do
  rbd "$bad"; out="$(errs "$T/ap/r6.md")"; rc=$?; [ "$rc" = 1 ] && out_has "review_by_default maps a type" && ok "review_by_default: fails fast on $(printf '%b' "$bad" | tr '\n' ' ')" \
    || no "review_by_default: fails fast on $bad"
done
# --help answers whatever the schema holds; the schema check stops a real run only
for c in validate list demote approve gen-index serve; do
  out="$(km "$c" --root "$T" --help 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && out_has "usage: km $c" && ! out_has "review_by_default"; } \
    && ok "review_by_default: a bad table still lets $c --help answer" || no "$c --help with a bad table ($rc: $out)"
done
cp "$T/schema.local.yaml" "$T/sl.bak"; printf 'gate: {enabled: maybe}\ncheck_index: 1\nindex_skip_prefixes: x\n' >> "$T/schema.local.yaml"
out="$(km validate --root "$T" --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "usage: km validate" && ! out_has "gate config"; } \
  && ok "a bad gate, check_index and index_skip_prefixes still let validate --help answer" || no "validate --help with a bad gate ($rc: $out)"
out="$(km validate --root "$T" "$T/ap/r6.md" 2>/dev/null)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate config error(s)" && out_has "gate.enabled must be true/false"; } \
  && ok "a bad gate config still stops a run first, on stdout, exit 1" || no "bad gate run ($rc: $out)"
mv "$T/sl.bak" "$T/schema.local.yaml"
cp "$T/schema.local.yaml" "$T/sl.bak"; printf 'status_rules:\n  acepted_requires: [review_by]\n' >> "$T/schema.local.yaml"
out="$(km validate --root "$T" --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "usage: km validate" && ! out_has "status_rules"; } \
  && ok "a mistyped status_rules key still lets validate --help answer" || no "validate --help with bad status_rules ($rc: $out)"
mv "$T/sl.bak" "$T/schema.local.yaml"
# a schema.local.yaml that is no YAML, or no mapping: every --help answers, a real run stops as before
cp "$T/schema.local.yaml" "$T/sl.bak"
for broken in 'gate: [unclosed\n' '- a list\n'; do
  printf -- "$broken" > "$T/schema.local.yaml"; what="$(printf -- "$broken" | head -c 12)"
  for c in validate gen-index demote serve promote approve repin cite cites list "promote stub" "cite add"; do
    out="$(km $c --root "$T" --help 2>&1)"; rc=$?
    { [ "$rc" = 0 ] && out_has "usage: km $c" && ! out_has "schema.local.yaml"; } \
      && ok "schema '$what': km $c --help answers" || no "schema '$what': $c --help ($rc: $out)"
  done
  for c in validate list serve; do
    err="$(km $c --root "$T" 2>&1 >/dev/null)"; rc=$?; out="$(km $c --root "$T" 2>/dev/null)"
    { [ "$rc" = 1 ] && [ -z "$out" ] && grep -Eq '^schema.local.yaml: (invalid YAML|must be a mapping)' <<< "$err"; } \
      && ok "schema '$what': a km $c run still stops on stderr, exit 1" || no "schema '$what': $c run ($rc: $out / $err)"
  done
done
{ [ "$(km --root "$T" --version)" = "$(km --version)" ] && km --root "$T" --help | grep -q "usage: km <command>"; } \
  && ok "a broken schema leaves km --help and --version alone" || no "km --help/--version with a broken schema"
# a setting of a type km cannot use stops every command with the schema message, never a traceback
for bad in 'index_skip_prefixes: 7' 'skip_prefixes: 7' 'skip_prefixes: [7]' 'exempt_files: 7' 'exempt_files: [[a]]' \
           'reserved_no_frontmatter: 7' 'gate: {customer_audience: [a]}' 'fields: 7' 'fields: {title: 7}' \
           'type_rules: [a]' 'type_rules_soft: {note: 7}'; do
  printf '%s\n' "$bad" > "$T/schema.local.yaml"; key="${bad%%:*}"; [ "$key" = gate ] && key=gate.customer_audience
  [ "$key" = fields ] && [ "$bad" != 'fields: 7' ] && key=fields.title; [ "$key" = type_rules_soft ] && key=type_rules_soft.note
  for c in validate list gen-index serve demote; do
    [ "$key$c" = gate.customer_audiencevalidate ] && continue   # validate reports its gate config first, as before
    out="$(km $c --root "$T" 2>&1)"; rc=$?
    { [ "$rc" = 1 ] && out_has "^schema.local.yaml: $key must be" && ! out_has Traceback; } \
      && ok "'$bad': km $c stops with the schema message" || no "'$bad': km $c ($rc: $out)"
  done
  out="$(km list --root "$T" --help 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && out_has "usage: km list"; } && ok "'$bad': km list --help answers" || no "'$bad': list --help ($rc: $out)"
done
printf 'status_rules: 7\n' > "$T/schema.local.yaml"; out="$(km validate --root "$T" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "status_rules must map" && ! out_has Traceback; } \
  && ok "status_rules that is no mapping stops validate with the schema message" || no "status_rules: 7 ($rc: $out)"
mv "$T/sl.bak" "$T/schema.local.yaml"
RB= TYPE=note doc "$T/ap/r13.md" review ''; cp "$T/ap/r13.md" "$T/r13.bak"; printf 'promoted\n' > "$T/rsrc.txt"
out="$(km approve --root "$T" "$T/ap/r13.md" --by RPA 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && out_has "review_by_default maps a type" && cmp -s "$T/ap/r13.md" "$T/r13.bak"; } \
  && ok "review_by_default: approve refuses a bad table before it computes a date" || no "approve with a bad table ($rc: $out)"
out="$(km promote --root "$T" rb-bad "$T/rsrc.txt" --folder ap --type note --author X 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && out_has "review_by_default maps a type" && [ ! -e "$T/ap/rb-bad.md" ]; } \
  && ok "review_by_default: promote refuses a bad table" || no "promote with a bad table ($rc: $out)"
rbd 'fields:\n  type:\n    required: true\nreview_by_default:\n  playbook: 30\n'
V "$T/ap/r6.md" && ok "review_by_default: a schema without a type enum takes any type as a key" || no "review_by_default: no type enum ($(errs "$T/ap/r6.md"))"
rbd
RB=2020-01-01 TYPE=decision doc "$T/ap/r14.md" review ''
out="$(km approve --root "$T" "$T/ap/r14.md" --by RPA 2>&1)"
{ grep -q '^status: accepted$' "$T/ap/r14.md" && grep -q '^review_by: 2020-01-01$' "$T/ap/r14.md" && ! errs "$T/ap/r14.md" | grep -q gate-stale; } \
  && ok "approve: a decision's passed review_by is ignored and kept; validate does not call it stale" || no "approve: passed review_by on a decision ($out)"
RB= TYPE=decision doc "$T/ap/r16.md" review ''; cp "$T/ap/r16.md" "$T/r16.bak"
out="$(km approve --root "$T" "$T/ap/r16.md" --by RPA --review-by 2099-01-01 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "does not expire, --review-by would be ignored" && cmp -s "$T/ap/r16.md" "$T/r16.bak"; } \
  && ok "approve: --review-by on a type that does not expire is refused" || no "approve --review-by on a decision ($rc: $out)"
RB=soon TYPE=decision doc "$T/ap/r17.md" review ''
out="$(km approve --root "$T" "$T/ap/r17.md" --by RPA 2>&1)"
out_has "is not a YYYY-MM-DD date" && ok "approve: a malformed review_by is refused on any type" || no "approve: malformed review_by on a decision ($out)"
RB=2020-01-01 TYPE=note doc "$T/ap/r15.md" review ''
out="$(km approve --root "$T" "$T/ap/r15.md" --by RPA 2>&1)"
{ out_has "has passed; pass --review-by with a new date" && grep -q '^status: review$' "$T/ap/r15.md"; } \
  && ok "approve: a note with a passed review_by is still refused" || no "approve: passed review_by on a note ($out)"
rbd
printf 'promoted\n' > "$T/rsrc.txt"
for ty in reference:365 note:182 summary:182 decision:none artifact:none; do
  t="${ty%%:*}" d="${ty#*:}"; f="$T/ap/rb-$t.md"
  km promote --root "$T" "rb-$t" "$T/rsrc.txt" --folder ap --type "$t" --author X >/dev/null 2>&1
  if [ "$d" = none ]; then [ -f "$f" ] && ! grep -q review_by "$f"; else want="D$d"; grep -q "^review_by: '${!want}'$" "$f"; fi \
    && ok "promote: type $t gets review_by: $d" || no "promote: type $t gets review_by: $d ($(cat "$f" 2>&1))"
done
rm -f "$T"/ap/r[0-9]*.md "$T"/ap/rb-*.md "$T/rsrc.txt"
doc "$T/ap/m1.md" review ''; printf -- '---\ntitle: broken\n---\nx\n' > "$T/ap/m2.md"
out="$(KM_ROOT="$T" kmpy -c 'import sys, km.validate as v
bad, good = sys.argv[1:3]
sys.argv = ["km validate", bad]; first = v.main()
sys.argv = ["km validate", good]; print("runs:", first, v.main())' "$T/ap/m2.md" "$T/ap/m1.md" 2>&1)"
out_has "runs: 1 0$" && ok "validate: a second main() starts with a clean report" || no "validate main twice ($out)"
rm -f "$T/ap/m1.md" "$T/ap/m2.md"
# an approval follows the content: km approve records approved_digest, a later content change makes it stale
doc "$T/ap/s1.md" review 'approval: ai\n'
km approve --root "$T" "$T/ap/s1.md" --by RPA --at 2026-09-30 >/dev/null 2>&1
{ grep -q '^approved_digest: "[0-9a-f]\{16\}"$' "$T/ap/s1.md" && V "$T/ap/s1.md"; } \
  && ok "approve: records the digest of the approved content" || no "approve: records the digest ($(cat "$T/ap/s1.md"))"
cp "$T/ap/s1.md" "$T/s1.approved"
sed -i.bak 's/^body$/changed body/' "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak"
out="$(km validate --root "$T" "$T/ap/s1.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "approval-stale" && out_has "km demote ap/s1.md" && out_has "km approve ap/s1.md --by" && out_has "or revert the change"; } \
  && ok "approval: a body change after the approval fails the gate, naming km demote and km approve" || no "approval: body change ($rc: $out)"
cp "$T/ap/s1.md" "$T/s1.changed"; printf 'reviewed_by: ["model-x 2026-09-29 (PR #1)"]\n' >> "$T/s1.rb"
sed -i.bak "/^owner: X$/r $T/s1.rb" "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak" "$T/s1.rb"
out="$(km demote --root "$T" "$T/ap/s1.md" 2>&1)"
{ grep -q '^status: review$' "$T/ap/s1.md" && ! grep -q '^approved_\|^reviewed_by' "$T/ap/s1.md" && out_has "back to review" && V "$T/ap/s1.md"; } \
  && ok "demote DOC: sends a changed accepted doc back to review, approval and reviewed_by dropped" || no "demote DOC ($out; $(cat "$T/ap/s1.md"))"
km approve --root "$T" "$T/ap/s1.md" --by RPA --at 2026-10-01 >/dev/null 2>&1 && V "$T/ap/s1.md" \
  && ok "approve: after the send-back, the approval is clean again" || no "approve after demote ($(cat "$T/ap/s1.md"))"
out="$(km demote --root "$T" "$T/ap/s3x.md" "$T/ap/p4.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "REFUSED ap/p4.md: not accepted" && grep -q '^status: draft$' "$T/ap/p4.md"; } \
  && ok "demote DOC: a doc that is not accepted is refused" || no "demote DOC on a draft ($rc: $out)"
cp "$T/s1.changed" "$T/ap/s1.md"; printf 'reviewed_by: ["model-x 2026-09-29 (PR #1)"]\n' >> "$T/ap/s1.rb"
sed -i.bak "/^owner: X$/r $T/ap/s1.rb" "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak" "$T/ap/s1.rb"
out="$(km approve --root "$T" "$T/ap/s1.md" --by RPA --at 2026-10-01 2>&1)"
{ grep -q '^approved_at: 2026-10-01$' "$T/ap/s1.md" && V "$T/ap/s1.md" && out_has "reviewed_by entries are from before the change"; } \
  && ok "approve: re-approving the changed doc clears it, and flags reviewed_by from before" || no "approve: re-approve ($out; $(cat "$T/ap/s1.md"))"
cp "$T/ap/s1.md" "$T/s1.clean"; out="$(km approve --root "$T" "$T/ap/s1.md" --by ai:model-x 2>&1)"
{ out_has "already approved for this content" && cmp -s "$T/ap/s1.md" "$T/s1.clean"; } \
  && ok "approve: an accepted doc whose content is unchanged is not approved over" || no "approve: unchanged re-approve ($out)"
cp "$T/s1.approved" "$T/ap/s1.md"
sed -i.bak 's/^title: t$/title: another claim/' "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak"
km validate --root "$T" "$T/ap/s1.md" 2>&1 | grep -q "approval-stale" \
  && ok "approval: a title change makes it stale too" || no "approval: a title change makes it stale too"
cp "$T/s1.approved" "$T/ap/s1.md"
sed -i.bak 's/^review_by: .*/review_by: 2028-06-30/; s/^tags: \[t\]$/tags: [t, more]/; s/^timestamp: .*/timestamp: 2026-10-02/' "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak"
printf 'report\n' > "$T/s1.pdf"; U=https://example.sharepoint.com/sites/x/Shared%20Documents/r.pdf
H="$(kmpy -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$T/s1.pdf")"
printf 'reviewed_by: ["model-x 2026-10-02 (PR #2)"]\ncites:\n- url: %s\n  sha256: %s\n  retrieved: 2026-10-02\n' "$U" "$H" > "$T/s1.extra"
sed -i.bak "/^owner: X$/r $T/s1.extra" "$T/ap/s1.md" && rm -f "$T/ap/s1.md.bak"
out="$(km cite add --root "$T" "$T/ap/s1.md" "$U" --file "$T/s1.pdf" --title "The report" 2>&1)"
{ grep -q '^  title: The report$' "$T/ap/s1.md" && grep -q '^status: accepted$' "$T/ap/s1.md" && grep -q '^review_by: 2028-06-30$' "$T/ap/s1.md" \
  && grep -q '^reviewed_by:' "$T/ap/s1.md" && V "$T/ap/s1.md"; } \
  && ok "approval: frontmatter bookkeeping (cites, km cite add, review_by, tags, timestamp, reviewed_by) keeps it" || no "approval: bookkeeping edits ($out; $(cat "$T/ap/s1.md"))"
printf '\n\n' >> "$T/ap/s1.md"
V "$T/ap/s1.md" && ok "approval: trailing blank lines are not a content change" || no "approval: trailing blank lines"
doc "$T/ap/s2.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
sed -i.bak 's/^body$/changed body/' "$T/ap/s2.md" && rm -f "$T/ap/s2.md.bak"
V "$T/ap/s2.md" && ok "approval: a doc approved before the digest existed is not checked" || no "approval: legacy doc without a digest"
out="$(km approve --root "$T" "$T/ap/s2.md" --by ai:model-x 2>&1)"
{ grep -q '^approved_by: RPA$' "$T/ap/s2.md" && grep -q '^approved_at: 2026-09-30$' "$T/ap/s2.md" && grep -q '^approved_digest:' "$T/ap/s2.md" \
  && out_has "kept as the approval" && V "$T/ap/s2.md"; } \
  && ok "approve: on a doc approved before the digest it records the content and keeps the approver" || no "approve legacy ($out; $(cat "$T/ap/s2.md"))"
doc "$T/ap/s6.md" review 'valid_for: {2026: fw, hw: C1, 2026-01-01: x}\n'
out="$(km approve --root "$T" "$T/ap/s6.md" --by RPA 2>&1)"
{ grep -q '^approved_digest:' "$T/ap/s6.md" && ! out_has Traceback && V "$T/ap/s6.md"; } \
  && ok "approval: mapping keys of mixed types are digested" || no "approval: mixed keys ($out)"
doc "$T/ap/s7.md" review 'valid_for: 1.10\n'; km approve --root "$T" "$T/ap/s7.md" --by RPA >/dev/null 2>&1
out="$(km validate --root "$T" "$T/ap/s7.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "approval-quote" && out_has "valid_for holds an unquoted number"; } \
  && ok "approval: an unquoted number in a content field is a warning to quote it" || no "approval: quote warning ($rc: $out)"
doc "$T/ap/s3.md" review 'approval: ai\n'
km approve --root "$T" "$T/ap/s3.md" --by ai:model-x --at 2026-09-30 >/dev/null 2>&1
sed -i.bak 's/^body$/changed body/' "$T/ap/s3.md" && rm -f "$T/ap/s3.md.bak"
km validate --root "$T" "$T/ap/s3.md" 2>&1 | grep -q "approval-stale" \
  && ok "approval: an AI approval goes stale the same way" || no "approval: an AI approval goes stale the same way"
KM_ROOT="$T" kmpy -c 'import sys, km.common as c
raw = open(sys.argv[1], encoding="utf-8").read().split("\n---\n", 1)[0] + "\n---\n"
sys.exit("approved_" in c.demote_raw(raw))' "$T/ap/s3.md" \
  && ok "demote: drops the digest with the approval" || no "demote: drops the digest with the approval"
V "$T/ap/p9.md" && ok "approval: a CRLF doc approved by km approve validates" || no "approval: a CRLF doc approved by km approve validates"
doc "$T/ap/s4.md" review ''; printf 'one\rtwo\n' >> "$T/ap/s4.md"
km approve --root "$T" "$T/ap/s4.md" --by RPA >/dev/null 2>&1 && grep -q '^approved_digest:' "$T/ap/s4.md" && V "$T/ap/s4.md" \
  && ok "approval: a body with a lone CR validates after km approve" || no "approval: a body with a lone CR validates after km approve"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'fields:\n  description:\n    alias: summary\n' >> "$T/schema.local.yaml"
doc "$T/ap/s5.md" review 'summary: what it says\n'
km approve --root "$T" "$T/ap/s5.md" --by RPA >/dev/null 2>&1 && grep -q '^approved_digest:' "$T/ap/s5.md" && V "$T/ap/s5.md" \
  && ok "approval: a field alias does not make km approve and km validate disagree" || no "approval: field alias ($(km validate --root "$T" "$T/ap/s5.md" 2>&1))"
printf 'meta: {profile: smoke}\nauthor_default: RPA\n' > "$T/schema.local.yaml"
out="$(km validate --root "$T" "$T/ap/s3.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "WARNINGS: 1" && out_has "approval-stale"; } \
  && ok "approval: without the gate (a personal brain) a stale approval is a warning" || no "approval: personal severity ($rc: $out)"
rm -f "$T/s1.approved" "$T/s1.clean" "$T/s1.changed" "$T/s1.extra" "$T/s1.pdf"; unset U H
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# promote drops reviewed_by (new doc and --replace); a cross-repo promote also drops approval
printf -- '---\ntype: note\ntitle: R\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\napproval: ai\nreviewed_by: ["model-x 2026-09-30 (PR #1)"]\n---\nbody\n' > "$T/inbox/rv.md"
km promote --root "$T" rv-topic "$T/inbox/rv.md" --folder ap >/dev/null 2>&1
{ [ -f "$T/ap/rv-topic.md" ] && ! grep -q '^reviewed_by:' "$T/ap/rv-topic.md" && grep -q '^approval: ai' "$T/ap/rv-topic.md"; } \
  && ok "promote: drops reviewed_by, keeps approval in the same brain" || no "promote: drops reviewed_by, keeps approval in the same brain"
! grep -q '^audience:' "$T/ap/rv-topic.md" && ok "promote: leaves the audience to the author" || no "promote: leaves the audience to the author"
printf -- '---\ntype: note\ntitle: Au\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$T/inbox/au.md"
km promote --root "$T" au-topic "$T/inbox/au.md" --folder ap --audience internal >/dev/null 2>&1
grep -q '^audience: internal$' "$T/ap/au-topic.md" && ok "promote: --audience sets it" || no "promote: --audience sets it"
AUD= doc "$T/ap/ra.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
out="$(km promote --root "$T" ra "$T/inbox/au.md" --replace --audience internal 2>&1)"
grep -q '^audience: internal$' "$T/ap/ra.md" && ok "promote --replace: --audience sets it too" || no "promote --replace: --audience sets it too ($out)"
doc "$T/ap/rp.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\nreviewed_by: ["model-x 2026-09-29 (PR #1)"]\n'
printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\n---\nnew text\n' > "$T/inbox/rp.md"
km promote --root "$T" rp "$T/inbox/rp.md" --replace >/dev/null 2>&1
{ grep -q '^status: review' "$T/ap/rp.md" && ! grep -q '^reviewed_by:' "$T/ap/rp.md"; } \
  && ok "promote --replace: drops reviewed_by with the approval" || no "promote --replace: drops reviewed_by with the approval"
X="$(mktemp -d)"; printf -- '---\ntype: note\ntitle: C\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\napproval: ai\n---\nbody\n' > "$X/cr.md"
km promote --root "$T" cr-topic "$X/cr.md" --folder ap --author X >/dev/null 2>&1
{ [ -f "$T/ap/cr-topic.md" ] && ! grep -q '^approval:' "$T/ap/cr-topic.md"; } \
  && ok "promote cross-repo: the target decides the approval level" || no "promote cross-repo: the target decides the approval level"
rm -rf "$X" "$T/ap" "$T/p2.bak" "$T/p5.bak" "$T/p7.bak"

# bergab resolves a bare [[slug]] by exact file name among the docs on disk git tracks or would track: no glob
S="$(mktemp -d)"; mkdir -p "$S/b/k" "$S/b/scratch"; git -C "$S" init -q   # the brain sits below the git top level
GATE_ON=$'meta: {profile: smoke}\ngate:\n  enabled: true\n'; printf '%s' "$GATE_ON" > "$S/b/schema.local.yaml"
draft(){ printf -- '---\ntype: note\ntitle: w\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nwip\n' > "$1"; }
draft "$S/b/k/wip.md"
acc "$S/b/k/glob.md" internal $'[Decision]: **use-LTC6813** for the stack\n\nsee [[wi*]] and [[w?p]] and [x](w[i]p)'
git -C "$S" add b
for m in "" "$S/b/k/glob.md"; do
  out="$(km validate --root "$S/b" $m 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && ! out_has Traceback && ! out_has gate-bergab; } \
    && ok "bergab: a link target with glob characters is a name, not a pattern ($([ -n "$m" ] && echo per file || echo whole repo))" \
    || no "bergab glob target ${m:+per file} ($rc: $out)"
done
draft "$S/b/scratch/foo.md"; acc "$S/b/k/sl.md" internal 'see [[foo]]'; git -C "$S" add b/k/sl.md
printf 'scratch/\n' > "$S/b/.gitignore"
out="$(km validate --root "$S/b" "$S/b/k/sl.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! out_has gate-bergab; } && ok "bergab: a gitignored draft is not a link target" || no "bergab: ignored draft ($rc: $out)"
# a link written as a path resolves as a slug does: a gitignored file is none, as nobody who clones has it
draft "$S/b/scratch/pth.md"; acc "$S/b/k/pl.md" internal 'see [x](../scratch/pth.md)'; git -C "$S" add b/k/pl.md
printf -- '---\ntype: note\ntitle: r\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\nrelated: [scratch/pth.md, brains/peer/p.md]\n---\nr\n' > "$S/b/k/rl.md"
mkdir -p "$S/b/brains/peer"; git -C "$S/b/brains/peer" init -q; draft "$S/b/brains/peer/p.md"   # a mounted brain: its own repository
out="$(km validate --root "$S/b" "$S/b/k/pl.md" "$S/b/k/rl.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! out_has gate-bergab && out_has "ref:related" && out_has "missing target scratch/pth.md" && ! out_has "brains/peer/p.md"; } \
  && ok "a path link or related: to a gitignored file is dead (no bergab, a ref warning); a mounted brain's file resolves" \
  || no "path link to an ignored file ($rc: $out)"
rm "$S/b/.gitignore"   # the gate runs before `git add` (km approve, promote): a draft not yet staged counts
out="$(km validate --root "$S/b" "$S/b/k/sl.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab" && out_has "scratch/foo.md"; } \
  && ok "bergab: an untracked draft that is not ignored fails" || no "bergab: untracked draft ($rc: $out)"
out="$(km validate --root "$S/b" "$S/b/k/pl.md" "$S/b/k/rl.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab" && out_has "scratch/pth.md" && ! out_has "ref:related"; } \
  && ok "a path link to an untracked draft that is not ignored resolves (bergab, no ref warning)" || no "path link to untracked draft ($rc: $out)"
rm -rf "$S/b/brains" "$S/b/k/rl.md"
git -C "$S" add b/scratch/foo.md
out="$(km validate --root "$S/b" "$S/b/k/sl.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab" && out_has "scratch/foo.md"; } && ok "bergab: a tracked draft slug still fails" || no "bergab: tracked draft slug ($rc: $out)"
mkdir -p "$S/b/a" "$S/b/z"; draft "$S/b/a/dup.md"; draft "$S/b/z/dup.md"; acc "$S/b/k/sh.md" internal 'see [[dup]]'
git -C "$S" add b; rm "$S/b/a/dup.md"   # deleted, the deletion not staged: it must not take the name from z/dup.md
out="$(km validate --root "$S/b" "$S/b/k/sh.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab" && out_has "z/dup.md"; } \
  && ok "bergab: a tracked doc deleted on disk does not shadow a live one of the same name" || no "bergab: deleted shadow ($rc: $out)"
N="$(mktemp -d)"; printf '%s' "$GATE_ON" > "$N/schema.local.yaml"   # not a git repo
draft "$N/nd.md"; acc "$N/nl.md" internal 'see [[nd]]'
out="$(km validate --root "$N" "$N/nl.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab" && out_has "nd.md"; } && ok "bergab: outside git a draft on disk is a link target" || no "bergab: no git, draft ($rc: $out)"
acc "$N/n.md" internal 'see [top](#top) and [[n2]]'
out="$(km validate --root "$N" "$N/n.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! out_has Traceback; } && ok "bergab: a brain outside git still validates per file" || no "bergab: no git ($rc: $out)"
# km validate takes FILEs only: an unknown option is a usage error, --help validates nothing, -- ends the options
out="$(km validate --root "$S/b" --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "usage: km validate" && ! out_has "ERRORS" && ! out_has "WARNINGS"; } \
  && ok "validate --help: usage, nothing validated" || no "validate --help ($rc: $out)"
out="$(km validate --root "$S/b" --strict 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && out_has "unrecognized arguments: --strict" && ! out_has "ERRORS"; } \
  && ok "validate: an unknown option is a usage error" || no "validate --strict ($rc: $out)"
# a FILE whose name starts with '-' after `--` (the hook's entry ends with it), --root before or after the command
printf -- '---\ntitle: no type\n---\nx\n' > "$S/b/-dash.md"
for r in "--root $S/b validate" "validate --root $S/b"; do
  out="$(cd "$S/b" && km $r -- -dash.md 2>&1)"; rc=$?
  { [ "$rc" = 1 ] && out_has "required field 'type' absent" && out_has "[-]dash.md" && ! out_has "unrecognized"; } \
    && ok "validate: a FILE named -dash.md after -- is checked (km ${r%% *} ...)" || no "validate -- -dash.md ($r; $rc: $out)"
done
rm "$S/b/-dash.md"
grep -qE '^  entry: km validate --( |$)' "$REPO/.pre-commit-hooks.yaml" \
  && ok "the km-validate hook ends its entry with --: a staged name never reads as an option" || no "km-validate hook entry lacks --"
out="$(km validate --root "$S/b" -- "$S/b/k/sl.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "gate-bergab"; } && ok "validate: -- ends the options, the FILE is checked" || no "validate -- FILE ($rc: $out)"
# promote: a slug is a file name every system can hold; a slug and a wiki-link target are names, never patterns
acc "$S/b/k/target.md" internal "old"; cp "$S/b/k/target.md" "$S/target.bak"; printf 'new\n' > "$N/src.txt"
for sl in 'targe?' '**x**'; do
  out="$(km promote --root "$S/b" "$sl" "$N/src.txt" --folder k --type note --author X --replace 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && out_has "which a file name on Windows" && cmp -s "$S/b/k/target.md" "$S/target.bak" \
    && ! ls "$S/b/k" | grep -q '[?*]' && ! out_has Traceback; } \
    && ok "promote: the slug '$sl' is refused, nothing written" || no "promote: slug '$sl' ($rc: $out)"
done
for sl in aux Com1 nul.x; do   # a device name Windows reserves, with any extension
  out="$(km promote --root "$S/b" "$sl" "$N/src.txt" --folder k --type note --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && out_has "name Windows reserves" && [ ! -e "$S/b/k/$sl.md" ]; } \
    && ok "promote: the slug '$sl' is refused, nothing written" || no "promote: slug '$sl' ($rc: $out)"
done
out="$(km promote --root "$S/b" target "$N/src.txt" --folder k 2>&1)"; rc=$?   # target.md is not yet `git add`ed
{ [ "$rc" = 2 ] && out_has "k/target.md exists" && cmp -s "$S/b/k/target.md" "$S/target.bak"; } \
  && ok "promote: an untracked doc that is not ignored still takes its slug" || no "promote: untracked collision ($rc: $out)"
printf 'mine\n' | tee "$S/b/k/ign.md" > "$S/b/scratch/ign2.md"; printf 'k/ign.md\nscratch/ign2.md\n' > "$S/b/.gitignore"
out="$(km promote --root "$S/b" ign "$N/src.txt" --folder k --type note --author X 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && out_has "exists but is no doc of the brain" && [ "$(cat "$S/b/k/ign.md")" = mine ]; } \
  && ok "promote: a gitignored file at the target is never overwritten" || no "promote: ignored target ($rc: $out)"
i=0; for w in 'targe*' '**nope**' 'ign2'; do i=$((i+1))
  printf -- '---\ntype: note\ntitle: G\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [[%s]]\n' "$w" > "$N/g.md"
  out="$(km promote --root "$S/b" "xr-glob$i" "$N/g.md" --folder k --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$S/b/k/xr-glob$i.md" ] && grep -qF -- "- [[$w]]" <<< "$out" && ! out_has Traceback; } \
    && ok "promote cross-repo: [[$w]] is a dead link$([ "$w" = ign2 ] && echo ': a gitignored file is none' || echo ', not a pattern')" \
    || no "promote cross-repo [[$w]] ($rc: $out)"
done
# a doc path a clone on Windows cannot check out is a warning, never an error; promote refuses it
mkdir -p "$S/b/pn/dir." "$S/b/pn/ok"; draft "$S/b/pn/aux.md"; draft "$S/b/pn/q?.md"; draft "$S/b/pn/dir./d.md"; draft "$S/b/pn/ok/fine.md"
git -C "$S" add b/pn
out="$(km validate --root "$S/b" "$S/b/pn/aux.md" "$S/b/pn/q?.md" "$S/b/pn/dir./d.md" "$S/b/pn/ok/fine.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "3 x portable-name" && out_has "'dir.' ends in a dot" && out_has "pn/aux.md - 'aux.md' is a device name" \
  && out_has "'q?.md' holds '?'" && ! out_has "fine.md"; } && ok "validate: an unportable doc path is a portable-name warning (per file)" \
  || no "validate portable-name per file ($rc: $out)"
out="$(km validate --root "$S/b" 2>&1)"
{ out_has "3 x portable-name" && ! sed -n '/^ERRORS/,/^WARNINGS/p' <<< "$out" | grep -q portable; } \
  && ok "validate: whole repo reports each unportable doc path as a warning" || no "validate portable-name whole repo ($out)"
git -C "$S" rm -rq --cached b/pn; rm -rf "$S/b/pn"
printf 'body\n' > "$N/pn.txt"
for f in 'k/aux' 'k/dir.' 'k/a b ' 'x<y'; do
  out="$(km promote --root "$S/b" pnew "$N/pn.txt" --folder "$f" --type note --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && out_has "pick another --folder" && [ ! -e "$S/b/$f/pnew.md" ]; } \
    && ok "promote: --folder '$f' is refused, nothing written" || no "promote: --folder '$f' ($rc: $out)"
done
for sl in 'x.' 'x '; do   # the file name is x..md, x .md: Windows keeps those
  out="$(km promote --root "$S/b" "$sl" "$N/pn.txt" --folder k --type note --author X 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ -e "$S/b/k/$sl.md" ]; } && ok "promote: the slug '$sl' becomes a file name Windows holds" || no "promote: slug '$sl' ($rc: $out)"
  rm -f "$S/b/k/$sl.md"
done
# two keys that read as the same text: a warning, and the digest covers both values
out="$(kmpy "$REPO/tests/digest_check.py" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "approved_digest is unchanged for every doc without such keys, and covers both values of a pair" || no "digest_check.py ($out)"
printf -- '---\ntype: note\ntitle: kc\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\nvalid_for:\n  1: a\n  "1": b\n  2026-01-01: c\n  "2026-01-01": d\n---\nx\n' > "$S/b/k/kc.md"
out="$(km validate --root "$S/b" "$S/b/k/kc.md" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "2 x key-collision" && out_has 'valid_for: 1 (int) and "1" read as the same text' \
  && out_has 'valid_for: 2026-01-01 (date) and "2026-01-01"'; } && ok "validate warns about two keys that read as the same text" || no "key-collision ($rc: $out)"
rm -f "$S/b/k/kc.md"
i=0; for l in 'ign.md' '/scratch/ign2.md' '../scratch/ign2.md'; do i=$((i+1))
  printf -- '---\ntype: note\ntitle: P\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [x](%s)\n' "$l" > "$N/p.md"
  out="$(km promote --root "$S/b" "xr-path$i" "$N/p.md" --folder k --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$S/b/k/xr-path$i.md" ] && grep -qF -- "- $l" <<< "$out"; } \
    && ok "promote cross-repo: [x]($l) to a gitignored file is a dead link" || no "promote cross-repo [x]($l) ($rc: $out)"
done
# a bare [[slug]] resolves for promote where it does for validate: not under skip_prefixes, a [[x.md]] only as a path
mkdir -p "$S/b/brains/x"; draft "$S/b/brains/x/only-there.md"; draft "$S/b/k/real.md"; draft "$S/b/k/two words.md"
git -C "$S" add b/brains/x b/k/real.md "b/k/two words.md"
i=0; for w in only-there real.md; do i=$((i+1))
  printf -- '---\ntype: note\ntitle: P\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [[%s]]\n' "$w" > "$N/p.md"
  out="$(km promote --root "$S/b" "xr-skip$i" "$N/p.md" --folder z --author X 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$S/b/z/xr-skip$i.md" ] && grep -qF -- "- [[$w]]" <<< "$out"; } \
    && ok "promote cross-repo: [[$w]] does not resolve, as km validate reads it" || no "promote cross-repo [[$w]] ($rc: $out)"
done
printf -- '---\ntype: note\ntitle: P\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [[real]] and [[two words]]\n' > "$N/p.md"
out="$(km promote --root "$S/b" xr-skip-ok "$N/p.md" --folder z --author X 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -e "$S/b/z/xr-skip-ok.md" ]; } && ok "promote cross-repo: [[real]] and [[two words]] resolve by name" || no "promote cross-repo [[real]] ($rc: $out)"
git -C "$S" rm -rq --cached b/brains/x b/k/real.md "b/k/two words.md"; rm -rf "$S/b/brains" "$S/b/z" "$S/b/k/real.md" "$S/b/k/two words.md"
printf -- '---\ntype: note\ntitle: P\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [x](target.md)\n' > "$N/p.md"
out="$(km promote --root "$S/b" xr-path-ok "$N/p.md" --folder k --author X 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -e "$S/b/k/xr-path-ok.md" ]; } && ok "promote cross-repo: a path link to a doc of the brain resolves" || no "promote cross-repo path link ($rc: $out)"
rm -rf "$S" "$N"

# bergab-old: a link to a superseded doc is quiet when its superseded_by chain reaches the linking doc or a doc
# it also links (body or related:); a link to an obsolete doc, or one with no successor in sight, warns, once per target
L="$(mktemp -d)"; mkdir -p "$L/d"; git -C "$L" init -q; printf '%s' "$GATE_ON" > "$L/schema.local.yaml"
sup(){ doc "$L/d/$1" superseded "superseded_by: $2\n"; }
sup old-design.md d/new-design.md; acc "$L/d/new-design.md" internal 'replaces [old](old-design.md), whose sections 2 and 3 still hold'
sup a.md d/b.md; sup b.md '[d/c.md]'; acc "$L/d/c.md" internal c
sup cy1.md d/cy2.md; sup cy2.md d/cy1.md; sup self.md d/self.md
sup gone.md d/missing.md; draft "$L/d/wip.md"
doc "$L/d/obs.md" obsolete
page(){ printf -- '---\ntype: concept\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: accepted\naudience: internal\ntags: [t]\n%bowner: X\napproved_by: X\napproved_at: 2026-08-26\n---\n%s\n' "${3:+related: $3\n}" "$2" > "$L/d/$1"; }
bo(){ out="$(km validate --root "$L" "$L/d/$1" 2>&1)"; rc=$?; }
quiet(){ bo "$1"; { [ "$rc" = 0 ] && ! out_has gate-bergab && ! out_has Traceback; } && ok "bergab-old quiet: $2" || no "bergab-old quiet: $2 ($rc: $out)"; }
warns(){ bo "$1"; { [ "$rc" = 0 ] && out_has " $2 x gate-bergab-old$" && out_has "$3"; } && ok "bergab-old warns: $4" || no "bergab-old warns: $4 ($rc: $out)"; }
page both.md 'see [old](old-design.md) and [new](new-design.md)'
page chain.md 'see [a](a.md) and [c](c.md)'
page rel-old.md 'see [new](new-design.md)' '[d/old-design.md]'
page rel-new.md 'see [old](old-design.md)' '[d/new-design.md]'
page cy-both.md 'see [x](cy1.md) and [y](cy2.md)'
quiet new-design.md "the successor links its predecessor"
quiet both.md "a page links the old doc and its successor"
quiet chain.md "a page links A and C of the chain A -> B -> C"
quiet rel-old.md "the old doc in related:, the successor in the body"
quiet rel-new.md "the old doc in the body, the successor in related:"
quiet cy-both.md "two superseded docs that name each other, both linked (the rule as written)"
page lone.md 'see [old](old-design.md), [again](old-design.md) and [[old-design]]' '[d/old-design.md]'
warns lone.md 1 "links to superseded d/old-design.md, replaced by d/new-design.md: link d/new-design.md instead or as well" \
  "no successor in sight, the successor named, once for a target linked four times"
page to-a.md 'see [a](a.md)'
warns to-a.md 1 "superseded d/a.md, replaced by d/c.md" "the warning names the first doc on the chain that is not retired"
page to-cy.md 'see [x](cy1.md) and [s](self.md)'; warns to-cy.md 2 "superseded d/cy1.md, superseded_by d/cy2.md leads to no accepted doc" "a cycle in superseded_by ends the walk"
out_has "superseded d/self.md, superseded_by d/self.md leads to no accepted doc" && ok "bergab-old warns: a doc superseded by itself" || no "bergab-old self ($rc: $out)"
page to-gone.md 'see [g](gone.md)'; warns to-gone.md 1 "superseded d/gone.md, superseded_by d/missing.md leads to no accepted doc" "a superseded_by that resolves to no doc"
page to-obs.md 'see [o](obs.md), [o2](obs.md) and [n](new-design.md)'
warns to-obs.md 1 "served doc links to obsolete d/obs.md" "a link to an obsolete doc, once"
page to-wip.md 'see [w](wip.md) and [[wip]]' '[d/wip.md]'; bo to-wip.md
{ [ "$rc" = 1 ] && out_has "1 x gate-bergab$" && out_has "unfinished (draft) d/wip.md"; } \
  && ok "bergab: a draft linked three times is one error" || no "bergab draft dedupe ($rc: $out)"
git -C "$L" add -A; out="$(km validate --root "$L" 2>&1)"; rc=$?
{ out_has "1 x gate-bergab$" && out_has "6 x gate-bergab-old" && ! out_has Traceback; } \
  && ok "bergab-old: the whole-repo run reports the same findings" || no "bergab-old whole repo ($rc: $out)"
mkdir -p "$L/brains/peer"; git -C "$L/brains/peer" init -q; acc "$L/brains/peer/p-new.md" internal p   # a mounted brain
printf '[submodule "brains/peer"]\n  path = brains/peer\n  url = x\n' > "$L/.gitmodules"
sup peer-old.md brains/peer/p-new.md; page to-peer.md 'see [o](peer-old.md) and [n](../brains/peer/p-new.md)'
quiet to-peer.md "the successor is a mounted brain's doc the page links"
printf -- '---\ntype: concept\ntitle: m\ntimestamp: 2026-08-26\nauthor: X\nstatus: superseded\ntags: [t]\nsuperseded_by: new-design\n---\nm\n' > "$L/brains/peer/p-mid.md"
sup mid-old.md brains/peer/p-mid.md; page to-mid.md 'see [o](mid-old.md) and [n](new-design.md)'
warns to-mid.md 1 "superseded d/mid-old.md, superseded_by brains/peer/p-mid.md leads to no accepted doc" \
  "the chain stops at a mounted brain's doc (its superseded_by is that brain's)"
rm -rf "$L/brains/peer"; warns to-peer.md 1 "superseded_by brains/peer/p-new.md leads to no accepted doc" "a successor in a mounted brain not checked out ends the chain"
sup ds-old.md d/ds-new.md; draft "$L/d/ds-new.md"; page to-ds.md 'see [o](ds-old.md)'
warns to-ds.md 1 "superseded d/ds-old.md, superseded_by d/ds-new.md leads to no accepted doc" "an unfinished successor is not offered as the link"
sup o2.md n2.md; acc "$L/n2.md" internal n2; doc "$L/d/n2.md" obsolete; page to-o2.md 'see [o](o2.md) and [n](../n2.md)'
quiet to-o2.md "superseded_by resolves from the brain root first, as CONVENTIONS.md writes it"
printf 'meta: {profile: smoke}\n' > "$L/schema.local.yaml"; bo lone.md
{ [ "$rc" = 0 ] && ! out_has gate-bergab; } && ok "bergab-old: with the gate off, no finding" || no "bergab-old gate off ($rc: $out)"
rm -rf "$L"

summary smoke || exit 1
