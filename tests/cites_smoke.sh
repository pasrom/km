#!/usr/bin/env bash
# Smoke test for cited external files (`cites:`): the format check and the soft cite:missing warning
# in `km validate`, `km cite add`, `km cites check` and `km repin --cites`. Nothing here needs a
# network: the cited files are local copies.
# Run:  bash tests/cites_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
C="$(mktemp -d)"   # the local copies, outside the brain
trap 'rm -rf "$T" "$C"' EXIT
git init -q "$T"
printf 'meta: {profile: cites}\n' > "$T/schema.local.yaml"
TODAY="$(date +%F)"
SITE="https://example.sharepoint.com/sites/Example/Shared%20Documents"
URL="$SITE/report.pdf"
sha(){ kmpy -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
printf 'first version\n' > "$C/report.pdf"
H1="$(sha "$C/report.pdf")"
Z64="$(printf '0%.0s' $(seq 64))"
# doc FILE CITES_YAML [BODY]: a draft note with that cites: block (empty: none), staged
doc(){ printf -- '---\ntype: note\ntitle: d\ntimestamp: 2026-10-09\nauthor: X\nstatus: draft\ntags: [t]\n%s---\n%s\n' \
  "$2" "${3:-body}" > "$T/$1"; git -C "$T" add "$1"; }
val(){ out="$(cd "$T" && km validate "$@" 2>&1)"; rc=$?; }
run(){ out="$(cd "$T" && km "$@" 2>&1)"; rc=$?; }

# --- km validate: the format check ---
doc ok.md "cites:
- url: $URL
  title: The report
  version: \"3.0\"
  sha256: $H1
  retrieved: 2026-11-04
  ctag: '\"c:{ABC},2\"'
"
val ok.md
{ [ "$rc" = 0 ] && ! out_has "cite:"; } && ok "a well-formed cites entry is clean" || no "well-formed ($rc: $out)"
bad(){ doc bad.md "cites:
$1
"; val bad.md; { [ "$rc" = 1 ] && out_has "cite:format" && out_has "$2"; } && ok "cite:format: $3" || no "$3 ($rc: $out)"; }
bad "- url: http://example.sharepoint.com/a.pdf
  sha256: $H1
  retrieved: 2026-11-04" "https:// URL" "a non-https url is an error"
bad "- url: $URL
  sha256: abc123
  retrieved: 2026-11-04" "64 hex" "a short sha256 is an error"
bad "- url: $URL
  sha256: ${H1:0:63}g
  retrieved: 2026-11-04" "64 hex" "a non-hex sha256 is an error"
bad "- url: $URL
  sha256: $H1
  retrieved: 4.11.2026" "YYYY-MM-DD" "a non-ISO date is an error"
bad "- url: $URL
  sha256: $H1
  retrieved: \"2026-02-30\"" "YYYY-MM-DD" "an impossible date is an error"
bad "- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
  etag: x" "unknown key 'etag'" "an unknown key is an error"
bad "- url: $URL
  sha256: $H1" "'retrieved' is required" "a missing retrieved is an error"
bad "- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
  version: 3.0" "version must be a string" "an unquoted number as version is an error"
bad "- url: $URL
  sha256: $Z64
  retrieved: 2026-11-04" "64 hex" "an all-digit sha256 YAML reads as a number is an error"
bad "- $URL" "must be a mapping" "a bare URL entry is an error"
bad "- url: [$URL]
  sha256: $H1
  retrieved: 2026-11-04" "https:// URL" "a url that is a list is an error, not a crash"
bad "- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
- url: $URL#page=2
  sha256: $H1
  retrieved: 2026-11-04" "cited twice" "the same file cited twice through a fragment is an error"
doc bad.md "cites:
- sha256: $H1
  retrieved: 2026-11-04
- sha256: $H1
  retrieved: 2026-11-04
"; val bad.md
{ out_has "'url' is required" && ! out_has "cited twice"; } && ok "two entries without a url are not reported as duplicates" || no "no-url duplicates ($out)"
bad "- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04" "cited twice" "the same url twice is an error"
doc bad.md "cites: $URL
"; val bad.md
{ [ "$rc" = 1 ] && out_has "type:cites"; } && ok "cites that is not a list is an error" || no "not a list ($rc: $out)"
git -C "$T" rm -q --cached bad.md && rm -f "$T/bad.md"

# --- km validate: the soft cite:missing warning ---
doc miss.md "" "See [the report]($URL), [a share](https://1drv.ms/b/s!AbC), <https://example-my.sharepoint.com/personal/x/Documents/n.docx>, https://example.com/x.pdf and \`$SITE/code.pdf\`."
val miss.md
{ [ "$rc" = 0 ] && out_has "cite:missing" && out_has "report.pdf" && out_has "1drv.ms/b/s!AbC" && out_has "example-my.sharepoint.com" \
  && ! out_has "example.com/x.pdf" && ! out_has "code.pdf"; } \
  && ok "SharePoint and OneDrive links without a cites entry are a warning, not an error" || no "cite:missing ($rc: $out)"
doc miss.md "" "See [the budget]($SITE/Budget%20(v2).xlsx) and [sheet 2]($SITE/Budget%20(v2).xlsx#s2)."
val miss.md
out_has "1 x cite:missing" && out_has "Budget%20(v2).xlsx with no" && ok "cite:missing keeps parentheses in a file name" || no "parentheses ($out)"
doc miss.md "cites:
- url: $SITE/Budget%20(v2).xlsx
  sha256: $H1
  retrieved: 2026-11-04
" "See [the budget]($SITE/Budget%20(v2).xlsx)."
val miss.md
! out_has "cite:missing" && ok "a cited file with parentheses in its name is not reported" || no "parentheses cited ($out)"
doc miss.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
" "See [the report]($URL#page=2)."
val miss.md
! out_has "cite:missing" && ok "a link to a cited file is not reported, a fragment aside" || no "cited link ($out)"
doc miss.md "resource: $URL
" "No links here."
val miss.md
! out_has "cite:missing" && ok "only the body is scanned for cite:missing" || no "frontmatter link ($out)"
doc miss.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
" "Open [it](${URL/example.sharepoint.com/EXAMPLE.SharePoint.com}?web=1&e=AbC) or [again]($URL/)."
val miss.md
! out_has "cite:missing" && ok "a view or sharing query, a trailing slash and the host's case name the same file" || no "same_url variants ($out)"
doc miss.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
" "Old link: [it](http://example.sharepoint.com/sites/Example/shared%20documents/REPORT.pdf)."
val miss.md
! out_has "cite:missing" && ok "http and a SharePoint path's case name the same file" || no "scheme and path case ($out)"
doc miss.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
" "Shared as [this](https://example.sharepoint.com/:b:/r/sites/Example/Shared%20Documents/report.pdf?csf=1&e=Ab)."
val miss.md
! out_has "cite:missing" && ok "a /:b:/r/ sharing link names the same file as its plain path" || no "sharing /r/ link ($out)"
doc miss.md "cites:
- url: https://onedrive.live.com/?id=A1
  sha256: $H1
  retrieved: 2026-11-04
- url: https://onedrive.live.com/?id=B2&e=x
  sha256: $H1
  retrieved: 2026-11-04
" "[a](https://onedrive.live.com/?id=A1&e=y) and [c](https://onedrive.live.com/?id=C3)"
val miss.md
{ ! out_has "cited twice" && out_has "1 x cite:missing" && out_has "id=C3"; } \
  && ok "a query key that names the file (?id=) still tells files apart" || no "naming query ($out)"
doc miss.md "" "Code is not a link:

~~~
$SITE/fenced.pdf
~~~

    $SITE/indented.pdf

- a list item

    its next paragraph links [this]($SITE/in-list.pdf)
"
val miss.md
{ ! out_has "fenced.pdf" && ! out_has "indented.pdf" && out_has "in-list.pdf"; } \
  && ok "cite:missing skips ~~~ fences and indented code, not a list item's next paragraph" || no "code blocks ($out)"
BT='```'
doc miss.md "" "~~~
use $BT here
~~~

[between]($SITE/between.pdf)

[^1]: a note

    with [a link]($SITE/footnote.pdf)

${BT}bash
echo
$BT"
val miss.md
{ out_has "between.pdf" && out_has "footnote.pdf"; } \
  && ok "cite:missing: a backtick fence inside a ~~~ fence does not swallow text; a footnote's next paragraph counts" || no "nested fences ($out; $(cat "$T/miss.md"))"
doc miss.md "" "[us](https://example.sharepoint.us/sites/E/a.pdf) [cn](https://example.sharepoint.cn/sites/E/b.pdf) [de](https://example.sharepoint.de/sites/E/c.pdf) [od](https://onedrive.com/?id=D4) [site](https://example.sharepoint.com/sites/Example) [lib]($SITE) [view]($SITE/Forms/AllItems.aspx) [page](https://example.sharepoint.com/sites/Example/SitePages/Home.aspx) [form](https://example.sharepoint.com/sites/Example/Lists/X/DispForm.aspx?ID=3) [word](https://example.sharepoint.com/:w:/r/sites/Example/_layouts/15/Doc.aspx?sourcedoc=AB&file=Plan.docx) [xlsx](https://example.sharepoint.com/sites/Example/_layouts/15/Doc.aspx?sourcedoc=CD&file=Budget.xlsx) [share folder](https://example.sharepoint.com/:f:/s/Example/EaBc) [share pdf](https://example.sharepoint.com/:b:/s/Example/EdEf) [1drv folder](https://1drv.ms/f/s!Gh)"
val miss.md
{ [ "$rc" = 0 ] && out_has "sharepoint.us" && out_has "sharepoint.cn" && out_has "sharepoint.de" && out_has "onedrive.com/?id=D4" \
  && out_has "7 x cite:missing" && ! out_has "SitePages" && ! out_has "DispForm" && ! out_has "sites/Example with" && ! out_has "Shared%20Documents with" && ! out_has "AllItems" \
  && ! out_has ":f:/" && ! out_has "1drv.ms/f/"; } \
  && ok "cite:missing covers the national clouds and onedrive.com, not sites, folders or library views" || no "hosts and roots ($rc: $out)"
git -C "$T" rm -q --cached miss.md && rm -f "$T/miss.md"

# --- km cite add ---
doc add.md "related: [ok.md]   # kept as written
" "See [the report]($URL)."
cp "$T/add.md" "$C/add.before"
run cite add add.md "$URL" --file "$C/report.pdf" --title "The report" --version 3.0
{ [ "$rc" = 0 ] && grep -q "^- url: $URL$" "$T/add.md" && grep -q "^  sha256: $H1$" "$T/add.md" \
  && grep -q "^  retrieved: $TODAY$" "$T/add.md" && grep -q '^  version: "3.0"$' "$T/add.md" \
  && grep -q "^  title: The report$" "$T/add.md"; } && ok "cite add writes the entry with the file's sha256 and today" || no "cite add ($rc: $out; $(cat "$T/add.md"))"
diff <(grep -v '^cites:\|^- url\|^  ' "$T/add.md") "$C/add.before" >/dev/null \
  && ok "cite add keeps the rest of the frontmatter byte for byte" || no "frontmatter kept ($(diff <(grep -v '^cites:\|^- url\|^  ' "$T/add.md") "$C/add.before"))"
git -C "$T" add add.md; val add.md
{ [ "$rc" = 0 ] && ! out_has "cite:"; } && ok "after cite add the doc validates clean" || no "after cite add ($rc: $out)"
printf 'second version\n' > "$C/report2.pdf"; H2="$(sha "$C/report2.pdf")"
sed -i.bak "s/^  retrieved: .*/  retrieved: 2026-01-01/" "$T/add.md" && rm -f "$T/add.md.bak"
run cite add add.md "$URL" --file "$C/report2.pdf"
{ [ "$rc" = 0 ] && [ "$(grep -c '^- url:' "$T/add.md")" = 1 ] && grep -q "^  sha256: $H2$" "$T/add.md" \
  && grep -q "^  retrieved: $TODAY$" "$T/add.md" && grep -q "^  title: The report$" "$T/add.md" && ! grep -q "version:" "$T/add.md"; } \
  && ok "cite add replaces the entry for the same URL, keeps its title, drops the old version label" || no "cite add replace ($rc: $out; $(cat "$T/add.md"))"
cp "$T/add.md" "$C/add.same"
run cite add add.md "${URL/example.sharepoint.com/EXAMPLE.sharepoint.com}?web=1" --file "$C/report2.pdf"
{ [ "$rc" = 0 ] && out_has "already cites" && cmp -s "$T/add.md" "$C/add.same"; } \
  && ok "cite add of the same content through a URL variant changes nothing, not even the date" || no "same-content re-cite ($rc: $out; $(cat "$T/add.md"))"
run cite add add.md "$URL?e=AbC" --file "$C/report.pdf"
{ [ "$rc" = 0 ] && [ "$(grep -c '^- url:' "$T/add.md")" = 1 ] && grep -q "^  sha256: $H1$" "$T/add.md"; } \
  && ok "cite add through a sharing-link variant replaces the entry, not a second one" || no "variant replaces ($rc: $out; $(cat "$T/add.md"))"
run cite add add.md "$URL" --file "$C/report2.pdf"
run cite add add.md "$SITE/other%20file.xlsx" --file "$C/report.pdf" --version 2026-02-30
{ [ "$rc" = 0 ] && [ "$(grep -c '^- url:' "$T/add.md")" = 2 ] && grep -q "^  sha256: $H2$" "$T/add.md" \
  && grep -q '^  version: "2026-02-30"$' "$T/add.md"; } \
  && ok "cite add appends an entry and quotes an odd label" || no "cite add append ($rc: $out; $(cat "$T/add.md"))"
run cite add add.md "https://example.sharepoint.com/:b:/r/sites/Example/Shared%20Documents/report.pdf?csf=1" --file "$C/report.pdf"
{ [ "$rc" = 0 ] && [ "$(grep -c '^- url:' "$T/add.md")" = 2 ] && grep -q "^  sha256: $H1$" "$T/add.md"; } \
  && ok "cite add through a /:b:/r/ sharing link replaces the plain path's entry" || no "cite add /r/ link ($rc: $out; $(cat "$T/add.md"))"
cp "$T/add.md" "$C/add.op"
for op in "https://example.sharepoint.com/:b:/g/EaBcDeF?e=xyz" "https://example.sharepoint.com/:w:/s/Example/EdEfGh" "https://1drv.ms/b/s!AbC" \
          "https://example.sharepoint.com/sites/Example/_layouts/15/Doc.aspx?sourcedoc=%7BAB%7D&file=Plan.docx" "https://onedrive.live.com/?id=A1"; do
  run cite add add.md "$op" --file "$C/report.pdf"
  { [ "$rc" = 2 ] && out_has "token, not a path" && out_has "path URL" && cmp -s "$T/add.md" "$C/add.op"; } \
    && ok "cite add refuses an opaque sharing link: ${op#https://}" || no "opaque link $op ($rc: $out)"
done
cp "$T/add.md" "$C/add.keep"
run cite add add.md "http://example.sharepoint.com/sites/Example/x.pdf" --file "$C/report.pdf"
{ [ "$rc" = 2 ] && out_has "not an https" && cmp -s "$T/add.md" "$C/add.keep"; } && ok "cite add refuses a non-https URL" || no "cite add http ($rc: $out)"
run cite add add.md "$URL"
{ [ "$rc" = 2 ] && cmp -s "$T/add.md" "$C/add.keep"; } && ok "cite add requires --file" || no "cite add without --file ($rc: $out)"
run cite add add.md "$URL" --file "$C/nope.pdf"
{ [ "$rc" = 2 ] && cmp -s "$T/add.md" "$C/add.keep"; } && ok "cite add refuses a missing local copy" || no "cite add missing file ($rc: $out)"
# a large file is hashed in chunks: memory stays well below its size
dd if=/dev/zero of="$C/big.bin" bs=1048576 count=200 2>/dev/null
out="$(cd "$T" && KM_ROOT="$T" kmpy -c 'import resource, sys
from km.cites import sha256_file
print(sha256_file(sys.argv[1]))
peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print("peak-mb", peak // (1 << 20) if sys.platform == "darwin" else peak // 1024)' "$C/big.bin" 2>&1)"
peak="$(echo "$out" | sed -n 's/^peak-mb //p')"
{ [ "$(echo "$out" | head -1)" = "$(sha "$C/big.bin")" ] && [ -n "$peak" ] && [ "$peak" -lt 120 ]; } \
  && ok "a 200 MB file is hashed streamed (peak ${peak} MB)" || no "large file ($out)"
rm -f "$C/big.bin"

# --- km cites check ---
doc chk.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
- url: $SITE/Q%C3%BCartal%20plan.xlsx
  sha256: $H1
  retrieved: 2026-11-04
- url: $SITE/never-synced.pdf
  sha256: $H1
  retrieved: 2026-11-04
"
git -C "$T" add -A
before="$(git -C "$T" status --porcelain; cat "$T/chk.md")"
run cites check chk.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 0 ] && out_has "current .*report.pdf" && out_has "1 current, 0 stale, 2 unchecked"; } \
  && ok "check: a matching copy is current, the others unchecked, exit 0" || no "check current ($rc: $out)"
run cites check chk.md --file "$URL=$C/report2.pdf"
{ [ "$rc" = 1 ] && out_has "stale .*report.pdf" && out_has "recorded ${H1:0:12}"; } && ok "check: a changed copy is stale, exit 1" || no "check stale ($rc: $out)"
[ "$before" = "$(git -C "$T" status --porcelain; cat "$T/chk.md")" ] && ok "check writes nothing" || no "check wrote"
doc inv.md "cites:
- url: $URL
  sha256: abc
  retrieved: 2026-11-04
"
run cites check inv.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 1 ] && out_has "invalid" && out_has "1 invalid"; } && ok "check: a malformed entry fails the check" || no "check invalid ($rc: $out)"
doc inv.md "cites: $URL
"
run cites check inv.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 1 ] && out_has "invalid .*must be a list"; } && ok "check: a cites: that is not a list is reported, exit 1" || no "check not a list ($rc: $out)"
doc inv.md "cites:
- $URL
"
run cites check inv.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 1 ] && out_has "invalid .*must be a mapping"; } && ok "check: an entry that is not a mapping is reported" || no "check not a mapping ($rc: $out)"
doc inv.md "cites:
- url: $URL
  sha256: $H1
  retrieved: 2026-11-04
