#!/usr/bin/env bash
# Smoke test for `km validate --signoff-since`: every doc a branch changes must be signed off at its
# level before the merge, a ripple edit asks for no new sign-off, and the team CI runs it on a PR.
# Run:  bash tests/signoff_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
git init -q -b main "$T"
printf 'meta: {profile: signoff}\napproval_default: ai\n' > "$T/schema.local.yaml"
# doc PATH STATUS AUDIENCE [EXTRA-FRONTMATTER] [BODY]
doc(){ mkdir -p "$(dirname "$T/$1")"; printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-01-15\nauthor: TT\nowner: TT\nstatus: %s\naudience: %s\ntags: [t]\n%b---\n%s\n' "$2" "$3" "${4:-}" "${5:-body}" > "$T/$1"; }
commit(){ git -C "$T" add -A && git -C "$T" "${G[@]}" commit -q -m "$1"; }
S(){ out="$(km validate --root "$T" --signoff-since main 2>&1)"; rc=$?; }
has_signoff(){ grep -A4 'x signoff' <<< "$out" | grep -qF "$1"; }
gate(){ printf 'meta: {profile: signoff}\napproval_default: ai\ngate: {enabled: %s}\n' "$1" > "$T/schema.local.yaml"; }
# fails_both_gates LABEL DOC NEEDLE...: S fails on DOC with each NEEDLE in its signoff finding, gate off and on
fails_both_gates(){ local g n hit; for g in false true; do
  gate $g; S; hit=0; [ "$rc" = 1 ] && has_signoff "$2" && hit=1
  for n in "${@:3}"; do has_signoff "$n" || hit=0; done
  [ "$hit" = 1 ] && ok "gate $g: $1" || no "gate $g: $1 (rc=$rc: $out)"
done; git -C "$T" checkout -q schema.local.yaml; }
# signoff_as_told DOC APPROVER [KM-APPROVE-ARGS]: as the message says, back to review, then km approve in a commit of its own
signoff_as_told(){ local o
  o="$(km demote --root "$T" "$T/$1" 2>&1)" || no "km demote $1 refused: $o"; commit "demote $1"
  o="$(km approve --root "$T" "$T/$1" --by "$2" "${@:3}" 2>&1)" || no "km approve $1 refused: $o"; commit "approve $1"; }
# kept_by_old_km DOC: record the digest of DOC's text and keep its approval, as km approve 1.12.0 and earlier did
kept_by_old_km(){ KM_ROOT="$T" kmpy -c 'import sys, km.common as c, km.edit as e
d = e.load_doc(sys.argv[1], c.ROOT / sys.argv[1]); open(d.path, "w", encoding="utf-8", newline="\n").write(c.set_digest(d.raw, d.fm, d.body) + d.body)' "$1"; }

doc old/ai-review.md review internal
doc old/human-review.md review customer
doc old/served.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n'
doc old/legacy.md accepted internal 'review_by: 2099-01-01\n'   # served before km recorded approvers
doc old/kept.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 200 240 | tr "\n" " ") approved before km recorded a digest"
doc old/signed.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 100 140 | tr "\n" " ") approved before km recorded a digest"
doc old/moved.md review internal "" "$(seq 50 90 | tr "\n" " ") moved as it is"
doc old/again.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 300 340 | tr "\n" " ") re-approved on the day of its first approval"
doc old/revert.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 500 540 | tr "\n" " ") sent back, and the send-back reverted"
doc old/swap.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 600 640 | tr "\n" " ") re-approved, then the old approval put back"
doc old/same.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 400 440 | tr "\n" " ") its approval kept for a new text"
doc old/gone.md review internal "" "$(seq 1 40 | tr "\n" " ") a body no other doc shares, so git sees no rename"
commit base
git -C "$T" switch -q -c topic

printf 'x\n' > "$T/notes.txt"; commit "no doc"
S; [ "$rc" = 0 ] && ok "a branch that changes no doc passes" || no "no doc changed (rc=$rc: $out)"

doc new/ai.md review internal; commit "ai review doc"
S; { [ "$rc" = 1 ] && has_signoff new/ai.md; } && ok "a changed doc an AI may sign off fails while in review" || no "ai level in review (rc=$rc: $out)"
doc new/ai.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-16\n'; commit "accepted by hand"
# an approval written by hand, with no approved_digest, binds nothing to the text: km approve must write it
fails_both_gates "a new doc accepted by hand, with no approved_digest, fails and names km demote and km approve" \
  new/ai.md "km demote new/ai.md" "km approve new/ai.md --by"
signoff_as_told new/ai.md ai:m2
S; { [ "$rc" = 0 ] && grep -q '^approved_by: "ai:m2"' "$T/new/ai.md" && grep -q '^approved_digest:' "$T/new/ai.md"; } \
  && ok "signed off with km demote and km approve, it passes, approved by who km approve names" || no "ai level accepted (rc=$rc: $out)"

# an approval typed into a new doc is never adopted: km approve signs off as --by, at the doc's level
doc new/typed.md accepted customer 'review_by: 2099-01-01\napproved_by: XY\napproved_at: 2026-01-16\n'; commit "approval typed by hand"
o="$(km approve --root "$T" "$T/new/typed.md" --by ai:m 2>&1)"; commit "km approve typed" >/dev/null
S; { [ "$rc" = 1 ] && has_signoff new/typed.md && grep -q "needs a human approver" <<< "$o" && ! grep -q '^approved_digest:' "$T/new/typed.md"; } \
  && ok "km approve does not bind a typed approver to the text: an AI --by on a customer doc is refused and the doc still fails" || no "typed approval adopted (rc=$rc: $o; $out)"
km approve --root "$T" "$T/new/typed.md" --by ZZ >/dev/null 2>&1; commit "approve typed"
# added served, it was never approved the way km approve does it (from review): a new doc must be
S; { [ "$rc" = 1 ] && grep -q '^approved_by: "ZZ"' "$T/new/typed.md" && has_signoff "new/typed.md - is new and accepted"; } \
  && ok "a new doc added served, then approved with --by in place, still fails" || no "typed doc approved in place (rc=$rc: $out)"
