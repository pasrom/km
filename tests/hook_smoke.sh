#!/usr/bin/env bash
# Smoke test for the plugin's PreToolUse hook (hooks/guard-brain-edit.sh): an edit inside a mounted
# brain is refused with exit 2 and a reason, everything else passes with exit 0, from the JSON Claude
# Code pipes in. And for the pre-push hook a team brain's pre-commit config carries: with pre-commit
# on the PATH a push to main is refused and a push to a branch goes through.
set -u
source "$(dirname "$0")/lib.sh"
HOOK="$REPO/hooks/guard-brain-edit.sh"
F="$(mktemp -d)"; trap 'rm -rf "$F"' EXIT
brain(){ mkdir -p "$1/docs"; printf '# Conventions\n' > "$1/CONVENTIONS.md"; printf 'meta: {profile: t}\n' > "$1/schema.local.yaml"
         printf -- '---\ntitle: a\n---\n' > "$1/docs/a.md"; git init -q -b main "$1" && git -C "$1" "${G[@]}" add -A && git -C "$1" "${G[@]}" commit -q -m init; }
brain "$F/peer-src"; brain "$F/host"
mkdir -p "$F/res-src"; printf 'tool\n' > "$F/res-src/README.md"; git init -q -b main "$F/res-src" && git -C "$F/res-src" "${G[@]}" add -A && git -C "$F/res-src" "${G[@]}" commit -q -m init
git -C "$F/host" "${G[@]}" submodule add -q "$F/peer-src" brains/peer && git -C "$F/host" "${G[@]}" submodule add -q "$F/res-src" tools/res \
  && git -C "$F/host" "${G[@]}" commit -q -m mounts
git "${G[@]}" clone -q "$F/peer-src" "$F/peer-clone"
mkdir -p "$F/proj"; git init -q -b main "$F/proj" && git -C "$F/proj" "${G[@]}" submodule add -q "$F/peer-src" brains/peer2 && git -C "$F/proj" "${G[@]}" commit -q -m mount
mkdir -p "$F/plain"; git init -q -b main "$F/plain"; printf 'x\n' > "$F/plain/f.txt"; mkdir -p "$F/nogit"
HOST="$F/host"; PEER="$F/host/brains/peer"
# guard JSON: runs the hook on that input; sets rc and err
guard(){ err="$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)"; rc=$?; }
tool(){ printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"%s":"%s"%s}}' "$HOST" "$1" "$2" "$3" "${4:-}"; }

guard "$(tool Edit file_path "$PEER/docs/a.md" ',"old_string":"a","new_string":"b"')"
{ [ "$rc" = 2 ] && [[ "$err" == *"brain fix @peer"* ]] && [[ "$err" == *"brain reset peer"* ]]; } \
  && ok "an Edit in a mounted brain is refused with the fix flows named" || no "Edit in a mount (rc $rc: $err)"
