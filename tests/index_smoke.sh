#!/usr/bin/env bash
# Smoke test for the opt-in index-tree check (check_index: true) + the PR #6 review findings.
# Codex: B1 exempt/reserved not content docs; B2 dead-link scan on a docs-less hub.
# Fable (round 2): B3 per-file runs skip the scan; E5 angle-bracket path with space; E7 git-set
#   existence (not disk); E9 dedupe dead links; scheme guard; footnote defs not links.
# Fable 5.1: skip_prefixes must not poison existence; worktree-absent tracked _index must not crash;
#   absolute path root-only; path-form wiki links; refdef angle-bracket target; quote-in-title.
# Cross-folder: a subfolder's _index.md must be linked from its parent's, a folder holding only a
#   subfolder index still needs its own, and the root _index.md is optional.
# Run:  bash tests/index_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/topics" "$T/orphan" "$T/docsonly" "$T/hub/sub" "$T/space" "$T/refs" \
         "$T/vendor" "$T/del" "$T/abs" "$T/wk" "$T/r3" "$T/t4" "$T/pe" "$T/aaa" "$T/coll" \
         "$T/nest/child" "$T/gap/deep"
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
# nest/: the parent index links its doc but not the subfolder's index -> index-incomplete on the parent
doc "$T/nest/n.md"; idx "$T/nest/_index.md" '# Nest\n- [N](n.md)'
doc "$T/nest/child/c.md"; idx "$T/nest/child/_index.md" '# Child\n- [C](c.md)'
# gap/: no index of its own, only a subfolder with one -> index-missing, or gap/deep/ is unreachable
doc "$T/gap/deep/d.md"; idx "$T/gap/deep/_index.md" '# Deep\n- [D](d.md)'

( cd "$T" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m i )
printf '# on disk, not tracked\n' > "$T/refs/untracked.md"   # present on disk, absent from git set
rm "$T/del/_index.md"                                        # tracked, now absent from the worktree

has(){ echo "$out" | grep -q "$1"; }

out="$(cd "$T" && km validate 2>&1)"; rc=$?
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
has "nest/_index.md - does not link nest/child/_index.md" && ok "parent index must link a subfolder index" || no "parent index must link a subfolder index"
has "gap/ - folder has 1 doc" && ok "folder holding only a subfolder index needs its own" || no "folder holding only a subfolder index needs its own"
has "\./ - folder" && no "no root _index.md: top-level folders not required" || ok "no root _index.md: top-level folders not required"

# a root _index.md, once present, must link the top-level folders that have an index
# (aaa/ sorts first: the report prints only the first few entries per category)
idx "$T/_index.md" '# Map\n- [Topics](topics/_index.md)'
( cd "$T" && git add _index.md && git -c user.name=t -c user.email=t@t commit -q -m root )
out="$(cd "$T" && km validate 2>&1)"
has "_index.md - does not link aaa/_index.md" && ok "root _index.md must link top-level indexes" || no "root _index.md must link top-level indexes"
has "does not link topics/_index.md" && no "root link to a top-level index counts" || ok "root link to a top-level index counts"

# Fable B3: a per-file (pre-commit) invocation must NOT run the whole-repo index scan
outf="$(cd "$T" && km validate topics/a.md 2>&1)"
echo "$outf" | grep -q "index-" && no "per-file run skips index scan" || ok "per-file run skips index scan"

# opt-out: no index warnings at all
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: false\n' > "$T/schema.local.yaml"
out="$(cd "$T" && km validate 2>&1)"
has "index-" && no "check off = no index warnings" || ok "check off = no index warnings"

# Fable 5.1 E6: a non-bool check_index is a config error (fail-fast, like gate.enabled)
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: "true"\n' > "$T/schema.local.yaml"
( cd "$T" && km validate >/dev/null 2>"$T/err.txt" ); rcx=$?
{ [ "$rcx" != "0" ] && grep -q "check_index must be true or false" "$T/err.txt"; } \
  && ok "non-bool check_index fails fast" || no "non-bool check_index fails fast"

