#!/usr/bin/env bash
# Smoke test for the opt-in index-tree check (check_index: true) + the PR #6 review findings.
# Codex: B1 exempt/reserved not content docs; B2 dead-link scan on a docs-less hub.
# Fable (round 2): B3 per-file runs skip the scan; E5 angle-bracket path with space; E7 git-set
#   existence (not disk); E9 dedupe dead links; scheme guard; footnote defs not links.
# Fable 5.1: skip_prefixes must not poison existence; worktree-absent tracked _index must not crash;
#   absolute path root-only; path-form wiki links; refdef angle-bracket target; quote-in-title.
# Run:  bash skills/km/tests/index_smoke.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KM="$(dirname "$HERE")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/topics" "$T/orphan" "$T/docsonly" "$T/hub/sub" "$T/space" "$T/refs" \
         "$T/vendor" "$T/del" "$T/abs" "$T/wk" "$T/r3" "$T/t4" "$T/pe" "$T/aaa" "$T/coll"
cp "$KM/validate.py" "$T/scripts/validate.py"
cp "$KM/schema.base.yaml" "$T/schema.base.yaml"
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: true\n' > "$T/schema.local.yaml"

doc(){ printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$1"; }
idx(){ printf -- '---\ntype: reference\ntitle: idx\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%b\n' "$2" > "$1"; }

# topics/: docs a + b + exempt README; index links a and a DEAD c.md TWICE (dedupe), an external .md,
# a footnote def, and a relative link INTO the skip_prefixes folder vendor/ (must resolve, B1).
doc "$T/topics/a.md"; doc "$T/topics/b.md"; printf '# readme\n' > "$T/topics/README.md"
idx "$T/topics/_index.md" '# Topics\n- [A](a.md)\n- [Gone](c.md)\n- [Gone again](c.md)\n- [Ext](https://example.com/x.md)\n- [V](../vendor/x.md)\n\n[^1]: see notes.md later'
printf 'skipped content, still tracked\n' > "$T/vendor/x.md"     # under skip_prefixes: not linted, but tracked (B1)
# orphan/: a real doc, no _index -> index-missing
doc "$T/orphan/x.md"
# docsonly/: only an exempt README, no _index -> must NOT be index-missing
printf '# readme\n' > "$T/docsonly/README.md"
# hub/: navigation hub, no direct docs, a dead link; subfolder owns its own (complete) index
idx "$T/hub/_index.md" '# Hub\n- [sub](sub/_index.md)\n- [Gone](nope.md)'
doc "$T/hub/sub/y.md"; idx "$T/hub/sub/_index.md" '# Sub\n- [Y](y.md)'
# space/: angle-bracket link to a filename containing a space -> resolved (E5)
doc "$T/space/my doc.md"; idx "$T/space/_index.md" '# Space\n- [My](<my doc.md>)'
# refs/: links a file created on disk but NEVER tracked -> dead via git set, not disk (E7)
idx "$T/refs/_index.md" '# Refs\n- [U](untracked.md)'
# del/: a tracked _index.md that will be removed from the worktree -> warning, no crash (Fable 5.1 B2)
doc "$T/del/d.md"; idx "$T/del/_index.md" '# Del\n- [D](d.md)'
# abs/: an ABSOLUTE link must resolve at the root, not folder-local (Fable 5.1 E1)
doc "$T/abs/a.md"; idx "$T/abs/_index.md" '# Abs\n- [Root](/a.md)'
# wk/: a path-form wiki link must resolve (Fable 5.1 E2)
doc "$T/wk/p.md"; idx "$T/wk/_index.md" '# Wk\n- [[./p]]'
# r3/: a reference-def with an angle-bracketed spaced target must resolve (Fable 5.1 E3)
doc "$T/r3/my doc.md"; idx "$T/r3/_index.md" '# R3\n\n[d]: <my doc.md>'
# t4/: a title containing the other quote char must still be stripped (Fable 5.1 E4)
doc "$T/t4/a.md"; idx "$T/t4/_index.md" '# T4\n- [A](a.md "It'\''s here")'
# pe/: a percent-encoded target must decode and resolve
doc "$T/pe/a b.md"; idx "$T/pe/_index.md" '# Pe\n- [P](a%20b.md)'
# aaa/ + coll/: a bare [[slug]] must credit the folder-local file, not an alphabetically-earlier peer
doc "$T/aaa/y.md"; idx "$T/aaa/_index.md" '# Aaa\n- [Y](y.md)'
doc "$T/coll/y.md"; idx "$T/coll/_index.md" '# Coll\n- [[y]]'

( cd "$T" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m i )
printf '# on disk, not tracked\n' > "$T/refs/untracked.md"   # present on disk, absent from git set
rm "$T/del/_index.md"                                        # tracked, now absent from the worktree

pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ echo "$out" | grep -q "$1"; }

