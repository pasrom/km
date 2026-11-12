#!/usr/bin/env bash
# Smoke test for `km init` (team and personal): a fresh brain must come out clean; then gen-index,
# demote, serve, the workflows and pre-commit hook it writes, and `km upgrade`.
# Run:  bash tests/team_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
KM_REF="v$(km --version)"
T="$(mktemp -d)"
F="$(mktemp -d)"                       # scratch for init runs that must be refused
trap 'rm -rf "$T" "$F"' EXIT
fake_km_remote "$F/remote"; export KM_REPO_URL="file://$F/remote"   # km pins releases by their commit
KM_SHA="$(git -C "$F/remote" rev-parse "$KM_REF^{commit}")"; V09_SHA="$(git -C "$F/remote" rev-parse v0.9.0)"
S99="$(printf '9%.0s' {1..40})"; S98="$(printf '8%.0s' {1..40})"           # commits of made-up newer releases
PINW="pasrom/km@$KM_SHA # $KM_REF"; PINH="rev: $KM_SHA  # frozen: $KM_REF"
git -C "$F/remote" "${G[@]}" commit -q --allow-empty -m three && git -C "$F/remote" tag v1.99.0   # a release that has the km-gen-index hook
NEW_SHA="$(git -C "$F/remote" rev-parse v1.99.0)"
# km 1.11.0, which the index-regen cases pin, whatever this km's version is (a commit off the branch)
git -C "$F/remote" rev-parse -q --verify refs/tags/v1.11.0 >/dev/null || git -C "$F/remote" tag v1.11.0 \
  "$(git -C "$F/remote" "${G[@]}" commit-tree -p v0.9.0 -m 1.11 'v0.9.0^{tree}')"
GI="$(kmpy -c 'import km.init as i; print(" km:km-gen-index:" if i.gen_index_hook(i.KM_REF) else "")')"   # whether this km's own pin gets it

G(){ git -C "$T" -c user.name=t -c user.email=t@t "$@"; }
kt(){ ( cd "$T" && km "$@" 2>&1 ); }
doc(){ mkdir -p "$(dirname "$1")"; printf -- '---\ntype: note\ntitle: %s\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [t]\n---\nbody\n' "$2" > "$1"; }
folder_idx(){ mkdir -p "$T/$1"; printf -- '---\ntype: reference\ntitle: "%s"\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [index]\n---\n\n## Documents\n' "$2" > "$T/$1/_index.md"; }

# --- init ---
km init "$T" --team --name Test-Brain --desc "the test team" --initials TT \
  --folder process="Tooling and workflow" --folder projects="Time-bound work, one subfolder per project" >/dev/null
G init -q && G add -A
ph="$(kmpy -c 'import km.init as i; print("\\|".join(i.PLACEHOLDERS))')"
grep -rln "$ph" "$T" --include='*.md' --include='*.yaml' >/dev/null && no "no placeholder left after init" || ok "no placeholder left after init"
grep -q '^| `projects/` | Time-bound work' "$T/CONVENTIONS.md" && ok "folder table rendered" || no "folder table rendered"
[ ! -e "$T/scripts" ] && [ ! -e "$T/schema.base.yaml" ] && ok "no km code is copied into the brain" || no "no km code is copied into the brain"
grep -qx "\* text=auto eol=lf" "$T/.gitattributes" && ok "init writes a .gitattributes: LF on every platform" || no "init writes a .gitattributes: LF on every platform"
{ grep -q "uses: $PINW" "$T/.github/workflows/ci.yml" && grep -q "uses: $PINW" "$T/.github/workflows/staleness.yml" \
  && grep -q "$PINH" "$T/.pre-commit-config.yaml" && [ -f "$T/.github/dependabot.yml" ]; } \
  && ok "workflows and hook pin km $KM_REF by its commit, Dependabot watches them" || no "workflows and hook pin km by commit"
[ "$(grep -c "km-gen-index" "$T/.pre-commit-config.yaml")" = "$([ -n "$GI" ] && echo 1 || echo 0)" ] \
  && ok "init --team names km-gen-index exactly when the km it pins has it" || no "init --team km-gen-index vs GI '$GI'"
grep -rhoE "uses: [^ ]+@[^ ]+" "$T/.github/workflows" | grep -vE "@[0-9a-f]{40}$" && no "every action is pinned by commit" || ok "every action is pinned by commit"
grep -q "blob/$KM_SHA/src/km/schema.base.yaml" "$T/CONVENTIONS.md" && ok "CONVENTIONS links km's base schema at that commit" || no "CONVENTIONS schema link"
grep -q '^author: <initials> ' "$T/CONVENTIONS.md" && ok "the schema example keeps its <initials> placeholder" || no "the schema example keeps its <initials> placeholder"
KT(){ km init "$1" --team --name X --desc y --initials Z "${@:2}" >/dev/null 2>&1; }
KT "$T" --folder a=b && no "init refuses a repo that already has its files" || ok "init refuses a repo that already has its files"
mkdir -p "$F/r" && echo "# x" > "$F/r/README.md"
KT "$F/r" --folder a=b && no "init refuses to overwrite a host-made README" || ok "init refuses to overwrite a host-made README"
KT "$F/f" --folder ..=b; [ -e "$F/_index.md" ] || [ -e "$F/f/CONVENTIONS.md" ] && no "init rejects a folder name outside the repo" || ok "init rejects a folder name outside the repo"
KT "$F/q" --folder 'a=say "hi"'; [ -e "$F/q/CONVENTIONS.md" ] && no "init rejects a quote in a purpose" || ok "init rejects a quote in a purpose"
km init "$F/y" --team --name Yes --desc on --initials NO --folder on=Off >/dev/null
python3 - "$F/y" <<'PY' && ok "YAML-ish values (NO, on) stay strings" || no "YAML-ish values (NO, on) stay strings"
import sys, yaml, re
r = sys.argv[1]
local = yaml.safe_load(open(f"{r}/schema.local.yaml"))
fm = yaml.safe_load(re.match(r"---\n(.*?)\n---", open(f"{r}/on/_index.md").read(), re.S).group(1))
sys.exit(0 if local["author_default"] == "NO" and fm["author"] == "NO" and fm["tags"][0] == "on" else 1)
PY
out="$(kt gen-index)"; echo "$out" | grep -q "updated 3" && ok "first gen-index fills root and folder lists" || no "first gen-index fills root and folder lists ($out)"
grep -q '^- \[projects/\](projects/_index.md): Time-bound work' "$T/_index.md" && ok "root map lists folders with their purpose" || no "root map lists folders with their purpose"
G add -A && G commit -q -m init
out="$(kt gen-index --check)"; rc=$?
[ "$rc" = 0 ] && ok "fresh brain: gen-index --check up to date" || no "fresh brain: gen-index --check up to date ($out)"
out="$(kt validate)"
echo "$out" | grep -q "ERRORS: 0" && echo "$out" | grep -q "WARNINGS: 0" \
  && ok "fresh brain: validate 0 errors / 0 warnings" || no "fresh brain: validate 0 errors / 0 warnings ($out)"

# --- gen-index: a subfolder index is listed by its parent ---
folder_idx projects/p1 "P1 project"; doc "$T/projects/p1/kickoff.md" "Kickoff"; G add -A
out="$(kt gen-index --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - projects/_index.md"; } && ok "--check fails when a subfolder index is not listed" || no "--check fails when a subfolder index is not listed ($out)"
kt gen-index >/dev/null
grep -q '^- \[P1 project\](p1/_index.md)' "$T/projects/_index.md" && ok "parent lists the subfolder index, titled from it" || no "parent lists the subfolder index, titled from it"
grep -q '^- \[Kickoff\](kickoff.md)' "$T/projects/p1/_index.md" && ok "subfolder lists its own doc" || no "subfolder lists its own doc"
G add -A && G commit -q -m p1

# --- generator and validator agree on a nested tree with an index-skipped folder ---
printf 'index_skip_prefixes: [process/generated/]\n' >> "$T/schema.local.yaml"
folder_idx process/tools "Tools"; folder_idx process/tools/ci "CI"; doc "$T/process/tools/ci/runner.md" "Runner"
doc "$T/process/generated/api.md" "API"; G add -A
kt gen-index >/dev/null; G add -A
out="$(kt gen-index --check)"; rc=$?; vout="$(kt validate)"
{ [ "$rc" = 0 ] && echo "$vout" | grep -q "WARNINGS: 0"; } \
  && ok "after gen-index, validate finds nothing to add (nested + index_skip)" || no "generator and validator disagree ($out / $vout)"
G commit -q -m nested

# --- a folder with something to list but no index fails in both modes ---
folder_idx process/lone/deep "Deep"; G add -A
out="$(kt gen-index --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "--check fails on a folder with only a subfolder index" || no "--check fails on a folder with only a subfolder index ($out)"
out="$(kt gen-index)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "write mode fails on it too" || no "write mode fails on it too ($out)"
G rm -rqf --cached process/lone; rm -rf "$T/process/lone"; G checkout -q -- .
mkdir -p "$T/process/misc"; printf '# readme\n' > "$T/process/misc/README.md"; G add -A
out="$(kt gen-index --check)"; echo "$out" | grep -q "process/misc" && no "a folder with only a README is not reported" || ok "a folder with only a README is not reported"
G rm -rq --cached process/misc; rm -rf "$T/process/misc"

# --- the root map is optional ---
G rm -q --cached _index.md; mv "$T/_index.md" "$T/root.bak"
out="$(kt gen-index --check)"; rc=$?
[ "$rc" = 0 ] && ok "no root _index.md: top-level indexes need no parent" || no "no root _index.md: top-level indexes need no parent ($out)"
mv "$T/root.bak" "$T/_index.md"; G add _index.md

# --- demote ---
printf -- '---\ntype: concept\ntitle: Old\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\nold\n' > "$T/process/old.md"
printf -- '---\ntype: concept\ntitle: Cust\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: customer\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2099-01-01\n---\ncustomer <!-- internal note -->\n' > "$T/process/cust.md"
sed 's/^title: Old$/title: Old2/; /^owner: TT$/d' "$T/process/old.md" > "$T/process/old2.md"
G add -A
out="$(kt demote)"; rc=$?
[ "$rc" = 1 ] && ok "demote dry-run exits 1 when something is overdue" || no "demote dry-run exits 1 (rc=$rc)"
grep -q '^status: accepted' "$T/process/old.md" && ok "dry-run leaves the file alone" || no "dry-run leaves the file alone"
echo "$out" | grep -qx "  - process/old.md (owner: TT)" && ok "dry-run names each doc's owner" || no "dry-run owner ($out)"
out="$(kt demote --apply)"
{ echo "$out" | grep -qx "  - process/old.md (owner: TT)" && echo "$out" | grep -qx "  - process/old2.md (owner: none)"; } \
  && ok "--apply names each demoted doc's owner, and says when it has none" || no "--apply owner ($out)"
G rm -qf process/old2.md
{ grep -q '^status: review$' "$T/process/old.md" && ! grep -q '^approved_' "$T/process/old.md"; } \
  && ok "--apply demotes to review and drops the approval" || no "--apply demotes to review and drops the approval"
grep -q '^status: accepted' "$T/process/cust.md" && ok "a doc not yet due stays accepted" || no "a doc not yet due stays accepted"
printf -- '---\ntype: concept\ntitle: Ctl\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\ncontrol\n' > "$T/process/ctl.md"
printf -- '---\ntype: decision\ntitle: Dec\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\ndecided\n' > "$T/process/dec.md"
G add -A; val="$(kt validate process/dec.md process/ctl.md)"; due="$(kt list --due today)"; out="$(kt demote --apply)"
{ echo "$val" | grep -q " 1 x gate-stale" && echo "$due" | grep -q ctl.md && echo "$out" | grep -q ctl.md \
  && grep -q '^status: accepted$' "$T/process/dec.md" && ! echo "$out" | grep -q dec.md && ! echo "$due" | grep -q dec.md; } \
  && ok "a decision's lapsed review_by (no expiry) is ignored by demote, list --due and validate; a concept's is not" || no "decision review_by ignored ($out | $due | $val)"
cp "$T/schema.local.yaml" "$T/sl.bak"; printf 'review_by_default:\n  decision: 0\n' >> "$T/schema.local.yaml"; G add -A
out="$(kt demote --apply)"; rc=$?; out2="$(kt list --due today)"; rc2=$?
{ [ "$rc" = 2 ] && [ "$rc2" = 2 ] && echo "$out" | grep -q "review_by_default maps a type" && grep -q '^status: accepted$' "$T/process/dec.md"; } \
  && ok "demote and list --due refuse a bad review_by_default table instead of reading it as no expiry" || no "bad table in demote/list ($rc $rc2: $out)"
mv "$T/sl.bak" "$T/schema.local.yaml"; G rm -qf --cached process/dec.md process/ctl.md; rm -f "$T/process/dec.md" "$T/process/ctl.md"; G add -A
printf -- '---\ntype: concept\ntitle: Odd\ntimestamp: 2025-01-15\nauthor: TT\nstatus: "accepted" # ok\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\n---\nx\n' > "$T/process/odd.md"
G add -A; kt demote --apply >/dev/null
grep -q '^status: review$' "$T/process/odd.md" && ok "a status line with a trailing comment is demoted" || no "a status line with a trailing comment is demoted"
printf -- '---\n{type: concept, title: Flow, timestamp: 2025-01-15, author: TT, status: accepted, review_by: 2025-06-01, tags: [t]}\n---\nx\n' > "$T/process/flow.md"
G add -A; out="$(kt demote --apply)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -q "  - process/flow.md: status line" && ! echo "$out" | grep -q "demoted"; } \
  && ok "a status it cannot rewrite fails loudly, never reported as demoted" || no "unrewritable status reported wrongly (rc=$rc: $out)"
printf -- '---\ntype: concept\ntitle: L1\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\n---\nCaf\xe9\n' > "$T/process/l1.md"
cp "$T/process/l1.md" "$T/l1.bak"; G add -A; out="$(kt demote --apply)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/l1.md: not UTF-8" && cmp -s "$T/process/l1.md" "$T/l1.bak"; } \
  && ok "demote leaves a doc that is not UTF-8 byte for byte and reports it" || no "demote non-UTF-8 (rc=$rc: $out)"
rm -f "$T/process/l1.md" "$T/l1.bak"; G add -A
G rm -qf --cached process/flow.md; rm -f "$T/process/flow.md"
# approved_by as a block list: the whole entry goes, its `- ` items do not fold into the field before them
blk(){ printf -- '---\ntype: concept\ntitle: %s\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\nreview_by: 2025-06-01\n%s\napproved_by:\n- TT\n- AB\napproved_at: 2025-01-15\n---\nx\n' "$2" "$3" > "$1"; cp "$1" "$1.orig"; }
# demoted_clean DOC [ORIGINAL]: byte for byte ORIGINAL (default DOC.orig) without its approval lines, status at
# review: edited in place, nothing reformatted
demoted_clean(){ grep -v -e '^approved_' -e '^- ' "${2:-$1.orig}" | sed 's/^status: accepted$/status: review/' | cmp -s - "$1"; }
blk "$T/process/bl1.md" BL1 $'tags: [t]\nowner: TT'; blk "$T/process/bl2.md" BL2 $'owner: TT\ntags: [t]'
G add -A; out="$(kt demote --apply)"
{ demoted_clean "$T/process/bl1.md" && demoted_clean "$T/process/bl2.md"; } \
  && ok "--apply drops a block-list approved_by whole, the frontmatter intact" || no "--apply on a block-list approved_by ($out; $(cat "$T/process/bl1.md" "$T/process/bl2.md"))"
blk "$T/process/bl3.md" BL3 $'tags: [t]\nowner: TT'; blk "$T/process/bl4.md" BL4 $'owner: TT\ntags: [t]'
G add -A; out="$(kt demote process/bl3.md process/bl4.md)"; rc=$?
{ [ "$rc" = 0 ] && demoted_clean "$T/process/bl3.md" && demoted_clean "$T/process/bl4.md"; } \
  && ok "demote DOC drops a block-list approved_by whole, the frontmatter intact" || no "demote DOC on a block-list approved_by (rc=$rc: $out; $(cat "$T/process/bl3.md" "$T/process/bl4.md"))"
rm -f "$T"/process/bl[1-4].md*; G add -A
# an approval key it cannot find (quoted): demoted all the same, the key left in, so a stale doc is never served on;
# the run fails so the staleness job does not report it as done, and a clean doc beside it is still demoted
printf -- '---\ntype: concept\ntitle: Q\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\n"approved_by": TT\napproved_at: 2025-01-15\n---\nx\n' > "$T/process/q.md"
printf -- '---\ntype: concept\ntitle: Q2\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\nx\n' > "$T/process/q2.md"
cp "$T/process/q.md" "$T/q.bak"; cp "$T/process/q2.md" "$T/q2.bak"; G add -A; out="$(kt demote --apply)"; rc=$?
{ [ "$rc" = 1 ] && out_has "demoted 2 doc" && out_has "  - process/q.md (owner: TT): drop its approved_by by hand" \
  && out_has "1 demoted doc(s) still carry an approval key" && demoted_clean "$T/process/q.md" "$T/q.bak" \
  && demoted_clean "$T/process/q2.md" "$T/q2.bak"; } \
  && ok "--apply demotes a doc whose approval key it cannot find, the rest byte for byte, and exits 1 after demoting the others" || no "--apply on a quoted approved_by (rc=$rc: $out; $(cat "$T/process/q.md"))"
rm -f "$T/process/q2.md" "$T/q2.bak"
cp "$T/q.bak" "$T/process/q.md"; G add -A; out="$(kt demote process/q.md)"; rc=$?
{ [ "$rc" = 1 ] && out_has "process/q.md sent back; back to review, but drop its approved_by by hand" \
  && out_has "1 doc(s) sent back still carry a key" && demoted_clean "$T/process/q.md" "$T/q.bak"; } \
  && ok "demote DOC sends it back too, says which approval key is left to drop and exits 1" || no "demote DOC on a quoted approved_by (rc=$rc: $out)"