# Fable 5.1: index_skip_prefixes opts a folder out of the lint (still a valid link target)
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\ncheck_index: true\nindex_skip_prefixes: [orphan/]\n' > "$T/schema.local.yaml"
out="$(cd "$T" && km validate 2>&1)"
has "orphan/" && no "index_skip_prefixes folder is not linted" || ok "index_skip_prefixes folder is not linted"

# gen-index: a title or description YAML reads as a number, a date or a block scalar is listed as text
GI="$T/gi"; mkdir -p "$GI/f"; printf 'meta: {profile: idx}\n' > "$GI/schema.local.yaml"
idx "$GI/f/_index.md" '## Documents'
printf -- '---\ntype: note\ntitle: 2024\ndescription: 1.5\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/y.md"
printf -- '---\ntype: note\ntitle: 2026-11-10\ndescription: >\n  two\n  lines\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/z.md"
printf -- '---\ntype: note\ntitle: >\n  long\n  title\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/w.md"
printf -- '---\ntype: note\ntitle: 0\ndescription: 0\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/v.md"
printf -- '---\ntype: note\ntitle: 1.10\ndescription: 2.50\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/u.md"
printf -- '---\ntype: note\ntitle: false\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$GI/f/s.md"
( cd "$GI" && git init -q && git add -A )
out="$(cd "$GI" && km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -qx -- '- \[2024\](y.md): 1.5' "$GI/f/_index.md" && grep -qx -- '- \[0\](v.md): 0' "$GI/f/_index.md" \
  && grep -qx -- '- \[2026-11-10\](z.md): two lines' "$GI/f/_index.md" && grep -qx -- '- \[long title\](w.md)' "$GI/f/_index.md" \
  && grep -qx -- '- \[1.10\](u.md): 2.50' "$GI/f/_index.md" && grep -qx -- '- \[false\](s.md)' "$GI/f/_index.md"; } \
  && ok "gen-index: a number or date title, a block-scalar title or description, a number as written" || no "gen-index: non-string title ($rc: $out; $(cat "$GI/f/_index.md"))"
out="$(cd "$GI" && git add -A && km gen-index --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "gen-index --check: a number or date title" || no "gen-index --check: non-string title ($rc: $out)"
rm -rf "$GI"

# a bare [[slug]] in an _index.md is a file name, never a glob pattern
GS="$(mktemp -d)"; mkdir -p "$GS/f"
printf 'meta: {profile: idx}\ncheck_index: true\n' > "$GS/schema.local.yaml"
doc "$GS/f/alpha.md"; doc "$GS/f/beta.md"; idx "$GS/f/_index.md" '# F\n- [[alph*]]\n- [[**x**]]'
( cd "$GS" && git init -q && git add -A )
out="$(cd "$GS" && km validate 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! has Traceback && has "does not link f/alpha.md" && has "does not link f/beta.md"; } \
  && ok "index: a [[slug]] with glob characters credits no doc" || no "index: glob slug ($rc: $out)"
idx "$GS/f/_index.md" '# F\n- [[alpha]]\n- [[beta]]'; ( cd "$GS" && git add -A )
out="$(cd "$GS" && km validate 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! has "does not link f/"; } && ok "index: an exact [[slug]] still credits its doc" || no "index: exact slug ($rc: $out)"
# gen-index and serve reject an unknown option and answer --help, writing nothing
idx "$GS/f/_index.md" '## Documents\n\n- stale'; ( cd "$GS" && git add -A ); cp "$GS/f/_index.md" "$GS/idx.bak"
out="$(cd "$GS" && km gen-index --chekc 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && has "unrecognized arguments: --chekc" && cmp -s "$GS/f/_index.md" "$GS/idx.bak"; } \
  && ok "gen-index: an unknown option is a usage error, nothing written" || no "gen-index --chekc ($rc: $out)"
