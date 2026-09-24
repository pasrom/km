#!/usr/bin/env bash
# Smoke test for `km init` (team and personal): a fresh brain must come out clean; then gen-index,
# demote, serve, the workflows and pre-commit hook it writes, and `km upgrade`.
# Run:  bash tests/team_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
KM_REF="v$(km --version)"
T="$(mktemp -d)"
F="$(mktemp -d)"                       # scratch for init runs that must be refused
trap 'rm -rf "$T" "$F"' EXIT
fake_km_remote "$F/remote"; export KM_REPO_URL="file://$F/remote"   # km pins releases by their commit
KM_SHA="$(git -C "$F/remote" rev-parse "$KM_REF^{commit}")"; V09_SHA="$(git -C "$F/remote" rev-parse v0.9.0)"
S99="$(printf '9%.0s' {1..40})"; S98="$(printf '8%.0s' {1..40})"           # commits of made-up newer releases
PINW="pasrom/km@$KM_SHA # $KM_REF"; PINH="rev: $KM_SHA  # frozen: $KM_REF"

G(){ git -C "$T" -c user.name=t -c user.email=t@t "$@"; }
kt(){ ( cd "$T" && km "$@" 2>&1 ); }
doc(){ mkdir -p "$(dirname "$1")"; printf -- '---\ntype: note\ntitle: %s\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [t]\n---\nbody\n' "$2" > "$1"; }
folder_idx(){ mkdir -p "$T/$1"; printf -- '---\ntype: reference\ntitle: "%s"\ntimestamp: 2026-01-15\nauthor: TT\nstatus: draft\ntags: [index]\n---\n\n## Documents\n' "$2" > "$T/$1/_index.md"; }

# --- init ---
km init "$T" --team --name Test-Brain --desc "the test team" --initials TT \
  --folder process="Tooling and workflow" --folder projects="Time-bound work, one subfolder per project" >/dev/null
G init -q && G add -A
ph="$(kmpy -c 'import km.init as i; print("\\|".join(i.PLACEHOLDERS))')"
grep -rln "$ph" "$T" --include='*.md' --include='*.yaml' >/dev/null && no "no placeholder left after init" || ok "no placeholder left after init"
grep -q '^| `projects/` | Time-bound work' "$T/CONVENTIONS.md" && ok "folder table rendered" || no "folder table rendered"
[ ! -e "$T/scripts" ] && [ ! -e "$T/schema.base.yaml" ] && ok "no km code is copied into the brain" || no "no km code is copied into the brain"
grep -qx "\* text=auto eol=lf" "$T/.gitattributes" && ok "init writes a .gitattributes: LF on every platform" || no "init writes a .gitattributes: LF on every platform"
{ grep -q "uses: $PINW" "$T/.github/workflows/ci.yml" && grep -q "uses: $PINW" "$T/.github/workflows/staleness.yml" \
  && grep -q "$PINH" "$T/.pre-commit-config.yaml" && [ -f "$T/.github/dependabot.yml" ]; } \
  && ok "workflows and hook pin km $KM_REF by its commit, Dependabot watches them" || no "workflows and hook pin km by commit"
grep -rhoE "uses: [^ ]+@[^ ]+" "$T/.github/workflows" | grep -vE "@[0-9a-f]{40}$" && no "every action is pinned by commit" || ok "every action is pinned by commit"
grep -q "blob/$KM_SHA/src/km/schema.base.yaml" "$T/CONVENTIONS.md" && ok "CONVENTIONS links km's base schema at that commit" || no "CONVENTIONS schema link"
grep -q '^author: <initials> ' "$T/CONVENTIONS.md" && ok "the schema example keeps its <initials> placeholder" || no "the schema example keeps its <initials> placeholder"
KT(){ km init "$1" --team --name X --desc y --initials Z "${@:2}" >/dev/null 2>&1; }
KT "$T" --folder a=b && no "init refuses a repo that already has its files" || ok "init refuses a repo that already has its files"
mkdir -p "$F/r" && echo "# x" > "$F/r/README.md"
KT "$F/r" --folder a=b && no "init refuses to overwrite a host-made README" || ok "init refuses to overwrite a host-made README"
KT "$F/f" --folder ..=b; [ -e "$F/_index.md" ] || [ -e "$F/f/CONVENTIONS.md" ] && no "init rejects a folder name outside the repo" || ok "init rejects a folder name outside the repo"
KT "$F/q" --folder 'a=say "hi"'; [ -e "$F/q/CONVENTIONS.md" ] && no "init rejects a quote in a purpose" || ok "init rejects a quote in a purpose"
km init "$F/y" --team --name Yes --desc on --initials NO --folder on=Off >/dev/null
python3 - "$F/y" <<'PY' && ok "YAML-ish values (NO, on) stay strings" || no "YAML-ish values (NO, on) stay strings"
import sys, yaml, re
r = sys.argv[1]
local = yaml.safe_load(open(f"{r}/schema.local.yaml"))
fm = yaml.safe_load(re.match(r"---\n(.*?)\n---", open(f"{r}/on/_index.md").read(), re.S).group(1))
sys.exit(0 if local["author_default"] == "NO" and fm["author"] == "NO" and fm["tags"][0] == "on" else 1)
PY
out="$(kt gen-index)"; echo "$out" | grep -q "updated 3" && ok "first gen-index fills root and folder lists" || no "first gen-index fills root and folder lists ($out)"
grep -q '^- \[projects/\](projects/_index.md): Time-bound work' "$T/_index.md" && ok "root map lists folders with their purpose" || no "root map lists folders with their purpose"
G add -A && G commit -q -m init
out="$(kt gen-index --check)"; rc=$?
[ "$rc" = 0 ] && ok "fresh brain: gen-index --check up to date" || no "fresh brain: gen-index --check up to date ($out)"
out="$(kt validate)"
echo "$out" | grep -q "ERRORS: 0" && echo "$out" | grep -q "WARNINGS: 0" \
  && ok "fresh brain: validate 0 errors / 0 warnings" || no "fresh brain: validate 0 errors / 0 warnings ($out)"

