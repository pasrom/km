#!/usr/bin/env bash
# Smoke test for `km search`: the merged docs and the open pull requests of the brain and of every
# mounted brain are searched, and each brain gets a coverage line that says what was not searched and
# why; a gap is never "0 hits". GitHub is a stand-in gh on PATH that serves pull requests from files.
# Run:  bash tests/search_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo "  FAIL: search_smoke needs jq (its stand-in gh applies --jq with it)"; exit 1; }
printf '[user]\n\tname = t\n\temail = t@t\n[protocol "file"]\n\tallow = always\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_CONFIG_DIR="$T/ghcfg"
unset GH_TOKEN GITHUB_TOKEN
mkdir -p "$T/home" && export HOME="$T/home"

mkdir -p "$T/bin" "$T/gh"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
# serves $FAKE as the GitHub API: <owner>/<repo>/repo (the repository: fork, parent), <owner>/<repo>/pulls
# (the open pull requests, a JSON array), <owner>/<repo>/diff/<N> (a diff, for -H Accept:
# application/vnd.github.diff), <owner>/<repo>/files/<N> (the files endpoint, a JSON array); --jq is
# applied by jq, --paginate ignored. A missing file is a 404; beside it <file>.fail makes it a 502,
# .406 a 406, .429 a rate limit, .delay sleeps that many seconds first, .hang never answers. Each
# call's path goes to $FAKE/calls.
jqx=""; prev=""; diff=""; p=""
for a in "$@"; do
  case "$a" in repos/*) p="${a#repos/}";; "Accept: application/vnd.github.diff") diff=1;; esac
  [ "$prev" = --jq ] && jqx="$a"; prev="$a"
done
echo "${diff:+diff }$p" >> "$FAKE/calls"
case "$p" in
  */*/pulls\?*) f="${p%%/pulls\?*}/pulls";;
  */*/pulls/*/files\?*) n="${p%/files\?*}"; f="${p%%/pulls/*}/files/${n##*/}";;
  */*/pulls/*) f="${p%%/pulls/*}/diff/${p##*/}";;
  */*) f="$p/repo";;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1;;
esac
[ -f "$FAKE/$f.hang" ] && exec sleep 30
[ -f "$FAKE/$f.delay" ] && sleep "$(cat "$FAKE/$f.delay")"
[ -f "$FAKE/$f.fail" ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
[ -f "$FAKE/$f.406" ] && { echo "gh: Sorry, the diff exceeded the maximum number of files (HTTP 406)" >&2; exit 1; }
[ -f "$FAKE/$f.429" ] && { echo "gh: API rate limit exceeded for user ID 1. (HTTP 429)" >&2; exit 1; }
[ -f "$FAKE/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$jqx" ]; then jq -r "$jqx" "$FAKE/$f"; else cat "$FAKE/$f"; fi
GH
chmod +x "$T/bin/gh"
F="$T/gh"
H1=$(printf 'a%.0s' {1..40}); H2=$(printf 'b%.0s' {1..40}); H3=$(printf 'c%.0s' {1..40})
# pr NUMBER TITLE HEAD [BODY]: one open pull request as the list endpoint returns it
pr(){ jq -n --argjson n "$1" --arg t "$2" --arg h "$3" --arg b "${4:-}" \
  '{number: $n, title: $t, body: $b, user: {login: "alice"}, updated_at: "2026-11-20T10:00:00Z", draft: false, base: {ref: "main"}, head: {sha: $h}}'; }
pulls(){ local f="$F/$1/pulls"; mkdir -p "$F/$1/diff" "$F/$1/files"; shift; printf '%s\n' "$@" | jq -s . > "$f"; }
# repo OWNER/REPO [PARENT]: the repository as GitHub describes it, a fork of PARENT if given
repo(){ mkdir -p "$F/$1"; if [ -n "${2:-}" ]; then printf '{"fork":true,"parent":{"full_name":"%s"}}\n' "$2"; else echo '{"fork":false}'; fi > "$F/$1/repo"; }
# diff OWNER/REPO N PATH ADDED-LINE: a pull request's diff that adds one line to one doc
diff_of(){ printf 'diff --git a/%s b/%s\nindex 1..2 100644\n--- a/%s\n+++ b/%s\n@@ -1,2 +1,3 @@\n context\n+%s\n context\n' "$3" "$3" "$3" "$3" "$4" > "$F/$1/diff/$2"; }
doc(){ mkdir -p "$(dirname "$1/$2")"; printf -- '---\ntitle: T\nstatus: %s\n---\n\n%s\n' "$3" "$4" > "$1/$2"; }

# three repositories: the brain (alpha) and two brains it mounts (beta, gamma)
for r in alpha beta gamma; do git init -q "$T/$r"; done
doc "$T/alpha" notes/own.md accepted "The alpha brain notes the relay timing."
doc "$T/beta" notes/pump.md accepted "The coolant pump starts 850 ms after the contactor closes (quokkaline)."
doc "$T/gamma" docs/fan.md accepted "The fan runs at 40 percent."
for r in alpha beta gamma; do git -C "$T/$r" add -A && git -C "$T/$r" commit -q -m init; done
B="$T/alpha"
git -C "$B" submodule add -q "$T/beta" brains/beta >/dev/null 2>&1
git -C "$B" submodule add -q "$T/gamma" brains/gamma >/dev/null 2>&1
git -C "$B" config -f .gitmodules submodule.brains/beta.url https://github.com/example-org/beta-brain.git
git -C "$B" config -f .gitmodules submodule.brains/gamma.url ../gamma-brain.git     # relative to alpha's origin
git -C "$B" add -A && git -C "$B" commit -q -m mounts
git -C "$B" config submodule.recurse true          # what `brain add` sets: the brain's own search must still not enter a mount
git -C "$B" remote add origin https://github.com/example-org/alpha-brain.git
git -C "$B/brains/beta" remote set-url origin https://github.com/example-org/beta-brain.git
git -C "$B/brains/gamma" remote set-url origin https://github.com/example-org/gamma-brain.git
BETA7=$(git -C "$B/brains/beta" rev-parse --short=7 HEAD)

for r in alpha beta gamma; do repo "example-org/$r-brain"; done
pulls example-org/alpha-brain
pulls example-org/beta-brain "$(pr 41 'Pump timing update' "$H1")" "$(pr 42 'Typo fix' "$H2")"
diff_of example-org/beta-brain 41 docs/pump.md "The pump also drives the wombatrix valve."
diff_of example-org/beta-brain 42 docs/typo.md "a fixed typo"
pulls example-org/gamma-brain "$(pr 7 'Fan curve' "$H3" 'mentions the zebrafin setting')"
diff_of example-org/gamma-brain 7 docs/fan.md "The fan curve is new (gnuplotter)."
# a second file whose name git quotes in the diff header (non-ASCII)
printf 'diff --git "a/docs/l\\303\\274fter.md" "b/docs/l\\303\\274fter.md"\n--- "a/docs/l\\303\\274fter.md"\n+++ "b/docs/l\\303\\274fter.md"\n@@ -1 +1,2 @@\n+the gnuplotter fan\n' >> "$F/example-org/gamma-brain/diff/7"

S(){ rm -f "$F/calls"; out="$(cd "$B" && FAKE="$F" PATH="$T/bin:$PATH" km search "$@" 2>&1)"; rc=$?; }
CACHE="$(cd "$B" && cd "$(git rev-parse --git-common-dir)" && pwd)/km-search"
nocache(){ rm -rf "${CACHE:?}"; }
cov(){ grep -E "^$1 " <<< "$out"; }                 # a brain's coverage line

S wombatrix
{ [ "$rc" = 0 ] && grep -qx 'pr    example-org/beta-brain#41 (alice, 2026-11-20, base main, not merged) Pump timing update' <<< "$out" \
  && grep -qx '        docs/pump.md: +The pump also drives the wombatrix valve.' <<< "$out" \
  && cov brains/beta | grep -q "prs searched (2 open, 1 hit)" && grep -qx "result: 1 hit; coverage complete" <<< "$out"; } \
  && ok "a term only in a mount's open pull request is found, with repo#N and not merged" || no "PR hit ($rc: $out)"
S gnuplotter
{ [ "$rc" = 0 ] && grep -qx 'pr    example-org/gamma-brain#7 (alice, 2026-11-20, base main, not merged) Fan curve' <<< "$out" \
  && grep -qx '        docs/fan.md: +The fan curve is new (gnuplotter).' <<< "$out" \
  && grep -qx '        docs/lüfter.md: +the gnuplotter fan' <<< "$out" && ! grep -q '(title/body)' <<< "$out"; } \
  && ok "an added line in the second mount's open pull request is found, also under a file name git quotes" || no "gamma diff hit ($rc: $out)"
S zebrafin
{ [ "$rc" = 0 ] && grep -q '^pr    example-org/gamma-brain#7 (alice.*) Fan curve$' <<< "$out" && grep -qx '        (title/body)' <<< "$out"; } \
  && ok "...and one whose body matches" || no "body hit ($rc: $out)"

S QUOKKALINE
{ [ "$rc" = 0 ] && grep -qx "docs  \[beta@$BETA7\] notes/pump.md:6: The coolant pump starts 850 ms after the contactor closes (quokkaline).   (accepted)" <<< "$out" \
  && [ "$(grep -c '^docs ' <<< "$out")" = 1 ] && cov . | grep -q "docs searched (1 file, 0 hits)" \
  && cov brains/beta | grep -q "docs searched (1 file, 1 hit)"; } \
  && ok "a merged doc of a mount carries [name@sha], case-insensitively, and the brain itself never reports the mount's files" || no "mount doc ($rc: $out)"

S nothing-matches-this
{ [ "$rc" = 1 ] && cov . | grep -q "prs searched (0 open, 0 hits)" && grep -qx "result: 0 hits; coverage complete" <<< "$out"; } \
  && ok "no open pull requests is searched, not a failure; no hits exits 1" || no "0 open ($rc: $out)"

mv "$F/example-org/gamma-brain/pulls" "$F/gamma.pulls"; S wombatrix
{ [ "$rc" = 3 ] && cov brains/gamma | grep -q "prs NOT SEARCHED (gh: HTTP 404)" \
  && grep -q "coverage INCOMPLETE: brains/gamma prs" <<< "$out"; } \
  && ok "a pull request list that fails is NOT SEARCHED with gh's reason, exit 3" || no "list 404 ($rc: $out)"
mv "$F/gamma.pulls" "$F/example-org/gamma-brain/pulls"

nocache; touch "$F/example-org/beta-brain/diff/42.fail"; S wombatrix
{ [ "$rc" = 3 ] && cov brains/beta | grep -q "prs PARTIAL (1 of 2 read, 1 hit; not read: #42 diff failed (gh: HTTP 502))" \
  && grep -q '^pr    example-org/beta-brain#41' <<< "$out"; } \
  && ok "a diff that fails makes the brain's pull requests PARTIAL, naming the pull request" || no "diff 502 ($rc: $out)"
rm "$F/example-org/beta-brain/diff/42.fail"

nocache; mv "$F/example-org/beta-brain/diff/41" "$F/beta41.diff"; touch "$F/example-org/beta-brain/diff/41.406"
printf '[{"filename":"docs/pump.md","patch":"@@ -1 +1,2 @@\\n context\\n+The pump also drives the wombatrix valve."}]\n' > "$F/example-org/beta-brain/files/41"
S wombatrix
{ [ "$rc" = 0 ] && grep -q "^example-org/beta-brain/pulls/41/files?per_page=100$" "$F/calls" \
  && grep -qx '        docs/pump.md: +The pump also drives the wombatrix valve.' <<< "$out"; } \
  && ok "a diff too large (406) is read from the files endpoint" || no "406 fallback ($rc: $out)"
nocache; printf '[{"filename":"docs/pump.md","patch":"@@ -1 +1,2 @@\\n+x"},{"filename":"big.pdf","changes":3},{"filename":"empty.md","changes":0}]\n' > "$F/example-org/beta-brain/files/41"
S wombatrix; S wombatrix
{ [ "$rc" = 3 ] && cov brains/beta | grep -q "not read: #41 1 file without a patch" && grep -q "/pulls/41/files?per_page=100$" "$F/calls"; } \
  && ok "...a file without a patch there leaves it PARTIAL, also on the next run (not cached)" || no "406 no patch ($rc: $out)"
rm "$F/example-org/beta-brain/diff/41.406"; mv "$F/beta41.diff" "$F/example-org/beta-brain/diff/41"

nocache; S wombatrix --limit 1
{ [ "$rc" = 3 ] && cov brains/beta | grep -q "prs PARTIAL (1 of 2 read, 1 hit; not read: 1 over --limit)" \
  && ! grep -q "beta-brain/pulls/42" "$F/calls"; } && ok "--limit caps the diffs read per brain, the rest PARTIAL" || no "--limit ($rc: $out)"

nocache; S wombatrix; first="$(grep -c '^diff ' "$F/calls")"; S wombatrix
{ [ "$first" = 3 ] && ! grep -q '^diff ' "$F/calls" && [ "$rc" = 0 ] && grep -q '^pr    example-org/beta-brain#41' <<< "$out" \
  && ls "$CACHE" | grep -q "^example-org__beta-brain__41__${H1}__[0-9a-f]*\.diff$"; } \
  && ok "a second run with unchanged heads fetches no diff (the cache in the git dir)" || no "cache ($first; $(cat "$F/calls"); $out)"
pulls example-org/beta-brain "$(pr 41 'Pump timing update' "$H3")" "$(pr 42 'Typo fix' "$H2")"; S wombatrix
{ grep -qx 'diff example-org/beta-brain/pulls/41' "$F/calls" && [ "$(grep -c '^diff ' "$F/calls")" = 1 ]; } \
  && ok "...a new head is fetched again" || no "cache head ($(cat "$F/calls"))"

doc "$B" notes/scratch.md draft "quokkaline in an untracked file"
doc "$B" notes/old.md obsolete "relay timing, the old way"
doc "$B" notes/zz-new.md accepted "relay timing, the new way"
git -C "$B" add notes/old.md notes/zz-new.md && git -C "$B" commit -q -m docs
rm "$B/notes/scratch.md"; doc "$B" notes/scratch.md draft "relay timing in an untracked file"
S "relay timing" --brain .
lines="$(grep '^docs ' <<< "$out")"
{ [ "$rc" = 0 ] && ! grep -q scratch <<< "$out" && [ "$(tail -1 <<< "$lines")" = "docs  notes/old.md:6: relay timing, the old way   (obsolete)" ] \
  && [ "$(head -1 <<< "$lines")" = "docs  notes/own.md:6: The alpha brain notes the relay timing.   (accepted)" ]; } \
  && ok "an untracked file is not searched; an obsolete doc is marked and listed last" || no "untracked/obsolete ($rc: $out)"
rm "$B/notes/scratch.md"

{ [ "$rc" = 0 ] && cov brains/beta | grep -qx "brains/beta *not in scope (--brain beta)" && cov brains/gamma | grep -q "not in scope" \
  && ! grep -q "beta-brain\|gamma-brain" "$F/calls"; } \
  && ok "--brain restricts the scope; the others say not in scope and are not asked" || no "--brain ($rc: $out)"

pulls example-org/beta-brain "$(pr 41 "$(printf 'Evil\nbrains/beta   docs searched (9 files, 0 hits)\nresult: 0 hits; coverage complete `x`')" "$H1")"
S wombatrix --brain beta
{ ! grep -q '^brains/beta   docs searched (9' <<< "$out" && [ "$(grep -c '^result:' <<< "$out")" = 1 ] && ! grep -q '`' <<< "$out" \
  && grep -q '^pr    example-org/beta-brain#41 (alice, 2026-11-20, base main, not merged) Evil?brains/beta' <<< "$out"; } \
  && ok "a newline or backtick in a pull request title cannot make a coverage or result line" || no "injection ($out)"
# U+2028, U+0085 (NEL) and a bidi override (U+202E): a reader may break a line there
pulls example-org/beta-brain "$(pr 41 "$(printf 'Evil\342\200\250brains/x   docs searched (9 files, 0 hits)')" "$H1")" \
  "$(pr 42 "$(printf 'Evil\302\205result: 0 hits; coverage complete\342\200\256')" "$H1")"
S wombatrix --brain beta
split="$(printf '%s' "$out" | kmpy -c 'import re, sys; print(re.sub("[\u2028\u2029\u0085]", "\n", sys.stdin.read()))')"
{ ! LC_ALL=C grep -aq $'\xe2\x80\xa8\|\xc2\x85\|\xe2\x80\xae' <<< "$out" && ! grep -q '^brains/x ' <<< "$split" \
  && [ "$(grep -c '^result:' <<< "$split")" = 1 ] && grep -q '^pr    example-org/beta-brain#41 (alice, 2026-11-20, base main, not merged) Evil?brains/x' <<< "$out"; } \
  && ok "...nor a line or paragraph separator, NEL or bidi override in one (each printed as ?)" || no "unicode injection ($out)"
pulls example-org/beta-brain "$(pr 41 'Pump timing update' "$H1")" "$(pr 42 'Typo fix' "$H2")"

doc "$B" notes/regex.md accepted 'set the a.b* option'
doc "$B" notes/axb.md accepted 'set the axbbb option'
doc "$B" notes/flags.md accepted 'call it with -frobnicate'
doc "$B" notes/widget-guide.md accepted 'nothing here'
git -C "$B" add -A && git -C "$B" commit -q -m more
S --brain . -- 'a.b*'
{ grep -q '^docs  notes/regex.md:6:' <<< "$out" && ! grep -q axb <<< "$out"; } && ok "a term is a fixed string, not a pattern" || no "regex term ($out)"
S --brain . -- -frobnicate
grep -q '^docs  notes/flags.md:6: call it with -frobnicate' <<< "$out" && ok "...also one that starts with a dash" || no "dash term ($rc: $out)"
S --brain . WIDGET-guide
grep -qx 'docs  notes/widget-guide.md   (path matches)   (accepted)' <<< "$out" && ok "a file's path matches too" || no "path match ($out)"
S --brain . set --max-hits 1
{ [ "$(grep -c '^docs  notes/' <<< "$out")" = 1 ] && grep -qx 'docs  \.: 1 more files (--max-hits 1)' <<< "$out" \
  && cov . | grep -q "2 hits"; } && ok "--max-hits caps the files listed, and says how many more" || no "--max-hits ($out)"

S quokkaline --no-prs
{ [ "$rc" = 3 ] && [ ! -s "$F/calls" ] && cov brains/beta | grep -q "prs NOT SEARCHED (--no-prs)" \
  && grep -q "coverage INCOMPLETE: . prs, brains/beta prs, brains/gamma prs" <<< "$out"; } \
  && ok "--no-prs asks GitHub nothing, and coverage is incomplete (exit 3)" || no "--no-prs ($rc: $out)"

mkdir "$T/nogh"; for c in git "$(command -v "$PY")"; do ln -s "$(command -v "$c")" "$T/nogh/"; done
nocache; out="$(cd "$B" && PY="$(command -v "$PY")" PATH="$T/nogh" km search quokkaline 2>&1)"; rc=$?
{ [ "$rc" = 3 ] && [ "$(grep -c '^[.b].*prs NOT SEARCHED (.*gh not installed)' <<< "$out")" = 3 ] && grep -q '^docs  \[beta@' <<< "$out"; } \
  && ok "without gh every brain's pull requests are NOT SEARCHED (gh not installed), the docs still searched" || no "no gh ($rc: $out)"

S quokkaline --json
{ [ "$rc" = 0 ] && kmpy -c 'import json, sys
d = json.loads(sys.stdin.read())
b = {x["path"]: x for x in d["brains"]}
assert d["complete"] is True and d["terms"] == ["quokkaline"], d
assert b["brains/beta"]["docs"]["hits"][0]["cite"].startswith("[beta@"), b
assert b["brains/beta"]["prs"]["state"] == "searched" and b["brains/beta"]["repo"] == "example-org/beta-brain", b' <<< "$out"; } \
  && ok "--json is JSON with terms, brains and complete" || no "--json ($rc: $out)"

S; [ "$rc" = 2 ] && ok "no term is a usage error (exit 2)" || no "no term ($rc: $out)"
S x --brain nosuch; [ "$rc" = 2 ] && ok "an unknown --brain is a usage error" || no "unknown brain ($rc: $out)"

# --- which repository: the parent of a fork, never the fork by mistake ---
nocache; S nothing-matches-this --brain .
{ grep -qx "example-org/alpha-brain" "$F/calls" && grep -q '"example-org/alpha-brain": ""' "$CACHE/forks.json"; } && S nothing-matches-this --brain . \
  && ! grep -qx "example-org/alpha-brain" "$F/calls" && cov . | grep -q "prs searched (0 open" \
  && ok "whether origin is a fork is asked once (no fork: origin searched), then read from the cache" || no "no fork ($(cat "$F/calls"); $out)"
nocache; repo example-org/alpha-brain upstream-org/alpha-brain; pulls upstream-org/alpha-brain "$(pr 5 'Forkfound in the parent' "$H1")"
diff_of upstream-org/alpha-brain 5 docs/a.md "x"
S forkfound --brain .
{ [ "$rc" = 0 ] && grep -q '^pr    upstream-org/alpha-brain#5 (alice' <<< "$out" && ! grep -q "^example-org/alpha-brain/pulls" "$F/calls"; } \
  && ok "a fork's pull requests are read on its parent" || no "fork parent ($rc: $out)"
nocache; rm "$F/example-org/alpha-brain/repo"; S forkfound --brain .
{ [ "$rc" = 3 ] && cov . | grep -q "prs NOT SEARCHED (could not ask whether example-org/alpha-brain is a fork: gh: HTTP 404)"; } \
  && ok "...and where gh cannot say whether origin is a fork: NOT SEARCHED, not the origin's pull requests" || no "probe fails ($rc: $out)"
git -C "$B" config km.fork "false https://github.com/example-org/alpha-brain.git"; S nothing-matches-this --brain .
{ [ "$rc" = 1 ] && ! grep -qx "example-org/alpha-brain" "$F/calls"; } && ok "...km.fork saying no fork is read, no call" || no "km.fork ($rc: $out)"
git -C "$B" config --unset km.fork; git -C "$B" remote add upstream git@github.com:upstream-org/alpha-brain.git; S forkfound --brain .
{ [ "$rc" = 0 ] && ! grep -qx "example-org/alpha-brain\|upstream-org/alpha-brain" "$F/calls" && grep -q '^pr    upstream-org/alpha-brain#5' <<< "$out"; } \
  && ok "...an upstream remote is the repository, without a call" || no "upstream remote ($rc: $(cat "$F/calls"); $out)"
git -C "$B" remote remove upstream; repo example-org/alpha-brain
nocache; repo example-org/beta-brain upstream-org/beta-brain; pulls upstream-org/beta-brain "$(pr 9 'Kiwiparent' "$H2")"; diff_of upstream-org/beta-brain 9 a.md x
S kiwiparent --brain beta
{ [ "$rc" = 0 ] && grep -q '^pr    upstream-org/beta-brain#9' <<< "$out"; } && ok "...a mount whose origin is a fork: its parent" || no "mount fork ($rc: $out)"
repo example-org/beta-brain; nocache
kmpy -c 'from km.remotes import resolve_url as r
assert r("../../p/x.git", "git@github.com:o/r.git") == "git@github.com:p/x.git", r("../../p/x.git", "git@github.com:o/r.git")
assert r("../x.git", "https://github.com/o/r.git") == "https://github.com/o/x.git"
assert r("./x", "https://github.com/o/r") == "https://github.com/o/r/x"
assert r("https://h/x", "git@github.com:o/r.git") == "https://h/x"' && ok "a relative url resolves in scp form too (km doctor uses the same function)" || no "resolve_url"

# --- docs matched in Python ---
doc "$B" notes/luefter.md accepted "Der Lüfter hat die Größe 40."
git -C "$B" add -A && git -C "$B" commit -q -m luefter
hit='docs  notes/luefter.md:6: Der Lüfter hat die Größe 40.   (accepted)'
out="$(cd "$B" && LC_ALL=C km search LÜFTER --brain . --no-prs 2>&1)"; one="$out"
out="$(cd "$B" && LC_ALL=C km search GRÖSSE --brain . --no-prs 2>&1)"
grep -qx "$hit" <<< "$one" && grep -qx "$hit" <<< "$out" \
  && ok "case folding beyond ASCII (LÜFTER, GRÖSSE for Größe), also under LC_ALL=C" || no "unicode fold ($out)"
S x --brain . --no-prs; before="$(cov . | grep -o '[0-9]* files')"
rm "$B/notes/luefter.md"; S x --brain . --no-prs
[ "$(cov . | grep -o '[0-9]* files')" = "$(( ${before% files} - 1 )) files" ] && ok "a tracked file missing here is not counted" || no "missing file ($before; $out)"
git -C "$B" checkout -q notes/luefter.md

# --- what a diff changes ---
printf 'diff --git a/docs/typo.md b/docs/typo.md\n--- a/docs/typo.md\n+++ b/docs/typo.md\n@@ -1 +1,2 @@\n+++ b/kangarooz.md\ndiff --git a/old-numbat.md b/new.md\nsimilarity index 90%%\nrename from old-numbat.md\nrename to new.md\ndiff --git a/img-numbat.png b/img-numbat.png\nBinary files a/img-numbat.png and /dev/null differ\ndiff --git a/gone-numbat.md b/gone-numbat.md\ndeleted file mode 100644\n--- a/gone-numbat.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n' > "$F/example-org/beta-brain/diff/42"
nocache; S kangarooz --brain beta
{ grep -qx '        docs/typo.md: +++ b/kangarooz.md' <<< "$out" && ! grep -q 'kangarooz.md (path)' <<< "$out"; } \
  && ok "a +++ line inside a hunk is an added line, not a file header" || no "in-hunk header ($out)"
S numbat --brain beta
{ grep -qx '        old-numbat.md (path)' <<< "$out" && grep -qx '        img-numbat.png (path)' <<< "$out" && grep -qx '        gone-numbat.md (path)' <<< "$out"; } \
  && ok "a renamed, binary or removed file matches by its path" || no "paths ($out)"
diff_of example-org/beta-brain 42 docs/typo.md "a fixed typo"

# --- time budget, rate limits, the file list cap, the cache ---
nocache; touch "$F/example-org/beta-brain/diff/41.hang"; start=$SECONDS
out="$(cd "$B" && KM_SEARCH_BUDGET=2 FAKE="$F" PATH="$T/bin:$PATH" km search wombatrix --brain beta 2>&1)"; rc=$?
{ [ "$rc" = 3 ] && [ $((SECONDS - start)) -lt 10 ] && cov brains/beta | grep -q "not read: #41 timed out"; } \
  && ok "the pull request part keeps to its time budget; a diff not read in it is 'timed out'" || no "budget ($rc, $((SECONDS - start)) s: $out)"
rm "$F/example-org/beta-brain/diff/41.hang"
list=(); for i in $(seq 1 12); do h=$(printf '%040d' "$i"); list+=("$(pr "$i" "P$i" "$h")"); diff_of example-org/alpha-brain "$i" a.md x; echo 1 > "$F/example-org/alpha-brain/diff/$i.delay"; done
pulls example-org/alpha-brain "${list[@]}"; rm "$F/example-org/alpha-brain/diff/1.delay"; touch "$F/example-org/alpha-brain/diff/1.429"
nocache; S nothing-matches-this --brain .
{ [ "$rc" = 3 ] && cov . | grep -q "not read: #1 diff failed (gh: HTTP 429 (gh: API rate limit exceeded" && cov . | grep -q "not read after gh: HTTP 429" \
  && [ "$(grep -c '^diff example-org/alpha-brain' "$F/calls")" -lt 12 ]; } \
  && ok "after HTTP 429 the rest of that repository is not asked, and named unread with gh's message" || no "429 ($rc: $(grep -c '^diff' "$F/calls"); $out)"
pulls example-org/alpha-brain
nocache; touch "$F/example-org/beta-brain/diff/41.406"; jq -n '[range(3000) | {filename: "f\(.).md", patch: "@@ -1 +1 @@\n+x", changes: 1}]' > "$F/example-org/beta-brain/files/41"
S wombatrix --brain beta
{ [ "$rc" = 3 ] && cov brains/beta | grep -q "not read: #41 file list capped at 3000"; } && ok "a pull request with 3000 files (GitHub's cap) is PARTIAL" || no "files cap ($rc: $out)"
rm "$F/example-org/beta-brain/diff/41.406"
nocache; S wombatrix --brain beta; f41="$(ls "$CACHE" | grep '__41__')"; touch -t 202001010000 "${CACHE:?}/.tmp-old"
pulls example-org/beta-brain "$(pr 41 'Pump timing update' "$H1" | jq '.base.ref = "release"')"; S wombatrix --brain beta
{ grep -qx 'diff example-org/beta-brain/pulls/41' "$F/calls" && ! ls "$CACHE" | grep -q '__42__' && ! ls "$CACHE" | grep -qx "$f41" && [ ! -e "$CACHE/.tmp-old" ]; } \
  && ok "a new base is fetched again; diffs of closed pull requests and stale temporary files are removed" || no "cache base/prune ($(cat "$F/calls"); $(ls -a "$CACHE"))"
pulls example-org/beta-brain "$(pr 41 'Pump timing update' "$H1")" "$(pr 42 'Typo fix' "$H2")"
S wombatrix --brain beta; f41="$(ls "$CACHE" | grep '__41__')"; rm "${CACHE:?}/${f41:?}"; mkdir "$CACHE/$f41"; S wombatrix --brain beta
{ [ "$rc" = 0 ] && grep -qx 'diff example-org/beta-brain/pulls/41' "$F/calls"; } && ok "an unreadable cache file is fetched again" || no "cache OSError ($rc: $out)"
rmdir "${CACHE:?}/${f41:?}"

S docs/ --brain beta --max-hits 1
{ [ "$(grep -c '^pr    example-org/beta-brain#' <<< "$out")" = 1 ] && grep -qx 'pr    example-org/beta-brain: 1 more pull requests (--max-hits 1)' <<< "$out"; } \
  && S docs/ --brain beta --max-hits 1 --json && kmpy -c 'import json, sys
p = json.loads(sys.stdin.read())["brains"][1]["prs"]; assert len(p["hits"]) == 1 and p["more"] == 1, p' <<< "$out" \
  && ok "--max-hits caps the pull requests listed too, in text and JSON" || no "pr max-hits ($out)"
S "$(printf 'a\nb')"; [ "$rc" = 2 ] && ok "a term with a line break is a usage error" || no "newline term ($rc)"
out="$(cd "$B" && KM_ROOT="$B" kmpy -c 'import sys, km.search as s
s.search_docs = lambda *a: 1 / 0
sys.argv = ["km search", "x", "--no-prs"]; sys.exit(s.main())' 2>&1)"; rc=$?
{ [ "$rc" = 3 ] && grep -qx "result: coverage INCOMPLETE (internal error: ZeroDivisionError)" <<< "$out"; } \
  && ok "an internal error is coverage INCOMPLETE, exit 3, never a clean 0 or 1" || no "internal error ($rc: $out)"

# a third mount, not on GitHub; then gamma not checked out, then left out
git init -q "$T/delta" && doc "$T/delta" a.md accepted x && git -C "$T/delta" add -A && git -C "$T/delta" commit -q -m init
git -C "$B" submodule add -q "$T/delta" brains/delta >/dev/null 2>&1
git -C "$B" config -f .gitmodules submodule.brains/delta.url https://git.example.net/x/delta.git
git -C "$B" add -A && git -C "$B" commit -q -m delta
git -C "$B/brains/delta" remote set-url origin https://git.example.net/x/delta.git
S quokkaline
{ [ "$rc" = 3 ] && cov brains/delta | grep -q "prs NOT SEARCHED (not on github.com: https://git.example.net/x/delta.git)"; } \
  && ok "a mount not on github.com: its pull requests NOT SEARCHED" || no "non-github ($rc: $out)"

git -C "$B" submodule deinit -q -f brains/gamma; S zebrafin --brain gamma
{ [ "$rc" = 3 ] && cov brains/gamma | grep -q "docs NOT SEARCHED (not checked out; run km sync) *prs searched (1 open, 1 hit)" \
  && grep -q '^pr    example-org/gamma-brain#7' <<< "$out" && grep -q "coverage INCOMPLETE: brains/gamma docs$" <<< "$out"; } \
  && ok "a mount not checked out: docs NOT SEARCHED, its pull requests still searched (relative .gitmodules url)" || no "not checked out ($rc: $out)"
git -C "$B" config submodule.brains/gamma.update none; S zebrafin --brain gamma
{ [ "$rc" = 3 ] && cov brains/gamma | grep -q "docs NOT SEARCHED (left out here: update = none)"; } \
  && ok "a mount left out here (update = none): docs NOT SEARCHED with that reason" || no "left out ($rc: $out)"
git -C "$B" config --unset submodule.brains/gamma.update
repo example-org/alpha-brain upstream-org/alpha-brain; repo upstream-org/gamma-brain; pulls upstream-org/gamma-brain "$(pr 3 'Zebrafin upstream' "$H3")"; diff_of upstream-org/gamma-brain 3 a.md x
nocache; S zebrafin --brain gamma
grep -q '^pr    upstream-org/gamma-brain#3' <<< "$out" && ok "...its relative url resolves against the brain's parent when the brain is a fork" || no "relative on fork ($out)"
repo example-org/alpha-brain

# entries that are no mount: a path leaving brains/, a gitlink whose name could pass for a coverage line;
# and a mount under a sub-folder whose last part is also beta
BETA=$(git -C "$T/beta" rev-parse HEAD)
git -C "$B" config -f .gitmodules submodule.out.path brains/../../outside
git -C "$B" config -f .gitmodules submodule.out.url https://github.com/example-org/out.git
git -C "$B" config -f .gitmodules submodule.ghost.path brains/ghost        # a plain name, but no gitlink in HEAD
EVIL="brains/evil  docs searched (9 files, 0 hits)"
git -C "$B" config -f .gitmodules submodule.evil.path "$EVIL"
git -C "$B" update-index --add --cacheinfo 160000,"$BETA","$EVIL"
git -C "$B" config -f .gitmodules submodule.team.path brains/team/beta
git -C "$B" config -f .gitmodules submodule.team.url https://github.com/example-org/beta-brain.git
git -C "$B" update-index --add --cacheinfo 160000,"$BETA",brains/team/beta
for k in team/kea old/kea; do git -C "$B" config -f .gitmodules "submodule.$k.path" "brains/$k"; git -C "$B" update-index --add --cacheinfo 160000,"$BETA","brains/$k"; done
git -C "$B" add .gitmodules && git -C "$B" commit -q -m entries
S quokkaline
{ ! grep -q '^brains/evil\|^brains/\.\.\|^brains/ghost' <<< "$out" && grep -qx 'note: 3 .gitmodules entries under brains/ ignored (not a gitlink in HEAD, or a path that is not plain names)' <<< "$out" \
  && cov brains/team/beta | grep -q "docs NOT SEARCHED (not checked out"; } \
  && ok "only gitlinks under brains/ with plain names are mounts; the others are counted, never printed" || no "unsafe mounts ($out)"
S x --brain kea; [ "$rc" = 2 ] && grep -q "ambiguous" <<< "$out" && ok "--brain by last part is a usage error where ambiguous" || no "ambiguous ($rc: $out)"
S quokkaline --brain team/beta
{ cov brains/team/beta | grep -q "docs NOT SEARCHED" && cov brains/beta | grep -q "not in scope (--brain beta)" && cov brains/gamma | grep -q "not in scope"; } \
  && ok "...and by its path under brains/ it is not" || no "--brain path ($rc: $out)"

summary search_smoke
