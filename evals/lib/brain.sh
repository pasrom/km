# Sourced by the eval fixtures: a brain made by `km init` from this checkout, in the empty workspace
# the run starts in. tests/lib.sh gives `km` from this checkout and `fake_km_remote`, a local
# repository tagged with this km's version that stands in for the km repository (KM_REPO_URL), since
# km init pins a release by its commit.
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib.sh"
# The session's sandbox has no network and the run's own empty HOME, which also holds uv's cache
# and Python dirs. This step runs before the session, outside the sandbox but with that HOME: it
# installs a uv-managed Python there with the PyYAML pin (pyproject.toml, the same one bin/km
# passes to `uv run --with`), so bin/km finds the requirement met and starts km offline. Best
# effort: without uv or network the run starts without it, and km may not start (evals/README.md).
# It installs only below HOME: a uv Python dir set elsewhere (UV_PYTHON_INSTALL_DIR) is left alone.
offline_km()(
  export UV_NO_CONFIG=1
  local pin py
  pin="$(grep -oE 'pyyaml==[0-9.]+' "$REPO/pyproject.toml")" \
    && command -v uv >/dev/null 2>&1 \
    && case "$(uv python dir 2>/dev/null)/" in */../*) false ;; "$HOME"/*) ;; *) false ;; esac \
    && uv python install 3.12 >/dev/null 2>&1 \
    && py="$(uv python find --managed-python '>=3.11' 2>/dev/null)" \
    && uv pip install --python "$py" --break-system-packages "$pin" >/dev/null 2>&1 \
    || echo "eval fixture: no offline Python for km; km may not start in the sandbox" >&2
)
offline_km
# brain DIR INITIALS: a personal brain in DIR, committed
brain(){
  local remote; remote="$(mktemp -d)/km-remote"; fake_km_remote "$remote"
  KM_REPO_URL="file://$remote" km init "$1" --initials "$2" >/dev/null
  git init -q -b main "$1" && git -C "$1" "${G[@]}" add -A && git -C "$1" "${G[@]}" commit -q -m "chore: initialize knowledge base conventions"
}
# doc DIR PATH TITLE STATUS BODY: a doc with km frontmatter
doc(){
  mkdir -p "$(dirname "$1/$2")"
  printf -- '---\ntitle: %s\ntype: note\nstatus: %s\nauthor: EV\ndate: 2026-01-15\ntags: [eval]\n---\n\n# %s\n\n%s\n' "$3" "$4" "$3" "$5" > "$1/$2"
}
# review_brain DIR: a brain with one doc in review, committed
review_brain(){
  brain "$1" EV
  doc "$1" inbox/thermal-derating.md "Thermal derating curve" review "Above 45 degrees Celsius the charge current is reduced by 2 percent per degree."
  git -C "$1" "${G[@]}" add -A && git -C "$1" "${G[@]}" commit -q -m "docs(inbox): thermal derating"
}
# brain_with_peer DIR: a brain that mounts a peer brain under brains/peer; the peer holds one accepted doc
brain_with_peer(){
  local T; T="$(mktemp -d)"
  brain "$T/peer" PE
  doc "$T/peer" docs/pump-timing.md "Pump timing" accepted "The coolant pump starts 850 ms after the main contactor closes."
  git -C "$T/peer" "${G[@]}" add -A && git -C "$T/peer" "${G[@]}" commit -q -m "docs: pump timing"
  brain "$1" EV
  git -C "$1" "${G[@]}" submodule add -q "$T/peer" brains/peer && git -C "$1" "${G[@]}" commit -q -m "chore(brains): mount peer"
}