# --- gen-index: a subfolder index is listed by its parent ---
folder_idx projects/p1 "P1 project"; doc "$T/projects/p1/kickoff.md" "Kickoff"; G add -A
out="$(kt gen-index --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - projects/_index.md"; } && ok "--check fails when a subfolder index is not listed" || no "--check fails when a subfolder index is not listed ($out)"
kt gen-index >/dev/null
grep -q '^- \[P1 project\](p1/_index.md)' "$T/projects/_index.md" && ok "parent lists the subfolder index, titled from it" || no "parent lists the subfolder index, titled from it"
grep -q '^- \[Kickoff\](kickoff.md)' "$T/projects/p1/_index.md" && ok "subfolder lists its own doc" || no "subfolder lists its own doc"
G add -A && G commit -q -m p1

# --- generator and validator agree on a nested tree with an index-skipped folder ---
printf 'index_skip_prefixes: [process/generated/]\n' >> "$T/schema.local.yaml"
folder_idx process/tools "Tools"; folder_idx process/tools/ci "CI"; doc "$T/process/tools/ci/runner.md" "Runner"
doc "$T/process/generated/api.md" "API"; G add -A
kt gen-index >/dev/null; G add -A
out="$(kt gen-index --check)"; rc=$?; vout="$(kt validate)"
{ [ "$rc" = 0 ] && echo "$vout" | grep -q "WARNINGS: 0"; } \
  && ok "after gen-index, validate finds nothing to add (nested + index_skip)" || no "generator and validator disagree ($out / $vout)"
G commit -q -m nested

# --- a folder with something to list but no index fails in both modes ---
folder_idx process/lone/deep "Deep"; G add -A
out="$(kt gen-index --check)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "--check fails on a folder with only a subfolder index" || no "--check fails on a folder with only a subfolder index ($out)"
out="$(kt gen-index)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/lone/"; } && ok "write mode fails on it too" || no "write mode fails on it too ($out)"
G rm -rqf --cached process/lone; rm -rf "$T/process/lone"; G checkout -q -- .
mkdir -p "$T/process/misc"; printf '# readme\n' > "$T/process/misc/README.md"; G add -A
out="$(kt gen-index --check)"; echo "$out" | grep -q "process/misc" && no "a folder with only a README is not reported" || ok "a folder with only a README is not reported"
G rm -rq --cached process/misc; rm -rf "$T/process/misc"

# --- the root map is optional ---
G rm -q --cached _index.md; mv "$T/_index.md" "$T/root.bak"
out="$(kt gen-index --check)"; rc=$?
[ "$rc" = 0 ] && ok "no root _index.md: top-level indexes need no parent" || no "no root _index.md: top-level indexes need no parent ($out)"
mv "$T/root.bak" "$T/_index.md"; G add _index.md

# --- demote ---
printf -- '---\ntype: concept\ntitle: Old\ntimestamp: 2025-01-15\nauthor: TT\nstatus: accepted\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\napproved_by: TT\napproved_at: 2025-01-15\n---\nold\n' > "$T/process/old.md"
printf -- '---\ntype: concept\ntitle: Cust\ntimestamp: 2026-01-15\nauthor: TT\nstatus: accepted\naudience: customer\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2099-01-01\n---\ncustomer <!-- internal note -->\n' > "$T/process/cust.md"
G add -A
kt demote >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "demote dry-run exits 1 when something is overdue" || no "demote dry-run exits 1 (rc=$rc)"
grep -q '^status: accepted' "$T/process/old.md" && ok "dry-run leaves the file alone" || no "dry-run leaves the file alone"
kt demote --apply >/dev/null
{ grep -q '^status: review$' "$T/process/old.md" && ! grep -q '^approved_' "$T/process/old.md"; } \
  && ok "--apply demotes to review and drops the approval" || no "--apply demotes to review and drops the approval"
