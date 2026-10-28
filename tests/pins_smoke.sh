#!/usr/bin/env bash
# Smoke test for source pins (`sources:`, `translates:`): blob and commit pins, the stale-source
# warning, pins that survive a rewritten commit, and `km repin`.
# Run:  bash tests/pins_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
G=(-c user.name=t -c user.email=t@t)
git init -q "$T"
printf 'meta: {profile: pins}\n' > "$T/schema.local.yaml"
printf -- '---\ntype: note\ntitle: src\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\n---\nfirst\n' > "$T/src.md"
printf -- '---\ntype: note\ntitle: orig\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nlanguage: en\n---\nhello\n' > "$T/orig.md"
git -C "$T" add -A && git -C "$T" "${G[@]}" commit -qm one
C1="$(git -C "$T" rev-parse --short=7 HEAD)"
B1="$(git -C "$T" rev-parse --short=12 :src.md)"
# summary_doc FILE SOURCE [TRANSLATES]: write a summary doc with those pins, and stage it
summary_doc(){ local tr=""; [ -n "${3:-}" ] && tr="translates: $3"$'\n'
  printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nsources:\n- %s\n%s---\nbody\n' \
    "$2" "$tr" > "$T/$1"; git -C "$T" add "$1"; }
val(){ out="$(cd "$T" && km validate 2>&1)"; }

summary_doc sum.md "src.md@$C1"; val
! out_has "pin:" && ok "a commit pin to an unchanged source is clean" || no "commit pin unchanged ($out)"
summary_doc sum.md "src.md@$B1"; val
! out_has "pin:" && ok "a blob pin to an unchanged source is clean" || no "blob pin unchanged ($out)"

# the commit is rewritten (as a rebase or squash merge does): the blob pin still holds, the commit pin breaks
git -C "$T" "${G[@]}" commit -q --amend -m one-rewritten
git -C "$T" reflog expire --expire=now --all && git -C "$T" gc -q --prune=now
summary_doc sum.md "src.md@$B1"; val
! out_has "pin:" && ok "a blob pin survives a rewritten commit" || no "blob pin after rewrite ($out)"
summary_doc sum.md "src.md@$C1"; val
out_has "not in this clone's git history" && ok "a commit pin to a rewritten commit is reported" || no "commit pin after rewrite ($out)"

# the source changes: both kinds of pin are reported stale
C2="$(git -C "$T" rev-parse --short=7 HEAD)"
sed -i.bak 's/^first$/second/' "$T/src.md" && rm -f "$T/src.md.bak" && git -C "$T" add src.md
summary_doc sum.md "src.md@$B1"; val
out_has "pin:stale" && out_has "changed since the pin" && ok "a blob pin to a changed source is stale" || no "blob pin stale ($out)"
summary_doc sum.md "src.md@$C2"; val
out_has "pin:stale" && ok "a commit pin to a changed source is stale" || no "commit pin stale ($out)"
summary_doc sum.md "src.md@$B1" "orig.md@$C2"; val
{ out_has "src.md@$B1" && ! out_has "orig.md@"; } && ok "an unchanged translates source is clean" || no "translates unchanged ($out)"

# the earlier checks still hold
summary_doc sum.md "src.md"; val
out_has "not path.md@hash" && ok "a pin without a hash is reported" || no "pin without hash ($out)"
summary_doc sum.md "src.md@deadbeefdead"; val
out_has "not in this clone's git history" && ok "a hash git does not know is reported" || no "unknown hash ($out)"

# km repin: a stale pin gets the blob of the staged content, a current one is left alone
summary_doc sum.md "src.md@$B1" "orig.md@$C2"
out="$(cd "$T" && km repin sum.md 2>&1)"; rc=$?
B2="$(git -C "$T" rev-parse --short=12 :src.md)"; BO="$(git -C "$T" rev-parse --short=12 :orig.md)"
{ [ "$rc" = 0 ] && grep -q -- "- src.md@$B2" "$T/sum.md" && grep -q "translates: orig.md@$C2" "$T/sum.md"; } \
  && ok "repin re-pins the stale source and keeps the current one" || no "repin ($rc: $out; $(cat "$T/sum.md"))"
git -C "$T" add sum.md; val
! out_has "pin:" && ok "after repin the doc validates clean" || no "after repin ($out)"
out="$(cd "$T" && km repin sum.md 2>&1)"
out_has "already pins the current content" && ok "repin on current pins changes nothing" || no "repin twice ($out)"
# only the pin itself is rewritten, not a longer value that ends with the same text
summary_doc sum.md "src.md@$B1"
sed -i.bak "s|^tags: \[t\]$|&\\
note: old/src.md@$B1|" "$T/sum.md" && rm -f "$T/sum.md.bak"
out="$(cd "$T" && km repin sum.md 2>&1)"
{ grep -q "note: old/src.md@$B1" "$T/sum.md" && grep -q -- "- src.md@$B2" "$T/sum.md"; } \
  && ok "repin rewrites the pin, not a longer value ending with it" || no "repin scope ($out; $(cat "$T/sum.md"))"
# a quoted or escaped pin, an entry without a hash, and the same value in another field
printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nrelated: [src.md@%s]\nsources:\n- "\\x73rc.md@%s"\n- orig.md\n---\nbody\n' "$B1" "$B1" > "$T/q.md"
git -C "$T" add q.md; out="$(cd "$T" && km repin q.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q -- "- src.md@$B2" "$T/q.md" && grep -q -- "- orig.md@$BO" "$T/q.md" \
  && grep -q "related: \[src.md@$B1\]" "$T/q.md"; } \
  && ok "repin rewrites quoted and hashless entries, and only the pinned fields" || no "repin forms ($rc: $out; $(cat "$T/q.md"))"
summary_doc sum.md "gone.md@$B1"
out="$(cd "$T" && km repin sum.md 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "not a tracked .md file" && grep -q "gone.md@$B1" "$T/sum.md"; } \
  && ok "repin refuses an untracked source and leaves the doc" || no "repin untracked ($rc: $out)"

# a change to the source's frontmatter alone (an approval, a demotion) leaves its pins current
summary_doc sum.md "src.md@$B2"
sed -i.bak 's/^status: draft$/status: review/' "$T/src.md" && rm -f "$T/src.md.bak" && git -C "$T" add src.md; val
! out_has "pin:" && ok "a frontmatter-only change keeps the pin current" || no "frontmatter-only change ($out)"

# a signed-off doc whose pins change goes back to review without its approval
summary_doc acc.md "src.md@$B1"
sed -i.bak 's/^status: draft$/status: accepted\
owner: X\
review_by: 2099-01-01\
approved_by: "X"\
approved_at: 2026-10-09/' "$T/acc.md" && rm -f "$T/acc.md.bak" && git -C "$T" add acc.md
out="$(cd "$T" && km repin acc.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "back to review" && grep -q "^status: review" "$T/acc.md" && ! grep -q "^approved_" "$T/acc.md"; } \
  && ok "repin of a signed-off doc drops its approval" || no "repin accepted ($rc: $out; $(cat "$T/acc.md"))"

summary_doc rv.md "src.md@$B1"
sed -i.bak 's/^status: draft$/status: accepted\
owner: X\
review_by: 2099-01-01\
approved_by: "X"\
approved_at: 2026-10-09\
reviewed_by:\
- "model-x 2026-10-09 (PR #1)"/' "$T/rv.md" && rm -f "$T/rv.md.bak" && git -C "$T" add rv.md
out="$(cd "$T" && km repin rv.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q "^status: review" "$T/rv.md" && ! grep -q "reviewed_by\|model-x" "$T/rv.md"; } \
  && ok "repin of a signed-off doc drops its pre-reviews" || no "repin reviewed_by ($rc: $out; $(cat "$T/rv.md"))"

# a blank or comment line inside the list is part of it: the old entries do not stay behind
printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nsources:\n# primary\n- src.md@%s\n\n- orig.md\n\n# end\ntranslates: orig.md@%s\n---\nbody\n' "$B1" "$BO" > "$T/gap.md"
git -C "$T" add gap.md; out="$(cd "$T" && km repin gap.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ "$(grep -c '^- ' "$T/gap.md")" = 2 ] && ! grep -q "$B1" "$T/gap.md" && grep -q "^# end" "$T/gap.md" \
  && grep -q "^translates: orig.md@$BO" "$T/gap.md"; } \
  && ok "repin rewrites a list with blank and comment lines whole" || no "list with gaps ($rc: $out; $(cat "$T/gap.md"))"
