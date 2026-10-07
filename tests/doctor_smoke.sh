#!/usr/bin/env bash
# Smoke test for `km doctor`: on a team brain with a local origin, every check must pass, and each
# thing that is missing (git identity, access, a newer km, a plugin, uv on the PATH) must fail with
# a fix, without hanging and in ASCII.
# Run:  bash tests/doctor_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fake_km_remote "$T/kmremote"; export KM_REPO_URL="file://$T/kmremote"
KM_REF="v$(km --version)"; KM_SHA="$(git -C "$T/kmremote" rev-parse "$KM_REF^{commit}")"
S99="$(printf '9%.0s' {1..40})"
# git and Claude Code read only what this test writes
printf '[user]\n\tname = t\n\temail = t@t\n[protocol "file"]\n\tallow = always\n' > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 CLAUDE_CONFIG_DIR="$T/cfg"
mkdir -p "$T/home" && export HOME="$T/home"
B="$T/brain"
km init "$B" --team --name D --desc d --initials DD --folder docs=Docs >/dev/null
git -C "$B" init -q -b main && git -C "$B" add -A && git -C "$B" commit -q -m init
git init -q --bare -b main "$T/origin.git" && git -C "$B" remote add origin "$T/origin.git" && git -C "$B" push -q origin main
doctor(){ out="$(cd "$B" && km doctor "$@" 2>&1)"; rc=$?; }

doctor
{ [ "$rc" = 0 ] && out_has "Everything needed is set up" && out_has "ok    origin" && out_has "has everything origin has" \
  && out_has "ok    km $KM_REF is the version the brain pins"; } && ok "a set-up brain passes" || no "a set-up brain passes ($out)"
LC_ALL=C grep -q '[^ -~]' <<< "$out" && no "the output is ASCII" || ok "the output is ASCII"
out="$(cd "$B" && PYTHONPATH="$REPO/src" "$PY" -c 'import sys, runpy
sys.modules["yaml"] = None                      # PyYAML missing
sys.argv = ["km", "doctor", "--offline"]; runpy.run_module("km", run_name="__main__")' 2>&1)"
out_has "km doctor:" && ! out_has "Traceback" && ok "runs without PyYAML" || no "runs without PyYAML ($out)"

printf '[user]\n\tname = t\n' > "$T/noemail"
out="$(cd "$B" && GIT_CONFIG_GLOBAL="$T/noemail" km doctor 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "FAIL  git does not know your email" && out_has 'git config --global user.email'; } \
  && ok "a missing git email fails with the command that sets it" || no "missing git email ($out)"

echo x > "$B/scratch.md"; doctor
{ [ "$rc" = 0 ] && out_has "note  1 changed or new file"; } && ok "uncommitted changes are a note, not a failure" || no "uncommitted changes ($out)"
rm "$B/scratch.md"

git clone -q "$T/origin.git" "$T/other" && git -C "$T/other" commit -q --allow-empty -m newer && git -C "$T/other" push -q origin main
doctor
{ [ "$rc" = 1 ] && out_has "FAIL  branch main lacks changes that are on origin"; } && ok "a brain behind origin fails" || no "behind origin ($out)"
git -C "$B" commit -q --allow-empty -m local; doctor
fix="$(sed -n 's/.*`\(git pull --rebase origin main\)`.*/\1/p' <<< "$out")"
{ [ "$rc" = 1 ] && [ -n "$fix" ] && ( cd "$B" && $fix -q ) && doctor && [ "$rc" = 0 ]; } \
  && ok "a diverged brain fails with a pull that works" || no "diverged brain ($out)"
doctor --offline
{ [ "$rc" = 0 ] && out_has "skip  origin .* (offline)"; } && ok "--offline skips the origin" || no "--offline ($out)"

git -C "$B" remote set-url origin "file://$T/nope.git"
start=$SECONDS; doctor
{ [ "$rc" = 1 ] && out_has "FAIL  origin: no access to" && out_has "fix: sign in" && [ $((SECONDS-start)) -lt 20 ]; } \
  && ok "an origin that cannot be read fails at once, with a fix" || no "unreadable origin ($out)"
git -C "$B" remote set-url origin "$T/origin.git"
git -C "$B" remote set-url origin "https://someone:s3cret@127.0.0.1:9/brain.git"; doctor
{ [ "$rc" = 1 ] && out_has "FAIL  origin: https://127.0.0.1:9/brain.git cannot be reached" && ! out_has "s3cret"; } \
  && ok "an origin that does not answer is a network problem, its token not shown" || no "token in URL ($out)"
