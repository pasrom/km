#!/usr/bin/env bash
# Smoke test for the brain's runner (km.runner): `runner:` in schema.local.yaml, written by `km init --team`
# and `km upgrade` into every runs-on line of the team workflows and the tools step's condition; the
# upgrade of km 1.22 copies, which read the variable KM_RUNNER; a label change; recognition on any label.
# Run:  bash tests/runner_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
KM_REF="v$(km --version)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fake_km_remote "$T/remote"; export KM_REPO_URL="file://$T/remote"
KM_SHA="$(git -C "$T/remote" rev-parse "$KM_REF^{commit}")"
WF=.github/workflows
SHIPPED="$(kmpy -c 'import km.upgrade as u; print(*(t[5:-4] for t in u.SHIPPED if t.endswith(".yml")))')"   # the shipped workflows
EXPR="\${{ vars.KM_RUNNER || 'ubuntu-latest' }}"
team(){ km init "$1" --team --name R --desc r --initials RR --folder d=D "${@:2}" >/dev/null && git -C "$1" init -q && git -C "$1" add -A; }
# runners DIR: every runner written into DIR's team workflows, one per line, sorted
runners(){ kmpy -c 'import sys, pathlib; from km.runner import labels, runs_on
print("\n".join(sorted({l for p in pathlib.Path(sys.argv[1], ".github/workflows").glob("*.yml") for t in [p.read_text(encoding="utf-8")]
                         for l in labels(t) | {v for v in runs_on(t) if "MOUNTED_PINS_RUNNER" not in v}})))' "$1"; }
# kms DIR: whether km takes each team workflow of DIR for its own (ci by KM_CI, the copies by SHIPPED)
kms(){ kmpy -c 'import sys, pathlib, km.upgrade as u
from km.runner import setting
w = pathlib.Path(sys.argv[1], ".github/workflows")
bad = [n for n in sys.argv[2].split() if not u.shipped(w.joinpath(n + ".yml").read_text(encoding="utf-8"), u.SHIPPED[f"team/{n}.yml"])]
bad or u.is_km_ci(w.joinpath("ci.yml").read_text(encoding="utf-8"), {setting(pathlib.Path(sys.argv[1]))} - {None}) or bad.append("ci")
sys.exit(" ".join(bad) or None)' "$1" "$SHIPPED"; }
# as122 DIR [ubuntu]: DIR's workflows as km 1.22.0 and 1.22.1 wrote them (the same files), pinned to this km;
# with `ubuntu`, ci and staleness as an earlier km wrote them, without the KM_RUNNER line and the timeout
as122(){ local n; for n in ci staleness $SHIPPED; do
    sed "s|<KM_SHA>|$KM_SHA|; s|<KM_VERSION>|$KM_REF|" "$REPO/tests/fixtures/team-1.22/$n.yml" > "$1/$WF/$n.yml"; done
  [ -z "${2:-}" ] || for n in ci staleness; do
    sed "s/runs-on: .*/runs-on: ubuntu-latest/; /timeout-minutes: 15/d" "$1/$WF/$n.yml" > "$1/$WF/$n.r" && mv "$1/$WF/$n.r" "$1/$WF/$n.yml"; done; }
set_runner(){ grep -v "^runner:" "$1/schema.local.yaml" > "$1/s.r"; echo "runner: $2" >> "$1/s.r"; mv "$1/s.r" "$1/schema.local.yaml"; }

# --- init ---
A="$T/a"; team "$A"
[ "$(runners "$A")" = ubuntu-latest ] && ! grep -q "^runner:" "$A/schema.local.yaml" && grep -q "^# runner: my-runner" "$A/schema.local.yaml" \
  && ok "init --team without --runner: every job on ubuntu-latest, the setting documented but unset" || no "init without runner ($(runners "$A"))"
grep -rq "vars.KM_RUNNER" "$A/$WF" && no "init writes no KM_RUNNER" || ok "init writes no runs-on that reads the variable KM_RUNNER"
B="$T/b"; team "$B" --runner my-runner
{ [ "$(runners "$B")" = my-runner ] && grep -qx "runner: my-runner" "$B/schema.local.yaml" && ! grep -rq "<RUNNER>" "$B" \
  && grep -q "runs-on: \${{ vars.MOUNTED_PINS_RUNNER || 'my-runner' }}" "$B/$WF/bump-mounted-pins.yml"; } \
  && ok "init --team --runner: the setting, every runs-on and bump-mounted-pins' fallback" || no "init with runner ($(runners "$B"))"
out="$(cd "$B" && km validate 2>&1)" && ok "a brain with the runner setting validates" || no "validate with runner ($out)"
kms "$A" && kms "$B" && ok "km takes its own workflows for its own on ubuntu-latest and on another runner" || no "recognition after init"
out="$(km init "$T/p" --initials PP --runner my-runner 2>&1)"; [ $? != 0 ] && out_has "only a team brain" && ok "init --runner on a personal brain is refused" || no "personal --runner ($out)"
out="$(km init "$T/c" --team --name R --desc r --initials RR --folder d=D --runner "a'b" 2>&1)"; [ $? != 0 ] && [ ! -e "$T/c" ] \
  && ok "init --runner with a quote is refused before anything is written" || no "bad --runner ($out)"

# --- upgrade from km 1.22 copies ---
U="$T/u"; team "$U"; as122 "$U"; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"
{ [ "$(runners "$U")" = ubuntu-latest ] && ! grep -rq "KM_RUNNER" "$U/$WF" && grep -q "timeout-minutes: 15" "$U/$WF/ci.yml" \
  && out_has "set the runs-on of $WF/ci.yml to the brain's runner ubuntu-latest" && out_has "set the runs-on of $WF/staleness.yml" \
  && out_has "read the runner from the variable KM_RUNNER, which km reads nowhere now" && out_has 'put its label in schema.local.yaml as `runner: <label>`' \
  && out_has "updated $WF/automerge.yml to this km's version" && kms "$U"; } \
  && ok "upgrade of 1.22 copies without a setting: ubuntu-latest everywhere, KM_RUNNER gone with a note to move it, still km's" || no "upgrade 1.22, no setting ($out)"
for n in $SHIPPED; do cmp -s "$U/$WF/$n.yml" "$A/$WF/$n.yml" || no "upgraded $n.yml is not what init writes"; done
git -C "$U" add -A; out="$(km upgrade --root "$U" 2>&1)"
[ "$out" = "km upgrade: already on km $KM_REF" ] && ok "a second upgrade changes nothing" || no "upgrade twice ($out)"

U="$T/v"; team "$U"; as122 "$U"; set_runner "$U" my-runner; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"
{ [ "$(runners "$U")" = my-runner ] && out_has "if the brain sets it, delete the variable" && kms "$U"; } \
  && ok "upgrade of 1.22 copies with the setting: its runner everywhere, still km's" || no "upgrade 1.22, setting ($out)"
for n in $SHIPPED; do cmp -s "$U/$WF/$n.yml" "$B/$WF/$n.yml" || no "upgraded $n.yml is not what init --runner writes"; done

U="$T/w"; team "$U"; as122 "$U" ubuntu; set_runner "$U" my-runner; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"
{ [ "$(runners "$U")" = my-runner ] && ! out_has "workflows/ci.yml, " && ! out_has "workflows/ci.yml read" && ! out_has "staleness.yml read" && kms "$U"; } \
  && ok "ci and staleness without the KM_RUNNER line (an earlier km's) get the setting's runner and are not in the variable note" || no "upgrade, no KM_RUNNER line ($out)"

# --- a label change, and a runner the brain chose by hand ---
set_runner "$U" other.runner_2; git -C "$U" add -A; out="$(km upgrade --root "$U" 2>&1)"
{ [ "$(runners "$U")" = other.runner_2 ] && out_has "set the runner of $WF/main-guard.yml to other.runner_2" && kms "$U"; } \
  && ok "a changed label reaches every workflow on the next upgrade, which still takes them for km's" || no "label change ($out)"
sed -i.bak 's/^runner: .*//' "$U/schema.local.yaml"; git -C "$U" add -A; out="$(km upgrade --root "$U" 2>&1)"
{ grep -q "runs-on: other.runner_2" "$U/$WF/ci.yml" && grep -q "runs-on: ubuntu-latest" "$U/$WF/main-guard.yml" \
  && out_has 'left the runs-on of .github/workflows/ci.yml at other.runner_2: a runner km did not write' \
  && out_has 'set `runner: other.runner_2`'; } \
  && ok "without the setting, a label in ci.yml is left with a note, the copies go back to ubuntu-latest" || no "no setting, own label ($out)"
set_runner "$U" my-runner; git -C "$U" add -A; km upgrade --root "$U" >/dev/null 2>&1
M='s/\(uses: actions\/checkout@\)[^ ]*.*/\1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v99/'
sed "$M" "$U/$WF/main-guard.yml" > "$T/mg" && cp "$T/mg" "$U/$WF/main-guard.yml"; out="$(km upgrade --root "$U" 2>&1)"
cmp -s "$T/mg" "$U/$WF/main-guard.yml" && ! out_has main-guard && ok "a copy on the brain's runner with moved pins is left as it is" || no "moved pins on a runner ($out)"
echo "# the brain's edit" >> "$U/$WF/main-guard.yml"; set_runner "$U" x; out="$(km upgrade --root "$U" 2>&1)"
{ grep -q "runs-on: my-runner" "$U/$WF/main-guard.yml" && out_has "left $WF/main-guard.yml: the brain changed it"; } \
  && ok "an edited copy keeps its runner, with the usual note" || no "edited copy on a label change ($out)"

# --- km 1.22 copies beside a ci.yml of the brain's own; runs-on lines with a comment ---
U="$T/y"; team "$U"; as122 "$U"; echo "      - run: make" >> "$U/$WF/ci.yml"; git -C "$U" add -A; out="$(km upgrade --root "$U" 2>&1)"
{ out_has "$WF/main-guard.yml.*read the runner from the variable KM_RUNNER.*now run on ubuntu-latest" && grep -q "KM_RUNNER" "$U/$WF/ci.yml"; } \
  && ok "copies moved off KM_RUNNER beside a ci.yml of the brain's own are named in the note, that ci.yml is left" || no "KM_RUNNER note, own ci ($out)"
kmpy -c 'from km.upgrade import is_km_ci, with_runner
from km.init import template
from km.runner import rendered
t = rendered(template("team/ci.yml", {}), "ubuntu-latest")
assert not is_km_ci(t.replace("runs-on: ubuntu-latest", "runs-on: ${{ vars.ANY }}"))
c = t.replace("runs-on: ubuntu-latest", "runs-on: ubuntu-latest  # GitHub")
assert is_km_ci(c) and not is_km_ci(c.replace("ubuntu-latest  #", "my-runner  #")) and is_km_ci(c.replace("ubuntu-latest  #", "my-runner  #"), {"my-runner"})
assert with_runner(c, "my-runner") == c.replace("ubuntu-latest  #", "my-runner  #")' \
  && ok "a runs-on km never wrote (an expression, a label it did not write here) makes ci.yml not km's; a label with a comment is km's and takes the setting" || no "runs-on forms"

# --- a ci.yml on a runner km did not write: the brain's own, so no approve-fork-ci or automerge is added or widened ---
AF=$WF/approve-fork-ci.yml; AM=$WF/automerge.yml
U="$T/z"; team "$U"; rm "$U/$AF" "$U/$AM"; sed -i.bak 's/runs-on: ubuntu-latest/runs-on: my-own-box/' "$U/$WF/ci.yml"; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"
{ [ ! -e "$U/$AF" ] && [ ! -e "$U/$AM" ] && grep -q "runs-on: my-own-box" "$U/$WF/ci.yml" \
  && out_has "left the runs-on of $WF/ci.yml at my-own-box: a runner km did not write" && out_has 'set `runner: my-own-box` in schema.local.yaml'; } \
  && ok "without the setting, a hand-set label in ci.yml makes it the brain's own: approve-fork-ci and automerge are not added" || no "own label adds afc ($out)"
cp "$REPO/tests/fixtures/approve-fork-ci-1.13.1.yml" "$U/$AF"; out="$(km upgrade --root "$U" 2>&1)"
cmp -s "$REPO/tests/fixtures/approve-fork-ci-1.13.1.yml" "$U/$AF" && ok "...nor is a data-only approve-fork-ci widened beside it" || no "own label widens afc ($out)"
set_runner "$U" my-own-box; out="$(km upgrade --root "$U" 2>&1)"
{ [ -e "$U/$AM" ] && grep -q "runs-on: my-own-box" "$U/$AM" && out_has "updated $AF to this km's version"; } \
  && ok "once the setting names that label, ci.yml is km's again and gets them" || no "setting makes ci km's ($out)"
sed -i.bak 's/runs-on: my-own-box/runs-on: other-box/' "$U/$WF/ci.yml"; out="$(km upgrade --root "$U" 2>&1)"
{ grep -q "runs-on: my-own-box" "$U/$WF/ci.yml" && out_has "set the runs-on of $WF/ci.yml to the brain's runner my-own-box"; } \
  && ok "with the setting, km's ci.yml on another label is moved to the setting's" || no "setting, other label ($out)"
sed -i.bak 's/runs-on: my-own-box/runs-on: ${{ vars.MINE }}/' "$U/$WF/ci.yml"; out="$(km upgrade --root "$U" 2>&1)"
{ out_has "left the runs-on of $WF/ci.yml at .{{ vars.MINE }}: a runner km did not write" && out_has "replace it by hand with the brain's runner"; } \
  && ok "an expression in ci.yml is left, with a note to replace it by hand (no setting can make it km's)" || no "ci expression ($out)"

# --- a staleness.yml of the brain's own keeps its runs-on ---
U="$T/s"; team "$U"; printf '  extra:\n    runs-on: their-box\n    steps:\n      - run: echo\n' >> "$U/$WF/staleness.yml"; set_runner "$U" my-runner; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"
{ grep -q "runs-on: their-box" "$U/$WF/staleness.yml" && grep -q "runs-on: ubuntu-latest" "$U/$WF/staleness.yml" \
  && out_has "left the runs-on of $WF/staleness.yml: it is not km's staleness workflow (its jobs are demote, extra" \
  && grep -q "runs-on: my-runner" "$U/$WF/ci.yml"; } \
  && ok "a staleness.yml with a job of the brain's own keeps every runs-on, with a note naming the job" || no "own staleness ($out)"
U="$T/s2"; team "$U" --runner my-runner; sed -i.bak "s/0 6 \* \* 1/0 7 * * 2/" "$U/$WF/staleness.yml"; set_runner "$U" other-runner; git -C "$U" add -A
out="$(km upgrade --root "$U" 2>&1)"; grep -q "runs-on: other-runner" "$U/$WF/staleness.yml" && grep -q "0 7" "$U/$WF/staleness.yml" \
  && ok "a staleness.yml with the brain's own cron still takes the setting's runner" || no "staleness own cron ($out)"

# --- the KM_RUNNER note: first, with the variable's value where gh reads it, never a value the setting refuses ---
GB="$T/ghbin"; mkdir -p "$GB"; printf '#!/bin/sh\n[ "$*" = "variable get KM_RUNNER -R o/r" ] && echo "$KMR" && exit 0\nexit 1\n' > "$GB/gh"; chmod +x "$GB/gh"
U="$T/k"; team "$U"; as122 "$U"; git -C "$U" remote add origin https://github.com/o/r.git; git -C "$U" add -A
out="$(KMR=my-runner PATH="$GB:$PATH" km upgrade --root "$U" 2>&1)"
{ head -1 <<< "$out" | grep -q "^km upgrade: ATTENTION: .* read the runner from the variable KM_RUNNER (here my-runner).*they now run on ubuntu-latest" \
  && out_has 'set `runner: my-runner` in schema.local.yaml, run km upgrade again, then delete the variable'; } \
  && ok "1.22 copies on KM_RUNNER without the setting: the first line says every job moved, with the variable's value and the line to add" || no "KM_RUNNER attention ($out)"
U="$T/k2"; team "$U"; as122 "$U"; git -C "$U" remote add origin https://github.com/o/r.git; git -C "$U" add -A
cp -R "$U" "$T/k3"; cp -R "$U" "$T/k4"
out="$(KMR='a b' PATH="$GB:$PATH" km upgrade --root "$U" 2>&1)"
{ out_has "(here a b)" && out_has 'set `runner:` in schema.local.yaml to one label' && ! out_has 'runner: a b'; } \
  && ok "a KM_RUNNER the setting would refuse is not suggested as its value" || no "KM_RUNNER bad value ($out)"
printf '#!/bin/sh\n[ "$*" = "variable get KM_RUNNER --org o" ] && echo org-runner && exit 0\nexit 1\n' > "$GB/gh"
out="$(PATH="$GB:$PATH" km upgrade --root "$T/k3" 2>&1)"; { out_has "(here org-runner)" && out_has 'set `runner: org-runner`'; } \
  && ok "an organisation's KM_RUNNER is named where the repository has none" || no "org KM_RUNNER ($out)"
printf '#!/bin/sh\n[ "$*" = "variable get KM_RUNNER -R o/r" ] && echo ubuntu-latest && exit 0\nexit 1\n' > "$GB/gh"
out="$(PATH="$GB:$PATH" km upgrade --root "$T/k4" 2>&1)"; { ! out_has ATTENTION && out_has "if the brain sets it, delete the variable"; } \
  && ok "a KM_RUNNER of ubuntu-latest needs no setting, only its deletion" || no "KM_RUNNER ubuntu-latest ($out)"

# --- the setting itself ---
set_runner "$U" '"$(x)"'; cp -R "$U/$WF" "$T/wf.before"
out="$(km upgrade --root "$U" 2>&1)"; rc=$?
{ [ $rc != 0 ] && out_has "must be one runner label" && diff -r "$T/wf.before" "$U/$WF" >/dev/null; } \
  && ok "a runner setting that is no label stops upgrade before anything is written" || no "bad setting on upgrade ($rc: $out)"
out="$(cd "$U" && km validate 2>&1)"; [ $? != 0 ] && out_has "must be one runner label" && ok "km validate fails on it too" || no "bad setting on validate ($out)"
kmpy -c 'import pathlib, sys, tempfile
from km.runner import setting
d = pathlib.Path(tempfile.mkdtemp())
for text, want in (("runner: my-runner\n", "my-runner"), ("runner: \"my-runner\"  # ours\n", "my-runner"), ("x: 1\n", None),
                   ("meta:\n  runner: a\n", None), ("runner: a b\n", ValueError), ("runner:\n  - a\n", ValueError),
                   ("runner: ${{ vars.X }}\n", ValueError), ("runner: a\nrunner: b\n", ValueError), ("runner:\n", None),
                   ("runner: ~  # unset\n", None), ("runner:foo\n", ValueError),
                   *((f"runner: {v}\n", ValueError) for v in ("true", "On", "no", "123", "1.0", "0x1f", "2026-01-01", "0b101", "1.5e-3"))):
    (d / "schema.local.yaml").write_text(text)
    try:
        got = setting(d)
    except ValueError:
        got = ValueError
    assert got == want, (text, got)
import yaml                                         # where PyYAML is at hand, the file as YAML reads it must agree
for text in ("\"runner\": a\n", "runner : a\n", "\ufeffrunner: a\n", "{runner: a}\n", "x: 1\nrunner:\n  a\n"):
    (d / "schema.local.yaml").write_text(text, encoding="utf-8")
    try:
        setting(d, yaml.safe_load); raise SystemExit(f"accepted {text!r}")
    except ValueError:
        pass
(d / "schema.local.yaml").write_text("x: 1\nrunner: my-runner  # ours\n")
assert setting(d, yaml.safe_load) == "my-runner"' && ok "the setting reads one label on its top-level line, quoted or with a comment; empty or null is unset; YAML's bools, nulls and numbers and anything else are refused" || no "setting reader"

summary runner-smoke || exit 1