signoff_as_told new/typed.md ZZ
S; { [ "$rc" = 0 ] && grep -q '^approved_by: "ZZ"' "$T/new/typed.md"; } && ok "sent back and approved with --by, it passes under that approver" || no "typed doc approved (rc=$rc: $out)"
git -C "$T" rm -q new/typed.md; commit "drop typed"
doc new/hand.md accepted customer 'review_by: 2099-01-01\n'; commit "accepted by hand"
S; { [ "$rc" = 1 ] && has_signoff new/hand.md && has_signoff "km demote new/hand.md"; } && ok "an accepted doc nobody signed off fails, told to send it back to review" || no "hand-set accepted (rc=$rc: $out)"
git -C "$T" rm -q new/hand.md; commit "drop hand"
doc old/served.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "changed after the sign-off"; commit "edit served"
S; { [ "$rc" = 1 ] && has_signoff old/served.md; } && ok "a served doc changed since its sign-off fails, gate off too" || no "served content change (rc=$rc: $out)"
doc old/served.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-20\n' "changed after the sign-off"; commit "re-approve by hand"
fails_both_gates "its content changed and re-approved by hand, with no approved_digest, it still fails" \
  old/served.md "km approve old/served.md --by"
signoff_as_told old/served.md ai:m
S; [ "$rc" = 0 ] && ok "signed off again with km approve, it passes" || no "served re-approved (rc=$rc: $out)"
# km approve 1.12.0 and earlier, on a doc with no digest, recorded the text as it found it and kept its
# approver: after a change in this PR that approver never saw the new text
printf 'changed in this PR\n' >> "$T/old/kept.md"; commit "edit kept"
kept_by_old_km old/kept.md
commit "record kept as an older km approve did"
fails_both_gates "changed, then its old approval kept with the digest of the new text, it still fails" old/kept.md "km demote old/kept.md"
signoff_as_told old/kept.md ai:m2
S; [ "$rc" = 0 ] && ok "approved again after km demote, it passes" || no "kept re-approved (rc=$rc: $out)"
# the same approver signing off again on the day of the first approval writes the approved_by and
# approved_at the merge base has: km demote in a commit of its own shows the approval is new
printf 'changed in this PR\n' >> "$T/old/again.md"
signoff_as_told old/again.md ai:m --at 2026-01-10   # the edit goes in with the demote
mkdir -p "$T/moved"; git -C "$T" mv old/again.md moved/again.md; commit "move again"   # the send-back is found across the move
for g in false true; do gate $g; S
  { [ "$rc" = 0 ] && grep -q '^approved_at: 2026-01-10$' "$T/moved/again.md" && grep -q '^approved_digest:' "$T/moved/again.md"; } \
    && ok "gate $g: sent back, approved again by the same approver on the same day and moved, it passes" || no "gate $g: same-day re-approval (rc=$rc: $out)"
done; git -C "$T" checkout -q schema.local.yaml
# without a send-back the approval of the merge base was kept: a ripple commit in between changes nothing
printf 'changed in this PR\n' >> "$T/old/same.md"; commit "edit same"
sed -i.bak 's/^tags: \[t\]/tags: [t, u]/' "$T/old/same.md" && rm -f "$T/old/same.md.bak"; commit "ripple same"
kept_by_old_km old/same.md
commit "record same as an older km approve did"
fails_both_gates "changed, a ripple commit, then its old approval kept with the digest of the new text, it still fails" old/same.md "km demote old/same.md"
signoff_as_told old/same.md ai:m2
# a send-back reverted is none: the approval of the merge base is back, then kept for a new text
o="$(km demote --root "$T" "$T/old/revert.md" 2>&1)" || no "km demote revert refused: $o"; commit "demote revert"
git -C "$T" "${G[@]}" revert --no-edit HEAD >/dev/null
printf 'changed in this PR\n' >> "$T/old/revert.md"; commit "edit revert"
kept_by_old_km old/revert.md; commit "record revert as an older km approve did"
fails_both_gates "sent back, the send-back reverted, then its old approval kept for a new text, it still fails" old/revert.md "km demote old/revert.md"
signoff_as_told old/revert.md ai:m2
# sent back and approved, then the merge base's approval put back on a new text: the send-back approved another
signoff_as_told old/swap.md ai:m2
printf 'changed in this PR\n' >> "$T/old/swap.md"
sed -i.bak 's/^approved_by: .*/approved_by: ai:m/; s/^approved_at: .*/approved_at: 2026-01-10/' "$T/old/swap.md" && rm -f "$T/old/swap.md.bak"
kept_by_old_km old/swap.md; commit "put the old approval back on swap"
fails_both_gates "approved again, then the merge base's approval put back on a new text, it still fails" old/swap.md "km demote old/swap.md"
signoff_as_told old/swap.md ai:m2
doc old/legacy.md accepted internal 'review_by: 2099-01-01\nrelated: [old/served.md]\n'; commit "ripple legacy"
S; [ "$rc" = 0 ] && ok "a ripple edit to a served doc with no approved_by asks for nothing" || no "legacy ripple (rc=$rc: $out)"
doc old/legacy.md accepted internal 'review_by: 2099-01-01\nrelated: [old/served.md]\n' "new legacy body"; commit "edit legacy"
S; { [ "$rc" = 1 ] && has_signoff old/legacy.md; } && ok "a content change to it does" || no "legacy content change (rc=$rc: $out)"
git -C "$T" "${G[@]}" revert --no-edit HEAD >/dev/null
doc new/late.md review internal; commit "late doc"
km approve --root "$T" "$T/new/late.md" --by ai:m >/dev/null 2>&1; commit "approve late"
S; [ "$rc" = 0 ] && ok "approved with km approve in the PR, it passes" || no "km approve in the PR (rc=$rc: $out)"
printf 'edited after the approval\n' >> "$T/new/late.md"; commit "edit late"
S; { [ "$rc" = 1 ] && has_signoff new/late.md; } && ok "edited after that approval, it fails with the gate off" || no "stale approval, gate off (rc=$rc: $out)"
gate true
S; { [ "$rc" = 1 ] && grep -q "approval-stale" <<< "$out" && ! has_signoff new/late.md; } && ok "with the gate on approval-stale reports it, once" || no "stale approval, gate on (rc=$rc: $out)"
git -C "$T" checkout -q schema.local.yaml
# an approved_digest that is there but no digest km wrote (empty, a number, a boolean, null) is a
# mismatch: blanking it next to a content change passes neither check, gate on or off
for v in '""' 0 false ''; do
  sed -i.bak "s/^approved_digest:.*/approved_digest: $v/" "$T/new/late.md" && rm -f "$T/new/late.md.bak"
  git -C "$T" "${G[@]}" commit -qm "blank the digest: $v" -- new/late.md   # not the schema the last round left
  gate true; S
  { [ "$rc" = 1 ] && grep -q "approval-stale" <<< "$out"; } && ok "gate on: a content change with approved_digest: $v fails" || no "gate on, approved_digest: $v (rc=$rc: $out)"
  gate false; S
  { [ "$rc" = 1 ] && has_signoff new/late.md; } && ok "gate off: a content change with approved_digest: $v fails the sign-off" || no "gate off, approved_digest: $v (rc=$rc: $out)"
  out="$(km validate --root "$T" 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && grep -q "approval-stale" <<< "$out"; } && ok "gate off, without --signoff-since: approved_digest: $v is approval-stale, a warning" || no "plain validate, approved_digest: $v (rc=$rc: $out)"
