#!/usr/bin/env bash
# Smoke test for `km automerge`: a pull request is merged only when every condition holds, and each
# condition, flipped alone, blocks it with its own reason. GitHub is a stand-in gh on PATH that serves
# a fake pull request: one AI-level page added by its author Alice, who labelled it km:ready.
# Run:  bash tests/automerge_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo "  FAIL: automerge_smoke needs jq (its stand-in gh applies --jq with it)"; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# serves $FAKE: each API path as a file named after it (/ ? = & as _), the Nth read of a path from
# <file>.N where that exists; --jq applied by jq as gh does; a missing file is a 404, <file>.fail a
# server error
jqx=""; prev=""; p=""
for a in "$@"; do case "$a" in repos/*) p="$a";; esac; [ "$prev" = --jq ] && jqx="$a"; prev="$a"; done
f="$(printf '%s' "${p#repos/o/r}" | tr '/?=&' '____')"; f="${f#_}"; f="${f:-repo}"
# a write (-X METHOD) is logged to writes with its input, and fails where <file>.fail is
case " $* " in *" -X GET "*) ;; *" -X "*) m="$(sed 's/.* -X \([A-Z]*\) .*/\1/' <<<" $* ")"
  echo "$m $f $(jq -c . 2>/dev/null)" >> "$FAKE/writes"; [ -f "$FAKE/$f.fail" ] && { echo "gh: Head branch was modified (HTTP 409)" >&2; exit 1; }
  echo '{}'; exit 0;; esac