out="$(cd "$GS" && km gen-index --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && has "usage: km gen-index" && has "\-\-check" && cmp -s "$GS/f/_index.md" "$GS/idx.bak"; } \
  && ok "gen-index --help: usage, nothing written" || no "gen-index --help ($rc: $out)"
out="$(cd "$GS" && km gen-index --check 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && has "out of date" && cmp -s "$GS/f/_index.md" "$GS/idx.bak"; } && ok "gen-index --check still checks" || no "gen-index --check ($rc: $out)"
out="$(cd "$GS" && km serve --help 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && has "usage: km serve" && [ ! -e "$GS/dist" ]; } && ok "serve --help: usage, no bundle" || no "serve --help ($rc: $out)"
out="$(cd "$GS" && km serve --out x 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$GS/dist" ]; } && ok "serve: an unknown option is a usage error" || no "serve --out ($rc: $out)"
rm -rf "$GS"

# gen-index creates a missing _index.md from the scaffold (ancestors too), fills its list and stages it,
# only in a brain that already generates a list; --check writes nothing; no scaffold for an odd folder
# name or over anything in the way (an untracked file, a dangling symlink, a tracked index deleted)
GC="$(mktemp -d)"; mkdir -p "$GC/top/mid/leaf" "$GC/odd name" "$GC/busy" "$GC/sym" "$GC/hand" "$GC/gen"
printf 'meta: {profile: idx}\ncheck_index: true\n' > "$GC/schema.local.yaml"
doc "$GC/top/mid/leaf/n.md"; doc "$GC/odd name/o.md"; doc "$GC/busy/b.md"; doc "$GC/sym/s.md"; doc "$GC/hand/h.md"; doc "$GC/gen/g.md"
idx "$GC/hand/_index.md" '# Hand\n\nMy intro.'
( cd "$GC" && git init -q && git add -A && git "${G[@]}" commit -qm i ); rm "$GC/hand/_index.md"
printf 'mine\n' > "$GC/busy/_index.md"; ln -s "$GC/outside.md" "$GC/sym/_index.md"
out="$(cd "$GC" && km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && [ -z "$(git -C "$GC" status --porcelain -- top gen)" ] && [ ! -e "$GC/top/mid/leaf/_index.md" ]; } \
  && ok "gen-index: no scaffold in a brain without a generated list" || no "gen-index, no list ($rc: $out)"
idx "$GC/gen/_index.md" '# Gen\n\n## Documents'; ( cd "$GC" && git add gen/_index.md )
out="$(cd "$GC" && km gen-index --check 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && has "  - top/mid/leaf/" && has "creates one for a folder with a plain name" && [ ! -e "$GC/top/mid/leaf/_index.md" ]; } \
  && ok "gen-index --check: a folder without an _index.md fails, nothing written" || no "gen-index --check, missing ($rc: $out)"
out="$(cd "$GC" && PRE_COMMIT=1 km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && has "stage them and commit again" && [ -f "$GC/top/mid/leaf/_index.md" ] && [ -z "$(git -C "$GC" diff --cached --name-only -- top)" ]; } \
  && ok "gen-index under pre-commit: creates but stages nothing, the commit fails" || no "gen-index PRE_COMMIT ($rc: $out)"
out="$(cd "$GC" && km gen-index 2>&1)"; rc=$?
printf -- '---\ntype: reference\ntitle: "leaf/"\ndescription: "Documents in top/mid/leaf/."\nstatus: draft\ntags: [index]\n---\n\n# leaf\n\n## Documents\n\n- [t](n.md)\n' > "$GC/golden"
staged="$(git -C "$GC" diff --cached --name-only)"
{ [ "$rc" = 1 ] && cmp -s "$GC/top/mid/leaf/_index.md" "$GC/golden" && grep -qx -- '- \[mid/\](mid/_index.md): Documents in top/mid/.' "$GC/top/_index.md" \
  && grep -qx -- '- \[leaf/\](leaf/_index.md): Documents in top/mid/leaf/.' "$GC/top/mid/_index.md" \
  && grep -qx "top/_index.md" <<< "$staged" && grep -qx "top/mid/leaf/_index.md" <<< "$staged" && [ -z "$(git -C "$GC" diff --name-only -- top)" ] \
  && [ ! -e "$GC/odd name/_index.md" ] && has "  - odd name/" && [ "$(cat "$GC/busy/_index.md")" = mine ] && has "  - busy/" \
  && has "  - sym/" && [ ! -e "$GC/outside.md" ] && has "  - hand/" && [ ! -e "$GC/hand/_index.md" ]; } \
  && ok "gen-index: takes back the unstaged scaffolds, stages them in full, parents list them; none for an odd name, an untracked file, a dangling symlink or a deleted tracked index" \
  || no "gen-index create ($rc: $out; $(cat "$GC/top/mid/leaf/_index.md"))"
