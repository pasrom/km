#!/usr/bin/env bash
# Smoke test for the team brain: `team/km_team.py init` builds a brain, which must come out clean;
# then gen_index / demote_stale / build_served, the workflows, and `km_team.py upgrade`.
# Run:  bash skills/km/tests/team_smoke.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KM="$(dirname "$HERE")"
T="$(mktemp -d)"
F="$(mktemp -d)"                       # scratch for init runs that must be refused
trap 'rm -rf "$T" "$F"' EXIT

pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
G(){ git -C "$T" -c user.name=t -c user.email=t@t "$@"; }
py(){ ( cd "$T" && python3 "scripts/$1" "${@:2}" 2>&1 ); }
doc(){ mkdir -p "$(dirname "$1")"; printf -- '---\ntype: note\ntitle: %s\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [t]\n---\nbody\n' "$2" > "$1"; }
folder_idx(){ mkdir -p "$T/$1"; printf -- '---\ntype: reference\ntitle: "%s"\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [index]\n---\n\n## Documents\n' "$2" > "$T/$1/_index.md"; }

# --- init ---
python3 "$KM/team/km_team.py" init "$T" --name Test-Brain --team "the test team" --initials TT \
  --folder process="Tooling and workflow" --folder projects="Time-bound work, one subfolder per project" >/dev/null
G init -q && G add -A
ph="$(cd "$KM/team" && python3 -c 'import km_team; print("\\|".join(km_team.PLACEHOLDERS))')"
grep -rln "$ph" "$T" --include='*.md' --include='*.yaml' >/dev/null && no "no placeholder left after init" || ok "no placeholder left after init"
grep -q '^| `projects/` | Time-bound work' "$T/CONVENTIONS.md" && ok "folder table rendered" || no "folder table rendered"
grep -q '^team_brain: true' "$T/schema.local.yaml" && ok "schema.local.yaml marks the team brain" || no "schema.local.yaml marks the team brain"
grep -q '^author: <initials> ' "$T/CONVENTIONS.md" && ok "the schema example keeps its <initials> placeholder" || no "the schema example keeps its <initials> placeholder"
KT(){ python3 "$KM/team/km_team.py" init "$1" --name X --team y --initials Z "${@:2}" >/dev/null 2>&1; }
KT "$T" --folder a=b && no "init refuses a repo that already has its files" || ok "init refuses a repo that already has its files"
mkdir -p "$F/r" && echo "# x" > "$F/r/README.md"
KT "$F/r" --folder a=b && no "init refuses to overwrite a host-made README" || ok "init refuses to overwrite a host-made README"
KT "$F/f" --folder ..=b; [ -e "$F/_index.md" ] || [ -e "$F/f/CONVENTIONS.md" ] && no "init rejects a folder name outside the repo" || ok "init rejects a folder name outside the repo"
KT "$F/q" --folder 'a=say "hi"'; [ -e "$F/q/CONVENTIONS.md" ] && no "init rejects a quote in a purpose" || ok "init rejects a quote in a purpose"
python3 "$KM/team/km_team.py" init "$F/y" --name Yes --team on --initials NO --folder on=Off >/dev/null
python3 - "$F/y" <<'PY' && ok "YAML-ish values (NO, on) stay strings" || no "YAML-ish values (NO, on) stay strings"
import sys, yaml, re
r = sys.argv[1]
local = yaml.safe_load(open(f"{r}/schema.local.yaml"))
fm = yaml.safe_load(re.match(r"---\n(.*?)\n---", open(f"{r}/on/_index.md").read(), re.S).group(1))
sys.exit(0 if local["author_default"] == "NO" and fm["author"] == "NO" and fm["tags"][0] == "on" else 1)
PY
out="$(py gen_index.py)"; echo "$out" | grep -q "updated 3" && ok "first gen_index fills root and folder lists" || no "first gen_index fills root and folder lists ($out)"
grep -q '^- \[projects/\](projects/_index.md): Time-bound work' "$T/_index.md" && ok "root map lists folders with their purpose" || no "root map lists folders with their purpose"
G add -A && G commit -q -m init
out="$(py gen_index.py --check)"; rc=$?
[ "$rc" = 0 ] && ok "fresh brain: gen_index --check up to date" || no "fresh brain: gen_index --check up to date ($out)"
out="$(py validate.py)"
echo "$out" | grep -q "ERRORS: 0" && echo "$out" | grep -q "WARNINGS: 0" \
  && ok "fresh brain: validate 0 errors / 0 warnings" || no "fresh brain: validate 0 errors / 0 warnings ($out)"