done
git -C "$T" checkout -q schema.local.yaml
git -C "$T" rm -q new/late.md; commit "drop late"
mkdir -p "$T/moved"; git -C "$T" mv old/moved.md moved/moved.md; commit "move"
S; [ "$rc" = 0 ] && ok "a doc moved as it is asks for no sign-off" || no "moved doc (rc=$rc: $out)"
# a served doc approved before km recorded a digest, which this PR does not change in content, keeps passing
git -C "$T" mv old/signed.md moved/signed.md; commit "move signed"
S; [ "$rc" = 0 ] && ok "a served doc with no approved_digest moved as it is asks for nothing" || no "moved legacy doc (rc=$rc: $out)"
sed -i.bak 's/^tags: \[t\]/tags: [t, u]/' "$T/moved/signed.md" && rm -f "$T/moved/signed.md.bak"; commit "ripple signed"
S; [ "$rc" = 0 ] && ok "nor a ripple edit to it" || no "legacy doc ripple (rc=$rc: $out)"
km approve --root "$T" "$T/moved/signed.md" --by ai:m2 >/dev/null 2>&1; commit "approve it with a digest"
S; { [ "$rc" = 0 ] && grep -q '^approved_digest:' "$T/moved/signed.md" && grep -q '^approved_by: "ai:m2"' "$T/moved/signed.md"; } \
  && ok "nor km approve on it, which records the approval of --by and a digest" || no "legacy doc approved (rc=$rc: $out)"

doc new/human.md review customer; commit "human review doc"
S; { [ "$rc" = 1 ] && has_signoff new/human.md; } && ok "a doc a person signs off fails in review without a recorded review" || no "human level, no reviewed_by (rc=$rc: $out)"
doc new/human.md review customer 'reviewed_by: ["ai:m 2026-01-16"]\n'; commit "pre-review"
S; [ "$rc" = 0 ] && ok "with reviewed_by it may wait for the person's sign-off" || no "human level, reviewed_by (rc=$rc: $out)"

doc new/draft.md draft customer 'reviewed_by: ["ai:m 2026-01-16"]\n'; commit "draft"
S; { [ "$rc" = 1 ] && has_signoff new/draft.md && grep -q "set .status: review." <<< "$out"; } && ok "a draft fails at any level, told to go to review first" || no "draft (rc=$rc: $out)"
doc new/draft.md obsolete customer; commit "retire"
S; [ "$rc" = 0 ] && ok "a retired doc passes" || no "obsolete (rc=$rc: $out)"

doc old/ai-review.md review internal 'related: [old/human-review.md]\n'; git -C "$T" rm -q old/gone.md; commit "ripple + delete"
S; [ "$rc" = 0 ] && ok "a ripple edit (related:) and a deleted doc ask for no sign-off" || no "ripple/delete (rc=$rc: $out)"
doc old/ai-review.md review internal 'related: [old/human-review.md]\n' "new body"; commit "content"
S; { [ "$rc" = 1 ] && has_signoff old/ai-review.md; } && ok "a content change to an old review doc does" || no "content change (rc=$rc: $out)"
git -C "$T" "${G[@]}" revert --no-edit HEAD >/dev/null

doc "new/übersicht.md" review internal; commit "umlaut"
# km prints the name in the console's encoding (cp1252 on Windows): match the ASCII part
S; { [ "$rc" = 1 ] && has_signoff "new/" && has_signoff "bersicht.md"; } && ok "a non-ASCII file name is seen" || no "umlaut path (rc=$rc: $out)"
git -C "$T" rm -q "new/übersicht.md"; commit "drop umlaut"

out="$(km validate --root "$T" --signoff-since no-such-ref 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && grep -q "no merge base" <<< "$out"; } && ok "an unknown base stops with exit 2" || no "unknown base (rc=$rc: $out)"
out="$(km validate --root "$T" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "without the option a review doc is fine" || no "plain validate (rc=$rc: $out)"

# the team CI passes the option on a pull request only
step="$(kmpy -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(next(s["run"] for s in d["jobs"]["validate"]["steps"] if "km validate" in s.get("run", "")))' "$REPO/src/km/templates/team/ci.yml")"
args(){ BASE="$1" bash -c "set -- ${step#km validate }; echo \"\$*\""; }
{ [ "$(args main)" = "--signoff-since origin/main" ] && [ -z "$(args '')" ]; } && ok "ci.yml adds --signoff-since on a pull request only" || no "ci.yml step ($step)"