# an empty list entry is skipped, as validate skips it
printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nsources:\n- src.md@%s\n-\n---\nbody\n' "$B1" > "$T/em.md"
git -C "$T" add em.md; out="$(cd "$T" && km repin em.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q -- "- src.md@" "$T/em.md" && ! grep -q "$B1" "$T/em.md"; } && ok "repin skips an empty list entry" || no "empty entry ($rc: $out; $(cat "$T/em.md"))"

# a source name YAML would misread unquoted is written quoted
printf 'x\n' > "$T/a #1.md" && git -C "$T" add "a #1.md"
summary_doc hash.md '"a #1.md"'
out="$(cd "$T" && km repin hash.md 2>&1)"; git -C "$T" add hash.md; val
{ grep -q -- '- "a #1.md@' "$T/hash.md" && ! out_has "pin:"; } && ok "repin quotes a source name YAML would misread" || no "repin quoting ($out; $(cat "$T/hash.md"))"

# a source saved with a BOM: a frontmatter-only change still leaves its pins current
printf '\xef\xbb\xbf---\ntype: note\ntitle: b\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\n---\nbom body\n' > "$T/bom.md"
git -C "$T" add bom.md; BB="$(git -C "$T" rev-parse --short=12 :bom.md)"
printf -- '---\ntype: note\ntitle: b\ntimestamp: 2026-10-09\nauthor: X\nstatus: review\ntags: [t]\n---\nbom body\n' > "$T/bom.md"
git -C "$T" add bom.md; summary_doc sum.md "bom.md@$BB"; val
! out_has "pin:" && ok "a BOM does not defeat the body-only comparison" || no "BOM source ($out)"

