#!/usr/bin/env bash
# Smoke test for `km ready`: a km:ready label someone other than the author applied counts; one the
# author applied counts only when no control file (nor a symlink or submodule) changed and every changed
# doc is at level ai at the head and at the base (an _index.md whose intro is unchanged aside), with the
# base's approval_default and field aliases; anything unread or undecided does not.
# GitHub is a stand-in gh on PATH that serves the files of a fake pull request.
# Run:  bash tests/ready_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo "  FAIL: ready_smoke needs jq (its stand-in gh applies --jq with it)"; exit 1; }
git init -q "$T/brain"
mkdir -p "$T/bin" "$T/gh/blobs" "$T/gh/trees"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# serves $FAKE as the GitHub API, with --jq applied by jq as gh does: pull (the pull request; from its
# second read on pull.next where that exists), events, compare, schema (schema.local.yaml at the base),
# blobs/<sha>, base/<path> (a doc at the base), trees/<sha> (setup serves an empty tree for the head and
# the base); a missing file is a 404, with <file>.fail beside it
# the call fails otherwise, and <file>.raw is served as it is, --jq or not
jqx=""; prev=""
for a in "$@"; do case "$a" in repos/*) p="$a";; esac; [ "$prev" = --jq ] && jqx="$a"; prev="$a"; done
echo "$p" >> "$FAKE/calls"
case "$p" in
  repos/o/r/pulls/9) f=pull; [ -f "$FAKE/pull.next" ] && [ -f "$FAKE/pull.read" ] && f=pull.next; touch "$FAKE/pull.read";;
  repos/o/r/issues/9/events) f=events; [ -f "$FAKE/events.next" ] && [ -f "$FAKE/events.read" ] && f=events.next; touch "$FAKE/events.read";;
  repos/o/r/compare/*) f=compare;;
  repos/o/r/contents/schema.local.yaml\?ref=*) f=schema;;
  repos/o/r/git/blobs/*) f="blobs/${p##*/}";;
  repos/o/r/git/trees/*) f="trees/${p##*/}"; f="${f%%\?*}";;
  repos/o/r/contents/schema.yaml\?ref=*) f=legacy;;
  repos/o/r/contents/*\?ref=*) p="${p#repos/o/r/contents/}"; p="${p%%\?*}"; f="base/$(printf '%b' "${p//%/\\x}")";;
  *) exit 1;;
esac
[ -f "$FAKE/$f.raw" ] && { cat "$FAKE/$f.raw"; exit 0; }
[ -f "$FAKE/$f.fail" ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
[ -f "$FAKE/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$jqx" ]; then jq -r "$jqx" "$FAKE/$f"; else cat "$FAKE/$f"; fi
GH
chmod +x "$T/bin/gh"
F="$T/gh"
HEAD=$(printf 'a%.0s' {1..40}); BASE=$(printf 'b%.0s' {1..40}); OTHER=$(printf 'c%.0s' {1..40}); MB=$(printf 'd%.0s' {1..40})   # MB: the merge base
sha(){ printf '%040d' "$1"; }
# blob N FRONTMATTER: a doc at blob id N
blob(){ printf -- '---\ntype: note\ntitle: "T"\nstatus: review\n%b---\nbody\n' "$2" > "$F/blobs/$(sha "$1")"; }
AI='audience: internal\napproval: ai\n'
blob 1 "$AI"
blob 2 'audience: internal\napproval: human\n'
blob 3 'audience: internal\n'                       # level from approval_default
blob 4 'approval: ai\n'                             # audience not written out
blob 5 'audience: internal\napproval: ai\ntype: verbatim-block\n'
blob 6 'audience: internal\nappr: human\n'          # an alias of approval
blob 7 'audience: internal\napproval: ai\ntags: &x [a]\n'
printf '# no frontmatter\n' > "$F/blobs/$(sha 8)"
printf -- '---\naudience: internal\napproval: [ai\n---\nbody\n' > "$F/blobs/$(sha 9)"
# _index.md files: 20 at level ai, 21 another intro, 22 another list; 30 at level human, 31 another
# list, 32 another list and a later section changed by hand
index(){ printf -- '---\n%bstatus: review\n---\n%s\n\n## Documents\n\n%b\n\n## Notes\n\n%s\n' "$2" "$3" "$4" "$5" > "$F/blobs/$(sha "$1")"; }
index 20 "$AI" Intro. '- [a](a.md)' Kept.
index 21 "$AI" 'Other intro.' '- [a](a.md)' Kept.
index 22 "$AI" Intro. '- [a](a.md)\n- [b](b.md)' Kept.
HU='audience: internal\napproval: human\n'
index 30 "$HU" Intro. '- [a](a.md)' Kept.
index 31 "$HU" Intro. '- [a](a.md)\n- [b](b.md)' Kept.
index 32 "$HU" Intro. '- [a](a.md)\n- [b](b.md)' 'Changed by hand.'
index 33 "$HU" 'Other intro.' '- [a](a.md)' Kept.
# file PATH BLOB [STATUS [PREVIOUS]]: one line of the file list; the base holds PREVIOUS (else PATH)
# as BLOB unless STATUS is added (base PATH BLOB sets another)
base(){ mkdir -p "$(dirname "$F/base/$1")"; cp "$F/blobs/$(sha "$2")" "$F/base/$1" 2>/dev/null; }
file(){ [ "${3:-}" = added ] || base "${4:-$1}" "$2"
  printf '{"filename":"%s","status":"%s","sha":"%s"%s}\n' "$1" "${3:-modified}" "$(sha "$2")" "${4:+,\"previous_filename\":\"$4\"}"; }
# label ACTOR [APP]: the km:ready events, Maint's and then ACTOR's (JSON, see actor; APP: the app it acted through)
label(){ printf '[%s,%s]\n' '{"event":"labeled","label":{"name":"km:ready"},"actor":{"login":"Maint","type":"User"}}' \
  "{\"event\":\"labeled\",\"label\":{\"name\":\"km:ready\"},\"actor\":$1,\"performed_via_github_app\":${2:-null}}" > "$F/events"; }
actor(){ printf '{"login":"%s","type":"%s"}' "$1" "${2:-User}"; }
# tree SHA [JSON-ENTRIES [TRUNCATED]]: the tree of a commit (its entries with path and mode)
tree(){ printf '{"truncated":%s,"tree":[%s]}\n' "${3:-false}" "${2:-}" > "$F/trees/$1"; }
pull(){ printf '{"user":{"login":"Alice"},"head":{"sha":"%s"},"base":{"sha":"%s"},"changed_files":%s}\n' "$HEAD" "$BASE" "$1"; }
# setup FILES-LINES [LABELLED-BY [CHANGED-FILES]]: the pull request by Alice, labelled last by LABELLED-BY
# (default: alice), with CHANGED-FILES as its file count (default: the lines given)
setup(){
  rm -f "$F/calls" "$F/schema" "$F/schema.fail" "$F/pull.next" "$F/events.next" "$F/compare" "$F/compare.raw" "$F"/trees/*
  tree "$HEAD"; tree "$MB"; tree "$BASE"
  printf '%s' "$1" | jq -s --arg mb "$MB" '{merge_base_commit: {sha: $mb}, files: .}' > "$F/compare"
  pull "${3:-$(grep -c . <<< "$1")}" > "$F/pull"
  label "$(actor "${2:-alice}")"
}
R(){ rm -f "$F/pull.read" "$F/events.read"; out="$(cd "$T/brain" && FAKE="$F" PATH="$T/bin:$PATH" km ready o/r 9 "$@" 2>&1)"; rc=$?; }
counts(){ R "$@"; [ "$rc" = 0 ] && [[ "$out" == counts:* ]]; }
refused(){ R "$@"; [ "$rc" = 1 ] && [[ "$out" == "does not count:"* ]]; }

setup "$(file a.md 2)" Maint
counts && ! grep -q blobs "$F/calls" && grep -q "applied by Maint, not the author" <<< "$out" \
  && ok "a label someone other than the author applied counts, without reading a doc" || no "other's label ($rc: $out)"

setup "$(file a.md 1; file a/_index.md 22; base a/_index.md 20; file b.md 1 added)"
counts && ok "the author's label counts when every changed doc is at level ai (an _index.md whose list alone changed aside)" || no "author, all ai ($rc: $out)"
setup "$(file a.md 1; file a/_index.md 33; base a/_index.md 30)"
refused && grep -q "_index.md is an index changed beyond its list" <<< "$out" && ok "...an _index.md changed beyond its list is level human, km validate checks no sign-off on it" || no "index intro ($rc: $out)"
bad=""
setup "$(file a.md 1; file a/_index.md 21; base a/_index.md 20)"; refused || bad+=" intro-ai"
setup "$(file a.md 1; file a/_index.md 20 added)"; refused || bad+=" new-index-ai"
setup "$(file a.md 1; file a/_index.md 31; base a/_index.md 30)"; counts || bad+=" list-only"
setup "$(file a.md 1; file a/_index.md 32; base a/_index.md 30)"; refused || bad+=" tail"
setup "$(file a.md 1; file a/_index.md 30 renamed a/doc.md)"; refused || bad+=" doc-to-index"
setup "$(file a.md 1; file a/notes.md 20 renamed a/_index.md)"; refused && grep -q "moved index" <<< "$out" || bad+=" index-to-doc"
setup "$(file a.md 1; file b/_index.md 30 renamed a/_index.md)"; refused || bad+=" index-moved"
setup "$(file a.md 1; file a/_index.md 31; base a/_index.md 30)"; printf 'index_skip_prefixes: [a/]\n' > "$F/schema"; refused || bad+=" index-skip"
sed 's/^status: review$/## Documents\nstatus: review/' "$F/blobs/$(sha 30)" > "$F/base/x.md"   # a heading-like line in the frontmatter
sed 's/^status: review$/## Documents\nstatus: review/; s/^Intro.$/Other intro./' "$F/blobs/$(sha 30)" > "$F/blobs/$(sha 34)"
setup "$(file a.md 1; file a/_index.md 34)"; cp "$F/base/x.md" "$F/base/a/_index.md"; refused || bad+=" fm-heading"
sed 's/^Intro.$/Intro.\n## Documents\r/' "$F/blobs/$(sha 30)" > "$F/base/x.md"   # gen-index reads a heading there
sed 's/^Intro.$/Intro.\n## Documents\r/' "$F/blobs/$(sha 31)" > "$F/blobs/$(sha 35)"
setup "$(file a.md 1; file a/_index.md 35)"; cp "$F/base/x.md" "$F/base/a/_index.md"; refused || bad+=" crlf"
printf '\357\273\277' | cat - "$F/blobs/$(sha 30)" > "$F/base/x.md"; printf '\357\273\277' | cat - "$F/blobs/$(sha 31)" > "$F/blobs/$(sha 36)"
setup "$(file a.md 1; file a/_index.md 36)"; cp "$F/base/x.md" "$F/base/a/_index.md"; refused || bad+=" bom"
[ -z "$bad" ] && ok "...level human beyond its list whatever its frontmatter (a changed intro at ai, a new one at ai with a later section), and left aside, even at level human, only when the list alone changed, not a later section, not under index_skip_prefixes, not with a heading-like line in its frontmatter, a BOM or CRLF line ends (gen-index reads those away), nor when it moved, became a doc or a doc became one" || no "index rules:$bad"
setup "$(file a.md 1)"; base a.md 2
refused && grep -q "level human at the base" <<< "$out" && ok "...and a doc the pull request lowered from level human does not count" || no "lowered ($rc: $out)"
setup "$(file a.md 1)"; rm "$F/base/a.md"
refused && ok "...nor one whose base text cannot be read" || no "base unread ($rc: $out)"
setup "$(file a.md 1)"; counts --head "$HEAD" && ok "...and at the head the queue saw" || no "author, --head ($rc: $out)"
refused --head "$BASE" && grep -q "head moved" <<< "$out" && ok "...not when the head moved" || no "head moved ($rc: $out)"

setup "$(file a.md 1; file b.md 2)"
refused && grep -q "b.md is at level human" <<< "$out" && ok "a doc at level human makes the author's label not count" || no "author, human doc ($rc: $out)"
setup "$(file a.md 2)" ALICE
refused && ok "...whatever the case of the author's login" || no "login case ($rc: $out)"

setup "$(file a.md 3)"
refused && ok "a doc with no level of its own is at the base's approval_default: human by default" || no "default human ($rc: $out)"
printf 'approval_default: ai\n' > "$F/schema"
counts && ok "...ai where schema.local.yaml at the base sets approval_default: ai" || no "default ai ($rc: $out)"
grep -q "contents/schema.local.yaml?ref=$BASE" "$F/calls" && ok "...read at the base commit" || no "schema ref ($(cat "$F/calls"))"
setup "$(file a.md 6)"; printf 'approval_default: ai\nfields:\n  approval: {alias: appr}\n' > "$F/schema"
refused && ok "...and a field alias the base declares is applied (appr: human)" || no "alias ($rc: $out)"
bad=""
setup "$(file a.md 1)"; touch "$F/schema.fail"; refused && grep -q "could not be read" <<< "$out" || bad+=" failed"
setup "$(file a.md 1)"; printf 'fields: [\n' > "$F/schema"; refused || bad+=" unparseable"
setup "$(file a.md 1)"; printf -- '- a\n' > "$F/schema"; refused || bad+=" list"
[ -z "$bad" ] && ok "no count when schema.local.yaml at the base fails to read (not a 404), does not parse or is no mapping" || no "schema:$bad"

bad=""
for n in 4 5 7 8 9; do setup "$(file a.md "$n")"; refused || bad+=" $n"; done
setup "$(file a.md 12345)"; refused || bad+=" unread"
[ -z "$bad" ] && ok "level human, so no count: audience not written out, a verbatim-block, a YAML anchor, no or unparseable frontmatter, an unread doc" \
  || no "fail closed:$bad"

bad=""
setup "$(file a.md 1 removed)"; refused && grep -q "removes a.md" <<< "$out" || bad+=" removed"
setup "$(file brains/x.md 1 renamed a.md)"; refused && grep -q "out of the docs" <<< "$out" || bad+=" moved-out"
setup "$(file a.md 1; file a/b.md 1 renamed a/b.txt)"; refused && grep -q "into the docs" <<< "$out" || bad+=" moved-in"
setup "$(file a.md 1; file brains/p/_index.md 20)"; refused && grep -q "index outside the docs" <<< "$out" || bad+=" mounted-index"
setup "$(file a.md 1; file x/_index.md 20 renamed README.md)"; refused || bad+=" readme-to-index"
setup "$(file a/_index.md 22; base a/_index.md 20)"; refused && grep -q "changes no doc" <<< "$out" || bad+=" no-doc"
setup "$(file a/a.png 1)"; refused && grep -q "changes no doc" <<< "$out" || bad+=" image-only"
[ -z "$bad" ] && ok "no count for a removed doc, a doc moved out of the docs or a file moved into them, an _index.md under a mount or moved from a README, and no doc changed (an image alone included)" \
  || no "changes:$bad"

# Files next to the pages do not stop the author's label; a control file does, on either side of a rename
bad=""
for f in a/a.png a/diagram.svg a/report.pdf _media/x.py a/data.csv a/README.md a/SKILL.md a/Makefile brains/notes.txt \
         a/_media/.gitkeep a/.DS_Store; do
  setup "$(file a.md 1; file "$f" 1)"; counts || bad+=" $f"
done
setup "$(file a.md 1; file a/old.png 1 removed)"; counts || bad+=" removed-image"
setup "$(file a.md 1; file a/new.png 1 renamed a/old.png)"; counts || bad+=" renamed-image"
[ -z "$bad" ] && ok "the author's label counts with an image, an SVG, a PDF, a generator script in _media/, data, a README, a Makefile in a doc folder or a file under a mount next to docs at level ai" \
  || no "user files:$bad"
bad=""
for f in .github/workflows/ci.yml .github/scripts/bump-mounted-pins.py .github/dependabot.yml .GitHub/x.md \
         schema.local.yaml schema.yaml Schema.Local.YAML .pre-commit-config.yaml .gitmodules .gitattributes .mcp.json \
         CLAUDE.md a/CLAUDE.md a/claude.md CLAUDE.local.md AGENTS.md a/agents.md .claude/settings.json .claude/commands/x.md \
         a/.claude/skills/s/SKILL.md CONVENTIONS.md a/CONVENTIONS.md conventions.md dist/served/internal.jsonl \
         scripts/validate.py scripts/yaml.py scripts/km/__init__.py schema.base.yaml a/.gitattributes GEMINI.md .cursorrules .cursor/rules/r.md .codex/x \
         .vscode/tasks.json .devcontainer/devcontainer.json .envrc a/.envrc .husky/pre-commit a/.gitignore \
         Makefile mise.toml lefthook.yml README.md Readme.md a/GEMINI.md a/AGENTS.override.md docs/CODEOWNERS a/.config/x.yml dist/.gitkeep .gitkeep; do
  for side in "" from: to:; do        # the file changed, renamed from it to a doc, renamed to it from an image
    case "$side" in from:) line="$(file a/x.md 1 renamed "$f")";; to:) line="$(file "$f" 1 renamed a/x.png)";; *) line="$(file "$f" 1)";; esac
    setup "$(file a.md 1; echo "$line")"; refused && grep -qF "changes $f, a control file" <<< "$out" || bad+=" $side$f"
  done
done
setup "$(file a.md 1; file a/terms.txt 1)"; printf 'gate:\n  forbidden_terms_file: ./a/Terms.txt\n' > "$F/schema"
refused && grep -q "a/terms.txt, a control file" <<< "$out" || bad+=" forbidden-terms-file"
[ -z "$bad" ] && ok "a control file stops the author's label, on either side of a rename and whatever its case: any dot path (.github/, .claude/, .husky/, .vscode/, .envrc and the like, at any depth), any top-level file that is no doc (the schema overlay, a Makefile, a README, CLAUDE.md), agent instructions and CONVENTIONS.md at any depth, scripts/ (a copy-in brain runs km's scripts there), dist/, the gate's forbidden_terms_file" \
  || no "control files:$bad"
bad=""
L='{"path":"a/link.md","mode":"120000"}'; M='{"path":"brains/p","mode":"160000"}'
setup "$(file a.md 1; file a/link.md 1)"; tree "$HEAD" "$L"; refused && grep -q "a/link.md, a symlink or submodule" <<< "$out" || bad+=" link-head"
setup "$(file a.md 1; file a/link.md 1)"; tree "$MB" "$L"; refused && grep -q "a symlink or submodule" <<< "$out" || bad+=" link-base"
setup "$(file a.md 1; file a/x.png 1 renamed a/link.png)"; tree "$MB" "${L/link.md/link.png}"; refused && grep -q "a symlink or submodule" <<< "$out" || bad+=" link-renamed"
setup "$(file a.md 1; file brains/p 1)"; tree "$HEAD" "$M"; tree "$MB" "$M"; refused && grep -q "brains/p, a symlink or submodule" <<< "$out" || bad+=" gitlink"
setup "$(file a.md 1; file a/x.png 1)"; tree "$HEAD" "$L"; refused && grep -q "holds the symlink a/link.md" <<< "$out" || bad+=" unchanged-link"
setup "$(file a.md 1)"; tree "$BASE" "$L"; refused && grep -q "holds the symlink a/link.md" <<< "$out" || bad+=" link-in-base-only"
T1='{"path":"mounted","mode":"160000"}'; T2='{"path":"Makefile","mode":"120000"}'
setup "$(file a.md 1)"; tree "$HEAD" "$T1"; tree "$MB" "$T1"; tree "$BASE" "$T1"; counts || bad+=" unchanged-top-mount"
setup "$(file a.md 1; file a/x.png 1)"; tree "$HEAD" "$T2"; refused && grep -q "holds the symlink Makefile" <<< "$out" || bad+=" unchanged-top-link"
setup "$(file a.md 1)"; tree "$HEAD" "" true; refused && grep -q "trees of its commits" <<< "$out" || bad+=" truncated"
setup "$(file a.md 1)"; rm "$F/trees/$MB"; refused && grep -q "trees of its commits" <<< "$out" || bad+=" unread"
setup "$(file a.md 1)"; touch "$F/trees/$HEAD.fail"; rm "$F/trees/$HEAD"; refused && grep -q "trees of its commits" <<< "$out" || bad+=" failed"; rm -f "$F/trees/$HEAD.fail"
C='{"path":"CLAUDE.md","mode":"120000"}'; D='{"path":"a/.Claude","mode":"120000"}'
setup "$(file a.md 1; file notes/rules.txt 1)"; tree "$HEAD" "$C"; refused && grep -q "holds the symlink CLAUDE.md" <<< "$out" || bad+=" control-link"
setup "$(file a.md 1; file tools/settings.json 1)"; tree "$MB" "$D"; refused && grep -q "holds the symlink a/.Claude" <<< "$out" || bad+=" control-dir-link"
setup "$(file a.md 1; file a/link.png 1)"; tree "$BASE" '{"path":"a/link.png","mode":"120000"}'; refused && grep -q "a symlink or submodule" <<< "$out" || bad+=" link-base-tip"
setup "$(file a.md 1)"; jq 'del(.merge_base_commit)' "$F/compare" > "$F/c.tmp" && mv "$F/c.tmp" "$F/compare"; refused && grep -q "trees of its commits" <<< "$out" || bad+=" no-merge-base"
setup "$(file a.md 1)"; R; grep -q "git/trees/$HEAD?recursive=1" "$F/calls" && grep -q "git/trees/$MB?recursive=1" "$F/calls" && grep -q "git/trees/$BASE?recursive=1" "$F/calls" || bad+=" all-trees"
setup "$(file a.md 2)" Maint; R; ! grep -q "git/trees" "$F/calls" || bad+=" others-label-reads-trees"
[ -z "$bad" ] && ok "a symlink anywhere in the trees of the head, the merge base or the base stops it, changed or not, as does a changed submodule (an unchanged mount does not), as does a tree cut or not read or no merge base; another person's label reads no tree" \
  || no "trees:$bad"

bad=""
setup "$(file a.md 1)" alice 2
refused && grep -q "file list" <<< "$out" || bad+=" cut-list"
setup "$(file a.md 1)"; echo '[]' > "$F/events"; refused || bad+=" no-event"
setup "$(file a.md 1)"; label null; refused || bad+=" deleted-actor"
setup "$(file a.md 1)" ghost; refused || bad+=" ghost"
setup "$(file a.md 1)"; rm "$F/pull"; refused || bad+=" no-pull"
setup "$(file a.md 1)"; printf 'not json\n' > "$F/compare.raw"; refused && grep -q "file list" <<< "$out" || bad+=" bad-list"
setup "$(file a.md 1)"; rm "$F/compare"; refused && grep -q "file list" <<< "$out" || bad+=" no-list"
setup "$(file a.md 1)"; pull 1 | sed "s/$HEAD/$OTHER/" > "$F/pull.next"; refused && grep -q "moved while it was read" <<< "$out" || bad+=" pushed-meanwhile"
setup "$(file a.md 1)"; pull 1 | sed "s/$BASE/$OTHER/" > "$F/pull.next"; refused && grep -q "moved while it was read" <<< "$out" || bad+=" base-moved"
setup "$(file a.md 1)"; jq '. + [{event: "unlabeled", label: {name: "km:ready"}, actor: {login: "Maint", type: "User"}}]' "$F/events" > "$F/events.next"
refused && grep -q "label changed while it was read" <<< "$out" || bad+=" unlabeled-meanwhile"
setup "$(file a.md 1)"; jq '.[:1] + [{event: "unlabeled", label: {name: "km:ready"}, actor: {login: "Maint", type: "User"}}]' "$F/events" > "$F/events.tmp"; mv "$F/events.tmp" "$F/events"
refused && grep -q "no km:ready label event" <<< "$out" || bad+=" removed-label"
[ -z "$bad" ] && ok "no count when the file list is cut, unreadable or no JSON, no label event or one by a deleted account, the label was removed, the pull request cannot be read, and when the head, base or label changed during the reads" || no "reads:$bad"
setup "$(file a.md 1)"; R; grep -q "compare/$BASE...$HEAD" "$F/calls" && grep -q "contents/a.md?ref=$BASE" "$F/calls" \
  && ok "the files come from comparing the head and base commits read first, the base texts from that base" || no "commit range ($(cat "$F/calls"))"

bad=""
setup "$(file a.md 2)" Maint; label "$(actor helper Bot)"; refused || bad+=" bot-type"
setup "$(file a.md 2)" Maint; label "$(actor 'helper[bot]')"; refused || bad+=" bot-login"
setup "$(file a.md 2)" Maint; label "$(actor Maint)" '{"slug":"x"}'; refused || bad+=" app"
setup "$(file a.md 1)" Maint; label "$(actor helper Bot)"; counts && grep -q "set by a bot or app" <<< "$out" || bad+=" bot-ai"
[ -z "$bad" ] && ok "a label a bot or an app applied is judged like the author's: no count with a doc at level human, a count when all are at level ai" || no "automated:$bad"

LS=$'a/line\xe2\x80\xa8sep.md'   # a U+2028 line separator in a file name
setup "$(file "$LS" 1)"; counts && ok "a U+2028 in a file name (jq leaves it raw, splitlines() would split there) does not cut the JSON lines gh prints" || no "line separator ($rc: $out)"

out="$(cd "$T/brain" && km ready o/r nine 2>&1)"; [ $? = 2 ] && ok "a NUMBER that is not one is a usage error" || no "usage ($out)"
printf 'fields: [\n' > "$T/brain/schema.local.yaml"; setup "$(file a.md 1)" Maint; R
[ "$rc" = 1 ] && [ "$(wc -l <<< "$out")" -eq 1 ] && [[ "$out" == "does not count: the local schema is broken: schema.local.yaml: invalid YAML"* ]] \
  && ok "a broken local schema.local.yaml is one does-not-count line" || no "local schema ($rc: $out)"
rm "$T/brain/schema.local.yaml"

summary ready_smoke