- url: $URL?web=1
  sha256: $H2
  retrieved: 2026-11-04
"
run cites check inv.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 1 ] && out_has "invalid .*cited twice"; } && ok "check: the same file cited twice is reported, as validate does" || no "check duplicate ($rc: $out)"
git -C "$T" rm -q --cached inv.md && rm -f "$T/inv.md"
run cites check chk.md --file "$URL=$C/nope.pdf"
[ "$rc" = 2 ] && ok "check: a missing --file copy is a usage error, exit 2" || no "check missing file ($rc: $out)"
run cites check chk.md --file "$C/report.pdf"
[ "$rc" = 2 ] && ok "check: --file without URL= is a usage error" || no "check bad --file ($rc: $out)"
run cites check chk.md
[ "$rc" = 2 ] && ok "check: neither --file nor --dir is a usage error" || no "check without copies ($rc: $out)"
run cites check chk.md --dir "$C/nowhere=$SITE"
{ [ "$rc" = 2 ] && out_has "does not exist" && out_has "LOCAL=URLPREFIX"; } \
  && ok "check: a mapped folder that does not exist is a usage error that says so" || no "check missing dir ($rc: $out)"
# --dir LOCAL=URLPREFIX: the folder holds exactly what the prefix holds; a URL below it names one
# local path (decoded, NFC, case-insensitive per segment), nothing is searched for by name
LIB="$C/Example - Documents"
MAP="$LIB=https://example.sharepoint.com/sites/Example/Shared Documents"
mkdir -p "$LIB/Sub"
cp "$C/report.pdf" "$LIB/QÜARTAL PLAN.xlsx"
cp "$C/report2.pdf" "$LIB/report.pdf"
cp "$C/report.pdf" "$LIB/Sub/report.pdf"
run cites check chk.md --file "$URL=$C/report.pdf" --dir "$MAP"
[ "$rc" = 2 ] && ok "check: --file and --dir together are a usage error" || no "check both ($rc: $out)"
run cites check chk.md --dir "$MAP"
{ [ "$rc" = 1 ] && out_has "current .*QÜARTAL PLAN.xlsx" && out_has "stale .*Example - Documents/report.pdf: ${H2:0:12}" \
  && ! out_has "Sub/" && out_has "unchecked .*never-synced.pdf (no local copy at $LIB/never-synced.pdf)"; } \
  && ok "check --dir maps the URL 1:1 below the prefix: a root file, decoded and case-insensitive names, no namesake search" || no "check --dir ($rc: $out)"