# Lowering the approval level from human to ai needs a person's sign-off in the branch (validate.lowered_problem).
# Each case in a repo of its own: lv_repo DEFAULT, a base doc a person signed off, then the branch.
OLD_T="$T"; trap 'rm -rf "$OLD_T" "$T"' EXIT
lv_default(){ printf 'meta: {profile: signoff}\napproval_default: %s\n' "$1" > "$T/schema.local.yaml"; }
lv_repo(){ rm -rf "$T"; T="$(mktemp -d)"; git init -q -b main "$T"; lv_default "$1"; }
lv_ed(){ sed -i.bak "$2" "$T/$1" && rm -f "$T/$1.bak"; }   # lv_ed FILE SED-EXPR: edit a file of the test repo in place
# lv_doc PATH FRONTMATTER: a doc with these fields (type, status, audience, approval ...) besides the fixed ones
lv_doc(){ mkdir -p "$(dirname "$T/$1")"; printf -- '---\n%btitle: t\ntimestamp: 2026-01-15\nauthor: TT\nowner: TT\ntags: [t]\n---\nbody\n' "$2" > "$T/$1"; }
# lv_base FRONTMATTER: d.md with it, in review, signed off by a person on main; the branch topic checked out
lv_base(){ lv_doc d.md "status: review\n$1"; km approve --root "$T" "$T/d.md" --by AB >/dev/null 2>&1 || no "base approve ($1)"
  commit base; grep -q '^approved_by: "AB"' "$T/d.md" || no "base not signed off ($1)"; git -C "$T" switch -q -c topic; }
lowered(){ has_signoff "the approval level was lowered from human to ai in this pull request"; }
# lv_case LABEL DEFAULT BASE-FRONTMATTER SED-EDIT: the edit lowers the level; it fails on both gates, an AI
# sign-off does not mend it, a person's does
lv_case(){ lv_repo "$2"; lv_base "$3"; lv_ed d.md "$4"; commit "lower"
  fails_both_gates "$1: fails without a person's sign-off" d.md "the approval level was lowered from human to ai in this pull request; a person must sign it off" "km demote d.md" "km approve d.md --by <initials>"
  signoff_as_told d.md ai:m; S; { [ "$rc" = 1 ] && lowered; } && ok "$1: an AI sign-off does not pass" || no "$1: AI sign-off (rc=$rc: $out)"
  signoff_as_told d.md AB; S; [ "$rc" = 0 ] && ok "$1: a person's sign-off in the branch passes" || no "$1: person's sign-off (rc=$rc: $out)"; }
lv_case "approval: human removed" ai 'type: note\naudience: internal\napproval: human\n' '/^approval: human/d'
lv_case "approval: human set to ai" ai 'type: note\naudience: internal\napproval: human\n' 's/^approval: human/approval: ai/'
lv_case "audience customer to internal" ai 'type: note\naudience: customer\n' 's/^audience: customer/audience: internal/'
lv_case "audience missing, set to internal" ai 'type: note\n' 's/^type: note/type: note\naudience: internal/'
lv_case "type verbatim-block to note" ai 'type: verbatim-block\nlanguage: en\naudience: internal\n' 's/^type: verbatim-block/type: note/'

# the person's approval kept from the merge base is not a sign-off in the branch, nor one typed by hand without a digest
lv_repo ai; lv_base 'type: note\naudience: internal\napproval: human\n'
lv_ed d.md '/^approval: human/d; s/^approved_by: .*/approved_by: "XY"/; /^approved_digest:/d'; commit "lower, approver typed"
S; { [ "$rc" = 1 ] && lowered; } && ok "a typed approver without a digest is no sign-off of a lowered doc" || no "typed approver (rc=$rc: $out)"
for e in 's/^approved_by: .*/approved_by: "XY"/' 's/^approved_at: .*/approved_at: 2026-02-01/'; do
  git -C "$T" checkout -q main -- d.md; lv_ed d.md "/^approval: human/d; $e"; commit "lower, approval edited ($e)"
  S; { [ "$rc" = 1 ] && lowered; } && ok "an approval edited by hand under the old digest is no sign-off ($e)" || no "edited approval $e (rc=$rc: $out)"
done

# a person's approval from before km recorded digests, a digest recorded for it in the PR, is no sign-off either
lv_repo ai; lv_doc d.md 'type: note\nstatus: accepted\naudience: internal\napproval: human\nreview_by: 2099-01-01\napproved_by: "AB"\napproved_at: 2026-01-10\n'
commit base; git -C "$T" switch -q -c topic; lv_ed d.md '/^approval: human/d'; kept_by_old_km d.md; commit "lower, digest recorded"
S; { [ "$rc" = 1 ] && lowered; } && ok "an approval without a digest at the merge base, given one in the PR, is no sign-off" || no "legacy approval (rc=$rc: $out)"
signoff_as_told d.md AB; S; [ "$rc" = 0 ] && ok "after km demote and a person's km approve, it passes" || no "legacy approval signed off (rc=$rc: $out)"

# a draft whose level the branch lowers is told to go to review first
lv_repo ai; lv_doc d.md 'type: note\nstatus: draft\naudience: internal\napproval: human\n'; commit base; git -C "$T" switch -q -c topic
lv_ed d.md '/^approval: human/d'; commit "lower"
S; { [ "$rc" = 1 ] && lowered && has_signoff 'set `status: review`, then `km approve d.md --by <initials>`'; } \
  && ok "a draft lowered fails, told to go to review and have a person approve it" || no "draft lowered (rc=$rc: $out)"

# a retired doc takes no sign-off: lowering its level, as it is retired or later, fails (else a PR that brings
# it back would start at level ai), and keeping `approval: human` passes
lv_repo ai; lv_base 'type: note\naudience: internal\napproval: human\n'
lv_ed d.md 's/^status: accepted/status: obsolete/; /^approval: human/d'; commit "retire and lower"
S; { [ "$rc" = 1 ] && lowered && has_signoff 'a retired doc takes no sign-off'; } && ok "retiring a doc and lowering its level fails" || no "retire and lower (rc=$rc: $out)"
lv_ed d.md 's/^type: note/type: note\napproval: human/'; commit "keep human"
S; [ "$rc" = 0 ] && ok "retired with approval: human kept, it passes" || no "retired, level kept (rc=$rc: $out)"
git -C "$T" switch -q main; git -C "$T" merge -q --ff-only topic; git -C "$T" switch -q -c topic2
lv_ed d.md '/^approval: human/d'; commit "lower the retired doc"
S; { [ "$rc" = 1 ] && lowered; } && ok "lowering the level of a doc already retired fails" || no "retired doc lowered (rc=$rc: $out)"

