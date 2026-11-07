#!/usr/bin/env bash
# PreToolUse hook of the km plugin for Edit, Write, MultiEdit and NotebookEdit: a mounted brain (a
# brain checked out as a git submodule of a brain) is a read-only, pinned mirror, so an edit in it
# is refused (exit 2; the reason on stderr reaches Claude). The mount is found through git, not a
# path pattern: the file's directory lies in a submodule, and both that submodule and its
# superproject are brains (CONVENTIONS.md plus a schema file, as hooks/session-start.sh checks).
# Everything else exits 0 at once: no path in the input, no git, a directory in no repository, a
# repository that is no submodule, a submodule or superproject that is no brain. It runs on every
# edit, so it is bash builtins plus one git call (a second one next to an empty mount); no jq,
# so it also runs in Git Bash on Windows,
# where the path arrives as C:\\Users\\... and git takes C:/Users/....
set -u
input="$(cat 2>/dev/null)" || exit 0
# The first "file_path" or "notebook_path" key: the tool's own, since a mention inside the content a
# Write carries has its quotes escaped (\"file_path\") and does not match.
re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $re ]] || exit 0
file="${BASH_REMATCH[2]}"
case "$file" in *\\*)
  file="$(printf '%s' "$file" | sed 's/\\\(.\)/\1/g')"                # JSON escapes undone: \\ -> \, \/ -> /
  case "$file" in [A-Za-z]:\\*) file="${file//\\//}" ;; esac         # C:\a\b -> C:/a/b, which git reads
esac
case "$file" in */*) dir="${file%/*}" ;; *) dir=. ;; esac
[ -n "$dir" ] || dir=/
while [ ! -d "$dir" ]; do                                          # a new file in a new folder: climb to one that exists
  case "$dir" in */*) dir="${dir%/*}"; [ -n "$dir" ] || dir=/ ;; *) exit 0 ;; esac
done
# one git call: the repository's top, the folder's path inside it (empty at the top), and the
# superproject's working tree (no line when the repository is no submodule)
{ read -r top; read -r prefix; read -r super; } < <(git -C "$dir" rev-parse --show-toplevel --show-prefix --show-superproject-working-tree 2>/dev/null)
[ -n "${top:-}" ] || exit 0
is_brain(){ [ -f "$1/CONVENTIONS.md" ] && { [ -f "$1/schema.local.yaml" ] || [ -f "$1/schema.yaml" ]; }; }
if [ -z "${super:-}" ]; then
  # no submodule around the file; but the deepest existing folder may be a mount that is not checked
  # out yet (an empty gitlink), where a file would land under the pin and block the checkout
  rel="${prefix%/}"
  [ -n "$rel" ] && is_brain "$top" || exit 0
  gitlink=; while IFS=$'\t' read -r meta path; do [ "$path" = "$rel" ] && [ "${meta%% *}" = 160000 ] && gitlink=1; done \
    < <(git -C "$top" ls-files --stage -- "$rel" 2>/dev/null)                 # the pathspec is a prefix: match the entry itself
  [ -n "$gitlink" ] || exit 0
  echo "km: $dir is a mounted brain that is not checked out yet (an empty mount): a file written here blocks the checkout at its pin. Run km sync (or git submodule update --init) first, and fix the brain through a pull request against its own repository (/km brain fix @${rel##*/}), never in the mount." >&2
  exit 2
fi
is_brain "$top" && is_brain "$super" || exit 0
name="${top##*/}"
echo "km: $file lies in the mounted brain $top, a read-only, pinned mirror of another repository: an edit here drifts the mount and is never published. Fix it through a pull request against that brain instead: /km brain fix @$name (a correction) or /km contribute @$name (a new or updated doc), both in a throwaway clone. A mount that already drifted goes back with /km brain reset $name." >&2
exit 2