run cites check chk.md --dir "$LIB"
{ [ "$rc" = 2 ] && out_has "LOCAL=URLPREFIX"; } && ok "check: a bare --dir is a usage error that shows the form" || no "check bare dir ($rc: $out)"
mkdir -p "$C/a=b" && cp "$C/report.pdf" "$C/a=b/report.pdf"
run cites check chk.md --dir "$C/a=b=$SITE"
{ [ "$rc" = 0 ] && out_has "current .*a=b/report.pdf"; } && ok "check: a LOCAL folder whose name holds = still maps" || no "check = in LOCAL ($rc: $out)"
mkdir -p "$T/brains/peer" && cp "$T/chk.md" "$T/brains/peer/p.md"
run cites check brains/peer/p.md --dir "$MAP"
{ [ "$rc" = 2 ] && out_has "skip_prefixes"; } && ok "check refuses a doc in a mounted brain" || no "check mounted brain ($rc: $out)"
rm -rf "$T/brains"
run cites check --dir "$MAP"
{ out_has "chk.md" && out_has "ok.md" && ! out_has "add.md.*never"; } && ok "check without docs checks every doc that cites" || no "check all ($rc: $out)"
doc share.md "cites:
- url: https://example.sharepoint.com/:b:/r/sites/Example/Shared%20Documents/report.pdf?csf=1&web=1
  sha256: $H2
  retrieved: 2026-11-04
