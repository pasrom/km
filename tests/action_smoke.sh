#!/usr/bin/env bash
# Smoke test for the km action's run_install step (action/install.sh), offline: stand-in interpreters
# for setup-python's, one that starts as on GitHub's runners and one that, as in another runner's tool
# cache, starts only with its lib folder on LD_LIBRARY_PATH. pip is stood in too; km runs for real.
# Run:  bash tests/action_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REAL="$(command -v "$PY")"
want="$(km --version)"

# standin DIR NEEDS_LIB: a setup-python run_install dir DIR with bin/python. With NEEDS_LIB it fails as a
# relocated libpython build does unless DIR/lib is an element of LD_LIBRARY_PATH. Each call logs
# its arguments and LD_LIBRARY_PATH; `-m venv V` copies it to V/bin/python (a venv's python is the
# same binary), `-m pip` only logs, the rest runs the real Python.
standin(){
  mkdir -p "$1/bin" "$1/lib"
  { echo '#!/usr/bin/env bash'
    printf 'echo "${LD_LIBRARY_PATH-<unset>} | $*" >> "%s/calls"\n' "$T"
    [ -z "$2" ] || printf 'case ":${LD_LIBRARY_PATH-}:" in *":%s:"*) ;; *) echo "python: error while loading shared libraries: libpython3.11.so.1.0" >&2; exit 127 ;; esac\n' "$1/lib"
    echo 'if [ "$1 $2 $3" = "-P -m venv" ]; then mkdir -p "$4/bin" && cp "$0" "$4/bin/python"; exit; fi'
    echo '[ "$1 $2 $3" = "-P -m pip" ] && exit 0'
    printf 'exec "%s" "$@"\n' "$REAL"
  } > "$1/bin/python"
  chmod +x "$1/bin/python"
}
# run_install NAME PYTHON [ENV...]: run install.sh as the action does, in a fresh RUNNER_TEMP
run_install(){ local rt="$T/$1"; mkdir -p "$rt"; : > "$T/calls"
  out="$(cd "$rt" && env -u LD_LIBRARY_PATH "${@:3}" RUNNER_TEMP="$rt" GITHUB_PATH="$rt/path" bash "$REPO/action/install.sh" "$2" 2>&1)"; }

# --- the interpreter starts as it is (GitHub's runners): nothing changes ---
standin "$T/hosted" ""
if run_install hosted "$T/hosted/bin/python"; then ok "a working interpreter installs km"; else no "working interpreter ($out)"; fi
! grep -q LD_LIBRARY_PATH "$T/hosted/km-bin/km" && ! grep -qv '^<unset> ' "$T/calls" \
  && ok "and neither the install nor the km command sets LD_LIBRARY_PATH" || no "LD_LIBRARY_PATH set for a working interpreter: $(cat "$T/calls" "$T/hosted/km-bin/km")"
[ "$(cat "$T/hosted/path")" = "$T/hosted/km-bin" ] && ok "km-bin goes on GITHUB_PATH" || no "GITHUB_PATH: $(cat "$T/hosted/path")"
grep -q -- '-P -m pip install --quiet --disable-pip-version-check pyyaml==6.0.3' "$T/calls" \
  && ok "PyYAML is installed at its pinned version" || no "pip call: $(cat "$T/calls")"
v="$(env -u LD_LIBRARY_PATH "$T/hosted/km-bin/km" --version 2>&1)"
[ "$v" = "$want" ] && ok "the km command runs this checkout's km" || no "km --version: $v"

# --- the interpreter needs its lib folder (another runner's tool cache, the reported failure) ---
lib="$T/selfhosted/lib"
standin "$T/selfhosted" 1
"$T/selfhosted/bin/python" -P -c '' 2>/dev/null && no "the stand-in starts without its lib folder: this test tests nothing" \
  || ok "the stand-in fails as a relocated build does (exit 127)"
if run_install selfhosted "$T/selfhosted/bin/python"; then ok "it installs km all the same"; else no "relocated interpreter ($out)"; fi
grep -q " -P -m venv " "$T/calls" && ! grep " -P -m \(venv\|pip\) " "$T/calls" | grep -qv "^$lib | " \
  && ok "venv and pip run with exactly its lib folder on LD_LIBRARY_PATH, no empty element" || no "install's LD_LIBRARY_PATH: $(cat "$T/calls")"
: > "$T/calls"
v="$(cd "$T" && env -u LD_LIBRARY_PATH "$T/selfhosted/km-bin/km" --version 2>&1)"
[ "$v" = "$want" ] && [ "$(cut -d'|' -f1 "$T/calls")" = "$lib " ] \
  && ok "the km command starts it, with LD_LIBRARY_PATH exactly its lib folder" || no "km through the relocated interpreter: $v / $(cat "$T/calls")"
: > "$T/calls"
v="$(cd "$T" && LD_LIBRARY_PATH=/job/lib "$T/selfhosted/km-bin/km" --version 2>&1)"
[ "$v" = "$want" ] && [ "$(cut -d'|' -f1 "$T/calls")" = "$lib:/job/lib " ] \
  && ok "and keeps the job's own LD_LIBRARY_PATH after it" || no "job's LD_LIBRARY_PATH: $(cat "$T/calls")"

# the job already has that lib folder on LD_LIBRARY_PATH (setup-python with update-environment, say):
# the km command must still carry it, for a later step or process without it
run_install selfhosted-env "$T/selfhosted/bin/python" LD_LIBRARY_PATH="$lib" \
  && grep -q "^export LD_LIBRARY_PATH=\"$lib" "$T/selfhosted-env/km-bin/km" \
  && [ "$(cd "$T" && env -u LD_LIBRARY_PATH "$T/selfhosted-env/km-bin/km" --version 2>&1)" = "$want" ] \
  && ok "the job's own LD_LIBRARY_PATH does not decide whether the km command sets it" || no "install with the lib already on LD_LIBRARY_PATH ($out)"

# --- an interpreter that does not start even so, or a relative path: a clear error, no km ---
mkdir -p "$T/dead/bin"; printf '#!/bin/sh\nexit 127\n' > "$T/dead/bin/python"; chmod +x "$T/dead/bin/python"
run_install dead "$T/dead/bin/python" && no "a dead interpreter installed km" \
  || { [[ "$out" == *"does not start, not even with $T/dead/lib on LD_LIBRARY_PATH"* ]] && [ ! -e "$T/dead/km-bin" ] \
    && ok "an interpreter that never starts fails the step with a reason" || no "dead interpreter message: $out"; }
run_install relative bin/python && no "a relative python-path was accepted" \
  || { [[ "$out" == *"not absolute"* ]] && ok "a relative python-path is refused" || no "relative path message: $out"; }

summary action_smoke.sh