rm -rf "$GC/odd name" "$GC/busy" "$GC/sym" "$GC/hand"; ( cd "$GC" && git add -A )
out="$(cd "$GC" && km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && has "up to date"; } && ok "gen-index: a rerun changes nothing" || no "gen-index rerun ($rc: $out)"
out="$(cd "$GC" && km gen-index --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "gen-index --check: up to date after creating" || no "gen-index --check after create ($rc: $out)"
rm -rf "$GC"

# dead-link: a link in the body of any tracked .md outside skip_prefixes whose target the git index does
# not list, with check_index off (independent of the index lint); read from km.validate.warnings, since the
# report prints four rows per category
D="$(mktemp -d)"; mkdir -p "$D/a/sub" "$D/a/Folder" "$D/a/_media" "$D/top" "$D/vendor" "$D/mnt"
printf 'meta: {profile: idx}\nskip_prefixes: [vendor/]\n' > "$D/schema.local.yaml"
dl(){ ( cd "$1" && shift && kmpy -P -c 'import contextlib, io, sys
sys.argv = ["km validate", *sys.argv[1:]]
from km import validate
with contextlib.redirect_stdout(io.StringIO()):
    rc = validate.main()
for c, p, d in validate.warnings:
    if c == "dead-link":
        print(f"{p} | {d}")
print(f"rc={rc}")' "$@" 2>&1 ); }
doc "$D/a/ok.md"; doc "$D/a/$(printf 'caf\303\251')1.md"; doc "$D/a/$(printf 'cafe\314\201')2.md"; doc "$D/a/sub/x.md"; doc "$D/a/Folder/f.md"; doc "$D/a/a b.md"; doc "$D/a/p(1).md"; doc "$D/top/t.md"
printf 'PNG\n' > "$D/a/_media/pic.png"; printf 'PDF\n' > "$D/a/doc.pdf"; printf 'skipped: [x](nope13.md)\n' > "$D/vendor/v.md"
mkdir -p "$D/a/my doc (v2)"; doc "$D/a/my doc (v2)/in.md"
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%s\n' \
'[a](ok.md) [b](./ok.md#sec) [c](#top) [d](https://example.com/x.md) [e](mailto:x@example.com) [f](//host/x.md)
[g](../top/) [h](..) [i](.) [j](/a/ok.md) [k](a%20b.md) [l](<a b.md>) [m](p(1).md) [n](ok.md "title") [o](ok.md?x=1)
[p [q] r](ok.md) ![s](_media/pic.png) [u](doc.pdf) [v](../vendor/v.md) [w](../mnt) [x](../mnt/m.md) [y](../emp/any.md)
<img data-src="nope1.md" src="_media/pic.png"> `[z](nope2.md)` <!-- [z](nope3.md) -->

```
[z](nope4.md)
```

~~~
[z](nope5.md)
~~~

[^1]: nope6.md
[label]: nope8.md is prose, not a definition
[[nope7]] [t](../top/t.md "it'\''s") [root fallback](top/t.md)
'"[nfd link to an nfc name]($(printf 'cafe\314\201')1.md) [nfc link to an nfd name]($(printf 'caf\303\251')2.md)" > "$D/a/good.md"
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%s\n' \
'[1](gone1.md) [1 again](gone1.md) ![2](_media/gone2.png) [3](OK.md) [4](folder/f.md) [5](ok) [6](../../gone3.md)
[7](sub\x.md) [![8](_media/gone4.png)](ok.md) <img src=gone6.png> <a href='\''gone7.md'\''>11</a>
[12](untracked8.md) [13](../mnt/gone9.md) [14](sub\_gone12.md)

[r]: gone5.md "a title"' > "$D/a/bad.md"
printf -- '---\ntype: note\ntitle: t\ndescription: "[x](nope12.md)"\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%s\n' \
'[a](ok.md (t)) [b](my doc (v2)) [c](ok.md
"title") [d](ok.md
) [e](../mnt/inner/deep.md) [f](../mnt/inner/)

    [indented](nope9.md)

``[dbl `x` ](nope10.md)``

```
[unclosed](nope11.md)' > "$D/a/good2.md"
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%s\n' \
'[m1](file:///etc/hosts) [m2](C:\Users\x\doc.md) [m3](C:/x/doc.md) [m4](~/notes/x.md) [m5](/Users/someone/x.md)
[n1](gone13.md
"title") [n2](gone14.md
) [t](ok.md/)' > "$D/a/bad2.md"
printf '# A\n- [Gone](gone10.md)\n' > "$D/a/_index.md"
printf '# readme\n[x](a/gone11.md)\n' > "$D/README.md"
git init -q "$D/mnt" && doc "$D/mnt/m.md" && git -C "$D/mnt" add -A && git -C "$D/mnt" "${G[@]}" commit -qm m \
  && git -C "$D/mnt" update-index --add --cacheinfo "160000,$(git -C "$D/mnt" rev-parse HEAD),inner" \
  && git -C "$D/mnt" "${G[@]}" commit -qm inner   # a mount with a mount of its own
( cd "$D" && git init -q && git config core.precomposeunicode false \
  && git -c advice.addEmbeddedRepo=false add -A 2>/dev/null && mkdir emp \
  && git update-index --add --cacheinfo "160000,$(git -C mnt rev-parse HEAD),emp" && git "${G[@]}" commit -qm i )
printf '# on disk, not tracked\n' > "$D/a/untracked8.md"
out="$(dl "$D")"
dead(){ grep -qxF "$1" <<< "$out" && ok "dead-link: $2" || no "dead-link: $2 ($out)"; }
dead "a/bad.md | links missing gone1.md" "a missing .md"
dead "a/bad.md | links missing _media/gone2.png" "a missing image in _media/"
dead "a/bad.md | links missing OK.md: differs only in case from a/ok.md" "a file in the wrong case"
dead "a/bad.md | links missing folder/f.md: differs only in case from a/Folder/f.md" "a folder in the wrong case"
dead "a/bad.md | links missing ok: add .md" "a target without .md"
dead "a/bad.md | links missing ../../gone3.md: leaves the repository" "a path out of the repository"
grep -q '^a/bad.md | links missing sub\\x.md: .*backslash' <<< "$out" && ok "dead-link: a backslash path" || no "dead-link: backslash ($out)"
dead "a/bad.md | links missing sub_gone12.md" "a Markdown escape is no backslash"
M=": a path on one machine: link a file in the brain or write the path as text"
dead "a/bad2.md | links missing file:///etc/hosts$M" "a file: URL"
dead "a/bad2.md | links missing C:\\Users\\x\\doc.md$M" "a Windows path with backslashes"
dead "a/bad2.md | links missing C:/x/doc.md$M" "a Windows path with slashes"
dead "a/bad2.md | links missing ~/notes/x.md$M" "a home folder path"
dead "a/bad2.md | links missing /Users/someone/x.md$M" "an absolute machine path"
dead "a/bad2.md | links missing gone13.md" "a title on the next line"
dead "a/bad2.md | links missing gone14.md" "the ) on the next line"
dead "a/bad2.md | links missing ok.md/" "a trailing / on a file"
[ "$(grep -c '^a/bad2.md' <<< "$out")" = 8 ] && ok "dead-link: nothing else in the second faulty doc" || no "dead-link: extra findings 2 ($out)"
grep -q '^a/good2.md\|^vendor/' <<< "$out" && no "dead-link: valid forms 2 stay silent ($out)" \
  || ok "dead-link: a paren title, a target with ( ), next-line titles, a mount inside a mount, indented and double-backtick code, an unclosed fence, the frontmatter and a skip_prefixes doc stay silent"
dead "a/bad.md | links missing _media/gone4.png" "a dead image nested in a link"
dead "a/bad.md | links missing gone5.md" "a dead reference definition"
dead "a/bad.md | links missing gone6.png" "a dead unquoted <img src>"
dead "a/bad.md | links missing gone7.md" "a dead <a href='...'>"
dead "a/bad.md | links missing untracked8.md" "a file on disk git does not track"
dead "a/bad.md | links missing ../mnt/gone9.md" "a file a checked-out mount lacks"
dead "a/_index.md | links missing gone10.md" "an _index.md with check_index off"
dead "README.md | links missing a/gone11.md" "a README"
[ "$(grep -c 'links missing gone1.md' <<< "$out")" = 1 ] && ok "dead-link: a target linked twice is one finding" || no "dead-link dedupe ($out)"
[ "$(grep -c '^a/bad.md' <<< "$out")" = 14 ] && ok "dead-link: nothing else in the faulty doc" || no "dead-link: extra findings ($out)"
grep -q '^a/good.md' <<< "$out" && no "dead-link: valid links stay silent ($out)" || ok "dead-link: valid links, code, comments, footnotes and [[wiki]] stay silent"
grep -qx "rc=0" <<< "$out" && ok "dead-link: a warning, the exit code stays 0" || no "dead-link exit code ($out)"
km validate --root "$D" >/dev/null 2>&1 && ok "dead-link: km validate exits 0" || no "dead-link: km validate exit code"
[ "$(dl "$D/a/sub")" = "$out" ] && ok "dead-link: a run from a subfolder finds the same" || no "dead-link: subfolder run ($(dl "$D/a/sub"))"
outf="$(dl "$D" README.md)"
[ "$outf" = "$(printf 'README.md | links missing a/gone11.md\nrc=0')" ] && ok "dead-link: a per-file run checks only the given file" || no "dead-link per file ($outf)"
rm -rf "$D"
# index: a target without .md credits the doc of that name before a folder the root fallback finds
D="$(mktemp -d)"; mkdir -p "$D/x" "$D/y" "$D/tools" "$D/z" "$D/w"
printf 'meta: {profile: idx}\ncheck_index: true\n' > "$D/schema.local.yaml"
doc "$D/x/tools.md"; doc "$D/y/tools.md"; doc "$D/tools/t.md"; idx "$D/tools/_index.md" '# Tools\n- [T](t.md)'
idx "$D/x/_index.md" '# X\n- [[tools]]'; idx "$D/y/_index.md" '# Y\n- [T](tools)'
doc "$D/z/zz.md"; idx "$D/z/_index.md" '# Z\n- [Z](zz.md\n  "a title")'          # a title on the next line
doc "$D/w/Page (2024).md"; idx "$D/w/_index.md" '# W\n- [[Page (2024)]]'           # ( ) in a wiki target is no title
( cd "$D" && git init -q && git add -A )
out="$(cd "$D" && km validate 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! has "does not link x/tools.md" && ! has "does not link y/tools.md"; } \
  && ok "index: a doc by its name wins over a folder of that name" || no "index: doc over folder ($rc: $out)"
{ ! has "does not link z/zz.md" && ! has "dead-link"; } && ok "index: a link with its title on the next line credits the doc" || no "index: next-line title ($out)"
! has "does not link w/Page (2024).md" && ok "index: [[Page (2024)]] credits its doc" || no "index: wiki parens ($out)"
rm -rf "$D"


summary index-smoke || exit 1