"
run cites check share.md --dir "$MAP"
{ [ "$rc" = 0 ] && out_has "current .*Example - Documents/report.pdf"; } \
  && ok "check --dir maps a sharing link that carries the path (/:b:/r/)" || no "check sharing link ($rc: $out)"
git -C "$T" rm -q --cached share.md && rm -f "$T/share.md"

# --- km repin --cites ---
acc(){ doc "$1" "cites:
- url: $URL
  version: \"3.0\"
  ctag: c1
  sha256: $H1
  retrieved: 2026-01-01
- url: $SITE/never-synced.pdf
  sha256: $H1
  retrieved: 2026-01-02
"
  sed -i.bak 's/^status: draft$/status: accepted\
owner: X\
review_by: 2099-01-01\
approved_by: "X"\
approved_at: 2026-10-09\
reviewed_by:\
- "model-x 2026-10-09 (PR #1)"/' "$T/$1" && rm -f "$T/$1.bak" && git -C "$T" add "$1"; }
acc rp.md
run repin --cites rp.md --file "$URL=$C/report.pdf"
{ [ "$rc" = 0 ] && out_has "already cites" && grep -q "^status: accepted" "$T/rp.md"; } \
  && ok "repin --cites with an unchanged copy changes nothing" || no "repin unchanged ($rc: $out)"