guard "$(tool Write file_path "$PEER/new/folder/b.md" ',"content":"x"')"
[ "$rc" = 2 ] && ok "a Write into a folder that does not exist yet in a mount is refused" || no "Write new folder in a mount (rc $rc)"
guard "$(tool NotebookEdit notebook_path "$PEER/n.ipynb" ',"new_source":"x"')"
[ "$rc" = 2 ] && ok "a NotebookEdit in a mount is refused (notebook_path)" || no "NotebookEdit in a mount (rc $rc)"
guard "$(tool MultiEdit file_path "$PEER/docs/a.md" ',"edits":[]')"
[ "$rc" = 2 ] && ok "a MultiEdit in a mount is refused" || no "MultiEdit in a mount (rc $rc)"
guard "$(tool Edit file_path "$HOST/docs/a.md")"
[ "$rc" = 0 ] && [ -z "$err" ] && ok "an edit in the brain itself passes" || no "edit in the host (rc $rc: $err)"
guard "$(tool Edit file_path "$HOST/tools/res/README.md")"
[ "$rc" = 0 ] && ok "an edit in a shared resource (a submodule that is no brain) passes" || no "edit in a shared resource (rc $rc: $err)"
guard "$(tool Edit file_path "$F/peer-clone/docs/a.md")"
[ "$rc" = 0 ] && ok "an edit in a standalone clone of the same brain passes" || no "edit in a clone (rc $rc: $err)"
guard "$(tool Edit file_path "$F/proj/brains/peer2/docs/a.md")"
[ "$rc" = 0 ] && ok "a brain mounted in a repository that is no brain is not km's to guard" || no "edit in a mount of a non-brain (rc $rc: $err)"
git "${G[@]}" clone -q "$F/host" "$F/host2"                    # a fresh clone: the mount is an empty gitlink directory
guard "$(tool Write file_path "$F/host2/brains/peer/docs/new.md" ',"content":"x"')"
{ [ "$rc" = 2 ] && [[ "$err" == *"not checked out yet"* ]]; } && ok "a Write into a mount that is not checked out yet is refused" || no "empty mount (rc $rc: $err)"
guard "$(tool Edit file_path "$F/host2/docs/a.md")"
[ "$rc" = 0 ] && ok "the clone's own doc next to the empty mount passes" || no "clone's own doc (rc $rc: $err)"
guard "$(tool Write file_path "$HOST/brains/README.md" ',"content":"x"')"; r1=$rc
guard "$(tool Write file_path "$HOST/brains/new/x.md" ',"content":"x"')"; r2=$rc
guard "$(tool Write file_path "$F/host2/brains/README.md" ',"content":"x"')"; r3=$rc
guard "$(tool Write file_path "$F/host2/brains/other/new.md" ',"content":"x"')"; r4=$rc
[ "$r1$r2$r3$r4" = 0000 ] && ok "the brain's own brains/ folder next to a mount (checked out or not) is not a mount" || no "brains/ folder itself ($r1 $r2 $r3 $r4)"
guard "$(tool Edit file_path "$F/plain/f.txt")"; r1=$rc
guard "$(tool Edit file_path "$F/nogit/f.txt")"; r2=$rc
guard "$(tool Write file_path "/no/such/root/$RANDOM/f.md")"; r3=$rc
[ "$r1$r2$r3" = 000 ] && ok "a plain repository, a folder outside git and a path under no existing folder pass" || no "outside a brain ($r1 $r2 $r3)"
guard '{"tool_name":"Bash","tool_input":{"command":"ls"}}'; r1=$rc
guard ''; r2=$rc
guard 'not json at all'; r3=$rc
[ "$r1$r2$r3" = 000 ] && ok "no path in the input, empty input and garbage pass" || no "no path ($r1 $r2 $r3)"
# the key inside a Write's content is escaped (\"file_path\"), the tool's own key is not
guard "$(tool Write file_path "$HOST/docs/a.md" ",\"content\":\"see \\\"file_path\\\": \\\"$PEER/docs/a.md\\\"\"")"
[ "$rc" = 0 ] && ok "a mounted path quoted inside the content of a Write to the brain itself passes" || no "mention in content (rc $rc: $err)"
guard "$(printf '{"tool_name":"Write","tool_input":{"content":"see \\"file_path\\": \\"%s\\"","file_path":"%s"}}' "$HOST/docs/a.md" "$PEER/docs/a.md")"
[ "$rc" = 2 ] && ok "content before the key, with the brain's own path quoted inside, still finds the mounted path" || no "content first (rc $rc: $err)"
# JSON escapes: a path with \/ for every /, and on Windows the C:\\... form Claude Code sends there
guard "$(tool Edit file_path "${PEER//\//\\/}/docs/a.md")"
[ "$rc" = 2 ] && ok "escaped slashes in the path are undone" || no "escaped slashes (rc $rc: $err)"
if pwd -W >/dev/null 2>&1; then
  win="$(cd "$PEER" && pwd -W)"; win="${win//\//\\\\}"
  guard "$(tool Edit file_path "$win\\\\docs\\\\a.md")"
  [ "$rc" = 2 ] && ok "a Windows path arrives as C:\\\\... and is read as C:/..." || no "windows path (rc $rc: $err)"
fi

# --- the pre-push hook of a team brain's pre-commit config ---
if command -v pre-commit >/dev/null 2>&1; then
  R="$F/remote.git"; git init -q --bare -b main "$R"
  P="$F/push"; git init -q -b main "$P"
  # the keys km writes, the push hook, and a hook without `stages:` standing in for no-commit-to-branch and km-validate
  { printf 'default_install_hook_types: [pre-commit, pre-push]\ndefault_stages: [pre-commit]\nrepos:\n'; sed 's/^/  /' "$REPO/src/km/templates/team/no-push-hook.yaml"
    printf '  - repo: local\n    hooks:\n      - id: stageless\n        name: stageless\n        entry: bash -c "echo stageless ran; exit 1"\n        language: system\n        always_run: true\n        pass_filenames: false\n'; } > "$P/.pre-commit-config.yaml"
  printf 'x\n' > "$P/f.md"; git -C "$P" "${G[@]}" add -A && git -C "$P" "${G[@]}" commit -q --no-verify -m one
  git -C "$P" remote add origin "$R"
  (cd "$P" && pre-commit install >/dev/null 2>&1)
  [ -f "$P/.git/hooks/pre-push" ] && ok "pre-commit install writes the pre-push hook (default_install_hook_types)" || no "no pre-push hook installed"
  out="$(git -C "$P" "${G[@]}" push origin HEAD:main 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && out_has "merged pull request" && ! git -C "$R" rev-parse -q --verify main >/dev/null; } \
    && ok "the first push of main is refused by the pre-push hook" || no "push to main (rc $rc: $out)"
  out="$(git -C "$P" "${G[@]}" push origin HEAD:feature 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && git -C "$R" rev-parse -q --verify feature >/dev/null && ! out_has "stageless ran"; } \
    && ok "a push to a branch goes through, and a hook without stages does not run at push (default_stages)" || no "push to a branch (rc $rc: $out)"
  git -C "$P" "${G[@]}" tag v2; out="$(git -C "$P" "${G[@]}" push origin v2 2>&1)"; rc=$?
  [ "$rc" = 0 ] && ok "a tag push from a main checkout goes through" || no "tag push (rc $rc: $out)"
  out="$(git -C "$P" "${G[@]}" push --no-verify origin HEAD:main 2>&1)"; rc=$?
  [ "$rc" = 0 ] && ok "--no-verify still pushes: the hook is a guard against mistakes, not a boundary" || no "no-verify (rc $rc: $out)"
  printf 'y\n' >> "$P/f.md"; git -C "$P" "${G[@]}" commit -q --no-verify -am two
  out="$(git -C "$P" "${G[@]}" push origin HEAD:main 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && out_has "merged pull request"; } && ok "a new commit pushed to the main the remote has is refused" || no "push to existing main (rc $rc: $out)"
  sed -i.bak '/^default_stages/d' "$P/.pre-commit-config.yaml" && rm -f "$P/.pre-commit-config.yaml.bak" && git -C "$P" "${G[@]}" commit -q --no-verify -am "no default_stages"
  out="$(git -C "$P" "${G[@]}" push origin HEAD:feature 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && out_has "stageless ran"; } && ok "without default_stages the hook without stages runs at push: that is why km writes it" || no "stageless without default_stages (rc $rc: $out)"

  # km's km-gen-index hook, installed by pre-commit from a snapshot of this checkout (its working tree,
  # so the uncommitted .pre-commit-hooks.yaml counts): a commit that leaves an _index.md stale fails
  # with the index rewritten, and goes through once that is staged
  K="$F/km"; mkdir -p "$K" && (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar xf - -C "$K"
  git -C "$K" init -q && git -C "$K" "${G[@]}" add -A && git -C "$K" "${G[@]}" commit -q -m snapshot
  B="$F/gi"; mkdir -p "$B/d"; git init -q -b work "$B"
  printf 'repos:\n  - repo: %s\n    rev: %s\n    hooks:\n      - id: km-gen-index\n' "$K" "$(git -C "$K" rev-parse HEAD)" > "$B/.pre-commit-config.yaml"
  printf -- '---\ntitle: D\n---\n\n## Documents\n' > "$B/d/_index.md"; printf -- '---\ntitle: One\ndescription: first\n---\nx\n' > "$B/d/a.md"
  git -C "$B" add -A && (cd "$B" && km gen-index >/dev/null) && git -C "$B" "${G[@]}" add -A && git -C "$B" "${G[@]}" commit -q --no-verify -m init
  export PRE_COMMIT_HOME="$F/pre-commit-home"; (cd "$B" && pre-commit install >/dev/null 2>&1)
  sed -i.bak 's/title: One/title: Two/' "$B/d/a.md" && rm -f "$B/d/a.md.bak" && git -C "$B" add d/a.md
  out="$(git -C "$B" "${G[@]}" commit -m retitle 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && out_has "files were modified by this hook" && out_has "updated 1: d/_index.md; stage them and commit again" \
    && grep -q '^- \[Two\](a.md): first$' "$B/d/_index.md" && [ "$(git -C "$B" rev-list --count HEAD)" = 1 ]; } \
    && ok "km-gen-index fails a commit that changes a title, rewrites the index and says to stage it" || no "km-gen-index on a stale index (rc $rc: $out)"
  git -C "$B" add d/_index.md; out="$(git -C "$B" "${G[@]}" commit -q -m retitle 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ "$(git -C "$B" rev-list --count HEAD)" = 2 ] && (cd "$B" && km gen-index --check >/dev/null); } \
    && ok "staged again, the commit goes through with the index CI checks" || no "km-gen-index after staging (rc $rc: $out)"
  printf -- '---\ntitle: New\n---\ny\n' > "$B/d/b.md"; git -C "$B" add d/b.md
  out="$(git -C "$B" "${G[@]}" commit -q -m add 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && grep -q '(b.md)' "$B/d/_index.md"; } && ok "a newly staged doc is listed: pre-commit's run sees it as tracked" || no "km-gen-index new doc (rc $rc: $out)"
  git -C "$B" add -A && git -C "$B" "${G[@]}" commit -q -m add >/dev/null 2>&1
  git -C "$B" rm -q d/b.md; out="$(git -C "$B" "${G[@]}" commit -q -m drop 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && ! grep -q '(b.md)' "$B/d/_index.md"; } \
    && ok "a commit that only deletes a doc fails too (always_run: pre-commit passes no deleted file)" || no "pure delete (rc $rc: $out)"

  # km-validate in a brain with the gate on: an edit to an accepted doc goes back to review in the same
  # commit, its approval follows in a commit of its own
  A="$F/ap"; mkdir -p "$A/d"; git init -q -b work "$A"
  printf 'repos:\n  - repo: %s\n    rev: %s\n    hooks:\n      - id: km-validate\n' "$K" "$(git -C "$K" rev-parse HEAD)" > "$A/.pre-commit-config.yaml"
  printf 'meta: {profile: t}\ngate:\n  enabled: true\n' > "$A/schema.local.yaml"
  printf -- '---\ntype: note\ntitle: A\ntimestamp: 2026-01-15\nauthor: X\nstatus: review\ntags: [t]\n---\nfirst\n' > "$A/d/a.md"
  git -C "$A" add -A && git -C "$A" "${G[@]}" commit -q --no-verify -m init && (cd "$A" && km approve d/a.md --by X >/dev/null) \
    && git -C "$A" "${G[@]}" commit -q --no-verify -am approve
  export PRE_COMMIT_HOME="$F/pre-commit-home"; (cd "$A" && pre-commit install >/dev/null 2>&1)
  sed -i.bak 's/^first$/second/' "$A/d/a.md" && rm -f "$A/d/a.md.bak"
  out="$(git -C "$A" "${G[@]}" commit -qam edit 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && out_has "approval-stale" && out_has "km demote d/a.md"; } \
    && ok "km-validate refuses the commit of an edited accepted doc, naming km demote" || no "km-validate on a stale approval (rc $rc: $out)"
  (cd "$A" && km demote d/a.md >/dev/null); out="$(git -C "$A" "${G[@]}" commit -qam edit 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && git -C "$A" show HEAD:d/a.md | grep -q '^status: review$'; } \
    && ok "sent back to review in the same commit, the edit commits" || no "commit after demote (rc $rc: $out)"
  (cd "$A" && km approve d/a.md --by X >/dev/null); out="$(git -C "$A" "${G[@]}" commit -qam approve 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ "$(git -C "$A" rev-list --count HEAD)" = 4 ]; } \
    && ok "the approval then commits on its own" || no "approval commit (rc $rc: $out)"
  unset PRE_COMMIT_HOME
else
  echo "  skip: pre-commit is not installed, the pre-push and km-gen-index hooks are not exercised"
fi
summary hook_smoke