# a quoted reviewed_by: sent back all the same, the key named, exit 1
sed 's/^"approved_by": TT$/approved_by: TT\n"reviewed_by": [AB]/' "$T/q.bak" > "$T/process/q.md"
G add -A; out="$(kt demote process/q.md)"; rc=$?
{ [ "$rc" = 1 ] && out_has "process/q.md sent back; back to review, but drop its reviewed_by by hand" \
  && grep -qx 'status: review' "$T/process/q.md" && ! grep -q '^approved_' "$T/process/q.md" && grep -q '^"reviewed_by"' "$T/process/q.md"; } \
  && ok "demote DOC sends back a doc with a quoted reviewed_by, names the key and exits 1" || no "demote DOC on a quoted reviewed_by (rc=$rc: $out; $(cat "$T/process/q.md"))"
# the gate refuses it for another reason (an unknown type): restored, not counted as sent back with a key left
sed 's/^type: concept$/type: bogus/' "$T/q.bak" > "$T/process/q.md"; cp "$T/process/q.md" "$T/qb.bak"
G add -A; out="$(kt demote process/q.md)"; rc=$?
{ [ "$rc" = 1 ] && out_has "REFUSED process/q.md: km validate fails" && ! out_has "still carry" && cmp -s "$T/process/q.md" "$T/qb.bak"; } \
  && ok "demote DOC: a doc the gate restores is not reported as sent back with a key left" || no "demote DOC gate restore (rc=$rc: $out)"
rm -f "$T/process/q.md" "$T/q.bak" "$T/qb.bak"; G add -A
# a block that would no longer parse without the approval line (a flow mapping over several lines): refused, unchanged
printf -- '---\n{type: concept, title: FM, timestamp: 2025-01-15, author: TT, review_by: 2025-06-01, tags: [t],\nstatus: accepted\n,\napproved_by: TT}\n---\nx\n' > "$T/process/fm.md"
cp "$T/process/fm.md" "$T/fm.bak"; G add -A; out="$(kt demote --apply)"; rc=$?
{ [ "$rc" = 1 ] && out_has "  - process/fm.md: status line cannot be rewritten" && ! out_has "demoted" && cmp -s "$T/process/fm.md" "$T/fm.bak"; } \
  && ok "--apply refuses a demotion that would leave a block that does not parse, the doc unchanged" || no "--apply on a block that would break (rc=$rc: $out; $(cat "$T/process/fm.md"))"
out="$(kt demote process/fm.md)"; rc=$?
{ [ "$rc" = 1 ] && out_has "REFUSED process/fm.md: signed off, but" && cmp -s "$T/process/fm.md" "$T/fm.bak"; } \
  && ok "demote DOC refuses it too, the doc unchanged" || no "demote DOC on a block that would break (rc=$rc: $out)"
rm -f "$T/process/fm.md" "$T/fm.bak"; G add -A

# --- a tracked file deleted on disk (deletion not staged yet) does not crash the scripts ---
doc "$T/process/gone.md" "Gone"; G add -A; kt gen-index >/dev/null; G add -A; G commit -q -m gone >/dev/null; rm "$T/process/gone.md"
out="$(kt gen-index)"; rc=$?
{ [ "$rc" = 0 ] && ! echo "$out" | grep -q Traceback && ! grep -q "gone.md" "$T/process/_index.md"; } \
  && ok "a deleted tracked doc drops out of the list, no crash" || no "a deleted tracked doc crashes gen-index ($out)"
out="$(kt serve)"; echo "$out" | grep -q Traceback && no "serve survives a deleted tracked doc" || ok "serve survives a deleted tracked doc"
out="$(kt validate)"; echo "$out" | grep -q Traceback && no "validate survives a deleted tracked doc" || ok "validate survives a deleted tracked doc"
G add -A; G commit -q -m gone2 >/dev/null

# --- serve ---
kt serve >/dev/null
m="$T/dist/served/manifest.json"
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "served bundle: only accepted docs, customer subset" || no "served bundle counts ($(cat "$m" 2>/dev/null))"
grep -q "internal note" "$T/dist/served/customer.jsonl" && no "HTML comments never ship" || ok "HTML comments never ship"
( cd "$T" && git check-ignore -q dist/served/manifest.json ) && ok "dist/ is gitignored" || no "dist/ is gitignored"
# a title, tag or ticket YAML reads as a date is served as its text, not a crash in the JSON dump
printf -- '---\ntype: concept\ntitle: 2026-11-10\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [2026-11-11]\nticket: 2026-11-12\nowner: TT\nreview_by: 2099-01-01\n---\nx\n' > "$T/process/dated.md"
G add -A; out="$(kt serve)"
{ ! out_has Traceback && grep '"path": "process/dated.md"' "$T/dist/served/internal.jsonl" | grep '"tags": \["2026-11-11"\]' \
    | grep '"ticket": "2026-11-12"' | grep -q '"title": "2026-11-10"'; } \
  && ok "serve: a date read as the title, a tag or the ticket is served as text" || no "serve: date values ($out)"
G rm -qf --cached process/dated.md; rm -f "$T/process/dated.md"
# a date YAML reads as a mapping KEY (default=str covers values only): served as text too
printf -- '---\ntype: concept\ntitle: Keyed\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [{2026-11-11: t}]\nticket: {2026-11-12: x, 7: y}\nowner: TT\nreview_by: 2099-01-01\n---\nx\n' > "$T/process/keyed.md"
G add -A; out="$(kt serve)"
{ ! out_has Traceback && grep '"path": "process/keyed.md"' "$T/dist/served/internal.jsonl" | grep '"tags": \[{"2026-11-11": "t"}\]' \
    | grep -q '"ticket": {"2026-11-12": "x", "7": "y"}'; } \
  && ok "serve: a date read as a mapping key is served as text" || no "serve: date keys ($out)"
G rm -qf --cached process/keyed.md; rm -f "$T/process/keyed.md"
# a number title is served as written: YAML reads `1.10` as 1.1
printf -- '---\ntype: concept\ntitle: 1.10\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2099-01-01\n---\nx\n' > "$T/process/num.md"
G add -A; out="$(kt serve)"
grep '"path": "process/num.md"' "$T/dist/served/internal.jsonl" | grep -q '"title": "1.10"' \
  && ok "serve: a number title as written in the file" || no "serve: number title ($out; $(grep num.md "$T/dist/served/internal.jsonl"))"
G rm -qf --cached process/num.md; rm -f "$T/process/num.md"; kt serve >/dev/null

# --- served_status is read from the gate config, as the validator does ---
G add -A && G commit -q -m docs >/dev/null
python3 - "$T/schema.local.yaml" <<'EOF'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["gate"]["served_status"] = "published"
yaml.safe_dump(d, open(p, "w"))
EOF
sed -i.bak 's/^status: accepted$/status: published/' "$T/process/cust.md" && rm -f "$T/process/cust.md.bak"
kt serve >/dev/null
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "a custom served_status is honoured by serve" || no "a custom served_status is honoured ($(cat "$m"))"
G checkout -q -- schema.local.yaml process/cust.md