run repin --cites rp.md --file "$URL=$C/report2.pdf"
{ [ "$rc" = 0 ] && grep -q "^  sha256: $H2$" "$T/rp.md" && grep -q "^  retrieved: $TODAY$" "$T/rp.md" \
  && grep -q "^  retrieved: 2026-01-02$" "$T/rp.md" && out_has "dropped the old version label" && ! grep -q "version:\|ctag:" "$T/rp.md" \
  && out_has "from $C/report2.pdf" && out_has "not compared: $SITE/never-synced.pdf (no local copy given)"; } \
  && ok "repin --cites rewrites the changed entry, the other keeps its date" || no "repin changed ($rc: $out; $(cat "$T/rp.md"))"
{ grep -q "^status: review" "$T/rp.md" && ! grep -q "^approved_\|reviewed_by\|model-x" "$T/rp.md" && out_has "back to review"; } \
  && ok "repin --cites sends an accepted doc back to review" || no "repin demotion ($(cat "$T/rp.md"))"
acc rp2.md
run repin --cites rp2.md --dir "$MAP"
{ [ "$rc" = 0 ] && grep -q "^  sha256: $H2$" "$T/rp2.md" && grep -q "^status: review" "$T/rp2.md" && out_has "from $LIB/report.pdf" \
  && out_has "not compared: $SITE/never-synced.pdf (no local copy at $LIB/never-synced.pdf)"; } \
  && ok "repin --cites --dir re-pins against the mapped copy" || no "repin --dir ($rc: $out; $(cat "$T/rp2.md"))"