git -C "$B" remote set-url origin "$T/origin.git"

git init -q "$T/peer" && git -C "$T/peer" commit -q --allow-empty -m peer
git -C "$B" submodule add -q "$T/peer" brains/peer >/dev/null 2>&1 && git -C "$B" commit -q -m mount && git -C "$B" push -q origin main
doctor; out_has "ok    mounted brains/peer answers" && ok "a mounted brain that answers passes" || no "mounted brain ($out)"
git -C "$B" submodule deinit -q -f brains/peer; doctor
{ [ "$rc" = 0 ] && out_has "note  mounted brains/peer is not checked out" && out_has "submodule update --init \"brains/peer\""; } \
  && ok "a mounted brain not checked out is a note with the command" || no "mounted brain not checked out ($out)"
git -C "$B" config -f .gitmodules submodule.brains/peer.url "file://$T/gone"; doctor
{ [ "$rc" = 1 ] && out_has "FAIL  mounted brains/peer: no access"; } && ok "a mounted brain that cannot be read fails" || no "unreadable mounted brain ($out)"
git -C "$B" checkout -q .gitmodules
git init -q "$T/my peer" && git -C "$T/my peer" commit -q --allow-empty -m peer
git -C "$B" submodule add -q "$T/my peer" "brains/my peer" >/dev/null 2>&1 && git -C "$B" commit -q -m spaces; doctor
{ out_has "ok    mounted brains/my peer answers" && ! out_has "FAIL  mounted"; } && ok "a mounted brain with a space in its path" || no "space in path ($out)"
git -C "$B" submodule deinit -q -f "brains/my peer"; git -C "$B" config -f .gitmodules "submodule.brains/my peer.url" ../gone.git; doctor
{ [ "$rc" = 1 ] && out_has "FAIL  mounted brains/my peer: no access to .*/gone.git"; } \
  && ok "a relative URL is resolved against origin and checked" || no "relative submodule URL ($out)"
git -C "$B" checkout -q .gitmodules

