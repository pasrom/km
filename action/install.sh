#!/usr/bin/env bash
# The km action's install step (action.yml): `install.sh PYTHON`, PYTHON being setup-python's
# python-path. km is pure Python: it runs from the action's checkout, with only its dependency
# (pyproject's `dependencies`, same exact version) in a venv of its own; no wheel to build on every job.
# Writes the `km` command to $RUNNER_TEMP/km-bin and puts that folder on $GITHUB_PATH.
set -euo pipefail
py="$1"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"
venv="$RUNNER_TEMP/km-venv"

# setup-python's Linux interpreters find libpython through an absolute RPATH into GitHub's tool cache
# (/opt/hostedtoolcache). In any other tool cache, a self-hosted runner's, they start only with their
# lib folder on LD_LIBRARY_PATH, which setup-python exports only with update-environment, off here so
# the job's own python stays as it is. So km gets it alone, and only where the interpreter needs it.
# The probe ignores the job's LD_LIBRARY_PATH: the km command must not depend on it.
lib=
if ! env -u LD_LIBRARY_PATH "$py" -P -c '' 2>/dev/null; then
  # an absolute path, so that lib is too: a relative one would be looked up from the working directory
  case "$py" in /*) ;; *) echo "::error::setup-python's python-path is not absolute: $py" >&2; exit 1 ;; esac
  lib="$(dirname "$(dirname "$py")")/lib"   # python-path is <install dir>/bin/python
  # no empty element: the loader would take it for the working directory, the brain's checkout
  export LD_LIBRARY_PATH="$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  "$py" -P -c '' || { echo "::error::$py does not start, not even with $lib on LD_LIBRARY_PATH (on macOS setup-python needs its tool cache at /Users/runner/hostedtoolcache)" >&2; exit 1; }
fi

# -P and PYTHONSAFEPATH keep the working directory (the brain's checkout) off sys.path, for this
# step and for km and every Python it starts: a `venv/`, `pip/` or `km/` folder or a `yaml.py` in a
# pull request must not stand in for the module it names
"$py" -P -m venv "$venv"
"$venv/bin/python" -P -m pip install --quiet --disable-pip-version-check "pyyaml==6.0.3"
mkdir -p "$RUNNER_TEMP/km-bin"
{
  echo '#!/usr/bin/env bash'
  [ -z "$lib" ] || printf 'export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$lib"
  printf 'PYTHONSAFEPATH=1 PYTHONPATH="%s" exec "%s/bin/python" -P -m km "$@"\n' "$src" "$venv"
} > "$RUNNER_TEMP/km-bin/km"
chmod +x "$RUNNER_TEMP/km-bin/km"
echo "$RUNNER_TEMP/km-bin" >> "$GITHUB_PATH"