grep -q '^status: accepted' "$T/process/cust.md" && ok "a doc not yet due stays accepted" || no "a doc not yet due stays accepted"
printf -- '---\ntype: concept\ntitle: Odd\ntimestamp: 2025-01-15\nauthor: TT\nstatus: "accepted" # ok\naudience: internal\nlanguage: en\ntags: [t]\nowner: TT\nreview_by: 2025-06-01\n---\nx\n' > "$T/process/odd.md"
G add -A; kt demote --apply >/dev/null
grep -q '^status: review$' "$T/process/odd.md" && ok "a status line with a trailing comment is demoted" || no "a status line with a trailing comment is demoted"
printf -- '---\n{type: concept, title: Flow, timestamp: 2025-01-15, author: TT, status: accepted, review_by: 2025-06-01, tags: [t]}\n---\nx\n' > "$T/process/flow.md"
G add -A; out="$(kt demote --apply)"; rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -qx "  - process/flow.md" && ! echo "$out" | grep -q "demoted"; } \
  && ok "a status it cannot rewrite fails loudly, never reported as demoted" || no "unrewritable status reported wrongly (rc=$rc: $out)"
G rm -qf --cached process/flow.md; rm -f "$T/process/flow.md"

# --- a tracked file deleted on disk (deletion not staged yet) does not crash the scripts ---
doc "$T/process/gone.md" "Gone"; G add -A; kt gen-index >/dev/null; G add -A; G commit -q -m gone >/dev/null; rm "$T/process/gone.md"
out="$(kt gen-index)"; rc=$?
{ [ "$rc" = 0 ] && ! echo "$out" | grep -q Traceback && ! grep -q "gone.md" "$T/process/_index.md"; } \
  && ok "a deleted tracked doc drops out of the list, no crash" || no "a deleted tracked doc crashes gen-index ($out)"
out="$(kt serve)"; echo "$out" | grep -q Traceback && no "serve survives a deleted tracked doc" || ok "serve survives a deleted tracked doc"
out="$(kt validate)"; echo "$out" | grep -q Traceback && no "validate survives a deleted tracked doc" || ok "validate survives a deleted tracked doc"
G add -A; G commit -q -m gone2 >/dev/null

# --- serve ---
kt serve >/dev/null
m="$T/dist/served/manifest.json"
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "served bundle: only accepted docs, customer subset" || no "served bundle counts ($(cat "$m" 2>/dev/null))"
grep -q "internal note" "$T/dist/served/customer.jsonl" && no "HTML comments never ship" || ok "HTML comments never ship"
( cd "$T" && git check-ignore -q dist/served/manifest.json ) && ok "dist/ is gitignored" || no "dist/ is gitignored"

# --- served_status is read from the gate config, as the validator does ---
G add -A && G commit -q -m docs >/dev/null
python3 - "$T/schema.local.yaml" <<'EOF'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["gate"]["served_status"] = "published"
yaml.safe_dump(d, open(p, "w"))
EOF
sed -i.bak 's/^status: accepted$/status: published/' "$T/process/cust.md" && rm -f "$T/process/cust.md.bak"
kt serve >/dev/null
python3 -c "import json,sys; c=json.load(open('$m'))['counts']; sys.exit(0 if c=={'internal':1,'customer':1} else 1)" \
  && ok "a custom served_status is honoured by serve" || no "a custom served_status is honoured ($(cat "$m"))"
G checkout -q -- schema.local.yaml process/cust.md