acc rp4.md
mkdir -p "$C/locked" && printf 'locked\n' > "$C/locked/report.pdf" && chmod 000 "$C/locked/report.pdf"
run cites check rp4.md --dir "$C/locked=$SITE"
{ [ "$rc" = 0 ] && out_has "unchecked .*unreadable"; } && ok "check: a mapped copy that cannot be read leaves it unchecked" || no "check unreadable ($rc: $out)"
run repin --cites rp4.md --dir "$C/locked=$SITE"
{ [ "$rc" = 1 ] && out_has "unreadable" && grep -q "^  sha256: $H1$" "$T/rp4.md"; } \
  && ok "repin --cites refuses when the mapped copy cannot be read" || no "unreadable copy ($rc: $out)"
acc rp5.md
run repin --cites rp5.md --file "$URL=$C/locked/report.pdf"
{ [ "$rc" = 1 ] && out_has "unreadable" && grep -q "^status: accepted" "$T/rp5.md"; } \
  && ok "repin --cites refuses when the only copy is unreadable" || no "unreadable only copy ($rc: $out)"
chmod 644 "$C/locked/report.pdf"
run repin --cites rp2.md --dir "$LIB"
{ [ "$rc" = 2 ] && out_has "LOCAL=URLPREFIX"; } && ok "repin --cites: a bare --dir is a usage error that shows the form" || no "repin bare dir ($rc: $out)"
run repin --cites rp2.md --dir "$C/nowhere-$$=$SITE"
{ [ "$rc" = 2 ] && out_has "does not exist" && out_has "LOCAL=URLPREFIX"; } \
  && ok "repin --cites: a mapped folder that does not exist is a usage error that says so" || no "repin missing dir ($rc: $out)"