out="$(cd "$T" && python3 scripts/validate.py 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "clean exit (warnings never fail, no crash)" || no "clean exit (rc=$rc)"          # B2 no crash
has "does not link topics/b.md" && ok "incomplete index flagged (missing sibling)" || no "incomplete index flagged (missing sibling)"
has "links missing c.md"        && ok "dead index link flagged"                    || no "dead index link flagged"
{ has "index-missing" && has "orphan/"; } && ok "folder without _index flagged" || no "folder without _index flagged"
has "topics/README.md" && no "exempt README not required by index"   || ok "exempt README not required by index"        # Codex B1
has "docsonly/"        && no "exempt-only folder not flagged missing" || ok "exempt-only folder not flagged missing"    # Codex B1
has "links missing nope.md" && ok "hub _index dead-link scanned (no direct docs)" || no "hub _index dead-link scanned (no direct docs)"  # Codex B2
{ has "hub/ - folder" || echo "$out" | grep -q "hub/_index.md - does not link"; } && no "hub not falsely missing/incomplete" || ok "hub not falsely missing/incomplete"
[ "$(echo "$out" | grep -c 'links missing c.md')" = "1" ] && ok "duplicate dead links deduped" || no "duplicate dead links deduped"      # Fable E9
has "does not link space/my doc.md" && no "angle-bracket path with space resolves" || ok "angle-bracket path with space resolves"        # Fable E5
has "links missing untracked.md" && ok "existence checked against git set, not disk" || no "existence checked against git set, not disk" # Fable E7
has "example.com" && no "external .md link is not a dead repo link" || ok "external .md link is not a dead repo link"                     # scheme guard
has "links missing notes.md" && no "footnote def is not a fabricated dead link" || ok "footnote def is not a fabricated dead link"        # REFDEF ^ skip
{ has "vendor/x.md"; } && no "link into skip_prefixes folder is not dead" || ok "link into skip_prefixes folder is not dead"             # Fable 5.1 B1
has "absent from the worktree" && ok "worktree-absent tracked _index warns (no crash)" || no "worktree-absent tracked _index warns (no crash)"  # Fable 5.1 B2
has "does not link abs/a.md" && ok "absolute link resolves at root, not folder-local" || no "absolute link resolves at root, not folder-local"  # Fable 5.1 E1
has "does not link wk/p.md"  && no "path-form wiki link resolves" || ok "path-form wiki link resolves"                                   # Fable 5.1 E2
has "does not link r3/my doc.md" && no "refdef angle-bracket spaced target resolves" || ok "refdef angle-bracket spaced target resolves" # Fable 5.1 E3
has "does not link t4/a.md" && no "quote-in-title is stripped" || ok "quote-in-title is stripped"                                        # Fable 5.1 E4
has "does not link pe/a b.md" && no "percent-encoded target resolves" || ok "percent-encoded target resolves"                            # percent-decode
has "does not link coll/y.md" && no "bare wiki slug prefers folder-local over alpha-first peer" || ok "bare wiki slug prefers folder-local over alpha-first peer"  # slug collision

# Fable B3: a per-file (pre-commit) invocation must NOT run the whole-repo index scan
outf="$(cd "$T" && python3 scripts/validate.py topics/a.md 2>&1)"
echo "$outf" | grep -q "index-" && no "per-file run skips index scan" || ok "per-file run skips index scan"

# opt-out: no index warnings at all
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: false\n' > "$T/schema.local.yaml"
out="$(cd "$T" && python3 scripts/validate.py 2>&1)"
has "index-" && no "check off = no index warnings" || ok "check off = no index warnings"

# Fable 5.1 E6: a non-bool check_index is a config error (fail-fast, like gate.enabled)
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: "true"\n' > "$T/schema.local.yaml"
( cd "$T" && python3 scripts/validate.py >/dev/null 2>"$T/err.txt" ); rcx=$?
{ [ "$rcx" != "0" ] && grep -q "check_index must be true or false" "$T/err.txt"; } \
  && ok "non-bool check_index fails fast" || no "non-bool check_index fails fast"

# Fable 5.1: index_skip_prefixes opts a folder out of the lint (still a valid link target)
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: true\nindex_skip_prefixes: [orphan/]\n' > "$T/schema.local.yaml"
out="$(cd "$T" && python3 scripts/validate.py 2>&1)"
has "orphan/" && no "index_skip_prefixes folder is not linted" || ok "index_skip_prefixes folder is not linted"

echo "index-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