# --- workflows ---
grep -h "scripts/" "$T"/.github/workflows/*.yml | grep -qv "\.github/scripts/bump-mounted-pins\.py" && no "workflows call km, not copied scripts" || ok "workflows call km, not copied scripts"
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('$T/.github/workflows/*.yml')]" 2>/dev/null \
  && ok "workflows are valid YAML" || no "workflows are valid YAML"
python3 - "$T/.github/workflows/staleness.yml" <<'PY' && ok "staleness validates after demoting, even after a failed step" || no "staleness validates after demoting"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["demote"]["steps"]
runs = [(s.get("run", ""), s.get("if", "")) for s in steps]
i = next(n for n, (r, _) in enumerate(runs) if "km demote" in r)
sys.exit(0 if any("km validate" in r and "cancelled" in c for r, c in runs[i + 1:]) else 1)
PY

# --- personal init ---
P="$F/personal"; km init "$P" --initials PP --folder notes="Loose notes" >/dev/null
git -C "$P" init -q && git -C "$P" add -A
{ grep -q '^| `notes/` | Loose notes |$' "$P/CONVENTIONS.md" && [ -f "$P/inbox/_index.md" ] && grep -q "$PINH" "$P/.pre-commit-config.yaml" \
  && [ ! -e "$P/.github" ] && grep -q "eol=lf" "$P/.gitattributes"; } && ok "personal init: conventions, inbox, pinned hook, .gitattributes, no CI" || no "personal init: conventions, inbox, pinned hook, .gitattributes, no CI"
out="$(km validate --root "$P" 2>&1)"; echo "$out" | grep -q "ERRORS: 0" && ok "personal brain validates clean" || no "personal brain validates clean ($out)"
mkdir -p "$F/p2" && git -C "$F/p2" init -q && echo "# mine" > "$F/p2/CLAUDE.md" && printf '\xef\xbb\xbf*.bin binary\n' > "$F/p2/.gitattributes"
out="$(km init "$F/p2" --initials PP 2>&1)"
{ grep -qx "# mine" "$F/p2/CLAUDE.md" && [ "$(cat "$F/p2/.gitattributes")" = $'\xef\xbb\xbf*.bin binary' ] && out_has "sets no line ending"; } \
  && ok "personal init keeps an existing CLAUDE.md and .gitattributes, and notes a missing line ending" || no "personal init keeps an existing CLAUDE.md and .gitattributes ($out)"
mkdir -p "$F/p3" && git -C "$F/p3" init -q && echo "  * text eol=crlf" > "$F/p3/.gitattributes"
out="$(km init "$F/p3" --initials PP 2>&1)"
{ [ "$(cat "$F/p3/.gitattributes")" = "  * text eol=crlf" ] && ! out_has "gitattributes"; } \
  && ok "a .gitattributes that sets its own line ending: no note (git decides)" || no "own line ending ($out)"

# --- upgrade: a brain from the copy-in days moves to the package ---
O="$F/old"; mkdir -p "$O/scripts" "$O/.github/workflows"
# each copy carries the header km's copies of it had
printf '"""Validate knowledge-base frontmatter against the km schema, a strict OKF v0.1 profile.\n"""\n' > "$O/scripts/validate.py"
printf '"""km promote — safe: gate before placing, never destroy content silently.\n"""\n' > "$O/scripts/km_promote.py"
printf '"""Regenerate the '"'"'## Documents'"'"' list in every folder\n"""\n' > "$O/scripts/gen_index.py"
printf '"""Demote stale served docs: an accepted doc\n"""\n' > "$O/scripts/demote_stale.py"
printf '"""Build the SERVED bundle\n"""\n' > "$O/scripts/build_served.py"
printf '"""Shared helpers for the team-brain scripts\n"""\n' > "$O/scripts/team_common.py"
printf '# schema.base.yaml — CANONICAL frontmatter schema for /km knowledge bases.\n' > "$O/schema.base.yaml"
printf 'meta:\n  profile: "old"\n\n# Marks a team brain: /km upgrade then also refreshes the km-owned team scripts and workflows.\nteam_brain: true\ncheck_index: true\n' > "$O/schema.local.yaml"
cp "$REPO/tests/fixtures/old-brain/ci.yml" "$REPO/tests/fixtures/old-brain/staleness.yml" "$O/.github/workflows/"   # km's last copied-in versions
printf 'jobs:\n  own:\n    steps:\n      - uses: pasrom/km@v0.1.0\n      - run: echo mine\n' > "$O/.github/workflows/own.yml"
cp "$REPO/tests/fixtures/old-brain/pre-commit-config.yaml" "$O/.pre-commit-config.yaml"
out="$(km upgrade --root "$O" 2>&1)"
AF=.github/workflows/approve-fork-ci.yml; AFT="$REPO/src/km/templates/team/approve-fork-ci.yml"
cmp -s "$O/$AF" "$AFT" \
  && ok "upgrade of a copy-in brain adds approve-fork-ci with the ci it rewrites" || no "copy-in upgrade approve-fork-ci ($out)"
{ [ ! -e "$O/scripts" ] && [ ! -e "$O/schema.base.yaml" ]; } && ok "upgrade removes the copied km files" || no "upgrade removes the copied km files ($out)"
{ grep -q "uses: $PINW" "$O/.github/workflows/ci.yml" && grep -q "km demote --apply" "$O/.github/workflows/staleness.yml" && [ -f "$O/.github/dependabot.yml" ]; } \
  && ok "upgrade rewrites the km workflows and adds Dependabot" || no "upgrade rewrites the km workflows ($out)"
{ grep -q "$PINW" "$O/.github/workflows/own.yml" && grep -q "echo mine" "$O/.github/workflows/own.yml"; } \
  && ok "a workflow of the brain's own only gets its pin moved" || no "own workflow pin ($out)"
{ grep -q "$PINH" "$O/.pre-commit-config.yaml" && ! grep -q "scripts/" "$O/.pre-commit-config.yaml"; } \
  && ok "upgrade rewrites the local hook to the pasrom/km hook" || no "upgrade rewrites the hook ($out)"
{ ! grep -q "team_brain" "$O/schema.local.yaml" && grep -q "check_index: true" "$O/schema.local.yaml"; } \
  && ok "upgrade drops only the old team_brain marker" || no "upgrade drops the marker ($(cat "$O/schema.local.yaml"))"
{ grep -q "eol=lf" "$O/.gitattributes" && out_has "added .gitattributes"; } \
  && ok "upgrade adds a .gitattributes to a brain without one" || no "upgrade adds .gitattributes ($out)"
out="$(km upgrade --root "$O" 2>&1)"; echo "$out" | grep -q "already on km $KM_REF" && ok "a second upgrade changes nothing" || no "a second upgrade changes nothing ($out)"
repin "$KM_SHA" "$KM_REF" "$V09_SHA" v0.9.0 "$O/.github/workflows/ci.yml" "$O/.pre-commit-config.yaml"
printf 'See [km base schema](https://github.com/pasrom/km/blob/%s/src/km/schema.base.yaml) (km v0.9.0).\n' "$V09_SHA" > "$O/CONVENTIONS.md"
out="$(km upgrade --root "$O" 2>&1)"
{ grep -q "$PINW" "$O/.github/workflows/ci.yml" && grep -q "$PINH" "$O/.pre-commit-config.yaml"; } \
  && ok "upgrade moves older pins to this km" || no "upgrade moves older pins ($out)"
grep -q "blob/$KM_SHA/src/km/schema.base.yaml) (km $KM_REF)" "$O/CONVENTIONS.md" \
  && ok "upgrade moves the CONVENTIONS schema link with the pins" || no "upgrade schema link ($(cat "$O/CONVENTIONS.md"))"
printf 'See [km base schema](https://github.com/pasrom/km/blob/%s/src/km/schema.base.yaml) (km v0.9.0).\n' "$V09_SHA" > "$O/CONVENTIONS.md"
out="$(km upgrade --root "$O" 2>&1)"
grep -q "blob/$KM_SHA/src/km/schema.base.yaml) (km $KM_REF)" "$O/CONVENTIONS.md" \
  && ok "upgrade fixes a stale schema link on a brain already on the release" || no "upgrade schema link when current ($out)"
NP="$(mktemp -d)"; git init -q "$NP"; printf 'meta: {profile: np}\n' > "$NP/schema.local.yaml"
printf 'See [km base schema](https://github.com/pasrom/km/blob/%s/src/km/schema.base.yaml) (km v0.9.0).\n' "$V09_SHA" > "$NP/CONVENTIONS.md"
out="$(km upgrade --root "$NP" 2>&1)"
out_has "left the base-schema link" && ok "upgrade says when it cannot move the schema link" || no "upgrade link without pins ($out)"
rm -rf "$NP"

# --- upgrade is careful with what is not km's ---
N="$F/notkm"; mkdir -p "$N/scripts"; echo "print('mine')" > "$N/scripts/validate.py"
( km upgrade --root "$N" >/dev/null 2>&1 ) && no "upgrade refuses a repo that is not a km brain" || ok "upgrade refuses a repo that is not a km brain"
[ -f "$N/scripts/validate.py" ] && ok "...and deletes nothing there" || no "...and deletes nothing there"
M="$F/mixed"; mkdir -p "$M/scripts" "$M/.github/workflows"; echo "# conv" > "$M/CONVENTIONS.md"
echo "print('mine')" > "$M/scripts/validate.py"
printf '"""Regenerate the '"'"'## Documents'"'"' list in every folder\n"""\n' > "$M/scripts/gen_index.py"
printf '"""Build the SERVED bundle\n"""\n' > "$M/scripts/build_served.py"
printf 'type_rules: {}\nteam_brain: true\n' > "$M/schema.local.yaml"
git -C "$M" init -q; echo "*.md text" > "$M/.gitattributes"
printf 'jobs:\n  own:\n    steps:\n      - run: python scripts/own.py\n' > "$M/.github/workflows/ci.yml"
printf 'jobs:\n  lint:\n    steps:\n      - run: python3 scripts/gen_index.py --check\n' > "$M/.github/workflows/lint.yml"
printf 'repos:\n  - repo: local\n    hooks:\n      - id: km-validate\n        entry: uv run scripts/validate.py\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v4.0.0\n    hooks:\n      - id: trailing-whitespace\n' > "$M/.pre-commit-config.yaml"
out="$(km upgrade --root "$M" 2>&1)"
{ [ -f "$M/scripts/validate.py" ] && [ ! -e "$M/scripts/build_served.py" ] && echo "$out" | grep -q "left scripts/validate.py: not km's copy"; } \
  && ok "upgrade deletes only km's own copies" || no "upgrade deletes only km's own copies ($out)"
grep -q "python scripts/own.py" "$M/.github/workflows/ci.yml" && ok "a brain's own ci.yml is not replaced" || no "a brain's own ci.yml is not replaced"
{ [ -f "$M/scripts/gen_index.py" ] && echo "$out" | grep -q "kept scripts/gen_index.py: .github/workflows/lint.yml still runs it"; } \
  && ok "a km copy a remaining workflow still runs is kept and reported" || no "script still run is kept ($out)"
{ [ "$(cat "$M/.gitattributes")" = "*.md text" ] && out_has "kept .gitattributes, which sets no line ending"; } \
  && ok "upgrade keeps a brain's own .gitattributes and notes a missing line ending" || no "upgrade and a brain's own .gitattributes ($out)"
[ -f "$M/.github/dependabot.yml" ] && ok "a team brain (team_brain marker) gets Dependabot even with its own workflows" || no "team brain via marker gets Dependabot ($out)"
{ grep -q "trailing-whitespace" "$M/.pre-commit-config.yaml" && echo "$out" | grep -q "differs from km's old hook"; } \
  && ok "a pre-commit config with other hooks is left for a hand edit" || no "pre-commit with other hooks ($out)"
C="$F/changed"; mkdir -p "$C/.github/workflows"; echo "# conv" > "$C/CONVENTIONS.md"
{ cat "$REPO/tests/fixtures/old-brain/staleness.yml"; printf '      - run: echo added-by-the-brain\n'; } > "$C/.github/workflows/staleness.yml"
printf '"""Demote stale served docs\n"""\n' > "$C/demote.tmp"; mkdir -p "$C/scripts"; mv "$C/demote.tmp" "$C/scripts/demote_stale.py"
out="$(km upgrade --root "$C" 2>&1)"
{ grep -q "added-by-the-brain" "$C/.github/workflows/staleness.yml" && [ -f "$C/scripts/demote_stale.py" ] \
  && echo "$out" | grep -q "kept scripts/demote_stale.py: .github/workflows/staleness.yml still runs it"; } \
  && ok "a km workflow the brain changed is reported, not overwritten" || no "changed km workflow ($out)"

# --- a legacy schema.yaml acts as the overlay until upgrade renames it ---
L="$F/legacy"; mkdir -p "$L/notes"; git -C "$L" init -q; echo "# conv" > "$L/CONVENTIONS.md"
printf 'fields:\n  mood:\n    required: true\n' > "$L/schema.yaml"
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-01-01\nauthor: X\nstatus: draft\ntags: [t]\n---\nx\n' > "$L/notes/a.md"; git -C "$L" add -A
out="$(km validate --root "$L" 2>&1)"
{ echo "$out" | grep -q "read as the local overlay" && echo "$out" | grep -q "required field 'mood' absent"; } \
  && ok "a legacy schema.yaml is read as the overlay" || no "legacy schema.yaml overlay ($out)"
km upgrade --root "$L" >/dev/null 2>&1
{ [ -f "$L/schema.local.yaml" ] && [ ! -e "$L/schema.yaml" ]; } && ok "upgrade renames it to schema.local.yaml" || no "upgrade renames schema.yaml"
# an older brain's overlay may still carry the meta.schema_version km's base schema no longer has
printf 'meta:\n  profile: "old"\n  schema_version: "1.4.0"\n' > "$L/schema.local.yaml"; git -C "$L" add -A
out="$(km validate --root "$L" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! echo "$out" | grep -qi "schema_version\|traceback"; } \
  && ok "an overlay with meta.schema_version still validates" || no "overlay with meta.schema_version ($out)"

# --- --root in every form ---
B="$F/badbrain"; mkdir -p "$B"; git -C "$B" init -q; printf -- '---\ntitle: x\n---\nx\n' > "$B/x.md"; git -C "$B" add -A
out="$(cd "$B" && km validate --root="$T" 2>&1)"; echo "$out" | grep -q "ERRORS: 0" && ok "--root=DIR validates that brain, not the cwd" || no "--root=DIR ($out)"
out="$(cd "$T" && km --root "$B" validate 2>&1)"; echo "$out" | grep -q "x.md - required field 'type' absent" && ok "km --root DIR <cmd> works before the command" || no "--root before the command ($out)"
( km validate --root "$F/nope" >/dev/null 2>&1 ) && no "a missing --root directory is an error" || ok "a missing --root directory is an error"

# --- pins: a brain pinning another km runs that one; a newer pin is not moved back ---
printf '#!/usr/bin/env bash\necho "$@" > "%s/runner-args"\n' "$F" > "$F/fake-uvx"; chmod +x "$F/fake-uvx"
repin "$KM_SHA" "$KM_REF" "$S99" v99.0.0 "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml"
KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" >/dev/null 2>&1
grep -q -- "--no-config --from git+$KM_REPO_URL@$S99 km validate" "$F/runner-args" 2>/dev/null \
  && ok "a brain command runs the km version the brain pins" || no "pinned run ($(cat "$F/runner-args" 2>/dev/null))"
repin "$S99" v99.0.0 "$V09_SHA" v0.9.0 "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml"
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km repin --root "$O" any.md 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && echo "$out" | grep -q "needs km v1.4.0, the brain pins v0.9.0" && [ ! -e "$F/runner-args" ]; } \
  && ok "a command the pinned km lacks says to upgrade" || no "command newer than the pin ($rc: $out)"
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km repin --root "$O" --cites any.md --dir . 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && echo "$out" | grep -q "needs km v1.8.0, the brain pins v0.9.0" && [ ! -e "$F/runner-args" ]; } \
  && ok "an option the pinned km lacks says to upgrade" || no "option newer than the pin ($rc: $out)"
for a in "--signoff-since main" --signoff-since=main; do   # an option with a value, in either spelling
  rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" $a 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && echo "$out" | grep -q "needs km v1.12.0, the brain pins v0.9.0" && [ ! -e "$F/runner-args" ]; } \
    && ok "km validate $a with an older pin says to upgrade" || no "km validate $a newer than the pin ($rc: $out)"
done
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km demote --root "$O" some.md 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && echo "$out" | grep -q "needs km v1.11.0, the brain pins v0.9.0" && [ ! -e "$F/runner-args" ]; } \
  && ok "a positional argument the pinned km ignores says to upgrade" || no "demote DOC newer than the pin ($rc: $out)"
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km demote --root "$O" --apply -- --odd.md 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$F/runner-args" ] && ok "...also a doc after --" || no "demote -- DOC newer than the pin ($rc: $out)"
for a in "" --apply; do
  rm -f "$F/runner-args"; KM_PINNED_RUNNER="$F/fake-uvx" km demote --root "$O" $a >/dev/null 2>&1
  grep -qx -- ".* km demote${a:+ $a}" "$F/runner-args" 2>/dev/null && ok "km demote $a without docs still runs the pinned km" || no "km demote $a forwarded ($(cat "$F/runner-args" 2>/dev/null))"
done
for c in init upgrade doctor list sync; do   # NO_PIN_CHECK in cli.py: they run the km that was started
  rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km "$c" --root "$O" --help 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ ! -e "$F/runner-args" ] && ! echo "$out" | grep -q "running that one"; } \
    && ok "km $c runs this km, not the older one the brain pins" \
    || no "km $c with an older pin ($rc: $(cat "$F/runner-args" 2>/dev/null) $out)"
done
repin "$V09_SHA" v0.9.0 "$S99" v99.0.0 "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml"
rm -f "$F/runner-args"; KM_LOCAL=1 KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" >/dev/null 2>&1
[ ! -e "$F/runner-args" ] && ok "KM_LOCAL=1 keeps this km" || no "KM_LOCAL=1 keeps this km"
out="$(KM_PINNED_RUNNER=no-such-runner km validate --root "$O" 2>&1)"; echo "$out" | grep -q "running this km since no-such-runner is not installed" \
  && ok "without uv it runs this km and says so" || no "no-uv fallback ($out)"
repin "$S99" v99.0.0 "$KM_SHA" "$KM_REF" "$O/.pre-commit-config.yaml"
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"
{ echo "$out" | grep -q "the pre-commit hook pins km $KM_REF (${KM_SHA:0:7}), CI pins v99.0.0 (9999999)" && grep -q "@$S99 km validate" "$F/runner-args" 2>/dev/null; } \
  && ok "a hook pinned apart from CI gets a note; CI's version runs" || no "hook vs CI pin ($out)"
printf '#!/usr/bin/env bash\nexit 3\n' > "$F/broken-uvx"; chmod +x "$F/broken-uvx"
out="$(KM_PINNED_RUNNER="$F/broken-uvx" km validate --root "$O" 2>&1)"; echo "$out" | grep -q "could not be fetched" \
  && ok "a pinned km that cannot be fetched falls back to this km" || no "fetch failure fallback ($out)"
repin "$S99" v99.0.0 "$S98" v98.0.0 "$O/.github/workflows/own.yml"
out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"; echo "$out" | grep -q "the workflows pin different km versions" \
  && ok "workflows that disagree: this km runs, with a warning" || no "disagreeing workflows ($out)"
out="$(km upgrade --root "$O" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && grep -q "pasrom/km@$S99 # v99.0.0" "$O/.github/workflows/ci.yml"; } && ok "upgrade refuses to move a newer pin back" || no "upgrade refuses a downgrade (rc=$rc: $out)"
km upgrade --root "$O" --force >/dev/null 2>&1; grep -q "$PINW" "$O/.github/workflows/ci.yml" && ok "upgrade --force moves it anyway" || no "upgrade --force"
sed -i.bak "s|$KM_SHA # $KM_REF|v99.0.0|; s|$KM_SHA  # frozen: $KM_REF|v99.0.0|" "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml" && rm -f "$O"/.github/workflows/*.bak "$O"/.*.bak
git -C "$O" init -q; rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"
{ echo "$out" | grep -q "v99.0.0 is a movable tag, not a commit" && [ ! -e "$F/runner-args" ] \
  && echo "$out" | grep -q "runs pasrom/km@v99.0.0, a ref that can be moved"; } \
  && ok "a pin to a movable tag is never fetched, warned about, and a km validate warning (so CI shows it)" || no "movable tag pin ($out)"
km upgrade --root "$O" --force >/dev/null 2>&1
{ grep -q "$PINW" "$O/.github/workflows/ci.yml" && grep -q "$PINH" "$O/.pre-commit-config.yaml" && ! grep -q "km@v99" "$O"/.github/workflows/*.yml; } \
  && ok "upgrade turns tag pins into commit pins" || no "upgrade turns tag pins into commit pins"

sed -i.bak "s|rev: $KM_SHA  # frozen: $KM_REF|rev: $KM_REF|" "$T/.pre-commit-config.yaml" && rm -f "$T/.pre-commit-config.yaml.bak"
out="$(km validate --root "$T" 2>&1)"; echo "$out" | grep -q "the pre-commit hook pins km tag $KM_REF, CI pins $KM_REF (${KM_SHA:0:7})" \
  && ok "a tag pin and a commit pin of the same version are told apart" || no "pin labels ($out)"
G checkout -q -- .pre-commit-config.yaml
out="$(KM_REPO_URL="file://$F/no-such-repo" km upgrade --root "$T" 2>&1)"; echo "$out" | grep -q "already on km $KM_REF" \
  && ok "upgrade of a current brain needs no lookup (works offline)" || no "offline upgrade of a current brain ($out)"

# --- the km hook is found however its entry is written; other repos stay untouched ---
H="$F/hooks"; mkdir -p "$H"; git -C "$H" init -q; echo "# conv" > "$H/CONVENTIONS.md"
cat > "$H/.pre-commit-config.yaml" <<'YML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v0.9.0
    hooks:
      - id: trailing-whitespace
  - rev: 'v0.9.0'
    # km, written unusually: rev first, quoted, a comment line, a .git URL
    repo: "https://github.com/pasrom/km.git"
    hooks:
      - id: km-validate
YML
out="$(km validate --root "$H" 2>&1)"; echo "$out" | grep -q "runs the km hook at v0.9.0" \
  && ok "a km hook pinned to a tag is found in an unusual entry and warned about" || no "unusual hook entry ($out)"
km upgrade --root "$H" >/dev/null 2>&1
{ grep -q "rev: $KM_SHA  # frozen: $KM_REF" "$H/.pre-commit-config.yaml" && grep -q "pasrom/km.git" "$H/.pre-commit-config.yaml" \
  && [ "$(grep -c "rev: v0.9.0" "$H/.pre-commit-config.yaml")" = 1 ]; } \
  && ok "upgrade pins that km entry by commit and leaves the other repo's rev alone" || no "hook entry re-pin ($(cat "$H/.pre-commit-config.yaml"))"

# --- actions from a movable ref are reported, km's or not ---
A="$F/actions"; mkdir -p "$A/.github/workflows"; git -C "$A" init -q; echo "# conv" > "$A/CONVENTIONS.md"
printf 'jobs:\n  j:\n    steps:\n      - uses: actions/checkout@v4\n      - uses: ./local-action\n' > "$A/.github/workflows/own.yml"
out="$(km validate --root "$A" 2>&1)"
{ echo "$out" | grep -q "runs actions/checkout@v4" && ! echo "$out" | grep -q "local-action"; } \
  && ok "validate warns about a third-party action pinned to a tag" || no "third-party tag action warning ($out)"
km upgrade --root "$A" 2>&1 | grep -q "runs actions/checkout@v4 from a movable ref" && ok "upgrade lists it too" || no "upgrade lists a tag action"

# --- a commit that is not the release its comment names is re-pinned ---
repin "$KM_SHA" "$KM_REF" "$V09_SHA" "$KM_REF" "$T/.github/workflows/ci.yml"
out="$(km upgrade --root "$T" 2>&1)"
{ echo "$out" | grep -q "points at ${V09_SHA:0:12}, not its release commit" && grep -q "$PINW" "$T/.github/workflows/ci.yml"; } \
  && ok "upgrade catches a commit that does not match its version comment" || no "stray commit ($out)"
G checkout -q -- .github 2>/dev/null; G status --short | grep -q .github && G add -A >/dev/null

# --- a failed lookup changes nothing ---
X="$F/nolookup"; mkdir -p "$X/scripts"; echo "# conv" > "$X/CONVENTIONS.md"
printf '"""km promote — safe: gate before placing\n"""\n' > "$X/scripts/km_promote.py"
cp "$REPO/tests/fixtures/old-brain/pre-commit-config.yaml" "$X/.pre-commit-config.yaml"
( KM_REPO_URL="file://$F/no-such-repo" km upgrade --root "$X" >/dev/null 2>&1 ) && no "upgrade fails when the release cannot be looked up" || ok "upgrade fails when the release cannot be looked up"
{ [ -f "$X/scripts/km_promote.py" ] && grep -q "scripts/validate.py" "$X/.pre-commit-config.yaml"; } \
  && ok "...before changing anything" || no "...before changing anything"

# --- a release must exist to be pinned ---
git init -q "$F/norelease"
( KM_REPO_URL="file://$F/norelease" km init "$F/nr" --initials NR >/dev/null 2>&1 ) && no "init refuses a km version with no release commit" || ok "init refuses a km version with no release commit"
[ ! -e "$F/nr/CONVENTIONS.md" ] && ok "...and writes nothing" || no "...and writes nothing"
km init "$F/p09" --initials PP --pin v0.9.0 >/dev/null && grep -q "rev: $V09_SHA  # frozen: v0.9.0" "$F/p09/.pre-commit-config.yaml" \
  && ok "init --pin pins another released version" || no "init --pin v0.9.0"
out="$(km validate --root "$T" 2>&1)"; echo "$out" | grep -q "^km: " && no "no pin note when the pins match" || ok "no pin note when the pins match"

# --- the action commits brains get are the ones km's own workflows use, which Dependabot keeps current ---
python3 - "$REPO" <<'PY' && ok "template actions pin the same commits as km's own workflows" || no "template action commits drift from km's workflows"
import re, sys, glob
repo = sys.argv[1]
def pins(paths):
    out = {}
    for f in paths:
        for name, sha in re.findall(r"uses: ([\w.\-]+/[\w.\-]+)@([0-9a-f]{40})", open(f).read()):
            out.setdefault(name, set()).add(sha)
    return out
own = pins([f"{repo}/action.yml", *glob.glob(f"{repo}/.github/workflows/*.yml")])
tpl = pins(glob.glob(f"{repo}/src/km/templates/team/*.yml"))
# Actions only a template uses: no Dependabot here sees them; each brain's own Dependabot moves them.
TEMPLATE_ONLY = {"actions/create-github-app-token"}
sys.exit(0 if all(shas == own[name] if name in own else name in TEMPLATE_ONLY for name, shas in tpl.items()) else 1)
PY

# --- non-ASCII file names on a system whose encoding is not UTF-8 (Windows, cp1252) ---
tested=
for e in "LC_ALL=C PYTHONCOERCECLOCALE=0" "LC_ALL=en_US.ISO8859-1"; do
  windows_like "$e" || continue; tested=1
  out="$(with_env "$e" bash "$REPO/tests/encoding_smoke.sh" 2>&1)" && ok "[$e] encoding_smoke.sh" || no "[$e] encoding_smoke.sh:
$out"
done
[ -n "$tested" ] || echo "  skip: no Windows-like encoding here (Linux); the windows CI job runs encoding_smoke.sh"

# On Linux a non-UTF-8 locale changes the file-name encoding too: each name git lists must still
# open its file (the smoke CI job generates this locale)
L="$F/latin1"; mkdir -p "$L/notes"; git -C "$L" init -q; echo "# conv" > "$L/CONVENTIONS.md"
printf -- '---\ntitle: "no type"\n---\nx\n' > "$L/notes/künstler.md"; git -C "$L" add -A
e="LC_ALL=en_US.ISO-8859-1"
if with_env "$e" "$PY" -c 'import sys; sys.exit(sys.getfilesystemencoding() == "utf-8")' 2>/dev/null; then
  out="$(with_env "$e" km validate --root "$L" 2>&1)"
  { ! out_has Traceback && out_has "required field 'type' absent"; } \
    && ok "[$e] a non-ASCII name is validated where file names are not UTF-8" || no "[$e] non-UTF-8 file names ($out)"
else echo "  skip: no locale here whose file names are not UTF-8 (the smoke CI job has one)"; fi

# git's messages follow the locale: a Latin-1 one outside a repo must give km's error, not a traceback
N="$F/norepo"; mkdir -p "$N"
if [ -n "$(cd "$N" && LC_ALL=fr_FR.ISO8859-1 git rev-parse 2>&1 | LC_ALL=C tr -d '\0-\177')" ]; then
  out="$(with_env LC_ALL=fr_FR.ISO8859-1 km validate --root "$N" 2>&1)"
  { ! out_has Traceback && out_has "git ls-files failed"; } \
    && ok "a git error in a Latin-1 locale is reported, not a crash" || no "git error in a Latin-1 locale ($out)"
else echo "  skip: git prints no non-ASCII error in a Latin-1 locale here"; fi

# --- km's dependencies are pinned to the same exact versions everywhere ---
v="$(grep -oE 'pyyaml==[0-9.]+' "$REPO/pyproject.toml")"
{ [ -n "$v" ] && grep -q "$v" "$REPO/action.yml" && grep -q "$v" "$REPO/skills/km/bin/km" && grep -q '"setuptools==' "$REPO/pyproject.toml"; } \
  && ok "PyYAML and setuptools are pinned exactly, the same in pyproject, action and launcher" || no "dependency pins"

# --- one version everywhere ---
python3 - "$REPO" "$KM_REF" <<'PY' && ok "plugin.json and the README name this km version" || no "plugin.json and the README name this km version"
import json, re, sys
repo, ref = sys.argv[1], sys.argv[2]
lines = [ln for ln in open(f"{repo}/README.md") if "pasrom/km" in ln or "frozen:" in ln]
readme = {v for ln in lines for v in re.findall(r"\bv\d+\.\d+\.\d+\b", ln)}
sys.exit(0 if "v" + json.load(open(f"{repo}/.claude-plugin/plugin.json"))["version"] == ref and readme == {ref} else 1)
PY

# --- ci.yml takes workflow_dispatch, so a workflow that opens a pull request can run the check on it ---
on_keys(){ kmpy -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(" ".join(d.get(True, d.get("on"))))' "$1"; }
sans_dispatch(){ kmpy -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); d[True].pop("workflow_dispatch", None); print(d)' "$1"; }
[ "$(on_keys "$T/.github/workflows/ci.yml")" = "push pull_request workflow_dispatch" ] && ok "init writes ci.yml with workflow_dispatch" || no "init ci.yml triggers ($(on_keys "$T/.github/workflows/ci.yml"))"
[ "$(on_keys "$O/.github/workflows/ci.yml")" = "push pull_request workflow_dispatch" ] && ok "a copied-in ci.yml is rewritten with workflow_dispatch" || no "old ci.yml triggers"
D="$F/dispatch"; mkdir -p "$D/.github/workflows"; printf 'meta: {profile: d}\n' > "$D/schema.local.yaml"
grep -v "workflow_dispatch\|GITHUB_TOKEN starts no\|dispatches this one" "$T/.github/workflows/ci.yml" > "$D/.github/workflows/ci.yml"
printf '  extra:\n    steps: [{run: make}]\n' >> "$D/.github/workflows/ci.yml"     # the brain's own job stays
before="$(sans_dispatch "$D/.github/workflows/ci.yml")"
out="$(km upgrade --root "$D" 2>&1)"
{ [ "$(on_keys "$D/.github/workflows/ci.yml")" = "push pull_request workflow_dispatch" ] && out_has "added the workflow_dispatch trigger" \
  && [ "$(sans_dispatch "$D/.github/workflows/ci.yml")" = "$before" ]; } \
  && ok "upgrade adds workflow_dispatch to a km ci.yml without it, and changes nothing else" || no "upgrade adds workflow_dispatch ($out; $(cat "$D/.github/workflows/ci.yml"))"
! out_has "sign-off check" && ok "a ci.yml that checks sign-offs is left as it is" || no "sign-off check on km's own ci.yml ($out)"
S="$F/signoff"; mkdir -p "$S/.github/workflows"; printf 'meta: {profile: s}\n' > "$S/schema.local.yaml"
kmpy - "$T/.github/workflows/ci.yml" "$S/.github/workflows/ci.yml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()   # km's ci.yml as km 1.11.0 wrote it: one plain `run: km validate` step
old, n = re.subn(r"(?m)^ *# A pull request, or a dispatched run.*\n(?: *#.*\n)*(.*\n) *env:\n *BASE: .*\n( *)run: km validate .*\n", r"\1\2run: km validate\n", text)
assert n == 1, "the template's sign-off step moved"
open(sys.argv[2], "w").write(old)
PY
out="$(km upgrade --root "$S" --pin v0.9.0 --force 2>&1)"
{ grep -q '^ *run: km validate$' "$S/.github/workflows/ci.yml" && ! out_has "sign-off check"; } \
  && ok "upgrade to a km without --signoff-since leaves the step as it is" || no "sign-off step before its release ($out)"
out="$(km upgrade --root "$S" --pin v1.99.0 2>&1)"
nopin(){ grep -v '^ *#\|uses: pasrom/km@' "$1"; }
{ out_has "turned on the sign-off check" && diff <(nopin "$S/.github/workflows/ci.yml") <(nopin "$T/.github/workflows/ci.yml") >/dev/null; } \
  && ok "upgrade turns on the sign-off check in a km ci.yml without it, as the template has it" || no "upgrade sign-off step ($out; $(diff "$S/.github/workflows/ci.yml" "$T/.github/workflows/ci.yml"))"
kmpy - "$REPO/src" <<'PY' && ok "with_signoff skips a comment, odd jobs and a second step without a crash" || no "with_signoff edge cases"
import sys; sys.path.insert(0, sys.argv[1])
from km.upgrade import with_signoff
step = "jobs:\n  v:\n    steps:\n      - run: km validate\n"
assert "--signoff-since" in with_signoff("# TODO: --signoff-since\n" + step).split("\n", 1)[1]
for odd in (step + "  w:\n    steps:\n", step + "  w: text\n", "jobs:\n" + step[6:].replace("v:", "v: ~\n  x:", 1)):
    assert "--signoff-since" in with_signoff(odd), odd       # a job that is null or text is no reason to give up
assert with_signoff("jobs:\n") is None and with_signoff(step + "      - run: km validate\n") is None
PY
cp "$D/.github/workflows/ci.yml" "$F/dispatch.before"; out="$(km upgrade --root "$D" 2>&1)"
{ cmp -s "$D/.github/workflows/ci.yml" "$F/dispatch.before" && ! out_has "workflow_dispatch"; } && ok "a second upgrade leaves the trigger as it is" || no "dispatch idempotent ($out)"
printf 'on:\n  pull_request:\n# workflow_dispatch: not yet\njobs:\n  v:\n    steps:\n      - uses: %s\n' "$PINW" > "$D/.github/workflows/ci.yml"
out="$(km upgrade --root "$D" 2>&1)"
[ "$(on_keys "$D/.github/workflows/ci.yml")" = "pull_request workflow_dispatch" ] && ok "a comment that names the trigger does not count as the trigger" || no "dispatch behind a comment ($out)"
printf 'jobs:\n  v:\n    steps:\n      - uses: %s\non:\n  pull_request:' "$PINW" > "$D/.github/workflows/ci.yml"   # on: last, no newline at the end
out="$(km upgrade --root "$D" 2>&1)"
[ "$(on_keys "$D/.github/workflows/ci.yml")" = "pull_request workflow_dispatch" ] && ok "an on: block at the end of a file without a final newline gets the trigger" || no "dispatch at the end ($out)"
printf 'on: [push, pull_request]\njobs:\n  v:\n    steps:\n      - uses: %s\n' "$PINW" > "$D/.github/workflows/ci.yml"
cp "$D/.github/workflows/ci.yml" "$F/dispatch.before"; out="$(km upgrade --root "$D" 2>&1)"
{ cmp -s "$D/.github/workflows/ci.yml" "$F/dispatch.before" && out_has "add .workflow_dispatch:. under its .on:. by hand"; } \
  && ok "a one-line on: is left for a hand edit, with a note" || no "one-line on ($out)"
cp "$T/.github/workflows/staleness.yml" "$D/.github/workflows/"                   # still a team brain without km in ci.yml
printf 'on:\n  pull_request:\njobs:\n  v:\n    steps:\n      - run: make\n' > "$D/.github/workflows/ci.yml"
out="$(km upgrade --root "$D" 2>&1)"
[ "$(on_keys "$D/.github/workflows/ci.yml")" = "pull_request" ] && ok "a ci.yml that does not install km gets no trigger" || no "own ci.yml gets no trigger ($out)"

# --- the workflow that moves the mounted pins, and its script ---
PW=.github/workflows/bump-mounted-pins.yml; PS=.github/scripts/bump-mounted-pins.py
{ cmp -s "$T/$PW" "$REPO/src/km/templates/team/bump-mounted-pins.yml" && cmp -s "$T/$PS" "$REPO/src/km/templates/team/bump-mounted-pins.py"; } \
  && ok "a team brain gets the mounted-pins workflow and its script" || no "team brain mounted-pins files"
{ [ -f "$O/$PW" ] && [ -f "$O/$PS" ]; } && ok "upgrade adds them to a team brain without them" || no "upgrade adds the mounted-pins files"
[ ! -e "$P/$PW" ] && [ ! -e "$P/$PS" ] && ok "a personal brain does not get them" || no "personal brain has no mounted-pins files"
kmpy - <<'PY' && ok "SHIPPED lists the current templates of the copies a team brain carries" || no "a SHIPPED template changed: add its hash to SHIPPED in upgrade.py"
import sys, km.upgrade as u
from km.init import template
sys.exit(any(u.shipped_hash(template(t, {})) not in h for t, h in u.SHIPPED.items()))
PY
kmpy - <<'PY' && ok "every SHIPPED template says in its header that km upgrade replaces it" || no "a SHIPPED template header does not say km upgrade replaces it"
import sys, km.upgrade as u
from km.init import template
sys.exit(any(not all(w in " ".join(template(t, {}).splitlines()[:5]) for w in ("km upgrade", "replaces it")) for t in u.SHIPPED))
PY
kmpy -c 'import km.upgrade as u
h = u.shipped_hash
assert h("  - uses: a/b@1 # v1\n") == h("  - uses: a/b@2 # v2\n") and h("    uses: \"a/b@1\"\n") == h("    uses: \"a/b@2\"\n")
assert h("  - uses: a/b@1\n") != h("  - uses: a/c@1\n")' && ok "an action pin and its comment do not count as an edit, the action does" || no "shipped_hash masking"
kmpy -c 'import km.upgrade as u
new = "  - uses: a/b@k # v2.0.0\n  - uses: a/c@k # v2.0.0\n"
got = u.carry_pins("  - uses: a/b@n # v2.1.0\n  - uses: a/c@o # v1.9.9\n", new)
assert got == "  - uses: a/b@n # v2.1.0\n  - uses: a/c@k # v2.0.0\n", got' \
  && ok "an upgrade keeps an action pin the brain moved past the template, and takes the template pin where that is newer" || no "carry_pins direction"
# an earlier version km shipped is replaced, also after the brain's Dependabot moved its action
# pins: a stand-in for one (a line ahead of the template), registered as shipped for this run
MOVE='s/\(uses: actions\/checkout@\)[^ ]*.*/\1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v99/'
for f in "$PW:bump-mounted-pins.yml" "$PS:bump-mounted-pins.py"; do
  { echo "# an earlier km version"; sed "$MOVE" "$REPO/src/km/templates/team/${f#*:}"; } > "$O/${f%%:*}"