repin "$KM_SHA" "$KM_REF" "$S99" v99.0.0 "$B"/.github/workflows/*.yml "$B/.pre-commit-config.yaml"; doctor
{ [ "$rc" = 1 ] && out_has "FAIL  km $KM_REF is older than the brain's v99.0.0" && out_has "ask the brain.s maintainer"; } \
  && ok "a km older than the brain's pin fails" || no "older km ($out)"
repin "$S99" v99.0.0 "$(git -C "$T/kmremote" rev-parse v0.9.0)" v0.9.0 "$B"/.github/workflows/*.yml "$B/.pre-commit-config.yaml"; doctor
{ [ "$rc" = 0 ] && out_has "note  km $KM_REF; the brain pins v0.9.0"; } && ok "a km newer than the pin is a note" || no "newer km ($out)"
git -C "$B" checkout -q .

mkdir -p "$B/.claude" "$T/cfg/plugins"
cat > "$B/.claude/settings.json" <<'JSON'
{"extraKnownMarketplaces": {"team": {"source": {"source": "github", "repo": "owner/team-plugins"}}},
 "enabledPlugins": {"km@team": true, "docs@team": true, "off@team": false}}
JSON
cat > "$T/cfg/plugins/installed_plugins.json" <<JSON
{"version": 2, "plugins": {
  "km@team": [{"scope": "user", "installPath": "/x"}],
  "docs@team": [{"scope": "project", "projectPath": "$T/elsewhere", "installPath": "/x"}]}}
JSON
doctor
{ [ "$rc" = 1 ] && out_has "ok    plugin km@team is installed" && out_has "FAIL  plugin docs@team is not installed" \
  && out_has "/plugin marketplace add owner/team-plugins., then ./plugin install docs@team" && ! out_has "off@team"; } \
  && ok "a plugin the brain enables but nobody installed fails, with the marketplace to add" || no "plugins ($out)"
printf '{"team": {}}' > "$T/cfg/plugins/known_marketplaces.json"; doctor
out_has "fix: in Claude Code: ./plugin install docs@team" && ok "a known marketplace is not added again" || no "known marketplace ($out)"
printf '{"enabledPlugins": ["x@team"], "extraKnownMarketplaces": "team"}' > "$B/.claude/settings.json"
printf '{"plugins": ["x"]}' > "$T/cfg/plugins/installed_plugins.json"; doctor
! out_has "Traceback" && ok "odd values in the JSON files are no crash" || no "odd JSON values ($out)"
printf '{"enabledPlugins": {"docs@team": true}, "extraKnownMarketplaces": {"team": {"source": "github"}}}' > "$B/.claude/settings.json"
printf '{"plugins": {"docs@team": [{"scope": "project", "projectPath": "%s"}]}}' "$(cd "$B" && { pwd -W 2>/dev/null || pwd; })" > "$T/cfg/plugins/installed_plugins.json"; doctor
{ ! out_has "Traceback" && out_has "ok    plugin docs@team is installed"; } && ok "a project install in the brain counts" || no "project install ($out)"
printf '{}' > "$T/cfg/plugins/installed_plugins.json"
mkdir -p "$T/cfg/plugins/synced/bucket/docs~g2"; doctor
{ [ "$rc" = 0 ] && out_has "ok    plugin docs@team is installed"; } && ok "a plugin synced by the organization counts" || no "synced plugin ($out)"

if [ "$SEP" = ":" ]; then   # PATH games need a POSIX layout
  mkdir -p "$T/bin" "$T/home/.local/bin" && : > "$T/home/.local/bin/uv"
  ln -s "$(command -v git)" "$T/bin/git" && ln -s "$(command -v "$PY")" "$T/bin/py"
  out="$(cd "$B" && HOME="$T/home" PATH="$T/bin" PYTHONPATH="$REPO/src" "$T/bin/py" -m km doctor --offline 2>&1)"
  out_has "FAIL  uv is installed in .* but that folder is not on the PATH" && ok "uv installed but not on the PATH fails" || no "uv off the PATH ($out)"
  rm "$T/home/.local/bin/uv"
  repin "$KM_SHA" "$KM_REF" "$(git -C "$T/kmremote" rev-parse v0.9.0)" v0.9.0 "$B"/.github/workflows/*.yml "$B/.pre-commit-config.yaml"
  out="$(cd "$B" && PATH="$T/bin" PYTHONPATH="$REPO/src" "$T/bin/py" -m km doctor --offline 2>&1)"
  out_has "the brain pins v0.9.0, which km cannot run without uv" && ok "without uv a differing pin says km cannot run it" || no "pin without uv ($out)"
  git -C "$B" checkout -q .
  out="$(cd "$B" && PATH="$T/bin" PYTHONPATH="$REPO/src" "$T/bin/py" -c 'import sys, runpy
sys.modules["yaml"] = None
sys.argv = ["km", "doctor", "--offline"]; runpy.run_module("km", run_name="__main__")' 2>&1)"
  out_has "FAIL  uv is not installed, and this Python has no PyYAML" && ok "no uv and no PyYAML fails: km cannot run" || no "no uv, no PyYAML ($out)"
  # the launcher: nothing to run km with, then uv only where its installer put it
  mkdir -p "$T/bare" && ln -s "$(command -v dirname)" "$T/bare/dirname"
  out="$(cd "$B" && PATH="$T/bare" "$BASH" "$REPO/skills/km/bin/km" doctor 2>&1)"; rc=$?
  { [ "$rc" = 1 ] && out_has "km cannot start on this computer" && out_has "install.ps1" && out_has "git is missing as well"; } \
    && ok "the launcher says what to install when nothing can run km" || no "launcher without uv or Python ($out)"
  printf '#!/bin/sh\necho "fake uv $*"\n' > "$T/home/.local/bin/uv" && chmod +x "$T/home/.local/bin/uv"
  out="$(cd "$B" && PATH="$T/bare" "$BASH" "$REPO/skills/km/bin/km" doctor 2>&1)"
  out_has "fake uv run .* -m km doctor" && ok "the launcher finds uv off the PATH, before a restart" || no "launcher uv off PATH ($out)"
  rm "$T/home/.local/bin/uv"
  rm "$T/bin/git"
  out="$(cd "$B" && PATH="$T/bin" PYTHONPATH="$REPO/src" "$T/bin/py" -m km doctor 2>&1)"; rc=$?
  { [ "$rc" = 1 ] && out_has "FAIL  git is not installed" && ! out_has "Traceback"; } && ok "without git it says so" || no "no git ($out)"
fi

out="$(cd "$T" && km doctor 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "is not a git repository"; } && ok "outside a git repository it says so" || no "outside a repository ($out)"
summary doctor_smoke