# --- workflows ---
grep -q "scripts/" "$T"/.github/workflows/*.yml && no "workflows call km, not copied scripts" || ok "workflows call km, not copied scripts"
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('$T/.github/workflows/*.yml')]" 2>/dev/null \
  && ok "workflows are valid YAML" || no "workflows are valid YAML"
python3 - "$T/.github/workflows/staleness.yml" <<'PY' && ok "staleness validates after demoting, even after a failed step" || no "staleness validates after demoting"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["demote"]["steps"]
runs = [(s.get("run", ""), s.get("if", "")) for s in steps]
i = next(n for n, (r, _) in enumerate(runs) if "km demote" in r)
sys.exit(0 if any("km validate" in r and "cancelled" in c for r, c in runs[i + 1:]) else 1)
PY

# --- personal init ---
P="$F/personal"; km init "$P" --initials PP --folder notes="Loose notes" >/dev/null
git -C "$P" init -q && git -C "$P" add -A
{ grep -q '^| `notes/` | Loose notes |$' "$P/CONVENTIONS.md" && [ -f "$P/inbox/_index.md" ] && grep -q "$PINH" "$P/.pre-commit-config.yaml" \
  && [ ! -e "$P/.github" ] && grep -q "eol=lf" "$P/.gitattributes"; } && ok "personal init: conventions, inbox, pinned hook, .gitattributes, no CI" || no "personal init: conventions, inbox, pinned hook, .gitattributes, no CI"
out="$(km validate --root "$P" 2>&1)"; echo "$out" | grep -q "ERRORS: 0" && ok "personal brain validates clean" || no "personal brain validates clean ($out)"
mkdir -p "$F/p2" && git -C "$F/p2" init -q && echo "# mine" > "$F/p2/CLAUDE.md" && printf '\xef\xbb\xbf*.bin binary\n' > "$F/p2/.gitattributes"
out="$(km init "$F/p2" --initials PP 2>&1)"
{ grep -qx "# mine" "$F/p2/CLAUDE.md" && [ "$(cat "$F/p2/.gitattributes")" = $'\xef\xbb\xbf*.bin binary' ] && out_has "sets no line ending"; } \
  && ok "personal init keeps an existing CLAUDE.md and .gitattributes, and notes a missing line ending" || no "personal init keeps an existing CLAUDE.md and .gitattributes ($out)"
mkdir -p "$F/p3" && git -C "$F/p3" init -q && echo "  * text eol=crlf" > "$F/p3/.gitattributes"
out="$(km init "$F/p3" --initials PP 2>&1)"
{ [ "$(cat "$F/p3/.gitattributes")" = "  * text eol=crlf" ] && ! out_has "gitattributes"; } \
  && ok "a .gitattributes that sets its own line ending: no note (git decides)" || no "own line ending ($out)"

# --- upgrade: a brain from the copy-in days moves to the package ---
O="$F/old"; mkdir -p "$O/scripts" "$O/.github/workflows"
# each copy carries the header km's copies of it had
printf '"""Validate knowledge-base frontmatter against the km schema, a strict OKF v0.1 profile.\n"""\n' > "$O/scripts/validate.py"
printf '"""km promote — safe: gate before placing, never destroy content silently.\n"""\n' > "$O/scripts/km_promote.py"
printf '"""Regenerate the '"'"'## Documents'"'"' list in every folder\n"""\n' > "$O/scripts/gen_index.py"
printf '"""Demote stale served docs: an accepted doc\n"""\n' > "$O/scripts/demote_stale.py"
printf '"""Build the SERVED bundle\n"""\n' > "$O/scripts/build_served.py"
printf '"""Shared helpers for the team-brain scripts\n"""\n' > "$O/scripts/team_common.py"
printf '# schema.base.yaml — CANONICAL frontmatter schema for /km knowledge bases.\n' > "$O/schema.base.yaml"
printf 'meta:\n  profile: "old"\n\n# Marks a team brain: /km upgrade then also refreshes the km-owned team scripts and workflows.\nteam_brain: true\ncheck_index: true\n' > "$O/schema.local.yaml"
cp "$REPO/tests/fixtures/old-brain/ci.yml" "$REPO/tests/fixtures/old-brain/staleness.yml" "$O/.github/workflows/"   # km's last copied-in versions
printf 'jobs:\n  own:\n    steps:\n      - uses: pasrom/km@v0.1.0\n      - run: echo mine\n' > "$O/.github/workflows/own.yml"
cp "$REPO/tests/fixtures/old-brain/pre-commit-config.yaml" "$O/.pre-commit-config.yaml"
out="$(km upgrade --root "$O" 2>&1)"
{ [ ! -e "$O/scripts" ] && [ ! -e "$O/schema.base.yaml" ]; } && ok "upgrade removes the copied km files" || no "upgrade removes the copied km files ($out)"
{ grep -q "uses: $PINW" "$O/.github/workflows/ci.yml" && grep -q "km demote --apply" "$O/.github/workflows/staleness.yml" && [ -f "$O/.github/dependabot.yml" ]; } \
  && ok "upgrade rewrites the km workflows and adds Dependabot" || no "upgrade rewrites the km workflows ($out)"
{ grep -q "$PINW" "$O/.github/workflows/own.yml" && grep -q "echo mine" "$O/.github/workflows/own.yml"; } \
  && ok "a workflow of the brain's own only gets its pin moved" || no "own workflow pin ($out)"
{ grep -q "$PINH" "$O/.pre-commit-config.yaml" && ! grep -q "scripts/" "$O/.pre-commit-config.yaml"; } \
  && ok "upgrade rewrites the local hook to the pasrom/km hook" || no "upgrade rewrites the hook ($out)"
{ ! grep -q "team_brain" "$O/schema.local.yaml" && grep -q "check_index: true" "$O/schema.local.yaml"; } \
  && ok "upgrade drops only the old team_brain marker" || no "upgrade drops the marker ($(cat "$O/schema.local.yaml"))"
{ grep -q "eol=lf" "$O/.gitattributes" && out_has "added .gitattributes"; } \
  && ok "upgrade adds a .gitattributes to a brain without one" || no "upgrade adds .gitattributes ($out)"
out="$(km upgrade --root "$O" 2>&1)"; echo "$out" | grep -q "already on km $KM_REF" && ok "a second upgrade changes nothing" || no "a second upgrade changes nothing ($out)"
repin "$KM_SHA" "$KM_REF" "$V09_SHA" v0.9.0 "$O/.github/workflows/ci.yml" "$O/.pre-commit-config.yaml"
out="$(km upgrade --root "$O" 2>&1)"
{ grep -q "$PINW" "$O/.github/workflows/ci.yml" && grep -q "$PINH" "$O/.pre-commit-config.yaml"; } \
  && ok "upgrade moves older pins to this km" || no "upgrade moves older pins ($out)"

# --- upgrade is careful with what is not km's ---
N="$F/notkm"; mkdir -p "$N/scripts"; echo "print('mine')" > "$N/scripts/validate.py"
( km upgrade --root "$N" >/dev/null 2>&1 ) && no "upgrade refuses a repo that is not a km brain" || ok "upgrade refuses a repo that is not a km brain"
[ -f "$N/scripts/validate.py" ] && ok "...and deletes nothing there" || no "...and deletes nothing there"
M="$F/mixed"; mkdir -p "$M/scripts" "$M/.github/workflows"; echo "# conv" > "$M/CONVENTIONS.md"
echo "print('mine')" > "$M/scripts/validate.py"
printf '"""Regenerate the '"'"'## Documents'"'"' list in every folder\n"""\n' > "$M/scripts/gen_index.py"
printf '"""Build the SERVED bundle\n"""\n' > "$M/scripts/build_served.py"
printf 'type_rules: {}\nteam_brain: true\n' > "$M/schema.local.yaml"
git -C "$M" init -q; echo "*.md text" > "$M/.gitattributes"
printf 'jobs:\n  own:\n    steps:\n      - run: python scripts/own.py\n' > "$M/.github/workflows/ci.yml"
printf 'jobs:\n  lint:\n    steps:\n      - run: python3 scripts/gen_index.py --check\n' > "$M/.github/workflows/lint.yml"
printf 'repos:\n  - repo: local\n    hooks:\n      - id: km-validate\n        entry: uv run scripts/validate.py\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v4.0.0\n    hooks:\n      - id: trailing-whitespace\n' > "$M/.pre-commit-config.yaml"
out="$(km upgrade --root "$M" 2>&1)"
{ [ -f "$M/scripts/validate.py" ] && [ ! -e "$M/scripts/build_served.py" ] && echo "$out" | grep -q "left scripts/validate.py: not km's copy"; } \
  && ok "upgrade deletes only km's own copies" || no "upgrade deletes only km's own copies ($out)"
grep -q "python scripts/own.py" "$M/.github/workflows/ci.yml" && ok "a brain's own ci.yml is not replaced" || no "a brain's own ci.yml is not replaced"
{ [ -f "$M/scripts/gen_index.py" ] && echo "$out" | grep -q "kept scripts/gen_index.py: .github/workflows/lint.yml still runs it"; } \
  && ok "a km copy a remaining workflow still runs is kept and reported" || no "script still run is kept ($out)"
{ [ "$(cat "$M/.gitattributes")" = "*.md text" ] && out_has "kept .gitattributes, which sets no line ending"; } \
  && ok "upgrade keeps a brain's own .gitattributes and notes a missing line ending" || no "upgrade and a brain's own .gitattributes ($out)"
[ -f "$M/.github/dependabot.yml" ] && ok "a team brain (team_brain marker) gets Dependabot even with its own workflows" || no "team brain via marker gets Dependabot ($out)"
{ grep -q "trailing-whitespace" "$M/.pre-commit-config.yaml" && echo "$out" | grep -q "differs from km's old hook"; } \
  && ok "a pre-commit config with other hooks is left for a hand edit" || no "pre-commit with other hooks ($out)"
C="$F/changed"; mkdir -p "$C/.github/workflows"; echo "# conv" > "$C/CONVENTIONS.md"
{ cat "$REPO/tests/fixtures/old-brain/staleness.yml"; printf '      - run: echo added-by-the-brain\n'; } > "$C/.github/workflows/staleness.yml"
printf '"""Demote stale served docs\n"""\n' > "$C/demote.tmp"; mkdir -p "$C/scripts"; mv "$C/demote.tmp" "$C/scripts/demote_stale.py"
out="$(km upgrade --root "$C" 2>&1)"
{ grep -q "added-by-the-brain" "$C/.github/workflows/staleness.yml" && [ -f "$C/scripts/demote_stale.py" ] \
  && echo "$out" | grep -q "kept scripts/demote_stale.py: .github/workflows/staleness.yml still runs it"; } \
  && ok "a km workflow the brain changed is reported, not overwritten" || no "changed km workflow ($out)"

# --- a legacy schema.yaml acts as the overlay until upgrade renames it ---
L="$F/legacy"; mkdir -p "$L/notes"; git -C "$L" init -q; echo "# conv" > "$L/CONVENTIONS.md"
printf 'fields:\n  mood:\n    required: true\n' > "$L/schema.yaml"
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-01-01\nauthor: X\nstatus: draft\ntags: [t]\n---\nx\n' > "$L/notes/a.md"; git -C "$L" add -A
out="$(km validate --root "$L" 2>&1)"
{ echo "$out" | grep -q "read as the local overlay" && echo "$out" | grep -q "required field 'mood' absent"; } \
  && ok "a legacy schema.yaml is read as the overlay" || no "legacy schema.yaml overlay ($out)"
km upgrade --root "$L" >/dev/null 2>&1
{ [ -f "$L/schema.local.yaml" ] && [ ! -e "$L/schema.yaml" ]; } && ok "upgrade renames it to schema.local.yaml" || no "upgrade renames schema.yaml"

# --- --root in every form ---
B="$F/badbrain"; mkdir -p "$B"; git -C "$B" init -q; printf -- '---\ntitle: x\n---\nx\n' > "$B/x.md"; git -C "$B" add -A
out="$(cd "$B" && km validate --root="$T" 2>&1)"; echo "$out" | grep -q "ERRORS: 0" && ok "--root=DIR validates that brain, not the cwd" || no "--root=DIR ($out)"
out="$(cd "$T" && km --root "$B" validate 2>&1)"; echo "$out" | grep -q "x.md - required field 'type' absent" && ok "km --root DIR <cmd> works before the command" || no "--root before the command ($out)"
( km validate --root "$F/nope" >/dev/null 2>&1 ) && no "a missing --root directory is an error" || ok "a missing --root directory is an error"

# --- pins: a brain pinning another km runs that one; a newer pin is not moved back ---
printf '#!/usr/bin/env bash\necho "$@" > "%s/runner-args"\n' "$F" > "$F/fake-uvx"; chmod +x "$F/fake-uvx"
repin "$KM_SHA" "$KM_REF" "$S99" v99.0.0 "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml"
KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" >/dev/null 2>&1
grep -q -- "--from git+$KM_REPO_URL@$S99 km validate" "$F/runner-args" 2>/dev/null \
  && ok "a brain command runs the km version the brain pins" || no "pinned run ($(cat "$F/runner-args" 2>/dev/null))"
rm -f "$F/runner-args"; KM_LOCAL=1 KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" >/dev/null 2>&1
[ ! -e "$F/runner-args" ] && ok "KM_LOCAL=1 keeps this km" || no "KM_LOCAL=1 keeps this km"
out="$(KM_PINNED_RUNNER=no-such-runner km validate --root "$O" 2>&1)"; echo "$out" | grep -q "running this km since no-such-runner is not installed" \
  && ok "without uv it runs this km and says so" || no "no-uv fallback ($out)"
repin "$S99" v99.0.0 "$KM_SHA" "$KM_REF" "$O/.pre-commit-config.yaml"
rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"
{ echo "$out" | grep -q "the pre-commit hook pins km $KM_REF (${KM_SHA:0:7}), CI pins v99.0.0 (9999999)" && grep -q "@$S99 km validate" "$F/runner-args" 2>/dev/null; } \
  && ok "a hook pinned apart from CI gets a note; CI's version runs" || no "hook vs CI pin ($out)"
printf '#!/usr/bin/env bash\nexit 3\n' > "$F/broken-uvx"; chmod +x "$F/broken-uvx"
out="$(KM_PINNED_RUNNER="$F/broken-uvx" km validate --root "$O" 2>&1)"; echo "$out" | grep -q "could not be fetched" \
  && ok "a pinned km that cannot be fetched falls back to this km" || no "fetch failure fallback ($out)"
repin "$S99" v99.0.0 "$S98" v98.0.0 "$O/.github/workflows/own.yml"
out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"; echo "$out" | grep -q "the workflows pin different km versions" \
  && ok "workflows that disagree: this km runs, with a warning" || no "disagreeing workflows ($out)"
out="$(km upgrade --root "$O" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && grep -q "pasrom/km@$S99 # v99.0.0" "$O/.github/workflows/ci.yml"; } && ok "upgrade refuses to move a newer pin back" || no "upgrade refuses a downgrade (rc=$rc: $out)"
km upgrade --root "$O" --force >/dev/null 2>&1; grep -q "$PINW" "$O/.github/workflows/ci.yml" && ok "upgrade --force moves it anyway" || no "upgrade --force"
sed -i.bak "s|$KM_SHA # $KM_REF|v99.0.0|; s|$KM_SHA  # frozen: $KM_REF|v99.0.0|" "$O"/.github/workflows/*.yml "$O/.pre-commit-config.yaml" && rm -f "$O"/.github/workflows/*.bak "$O"/.*.bak
git -C "$O" init -q; rm -f "$F/runner-args"; out="$(KM_PINNED_RUNNER="$F/fake-uvx" km validate --root "$O" 2>&1)"
{ echo "$out" | grep -q "v99.0.0 is a movable tag, not a commit" && [ ! -e "$F/runner-args" ] \
  && echo "$out" | grep -q "runs pasrom/km@v99.0.0, a ref that can be moved"; } \
  && ok "a pin to a movable tag is never fetched, warned about, and a km validate warning (so CI shows it)" || no "movable tag pin ($out)"
km upgrade --root "$O" --force >/dev/null 2>&1
{ grep -q "$PINW" "$O/.github/workflows/ci.yml" && grep -q "$PINH" "$O/.pre-commit-config.yaml" && ! grep -q "km@v99" "$O"/.github/workflows/*.yml; } \
  && ok "upgrade turns tag pins into commit pins" || no "upgrade turns tag pins into commit pins"

sed -i.bak "s|rev: $KM_SHA  # frozen: $KM_REF|rev: $KM_REF|" "$T/.pre-commit-config.yaml" && rm -f "$T/.pre-commit-config.yaml.bak"
out="$(km validate --root "$T" 2>&1)"; echo "$out" | grep -q "the pre-commit hook pins km tag $KM_REF, CI pins $KM_REF (${KM_SHA:0:7})" \
  && ok "a tag pin and a commit pin of the same version are told apart" || no "pin labels ($out)"
G checkout -q -- .pre-commit-config.yaml
out="$(KM_REPO_URL="file://$F/no-such-repo" km upgrade --root "$T" 2>&1)"; echo "$out" | grep -q "already on km $KM_REF" \
  && ok "upgrade of a current brain needs no lookup (works offline)" || no "offline upgrade of a current brain ($out)"

# --- the km hook is found however its entry is written; other repos stay untouched ---
H="$F/hooks"; mkdir -p "$H"; git -C "$H" init -q; echo "# conv" > "$H/CONVENTIONS.md"
cat > "$H/.pre-commit-config.yaml" <<'YML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v0.9.0
    hooks:
      - id: trailing-whitespace
  - rev: 'v0.9.0'
    # km, written unusually: rev first, quoted, a comment line, a .git URL
    repo: "https://github.com/pasrom/km.git"
    hooks:
      - id: km-validate
YML
out="$(km validate --root "$H" 2>&1)"; echo "$out" | grep -q "runs the km hook at v0.9.0" \
  && ok "a km hook pinned to a tag is found in an unusual entry and warned about" || no "unusual hook entry ($out)"
km upgrade --root "$H" >/dev/null 2>&1
{ grep -q "rev: $KM_SHA  # frozen: $KM_REF" "$H/.pre-commit-config.yaml" && grep -q "pasrom/km.git" "$H/.pre-commit-config.yaml" \
  && [ "$(grep -c "rev: v0.9.0" "$H/.pre-commit-config.yaml")" = 1 ]; } \
  && ok "upgrade pins that km entry by commit and leaves the other repo's rev alone" || no "hook entry re-pin ($(cat "$H/.pre-commit-config.yaml"))"

# --- actions from a movable ref are reported, km's or not ---
A="$F/actions"; mkdir -p "$A/.github/workflows"; git -C "$A" init -q; echo "# conv" > "$A/CONVENTIONS.md"
printf 'jobs:\n  j:\n    steps:\n      - uses: actions/checkout@v4\n      - uses: ./local-action\n' > "$A/.github/workflows/own.yml"
out="$(km validate --root "$A" 2>&1)"
{ echo "$out" | grep -q "runs actions/checkout@v4" && ! echo "$out" | grep -q "local-action"; } \
  && ok "validate warns about a third-party action pinned to a tag" || no "third-party tag action warning ($out)"
km upgrade --root "$A" 2>&1 | grep -q "runs actions/checkout@v4 from a movable ref" && ok "upgrade lists it too" || no "upgrade lists a tag action"

# --- a commit that is not the release its comment names is re-pinned ---
repin "$KM_SHA" "$KM_REF" "$V09_SHA" "$KM_REF" "$T/.github/workflows/ci.yml"
out="$(km upgrade --root "$T" 2>&1)"
{ echo "$out" | grep -q "points at ${V09_SHA:0:12}, not its release commit" && grep -q "$PINW" "$T/.github/workflows/ci.yml"; } \
  && ok "upgrade catches a commit that does not match its version comment" || no "stray commit ($out)"
G checkout -q -- .github 2>/dev/null; G status --short | grep -q .github && G add -A >/dev/null

# --- a failed lookup changes nothing ---
X="$F/nolookup"; mkdir -p "$X/scripts"; echo "# conv" > "$X/CONVENTIONS.md"
printf '"""km promote — safe: gate before placing\n"""\n' > "$X/scripts/km_promote.py"
cp "$REPO/tests/fixtures/old-brain/pre-commit-config.yaml" "$X/.pre-commit-config.yaml"
( KM_REPO_URL="file://$F/no-such-repo" km upgrade --root "$X" >/dev/null 2>&1 ) && no "upgrade fails when the release cannot be looked up" || ok "upgrade fails when the release cannot be looked up"
{ [ -f "$X/scripts/km_promote.py" ] && grep -q "scripts/validate.py" "$X/.pre-commit-config.yaml"; } \
  && ok "...before changing anything" || no "...before changing anything"

# --- a release must exist to be pinned ---
git init -q "$F/norelease"
( KM_REPO_URL="file://$F/norelease" km init "$F/nr" --initials NR >/dev/null 2>&1 ) && no "init refuses a km version with no release commit" || ok "init refuses a km version with no release commit"
[ ! -e "$F/nr/CONVENTIONS.md" ] && ok "...and writes nothing" || no "...and writes nothing"
km init "$F/p09" --initials PP --pin v0.9.0 >/dev/null && grep -q "rev: $V09_SHA  # frozen: v0.9.0" "$F/p09/.pre-commit-config.yaml" \
  && ok "init --pin pins another released version" || no "init --pin v0.9.0"
out="$(km validate --root "$T" 2>&1)"; echo "$out" | grep -q "^km: " && no "no pin note when the pins match" || ok "no pin note when the pins match"

# --- the action commits brains get are the ones km's own workflows use, which Dependabot keeps current ---
python3 - "$REPO" <<'PY' && ok "template actions pin the same commits as km's own workflows" || no "template action commits drift from km's workflows"
import re, sys, glob
repo = sys.argv[1]
def pins(paths):
    out = {}
    for f in paths:
        for name, sha in re.findall(r"uses: ([\w.\-]+/[\w.\-]+)@([0-9a-f]{40})", open(f).read()):
            out.setdefault(name, set()).add(sha)
    return out
own = pins([f"{repo}/action.yml", *glob.glob(f"{repo}/.github/workflows/*.yml")])
tpl = pins(glob.glob(f"{repo}/src/km/templates/team/*.yml"))
sys.exit(0 if all(name in own and shas == own[name] for name, shas in tpl.items()) else 1)
PY

# --- non-ASCII file names on a system whose encoding is not UTF-8 (Windows, cp1252) ---
tested=
for e in "LC_ALL=C PYTHONCOERCECLOCALE=0" "LC_ALL=en_US.ISO8859-1"; do
  windows_like "$e" || continue; tested=1
  out="$(with_env "$e" bash "$REPO/tests/encoding_smoke.sh" 2>&1)" && ok "[$e] encoding_smoke.sh" || no "[$e] encoding_smoke.sh:
$out"
done
[ -n "$tested" ] || echo "  skip: no Windows-like encoding here (Linux); the windows CI job runs encoding_smoke.sh"

# On Linux a non-UTF-8 locale changes the file-name encoding too: each name git lists must still
# open its file (the smoke CI job generates this locale)
L="$F/latin1"; mkdir -p "$L/notes"; git -C "$L" init -q; echo "# conv" > "$L/CONVENTIONS.md"
printf -- '---\ntitle: "no type"\n---\nx\n' > "$L/notes/künstler.md"; git -C "$L" add -A
e="LC_ALL=en_US.ISO-8859-1"
if with_env "$e" "$PY" -c 'import sys; sys.exit(sys.getfilesystemencoding() == "utf-8")' 2>/dev/null; then
  out="$(with_env "$e" km validate --root "$L" 2>&1)"
  { ! out_has Traceback && out_has "required field 'type' absent"; } \
    && ok "[$e] a non-ASCII name is validated where file names are not UTF-8" || no "[$e] non-UTF-8 file names ($out)"
else echo "  skip: no locale here whose file names are not UTF-8 (the smoke CI job has one)"; fi

# git's messages follow the locale: a Latin-1 one outside a repo must give km's error, not a traceback
N="$F/norepo"; mkdir -p "$N"
if [ -n "$(cd "$N" && LC_ALL=fr_FR.ISO8859-1 git rev-parse 2>&1 | LC_ALL=C tr -d '\0-\177')" ]; then
  out="$(with_env LC_ALL=fr_FR.ISO8859-1 km validate --root "$N" 2>&1)"
  { ! out_has Traceback && out_has "git ls-files failed"; } \
    && ok "a git error in a Latin-1 locale is reported, not a crash" || no "git error in a Latin-1 locale ($out)"
else echo "  skip: git prints no non-ASCII error in a Latin-1 locale here"; fi

# --- km's dependencies are pinned to the same exact versions everywhere ---
v="$(grep -oE 'pyyaml==[0-9.]+' "$REPO/pyproject.toml")"
{ [ -n "$v" ] && grep -q "$v" "$REPO/action.yml" && grep -q "$v" "$REPO/skills/km/bin/km" && grep -q '"setuptools==' "$REPO/pyproject.toml"; } \
  && ok "PyYAML and setuptools are pinned exactly, the same in pyproject, action and launcher" || no "dependency pins"

# --- one version everywhere ---
python3 - "$REPO" "$KM_REF" <<'PY' && ok "plugin.json and the README name this km version" || no "plugin.json and the README name this km version"
import json, re, sys
repo, ref = sys.argv[1], sys.argv[2]
lines = [ln for ln in open(f"{repo}/README.md") if "pasrom/km" in ln or "frozen:" in ln]
readme = {v for ln in lines for v in re.findall(r"\bv\d+\.\d+\.\d+\b", ln)}
sys.exit(0 if "v" + json.load(open(f"{repo}/.claude-plugin/plugin.json"))["version"] == ref and readme == {ref} else 1)
PY

summary team-smoke || exit 1
