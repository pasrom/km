#!/usr/bin/env bash
# Smoke test for the pure parts of the e2e driver (e2e/): the name check that keeps the public driver
# free of organisation, account and repository names, the steps that end a run (run.py, imported), and
# the seed generator (deterministic, valid).
# The live run itself needs a sandbox and two identities (e2e/README.md) and is not run here.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
E2E="$REPO/e2e"

echo "== name check"
out="$(env -u KM_E2E_DENY_FILE "$PY" "$E2E/check_names.py" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "e2e/ and this test name no repository but pasrom/km" || no "e2e/ names something ($out)"
grep 'e2e' "$REPO/README.md" > "$T/readme-e2e.txt"
out="$(env -u KM_E2E_DENY_FILE "$PY" "$E2E/check_names.py" "$T/readme-e2e.txt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the README's e2e lines name nothing" || no "README e2e lines ($out)"
mkdir -p "$T/names"
printf 'clone https://github.com/pasrom/km.git and pasrom/km@abc\napi repos/{org}/{repo}/pulls\nuses: $ORG/$REPO\ncp -r e2e/runs out\n' > "$T/names/clean.txt"
out="$(env -u KM_E2E_DENY_FILE "$PY" "$E2E/check_names.py" "$T/names/clean.txt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "km's own slug, placeholders and a lowercase -r path pass" || no "placeholders flagged ($out)"
# the planted names are built from variables, so this file passes the check it tests
O=acme-team P=pasrom
for line in "see https://github.com/$O/brain" "gh api repos/$O/brain/pulls" "GET orgs/$O" \
            "git@github.com:$O/brain.git" "uses: $O/action@v1" "gh pr list -R $O/brain" "gh pr list -R$O/brain" \
            "see https://github.com/$P/other" "km ready $O/brain 5" "gh repo clone $O/brain" \
            "see https://github.com/$O" "see https://github.com/$O/" "see https://GitHub.COM/$O/brain" \
            "https://raw.githubusercontent.com/$O/brain/main/x.md" "https://$O.github.io/brain" \
            "ghcr.io/$O/image:1" "12345+$O@users.noreply.github.com" "$O@users.noreply.github.com"; do
  printf '%s\n' "$line" > "$T/names/one.txt"
  out="$(env -u KM_E2E_DENY_FILE "$PY" "$E2E/check_names.py" "$T/names/one.txt" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && ok "flagged: $line" || no "not flagged: $line ($rc: $out)"
done
printf 'secretco # a term kept outside the repository\n' > "$T/deny.txt"
printf 'a page about SecretCo widgets\n' > "$T/names/deny.txt"
out="$(KM_E2E_DENY_FILE="$T/deny.txt" "$PY" "$E2E/check_names.py" "$T/names/deny.txt" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "deny list" && ! grep -qi secretco <<< "$out"; } && ok "a deny-list term fails, unprinted" || no "deny list ($rc: $out)"
printf 'secretcompany\n' > "$T/names/deny.txt"
KM_E2E_DENY_FILE="$T/deny.txt" "$PY" "$E2E/check_names.py" "$T/names/deny.txt" >/dev/null 2>&1 \
  && ok "a deny term inside a longer word does not count" || no "deny term matched inside a word"
printf 'the secretco-team repository\n' > "$T/names/deny.txt"
KM_E2E_DENY_FILE="$T/deny.txt" "$PY" "$E2E/check_names.py" "$T/names/deny.txt" >/dev/null 2>&1 \
  && no "a deny term joined by a hyphen passed" || ok "a deny term joined by a hyphen fails"

echo "== run cleanup"
out="$(cd "$E2E" && "$PY" -B -c 'import run
print([n for n, _, _ in run.cleanup_steps(False, {}, "")]); print([n for n, _, _ in run.cleanup_steps(True, {}, "")])' 2>&1)"
{ [ "$(sed -n 1p <<< "$out")" = "[]" ] \
  && [ "$(sed -n 2p <<< "$out")" = "['wait for runs', 'Actions off', 'drop the lock', 'count the minutes']" ]; } \
  && ok "a run without the lock leaves the sandbox alone; one with it settles, switches Actions off, then drops the lock" \
  || no "cleanup steps ($out)"

echo "== seed"
fake_km_remote "$T/kmremote"
export KM_REPO_URL="file://$T/kmremote" PYTHONPATH="$REPO/src${PYTHONPATH:+$SEP$PYTHONPATH}"
KM="$PY -P -m km"
D="2026-11-13"
for x in a b; do
  "$PY" "$E2E/seed.py" build "$T/seed-$x" --km "$KM" --date "$D" --mount "https://example.invalid/notes.git@$(printf '1%.0s' {1..40})" \
    > "$T/head-$x" 2> "$T/err-$x" || { no "seed build $x failed: $(tail -5 "$T/err-$x")"; summary e2e-smoke; exit 1; }
done
[ "$(cat "$T/head-a")" = "$(cat "$T/head-b")" ] && ok "two seeds of the same inputs are the same commit" \
  || no "seed not deterministic ($(cat "$T/head-a") vs $(cat "$T/head-b"))"
out="$(cd "$T/seed-a" && km validate 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "ERRORS: 0"; } && ok "the seed validates without errors" || no "seed validate ($out)"
out="$(cd "$T/seed-a" && km list --json 2>&1)"
n="$("$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))' <<< "$out" 2>/dev/null)"
[ "$n" = 20 ] && ok "the seed holds the 20 pages of the data set" || no "seed pages: $n"
st(){ "$PY" -c 'import json,sys; d={x["path"]: x for x in json.load(sys.stdin)}; print(d[sys.argv[1]]["status"])' "$1" <<< "$out"; }
{ [ "$(st product/old-charger.md)" = superseded ] && [ "$(st process/onboarding.md)" = draft ] \
  && [ "$(st projects/p9001/customer-faq.md)" = review ] && [ "$(st process/how-we-work.md)" = accepted ] \
  && [ "$(st product/cited-spec.md)" = accepted ]; } && ok "statuses as the data set lists them" || no "seed statuses"
grep -q "^review_by: 2026-10-14" "$T/seed-a/product/lamp-overview.md" && grep -q "^review_by: 2026-10-14" "$T/seed-a/product/charging-note.md" \
  && ok "two served pages have a lapsed review_by (run date minus 30)" || no "lapsed review_by"
out="$(cd "$T/seed-a" && km demote 2>&1)"
{ out_has "lamp-overview.md" && out_has "charging-note.md" && ! out_has "battery-choice.md"; } \
  && ok "km demote would send back exactly the lapsed pages, not the decision" || no "demote dry run ($out)"
cp "$T/seed-a/product/thermal-plot_media/plot.svg" "$T/plot.svg" && (cd "$T/seed-a/product/thermal-plot_media" && "$PY" make_plot.py) \
  && cmp -s "$T/plot.svg" "$T/seed-a/product/thermal-plot_media/plot.svg" && ok "the seeded plot is what its script writes" || no "plot.svg differs from make_plot.py"
[ "$(git -C "$T/seed-a" ls-files -s mounted/notes | cut -c1-6)" = 160000 ] && ok "the mount is a gitlink" || no "mount gitlink"
"$PY" "$E2E/seed.py" pages "$T/p1" --date 2026-01-01 && "$PY" "$E2E/seed.py" pages "$T/p2" --date 2026-01-01
diff -r "$T/p1" "$T/p2" >/dev/null && grep -q "timestamp: 2026-01-01" "$T/p1/product/lamp-overview.md" \
  && ok "pages are a pure function of the date" || no "pages not deterministic"

summary e2e-smoke
