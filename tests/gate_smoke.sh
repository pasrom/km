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
doc(){ # doc FILE STATUS "extra frontmatter lines"; TYPE=, AUD= override, RB= (empty) drops review_by
  local rb="${RB-2027-01-01}"
  printf -- '---\ntype: %s\ntitle: t\ntimestamp: 2026-09-30\nauthor: X\nstatus: %s\naudience: %s\nlanguage: en\ntags: [t]\nowner: X\n%b%b---\nbody\n' \
    "${TYPE:-concept}" "$2" "${AUD:-internal}" "${rb:+review_by: $rb\n}" "${3:-}" > "$1"; }
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
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"; printf 'status_rules:\n  accepted_requires: [review_by]\n' >> "$T/schema.local.yaml"
RB= doc "$T/ap/a8.md" accepted 'approved_by: RPA\napproved_at: 2026-09-30\n'
V "$T/ap/a8.md" && no "accepted_requires: a missing field fails" || ok "accepted_requires: a missing field fails"
V "$T/ap/a6.md" && ok "accepted_requires: a doc with the field passes" || no "accepted_requires: a doc with the field passes"
printf 'meta: {profile: smoke}\ngate:\n  enabled: true\n  served_status: published\nfields:\n  status:\n    enum: [draft, review, published, superseded, obsolete]\n' > "$T/schema.local.yaml"
doc "$T/ap/a9.md" published 'approved_by: "ai:model-x"\napproved_at: 2026-09-30\n'
km validate --root "$T" "$T/ap/a9.md" 2>&1 | grep -q "an AI approver needs" && ok "approval: the rule follows a renamed served status" || no "approval: the rule follows a renamed served status"
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
AUD=customer doc "$T/ap/p3.md" review ''
km approve --root "$T" "$T/ap/p3.md" --by ai:model-x 2>&1 | grep -q "needs a human approver" \
  && ok "approve: ai: refused on a customer doc" || no "approve: ai: refused on a customer doc"
km approve --root "$T" "$T/ap/p2.md" --by RPA >/dev/null 2>&1 && grep -q '^approved_by: "RPA"$' "$T/ap/p2.md" \
  && ok "approve: a human signs off a default doc" || no "approve: a human signs off a default doc"
doc "$T/ap/p4.md" draft ''
km approve --root "$T" "$T/ap/p4.md" --by RPA 2>&1 | grep -q "only a review doc" && grep -q '^status: draft$' "$T/ap/p4.md" \
  && ok "approve: a draft is refused" || no "approve: a draft is refused"
RB= doc "$T/ap/p5.md" review ''; cp "$T/ap/p5.md" "$T/p5.bak"
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
RB= doc "$T/ap/p7.md" review ''; { printf '\357\273\277'; cat "$T/ap/p7.md"; } > "$T/p7.tmp" && mv "$T/p7.tmp" "$T/ap/p7.md"; cp "$T/ap/p7.md" "$T/p7.bak"
km approve --root "$T" "$T/ap/p7.md" --by RPA 2>&1 | grep -q "km validate fails" && cmp -s "$T/ap/p7.md" "$T/p7.bak" \
  && ok "approve: a refused doc keeps its bytes, BOM included" || no "approve: a refused doc keeps its bytes, BOM included"
printf '%s' "$BASE_LOCAL" > "$T/schema.local.yaml"

# promote drops reviewed_by (new doc and --replace); a cross-repo promote also drops approval
printf -- '---\ntype: note\ntitle: R\ntimestamp: 2026-09-30\nauthor: X\nstatus: draft\ntags: [t]\napproval: ai\nreviewed_by: ["model-x 2026-09-30 (PR #1)"]\n---\nbody\n' > "$T/inbox/rv.md"
km promote --root "$T" rv-topic "$T/inbox/rv.md" --folder ap >/dev/null 2>&1
{ [ -f "$T/ap/rv-topic.md" ] && ! grep -q '^reviewed_by:' "$T/ap/rv-topic.md" && grep -q '^approval: ai' "$T/ap/rv-topic.md"; } \
  && ok "promote: drops reviewed_by, keeps approval in the same brain" || no "promote: drops reviewed_by, keeps approval in the same brain"
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

summary smoke || exit 1