# --- gen_index: a subfolder index is listed by its parent ---
folder_idx projects/p1 "P1 project"; doc "$T/projects/p1/kickoff.md" "Kickoff"; G add -A
out="$(py gen_index.py --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - projects/_index.md"; } && ok "--check fails when a subfolder index is not listed" || no "--check fails when a subfolder index is not listed ($out)"
py gen_index.py >/dev/null
grep -q '^- \[P1 project\](p1/_index.md)' "$T/projects/_index.md" && ok "parent lists the subfolder index, titled from it" || no "parent lists the subfolder index, titled from it"
grep -q '^- \[Kickoff\](kickoff.md)' "$T/projects/p1/_index.md" && ok "subfolder lists its own doc" || no "subfolder lists its own doc"
G add -A && G commit -q -m p1

# --- generator and validator agree on a nested tree with an index-skipped folder ---
printf 'index_skip_prefixes: [process/generated/]\n' >> "$T/schema.local.yaml"
folder_idx process/tools "Tools"; folder_idx process/tools/ci "CI"; doc "$T/process/tools/ci/runner.md" "Runner"
doc "$T/process/generated/api.md" "API"; G add -A
py gen_index.py >/dev/null; G add -A
out="$(py gen_index.py --check)"; rc=$?; vout="$(py validate.py)"
{ [ "$rc" = 0 ] && echo "$vout" | grep -q "WARNINGS: 0"; } \
  && ok "after gen_index, validate finds nothing to add (nested + index_skip)" || no "generator and validator disagree ($out / $vout)"
G commit -q -m nested

# --- a folder with something to list but no index fails in both modes ---
folder_idx process/lone/deep "Deep"; G add -A
out="$(py gen_index.py --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "--check fails on a folder with only a subfolder index" || no "--check fails on a folder with only a subfolder index ($out)"
out="$(py gen_index.py)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "write mode fails on it too" || no "write mode fails on it too ($out)"
G rm -rqf --cached process/lone; rm -rf "$T/process/lone"; G checkout -q -- .
mkdir -p "$T/process/misc"; printf '# readme\n' > "$T/process/misc/README.md"; G add -A
out="$(py gen_index.py --check)"; echo "$out" | grep -q "process/misc" && no "a folder with only a README is not reported" || ok "a folder with only a README is not reported"
G rm -rq --cached process/misc; rm -rf "$T/process/misc"

# --- the root map is optional ---
G rm -q --cached _index.md; mv "$T/_index.md" "$T/root.bak"
out="$(py gen_index.py --check)"; rc=$?
[ "$rc" = 0 ] && ok "no root _index.md: top-level indexes need no parent" || no "no root _index.md: top-level indexes need no parent ($out)"
mv "$T/root.bak" "$T/_index.md"; G add _index.md

# --- demote_stale ---
printf -- '---\ntype: concept\ntitle: Old\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\nold\n' > "$T/process/old.md"
printf -- '---\ntype: concept\ntitle: Cust\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: customer\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2099-01-01\n---\ncustomer <!-- internal note -->\n' > "$T/process/cust.md"
G add -A
py demote_stale.py >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "demote_stale dry-run exits 1 when something is overdue" || no "demote_stale dry-run exits 1 (rc=$rc)"
grep -q '^status: accepted' "$T/process/old.md" && ok "dry-run leaves the file alone" || no "dry-run leaves the file alone"
py demote_stale.py --apply >/dev/null
{ grep -q '^status: review$' "$T/process/old.md" && ! grep -q '^approved_' "$T/process/old.md"; } \
  && ok "--apply demotes to review and drops the approval" || no "--apply demotes to review and drops the approval"
grep -q '^status: accepted' "$T/process/cust.md" && ok "a doc not yet due stays accepted" || no "a doc not yet due stays accepted"
printf -- '---\ntype: concept\ntitle: Odd\ntimestamp: 2025-01-15\nauthor: TT\nstatus: "accepted" # ok\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\n---\nx\n' > "$T/process/odd.md"
G add -A; py demote_stale.py --apply >/dev/null
grep -q '^status: review$' "$T/process/odd.md" && ok "a status line with a trailing comment is demoted" || no "a status line with a trailing comment is demoted"
printf -- '---\n{type: concept, title: Flow, timestamp: 2025-01-15, author: TT, status: accepted, review_by: 2025-06-01, tags: [t]}\n---\nx\n' > "$T/process/flow.md"
G add -A; out="$(py demote_stale.py --apply)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/flow.md" && ! echo "$out" | grep -q "demoted"; } \
  && ok "a status it cannot rewrite fails loudly, never reported as demoted" || no "unrewritable status reported wrongly (rc=$rc: $out)"
G rm -qf --cached process/flow.md; rm -f "$T/process/flow.md"