# a doc in review whose level the branch lowers: a person's km approve, no demote
lv_repo ai; lv_doc d.md 'type: note\nstatus: review\naudience: internal\napproval: human\nreviewed_by: ["ai:m 2026-01-16"]\n'; commit base; git -C "$T" switch -q -c topic
lv_ed d.md '/^approval: human/d'; commit "lower"
S; { [ "$rc" = 1 ] && lowered && has_signoff '`km approve d.md --by <initials>`' && ! has_signoff "km demote"; } \
  && ok "a review doc lowered fails, told to have a person run km approve" || no "review doc lowered (rc=$rc: $out)"
km approve --root "$T" "$T/d.md" --by AB >/dev/null 2>&1; commit approve
S; [ "$rc" = 0 ] && ok "approved by a person, it passes" || no "review doc approved by a person (rc=$rc: $out)"

# approval_default human to ai in the same PR lowers every internal doc without its own approval,
# changed by the branch or not; a customer doc and one with approval: human stay human
lv_repo human; lv_base 'type: note\naudience: internal\n'
lv_doc c.md 'type: note\nstatus: accepted\naudience: customer\n'; lv_doc h.md 'type: note\nstatus: draft\naudience: internal\napproval: human\n'
git -C "$T" switch -q main; commit "more docs"; git -C "$T" switch -q topic; git -C "$T" rebase -q main
lv_default ai; commit "default ai"
S; { [ "$rc" = 1 ] && lowered && has_signoff d.md && ! has_signoff c.md && ! has_signoff h.md; } \
  && ok "approval_default human to ai fails on an unchanged doc it lowers, and only there" || no "default lowered (rc=$rc: $out)"
signoff_as_told d.md AB
S; [ "$rc" = 0 ] && ok "signed off by a person in the branch, it passes" || no "default lowered, signed off (rc=$rc: $out)"

# the settings that decide which docs are checked and what counts as signed off are read at HEAD: a PR that
# changes one may change no doc (else it could skip a doc it lowers, or call it signed off)
lv_repo ai; lv_doc sub/d.md 'type: note\nstatus: review\naudience: internal\napproval: human\nreviewed_by: ["ai:m 2026-01-16"]\n'; commit base
git -C "$T" switch -q -c topic; printf 'gate: {served_status: published}\n' >> "$T/schema.local.yaml"; commit "served_status"
S; [ "$rc" = 0 ] && ok "a PR that changes gate.served_status and no doc passes the sign-off check" || no "served_status alone (rc=$rc: $out)"
printf '# readme\n' > "$T/README.md"; commit "readme"
S; [ "$rc" = 0 ] && ok "nor does an exempt file changed with it (README.md) count as a doc" || no "served_status + README (rc=$rc: $out)"
lv_ed sub/d.md 's/^body$/new body/'; commit "and a doc"
S; { [ "$rc" = 1 ] && has_signoff "gate.served_status changed in this pull request" && has_signoff "also changes docs: change them in a pull request of their own"; } \
  && ok "one that also changes a doc fails, told to change it on its own" || no "served_status with a doc (rc=$rc: $out)"
# the roster, and a list setting reordered or with a duplicate, change nothing the sign-off check reads
git -C "$T" reset -q --hard main; printf 'owners: [TT, ZZ]\nskip_prefixes: [brains/, x/, brains/]\n' >> "$T/schema.local.yaml"; commit "owners, base skip repeated"
git -C "$T" switch -q main; git -C "$T" merge -q --ff-only topic; git -C "$T" switch -q -c topic3
lv_default ai; printf 'owners: [ZZ, TT, AB]\nskip_prefixes: [x/]\n' >> "$T/schema.local.yaml"; lv_ed sub/d.md 's/^body$/new body/'; commit "roster grows, skip trimmed"
S; ! has_signoff "changed in this pull request" && ok "a grown roster and a trimmed, reordered skip_prefixes with a doc changed are no settings change" || no "roster/reorder (rc=$rc: $out)"

# skip_prefixes, exempt_files, reserved_no_frontmatter count per doc: one the branch changes and they now leave out fails
for k in "skip_prefixes: [sub/]" "exempt_files: [d.md]" "reserved_no_frontmatter: [d.md]"; do
  git -C "$T" reset -q --hard main; lv_default ai; echo "$k" >> "$T/schema.local.yaml"; lv_ed sub/d.md '/^approval: human/d'; commit "$k, lowered"
  S; { [ "$rc" = 1 ] && has_signoff "sub/d.md - was checked at the merge base, and this pull request's skip_prefixes" && ! has_signoff "move it back"; } \
    && ok "$k hiding a doc the branch changes fails" || no "$k (rc=$rc: $out)"