mkdir -p "$C/empty"; cp "$T/rp2.md" "$C/rp2.keep"
run repin --cites rp2.md --dir "$C/empty=$SITE"
{ [ "$rc" = 0 ] && out_has "compared nothing" && cmp -s "$T/rp2.md" "$C/rp2.keep"; } \
  && ok "repin --cites says when it found no local copy at all" || no "repin no copy ($rc: $out)"
run repin --cites rp2.md
[ "$rc" = 2 ] && ok "repin --cites without --file or --dir is a usage error" || no "repin no copies ($rc: $out)"
run repin rp2.md --dir "$MAP"
[ "$rc" = 2 ] && ok "repin --dir without --cites is a usage error" || no "repin --dir alone ($rc: $out)"
# cite add replacing a signed-off doc's hash sends it back to review too
acc rp3.md
run cite add rp3.md "$URL" --file "$C/report2.pdf"
{ [ "$rc" = 0 ] && grep -q "^status: review" "$T/rp3.md"; } && ok "cite add with a changed hash sends a signed-off doc back to review" || no "cite add demotion ($rc: $out)"
acc rp6.md; cp "$T/rp6.md" "$C/rp6.keep"
run cite add rp6.md "$URL" --file "$C/report.pdf"
{ [ "$rc" = 0 ] && cmp -s "$T/rp6.md" "$C/rp6.keep"; } && ok "cite add of the same content leaves a signed-off doc as it is" || no "same content signed-off ($rc: $out)"
run cite add rp6.md "$URL" --file "$C/report.pdf" --version 4.0
{ [ "$rc" = 0 ] && grep -q '^  version: "4.0"$' "$T/rp6.md" && grep -q "^status: accepted" "$T/rp6.md" && grep -q "^  retrieved: 2026-01-01$" "$T/rp6.md"; } \
  && ok "cite add with a new label only relabels: no new date, no demotion" || no "relabel ($rc: $out; $(cat "$T/rp6.md"))"
run cite add rp6.md "$SITE/new%20source.pdf" --file "$C/report.pdf"
{ [ "$rc" = 0 ] && grep -q "^status: review" "$T/rp6.md" && out_has "back to review"; } \
  && ok "cite add of a new file sends a signed-off doc back to review" || no "new cite demotion ($rc: $out)"

# an approval key it cannot find (quoted): sent back all the same, the key named, exit 1 (as km demote)
for c in "repin --cites" "cite add"; do
  f="q${c%% *}.md"; acc "$f"; sed -i.bak 's/^approved_by:/"approved_by":/' "$T/$f" && rm -f "$T/$f.bak"; git -C "$T" add "$f"
  if [ "$c" = "cite add" ]; then run cite add "$f" "$URL" --file "$C/report2.pdf"; else run repin --cites "$f" --file "$URL=$C/report2.pdf"; fi
  { [ "$rc" = 1 ] && out_has "drop its approved_by by hand" && out_has "1 doc(s) sent back still carry a key" \
    && grep -q "^status: review" "$T/$f" && grep -q '^"approved_by"' "$T/$f"; } \
    && ok "$c sends back a doc with a quoted approved_by, names the key and exits 1" || no "$c quoted approved_by ($rc: $out; $(cat "$T/$f"))"
done
acc qr.md; sed -i.bak 's/^approved_by:/"approved_by":/' "$T/qr.md" && rm -f "$T/qr.md.bak"; git -C "$T" add qr.md
run cite add qr.md "$URL" --file "$C/report.pdf" --version 4.0
{ [ "$rc" = 0 ] && grep -q "^status: accepted" "$T/qr.md" && ! out_has "still carry"; } \
  && ok "cite add that only relabels a signed-off doc with a quoted approved_by sends nothing back, exit 0" || no "relabel quoted ($rc: $out)"

