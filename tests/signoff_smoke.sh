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
# signoff_as_told DOC APPROVER: as the message says, back to review, then km approve in a commit of its own
signoff_as_told(){ local o
  o="$(km demote --root "$T" "$T/$1" 2>&1)" || no "km demote $1 refused: $o"; commit "demote $1"
  o="$(km approve --root "$T" "$T/$1" --by "$2" 2>&1)" || no "km approve $1 refused: $o"; commit "approve $1"; }

doc old/ai-review.md review internal
doc old/human-review.md review customer
doc old/served.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n'
doc old/legacy.md accepted internal 'review_by: 2099-01-01\n'   # served before km recorded approvers
doc old/kept.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 200 240 | tr "\n" " ") approved before km recorded a digest"
doc old/signed.md accepted internal 'review_by: 2099-01-01\napproved_by: ai:m\napproved_at: 2026-01-10\n' "$(seq 100 140 | tr "\n" " ") approved before km recorded a digest"
doc old/moved.md review internal "" "$(seq 50 90 | tr "\n" " ") moved as it is"
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
S; { [ "$rc" = 0 ] && grep -q '^approved_by: "ZZ"' "$T/new/typed.md"; } && ok "approved with --by, it passes under that approver" || no "typed doc approved (rc=$rc: $out)"
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
KM_ROOT="$T" kmpy -c 'import sys, km.common as c, km.edit as e
d = e.load_doc(sys.argv[1], c.ROOT / sys.argv[1]); open(d.path, "w", encoding="utf-8", newline="\n").write(c.set_digest(d.raw, d.fm, d.body) + d.body)' old/kept.md
commit "record kept as an older km approve did"
fails_both_gates "changed, then its old approval kept with the digest of the new text, it still fails" old/kept.md "km demote old/kept.md"
signoff_as_told old/kept.md ai:m2
S; [ "$rc" = 0 ] && ok "approved again after km demote, it passes" || no "kept re-approved (rc=$rc: $out)"
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

summary signoff_smoke
