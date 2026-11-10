#!/usr/bin/env bash
# Smoke test for `km list`: rows from the frontmatter, each filter, who may sign off, from the
# brain's default, --due, --fields, --json, --all, and that it runs whatever km the brain pins.
# Run:  bash tests/list_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
git init -q "$T"
printf 'meta: {profile: list}\napproval_default: ai\n' > "$T/schema.local.yaml"
doc(){ mkdir -p "$(dirname "$T/$1")"; printf -- '---\ntype: %s\ntitle: "%s"\ntimestamp: 2026-01-15\nauthor: TT\nowner: %s\nstatus: %s\ntags: [%s]\n%b---\nbody\n' "$2" "$3" "$4" "$5" "$6" "${7:-}" > "$T/$1"; }
doc a/one.md note "One: with a colon" AA accepted "x, y" 'review_by: 2026-03-01\naudience: internal\n'
doc a/sub/two.md decision "Two" BB review y 'approval: human\naudience: customer\n'
doc b/three.md note "Three" AA draft z 'review_by: 2099-01-01\naudience: internal\n'
doc ab/four.md note "Four" CC obsolete q 'approval: human\n'
doc a/_index.md reference "A index" AA draft index
printf '# no frontmatter\n' > "$T/b/plain.md"
printf 'untracked\n' > "$T/b/new.md"
git -C "$T" add a ab b/three.md b/plain.md schema.local.yaml
L(){ out="$(cd "$T" && km list "$@" 2>/dev/null)"; }
paths(){ L "$@" --json --fields path; out="$(kmpy -c 'import json, sys; print(" ".join(r["path"] for r in json.load(sys.stdin)))' <<< "$out")"; }

L; { [ "$(sed -n 1p <<< "$out" | tr -s ' ')" = "path status signoff title" ] && grep -q "One: with a colon$" <<< "$out" \
  && [ "$(grep -c '\.md' <<< "$out")" = 4 ]; } && ok "lists tracked docs with path, status, signoff, title" || no "default listing ($out)"
paths a; [ "$out" = "a/one.md a/sub/two.md" ] && ok "a folder covers its subfolders, not indexes" || no "folder filter ($out)"
paths a/sub/; [ "$out" = "a/sub/two.md" ] && ok "a trailing slash is fine" || no "folder with slash ($out)"
paths ab; [ "$out" = "ab/four.md" ] && ok "a folder prefix is not a name prefix" || no "name prefix ($out)"
paths --status review --status draft; [ "$out" = "a/sub/two.md b/three.md" ] && ok "--status repeats as OR" || no "status ($out)"
paths --signoff ai; [ "$out" = "a/one.md b/three.md" ] && ok "--signoff uses the brain's default where a doc sets none" || no "approval default ($out)"
paths --signoff human; [ "$out" = "a/sub/two.md ab/four.md" ] && ok "--signoff human" || no "approval human ($out)"
paths --tag y --owner AA; [ "$out" = "a/one.md" ] && ok "filters combine as AND" || no "tag + owner ($out)"
paths --type decision --audience customer; [ "$out" = "a/sub/two.md" ] && ok "--type and --audience" || no "type audience ($out)"
paths --due 2026-12-31; [ "$out" = "a/one.md" ] && ok "--due: review_by on or before the date" || no "due ($out)"
paths --due today; [ "$out" = "a/one.md" ] && ok "--due today" || no "due today ($out)"
out="$(cd "$T" && km list --due 2026-13-01 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && grep -q "not a date" <<< "$out"; } && ok "a bad date is refused" || no "bad date (rc=$rc: $out)"
paths --all; [ "$out" = "a/_index.md a/one.md a/sub/two.md ab/four.md b/plain.md b/three.md" ] && ok "--all adds indexes and files without frontmatter, never untracked ones" || no "all ($out)"
L a/one.md --fields path,tags,review_by --json
kmpy -c 'import json, sys; sys.exit(json.load(sys.stdin) != [{"path": "a/one.md", "tags": ["x", "y"], "review_by": "2026-03-01"}])' <<< "$out" \
  && ok "--json keeps lists and dates as values" || no "json ($out)"
mkdir -p "$T/k"; printf -- '---\ntitle: K\nticket: {2026-11-12: x, 7: y}\n---\nbody\n' > "$T/k/keyed.md"; git -C "$T" add k
L k/keyed.md --fields ticket --json
kmpy -c 'import json, sys; sys.exit(json.load(sys.stdin) != [{"ticket": {"2026-11-12": "x", "7": "y"}}])' <<< "$out" \
  && ok "--json: a date or number read as a mapping key is listed as text" || no "date key ($out)"
git -C "$T" rm -qf k/keyed.md
L a/one.md --fields path,tags; grep -q "a/one.md  x,y$" <<< "$out" && ok "a list is joined with commas in the table" || no "table list ($out)"
printf 'repos:\n  - repo: https://github.com/pasrom/km\n    rev: %s  # frozen: v0.0.1\n    hooks:\n      - id: km-validate\n' "$(printf 'a%.0s' {1..40})" > "$T/.pre-commit-config.yaml"
out="$(cd "$T" && KM_PINNED_RUNNER=false km list b 2>&1)"
{ grep -q "b/three.md" <<< "$out" && ! grep -q "pins km" <<< "$out"; } && ok "runs this km, whatever km the brain pins" || no "pin check skipped ($out)"
doc d/cust.md note "Customer, no approval set" AA review q 'audience: customer\nreview_by: "2026-02-01"\n'
doc d/noaud.md note "No audience" AA review q 'review_by: 2026-02-01 10:00:00\n'
git -C "$T" add d
paths d --signoff human; [ "$out" = "d/cust.md d/noaud.md" ] && ok "a customer doc or one without an audience needs a person, as km approve decides" || no "approval by audience ($out)"
paths d --due 2026-02-15; [ "$out" = "d/cust.md d/noaud.md" ] && ok "--due reads a quoted date and a date with a time" || no "due forms ($out)"
out="$(cd "$T" && km list --fields , 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && grep -q "names no field" <<< "$out"; } && ok "an empty --fields is refused" || no "empty fields (rc=$rc: $out)"
out="$(cd "$T" && km list a --fields path,titel 2>&1)"; grep -q "no listed doc has titel, and the schema does not know it" <<< "$out" && ok "a field no doc has is named" || no "unknown field ($out)"
L a --fields path,approval --json; kmpy -c 'import json, sys; sys.exit([r["approval"] for r in json.load(sys.stdin)] != [None, "human"])' <<< "$out" \
  && ok "the frontmatter key approval stays its own field" || no "approval field ($out)"