done
upgrade_older(){ out="$(cd "${1:-$O}" && kmpy - 2>&1 <<'PY'
import sys, km.upgrade as u
from km.init import template
for t, h in u.SHIPPED.items():
    h.add(u.shipped_hash("# an earlier km version\n" + template(t, {})))
sys.argv = ["km upgrade"]
sys.exit(u.main())
PY
)"; }
upgrade_older
{ cmp -s "$O/$PW" <(sed "$MOVE" "$REPO/src/km/templates/team/bump-mounted-pins.yml") && cmp -s "$O/$PS" "$REPO/src/km/templates/team/bump-mounted-pins.py" \
  && out_has "updated $PW to this km's version" && out_has "updated $PS to this km's version"; } \
  && ok "upgrade replaces a copy that is an earlier version km shipped, keeping the action pins its Dependabot moved" || no "upgrade replaces an unchanged earlier copy ($out)"
sed "$MOVE" "$O/$PW" > "$F/moved.yml" && mv "$F/moved.yml" "$O/$PW"; cp "$O/$PW" "$F/moved.yml"; upgrade_older
{ cmp -s "$O/$PW" "$F/moved.yml" && ! out_has "mounted-pins"; } \
  && ok "the current version with pins the brain's Dependabot moved is left as it is" || no "current copy with moved pins ($out)"
echo "# the brain's edit" >> "$O/$PW"; echo "# the brain's edit" >> "$O/$PS"; out="$(km upgrade --root "$O" 2>&1)"
{ tail -1 "$O/$PW" | grep -q "the brain's edit" && tail -1 "$O/$PS" | grep -q "the brain's edit" \
  && out_has "left $PW: the brain changed it" && out_has "left $PS: the brain changed it"; } \
  && ok "upgrade leaves an edited copy, with a note" || no "upgrade keeps edited mounted-pins files ($out)"
rm "$O/$PW"; touch "$O/.gitmodules"; out="$(km upgrade --root "$O" 2>&1)"; rm "$O/.gitmodules"
out_has "create the environment mounted-pins restricted to main" && ok "upgrade adding the workflow to a brain with mounts says to restrict the environment first" || no "environment note on upgrade ($out)"

