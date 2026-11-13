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

echo "== queue oracle"
out="$(cd "$E2E" && "$PY" -B - <<'PYEOF' 2>&1
import datetime
import oracle as O
now = datetime.datetime(2026, 11, 13, 12, tzinfo=datetime.timezone.utc)
H = "a" * 40
def pr(n, labels=(), draft=False, bot=False, days=0, base="main", head=H, body=f"Last reviewed: {H}"):
    t = (now - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"number": n, "is_bot": bot, "labels": list(labels), "updated_at": t, "draft": draft, "base": base,
            "head": head, "body": body}
CI = {"name": "validate", "workflow": "ci", "bucket": "pass"}
GUIDE = {"name": "guide", "workflow": "review-request-guide", "bucket": "pass"}
ok = {"ready": (0, "counts: x"), "checks": [CI, GUIDE]}
R = ["km:ready"]
prs = [pr(1, draft=True, labels=R), pr(2, bot=True), pr(3, days=20), pr(4, R, days=20),
       pr(5, ["km:blocked", "km:ready"]), pr(6, ["km:needs-human"]), pr(7, R), pr(8, ["km:later"]), pr(9, ["bug"]),
       pr(10, R, body="Last reviewed: " + "b" * 40), pr(11, R), pr(12, R), pr(13, R), pr(14, R, base="feat"),
       pr(15, R, body="Labels: km:ready"), pr(16, R, body=f"Last reviewed: {'c' * 40}\nLast reviewed: `{H}`"),
       pr(17, R), pr(18, R, body=f"Last reviewed: {H[:7]}"), pr(19, R, body=f"Last reviewed: {H}\nLast reviewed: soon"),
       pr(20, R), pr(21, R)]
det = {n: ok for n in (4, 7, 10, 14, 15, 16, 18, 19)}
det |= {11: {**ok, "ready": (1, "does not count: set by its author")},
        12: {**ok, "checks": [CI, {**GUIDE, "bucket": "pending"}]},
        13: {**ok, "checks": []},
        17: {**ok, "checks": [GUIDE], "ci_waiting": True},
        20: {**ok, "checks": [CI, {**GUIDE, "bucket": "fail"}]},
        21: {**ok, "checks": [{**CI, "bucket": "pending"}]}}
q = O.classify_prs(prs, "main", now, det)
g = {n: r["group"] for n, r in q.items()}
want = {1: "drafts", 2: "bots", 3: "stale", 5: "km:blocked", 6: "km:needs-human", 8: "other km:", 9: "no label"}
print(all(g[n] == want.get(n, "km:ready") for n in g) or g)
why = {n: r.get("reasons") for n, r in q.items() if r["group"] == "km:ready"}
print([n for n, w in why.items() if not w] == [4, 7, 16] or why)
one = lambda n, s: len(why[n]) == 1 and s in why[n][0]
print(all([one(10, "is not the head"), one(11, "does not count"), one(12, "checks pending"), one(13, "no passing ci check"),
           one(14, "stacked"), one(15, "no `Last reviewed:`"), one(17, "its run waits for a person"),
           one(18, "names no full commit sha"), one(19, "names no full commit sha"), one(20, "a check fails"),
           why[21] == ["checks pending", "no passing ci check"], q[14]["stacked"]]) or why)
print(O.last_reviewed("Last reviewed: `ABCDEF" + "0" * 34 + "`\n") == "abcdef" + "0" * 34)
def raises(fn):
    try:
        fn()
    except O.NotChecked:
        return True
    return False
import subprocess, types
def ctx(stdout="", stderr="", rc=0):
    done = subprocess.CompletedProcess([], rc, stdout, stderr)
    return types.SimpleNamespace(cfg=types.SimpleNamespace(slug="o/r"), gh=lambda *a: done, km=lambda *a: done)
print(all([raises(lambda: O.classify_prs([pr(30, R)], "main", now, {30: {**ok, "ready": (2, "no gh")}})),
           raises(lambda: O.classify_prs([pr(31, R)], "main", now, {})),
           raises(lambda: O.classify_docs([{"path": "x.md", "status": "review", "signoff": None}], [])),
           O.pr_checks(ctx('[{"name": "validate", "workflow": "ci", "bucket": "pass"}]'), 1)[0]["workflow"] == "ci",
           O.pr_checks(ctx(stderr="no checks reported on the 'x' branch", rc=1), 1) == [],
           raises(lambda: O.pr_checks(ctx(stderr="GraphQL: Resource not accessible by personal access token", rc=1), 1)),
           O.km_list(ctx('[{"path": "a.md"}]'), None) == [{"path": "a.md"}],
           O.km_list(ctx("[]", rc=1), None) == [] and O.km_list(ctx("", rc=1), None) == [],
           raises(lambda: O.km_list(ctx("", "Traceback", rc=2), None)),
           raises(lambda: O.km_list(ctx("not json"), None))]))