out="$(cd "$T/a" && km list a/sub 2>/dev/null)"; grep -q "a/sub/two.md" <<< "$out" && ok "a path from the brain root works from a subfolder too" || no "root path from subfolder ($out)"
out="$(cd "$T" && km list nosuch 2>&1)"; rc=$?; { [ "$rc" = 2 ] && grep -q "no such file or folder" <<< "$out"; } && ok "a path that does not exist is refused" || no "missing path (rc=$rc: $out)"
mkdir -p "$T/peer" && git init -q "$T/peer"
out="$(cd "$T" && km list peer 2>&1)"; rc=$?; { [ "$rc" = 2 ] && grep -q "km list --root peer" <<< "$out"; } && ok "a mounted brain points to --root" || no "mounted brain (rc=$rc: $out)"
doc e/today.md note "Due today" AA accepted q "review_by: $(date +%Y-%m-%d)\naudience: internal\n"; git -C "$T" add e
paths e --due today; [ -z "$out" ] && ok "--due today is overdue as km demote counts it: not a doc due today" || no "due today strict ($out)"
printf -- '---\ntitle: a: b\n---\nbody\n' > "$T/e/broken.md"; git -C "$T" add e/broken.md
out="$(cd "$T" && km list e 2>&1)"; grep -q "1 doc(s) whose frontmatter does not parse, e.g. e/broken.md, left out" <<< "$out" && ok "a doc whose frontmatter does not parse is named" || no "broken frontmatter ($out)"
out="$(cd "$T/a" && km list ./sub 2>/dev/null)"; grep -q "a/sub/two.md" <<< "$out" && ok "a path is taken from the current folder" || no "relative path ($out)"
out="$(cd "$T/a" && km list . --json --fields path 2>/dev/null)"; { grep -q "a/one.md" <<< "$out" && ! grep -q "b/three.md" <<< "$out"; } && ok ". is the current folder" || no "dot ($out)"
out="$(cd "$T" && km list ../x 2>&1)"; grep -q "outside the brain" <<< "$out" && ok "a path outside the brain is refused" || no "outside ($out)"
doc c/esc.md note 'Bad\e[2Jtitle' AA draft x; git -C "$T" add c
L c; { grep -q 'Bad?\[2Jtitle' <<< "$out" && ! LC_ALL=C grep -q $'\033' <<< "$out"; } && ok "a control character in a title is not printed raw" || no "escape ($out)"
printf -- '---\n{}\n---\nbody\n' > "$T/e/empty.md"; git -C "$T" add e/empty.md
out="$(cd "$T" && km list e 2>&1)"; ! grep -q "e/empty.md" <<< "$out" && grep -q "1 doc(s) whose" <<< "$out" && ok "empty frontmatter is not called unparseable" || no "empty fm ($out)"
out="$(cd "$T" && km list --all e 2>&1)"; grep -q "listed without fields" <<< "$out" && ok "with --all an unparseable doc is listed, and said so" || no "all broken ($out)"
out="$(cd "$T" && km list a --fields path,description 2>&1)"; ! grep -q "a typo" <<< "$out" && ok "a schema field no listed doc sets is not called a typo" || no "known field ($out)"
mkdir -p "$T/peer/docs"; out="$(cd "$T" && km list peer/docs 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && grep -q "km list --root peer" <<< "$out"; } && ok "a path inside a mounted brain points to its --root" || no "inside mount (rc=$rc: $out)"
mkdir -p "$T/brains/x"; out="$(cd "$T" && km list brains/x 2>&1)"; grep -q "km list --root brains/x" <<< "$out" && ok "a mount under brains/ is named, checked out or not" || no "brains mount ($out)"
doc f/edge.md note "Edge" AA accepted q 'review_by: 2026-06-01\naudience: internal\n'; git -C "$T" add f
paths f --due 2026-06-01; [ -z "$out" ] && ok "--due DATE: a doc due on DATE itself is not yet overdue" || no "due boundary ($out)"
paths f --due 2026-06-02; [ "$out" = "f/edge.md" ] && ok "--due DATE: due the day before is" || no "due boundary +1 ($out)"
out="$(cd "$T" && km list --status nosuch >/dev/null 2>&1; echo $?)"; [ "$out" = 1 ] && ok "no match exits 1, like grep" || no "no match rc ($out)"
if [ -e "$T/F" ] || { mkdir -p "$T/f2" && [ -e "$T/F2" ]; }; then   # a case-insensitive file system
  out="$(cd "$T" && km list F 2>/dev/null)"; grep -q "f/edge.md" <<< "$out" && ok "a folder in other letter case finds git's spelling" || no "case ($out)"
fi
doc g/soft.md note "Zell­spannung" AA draft q; git -C "$T" add g
L g; grep -q "Zell­spannung" <<< "$out" && ok "a soft hyphen is kept, only control characters are replaced" || no "soft hyphen ($out)"
summary list-smoke