done
# a mount: skip_prefixes gains a new folder, with docs that describe it and an edited README, passes; so do
# a changed doc under a skip prefix the merge base already had and a status rule added
git -C "$T" reset -q --hard main; printf '# readme\n' > "$T/README.md"; mkdir -p "$T/brains/p"; printf 'x\n' > "$T/brains/p/a.md"; commit "readme, peer"
git -C "$T" switch -q main; git -C "$T" merge -q --ff-only topic3; git -C "$T" switch -q -c topic4
lv_default ai; printf 'skip_prefixes: [peer2/]\nstatus_rules: {review_recommends: [owner]}\n' >> "$T/schema.local.yaml"
lv_doc notes/peer2.md 'type: note\nstatus: review\naudience: internal\napproval: human\nreviewed_by: ["ai:m 2026-01-16"]\n'
printf '# readme, the peer\n' > "$T/README.md"; printf 'y\n' > "$T/brains/p/a.md"; lv_ed sub/d.md 's/^body$/body, the peer/'; commit "mount peer2, docs"
S; [ "$rc" = 0 ] && ok "a mount PR (skip_prefixes and a status rule added, docs, README and a skipped file changed) passes" || no "mount PR (rc=$rc: $out)"
# a recommends rule turned into a requires rule is stricter: it passes
lv_repo ai; printf 'status_rules: {review_recommends: [owner]}\n' >> "$T/schema.local.yaml"; lv_doc d.md 'type: note\nstatus: review\naudience: customer\nreviewed_by: ["ai:m 2026-01-16"]\n'; commit base
git -C "$T" switch -q -c topic; lv_default ai; printf 'status_rules: {review_requires: [owner]}\n' >> "$T/schema.local.yaml"; lv_ed d.md 's/^body$/new body/'; commit "recommend to require"
S; [ "$rc" = 0 ] && ok "a recommends rule made a requires rule, with a doc changed, passes" || no "recommends to requires (rc=$rc: $out)"
# a status rule that loses a requirement, with a doc changed, fails
lv_repo ai; printf 'status_rules: {review_requires: [owner, tags]}\n' >> "$T/schema.local.yaml"; lv_doc d.md 'type: note\nstatus: review\naudience: customer\nreviewed_by: ["ai:m 2026-01-16"]\n'; commit base
git -C "$T" switch -q -c topic; lv_default ai; printf 'status_rules: {review_requires: [owner]}\n' >> "$T/schema.local.yaml"; lv_ed d.md 's/^body$/new body/'; commit "requirement dropped"
S; { [ "$rc" = 1 ] && has_signoff "status_rules (a rule dropped or a field removed from one) changed"; } && ok "a status rule losing a requirement, with a doc changed, fails" || no "requires shrunk (rc=$rc: $out)"

# the merge base's overlay is a legacy schema.yaml: its approval_default counts (read as human, a ripple edit
# would look like a lowering)
lv_repo ai; mv "$T/schema.local.yaml" "$T/schema.yaml"; lv_base 'type: note\naudience: internal\n'
lv_ed d.md 's/^tags: \[t\]/tags: [t, u]/'; commit "ripple"
S; [ "$rc" = 0 ] && ok "approval_default: ai in a legacy schema.yaml at the merge base counts" || no "legacy overlay (rc=$rc: $out)"
# a merge-base overlay that does not parse is read as HEAD's (a known limit): the PR that repairs it is not flooded
lv_repo ai; lv_doc e.md 'type: note\nstatus: review\naudience: internal\nreviewed_by: ["ai:m 2026-01-16"]\n'; lv_base 'type: note\naudience: internal\napproval: human\n'
git -C "$T" switch -q main; printf 'meta: [\n' > "$T/schema.local.yaml"; git -C "$T" add -A; git -C "$T" "${G[@]}" commit -q --no-verify -m broken
git -C "$T" switch -q topic; git -C "$T" rebase -q main 2>/dev/null; lv_default ai; printf 'exempt_files: [x.md]\n' >> "$T/schema.local.yaml"; lv_ed d.md 's/^body$/new body/'; commit "repair the overlay"
S; { ! lowered && ! has_signoff "changed in this pull request"; } && ok "a broken merge-base overlay is read as HEAD's, so the repair is not flagged" || no "broken overlay (rc=$rc: $out)"

# approval_default flipped together with a setting that skips the docs it lowers: no doc changed, still fails
lv_repo human; lv_doc c.md 'type: note\nstatus: review\naudience: customer\nreviewed_by: ["ai:m 2026-01-16"]\n'; lv_base 'type: note\naudience: internal\n'
lv_default ai; echo "exempt_files: [d.md, c.md]" >> "$T/schema.local.yaml"; commit "default ai, d.md and c.md exempt"
S; { [ "$rc" = 1 ] && has_signoff "d.md - was checked at the merge base" && ! has_signoff "c.md -"; } \
  && ok "approval_default to ai with a doc made exempt fails, though no doc changed" || no "default + exempt (rc=$rc: $out)"

# a doc moved under skip_prefixes as its level drops is still checked, by the merge base's settings
lv_repo ai; printf 'skip_prefixes: [arch/]\n' >> "$T/schema.local.yaml"; lv_base 'type: note\naudience: internal\napproval: human\n'
mkdir -p "$T/arch"; git -C "$T" mv d.md arch/d.md; lv_ed arch/d.md '/^approval: human/d'; commit "move under skip, lower"
S; { [ "$rc" = 1 ] && lowered && has_signoff arch/d.md && has_signoff "move it back"; } && ok "a doc moved under skip_prefixes and lowered fails" || no "moved under skip (rc=$rc: $out)"

# an alias the schema declares for audience counts for the level
lv_repo ai; printf 'fields: {audience: {alias: aud}}\n' >> "$T/schema.local.yaml"; lv_base 'type: note\naud: customer\n'
lv_ed d.md 's/^aud: customer/aud: internal/'; commit "lower by the alias"
S; { [ "$rc" = 1 ] && lowered; } && ok "lowering through a field alias fails" || no "alias lowered (rc=$rc: $out)"
git -C "$T" reset -q --hard main; printf 'fields: {audience: {alias: aud2}}\n' >> "$T/schema.local.yaml"; lv_ed d.md 's/^body$/new body/'; commit "alias changed, and a doc"
S; { [ "$rc" = 1 ] && has_signoff "a field alias changed in this pull request"; } && ok "a changed field alias with a doc changed fails" || no "alias changed (rc=$rc: $out)"
# an alias change alone, no doc touched, that lowers docs (customer docs carry `aud: internal`) fails too
lv_repo ai; lv_doc c.md 'type: note\nstatus: review\naudience: customer\nreviewed_by: ["ai:m 2026-01-16"]\n'; lv_base 'type: note\naud: internal\n'
printf 'fields: {audience: {alias: aud}}\n' >> "$T/schema.local.yaml"; commit "alias only"
S; { [ "$rc" = 1 ] && has_signoff "a field alias changed in this pull request"; } && ok "a field alias added alone, no doc changed, fails" || no "alias only (rc=$rc: $out)"

# a new doc served with an approval it did not get in the branch (a copy) fails, at any level
COPIED="with an approval no commit of this pull request gave it"
lv_repo ai; lv_base 'type: note\naudience: internal\napproval: human\n'
sed '/^approval: human/d' "$T/d.md" > "$T/e.md"; commit "copy at level ai"
S; { [ "$rc" = 1 ] && has_signoff "e.md - is new and accepted at level ai $COPIED" && has_signoff '`km demote e.md` in a commit of its own'; } \
  && ok "a new doc copied with a person's approval and lowered to level ai fails" || no "copied approval (rc=$rc: $out)"