# a contents read with --jq (its metadata, not the raw text) is served from <file>__json
case "$p" in repos/o/r/contents/*) [ -n "$jqx" ] && f="${f}__json";; esac
n=$(( $(cat "$FAKE/$f.reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/$f.reads"
[ -f "$FAKE/$f.$n" ] && f="$f.$n"
[ -f "$FAKE/$f.fail" ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
[ -f "$FAKE/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$jqx" ]; then jq -r "$jqx" "$FAKE/$f"; else cat "$FAKE/$f"; fi
GH
chmod +x "$T/bin/gh"
HEAD=$(printf 'a%.0s' {1..40}); BASE=$(printf 'b%.0s' {1..40}); MB=$(printf 'd%.0s' {1..40}); BLOB=$(printf '1%.0s' {1..40})
OTHER=$(printf 'c%.0s' {1..40})
# setup: the passing case; each test then changes one file
setup(){ F="$T/f$1"; rm -rf "$F"; mkdir -p "$F"; export FAKE="$F"
  echo '{"default_branch":"main"}' > "$F/repo"
  printf '{"state":"open","merged":false,"draft":false,"user":{"login":"Alice"},"head":{"sha":"%s"},"base":{"ref":"main","sha":"%s"},"changed_files":1,"labels":[{"name":"km:ready"}],"body":"Table.\\n\\nLast reviewed: %s\\n"}\n' \
    "$HEAD" "$BASE" "$HEAD" > "$F/pulls_9"
  printf '{"object":{"sha":"%s"}}\n' "$BASE" > "$F/git_ref_heads_main"
  printf 'jobs:\n  v:\n    steps:\n      - run: km validate ${BASE:+--signoff-since "origin/$BASE"}\n' > "$F/contents_.github_workflows_ci.yml_ref_$BASE"
  echo '[{"event":"labeled"},{"event":"commented"}]' > "$F/issues_9_timeline_per_page_100"
  echo '[{"user":{"login":"Bob"},"state":"COMMENTED"}]' > "$F/pulls_9_reviews_per_page_100"
  checks "ci validate completed success" "review-request-guide guide completed skipped" "automerge act in_progress -"
  echo '{"statuses":[]}' > "$F/commits_${HEAD}_status_per_page_100"
  for c in "$BASE" "$HEAD"; do echo '{"sha":"'"$MB"'"}' > "$F/contents_.github_workflows_ci.yml_ref_${c}__json"; done
  label Alice
  printf '{"merge_base_commit":{"sha":"%s"},"files":[{"filename":"product/a.md","status":"added","sha":"%s"}]}\n' "$MB" "$BLOB" > "$F/compare_$BASE...${HEAD}_per_page_1"
  for c in "$HEAD" "$MB" "$BASE"; do echo '{"truncated":false,"tree":[]}' > "$F/git_trees_${c}_recursive_1"; done
  doc ai
}
# checks "WORKFLOW[@RUN] JOB STATUS CONCLUSION" ...: the check runs of the head, each in a run of
# .github/workflows/WORKFLOW.yml (@RUN: another run of it, its own check suite; conclusion - is none;
# WORKFLOW unlisted: a run the listing lacks), made for EVENT (default pull_request); into the files'
# .N variant with N set
checks(){ printf '%s\n' "$@" | jq -Rs '[split("\n")[] | select(. != "") | split(" ")
    | {w: .[0], name: .[1], status: .[2], conclusion: (if .[3] == "-" then null else .[3] end)}]' > "$F/rows"
  jq '{check_runs: [to_entries[] | .key as $i | .value | {id: ($i + 1), name, status, conclusion,
    check_suite: {id: (.w | explode | add)}, app: {slug: "github-actions"}}]}' \
    "$F/rows" > "$F/commits_${HEAD}_check-runs_per_page_100${N:+.$N}"
  jq --arg ev "${EVENT:-pull_request}" '{workflow_runs: ([.[] | select(.w != "unlisted") | (.w | split("@")[0]) as $n
    | {check_suite_id: (.w | explode | add), name: $n, path: ".github/workflows/\($n).yml", event: $ev,
       }] | unique)}' "$F/rows" > "$F/actions_runs_head_sha_${HEAD}_per_page_100${N:+.$N}"; }
label(){ printf '[{"event":"labeled","label":{"name":"km:ready"},"actor":{"login":"%s","type":"User"},"performed_via_github_app":null}]\n' "$1" > "$F/issues_9_events"; }
doc(){ printf -- '---\ntype: note\ntitle: "T"\nstatus: accepted\naudience: internal\napproval: %s\n---\nbody\n' "$1" > "$F/git_blobs_$BLOB"; }
run(){ out="$(cd "$T" && PATH="$T/bin:$PATH" km automerge o/r 9 --wait 0 "$@" 2>&1)"; rc=$?; }
# blocks WHAT PATTERN: exit 1, `no merge`, and exactly one reason, matching PATTERN
blocks(){ run; local n; n=$(grep -c '^- ' <<<"$out")
  if [ "$rc" = 1 ] && [ "$(head -1 <<<"$out")" = "no merge" ] && [ "$n" = 1 ] && grep -qE -- "^- $2" <<<"$out"; then ok "$1"
  else no "$1 (exit $rc: $out)"; fi; }

setup 0; run
[ "$rc" = 0 ] && [ "$out" = merge ] && ok "positive control: every condition holds, merge" || no "positive control (exit $rc: $out)"
setup 0; run --github-output "$T/out"
{ grep -qx merge=1 "$T/out" && grep -qx labelled=1 "$T/out" && grep -qx "head=$HEAD" "$T/out" && grep -qx "tip=$BASE" "$T/out" \
  && grep -qx "comment=" "$T/out"; } && ok "--github-output: merge, labelled, head, tip, no comment" || no "--github-output ($(cat "$T/out"))"

setup 1; label Maint; run; [ "$rc" = 0 ] && ok "an AI-level page merges whoever set the label (the levels path holds)" || no "ai page, maintainer's label ($out)"
setup 1; doc human; label Maint
blocks "a human-level page does not merge, even with another person's label (km ready counts that label)" \
  "the label does not count without a person: set by Maint, and product/a.md is at level human"
setup 2; doc human; blocks "a human-level page with the author's label does not merge" "the label does not count without a person: set by its author"
setup 3; jq '.files[0].filename = "CLAUDE.md"' "$F/compare_$BASE...${HEAD}_per_page_1" > "$F/x" && mv "$F/x" "$F/compare_$BASE...${HEAD}_per_page_1"
blocks "a control file does not merge" "the label does not count without a person: .*CLAUDE.md, a control file"
setup 4; sed -i.bak "s/Last reviewed: $HEAD/Last reviewed: $OTHER/" "$F/pulls_9"
blocks "a stale Last reviewed does not merge" "Last reviewed ccccccc is not the head aaaaaaa"
setup 5; sed -i.bak "s/Last reviewed: $HEAD//" "$F/pulls_9"; blocks "no Last reviewed line does not merge" "its body has no .Last reviewed:. line"
setup 6; sed -i.bak "s/Last reviewed: $HEAD/Last reviewed: ${HEAD:0:7}/" "$F/pulls_9"
blocks "a short Last reviewed sha does not merge" "the last .Last reviewed:. line of its body names no full commit sha"
setup 7; checks "ci validate completed failure"
blocks "a failing ci does not merge" "no passing ci check on the head"
setup 7b; checks "ci validate completed success" "ci other completed failure"
blocks "a failing ci check run beside a passing one does not merge" "the ci check other is fail, not pass"
setup 7c; checks "ci lint completed success"
blocks "a passing ci without its sign-off job validate does not merge" "no passing ci check on the head"
setup 7d; checks "ci validate completed success"; echo '{"statuses":[{"context":"ext","state":"failure"}]}' > "$F/commits_${HEAD}_status_per_page_100"
blocks "a failing commit status does not merge" "the check status/ext is fail"
setup 7e; checks "ci validate completed success" "unlisted job completed success"
blocks "a check run whose workflow run is not listed does not merge" "the check \(an unlisted workflow run\)/job is pending"
setup 8; checks "review-request-guide guide completed success"
blocks "no ci check (a fork's run waiting for approval) does not merge" "no passing ci check on the head \(a fork's ci run may wait"
setup 9; checks "ci validate in_progress -"
blocks "a pending ci does not merge" "ci has not finished on the head"
setup 10; checks "ci validate completed success" "other x completed failure"
blocks "another failing check does not merge" "the check other/x is fail, not pass or skipping"
setup 11; checks "ci validate completed success" "other x queued -"
blocks "another check still pending after the wait does not merge" "the check other/x is pending"
setup 11b; checks "ci validate completed failure"; mv "$F/commits_${HEAD}_check-runs_per_page_100" "$F/pr-checks-elsewhere"
checks "ci validate completed success"; cp "$F/commits_${HEAD}_check-runs_per_page_100" "$F/commits_${OTHER}_check-runs_per_page_100"
mv "$F/pr-checks-elsewhere" "$F/commits_${HEAD}_check-runs_per_page_100"
blocks "the checks of exactly the judged head count, not another commit's" "no passing ci check on the head"
setup 12; touch "$F/commits_${HEAD}_check-runs_per_page_100.fail"; blocks "unreadable checks do not merge" "its checks could not be read"
setup 13; sed -i.bak 's/"draft":false/"draft":true/' "$F/pulls_9"; blocks "a draft does not merge" "it is a draft"
setup 14; sed -i.bak 's/"ref":"main"/"ref":"feature"/' "$F/pulls_9"; blocks "a base other than main does not merge" "its base is feature, not the default branch main"
setup 15; echo '[{"event":"base_ref_changed"}]' > "$F/issues_9_timeline_per_page_100"
blocks "a pull request whose base was changed does not merge" "its base was changed after it was opened"
setup 16; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"}]' > "$F/pulls_9_reviews_per_page_100"
blocks "a review that requests changes stops it" "changes requested by Bob"
setup 17; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"},{"user":{"login":"Bob"},"state":"APPROVED"}]' > "$F/pulls_9_reviews_per_page_100"
run; [ "$rc" = 0 ] && ok "changes requested and then approved by the same reviewer: merge" || no "re-approved review ($out)"
setup 18; printf 'jobs:\n  v:\n    steps:\n      - run: km validate\n' > "$F/contents_.github_workflows_ci.yml_ref_$BASE"
blocks "a ci.yml without the sign-off check does not merge" "the default branch's ci.yml does not run the sign-off check"
setup 19; cp "$F/pulls_9" "$F/pulls_9.4"; sed -i.bak "s/\"sha\":\"$HEAD\"/\"sha\":\"$OTHER\"/" "$F/pulls_9.4"
blocks "the head moving between the first and the last read does not merge (TOCTOU)" "the head, the base, the body, the reviews or the label changed while it was read"
setup 20; printf '{"object":{"sha":"%s"}}\n' "$OTHER" > "$F/git_ref_heads_main.2"
blocks "the default branch moving while it was read does not merge" "the head, the base, the body, the reviews or the label changed while it was read"
setup 20b; cp "$F/pulls_9" "$F/pulls_9.4"; sed -i.bak "s/Last reviewed: $HEAD/Last reviewed: $OTHER/" "$F/pulls_9.4"
blocks "the body changing while it was read does not merge" "the head, the base, the body, the reviews or the label changed"
setup 20c; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"}]' > "$F/pulls_9_reviews_per_page_100.2"
blocks "a review requesting changes while it was read does not merge" "the head, the base, the body, the reviews or the label changed"
setup 20d; run --tip "$OTHER"; [ "$rc" = 1 ] && grep -q "^- the default branch moved after the workflow read its ci.yml" <<<"$out" \
  && ok "--tip other than the default branch's commit does not merge" || no "--tip ($out)"
setup 21; touch "$F/issues_9_timeline_per_page_100.fail"; blocks "an unreadable timeline does not merge" "its timeline could not be read"
# M1: beside the docs only media files; a script beside a page is for a person, though km ready counts it
twofiles(){ sed -i.bak 's/"changed_files":1/"changed_files":2/' "$F/pulls_9"
  jq --arg f "$1" '.files += [{filename: $f, status: "added", sha: "'"$OTHER"'"}]' "$F/compare_$BASE...${HEAD}_per_page_1" > "$F/x" && mv "$F/x" "$F/compare_$BASE...${HEAD}_per_page_1"; }
setup 40; twofiles product/a_media/make_figure.py
blocks "a script beside the page is not merged by the bot" "the label does not count without a person: .*product/a_media/make_figure.py, neither a doc nor a media file: a person merges"
setup 41; twofiles product/a_media/figure.PNG; run; [ "$rc" = 0 ] && ok "an image beside the page is merged" || no "image beside page ($out)"
setup 42; twofiles product/a_media/data.csv; run; [ "$rc" = 0 ] && ok "a CSV beside the page is merged" || no "csv beside page ($out)"
setup 43; twofiles Makefile; blocks "a Makefile is not merged" "the label does not count without a person: .*Makefile"
# M2: the base is judged at the default branch's tip, not at the pull request's (stale) base
setup 44; sed -i.bak "s/\"sha\":\"$BASE\"/\"sha\":\"$OTHER\"/" "$F/pulls_9"; run
[ "$rc" = 0 ] && ok "levels and schema at the base are read at the default branch's tip" || no "base at the tip ($out)"
setup 45; echo '{"sha":"'"$OTHER"'"}' > "$F/contents_.github_workflows_ci.yml_ref_${BASE}__json"
blocks "a ci.yml on the default branch other than the head's: no merge" "ci.yml on the default branch differs from the head's"
setup 46; touch "$F/contents_.github_workflows_ci.yml_ref_${HEAD}__json.fail"
blocks "the head's ci.yml unreadable: no merge" "the ci.yml of the default branch or of the head could not be read"
setup 46b; touch "$F/contents_.github_workflows_ci.yml_ref_${BASE}__json.fail"
blocks "the tip's ci.yml blob unreadable: no merge" "the ci.yml of the default branch or of the head could not be read"
# review of the delta: runs of other pull requests, dispatched runs, same-second changes, SVG, dot files
setup 81; checks "ci validate completed failure" "ci@other validate completed success"
blocks "a passing ci of another run on the same commit does not hide this one's failure" "the ci check validate is fail, not pass"
setup 82; EVENT=workflow_dispatch checks "ci validate completed success"
blocks "a dispatched ci run is not the pull request's" "a ci check on the head comes from a run that is not the pull request's"
setup 84; twofiles product/a_media/figure.svg; run; [ "$rc" = 0 ] && ok "an SVG beside the page counts as media (never rendered by CI or the bot)" || no "svg beside page ($out)"
setup 85; twofiles product/new/.gitkeep; run; [ "$rc" = 0 ] && ok "a .gitkeep beside the page is merged" || no "gitkeep ($out)"
setup 86; sed -i.bak "s/\"ref\":\"main\",\"sha\":\"$BASE\"/\"ref\":\"feature\",\"sha\":\"$OTHER\"/" "$F/pulls_9"
mv "$F/compare_$BASE...${HEAD}_per_page_1" "$F/compare_$OTHER...${HEAD}_per_page_1"; for c in "$OTHER"; do echo '{"truncated":false,"tree":[]}' > "$F/git_trees_${c}_recursive_1"; done
blocks "a pull request against another branch is judged at its own base, with that one reason" "its base is feature, not the default branch main"
setup 87; rm "$F/git_ref_heads_main"; blocks "an unreadable default branch gives one reason" "the default branch could not be read$"
# Fable's survivors: a script renamed to a media name, a head of the same sha and branch in another repository
setup 88; sed -i.bak 's/"changed_files":1/"changed_files":2/' "$F/pulls_9"
jq '.files += [{filename: "product/a_media/figure.png", previous_filename: "product/a_media/make.py", status: "renamed", sha: "'"$OTHER"'"}]' \
  "$F/compare_$BASE...${HEAD}_per_page_1" > "$F/x" && mv "$F/x" "$F/compare_$BASE...${HEAD}_per_page_1"
blocks "a script renamed to a media name is for a person (both sides of a rename)" "the label does not count without a person: .*make.py, neither a doc nor a media file"
# L1: fail closed on every read, and each re-read field
setup 47; touch "$F/pulls_9_reviews_per_page_100.fail"; blocks "unreadable reviews do not merge" "its reviews could not be read"
setup 48; rm "$F/contents_.github_workflows_ci.yml_ref_$BASE"; blocks "an unreadable ci.yml does not merge" "the default branch's ci.yml could not be read"
setup 49; touch "$F/commits_${HEAD}_status_per_page_100.fail"; blocks "unreadable statuses do not merge" "its checks could not be read"
setup 50; touch "$F/actions_runs_head_sha_${HEAD}_per_page_100.fail"; blocks "an unreadable run listing does not merge" "its checks could not be read"
setup 51; echo '{"statuses":[{"context":"ext","state":"pending"}]}' > "$F/commits_${HEAD}_status_per_page_100"
blocks "a pending commit status does not merge" "the check status/ext is pending"
setup 52; printf 'jobs:\n  v:\n    steps:\n      - run: km validate # --signoff-since x\n' > "$F/contents_.github_workflows_ci.yml_ref_$BASE"
blocks "a --signoff-since in a comment is no sign-off check" "the default branch's ci.yml does not run the sign-off check"
setup 53; printf 'jobs:\n  v:\n    steps:\n      # - run: km validate --signoff-since x\n      - run: km validate\n' > "$F/contents_.github_workflows_ci.yml_ref_$BASE"
blocks "a commented-out sign-off line is no sign-off check" "the default branch's ci.yml does not run the sign-off check"
for k in 'labels:s/"labels":\[{"name":"km:ready"}\]/"labels":[]/' 'draft:s/"draft":false/"draft":true/' 'base:s/"ref":"main"/"ref":"other"/' 'state:s/"state":"open"/"state":"closed"/'; do
  setup "54${k%%:*}"; cp "$F/pulls_9" "$F/pulls_9.4"; sed -i.bak "${k#*:}" "$F/pulls_9.4"
  blocks "the ${k%%:*} changing while it was read does not merge" "the head, the base, the body, the reviews or the label changed"
done
setup 55; checks "ci validate completed success" "ci other completed skipped"
blocks "a skipped ci check run is not a pass" "the ci check other is skipping, not pass"
setup 56; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"},{"user":{"login":"Bob"},"state":"DISMISSED"}]' > "$F/pulls_9_reviews_per_page_100"
run; [ "$rc" = 0 ] && ok "a dismissed request for changes no longer stops it" || no "dismissed review ($out)"
setup 57; sed -i.bak "s/Last reviewed: $HEAD/Last reviewed: $HEAD\\\\nLast reviewed: $OTHER/" "$F/pulls_9"
blocks "only the last Last reviewed line counts" "Last reviewed ccccccc is not the head"
setup 58; echo '[{"event":"automatic_base_change_succeeded"}]' > "$F/issues_9_timeline_per_page_100"
blocks "an automatic base change counts as a base change" "its base was changed after it was opened"
# L3a: of a check name, the newest run counts
setup 59; checks "ci validate completed failure" "ci validate completed success"; run
[ "$rc" = 0 ] && ok "a re-run's pass replaces the failure before it" || no "newest run passes ($out)"
setup 59b; checks "ci validate completed failure" "ci validate completed success"
jq '.check_runs |= reverse' "$F/commits_${HEAD}_check-runs_per_page_100" > "$F/x" && mv "$F/x" "$F/commits_${HEAD}_check-runs_per_page_100"; run
[ "$rc" = 0 ] && ok "the newest run counts by its id, not by where the listing puts it" || no "newest by id ($out)"
setup 60; checks "ci validate completed success" "ci validate completed failure"
blocks "a re-run's failure replaces the pass before it" "no passing ci check on the head"
# not labelled: nothing to do, and the workflow's act job is skipped (labelled empty)
setup 22; sed -i.bak 's/"labels":\[{"name":"km:ready"}\]/"labels":[]/' "$F/pulls_9"; run --github-output "$T/out22"
[ "$rc" = 1 ] && grep -q "^- it is not labelled km:ready" <<<"$out" && grep -qx "labelled=" "$T/out22" \
  && ok "without km:ready: no merge, labelled empty (no comment)" || no "unlabelled ($out)"
setup 23; sed -i.bak 's/"state":"open"/"state":"closed"/' "$F/pulls_9"; blocks "a closed pull request does not merge" "it is not open"
# the comment: each reason JSON-quoted in a code block, the marker first
setup 24; doc human; run --github-output "$T/out24"
body="$(sed -n 's/^comment=//p' "$T/out24" | base64 -d 2>/dev/null || sed -n 's/^comment=//p' "$T/out24" | base64 -D)"
{ head -1 <<<"$body" | grep -qx '<!-- km:automerge -->' && grep -q '^"the label does not count without a person: set by its author, and product/a.md is at level human"$' <<<"$body" \
  && grep -qx 'merge=' "$T/out24"; } && ok "the comment starts with the marker and quotes each reason" || no "comment ($body)"
# a pending check other than ci is waited for, then the merge goes ahead
setup 25; N=1 checks "ci validate completed success" "review-request-guide guide in_progress -"
out="$(cd "$T" && PATH="$T/bin:$PATH" kmpy -c 'import sys, km.automerge as a; a.EVERY = 0; sys.argv = ["km automerge", "o/r", "9", "--wait", "5"]; sys.exit(a.main())' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$F/commits_${HEAD}_check-runs_per_page_100.reads")" = 2 ] && ok "a pending check other than ci is waited for, then merged" || no "wait for a pending check (exit $rc: $out)"
# already declined (a draft): the checks are read once, not waited for
setup 25b; sed -i.bak 's/"draft":false/"draft":true/' "$F/pulls_9"; checks "ci validate completed success" "review-request-guide guide in_progress -"
out="$(cd "$T" && PATH="$T/bin:$PATH" kmpy -c 'import sys, km.automerge as a; a.EVERY = 0; sys.argv = ["km automerge", "o/r", "9", "--wait", "2"]; sys.exit(a.main())' 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$F/commits_${HEAD}_check-runs_per_page_100.reads")" = 1 ] && ok "a pull request already declined does not wait for pending checks" || no "declined, no wait (exit $rc, reads $(cat "$F/commits_${HEAD}_check-runs_per_page_100.reads"): $out)"
# --self: the workflow's own pending check is left out, another name's is not
setup 26; run --self other-name; grep -q "the check automerge/act is pending" <<<"$out" && ok "--self leaves out only the named workflow's own checks" || no "--self ($out)"
# --- the workflow's act job: its own script, against the same stand-in ---
act(){ kmpy -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["act"]["steps"][0]["run"])' \
    "$REPO/src/km/templates/team/automerge.yml" > "$T/act.sh"
  if [ -f "$F/comments.json" ]; then cp "$F/comments.json" "$F/issues_9_comments_per_page_100"
  else echo '[]' > "$F/issues_9_comments_per_page_100"; fi; rm -f "$F/writes"
  out="$(cd "$T" && PATH="$T/bin:$PATH" GITHUB_OUTPUT=/dev/null REPO=o/r PR=9 DEFAULT=main HEAD="$HEAD" TIP="$BASE" \
    MERGE="$1" COMMENT="$(printf '<!-- km:automerge -->\nwhy' | base64)" bash "$T/act.sh" 2>&1)"; rc=$?; }
writes(){ cat "$F/writes" 2>/dev/null; }
setup 30; act 1
{ [ "$rc" = 0 ] && writes | grep -q "^PUT pulls_9_merge .*\"merge_method\":\"rebase\".*\"sha\":\"$HEAD\"" \
  && writes | grep -q "^POST issues_9_comments .*Merged by the automerge workflow (rebase) at $HEAD"; } \
  && ok "act merges by rebase with the judged head sha, then says so" || no "act merges ($out; $(writes))"
setup 31; act ""; { [ "$rc" = 0 ] && ! writes | grep -q "^PUT" && writes | grep -q '^POST issues_9_comments .*why'; } \
  && ok "act on a declined verdict posts decide's comment and merges nothing" || no "act declined ($out; $(writes))"
setup 32; sed -i.bak 's/"merged":false/"merged":true/; s/"state":"open"/"state":"closed"/' "$F/pulls_9"; act 1
[ "$rc" = 0 ] && [ -z "$(writes)" ] && ok "act on a pull request another run merged writes nothing" || no "act merged already ($out; $(writes))"
setup 33; sed -i.bak "s/\"sha\":\"$HEAD\"/\"sha\":\"$OTHER\"/" "$F/pulls_9"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT" && writes | grep -q "changed after it was checked"; } \
  && ok "act does not merge when the head moved after decide" || no "act head moved ($out; $(writes))"
setup 34; printf '{"object":{"sha":"%s"}}\n' "$OTHER" > "$F/git_ref_heads_main"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge when the default branch moved after decide" || no "act tip moved ($out; $(writes))"
setup 35; sed -i.bak 's/"labels":\[{"name":"km:ready"}\]/"labels":[]/' "$F/pulls_9"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge when the label went after decide" || no "act label gone ($out; $(writes))"
setup 36; sed -i.bak 's/"draft":false/"draft":true/' "$F/pulls_9"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge a pull request turned into a draft after decide" || no "act draft ($out; $(writes))"
setup 37; touch "$F/pulls_9_merge.fail"; act 1
{ [ "$rc" = 0 ] && writes | grep -q "^PATCH\|^POST issues_9_comments .*GitHub refused the merge"; } \
  && ok "act says so when GitHub refuses the merge, and fails no check" || no "act refused ($out; $(writes))"
setup 38; sed -i.bak 's/"state":"open"/"state":"closed"/' "$F/pulls_9"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge a pull request closed after decide" || no "act closed ($out; $(writes))"
setup 39; sed -i.bak 's/"ref":"main"/"ref":"other"/' "$F/pulls_9"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge a pull request retargeted after decide" || no "act base ($out; $(writes))"
setup 61; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"}]' > "$F/pulls_9_reviews_per_page_100"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT" && writes | grep -q "the reviews"; } \
  && ok "act does not merge when a review requests changes after decide" || no "act review ($out; $(writes))"
setup 62; echo '[{"user":{"login":"Bob"},"state":"CHANGES_REQUESTED"},{"user":{"login":"Bob"},"state":"DISMISSED"}]' > "$F/pulls_9_reviews_per_page_100"; act 1
writes | grep -q "^PUT" && ok "act: a dismissed request for changes does not stop the merge" || no "act dismissed ($out; $(writes))"
setup 63; touch "$F/pulls_9_reviews_per_page_100.fail"; act 1
{ [ "$rc" = 0 ] && ! writes | grep -q "^PUT"; } && ok "act does not merge when the reviews cannot be read" || no "act reviews unread ($out; $(writes))"
setup 64; printf '[{"id":5,"user":{"login":"mallory"},"body":"<!-- km:automerge -->\\nforged"}]' > "$F/comments.json"; act ""
{ writes | grep -q "^POST issues_9_comments" && ! writes | grep -q "^PATCH"; } \
  && ok "act ignores a comment with the marker by anyone but the bot" || no "act forged marker ($(writes))"
setup 65; printf '[{"id":7,"user":{"login":"github-actions[bot]"},"body":"<!-- km:automerge -->\\nold"}]' > "$F/comments.json"; act ""
{ writes | grep -q "^PATCH issues_comments_7 .*why" && ! writes | grep -q "^POST"; } && ok "act updates its own comment in place" || no "act update ($(writes))"
setup 66; sed -i.bak 's/"merged":false/"merged":true/; s/"state":"open"/"state":"closed"/' "$F/pulls_9"; act ""
[ -z "$(writes)" ] && ok "act posts no 'not merged' on a pull request that is merged" || no "act declined but merged ($(writes))"
setup 68; touch "$F/pulls_9.fail"; act ""
writes | grep -q '^POST issues_9_comments .*why' && ok "act posts the decline even when it cannot read the pull request again" || no "act decline unread ($(writes))"
setup 67; touch "$F/pulls_9_merge.fail"; cp "$F/pulls_9" "$F/pulls_9.2"; sed -i.bak 's/"merged":false/"merged":true/' "$F/pulls_9.2"; act 1
{ writes | grep -q "^PUT" && ! writes | grep -q "comments"; } && ok "act posts nothing when another run merged it as GitHub refused this one" || no "act refused but merged ($(writes))"

# --- the resolve job's script: exactly one open km:ready pull request with this run's head ---
step(){ kmpy -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]["steps"][0]["run"])' \
  "$REPO/src/km/templates/team/automerge.yml" "$1"; }
step resolve > "$T/resolve.sh"; step decide > "$T/pin.sh"
resolve(){ rm -f "$T/gho"; out="$(cd "$T" && PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/gho" REPO=o/r EVENT="$1" NUMBER="${2:-}" \
  SHA="$HEAD" HEAD_REPO=fork/r HEAD_REF=br bash "$T/resolve.sh" 2>&1)"; rc=$?; got="$(cat "$T/gho" 2>/dev/null)"; }
pr(){ printf '{"number":%s,"head":{"sha":"%s","ref":"%s","repo":{"full_name":"fork/r"}},"labels":[%s]}' "$1" "$2" "$3" "$4"; }
L='{"name":"km:ready"}'
setup 70; echo "[$(pr 9 "$HEAD" br "$L"),$(pr 8 "$OTHER" br "$L")]" > "$F/pulls_state_open_per_page_100"; resolve workflow_run
[ "$rc" = 0 ] && [ "$got" = pr=9 ] && ok "resolve: the one open km:ready pull request with the run's head" || no "resolve one ($out; $got)"
setup 71; echo "[$(pr 9 "$HEAD" br "$L"),$(pr 8 "$HEAD" br "$L")]" > "$F/pulls_state_open_per_page_100"; resolve workflow_run
[ "$rc" = 0 ] && [ -z "$got" ] && ok "resolve: two pull requests with the head, none judged" || no "resolve two ($got)"
setup 72; echo "[$(pr 9 "$HEAD" other "$L")]" > "$F/pulls_state_open_per_page_100"; resolve workflow_run
[ "$rc" = 0 ] && [ -z "$got" ] && ok "resolve: another branch with the same commit is not this run's" || no "resolve branch ($got)"
setup 72b; echo "[$(pr 9 "$HEAD" br "$L" | sed 's|fork/r|elsewhere/r|')]" > "$F/pulls_state_open_per_page_100"; resolve workflow_run
[ "$rc" = 0 ] && [ -z "$got" ] && ok "resolve: the same commit and branch name from another repository is not this run's" || no "resolve other repo ($got)"
setup 73; echo "[$(pr 9 "$HEAD" br '')]" > "$F/pulls_state_open_per_page_100"; resolve workflow_run
[ "$rc" = 0 ] && [ -z "$got" ] && ok "resolve: an unlabelled pull request is not judged" || no "resolve unlabelled ($got)"
setup 74; touch "$F/pulls_state_open_per_page_100.fail"; resolve workflow_run
[ "$rc" = 0 ] && [ -z "$got" ] && ok "resolve: an unreadable list judges nothing and fails no check" || no "resolve unread ($got)"
setup 75; resolve pull_request_target 9; [ "$got" = pr=9 ] && ok "resolve: an event on the pull request names it" || no "resolve event ($got)"
setup 76; resolve workflow_dispatch '9;x'; [ -z "$got" ] && ok "resolve: a number that is none judges nothing" || no "resolve bad number ($got)"
# --- the pin step: exactly one km commit pinned in the default branch's ci.yml ---
K1=$(printf '1%.0s' {1..40}); K2=$(printf '2%.0s' {1..40})
pin(){ printf '%b' "$1" > "$F/contents_.github_workflows_ci.yml_ref_$BASE"; rm -f "$T/gho"
  out="$(cd "$T" && PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/gho" REPO=o/r DEFAULT=main bash "$T/pin.sh" 2>&1)"; rc=$?; got="$(cat "$T/gho" 2>/dev/null)"; }
setup 77; pin "      - uses: pasrom/km@$K1 # v1.20.0\n      - uses: pasrom/km@$K1 # v1.20.0\n"
[ "$rc" = 0 ] && [ "$got" = "$(printf 'sha=%s\ntip=%s' "$K1" "$BASE")" ] && ok "pin: one km commit (twice), with the tip it was read at" || no "pin one ($out; $got)"
setup 78; pin "      - uses: pasrom/km@$K1\n      - uses: pasrom/km@$K2\n"; [ -z "$got" ] && ok "pin: two km commits, nothing judged" || no "pin two ($got)"
setup 79; pin "      - uses: pasrom/km@v1.19.0\n"; [ -z "$got" ] && ok "pin: a tag, not a commit, nothing judged" || no "pin tag ($got)"
setup 80; rm "$F/git_ref_heads_main"; pin "      - uses: pasrom/km@$K1 # v1.20.0\n"; [ "$rc" = 0 ] && [ -z "$got" ] && ok "pin: an unreadable tip judges nothing" || no "pin no tip ($got)"
# the version gate: km 1.20.0 or later, from the pin's comment, else from src/km/__init__.py at that commit
INIT="repos_pasrom_km_contents_src_km___init__.py_ref_$K1"
gate_pin(){ local want="$1" what="$2"; pin "$3"
  if [ "$want" = run ]; then [ "$rc" = 0 ] && [ -n "$got" ] && ok "version gate: $what" || no "version gate: $what ($out; $got)"
  else [ "$rc" = 0 ] && [ -z "$got" ] && grep -q "automerge needs km 1.20.0 or later" <<<"$out" && ok "version gate: $what" || no "version gate: $what ($out; $got)"; fi; }
setup 81g; gate_pin skip "a pin commented v1.19.0 is refused" "      - uses: pasrom/km@$K1 # v1.19.0, installs km\n"
setup 82g; gate_pin run "a pin commented 1.20.0 (no v) runs" "      - uses: pasrom/km@$K1 # 1.20.0\n"
setup 83g; gate_pin run "a pin commented v1.100.0 runs (versions compared as numbers)" "      - uses: pasrom/km@$K1 # v1.100.0\n"
setup 84g; gate_pin skip "a pin commented v0.99.0 is refused" "      - uses: pasrom/km@$K1 # v0.99.0\n"
setup 85g; printf '"""km."""\n\n__version__ = "1.20.0"\n' > "$F/$INIT"; gate_pin run "a bare pin whose __init__.py says 1.20.0 runs" "      - uses: pasrom/km@$K1\n"
setup 86g; printf '__version__ = "1.19.0"\n' > "$F/$INIT"; gate_pin skip "a bare pin whose __init__.py says 1.19.0 is refused" "      - uses: pasrom/km@$K1\n"
setup 87g; gate_pin skip "a bare pin whose __init__.py cannot be read is refused" "      - uses: pasrom/km@$K1\n"
setup 88g; printf '__version__ = "1.20.0"\n' > "$F/$INIT"; gate_pin skip "the comment wins over __init__.py" "      - uses: pasrom/km@$K1 # v1.19.0\n"
# --- the jobs' if: gates, evaluated as GitHub would on these contexts ---
cat > "$T/gate.py" <<'EOF'
import json, re, sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
job, ctx = sys.argv[2], json.loads(sys.argv[3])
def get(path):
    cur = [ctx]
    for part in path.split("."):
        if part == "*":
            cur = [x for c in cur for x in (c if isinstance(c, list) else [])]
        else:
            cur = [c.get(part) if isinstance(c, dict) else None for c in cur]
    return cur if "*" in path else S(cur[0] if cur[0] is not None else "")
class S(str):   # GitHub's == compares strings case-insensitively
    def __eq__(self, o): return str(self).lower() == str(o).lower()
    def __ne__(self, o): return not self == o
    __hash__ = str.__hash__
def contains(a, b):
    return any(S(x) == b for x in a) if isinstance(a, list) else str(b).lower() in str(a).lower()
# evaluates km's own template text (its if:, rewritten into Python), never input from elsewhere
py = re.sub(r"\b(?:vars|github|needs|inputs)(?:\.(?:[\w-]+|\*))+", lambda m: f"get({m.group(0)!r})", jobs[job]["if"])
print("run" if eval(py.replace("&&", " and ").replace("||", " or "), {"get": get, "contains": contains}) else "skip")
EOF
gate(){ local want="$1" what="$2"; got="$(kmpy "$T/gate.py" "$REPO/src/km/templates/team/automerge.yml" "$3" "$4" 2>&1)"
  [ "$got" = "$want" ] && ok "if: $what" || no "if: $what (got $got)"; }
EV='"event_name":"pull_request_target","event":{"action":"labeled","label":{"name":"km:ready"},"pull_request":{"labels":[{"name":"km:ready"}]}}'
gate run "a km:ready label with KM_AUTOMERGE=1 runs resolve" resolve "{\"vars\":{\"KM_AUTOMERGE\":\"1\"},\"github\":{$EV}}"
gate skip "without KM_AUTOMERGE nothing runs" resolve "{\"vars\":{},\"github\":{$EV}}"
gate skip "KM_AUTOMERGE other than 1 runs nothing" resolve '{"vars":{"KM_AUTOMERGE":"true"},"github":{"event_name":"workflow_dispatch","event":{}}}'
gate run "a label KM:Ready runs resolve, as GitHub compares case-insensitively (km automerge then finds no km:ready)" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"pull_request_target","event":{"action":"labeled","label":{"name":"KM:Ready"},"pull_request":{"labels":[{"name":"KM:Ready"}]}}}}'
gate skip "another label runs nothing" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"pull_request_target","event":{"action":"labeled","label":{"name":"x"},"pull_request":{"labels":[{"name":"km:ready"}]}}}}'
gate skip "ready_for_review without km:ready runs nothing" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"pull_request_target","event":{"action":"ready_for_review","pull_request":{"labels":[]}}}}'
gate run "ready_for_review with km:ready runs" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"pull_request_target","event":{"action":"ready_for_review","pull_request":{"labels":[{"name":"km:ready"}]}}}}'
gate run "a successful ci run for a pull request runs" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"workflow_run","event":{"workflow_run":{"event":"pull_request","conclusion":"success"}}}}'
gate skip "a failed ci run runs nothing" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"workflow_run","event":{"workflow_run":{"event":"pull_request","conclusion":"failure"}}}}'
gate skip "a ci run on a push runs nothing" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"workflow_run","event":{"workflow_run":{"event":"push","conclusion":"success"}}}}'
gate run "a dispatch runs" resolve '{"vars":{"KM_AUTOMERGE":"1"},"github":{"event_name":"workflow_dispatch","event":{}}}'
gate skip "decide: no pull request, no run" decide '{"needs":{"resolve":{"outputs":{"pr":""}}}}'
gate run "decide: a pull request" decide '{"needs":{"resolve":{"outputs":{"pr":"9"}}}}'
gate skip "act: not labelled, no run" act '{"needs":{"decide":{"outputs":{"labelled":""}}}}'
gate run "act: labelled" act '{"needs":{"decide":{"outputs":{"labelled":"1"}}}}'
out="$(cd "$T" && PATH="$T/bin:$PATH" km automerge o/r nine 2>&1)"; rc=$?; [ "$rc" = 2 ] && ok "a NUMBER that is not one is a usage error" || no "usage error (exit $rc)"
summary automerge_smoke