# --- a tracked file deleted on disk (deletion not staged yet) does not crash the scripts ---
doc "$T/process/gone.md" "Gone"; G add -A; py gen_index.py >/dev/null; G add -A; G commit -q -m gone >/dev/null; rm "$T/process/gone.md"
out="$(py gen_index.py)"; rc=$?
{ [ "$rc" = 0 ] && ! echo "$out" | grep -q Traceback && ! grep -q "gone.md" "$T/process/_index.md"; } \
  && ok "a deleted tracked doc drops out of the list, no crash" || no "a deleted tracked doc crashes gen_index ($out)"
out="$(py build_served.py)"; echo "$out" | grep -q Traceback && no "build_served survives a deleted tracked doc" || ok "build_served survives a deleted tracked doc"
G add -A; G commit -q -m gone2 >/dev/null

# --- build_served ---
py build_served.py >/dev/null
m="$T/dist/served/manifest.json"
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "served bundle: only accepted docs, customer subset" || no "served bundle counts ($(cat "$m" 2>/dev/null))"
grep -q "internal note" "$T/dist/served/customer.jsonl" && no "HTML comments never ship" || ok "HTML comments never ship"
( cd "$T" && git check-ignore -q dist/served/manifest.json ) && ok "dist/ is gitignored" || no "dist/ is gitignored"
( cd "$T" && git check-ignore -q scripts/__pycache__/team_common.cpython-311.pyc ) && ok "the scripts' bytecode cache is gitignored" || no "the scripts' bytecode cache is gitignored"

# --- served_status is read from the gate config, as the validator does ---
G add -A && G commit -q -m docs >/dev/null
python3 - "$T/schema.local.yaml" <<'EOF'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["gate"]["served_status"] = "published"
yaml.safe_dump(d, open(p, "w"))
EOF
sed -i.bak 's/^status: accepted$/status: published/' "$T/process/cust.md" && rm -f "$T/process/cust.md.bak"
py build_served.py >/dev/null
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "a custom served_status is honoured by build_served" || no "a custom served_status is honoured ($(cat "$m"))"
G checkout -q -- schema.local.yaml process/cust.md

# --- workflows reference scripts that exist ---
missing=""
for s in $(grep -ho 'scripts/[a-z_]*\.py' "$T"/.github/workflows/*.yml | sort -u); do [ -f "$T/$s" ] || missing="$missing $s"; done
[ -z "$missing" ] && ok "workflows only call shipped scripts" || no "workflows call missing:$missing"
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('$T/.github/workflows/*.yml')]" 2>/dev/null \
  && ok "workflows are valid YAML" || no "workflows are valid YAML"
python3 - "$T/.github/workflows/staleness.yml" <<'PY' && ok "staleness validates after demoting, even after a failed step" || no "staleness validates after demoting"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["demote"]["steps"]
runs = [(s.get("run", ""), s.get("if", "")) for s in steps]
i = next(n for n, (r, _) in enumerate(runs) if "demote_stale.py" in r)
sys.exit(0 if any("validate.py" in r and "cancelled" in c for r, c in runs[i + 1:]) else 1)
PY

# --- upgrade ---
echo "# local edit" >> "$T/scripts/demote_stale.py"; rm "$T/scripts/team_common.py" "$T/.github/workflows/staleness.yml"
out="$(python3 "$KM/team/km_team.py" upgrade "$T" 2>&1)"
{ echo "$out" | grep -q "updated: scripts/demote_stale.py" && ! grep -q "# local edit" "$T/scripts/demote_stale.py"; } \
  && ok "upgrade overwrites an edited team script and says so" || no "upgrade overwrites an edited team script ($out)"
{ echo "$out" | grep -q "added: scripts/team_common.py" && [ -f "$T/scripts/team_common.py" ]; } \
  && ok "upgrade adds a missing team script" || no "upgrade adds a missing team script ($out)"
echo "# local" >> "$T/scripts/validate.py"; out="$(python3 "$KM/team/km_team.py" upgrade "$T" 2>&1)"
echo "$out" | grep -q "updated: scripts/validate.py" && ok "upgrade refreshes the base km-owned files too" || no "upgrade refreshes the base files ($out)"
{ echo "$out" | grep -q "left out: .github/workflows/staleness.yml" && [ ! -f "$T/.github/workflows/staleness.yml" ]; } \
  && ok "a deleted workflow stays deleted" || no "a deleted workflow stays deleted ($out)"
sed -i.bak '/^team_brain:/d' "$T/schema.local.yaml" && rm -f "$T/schema.local.yaml.bak"
( python3 "$KM/team/km_team.py" upgrade "$T" >/dev/null 2>&1 ) && no "upgrade refuses a brain without team_brain" || ok "upgrade refuses a brain without team_brain"

echo "team-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