TEAMH="km:km-validate:$GI pre-commit-hooks:no-commit-to-branch:--branch,main local:no-push-to-main:"   # a team brain's hooks, as hooks_of prints them
# --- main guard: the hook that refuses a commit on main, and the workflow that flags a direct push ---
hooks_of(){ kmpy -c 'import sys, yaml
print(" ".join(r["repo"].rsplit("/", 1)[-1] + ":" + h["id"] + ":" + ",".join(h.get("args", []))
               for r in yaml.safe_load(open(sys.argv[1]))["repos"] for h in r["hooks"]))' "$1"; }
{ [ "$(hooks_of "$T/.pre-commit-config.yaml")" = "$TEAMH" ] && grep -q "^default_install_hook_types: \[pre-commit, pre-push\]$" "$T/.pre-commit-config.yaml" && grep -q "^default_stages: \[pre-commit\]$" "$T/.pre-commit-config.yaml"; } \
  && ok "a team brain's hooks refuse a commit on main and a push to main, both installed by pre-commit install" || no "team hooks ($(hooks_of "$T/.pre-commit-config.yaml"))"
grep -q "branches: \[main\]" "$T/.github/workflows/main-guard.yml" \
  && ok "a team brain gets the main-guard workflow" || no "team brain main-guard workflow"
! grep -q "no-commit-to-branch\|no-push-to-main\|default_install_hook_types\|default_stages" "$P/.pre-commit-config.yaml" && ok "a personal brain keeps committing and pushing on main" || no "personal brain has no main hook"
{ [ -f "$O/.github/workflows/main-guard.yml" ] && [ "$(grep -c '^ *- id: no-commit-to-branch' "$O/.pre-commit-config.yaml")" = 1 ] \
  && [ "$(grep -c '^default_install_hook_types' "$O/.pre-commit-config.yaml")" = 1 ] && [ "$(grep -c '^default_stages' "$O/.pre-commit-config.yaml")" = 1 ] \
  && [ "$(hooks_of "$O/.pre-commit-config.yaml")" = "$TEAMH" ]; } \
  && ok "upgrade adds the guard workflow and both hooks to a team brain, once" || no "upgrade adds the main guard ($(cat "$O/.pre-commit-config.yaml"))"
# --- staleness: a checkout from before fetch-depth: 0 (km 1.3.0 and earlier) gets it ---
SW=.github/workflows/staleness.yml; cp "$O/$SW" "$F/stale.want"
sed '/uses: actions\/checkout@/{n;N;d;}' "$F/stale.want" > "$O/$SW"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$SW" "$F/stale.want" && out_has "gave the checkout step of $SW .fetch-depth: 0."; } \
  && ok "upgrade gives the staleness checkout fetch-depth: 0 where it lacks it, as the template has it" || no "staleness fetch-depth ($out; $(diff "$F/stale.want" "$O/$SW"))"
out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$SW" "$F/stale.want" && ! out_has "fetch-depth"; } && ok "a second upgrade leaves it as it is" || no "staleness fetch-depth again ($out)"
sed 's/fetch-depth: 0 .*/fetch-depth: 1/' "$F/stale.want" > "$O/$SW"; cp "$O/$SW" "$F/stale.own"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$SW" "$F/stale.own" && ! out_has "fetch-depth"; } && ok "a fetch-depth the brain set is left as it is" || no "staleness own fetch-depth ($out)"
sed 's/fetch-depth: 0 .*/persist-credentials: false/' "$F/stale.want" > "$O/$SW"; cp "$O/$SW" "$F/stale.own"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$SW" "$F/stale.own" && out_has "could not give the checkout step of $SW"; } \
  && ok "a checkout with a with: of its own and no fetch-depth is left as it is, with a note" || no "staleness own with ($out)"
# a staleness workflow of the brain's own (no km pin) is left alone: a fetch-depth dropped on purpose stays dropped
sed -e '/uses: actions\/checkout@/{n;N;d;}' -e 's|uses: pasrom/km@.*|run: pip install km|' "$F/stale.want" > "$O/$SW"; cp "$O/$SW" "$F/stale.own"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$SW" "$F/stale.own" && ! out_has "fetch-depth"; } && ok "a staleness workflow that does not pin km is left as it is" || no "staleness without km pin ($out)"
cp "$F/stale.want" "$O/$SW"
# --- approve-fork-ci: approves a fork's waiting ci run when the pull request changes only data ---
cmp -s "$T/$AF" "$AFT" && ok "init --team writes the approve-fork-ci workflow" || no "init --team approve-fork-ci"
rm "$O/$AF"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$AF" "$AFT" && out_has "added $AF"; } && ok "upgrade adds approve-fork-ci to a team brain that lacks it" || no "upgrade adds approve-fork-ci ($out)"
{ echo "# an earlier km version"; cat "$AFT"; } > "$O/$AF"; upgrade_older
{ cmp -s "$O/$AF" "$AFT" && out_has "updated $AF to this km's version"; } \
  && ok "upgrade replaces an approve-fork-ci that is an earlier version km shipped, so security fixes reach it" || no "upgrade replaces an earlier approve-fork-ci ($out)"
cp "$REPO/tests/fixtures/approve-fork-ci-1.13.0.yml" "$O/$AF"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$AF" "$AFT" && out_has "updated $AF to this km's version"; } \
  && ok "upgrade replaces the approve-fork-ci km 1.12.0 and 1.13.0 shipped" || no "upgrade replaces the 1.13.0 approve-fork-ci ($out)"
echo "# the brain's own guard" >> "$O/$AF"; cp "$O/$AF" "$F/af.before"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$AF" "$F/af.before" && out_has "left $AF: the brain changed it"; } \
  && ok "upgrade leaves a brain's own approve-fork-ci byte for byte, with a note" || no "upgrade overwrote approve-fork-ci ($out)"
N="$F/own-team-ci"; mkdir -p "$N/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$N/.github/workflows/"
printf 'meta: {profile: n}\n' > "$N/schema.local.yaml"; printf 'jobs:\n  t:\n    runs-on: x\n    steps:\n      - run: make\n' > "$N/.github/workflows/ci.yml"
out="$(km upgrade --root "$N" 2>&1)"
{ [ ! -e "$N/$AF" ] && [ -f "$N/.github/workflows/main-guard.yml" ] && out_has "did not add $AF"; } \
  && ok "upgrade gives no approve-fork-ci to a team brain whose ci.yml is its own, with a note" || no "approve-fork-ci with an own ci.yml ($out)"
sed "$MOVE" "$T/.github/workflows/ci.yml" > "$N/.github/workflows/ci.yml"; out="$(km upgrade --root "$N" 2>&1)"
cmp -s "$N/$AF" "$AFT" && ok "a km ci.yml whose action pins moved still gets approve-fork-ci" || no "approve-fork-ci with moved pins ($out)"
rm "$N/$AF"; grep -v "workflow_dispatch:" "$T/.github/workflows/ci.yml" > "$N/.github/workflows/ci.yml"; out="$(km upgrade --root "$N" 2>&1)"
{ cmp -s "$N/$AF" "$AFT" && out_has "added the workflow_dispatch trigger"; } \
  && ok "a km ci.yml from before the dispatch trigger gets approve-fork-ci and the trigger in one run" || no "approve-fork-ci without dispatch ($out)"
rm "$N/$AF"; printf '      - run: python tools/check.py\n' >> "$N/.github/workflows/ci.yml"; out="$(km upgrade --root "$N" 2>&1)"
{ [ ! -e "$N/$AF" ] && out_has "did not add $AF" && grep -q "pasrom/km" "$N/.github/workflows/ci.yml"; } \
  && ok "a km ci.yml with a step of the brain's own gets no approve-fork-ci, with a note" || no "approve-fork-ci with an extra ci step ($out)"
kmpy -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); open(sys.argv[2], "w", encoding="utf-8").write(
    t.replace("run: km gen-index --check\n", "run: km gen-index --check\n          \u00a0#$(touch pwned)\n", 1))' "$T/.github/workflows/ci.yml" "$N/.github/workflows/ci.yml"
out="$(km upgrade --root "$N" 2>&1)"
{ [ ! -e "$N/$AF" ] && out_has "did not add $AF" && grep -q "#\$(touch pwned)" "$N/.github/workflows/ci.yml"; } \
  && ok "a ci.yml line that only looks like a comment but runs (NBSP before #) gets no approve-fork-ci" || no "approve-fork-ci with a hidden step ($out)"
sed "s/branches: \[main\]/branches: [trunk]/" "$T/.github/workflows/ci.yml" > "$N/.github/workflows/ci.yml"; out="$(km upgrade --root "$N" 2>&1)"
{ cmp -s "$N/$AF" "$AFT" && grep -q "branches: \[trunk\]" "$N/.github/workflows/ci.yml"; } \
  && ok "a km ci.yml on a default branch other than main gets approve-fork-ci" || no "approve-fork-ci on trunk ($out)"
rm "$N/$AF"; printf 'jobs:\n  t:\n    runs-on: x\n    steps:\n      - run: make\n' > "$N/.github/workflows/ci.yml"
{ echo "# an earlier km version"; cat "$AFT"; } > "$N/$AF"; upgrade_older "$N"
{ cmp -s "$N/$AF" "$AFT" && out_has "updated $AF to this km's version" && out_has "$AF lets a fork's ci run start unreviewed, but ci.yml is not km's unchanged one"; } \
  && ok "upgrade warns about an approve-fork-ci beside a ci.yml that is not km's, and still brings an earlier km copy up to date" || no "approve-fork-ci beside an edited ci ($out)"
Z="$F/zero-indent"; mkdir -p "$Z/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$Z/.github/workflows/"
printf 'meta: {profile: z}\n' > "$Z/schema.local.yaml"
printf 'repos:\n- repo: https://github.com/pasrom/km\n  rev: %s  # frozen: %s\n  hooks:\n  - id: km-validate\n' "$KM_SHA" "$KM_REF" > "$Z/.pre-commit-config.yaml"
out="$(km upgrade --root "$Z" 2>&1)"
[ "$(hooks_of "$Z/.pre-commit-config.yaml" 2>&1)" = "$TEAMH" ] \
  && ok "the added hooks follow the brain's own indent" || no "hook indent ($out; $(cat "$Z/.pre-commit-config.yaml"))"
W="$F/with-keys"; mkdir -p "$W/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$W/.github/workflows/"
printf 'meta: {profile: w}\n' > "$W/schema.local.yaml"
printf 'default_stages: [pre-commit]\nrepos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: %s\n    hooks:\n      - id: km-validate\n  - repo: local\n    hooks:\n      - id: no-commit-to-branch\n        name: x\n        entry: x\n        language: system\n        args: [--branch, master]\n\nci:\n  skip:\n  - km-validate\n' "$KM_SHA" "$KM_REF" > "$W/.pre-commit-config.yaml"
out="$(km upgrade --root "$W" 2>&1)"
{ [ "$(hooks_of "$W/.pre-commit-config.yaml" 2>&1)" = "km:km-validate:$GI local:no-commit-to-branch:--branch,master pre-commit-hooks:no-commit-to-branch:--branch,main local:no-push-to-main:" ] \
  && kmpy -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); sys.exit(d["ci"] != {"skip": ["km-validate"]} or d["default_stages"] != ["pre-commit"] or d["default_install_hook_types"] != ["pre-commit", "pre-push"])' "$W/.pre-commit-config.yaml"; } \
  && ok "the hooks go into repos: before a later key, a hook guarding another branch does not count, other keys stay" || no "hook placement ($out; $(cat "$W/.pre-commit-config.yaml"))"
X="$F/types"; mkdir -p "$X/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$X/.github/workflows/"
printf 'meta: {profile: x}\n' > "$X/schema.local.yaml"
printf 'default_install_hook_types: [pre-commit, commit-msg]\nrepos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: %s\n    hooks:\n      - id: km-validate\n' "$KM_SHA" "$KM_REF" > "$X/.pre-commit-config.yaml"
out="$(km upgrade --root "$X" 2>&1)"
{ grep -q "^default_install_hook_types: \[pre-commit, commit-msg, pre-push\]$" "$X/.pre-commit-config.yaml" && grep -q "^default_stages: \[pre-commit\]$" "$X/.pre-commit-config.yaml" \
  && out_has "pre-push in default_install_hook_types"; } && ok "pre-push is appended to a one-line install types list" || no "types list ($out; $(cat "$X/.pre-commit-config.yaml"))"
printf 'default_install_hook_types:\n  - pre-commit\nrepos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: %s\n    hooks:\n      - id: km-validate\n' "$KM_SHA" "$KM_REF" > "$X/.pre-commit-config.yaml"
cp "$X/.pre-commit-config.yaml" "$F/types.before"; out="$(km upgrade --root "$X" 2>&1)"
d="$(diff "$F/types.before" "$X/.pre-commit-config.yaml" | grep '^[<>]')"
{ [ "$d" = "${GI:+>       - id: km-gen-index}" ] \
  && out_has "could not add the hooks"; } && ok "a block-style install types list is left for a hand edit, with a note (km-gen-index goes in all the same)" || no "block types ($out)"
printf 'default_install_hook_types: [pre-commit, pre-push]\nrepos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: %s\n    hooks:\n      - id: km-validate\n' "$KM_SHA" "$KM_REF" > "$X/.pre-commit-config.yaml"
out="$(km upgrade --root "$X" 2>&1)"
{ grep -q "^default_stages: \[pre-commit\]$" "$X/.pre-commit-config.yaml" && [ "$(grep -c '^default_install_hook_types' "$X/.pre-commit-config.yaml")" = 1 ] && ! out_has "pre-commit install. again"; } \
  && ok "a config that already installs pre-push still gets default_stages with the hooks" || no "default_stages with types present ($out; $(cat "$X/.pre-commit-config.yaml"))"
# a brain that already has both hooks and the install types is left alone
cp "$T/.pre-commit-config.yaml" "$F/full.before"; out="$(km upgrade --root "$T" 2>&1)"
cmp -s "$T/.pre-commit-config.yaml" "$F/full.before" && ! out_has "pre-commit-config" && ok "a config with both hooks is left as it is" || no "hooks added twice ($out)"
R="$F/flow"; mkdir -p "$R/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$R/.github/workflows/"
printf 'meta: {profile: r}\n' > "$R/schema.local.yaml"; printf 'repos: [{repo: local, hooks: [{id: y, name: y, entry: y, language: system}]}]\n' > "$R/.pre-commit-config.yaml"
cp "$R/.pre-commit-config.yaml" "$F/flow.before"; out="$(km upgrade --root "$R" 2>&1)"
{ cmp -s "$R/.pre-commit-config.yaml" "$F/flow.before" && out_has "could not add the hook"; } \
  && ok "a config the edit cannot handle is left alone, with a note" || no "flow-style config ($out)"
Q="$F/own-ci"; mkdir -p "$Q/.github/workflows"; printf 'meta: {profile: q}\n' > "$Q/schema.local.yaml"
printf 'jobs:\n  t:\n    runs-on: x\n    steps:\n      - run: make\n' > "$Q/.github/workflows/ci.yml"; cp "$P/.pre-commit-config.yaml" "$Q/"
km upgrade --root "$Q" >/dev/null 2>&1
{ [ ! -e "$Q/.github/workflows/main-guard.yml" ] && ! grep -q no-commit-to-branch "$Q/.pre-commit-config.yaml"; } \
  && ok "a personal brain with a ci.yml of its own is not taken for a team brain" || no "own ci.yml makes a team brain"
# --- km-gen-index: the hook that fails a commit with a stale _index.md, in a team brain's km entry ---
grep -q "km-gen-index" "$P/.pre-commit-config.yaml" && no "a personal brain gets no km-gen-index hook" || ok "a personal brain gets no km-gen-index hook (its CI runs no gen-index --check)"
NEWH="km:km-validate: km:km-gen-index: pre-commit-hooks:no-commit-to-branch:--branch,main local:no-push-to-main:"   # pinned to v1.99.0
km init "$F/t199" --team --name N --desc n --initials NN --folder d=D --pin v1.99.0 >/dev/null
{ [ "$(hooks_of "$F/t199/.pre-commit-config.yaml")" = "$NEWH" ] && [ "$(grep -c "pasrom/km" "$F/t199/.pre-commit-config.yaml")" = 1 ]; } \
  && ok "init --team pinning a km with the hook writes it into the km entry: one km pin" || no "init --pin v1.99.0 ($(cat "$F/t199/.pre-commit-config.yaml"))"
km init "$F/t09" --team --name O --desc o --initials OO --folder d=D --pin v0.9.0 >/dev/null
{ grep -q "km-validate" "$F/t09/.pre-commit-config.yaml" && ! grep -q "km-gen-index" "$F/t09/.pre-commit-config.yaml"; } \
  && ok "init --team pinning a km without the hook does not name it (pre-commit would fail on the unknown id)" || no "init --pin v0.9.0 names km-gen-index"
cp "$F/t09/.pre-commit-config.yaml" "$F/t09.before"; out="$(km upgrade --root "$F/t09" --pin v0.9.0 2>&1)"
{ cmp -s "$F/t09/.pre-commit-config.yaml" "$F/t09.before" && ! out_has "km-gen-index"; } && ok "upgrade to a km without the hook does not add it" || no "upgrade --pin v0.9.0 adds km-gen-index ($out)"
out="$(km upgrade --root "$F/t09" --pin v1.99.0 2>&1)"
{ [ "$(hooks_of "$F/t09/.pre-commit-config.yaml")" = "$NEWH" ] \
  && grep -q "rev: $NEW_SHA  # frozen: v1.99.0" "$F/t09/.pre-commit-config.yaml" && out_has "added the km-gen-index hook"; } \
  && ok "upgrade that moves the pin to a km with the hook adds it to the km entry" || no "upgrade adds km-gen-index ($out; $(cat "$F/t09/.pre-commit-config.yaml"))"
out="$(km upgrade --root "$F/t09" --pin v0.9.0 --force 2>&1)"
out_has "names the km-gen-index hook, which km v0.9.0 lacks: remove it by hand" && ok "upgrade --force back to a km without the hook says to remove it" || no "downgrade note ($out)"
I="$F/gen-index"; mkdir -p "$I/.github/workflows"; cp "$T/.github/workflows/staleness.yml" "$I/.github/workflows/"; printf 'meta: {profile: i}\n' > "$I/schema.local.yaml"
cat > "$I/.pre-commit-config.yaml" <<YML
default_install_hook_types: [pre-commit, pre-push]
default_stages: [pre-commit]
repos:
  - repo: 'https://github.com/pasrom/km.git'
    hooks:
      - id: km-validate
        args: [--strict]
        # a comment under the hook

    rev: $KM_SHA  # frozen: $KM_REF
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: 3e8a8703264a2f4a69428a0aa4dcb512790b2c8c  # frozen: v6.0.0
    hooks:
      - id: no-commit-to-branch
        args: [--branch, main]
  - repo: local
    hooks:
      - id: no-push-to-main
        name: x
        entry: x
        language: system
YML
out="$(km upgrade --root "$I" --pin v1.99.0 2>&1)"
{ [ "$(hooks_of "$I/.pre-commit-config.yaml" 2>&1)" = "km.git:km-validate:--strict km.git:km-gen-index: pre-commit-hooks:no-commit-to-branch:--branch,main local:no-push-to-main:" ] \
  && grep -q "^    rev: $NEW_SHA  # frozen: v1.99.0$" "$I/.pre-commit-config.yaml" && out_has "added the km-gen-index hook" \
  && [ "$(kmpy -c 'from pathlib import Path; import sys, km.pins as p; print(len(p.read_pins(Path(sys.argv[1]))[".pre-commit-config.yaml"]))' "$I")" = 1 ]; } \
  && ok "km-gen-index goes after a hook with args, before a rev that follows hooks:, in a quoted .git entry" || no "gen-index placement ($out; $(cat "$I/.pre-commit-config.yaml"))"
printf 'repos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: %s\n    hooks: [{id: km-validate}]\n' "$KM_SHA" "$KM_REF" > "$I/.pre-commit-config.yaml"
out="$(km upgrade --root "$I" --pin v1.99.0 2>&1)"
{ ! grep -q "km-gen-index" "$I/.pre-commit-config.yaml" && out_has "could not add km's km-gen-index hook"; } \
  && ok "a flow-style km hooks list gets a by-hand note, not a second km entry" || no "flow hooks ($out; $(cat "$I/.pre-commit-config.yaml"))"
kmpy -c 'import km.init as i
assert not i.gen_index_hook("v0.9.0") and not i.gen_index_hook("v1.10.1") and i.gen_index_hook("v1.10.2") and i.gen_index_hook("v1.11.0") and not i.gen_index_hook("main")
assert i.with_gen_index("repos:\n  - repo: local\n    hooks:\n      - id: km-validate\n") is None' \
  && ok "the hook is named for the releases after v1.10.1 only; a config without a km entry is not touched" || no "gen_index_hook / no km entry"
# The workflow's check, run with a stand-in gh: a merged PR per commit passes; an unmerged commit or a
# force push fails and opens an issue.
SB="$F/stub"; mkdir -p "$SB"
cat > "$SB/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  api) case "$2" in *"/commits/bad"*) echo 0 ;; *"/commits/down"*) exit 1 ;; *) echo 1 ;; esac ;;
  issue) echo "issue $*" >> "$GH_LOG" ;;