# a source name starting with a YAML indicator is quoted, not a crash
printf 'y\n' > "$T/[wip] a.md" && git -C "$T" add "[wip] a.md"
summary_doc wip.md '"[wip] a.md"'
out="$(cd "$T" && km repin wip.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q -- '- "\[wip\] a.md@' "$T/wip.md" && ! out_has Traceback; } \
  && ok "repin quotes a name starting with a YAML indicator" || no "indicator name ($rc: $out)"

# a field whose pins are all current keeps its lines, comment included
summary_doc keep.md "src.md@$B2" "orig.md"
sed -i.bak "s|^- src.md@$B2$|- src.md@$B2  # checked|" "$T/keep.md" && rm -f "$T/keep.md.bak" && git -C "$T" add keep.md
out="$(cd "$T" && km repin keep.md 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q -- "- src.md@$B2  # checked" "$T/keep.md" && grep -q "translates: orig.md@$BO" "$T/keep.md"; } \
  && ok "repin leaves a field with current pins untouched" || no "untouched field ($rc: $out; $(cat "$T/keep.md"))"

# a key this edit cannot find is refused, not duplicated; a doc that is not UTF-8 is refused
printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nsources: [src.md]\n"translates": src.md\n---\nbody\n' > "$T/qk.md"
git -C "$T" add qk.md; out="$(cd "$T" && km repin qk.md 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "cannot find the \`translates:\` line" && [ "$(grep -c translates "$T/qk.md")" = 1 ]; } \
  && ok "repin refuses a key line it cannot find" || no "quoted key ($rc: $out; $(cat "$T/qk.md"))"
printf '\xff\xfe---\n' > "$T/bin.md"; out="$(cd "$T" && km repin bin.md 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "not UTF-8" && ! out_has "Traceback"; } && ok "repin refuses a doc that is not UTF-8" || no "non-UTF-8 ($rc: $out)"

# a source that is superseded or obsolete is reported even though its body did not change
printf -- '---\ntype: note\ntitle: o\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\n---\nold body\n' > "$T/old.md"
git -C "$T" add old.md; summary_doc oldsum.md "old.md@$(git -C "$T" rev-parse --short=12 :old.md)"
sed -i.bak 's/^status: draft$/status: obsolete/' "$T/old.md" && rm -f "$T/old.md.bak" && git -C "$T" add old.md; val
out_has "pin:old" && out_has "the source is obsolete" && ok "a pin to an obsolete source is reported" || no "obsolete source ($out)"
printf 'replaced\n' >> "$T/old.md" && git -C "$T" add old.md; val
{ out_has "pin:old" && ! out_has "pin:stale"; } && ok "a retired source whose text changed is pin:old, not stale" || no "retired and changed ($out)"
sed -i.bak 's/^status: draft$/status: superseded/' "$T/oldsum.md" && rm -f "$T/oldsum.md.bak" && git -C "$T" add oldsum.md; val
! out_has "pin:old" && ok "a retired doc's own pins are not checked" || no "retired doc pins ($out)"
git -C "$T" rm -q --cached old.md oldsum.md && rm -f "$T/old.md" "$T/oldsum.md"

# a doc under skip_prefixes (a mounted brain) is not repinned
mkdir -p "$T/vendor" && summary_doc vendor/p.md "src.md@$B1" && cp "$T/vendor/p.md" "$T/p.bak"
printf 'skip_prefixes: [vendor/]\n' >> "$T/schema.local.yaml"
out="$(cd "$T" && km repin vendor/p.md 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "skip_prefixes" && cmp -s "$T/vendor/p.md" "$T/p.bak"; } && ok "repin refuses a doc under skip_prefixes" || no "repin skip ($rc: $out)"
printf 'meta: {profile: pins}\n' > "$T/schema.local.yaml"; git -C "$T" rm -rq --cached vendor && rm -rf "$T/vendor"

# a brain below the repository's top level: pins are relative to the brain
mkdir -p "$T/sub" && cp "$T/schema.local.yaml" "$T/src.md" "$T/sub/" && echo "only in the subfolder" >> "$T/sub/src.md"
git -C "$T" add sub
SB="$(git -C "$T" rev-parse --short=12 :sub/src.md)"
printf -- '---\ntype: summary\ntitle: s\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\nsources:\n- src.md@%s\n---\nbody\n' "$SB" > "$T/sub/s.md"
git -C "$T" add sub/s.md; out="$(km --root "$T/sub" validate 2>&1)"
! out_has "pin:" && ok "a brain in a subfolder resolves its pins" || no "subfolder brain ($out)"
git -C "$T" "${G[@]}" commit -qm sub; SC="$(git -C "$T" rev-parse --short=7 HEAD)"
sed -i.bak "s|^- src.md@.*|- sub/src.md@$SC|" "$T/sub/s.md" && rm -f "$T/sub/s.md.bak" && git -C "$T" add sub/s.md
out="$(km --root "$T/sub" validate 2>&1)"
! out_has "pin:" && ok "a pin relative to the repository's top level still resolves" || no "top-level pin ($out)"

summary pins-smoke || exit 1