# --dir maps a library to its URL prefix, 1:1: a doc citing the HR library's A/Datasheet.pdf is
# never checked against the Eng library's A/Datasheet.pdf, even when only Eng is synced
mkdir -p "$C/Eng - Docs/A" "$C/HR - Docs/A"
printf 'eng sheet\n' > "$C/Eng - Docs/A/Datasheet.pdf"
printf 'hr sheet\n' > "$C/HR - Docs/A/Datasheet.pdf"
ENG="$C/Eng - Docs=https://example.sharepoint.com/sites/Eng/Shared Documents"
HR_URL="https://example.sharepoint.com/sites/HR/Shared%20Documents/A/Datasheet.pdf"
acc hr.md
sed -i.bak "s|^- url: $URL\$|- url: $HR_URL|" "$T/hr.md" && rm -f "$T/hr.md.bak" && git -C "$T" add hr.md
cp "$T/hr.md" "$C/hr.keep"
run cites check hr.md --dir "$ENG"
{ [ "$rc" = 0 ] && out_has "unchecked .*sites/HR/.*not under any --dir library" && out_has "no cited URL is under --dir https://example.sharepoint.com/sites/Eng" \
  && out_has "LOCAL=URLPREFIX"; } \
  && ok "check: a URL of another library is not under the --dir prefix: unchecked, with the expected form" || no "check cross-library ($rc: $out)"
run repin --cites hr.md --dir "$ENG"
{ [ "$rc" = 0 ] && out_has "compared nothing" && out_has "not under any --dir library" && cmp -s "$T/hr.md" "$C/hr.keep"; } \
  && ok "repin --cites never pins another library's file to a URL" || no "repin cross-library ($rc: $out; $(cat "$T/hr.md"))"
run repin --cites hr.md --dir "$ENG" --dir "$C/HR - Docs=https://EXAMPLE.sharepoint.com/sites/hr/shared documents/"
{ [ "$rc" = 0 ] && grep -q "^  sha256: $(sha "$C/HR - Docs/A/Datasheet.pdf")$" "$T/hr.md" && out_has "from $C/HR - Docs/A/Datasheet.pdf"; } \
  && ok "repin --cites with the right library maps the path, the prefix's case and a trailing slash aside" || no "repin mapped ($rc: $out; $(cat "$T/hr.md"))"
mkdir -p "$C/only-A"; printf 'nested\n' > "$C/only-A/Datasheet.pdf"
run cites check hr.md --dir "$C/HR - Docs=https://example.sharepoint.com/sites/HR/Shared Documents" \
  --dir "$C/only-A=https://example.sharepoint.com/sites/HR/Shared Documents/A"
out_has "stale .*only-A/Datasheet.pdf" && ok "check: the most specific --dir prefix wins" || no "longest prefix ($rc: $out)"
run repin --cites hr.md --file "$SITE/ProjC/Other.pdf=$C/report.pdf"
out_has "no doc given cites" && ok "repin --cites names a --file URL no doc cites" || no "repin unused --file ($rc: $out)"

# a token link in the body: the warning says to link the path URL instead (cite add refuses the token)
doc tok.md "" "[t](https://example.sharepoint.com/:b:/s/Eng/EabcTOKEN?e=x)"; git -C "$T" add tok.md
run validate tok.md
{ out_has "cite:missing" && out_has "names the file by a token: link the file's path URL instead"; } \
  && ok "cite:missing tells a token link to become the path URL" || no "token warning ($rc: $out)"
# a --dir whose prefix no cited URL falls under is named even when another --dir matched
run cites check hr.md --dir "$C/HR - Docs=https://example.sharepoint.com/sites/HR/Shared Documents" \
  --dir "$C/Eng - Docs=https://example.sharepoint.com/sites/Engg/Shared Documents"
{ out_has "no cited URL is under --dir https://example.sharepoint.com/sites/Engg" && ! out_has "under --dir https://example.sharepoint.com/sites/HR"; } \
  && ok "check names the --dir that matched nothing, beside one that matched" || no "idle dir ($rc: $out)"
# a sharing or viewer link is no library prefix
run cites check hr.md --dir "$C/HR - Docs=https://example.sharepoint.com/:f:/s/HR/EaBc"
{ [ "$rc" = 2 ] && out_has "not the library's path URL"; } && ok "--dir refuses a sharing link as its URL prefix" || no "opaque prefix ($rc: $out)"
summary "cites-smoke"