# sent back and approved again by the original's approver on the original's day: the same approval as d.md's
signoff_as_told e.md AB; S; { [ "$rc" = 1 ] && has_signoff "it carries exactly the approval d.md has, so it was copied"; } \
  && ok "a copy approved again with exactly the original's approval (same approver, same day) fails" || no "twin approval (rc=$rc: $out)"
signoff_as_told e.md CD; S; [ "$rc" = 0 ] && ok "approved in the branch by another person, it passes" || no "new doc approved (rc=$rc: $out)"
lv_repo ai; lv_base 'type: note\naudience: customer\n'
mkdir -p "$T/p2"; cp "$T/d.md" "$T/p2/d.md"; commit "verbatim copy at level human"
fails_both_gates "a verbatim copy of a person-approved customer doc at a new path fails" p2/d.md "p2/d.md - is new and accepted at level human $COPIED"
signoff_as_told p2/d.md CD; S; [ "$rc" = 0 ] && ok "the copy sent back and approved by a person in the branch passes" || no "copy re-approved (rc=$rc: $out)"
lv_repo ai; lv_doc d.md 'type: note\nstatus: review\naudience: internal\n'; km approve --root "$T" "$T/d.md" --by ai:m >/dev/null 2>&1
commit base; git -C "$T" switch -q -c topic; cp "$T/d.md" "$T/e.md"; commit "copy at level ai, approved by an AI"
S; { [ "$rc" = 1 ] && has_signoff "e.md - is new and accepted at level ai $COPIED"; } && ok "a copy of an AI-approved doc fails too" || no "AI copy (rc=$rc: $out)"
# the original signed off again in the branch, then copied: its sign-off is not the copy's (git log --follow
# would take the copy for the original's history)
lv_repo ai; lv_base 'type: note\naudience: customer\n'; signoff_as_told d.md AB; cp "$T/d.md" "$T/e.md"; commit "copy after re-approval"
S; { [ "$rc" = 1 ] && has_signoff "e.md - is new and accepted at level human $COPIED" && ! has_signoff "d.md -"; } \
  && ok "a copy of a doc signed off again in the branch fails, the original passes" || no "copy after re-approval (rc=$rc: $out)"
# a copy sent to review by hand with its approval kept, then served again: no new approval was written
# (an approval from outside the brain, so no doc at the merge base carries it)
lv_repo ai; lv_doc d.md 'type: note\nstatus: review\naudience: customer\n'; commit base; git -C "$T" switch -q -c topic
lv_doc e.md 'type: note\nstatus: accepted\naudience: customer\nreview_by: 2099-01-01\napproved_by: "AB"\napproved_at: 2026-01-10\n'
kept_by_old_km e.md; commit "copy from elsewhere"
lv_ed e.md 's/^status: accepted/status: review/'; commit "to review by hand"; lv_ed e.md 's/^status: review/status: accepted/'; commit "back"
fails_both_gates "a copy whose status was flipped by hand around the copied approval fails" e.md "e.md - is new and accepted at level human $COPIED"
# a doc moved from a file the merge base read no frontmatter from keeps nothing from it
lv_repo ai; seq 1 300 > "$T/d.md"; commit base; git -C "$T" switch -q -c topic
mkdir -p "$T/p2"; git -C "$T" mv d.md p2/d.md
{ printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-01-15\nauthor: TT\nowner: TT\nstatus: accepted\naudience: customer\ntags: [t]\n'
  printf 'review_by: 2099-01-01\napproved_by: "AB"\napproved_at: 2026-01-10\n---\n'; seq 1 300; } > "$T/p2/d.md"; kept_by_old_km p2/d.md; commit "frontmatter and an approval"
