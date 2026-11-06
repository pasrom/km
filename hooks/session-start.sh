#!/usr/bin/env bash
# SessionStart hook of the km plugin: when the session's working directory lies in a brain, bring
# that copy up to the upstream brain (`km sync --quiet --max-age 15m`): a clean default branch is
# fast-forwarded, everything else is only reported. What it prints reaches Claude as context, so it
# prints only what changed or needs attention. It never fails the session: outside a brain, without
# git, uv or Python, without network, or within 15 minutes of the last sync it exits 0 in silence.
set -u
mins=15                                                                  # at most one sync this often
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$root/CONVENTIONS.md" ] || exit 0                                  # not a brain
[ -f "$root/schema.local.yaml" ] || [ -f "$root/schema.yaml" ] || exit 0
[ -z "$(git -C "$root" rev-parse --show-superproject-working-tree 2>/dev/null)" ] || exit 0   # a mounted brain: synced from its parent
stamp="$(git -C "$root" rev-parse --git-path km-sync 2>/dev/null)"
case "$stamp" in /*|[A-Za-z]:*) ;; *) stamp="$root/$stamp" ;; esac
# synced recently: nothing to start (km sync --max-age checks the same stamp, but only once uv and Python run)
[ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin "-$mins" 2>/dev/null)" ] && exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$here/../skills/km/bin/km" --root "$root" sync --quiet --no-init --max-age "${mins}m" 2>/dev/null   # --no-init: a clone is not for a session start
exit 0