listed = [{"path": "a.md", "status": "accepted", "signoff": "ai", "owner": "BBB"},
          {"path": "b.md", "status": "review", "signoff": "human", "owner": ["CCC", "AAA"]},
          {"path": "c.md", "status": "review", "signoff": "ai", "owner": None},
          {"path": "d.md", "status": "review", "signoff": "ai", "owner": "AAA"},
          {"path": "e.md", "status": "accepted", "signoff": "ai", "owner": "AAA"}]
d = O.classify_docs(listed, ["a.md"])
print(d == {"overdue": {"BBB": ["a.md"]}, "needs a person": {"AAA": ["b.md"], "CCC": ["b.md"]},
            "an AI review may sign off": {"AAA": ["d.md"], "no owner": ["c.md"]}} or d)
print(list(d["an AI review may sign off"]) == ["AAA", "no owner"])
PYEOF
)"
[ "$out" = "$(printf 'True\nTrue\nTrue\nTrue\nTrue\nTrue\nTrue')" ] \
  && ok "the queue oracle groups PRs and docs, gives each merge-candidate reason as queue.md says, and never turns 'not checked' into a verdict" \
  || no "queue oracle ($out)"

echo "== scenario ids"
out="$(cd "$E2E" && "$PY" -B -c 'import run
ids = [s[0] for s in run.SCENARIOS]
print(len(ids) == len(set(ids)), all(callable(s[1]) for s in run.SCENARIOS))' 2>&1)"
[ "$out" = "True True" ] && ok "scenario ids are unique and each has a function" || no "scenario registry ($out)"

echo "== driver calls"
out="$(cd "$E2E" && "$PY" -B - <<'PYEOF' 2>&1
import ast, inspect, pathlib, lib
# every ctx.<method>(...) call in the driver names only keywords that method takes
sig = {n: inspect.signature(f).parameters for n, f in inspect.getmembers(lib.Ctx, inspect.isfunction)}
takes = {n: set(ps) for n, ps in sig.items() if all(p.kind != p.VAR_KEYWORD for p in ps.values())}   # **kw: any
bad = [f"{p.name}:{c.lineno} {c.func.attr}({k.arg}=)" for p in pathlib.Path(".").glob("*.py")
       for c in ast.walk(ast.parse(p.read_text())) if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute)
       and isinstance(c.func.value, ast.Name) and c.func.value.id == "ctx" and c.func.attr in takes
       for k in c.keywords if k.arg and k.arg not in takes[c.func.attr]]
print(bad == [] or bad)
t = lib.TRANSIENT_PUSH.search
print(bool(t(" ! [remote rejected] HEAD -> x (failed)")) and bool(t("The requested URL returned error: 502"))
      and not t(" ! [rejected] HEAD -> main (non-fast-forward)") and not t("Authentication failed"))
PYEOF
)"
[ "$out" = "$(printf 'True\nTrue')" ] && ok "driver calls name only keywords the Ctx methods take; only transient push errors are retried" \
  || no "driver calls ($out)"

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

echo "== expected findings against this km"
# the texts the live scenarios expect (catalogue.finding) must be what this km's validate prints
expect(){ out="$(cd "$1" && km validate --signoff-since main 2>&1)"
  (cd "$E2E" && "$PY" -B -c 'import re, sys, catalogue as C
sys.exit(0 if re.search(C.finding(sys.argv[1], sys.argv[2], getattr(C, sys.argv[3], sys.argv[3])), sys.stdin.read()) else 1)' "$2" "$3" "$4" <<< "$out"); }
cp -R "$T/seed-a" "$T/lower" && git -C "$T/lower" checkout -q -b e2e
sed -i.bak '/^approval: human$/d' "$T/lower/process/label-guide.md" && rm "$T/lower/process/label-guide.md.bak"
git -C "$T/lower" "${G[@]}" commit -qam lower --no-verify
expect "$T/lower" signoff process/label-guide.md LOWERED && ok "E10's lowered-level finding is this km's text" \
  || no "E10 finding not in km validate's output"
cp -R "$T/seed-a" "$T/edit" && git -C "$T/edit" checkout -q -b e2e && printf '\nInvented.\n' >> "$T/edit/process/how-we-work.md"
git -C "$T/edit" "${G[@]}" commit -qam edit --no-verify
expect "$T/edit" approval-stale process/how-we-work.md "content changed since approved_by" \
  && ok "E16's approval-stale finding is this km's text" || no "E16 finding not in km validate's output"
! expect "$T/seed-a" approval-stale process/how-we-work.md "content changed since approved_by" \
  && ok "and it is not found on the unchanged seed" || no "finding pattern matches the clean seed"

summary e2e-smoke