git -C "$T" diff -M --name-status main HEAD | grep -q "^R.*d.md.*p2/d.md" || no "the move is not paired as a rename"
fails_both_gates "a move from a file without frontmatter, served with a typed approval and digest, fails" p2/d.md "p2/d.md - was moved here from d.md"
# a copy whose text is then edited and given the digest of the new text by hand, keeping the approval
lv_repo ai; lv_base 'type: note\naudience: customer\n'; cp "$T/d.md" "$T/e.md"; commit "copy"
lv_ed e.md 's/^body$/edited body/'; kept_by_old_km e.md; commit "edit the copy, digest by hand"
fails_both_gates "a copy given the digest of an edited text by hand still fails" e.md "e.md - is new and accepted at level human $COPIED"
# a copy of one approved doc that git pairs as a rename of another, deleted one, keeps neither's approval
lv_repo ai; lv_doc c.md 'type: note\nstatus: review\naudience: customer\n'; lv_ed c.md 's/^body$/body of c/'
km approve --root "$T" "$T/c.md" --by AB >/dev/null 2>&1 || no "approve c.md"; lv_base 'type: note\naudience: customer\n'
git -C "$T" rm -q d.md; mkdir -p "$T/p2"; cp "$T/c.md" "$T/p2/d.md"; commit "replace d.md with a copy of c.md, paired as a rename"
git -C "$T" diff -M --name-status main HEAD | grep -q "^R.*d.md.*p2/d.md" || no "the copy is not paired as a rename"
fails_both_gates "a copy of another approved doc paired as a rename fails" p2/d.md "p2/d.md - was moved here from d.md with another approved_digest than it had there"
# a move keeps its approval: a pure rename, and a rename with a ripple edit; a doc added in review and approved
# in the branch passes, also after a move within the branch
lv_repo ai; lv_base 'type: note\naudience: customer\n'; mkdir -p "$T/p2"; git -C "$T" mv d.md p2/d.md; commit "move"
S; [ "$rc" = 0 ] && ok "a person-approved doc moved unchanged keeps its approval" || no "pure rename (rc=$rc: $out)"
lv_ed p2/d.md 's/^tags: \[t\]/tags: [t, u]/'; commit "ripple after the move"
S; [ "$rc" = 0 ] && ok "moved and given a ripple edit, it keeps its approval" || no "rename + ripple (rc=$rc: $out)"
# a doc git pairs with its old path only commit by commit (bookkeeping grew past half the file) keeps its approval
lv_repo ai; lv_base 'type: note\naudience: customer\n'; mkdir -p "$T/p3"; git -C "$T" mv d.md p3/d.md; commit "move"
lv_ed p3/d.md "s/^tags: \\[t\\]/tags: [$(printf "%s," $(seq 1000 1150))t]/"; commit "many tags"
git -C "$T" diff -M --name-status main HEAD | grep -q "^R" && no "the move is still paired over the range"
S; [ "$rc" = 0 ] && ok "a move git pairs only commit by commit keeps its approval" || no "unpaired move (rc=$rc: $out)"
# a copy written over an existing path: the path is not new, the approval is another doc's
lv_repo ai; lv_doc c.md 'type: note\nstatus: review\naudience: customer\n'; lv_ed c.md 's/^body$/body of c/'
km approve --root "$T" "$T/c.md" --by AB >/dev/null 2>&1 || no "approve c.md"; lv_base 'type: note\naudience: customer\n'
cp "$T/c.md" "$T/d.md"; commit "write c.md over d.md"
fails_both_gates "a copy written over an existing approved path fails" d.md "d.md - carries the approval of another doc, and is accepted at level human"
signoff_as_told d.md CD; S; [ "$rc" = 0 ] && ok "signed off in the branch, the overwritten path passes" || no "overwrite re-approved (rc=$rc: $out)"
# a doc moved over an existing path (the source deleted) is a move, not a copy
lv_repo ai; lv_doc c.md 'type: note\nstatus: review\naudience: customer\n'; lv_ed c.md 's/^body$/body of c/'
km approve --root "$T" "$T/c.md" --by AB >/dev/null 2>&1 || no "approve c.md"; lv_base 'type: note\naudience: customer\n'
cp "$T/c.md" "$T/d.md"; git -C "$T" rm -q c.md; commit "move c.md over d.md"
S; { ! grep -q "carries the approval of another doc" <<< "$out"; } && ok "a doc moved over an existing path is no copy" || no "move over a path (rc=$rc: $out)"
# a move with a stub at the old path: in one commit the doc counts as new, with the stub in a commit of its own it is a move
STUB='type: note\nstatus: superseded\naudience: internal\nsuperseded_by: p5/d.md\n'
lv_repo ai; lv_base 'type: note\naudience: customer\n'; mkdir -p "$T/p5"; git -C "$T" mv d.md p5/d.md; lv_doc d.md "$STUB"; commit "move and stub"
S; { [ "$rc" = 1 ] && has_signoff "p5/d.md - is new and accepted"; } && ok "a move and a stub in one commit count as new" || no "move + stub, one commit (rc=$rc: $out)"
lv_repo ai; lv_base 'type: note\naudience: customer\n'; mkdir -p "$T/p5"; git -C "$T" mv d.md p5/d.md; commit "move"; lv_doc d.md "$STUB"; commit "stub"
S; ! has_signoff "p5/d.md -" && ok "a move, then a stub in a commit of its own, keeps the approval" || no "move then stub (rc=$rc: $out)"
# a copy made through a rename in the branch while the original stays: a copy, not a move
lv_repo ai; lv_base 'type: note\naudience: customer\n'; mkdir -p "$T/p4"; git -C "$T" mv d.md p4/d.md; commit "move"
cp "$T/p4/d.md" "$T/d.md"; commit "the original back"
S; { [ "$rc" = 1 ] && has_signoff "p4/d.md - is new and accepted at level human $COPIED" && ! grep -q "^ *d.md - " <<< "$out"; } \
  && ok "a copy made through a rename while the original stays fails" || no "copy via rename (rc=$rc: $out)"
lv_repo ai; lv_base 'type: note\naudience: internal\n'; mkdir -p "$T/p2"
lv_doc n.md 'type: note\nstatus: review\naudience: internal\n'; commit "new in review"
km approve --root "$T" "$T/n.md" --by ai:m >/dev/null 2>&1; commit "approve n"
lv_ed n.md 's/^body$/edited body/'; km approve --root "$T" "$T/n.md" --by ai:m2 >/dev/null 2>&1; commit "edit and approve n in place"
S; [ "$rc" = 0 ] && ok "a new doc approved in the branch, edited and approved again in place, passes" || no "re-approved in place (rc=$rc: $out)"
lv_doc n.md 'type: note\nstatus: review\naudience: internal\n'; commit "new in review"
km approve --root "$T" "$T/n.md" --by ai:m >/dev/null 2>&1; commit "approve n"; git -C "$T" mv n.md p2/n.md; commit "move n"
S; [ "$rc" = 0 ] && ok "a new doc approved in the branch and moved after passes" || no "new doc moved (rc=$rc: $out)"

# raising the level, and a level that does not change, ask for nothing
lv_repo ai; lv_doc d.md 'type: note\nstatus: review\naudience: internal\napproval: ai\n'
km approve --root "$T" "$T/d.md" --by AB >/dev/null 2>&1; lv_doc e.md 'type: note\nstatus: review\naudience: internal\napproval: ai\n'
lv_doc f.md 'type: note\nstatus: review\naudience: internal\napproval: human\nreviewed_by: ["ai:m 2026-01-16"]\n'; commit base; git -C "$T" switch -q -c topic
lv_ed d.md 's/^approval: ai/approval: human/'; commit "raise"
S; [ "$rc" = 0 ] && ok "raising the level of a signed-off doc passes" || no "raised (rc=$rc: $out)"
lv_ed e.md '/^approval: ai/d'; lv_ed f.md '/^audience: internal/d'; commit "level kept"
S; [ "$rc" = 0 ] && ok "approval: ai dropped at level ai, and audience dropped at level human, ask for nothing" || no "level kept (rc=$rc: $out)"
lv_default human; git -C "$T" checkout -q main -- e.md f.md; commit "default human"
S; [ "$rc" = 0 ] && ok "approval_default ai to human raises the level and passes" || no "default raised (rc=$rc: $out)"

summary signoff_smoke