esac
SH
printf '#!/bin/sh\n' > "$SB/sleep"; chmod +x "$SB/gh" "$SB/sleep"
kmpy -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["check"]["steps"][0]["run"])' "$T/.github/workflows/main-guard.yml" > "$F/guard.sh"
guard(){ GH_LOG="$F/gh.log" PATH="$SB:$PATH" REPO=o/r FORCED="$1" COMMITS="$2" PUSHER=p RUN=u bash "$F/guard.sh" >/dev/null 2>&1; }
rm -f "$F/gh.log"; guard false '["good1","good2"]' && [ ! -f "$F/gh.log" ] && ok "main-guard passes commits from merged PRs" || no "main-guard passes merged commits"
rm -f "$F/gh.log"; ! guard false '["good1","bad2"]' && grep -q "Direct push to main" "$F/gh.log" && ok "main-guard fails and opens an issue on a commit without a PR" || no "main-guard flags an unmerged commit"
rm -f "$F/gh.log"; ! guard true '["good1"]' && grep -q "issue" "$F/gh.log" && ok "main-guard fails on a force push" || no "main-guard flags a force push"
rm -f "$F/gh.log"; ! guard false '["good1","down2"]' && [ ! -f "$F/gh.log" ] && ok "a failed lookup fails main-guard without a false issue" || no "main-guard on a failed lookup"
kmpy -c 'import km.upgrade as u; from km.init import template; raise SystemExit(u.ci_hash(template("team/ci.yml", {})) not in u.KM_CI)' \
  && ok "KM_CI lists the current team ci template" || no "team/ci.yml changed: add its ci_hash to KM_CI in upgrade.py"
kmpy - <<'PY' && ok "a km ci.yml with the sign-off step turned on by upgrade still counts as km's" || no "with_signoff result not in KM_CI"
import re, km.upgrade as u
from km.init import template
t = template("team/ci.yml", {})
old, n = re.subn(r"(?m)^( *)env:\n *BASE: .*\n( *)run: km validate .*\n", r"\2run: km validate\n", t)
raise SystemExit(n != 1 or u.ci_hash(u.with_signoff(old)) not in u.KM_CI)
PY
kmpy -c 'import km.upgrade as u
assert [u.ci_hash(t) is None for t in ("jobs: {a: {steps: 3}}", "a: &x [*x]", "- a", "{1: a, b: c}")] == [False, True, True, False]' \
  && ok "ci_hash takes a malformed ci.yml (steps not a list, an alias cycle, no mapping, mixed keys) without a traceback" || no "ci_hash on a malformed ci.yml"
# approve-fork-ci's script, run with a stand-in gh that serves one pull request's compare, tree, pull
# requests and waiting runs from files, logs every call and each approval
if command -v jq >/dev/null; then
AB="$F/af-stub"; mkdir -p "$AB"
cat > "$AB/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$AF_DIR/calls"
[ -n "${AF_FAIL:-}" ] && case "$*" in *"$AF_FAIL"*) exit 1 ;; esac
[ "$2" = -X ] && { echo "approve $4" >> "$AF_DIR/approved"; exit 0; }
case "$*" in
  */compare/*) cat "$AF_DIR/compare.json" ;;
  */git/trees/*) cat "$AF_DIR/tree.json" ;;
  *pulls\?*) if [ -f "$AF_DIR/pulls.seen" ]; then touch "$AF_DIR/pulls2.seen"; cat "$AF_DIR/pulls2.json"; else touch "$AF_DIR/pulls.seen"; cat "$AF_DIR/pulls.json"; fi ;;
  */issues/*/timeline*) n="$*"; n="${n#*/issues/}"; n="${n%%/*}"
    if [ -f "$AF_DIR/pulls2.seen" ] && [ -f "$AF_DIR/timeline.late.json" ]; then cat "$AF_DIR/timeline.late.json"
    elif [ -f "$AF_DIR/timeline.$n.json" ]; then cat "$AF_DIR/timeline.$n.json"; else cat "$AF_DIR/timeline.json"; fi ;;
  *actions/runs\?*) cat "$AF_DIR/runs.json" ;;
esac
SH
chmod +x "$AB/gh"
kmpy -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["approve"]["steps"][0]["run"])' "$T/$AF" > "$F/af.sh"
# afrun FILES-JSON [CHANGED]: 0 when it approved run 7; 1 when it left it to a person with a notice and
# exit 0; 2 when it exited 0 with neither; 3 when it failed (a crash would turn every fork pull request
# red). TREE, PRS, PRS2 (the pull requests from the second lookup on, the one right before approving),
# TIMELINE (of every pull request), TIMELINE2 (of pull request 2 only), TIMELINE_LATE (of every pull
# request from the second lookup on), SINCE (the event's time), RUN, AF_REF (the fork's branch),
# AF_DEFAULT and AF_FAIL (a call that fails) override the stand-in; the calls it made are in $AFD/calls
AFD="$F/af"; mkdir -p "$AFD"
RUN_OF(){ printf '{"id":7,"path":".github/workflows/ci.yml","head_repository":{"full_name":"%s"},"head_branch":"%s","created_at":"%s"}' "$@"; }
PR(){ printf '{"number":%s,"state":"%s","base":{"ref":"%s"}}' "$@"; }
BASE_AT(){ printf '[{"event":"base_ref_changed","created_at":"%s"}]' "$1"; }   # a timeline with a base change at that time
afrun(){ local prs tree='{"truncated":false,"tree":[]}' run
  prs="[$(PR 1 open main)]"; run="$(RUN_OF f/r "${AF_REF:-x}" 2026-01-01T00:00:09Z)"
  rm -f "$AFD"/*; printf '{"files":%s}' "$1" > "$AFD/compare.json"
  printf '%s' "${TREE:-$tree}" > "$AFD/tree.json"; printf '%s' "${TIMELINE:-[]}" > "$AFD/timeline.json"
  [ -z "${TIMELINE2:-}" ] || printf '%s' "$TIMELINE2" > "$AFD/timeline.2.json"
  [ -z "${TIMELINE_LATE:-}" ] || printf '%s' "$TIMELINE_LATE" > "$AFD/timeline.late.json"
  printf '%s' "${PRS:-$prs}" > "$AFD/pulls.json"; printf '%s' "${PRS2:-${PRS:-$prs}}" > "$AFD/pulls2.json"
  printf '{"workflow_runs":[%s]}' "${RUN:-$run}" > "$AFD/runs.json"
  AF_DIR="$AFD" PATH="$AB:$SB:$PATH" REPO=o/r BASE=b SHA=s HEAD_REPO=f/r HEAD_REF="${AF_REF:-x}" DEFAULT="${AF_DEFAULT:-main}" \
    SINCE="${SINCE:-2026-01-01T00:00:05Z}" CHANGED="${2:-$(printf '%s' "$1" | jq length)}" bash "$F/af.sh" > "$AFD/out" 2>&1 || return 3
  grep -qx "approve repos/o/r/actions/runs/7/approve" "$AFD/approved" 2>/dev/null && return 0
  grep -q "^::notice::" "$AFD/out" && return 1 || return 2; }
refuse(){ local name="$1"; shift; afrun "$@"; [ $? = 1 ] || refused="$refused $name"; }
called(){ grep -qxF "$1" "$AFD/calls"; }
{ afrun '[{"filename":"d/a.md"},{"filename":"d/p.png"},{"filename":"README.md"}]' \
  && called "api repos/o/r/compare/b...s" && called "api repos/o/r/git/trees/s?recursive=1" \
  && called "api --paginate repos/o/r/pulls?state=all&per_page=100&head=f%3Ax" \
  && called "api --paginate repos/o/r/issues/1/timeline?per_page=100" \
  && called "api repos/o/r/actions/runs?head_sha=s&status=action_required&event=pull_request"; } \
  && ok "approve-fork-ci approves a pull request of data only, through exactly the API calls it means" \
  || no "approve-fork-ci on data ($(cat "$AFD/calls" "$AFD/out" 2>/dev/null))"
missed=""; approves(){ local name="$1"; shift; afrun "$@" || missed="$missed $name"; }
PRS="[$(PR 1 open main),$(PR 2 closed main)]" approves earlier-closed-pr '[{"filename":"d/a.md"}]'
AF_DEFAULT=trunk PRS="[$(PR 1 open trunk)]" approves default-branch-trunk '[{"filename":"d/a.md"}]'
AF_REF='a/b&c#d' approves branch-to-encode '[{"filename":"d/a.md"}]'
called "api --paginate repos/o/r/pulls?state=all&per_page=100&head=f%3Aa%2Fb%26c%23d" || missed="$missed branch-encoding"
# a base change long before the run (an old retarget of a closed or the open pull request) blocks no later run
TIMELINE2="$(BASE_AT 2025-12-01T00:00:00Z)" PRS="[$(PR 1 open main),$(PR 2 closed main)]" approves old-base-change '[{"filename":"d/a.md"}]'
called "api --paginate repos/o/r/issues/2/timeline?per_page=100" || missed="$missed timeline-of-every-pr"
TIMELINE="$(BASE_AT 2025-12-31T23:55:00Z)" RUN="$(RUN_OF f/r x 2026-01-01T00:00:00Z)" approves run-300s-after-base-change '[{"filename":"d/a.md"}]'
# GitHub may stamp the run a second before the pull request's update: 30 s before SINCE still counts
RUN="$(RUN_OF f/r x 2025-12-31T23:59:35Z)" approves run-30s-before-event '[{"filename":"d/a.md"}]'
[ -z "$missed" ] && ok "approve-fork-ci also approves beside an earlier closed pull request, after a base change long before the run, a run stamped up to 30 s before the event, on a default branch other than main, and for a branch name it must encode" \
  || no "approve-fork-ci did not approve:$missed"
AF_FAIL=/approve afrun '[{"filename":"d/a.md"}]'; rc=$?
{ [ $rc = 2 ] && grep -q "^::warning::could not approve run 7" "$AFD/out"; } \
  && ok "approve-fork-ci on a failed approval warns and ends green" || no "approve-fork-ci failed approval (rc $rc; $(cat "$AFD/out"))"
refused=""
AF_FAIL=compare/ refuse compare-fails '[{"filename":"d/a.md"}]'
AF_FAIL=git/trees refuse tree-fails '[{"filename":"d/a.md"}]'
AF_FAIL=pulls refuse pulls-fails '[{"filename":"d/a.md"}]'
AF_FAIL=timeline refuse timeline-fails '[{"filename":"d/a.md"}]'
refuse script '[{"filename":"d/a.md"},{"filename":"d/run.py"}]'
refuse .github '[{"filename":".github/workflows/x.yml"}]'
refuse top-level-yaml '[{"filename":"schema.local.yaml"}]'
refuse rename '[{"filename":"d/a.md","previous_filename":"d/a.py"}]'
TREE='{"truncated":false,"tree":[{"path":"d/l.md","mode":"120000"}]}' refuse symlink '[{"filename":"d/l.md"}]'
TREE='{"truncated":true,"tree":[]}' refuse truncated '[{"filename":"d/a.md"}]'
refuse count '[{"filename":"d/a.md"}]' 2
refuse empty '[]'
AF_DEFAULT=trunk refuse not-the-default-branch '[{"filename":"d/a.md"}]'
PRS="[$(PR 1 open main),$(PR 2 open main)]" refuse second-pr '[{"filename":"d/a.md"}]'
PRS="[$(PR 1 open main)][$(PR 2 closed legacy)]" refuse closed-pr-other-base '[{"filename":"d/a.md"}]'
PRS2="[$(PR 1 open main),$(PR 2 open legacy)]" refuse pr-opened-while-waiting '[{"filename":"d/a.md"}]'
TIMELINE='[{"event":"labeled"}][{"event":"base_ref_changed"}]' refuse base-changed '[{"filename":"d/a.md"}]'
TIMELINE='[{"event":"automatic_base_change_succeeded"}]' refuse base-changed-by-github '[{"filename":"d/a.md"}]'
# the branch forced back to this commit: a closed pull request, retargeted to main after its run for
# another base was made, ended on another commit; the run predates the base change
TIMELINE2="$(BASE_AT 2026-01-01T00:00:08Z)" PRS="[$(PR 1 open main),$(PR 2 closed main)]" refuse closed-pr-base-changed-after-the-run '[{"filename":"d/a.md"}]'
TIMELINE="$(BASE_AT 2025-12-31T23:55:01Z)" RUN="$(RUN_OF f/r x 2026-01-01T00:00:00Z)" refuse run-299s-after-base-change '[{"filename":"d/a.md"}]'
# a run inside the 30 s before the event, but before a base change in that window
TIMELINE="$(BASE_AT 2025-12-31T23:59:50Z)" RUN="$(RUN_OF f/r x 2025-12-31T23:59:40Z)" refuse in-window-before-base-change '[{"filename":"d/a.md"}]'
TIMELINE_LATE="$(BASE_AT 2026-01-01T00:00:08Z)" refuse base-changed-while-waiting '[{"filename":"d/a.md"}]'
TIMELINE='[{"event":"base_ref_changed","created_at":"soon"}]' refuse base-change-time-unreadable '[{"filename":"d/a.md"}]'
{ grep -q "dated in the future or cannot be read" "$AFD/out" && ! grep -q "actions/runs?" "$AFD/calls"; } || refused="$refused unreadable-base-change-polls"
# a retarget a moment ago is no future date, but no run made since can count before the wait ends
TIMELINE="$(BASE_AT "$(jq -rn 'now - 10 | todate')")" refuse fresh-retarget '[{"filename":"d/a.md"}]'
{ grep -q "retargeted less than 5 minutes ago" "$AFD/out" && ! grep -q "actions/runs?" "$AFD/calls"; } || refused="$refused fresh-retarget"
RUN="$(RUN_OF f/r y 2026-01-01T00:00:09Z)" refuse other-branch '[{"filename":"d/a.md"}]'
RUN="$(RUN_OF g/r x 2026-01-01T00:00:09Z)" refuse other-fork '[{"filename":"d/a.md"}]'
RUN="$(RUN_OF f/r x 2025-12-31T23:59:34Z)" refuse run-before-event '[{"filename":"d/a.md"}]'
RUN="$(RUN_OF f/r x not-a-time)" refuse run-time-unreadable '[{"filename":"d/a.md"}]'
SINCE=garbage refuse event-time-unreadable '[{"filename":"d/a.md"}]'
[ -z "$refused" ] && ok "approve-fork-ci leaves code, .github, top-level config, renames, links, a bad count, failed reads, other pull requests, a changed base, other forks and branches, and an older run to a person, with a notice" \
  || no "approve-fork-ci approved or crashed on:$refused"
else no "the approve-fork-ci tests need jq"; fi

# --- review-request-guide: one comment that says what comes before asking the maintainer ---
RG=.github/workflows/review-request-guide.yml; RGT="$REPO/src/km/templates/team/review-request-guide.yml"
cmp -s "$T/$RG" "$RGT" && ok "init --team writes the review-request-guide workflow" || no "init --team review-request-guide"
rm "$O/$RG"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$RG" "$RGT" && out_has "added $RG" && out_has "until the repository variable KM_MAINTAINERS"; } && ok "upgrade adds review-request-guide to a team brain that lacks it" || no "upgrade adds review-request-guide ($out)"
cp "$REPO/tests/fixtures/review-request-guide-1.13.1.yml" "$O/$RG"; out="$(km upgrade --root "$O" 2>&1)"
{ cmp -s "$O/$RG" "$RGT" && out_has "updated $RG to this km's version"; } \
  && ok "upgrade replaces the review-request-guide km 1.13.1 shipped" || no "upgrade replaces the 1.13.1 review-request-guide ($out)"
# its script, run with a stand-in gh that serves the pull request's files, the blobs, schema.local.yaml and the
# comments from files, and keeps what it posts or patches
if command -v jq >/dev/null && command -v yq >/dev/null; then
RB="$F/rg-stub"; RGD="$F/rg"; mkdir -p "$RB" "$RGD"
cat > "$RB/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$RG_DIR/calls"
[ -n "${RG_FAIL:-}" ] && case "$*" in *"$RG_FAIL"*) exit 1 ;; esac
case "$*" in
  *"-X POST "*) echo "$4" > "$RG_DIR/posted.url"; jq -r .body > "$RG_DIR/posted" ;;
  *"-X PATCH "*) echo "$4" > "$RG_DIR/patched.url"; jq -r .body > "$RG_DIR/patched" ;;
  */pulls/9/files*) cat "$RG_DIR/files.json" ;;
  */pulls/9) cat "$RG_DIR/pr.json" ;;
  *contents/schema.local.yaml*) cat "$RG_DIR/schema.yaml" 2>/dev/null || exit 1 ;;
  */git/blobs/*) u="${@: -1}"; cat "$RG_DIR/blobs/${u##*/}" 2>/dev/null || exit 1 ;;
  */comments*) cat "$RG_DIR/comments.json" ;;
esac
SH
chmod +x "$RB/gh"
command -v timeout >/dev/null || { printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$RB/timeout"; chmod +x "$RB/timeout"; }   # stock macOS has none
kmpy -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["guide"]["steps"][0]["run"])' "$T/$RG" > "$F/rg.sh"
fmd(){ printf -- '---\n%s\n---\nbody\n' "$1"; }       # a doc with this frontmatter
EVIL='d/`'$'\n''```'$'\n''@everyone ::error::pwned.md'   # a file name that would close a code block, mention and pose as a command
# rgrun: run the script on the pull request of the docs in rg_docs (path<TAB>content, one per
# entry of RG_FILES); RG_LABELS, RG_REVIEWERS (the pull request as it is now), RG_MAINT, RG_DRAFT, RG_SCHEMA,
# RG_COMMENTS, RG_ACTION, RG_LABEL (the event's), RG_STATE, RG_REQUESTED and RG_FAIL override the stand-in. Returns 3 when the script failed; its log is $RGD/out
rgrun(){ local i=0 files='[]' p
  rm -rf "$RGD"/*; mkdir -p "$RGD/blobs"
  for p in "${RG_PATHS[@]}"; do
    i=$((i + 1)); local sha; sha="$(printf '%040d' "$i")"
    printf '%s' "${RG_TEXTS[$((i - 1))]}" > "$RGD/blobs/$sha"
    files="$(jq -c --arg f "$p" --arg s "$sha" --arg st "${RG_STATUS[$((i - 1))]:-modified}" '. + [{filename: $f, sha: $s, status: $st}]' <<<"$files")"
  done
  printf '%s' "$files" > "$RGD/files.json"
  [ -n "${RG_SCHEMA:-}" ] && printf '%s' "$RG_SCHEMA" > "$RGD/schema.yaml"
  printf '%s' "${RG_COMMENTS:-[]}" > "$RGD/comments.json"
  jq -n --argjson l "${RG_LABELS:-[]}" --argjson r "${RG_REVIEWERS:-[\"Maint\"]}" --arg d "${RG_DRAFT:-false}" --arg c "${RG_CHANGED:-$i}" \
    --arg s "${RG_STATE:-open}" '{state: $s, labels: ($l | map({name: .})), requested_reviewers: ($r | map({login: .})), draft: ($d == "true"),
      changed_files: ($c | tonumber), head: {sha: "abcdef0123456789"}}' > "$RGD/pr.json"
  RG_DIR="$RGD" PATH="$RB:$SB:$PATH" REPO=o/r PR=9 ACTION="${RG_ACTION:-review_requested}" LABEL="${RG_LABEL:-km:ready}" REQUESTED="${RG_REQUESTED-Maint}" \
    MAINTAINERS="${RG_MAINT-other, maint}" bash "${RG_SCRIPT:-$F/rg.sh}" > "$RGD/out" 2>&1 || return 3; }
has(){ grep -qxF -- "$2" "$RGD/$1"; }
section(){ sed -n "/^\*\*$1/,/^\$/p" "$RGD/posted"; }   # a list of the comment, by its heading
RG_PATHS=(d/a.md d/b.md d/c.md d/old.md d/_index.md README.md brains/p/x.md d/n.md d/p.png "$EVIL" d/e.md d/gone.md)
RG_TEXTS=("$(fmd $'status: review\naudience: internal\napproval: ai')"
  "$(fmd $'status: review\nreviewed_by: ["ai:m 2026-01-01"]')"
  "$(fmd $'status: accepted\napproved_by: TT\napproved_digest: x')"
  "$(fmd 'status: superseded')" "$(fmd 'status: draft')" "$(fmd 'status: draft')" "$(fmd 'status: draft')"
  "no frontmatter" "png" "$(fmd 'status: draft')"
  "$(fmd $'status: accepted\napproved_by: TT\naudience: internal')" "$(fmd 'status: draft')")
RG_STATUS=(modified added modified modified modified modified modified added added added modified removed)
rgrun; rc=$?
EVILQ="$(jq -nr --arg f "$EVIL" '$f | @json')"
{ [ $rc = 0 ] && [ ! -e "$RGD/patched" ] && has posted.url "repos/o/r/issues/9/comments" && has posted "<!-- km:review-request-guide -->" \
  && [ "$(section 'No AI review' | grep -c '^"')" = 3 ] \
  && section 'No AI review' | grep -qxF '"d/a.md"' \
  && section 'No AI review' | grep -qxF '"d/e.md"' \
  && has posted '"d/a.md"  level ai  status review' && has posted '"d/b.md"  level human  status review' \
  && has posted "$EVILQ  level human  status draft" && has posted '"d/e.md"  level human  status accepted' \
  && section 'No frontmatter' | grep -qxF '"d/n.md"' \
  && ! grep -q 'c\.md\|old\.md\|_index\.md\|README\.md\|brains/\|p\.png\|gone\.md' "$RGD/posted" \
  && grep -q "needs the sign-off of a person who knows its subject" "$RGD/posted" && grep -q "as of abcdef012345:" "$RGD/posted"; } \
  && ok "review-request-guide comments with the docs that lack an AI review, those not signed off at their level, and those without frontmatter" \
  || no "review-request-guide comment (rc $rc; $(cat "$RGD/calls" "$RGD/out" "$RGD/posted" 2>/dev/null))"
{ [ "$(grep -c '^```$' "$RGD/posted")" = 6 ] && ! grep -q '^@everyone\|^::error' "$RGD/posted" "$RGD/out" && grep -qF "$EVILQ" "$RGD/out"; } \
  && ok "review-request-guide quotes a hostile file name as JSON, in the comment and the log" || no "review-request-guide hostile name ($(cat "$RGD/out" "$RGD/posted"))"
( RG_SCHEMA=$'approval_default: ai\nskip_prefixes: [d/x/]'; RG_PATHS=(d/e.md d/f.md d/x/y.md); RG_STATUS=()
  RG_TEXTS=("$(fmd $'status: draft\naudience: internal')" "$(fmd $'status: draft\naudience: customer')" "$(fmd 'status: draft')"); rgrun )
{ has posted '"d/e.md"  level ai  status draft' && has posted '"d/f.md"  level human  status draft' && ! grep -q "d/x/y.md" "$RGD/posted"; } \
  && ok "review-request-guide takes the level default and the skipped folders from schema.local.yaml at the base" || no "review-request-guide schema ($(cat "$RGD/out" "$RGD/posted"))"
# the level of each doc is km's approval_level, for a spread of frontmatter (km as the oracle)
LVL=($'audience: internal\napproval: ai' $'audience: internal\napproval: human' $'approval: ai' $'audience: customer\napproval: ai'
  $'audience: internal\napproval: ai\ntype: verbatim-block' $'audience: internal\napproval: ""' $'audience: internal\napproval: false'
  $'audience: [internal]\napproval: ai' $'audience: internal\napproval: [ai]' $'audience: internal')
for sch in "" "ai"; do
  ( RG_SCHEMA="${sch:+approval_default: $sch}"; RG_PATHS=(); RG_TEXTS=(); RG_STATUS=()
    for i in "${!LVL[@]}"; do RG_PATHS+=("d/l$i.md"); RG_TEXTS+=("$(fmd $'status: draft\n'"${LVL[$i]}")"); done; rgrun )
  want="$(printf '%s\0' "${LVL[@]}" | kmpy -c 'import sys, yaml, km.common as c
c.APPROVAL_DEFAULT = sys.argv[1] or "human"
for i, fm in enumerate(sys.stdin.read().split("\0")[:-1]):
    print(f"\"d/l{i}.md\"  level {c.approval_level(yaml.safe_load(fm))}  status draft")' "$sch")"
  got="$(grep '^"d/l[0-9]*\.md"  level' "$RGD/posted")"
  [ "$want" = "$got" ] && ok "review-request-guide gives each doc km's approval level (approval_default ${sch:-unset})" \
    || no "review-request-guide levels differ from km's (approval_default ${sch:-unset}): $(diff <(echo "$want") <(echo "$got") | tr "\n" " ")"
done
kmpy -c 'import sys, yaml
from km.paths import TEMPLATES
base = yaml.safe_load((TEMPLATES.parent / "schema.base.yaml").read_text())
text = open(sys.argv[1]).read()
sys.exit(any(f"\"{v}\"" not in text for k in ("exempt_files", "skip_prefixes", "reserved_no_frontmatter") for v in base[k]))' "$RGT" \
  && ok "review-request-guide knows the skipped folders and exempt names of km's base schema" || no "review-request-guide misses a default of schema.base.yaml"
( RG_PATHS=(d/c.md); RG_TEXTS=("$(fmd $'status: accepted\napproved_by: TT\napproved_digest: x')"); RG_STATUS=(); rgrun )
{ grep -q "^Every changed doc carries a sign-off" "$RGD/posted" && ! grep -q '^\*\*' "$RGD/posted"; } \
  && ok "review-request-guide on signed-off docs only points to km:ready" || no "review-request-guide all signed off ($(cat "$RGD/posted"))"
BOT='{"id":5,"user":{"login":"github-actions[bot]"},"body":"<!-- km:review-request-guide -->\nold"}'
SPOOF='{"id":4,"user":{"login":"someone"},"body":"<!-- km:review-request-guide -->\nmine"}'
RG_COMMENTS="[$SPOOF,$BOT]" rgrun
{ [ ! -e "$RGD/posted" ] && has patched.url "repos/o/r/issues/comments/5" && has patched '"d/a.md"  level ai  status review'; } \
  && ok "review-request-guide updates its own comment instead of adding one, and never another's with the marker" || no "review-request-guide update ($(cat "$RGD/calls" "$RGD/out"))"
RG_COMMENTS="[$SPOOF]" rgrun
{ [ ! -e "$RGD/patched" ] && [ -e "$RGD/posted" ]; } && ok "review-request-guide posts its own comment beside a marker someone else wrote" || no "review-request-guide spoofed marker ($(cat "$RGD/calls"))"
RG_MAINT='Other,MAINT' RG_REVIEWERS='["maint"]' rgrun; [ -e "$RGD/posted" ] && ok "review-request-guide matches a maintainer's login whatever its case" || no "review-request-guide login case ($(cat "$RGD/out"))"
quiet=""; silent(){ local name="$1"; shift; "$@"; rc=$?
  { [ $rc = 0 ] && [ ! -e "$RGD/posted" ] && [ ! -e "$RGD/patched" ] && grep -q "^::notice::" "$RGD/out"; } || quiet="$quiet $name"; }
RG_LABELS='["x","km:ready"]' silent km-ready rgrun
RG_REVIEWERS='["someone"]' silent not-a-maintainer rgrun
RG_MAINT='' silent maintainers-unset rgrun; grep -q 'KM_MAINTAINERS is not set' "$RGD/out" || quiet="$quiet maintainers-unset-notice"
RG_MAINT=' , ' silent maintainers-blank rgrun
RG_DRAFT=true silent draft rgrun
RG_FAIL=/files silent files-fail rgrun
RG_FAIL=pulls/9 silent pr-read-fails rgrun
RG_REVIEWERS='["maint","expert"]' RG_REQUESTED=expert silent maintainer-asked-earlier rgrun
RG_MAINT=joanna RG_REVIEWERS='["joanna","ann"]' RG_REQUESTED=ann silent login-substring rgrun
RG_ACTION=ready_for_review RG_REVIEWERS='["expert"]' silent ready-no-maintainer rgrun
RG_LABELS='["x"]' RG_ACTION=labeled RG_LABEL=x silent other-label rgrun
RG_ACTION=unlabeled RG_LABEL=wip RG_COMMENTS="[$BOT]" silent other-label-removed rgrun
RG_STATE=closed RG_ACTION=unlabeled RG_COMMENTS="[$BOT]" silent closed rgrun
[ -z "$quiet" ] && ok "review-request-guide stays silent on a km:ready pull request, no maintainer requested now or by this request (a login that is part of one included), KM_MAINTAINERS unset, a draft, another label set or removed, a closed pull request, and a failed read of the pull request or its files" \
  || no "review-request-guide commented or failed on:$quiet"
RG_ACTION=ready_for_review RG_REVIEWERS='["expert","Maint"]' rgrun; a=$?; [ -e "$RGD/posted" ] || a=1
RG_REVIEWERS='["expert","Maint"]' rgrun; [ -e "$RGD/posted" ] || a=1
[ "$a" = 0 ] && ok "review-request-guide decides from the reviewers requested now, whichever event's run it is" || no "review-request-guide current reviewers ($(cat "$RGD/out"))"
( RG_PATHS=(); RG_TEXTS=(); RG_STATUS=(); long="$(printf 'x%.0s' {1..1500})"
  for i in $(seq 1 60); do RG_PATHS+=("d/$i-$long.md"); RG_TEXTS+=("$(fmd 'status: draft')"); done; rgrun )
{ [ "$(wc -c < "$RGD/posted")" -lt 65536 ] && grep -qx '\.\.\. and [0-9]* more' "$RGD/posted"; } \
  && ok "review-request-guide shortens its lists to stay under GitHub's comment limit" || no "review-request-guide long comment ($(wc -c < "$RGD/posted"))"
( RG_PATHS=(d/a.md d/s.md d/e.md d/w.md d/shift.md); RG_STATUS=()
  RG_TEXTS=("$(fmd 'status: draft')" $'---\nstatus: draft\n--- \nbody\n' $'---\n---\nbody\n' $'\xef\xbb\xbf---\r\nstatus: review\r\n---\r\nbody\r\n'
    "$(fmd $'title: "Using << for the frame"\nstatus: draft')"); rgrun )
{ [ "$(section 'No frontmatter' | grep '^"')" = '"d/e.md"' ] && has posted '"d/s.md"  level human  status draft' && has posted '"d/w.md"  level human  status review' \
  && has posted '"d/shift.md"  level human  status draft'; } \
  && ok "review-request-guide reads the frontmatter block as km does: after a BOM, CRLF too, closed by a line that starts with ---, never empty" || no "review-request-guide frontmatter end ($(cat "$RGD/posted"))"
# data that would cost yq time or memory, or that yq reads otherwise than PyYAML, is left to ci, and
# a large doc is read to its end (awk stopping early must not fail a writer under pipefail)
BOMB='a: &a ["x","x","x","x","x","x","x","x","x"]'; for v in b c d e f g h i; do BOMB="$BOMB"$'\n'"$v: &$v [$(printf "*${p:-a},%.0s" 1 2 3 4 5 6 7 8)*${p:-a}]"; p=$v; done; unset p
BIG="$(fmd 'status: draft')$(head -c 600000 /dev/zero | tr '\0' 'x')"
EDGE="$(fmd 'status: draft')"; EDGE="$EDGE$(head -c $((1000000 - ${#EDGE})) /dev/zero | tr '\0' x)"$'\n'"$(head -c 500000 /dev/zero | tr '\0' x)"   # byte 1 000 001 is a newline
WIDE="$(fmd 'status: draft')$(for i in $(seq 1 6000); do printf '\303\251%.0s' $(seq 1 100); done)"   # 1.2 MB, 600 000 characters
( RG_PATHS=(d/bomb.md d/merge.md d/big.md d/huge.md d/flow.md d/merge2.md d/merge3.md d/wide.md d/edge.md); RG_STATUS=()
  RG_TEXTS=("$(fmd "$BOMB")" "$(fmd $'<<: {status: accepted}')" "$BIG" "$BIG$BIG" "$(fmd 'x: {"a":&a [1], "b":*a}')" "$(fmd $'"<<" : {status: accepted}')" \
    "$(fmd $'? <<\n: {status: accepted}')" "$WIDE" "$EDGE"); rgrun ); rc=$?
left="$(section 'No frontmatter' | grep '^"' | tr '\n' ' ')"
{ [ $rc = 0 ] && [ "$left" = '"d/bomb.md" "d/merge.md" "d/huge.md" "d/flow.md" "d/merge2.md" "d/merge3.md" "d/wide.md" "d/edge.md" ' ] \
  && has posted '"d/big.md"  level human  status draft'; } \
  && ok "review-request-guide leaves an alias bomb, merge keys and a doc over 1 MB (counted in bytes, cut while read) to ci, and reads a 600 KB doc" \
  || no "review-request-guide unsafe or large docs (rc $rc; left to ci: $left; $(cat "$RGD/out"))"
# (whether the cut also stops the download depends on the platform's pipes: on GitHub's runners the
# writer finished every read, so only the call count is checked)
api="$(grep -c '^api' "$RGD/calls")"
[ "$api" -lt 16 ] && ok "review-request-guide makes one API call per doc" || no "review-request-guide API calls: $api"
# an AI sign-off does not count at level human: km's is_ai_approver decides, over a spread of approvers
APV=('"ai:m"' '[" AI:m"]' '"  ai:m"' '"\tai:m "' '["ai:x", "TT"]' '[null, "ai:x"]' 'TT' '""')
( RG_PATHS=(d/lvl-ai.md); RG_STATUS=(); RG_TEXTS=("$(fmd $'status: accepted\napproved_by: "ai:m"\napproved_digest: x\naudience: internal\napproval: ai')")
  for i in "${!APV[@]}"; do RG_PATHS+=("d/p$i.md"); RG_TEXTS+=("$(fmd $'status: accepted\napproved_digest: x\napproved_by: '"${APV[$i]}")"); done; rgrun )
want="$(printf '%s\0' "${APV[@]}" | kmpy -c 'import sys, yaml, km.common as c
for i, v in enumerate(sys.stdin.read().split("\0")[:-1]):
    by = yaml.safe_load("a: " + v)["a"]
    if not by or c.is_ai_approver(by):
        print(f"\"d/p{i}.md\"  level human  status accepted")')"
got="$(grep '^"d/\(p[0-9]*\|lvl-ai\)\.md"  level' "$RGD/posted")"
[ "$want" = "$got" ] && ok "review-request-guide counts an AI sign-off only at level ai, as km's is_ai_approver reads the approver" \
  || no "review-request-guide AI approvers differ from km's: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"
( RG_PATHS=(d/no.md d/qno.md d/on.md d/qon.md); RG_STATUS=()
  RG_TEXTS=("$(fmd $'status: review\nreviewed_by: no')" "$(fmd $'status: review\nreviewed_by: "no"')" "$(fmd $'status: accepted\napproved_by: "ON"\napproved_digest: x')" "$(fmd $'status: "On"\nreviewed_by: [x]')"); rgrun )
{ [ "$(section 'No AI review' | grep '^"')" = '"d/no.md"' ] && ! grep -q '"d/on.md"' "$RGD/posted" && has posted '"d/qon.md"  level human  status other'; } \
  && ok "review-request-guide reads a plain YAML 1.1 bool word as PyYAML does, and a quoted one as a string" || no "review-request-guide YAML 1.1 words ($(cat "$RGD/posted"))"
RG_LABELS='["km:ready"]' RG_ACTION=labeled RG_COMMENTS="[$BOT]" rgrun
{ [ ! -e "$RGD/posted" ] && has patched.url "repos/o/r/issues/comments/5" && grep -q "is labelled \`km:ready\`: once ci is green" "$RGD/patched"; } \
  && ok "review-request-guide turns its comment into a km:ready note once the label is set" || no "review-request-guide km:ready note ($(cat "$RGD/calls" "$RGD/out"))"
NOTE="$(jq -c --rawfile b "$RGD/patched" '{id: 5, user: {login: "github-actions[bot]"}, body: ($b | rtrimstr("\n"))}' <<<null)"
RG_LABELS='["km:ready"]' RG_ACTION=labeled RG_COMMENTS="[$NOTE]" rgrun; a=$?; [ -e "$RGD/patched" ] && a=1
RG_LABELS='["km:ready"]' RG_ACTION=labeled rgrun; [ -e "$RGD/patched" ] || [ -e "$RGD/posted" ] && a=1
[ "$a" = 0 ] && ok "review-request-guide leaves an up-to-date comment alone, and adds no km:ready note where it never commented" || no "review-request-guide note rewrite ($(cat "$RGD/calls"))"
RG_ACTION=unlabeled RG_REVIEWERS='[]' RG_DRAFT=true RG_COMMENTS="[$NOTE]" rgrun
{ has patched.url "repos/o/r/issues/comments/5" && has patched '"d/a.md"  level ai  status review' && grep -q "^This pull request is no longer labelled" "$RGD/patched"; } \
  && ok "review-request-guide lists the docs again when km:ready is removed, on a draft and with no maintainer requested too" || no "review-request-guide unlabeled ($(cat "$RGD/out"))"
RG_ACTION=unlabeled RG_REVIEWERS='[]' rgrun; { [ ! -e "$RGD/posted" ] && [ ! -e "$RGD/patched" ]; } \
  && ok "review-request-guide adds no comment when km:ready is removed from a pull request it never commented on" || no "review-request-guide unlabeled without comment"
# the job filter keeps other reviewers' events out of the concurrency group, where they would cancel a
# maintainer's waiting run
kmpy - "$RGT" <<'KMPY' && ok "review-request-guide lets only a maintainer's request, ready_for_review and km:ready set or removed into its per-job concurrency group" \
  || no "review-request-guide job filter or concurrency"
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); j = w["jobs"]["guide"]; c = " ".join(j.get("if", "").split())
needles = ("vars.KM_MAINTAINERS != ''", "contains(vars.KM_MAINTAINERS, github.event.requested_reviewer.login)",
           "github.event.action == 'unlabeled'", "github.event.label.name == 'km:ready'")
types = set(w[True]["pull_request_target"]["types"])   # YAML 1.1 reads the key `on` as True
sys.exit("concurrency" in w or "concurrency" not in j or any(n not in c for n in needles)
         or types != {"review_requested", "ready_for_review", "labeled", "unlabeled"})
KMPY
RG_FAIL=/git/blobs/ rgrun; rc=$?
{ [ $rc = 0 ] && section 'Could not be read' | grep -qxF '"d/a.md"' && ! section 'No frontmatter' | grep -q .; } \
  && ok "review-request-guide lists a doc it could not read as such, not as one without frontmatter" || no "review-request-guide unread doc (rc $rc; $(cat "$RGD/out"))"
sed 's/"\$SECONDS" -le 420/"$SECONDS" -le -1/' "$F/rg.sh" > "$F/rg0.sh"   # the read budget already spent
RG_SCRIPT="$F/rg0.sh" rgrun; rc=$?
{ ! cmp -s "$F/rg.sh" "$F/rg0.sh" && [ $rc = 0 ] && section 'Could not be read' | grep -qxF '"d/a.md"' && ! grep -q '/git/blobs/' "$RGD/calls"; } \
  && ok "review-request-guide stops reading docs when its time budget is spent, and still comments" || no "review-request-guide read budget (rc $rc; $(cat "$RGD/out"))"
RG_FAIL="-X POST" rgrun; rc=$?
{ [ $rc = 0 ] && grep -q "^::warning::could not comment" "$RGD/out"; } && ok "review-request-guide on a failed comment warns and ends green" || no "review-request-guide failed post (rc $rc)"
else no "the review-request-guide tests need jq and yq"; fi

# --- upgrade records approved_digest for docs approved before km recorded it ---
D="$F/digest"; km init "$D" --team --name D --desc d --initials DD --folder d=D --pin v0.9.0 >/dev/null
acc_doc(){ # acc_doc FILE TITLE STATUS "extra lines"; TYPE= overrides concept, RB= (empty) drops review_by
  local rb="${RB-2099-01-01}"
  printf -- '---\ntype: %s\ntitle: %s\ntimestamp: 2026-01-15\nauthor: DD\nstatus: %s\naudience: internal\nlanguage: en\ntags: [t]\nowner: DD\n%b%b---\nbody\n' \
    "${TYPE:-concept}" "$2" "$3" "${rb:+review_by: $rb\n}" "${4:-}" > "$1"; }
acc_doc "$D/d/legacy.md" legacy accepted 'approved_by: DD\napproved_at: 2026-01-15\n'
acc_doc "$D/d/open.md" open review
acc_doc "$D/d/edited.md" edited accepted 'approved_by: DD\napproved_at: 2026-01-15\n'
acc_doc "$D/d/drift.md" drift accepted 'approved_by: DD\napproved_at: 2026-01-15\n'
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" "${G[@]}" commit -qm init
sed -i.bak 's/^body$/changed after the approval/; s/^tags: \[t\]$/tags: [t, u]/' "$D/d/drift.md" && rm -f "$D/d/drift.md.bak"
sed -i.bak 's/^tags: \[t\]$/tags: [t, u]/' "$D/d/legacy.md" && rm -f "$D/d/legacy.md.bak"
git -C "$D" "${G[@]}" commit -qam "edit after the approval"
sed -i.bak 's/^body$/edited, not approved/' "$D/d/edited.md" && rm -f "$D/d/edited.md.bak"
out="$(km upgrade --root "$D" --pin v0.9.0 2>&1)"
{ ! grep -q approved_digest "$D/d/legacy.md" && ! out_has "approved_digest"; } \
  && ok "upgrade to a km that does not check the digest records none" || no "upgrade --pin v0.9.0 records a digest ($out)"
out="$(km upgrade --root "$D" --pin v1.99.0 2>&1)"
{ grep -q '^approved_digest: "[0-9a-f]\{16\}"$' "$D/d/legacy.md" && ! grep -q approved_digest "$D/d/open.md" \
  && out_has "recorded approved_digest for the current content of 1 accepted doc(s), taking that text as the approved one" && out_has "d/legacy.md"; } \
  && ok "upgrade records the digest of each accepted doc's current content, and says so" || no "upgrade records digests ($out; $(cat "$D/d/legacy.md"))"
{ ! grep -q approved_digest "$D/d/edited.md" && out_has "d/edited.md (uncommitted changes)"; } \
  && ok "upgrade takes no uncommitted text as approved" || no "upgrade and an edited doc ($out)"
{ ! grep -q approved_digest "$D/d/drift.md" && out_has "recorded no approved_digest for d/drift.md (changed since its approval)"; } \
  && ok "upgrade takes no text committed after the approval as approved (a tags-only commit is fine)" || no "upgrade and a drifted doc ($out)"
out="$(KM_LOCAL=1 km validate --root "$D" "$D/d/legacy.md" 2>&1)" && ok "a doc given its digest by upgrade validates" || no "validate after upgrade ($out)"
sed -i.bak 's/^body$/changed body/' "$D/d/legacy.md" && rm -f "$D/d/legacy.md.bak"
out="$(KM_LOCAL=1 km validate --root "$D" "$D/d/legacy.md" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "approval-stale"; } && ok "after the upgrade, a content change fails a team brain's gate" || no "stale after upgrade ($rc: $out)"
cp "$D/d/legacy.md" "$F/legacy.before"; out="$(km upgrade --root "$D" --pin v1.99.0 2>&1)"
{ cmp -s "$D/d/legacy.md" "$F/legacy.before" && ! out_has "approved_digest"; } \
  && ok "a second upgrade keeps the recorded digest (never takes a changed text as approved)" || no "second upgrade ($out)"
acc_doc "$D/d/byhand.md" byhand accepted 'approved_by: DD\napproved_at: 2026-01-15\n'; git -C "$D" add -A && git -C "$D" "${G[@]}" commit -qam byhand
out="$(km upgrade --root "$D" --pin v1.99.0 --force 2>&1)"
{ ! grep -q approved_digest "$D/d/byhand.md" && ! out_has "approved_digest" && out_has "have approved_by but no digest" && out_has "d/byhand.md"; } \
  && ok "an upgrade on a brain already past the digest release records none (records once, on the crossing), and lists the docs" || no "upgrade after the crossing ($out)"

# a schema km cannot read stops the upgrade before it moves the pins, so a run after the fix still records the digests
D2="$F/digest2"; km init "$D2" --team --name D --desc d --initials DD --folder d=D --pin v0.9.0 >/dev/null
acc_doc "$D2/d/legacy.md" legacy accepted 'approved_by: DD\napproved_at: 2026-01-15\n'; cp "$D2/schema.local.yaml" "$F/sl2.ok"
printf 'fields: {title: 7}\n' >> "$D2/schema.local.yaml"; git -C "$D2" init -q && git -C "$D2" add -A && git -C "$D2" "${G[@]}" commit -qm init
out="$(km upgrade --root "$D2" --pin v1.99.0 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "^schema.local.yaml: fields.title must be a mapping" && ! grep -rq "v1.99.0" "$D2/.github/workflows" && ! out_has Traceback; } \
  && ok "upgrade over a schema km cannot read stops with the schema message before it moves the pins" || no "upgrade with a broken schema ($rc: $out)"
cp "$F/sl2.ok" "$D2/schema.local.yaml"; out="$(km upgrade --root "$D2" --pin v1.99.0 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q '^approved_digest:' "$D2/d/legacy.md" && grep -rq "v1.99.0" "$D2/.github/workflows"; } \
  && ok "the upgrade run after the schema is fixed records the digests and moves the pins" || no "upgrade after the schema fix ($rc: $out)"

# pins moved past the digest release (Dependabot, pre-commit autoupdate) before km upgrade ran: no crossing, so no
# digest, not even for an approval committed under the old pins (a branch can write such a commit and pin comment
# around a typed approval); the upgrade lists those docs with what each needs once a pull request changes it
D3="$F/digest3"; km init "$D3" --team --name D --desc d --initials DD --folder d=D --pin v0.9.0 >/dev/null
S11="$(git -C "$F/remote" rev-parse v1.11.0)"
acc_doc "$D3/d/legacy.md" legacy accepted 'approved_by: DD\napproved_at: 2026-01-15\n'
acc_doc "$D3/d/open.md" open review
acc_doc "$D3/d/body.md" body accepted 'approved_by: DD\napproved_at: 2026-01-15\n'; printf 'approved_digest: in the body\n' >> "$D3/d/body.md"
git -C "$D3" init -q && git -C "$D3" add -A && git -C "$D3" "${G[@]}" commit -qm "approved under km 0.9.0"
repin "$V09_SHA" v0.9.0 "$S11" v1.11.0 "$D3"/.github/workflows/*.yml "$D3/.pre-commit-config.yaml"
git -C "$D3" "${G[@]}" commit -qam "bump km to 1.11.0"
out="$(km upgrade --root "$D3" --pin v1.99.0 2>&1)"
{ ! grep -rq '^approved_digest: "' "$D3/d" && out_has "2 accepted doc(s) have approved_by but no digest" && out_has "records none: d/body.md, d/legacy.md\." \
  && out_has "km demote <doc>" && ! out_has "d/open.md"; } \
  && ok "upgrade after the pins moved past the digest release records no digest and lists each accepted doc without one" || no "upgrade after the pins moved ($out)"
git -C "$D3" checkout -q -- . && git -C "$D3" clean -qfd
sed -i.bak 's/^\( *\)run: km validate .*/\1run: km validate \&\& true/' "$D3/.github/workflows/ci.yml" && rm -f "$D3/.github/workflows/ci.yml.bak"
git -C "$D3" "${G[@]}" commit -qam "a ci step km cannot turn the sign-off check on in"
out="$(km upgrade --root "$D3" --pin v1.99.0 2>&1)"
{ out_has "could not turn on the sign-off check" && ! out_has "no digest"; } \
  && ok "where the sign-off check could not be turned on, no list says it will catch those docs" || no "upgrade without the sign-off check ($out)"
git -C "$D3" checkout -q -- . && git -C "$D3" rm -q .github/workflows/ci.yml && git -C "$D3" "${G[@]}" commit -qm "no ci"
out="$(km upgrade --root "$D3" --pin v1.99.0 2>&1)"
! out_has "no digest" && ok "nor in a brain without km's ci" || no "upgrade without a ci ($out)"

# --- upgrade past 1.11.0 regenerates the '## Documents' lists, which km 1.11.0 wrote with titles as YAML reads them ---
X="$F/xidx"; km init "$X" --team --name X --desc x --initials XX --folder d=D --pin v1.11.0 >/dev/null
doc "$X/d/ver.md" 1.10; doc "$X/d/flag.md" false
printf -- '---\ntitle: [unclosed\n---\nbroken\n' > "$X/d/broken.md"   # km gen-index lists it by its file name
old_list(){ kmpy - "$1" <<'PY'   # the list as km 1.11.0 wrote it: YAML's reading of a title
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(re.sub(r"(?s)## Documents.*", "## Documents\n\n- [Broken](broken.md)\n- [False](flag.md)\n- [1.1](ver.md)\n", t))
PY
}
git -C "$X" init -q && git -C "$X" add -A && (cd "$X" && km gen-index >/dev/null)
old_list "$X/d/_index.md"; cp "$X/d/_index.md" "$F/xidx.old"; git -C "$X" add -A && git -C "$X" "${G[@]}" commit -qm init
cp "$X/schema.local.yaml" "$F/xidx.sl"; printf 'fields: {title: 7}\n' >> "$X/schema.local.yaml"
out="$(km upgrade --root "$X" --pin v1.99.0 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "^schema.local.yaml: fields.title must be a mapping" && cmp -s "$X/d/_index.md" "$F/xidx.old" \
  && ! grep -rq "v1.99.0" "$X/.github/workflows" && ! out_has Traceback; } \
  && ok "upgrade past 1.11.0 over a schema km cannot read stops before the lists and the pins" || no "index regen, broken schema ($rc: $out)"
cp "$F/xidx.sl" "$X/schema.local.yaml"
out="$(km upgrade --root "$X" --pin v1.99.0 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -qx -- '- \[1.10\](ver.md)' "$X/d/_index.md" && grep -qx -- '- \[false\](flag.md)' "$X/d/_index.md" \
  && grep -qx -- '- \[Broken\](broken.md)' "$X/d/_index.md" && out_has "regenerated the '## Documents' list of d/_index.md:" \
  && grep -rq "v1.99.0" "$X/.github/workflows" && (cd "$X" && km gen-index --check >/dev/null 2>&1); } \
  && ok "upgrade from 1.11.0 past it regenerates the lists (an unparseable doc by its name), says so, and gen-index --check passes" \
  || no "index regen on upgrade ($rc: $out; $(cat "$X/d/_index.md"))"
git -C "$X" add -A && git -C "$X" "${G[@]}" commit -qm upgrade
cp "$X/d/_index.md" "$F/xidx.new"; out="$(km upgrade --root "$X" --pin v1.99.0 2>&1)"
{ cmp -s "$X/d/_index.md" "$F/xidx.new" && ! out_has "regenerated"; } && ok "a second upgrade regenerates nothing" || no "index regen twice ($out)"
cp "$F/xidx.old" "$X/d/_index.md"; out="$(km upgrade --root "$X" --pin v1.11.0 --force 2>&1)"
{ cmp -s "$X/d/_index.md" "$F/xidx.old" && ! out_has "regenerated"; } \
  && ok "upgrade --force back to 1.11.0 does not regenerate with the new rules" || no "index regen on a downgrade ($out)"
doc "$X/e/x.md" X; git -C "$X" add -A && git -C "$X" "${G[@]}" commit -qm "a folder without an index"
out="$(km upgrade --root "$X" --pin v1.99.0 2>&1)"
out_has "e/ hold docs but no _index.md" && ok "upgrade past 1.11.0 names a folder gen-index --check fails on for its missing _index.md" || no "unindexed note ($out)"
P="$F/pidx"; km init "$P" --initials PP --pin v1.11.0 >/dev/null; doc "$P/inbox/ver.md" 1.10
printf 'fields: {title: 7}\n' >> "$P/schema.local.yaml"   # read by no step of this upgrade, as before
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" "${G[@]}" commit -qm init
out="$(km upgrade --root "$P" --pin v1.99.0 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! out_has "regenerated" && [ -z "$(git -C "$P" status --porcelain -- '*_index.md')" ]; } \
  && ok "a brain with no generated list is left alone, its schema not read" || no "index regen, personal brain ($rc: $out)"

# --- a team brain: a type without expiry is accepted without review_by, the others still need it ---
signed='approved_by: DD\napproved_at: 2026-01-15\n'
RB= TYPE=decision acc_doc "$D/d/nx-decision.md" Decided accepted "$signed"
RB= TYPE=transcript acc_doc "$D/d/nx-transcript.md" Met accepted "${signed}participants: [DD]\n"
RB= acc_doc "$D/d/nx-concept.md" Concept accepted "$signed"
out="$(KM_LOCAL=1 km validate --root "$D" "$D/d/nx-decision.md" "$D/d/nx-transcript.md" 2>&1)" \
  && ok "team brain: an accepted decision or transcript without review_by passes" || no "team brain: no-expiry types ($out)"
out="$(KM_LOCAL=1 km validate --root "$D" "$D/d/nx-concept.md" 2>&1)"
out_has "accepted requires 'review_by'" && ok "team brain: an accepted concept without review_by still fails" || no "team brain: concept needs review_by ($out)"
rm -f "$D"/d/nx-*.md

summary team-smoke || exit 1
