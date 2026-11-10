#!/usr/bin/env bash
# Smoke test for `km sync`, on local bare repositories: an upstream brain, a fork of it, and a clone
# of the fork with the `upstream` remote. A clean default branch is fast-forwarded and the fork on
# the host brought along by a plain push; a dirty tree, a work branch, a diverged branch and a
# diverged fork are only reported; a mounted brain is checked out at the pinned commit and a pin is
# never moved; an unreachable remote is no traceback; --quiet says nothing when there is nothing.
# Run:  bash tests/sync_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fake_km_remote "$T/kmremote"; export KM_REPO_URL="file://$T/kmremote"
printf '[user]\n\tname = t\n\temail = t@t\n[protocol "file"]\n\tallow = always\n[init]\n\tdefaultBranch = main\n' > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_CONFIG_DIR="$T/ghcfg"
unset GH_TOKEN GITHUB_TOKEN                     # a gh on this computer must not be signed in for the test
mkdir -p "$T/home" && export HOME="$T/home"
U="$T/upstream.git"; F="$T/fork.git"; B="$T/brain"; W="$T/writer"
git init -q --bare -b main "$U"
km init "$T/seed" --initials SS >/dev/null
git -C "$T/seed" init -q -b main && git -C "$T/seed" add -A && git -C "$T/seed" commit -q -m init && git -C "$T/seed" push -q "$U" main
git clone -q --bare "$U" "$F" && git clone -q "$F" "$B" && git -C "$B" remote add upstream "$U"
git clone -q "$U" "$W"                          # where the upstream brain gains commits
sync(){ out="$(cd "$B" && km sync "$@" 2>&1)"; rc=$?; }
up(){ git -C "$W" commit -q --allow-empty -m "$1" && git -C "$W" push -q origin main; }
sha(){ git -C "$1" rev-parse "$2"; }
clean(){ [ -z "$(git -C "$B" status --porcelain --ignore-submodules=none)" ] && git -C "$B" diff --cached --quiet; }

sync
{ [ "$rc" = 0 ] && out_has "ok    branch main has everything upstream main has" && out_has "ok    your fork's main has everything upstream has"; } \
  && ok "a copy at upstream: nothing to do" || no "nothing to do ($out)"
sync --quiet
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "--quiet says nothing when there is nothing to do" || no "--quiet idle ($out)"

up one; up two; sync
{ [ "$rc" = 0 ] && out_has "done  main fast-forwarded 2 commits to upstream main" && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] \
  && out_has "done  your fork's main updated on the host by 2 commits (pushed upstream's commit)" \
  && [ "$(sha "$F" main)" = "$(sha "$W" HEAD)" ] && clean; } \
  && ok "a clean main is fast-forwarded and the fork pushed along" || no "fast-forward ($out)"
up three; sync --quiet
{ [ "$rc" = 0 ] && out_has "^km sync: main fast-forwarded 1 commit" && ! out_has "  ok " && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ]; } \
  && ok "--quiet reports a fast-forward and nothing else" || no "--quiet fast-forward ($out)"

echo x >> "$B/CONVENTIONS.md"; before="$(sha "$B" HEAD)"; up four; sync
{ [ "$rc" = 0 ] && [ "$(sha "$B" HEAD)" = "$before" ] && grep -q '^x$' "$B/CONVENTIONS.md" \
  && out_has "note  main is 1 commit behind upstream main; commit or stash the 1 changed file(s) first"; } \
  && ok "a dirty tree is left alone and reported" || no "dirty tree ($out)"
git -C "$B" checkout -q CONVENTIONS.md; echo x > "$B/scratch.md"; sync
{ [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && [ -f "$B/scratch.md" ]; } && ok "an untracked file does not block the fast-forward" || no "untracked file ($out)"
rm "$B/scratch.md"

git -C "$B" checkout -q -b work; before="$(sha "$B" HEAD)"; up five; up six; sync
{ [ "$rc" = 0 ] && [ "$(sha "$B" HEAD)" = "$before" ] && [ "$(sha "$B" main)" = "$before" ] \
  && out_has "note  branch work is 2 commits behind upstream main; rebase it when you are ready"; } \
  && ok "a work branch is only reported, with the count" || no "work branch ($out)"
sync --quiet
{ [ "$rc" = 0 ] && [ "$out" = "km sync: branch work is 2 commits behind upstream main; rebase it when you are ready" ]; } \
  && ok "--quiet prints the work branch note alone" || no "--quiet work branch ($out)"
git -C "$B" checkout -q main; sync
[ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && ok "back on main: fast-forwarded" || no "back on main ($out)"

git -C "$B" commit -q --allow-empty -m local; before="$(sha "$B" HEAD)"; up seven; sync
{ [ "$rc" = 0 ] && [ "$(sha "$B" HEAD)" = "$before" ] && [ "$(git -C "$B" rev-parse --abbrev-ref HEAD)" = main ] \
  && out_has "note  main has 1 commit of its own and is 1 commit behind upstream main; rebase it when you are ready" \
  && out_has "git rebase upstream/main"; } \
  && ok "a main that diverged is never rebased or reset, only reported" || no "diverged main ($out)"
git -C "$B" reset -q --hard upstream/main

git clone -q "$F" "$T/forker" && git -C "$T/forker" commit -q --allow-empty -m "on the fork" && git -C "$T/forker" push -q origin main
forkhead="$(sha "$F" main)"; sync
{ [ "$rc" = 0 ] && out_has "ok    your fork's main has everything upstream has" && [ "$(sha "$F" main)" = "$forkhead" ]; } \
  && ok "a fork ahead of upstream is fine" || no "fork ahead ($out)"
up eight; sync
{ [ "$rc" = 0 ] && [ "$(sha "$F" main)" = "$forkhead" ] && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] \
  && out_has "note  your fork's main and upstream main have diverged: nothing done, that would need a force"; } \
  && ok "a diverged fork is never forced; the local main still follows upstream" || no "diverged fork ($out)"
git -C "$W" push -q --force "$F" main          # the fixture's own fork back at upstream
# the fork moves between the fetch and the push: git refuses the push, since nothing here forces it
stale="$(sha "$F" main)"; up "eight b"; git -C "$B" fetch -q upstream   # what a sync would have fetched
git -C "$T/forker" pull -q --rebase origin main && git -C "$T/forker" commit -q --allow-empty -m "meanwhile" && git -C "$T/forker" push -q origin main
forkhead="$(sha "$F" main)"
out="$(cd "$B" && kmpy -c '
import sys, km.sync as s, km.remotes as r
from pathlib import Path
s.sync_fork(Path.cwd(), r.Upstream("upstream", sys.argv[1], "main", ""), sys.argv[2], sys.argv[3], True)' "$U" "$(sha "$W" HEAD)" "$stale" 2>&1)"
{ out_has "FAIL  your fork's main is 1 commit behind upstream and could not be pushed" && [ "$(sha "$F" main)" = "$forkhead" ]; } \
  && ok "a fork that moved since the fetch is not overwritten: the push is refused, never forced" || no "push refused ($out)"
git -C "$W" push -q --force "$F" main; sync >/dev/null

git -C "$B" remote set-url upstream "$T/nope.git"; up nine; sync
{ [ "$rc" = 0 ] && ! out_has "Traceback" && out_has "upstream .*nope.git cannot be reached" \
  && out_has "ok    branch main has everything the last fetched upstream main (fetch failed: fatal: .*nope.git.*) has"; } \
  && ok "an unreachable upstream is a note, compared with the last fetch, no traceback" || no "unreachable upstream ($out)"
sync --quiet
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "--quiet is silent when a remote cannot be reached" || no "--quiet unreachable ($out)"
# behind what was fetched last, with the upstream unreachable now: the fast-forward says which state it went to
git -C "$B" reset -q --hard HEAD~1; sync
{ [ "$rc" = 0 ] && out_has "done  main fast-forwarded 1 commit to the last fetched upstream main (fetch failed: fatal: .*nope.git" ; } \
  && ok "a fast-forward to the last fetched state says so, with why" || no "stale fast-forward ($out)"
git -C "$B" reset -q --hard HEAD~1; sync --quiet
{ [ "$rc" = 0 ] && out_has "^km sync: main fast-forwarded 1 commit to the last fetched upstream main (fetch failed: "; } \
  && ok "--quiet prints that line, reason included" || no "--quiet stale fast-forward ($out)"
git -C "$B" remote set-url upstream "$U"
git -C "$B" remote set-url origin "$T/nope.git"; sync
{ [ "$rc" = 0 ] && ! out_has "Traceback" && out_has "origin cannot be reached" && out_has "done  main fast-forwarded 1 commit"; } \
  && ok "an unreachable origin still lets the local main follow upstream" || no "unreachable origin ($out)"
git -C "$B" remote set-url origin "$F"
up ten; sync --offline
{ [ "$rc" = 0 ] && out_has "ok    branch main has everything the last fetched upstream main (offline) has" && [ "$(sha "$B" HEAD)" != "$(sha "$W" HEAD)" ]; } \
  && ok "--offline compares with the last fetch and touches no network" || no "--offline ($out)"
sync; [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && ok "online again: fast-forwarded" || no "online again ($out)"

up eleven; sync --max-age 1h
{ [ "$rc" = 0 ] && out_has "synced 0 min ago, nothing done" && [ "$(sha "$B" HEAD)" != "$(sha "$W" HEAD)" ]; } \
  && ok "--max-age skips a run right after the last one" || no "--max-age ($out)"
sync --quiet --max-age 1h
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "--quiet --max-age is silent" || no "--quiet --max-age ($out)"
sync --max-age 0; [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && ok "--max-age 0 syncs" || no "--max-age 0 ($out)"
out="$(cd "$B" && km sync --max-age soon 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && out_has "give a number with s, m, h or d"; } && ok "a bad --max-age is refused" || no "bad --max-age ($out)"

# a mounted brain: checked out at the commit the brain pins, never moved by km sync
git init -q "$T/peer" && git -C "$T/peer" commit -q --allow-empty -m peer
git -C "$W" submodule add -q "$T/peer" brains/peer >/dev/null 2>&1 && git -C "$W" commit -q -m mount && git -C "$W" push -q origin main
sync
{ [ "$rc" = 0 ] && out_has "done  mounted brains/peer checked out at the commit the brain pins" && [ -e "$B/brains/peer/.git" ] \
  && [ "$(sha "$B/brains/peer" HEAD)" = "$(sha "$T/peer" HEAD)" ] && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && clean; } \
  && ok "a new mount is checked out at its pin, the tree stays clean" || no "new mount ($out)"
git -C "$T/peer" commit -q --allow-empty -m peer2
git -C "$W" submodule update -q --remote brains/peer 2>/dev/null && git -C "$W" commit -q -am "bump peer" && git -C "$W" push -q origin main
sync
{ [ "$rc" = 0 ] && out_has "done  mounted brains/peer checked out at the commit the brain pins" \
  && [ "$(sha "$B/brains/peer" HEAD)" = "$(sha "$T/peer" HEAD)" ] && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ] && clean; } \
  && ok "a moved pin is followed, no gitlink change and no commit of km's own" || no "moved pin ($out)"
sync; out_has "ok    mounted brains/peer is at the commit the brain pins" && ok "a mount at its pin is left alone" || no "mount at pin ($out)"
echo x > "$B/brains/peer/junk.md"; git -C "$T/peer" commit -q --allow-empty -m peer3
git -C "$W" submodule update -q --remote brains/peer 2>/dev/null && git -C "$W" commit -q -am "bump peer again" && git -C "$W" push -q origin main
sync
{ [ "$rc" = 0 ] && out_has "note  mounted brains/peer skipped: it has changes of its own" && [ -f "$B/brains/peer/junk.md" ] \
  && [ "$(sha "$B/brains/peer" HEAD)" != "$(sha "$T/peer" HEAD)" ] && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ]; } \
  && ok "a mount with changes of its own is skipped and reported" || no "dirty mount ($out)"
rm "$B/brains/peer/junk.md"; sync
{ [ "$(sha "$B/brains/peer" HEAD)" = "$(sha "$T/peer" HEAD)" ] && clean; } && ok "clean again: the mount follows its pin" || no "mount clean again ($out)"
sync --offline; out_has "ok    mounted brains/peer is at the commit the brain pins" && ok "--offline still checks the mounts" || no "--offline mounts ($out)"
git -C "$B" submodule deinit -q -f brains/peer; sync --no-init
{ [ "$rc" = 0 ] && out_has "note  mounted brains/peer is not checked out; .git submodule update --init --checkout \"brains/peer\". in the brain" \
  && [ ! -e "$B/brains/peer/.git" ]; } && ok "--no-init names a mount that is not checked out instead of cloning it" || no "--no-init ($out)"
sync; { [ -e "$B/brains/peer/.git" ] && out_has "done  mounted brains/peer checked out"; } && ok "without --no-init it is checked out" || no "init after --no-init ($out)"
git -C "$T/peer" commit -q --allow-empty -m peer4; git -C "$B" submodule update -q --remote brains/peer 2>/dev/null   # the skill's query-time sync
ahead="$(sha "$B/brains/peer" HEAD)"; sync
{ [ "$rc" = 0 ] && out_has "note  mounted brains/peer is ahead of the commit the brain pins; left as it is: .brain reset \"peer\". puts it back, a pull request moves the pin" \
  && [ "$(sha "$B/brains/peer" HEAD)" = "$ahead" ]; } && ok "a mount moved past its pin is never moved back" || no "mount ahead ($out)"
git -C "$B/brains/peer" checkout -q -b mine; sync
{ out_has "note  mounted brains/peer skipped: it has the branch mine checked out" && [ "$(sha "$B/brains/peer" HEAD)" = "$ahead" ]; } \
  && ok "a mount with a branch checked out is left alone" || no "mount on a branch ($out)"
git -C "$B/brains/peer" checkout -q --detach && git -C "$B/brains/peer" branch -q -D mine && git -C "$B" submodule update -q --init brains/peer
sync; out_has "ok    mounted brains/peer is at the commit the brain pins" && ok "back at its pin" || no "back at pin ($out)"
# a mount this computer leaves out: never checked out by km sync, and quiet about it
git -C "$B" submodule deinit -q -f brains/peer && git -C "$B" config submodule.brains/peer.update none; sync
{ [ "$rc" = 0 ] && out_has "skip  mounted brains/peer is skipped here (update = none)" && [ ! -e "$B/brains/peer/.git" ]; } \
  && ok "a mount with update = none is not checked out" || no "update none ($out)"
sync --quiet; { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "--quiet says nothing about a mount left out" || no "update none quiet ($out)"
git -C "$B" config --unset submodule.brains/peer.update; git -C "$B" config submodule.brains/peer.active false; sync
{ out_has "skip  mounted brains/peer is skipped here (inactive)" && [ ! -e "$B/brains/peer/.git" ]; } && ok "an inactive mount is not checked out" || no "inactive ($out)"
git -C "$B" config --unset submodule.brains/peer.active
# a mount this computer cannot read fails alone: the other mounts are still synced
git init -q "$T/closed" && git -C "$T/closed" commit -q --allow-empty -m closed
git -C "$W" submodule add -q "$T/closed" brains/aaa >/dev/null 2>&1 && git -C "$W" commit -q -m "mount closed" && git -C "$W" push -q origin main
rm -rf "$T/closed"; sync
{ [ "$rc" = 1 ] && out_has "FAIL  mounted brains/aaa could not be checked out (fatal: " && out_has 'leave it out on this computer: .git config "submodule.brains/aaa.update" none.' \
  && out_has "done  mounted brains/peer checked out at the commit the brain pins" && [ -e "$B/brains/peer/.git" ]; } \
  && ok "an unreadable mount fails with the skip as a fix, and the other mounts still sync" || no "unreadable mount ($out)"
git -C "$B" config submodule.brains/aaa.update none; sync
{ [ "$rc" = 0 ] && out_has "skip  mounted brains/aaa is skipped here (update = none)"; } && ok "the skip it names ends the failure" || no "skip ends failure ($out)"
git -C "$W" rm -q brains/aaa && git -C "$W" commit -q -m "unmount closed" && git -C "$W" push -q origin main && sync
# a pin to a commit the mount's host lacks is no question of access: no skip offered
git -C "$W" submodule update -q --init brains/peer && git -C "$W/brains/peer" "${G[@]}" commit -q --allow-empty -m unpushed
git -C "$W" commit -q -am "pin an unpushed commit" && git -C "$W" push -q origin main; sync
{ [ "$rc" = 1 ] && out_has "FAIL  mounted brains/peer could not be checked out" && ! out_has "leave it out on this computer"; } \
  && ok "a pinned commit the host lacks fails without offering the skip" || no "unpushed pin ($out)"
git -C "$W/brains/peer" push -q origin HEAD:refs/heads/extra; sync   # the host gets the commit: the pin works again

git -C "$B" checkout -q --detach HEAD~1; sync
{ [ "$rc" = 0 ] && out_has "note  the detached HEAD is 1 commit behind upstream main; .git switch main. when you are ready"; } && ok "a detached HEAD is reported" || no "detached ($out)"
git -C "$B" checkout -q main

# inside a mounted brain: nothing is touched, the parent brain syncs it
git -C "$T/peer" commit -q --allow-empty -m peer5; peerhead="$(sha "$B/brains/peer" HEAD)"
out="$(cd "$B/brains/peer" && km sync 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "skip  this is a brain mounted in" && [ "$(sha "$B/brains/peer" HEAD)" = "$peerhead" ] && clean; } \
  && ok "inside a mounted brain km sync changes nothing and says where to run it" || no "inside a mount ($out)"
# a brain with no origin yet: nothing to sync from, no failure
git init -q "$T/lonely" && git -C "$T/lonely" commit -q --allow-empty -m init
out="$(cd "$T/lonely" && km sync --quiet 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ -f "$T/lonely/.git/km-sync" ]; } && ok "a brain without origin is a silent skip that counts as a try" || no "no origin ($out)"

# no fork: a clone of the upstream itself
git clone -q "$U" "$T/direct"; up twelve
out="$(cd "$T/direct" && km sync 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "done  main fast-forwarded 1 commit to origin main" && ! out_has "fork"; } \
  && ok "without a fork, origin is the upstream" || no "no fork ($out)"
out="$(cd "$T" && km sync 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && out_has "FAIL  .* is not a git repository"; } && ok "outside a repository it fails and says so" || no "outside a repository ($out)"

# a fork on GitHub: the parent through gh, and `gh repo sync` before a push (a stand-in gh, POSIX only)
if [ "$SEP" = ":" ]; then
  G="$T/ghstub"; mkdir -p "$G"
  cat > "$G/gh" <<SH
#!/bin/sh
echo "\$*" >> "$T/gh.log"
case "\$*" in
  "api --hostname github.com repos/o/r --jq "*) printf 'true\to/r-1\tmain\thttps://github.com/o/r.git\tgit@github.com:o/r.git\n' ;;
  "repo sync o/r-1 --branch main") exit "\${GH_SYNC_RC:-0}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$G/gh"
  git init -q "$T/ghfork" && git -C "$T/ghfork" remote add origin https://github.com/o/r.git
  out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd()))' 2>&1)"
  out_has "Upstream(remote=None, url='https://github.com/o/r.git', branch='main', fork='o/r-1')" \
    && ok "a GitHub fork's parent is found through gh, with its default branch" || no "gh parent ($out)"
  git -C "$T/ghfork" remote set-url origin git@github.com:o/r.git
  out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd()))' 2>&1)"
  out_has "url='git@github.com:o/r.git'" && ok "an ssh origin gets the parent's ssh URL" || no "gh parent ssh ($out)"
  out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd(), offline=True))' 2>&1)"
  out_has "Upstream(remote='origin'" && ok "offline, gh is not asked: origin is the upstream" || no "gh offline ($out)"
  git -C "$T/ghfork" remote add upstream "$U"
  out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd()))' 2>&1)"
  out_has "Upstream(remote='upstream', url='$U', branch='main', fork='o/r-1')" && ok "with an upstream remote, gh still names the fork" || no "upstream remote + gh ($out)"
  git -C "$T/ghfork" remote set-url origin https://github.com/o/plain.git
  out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd()))' 2>&1)"
  out_has "fork=None)" && ok "an upstream remote on a repository gh does not know as a fork: origin's main is left alone" || no "upstream remote, no fork ($out)"
  # what gh said is kept in git config km.fork: the next runs ask nothing, until the key is unset
  cat > "$G/gh" <<SH
#!/bin/sh
echo "\$*" >> "$T/gh.log"
case "\$*" in
  "api --hostname github.com repos/o/plain --jq "*) printf 'false\to/plain\t\t\t\n' ;;
  "api --hostname github.com repos/o/r --jq "*) printf 'true\to/r-1\tmain\thttps://github.com/o/r.git\tgit@github.com:o/r.git\n' ;;
  "repo sync o/r-1 --branch main") exit "\${GH_SYNC_RC:-0}" ;;
  *) exit 2 ;;
esac
SH
  ask(){ out="$(cd "$T/ghfork" && PATH="$G:$PATH" kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd(), remember=True))' 2>&1)"; }
  : > "$T/gh.log"; ask; n1="$(grep -c "repos/o/plain" "$T/gh.log")"; ask; n2="$(grep -c "repos/o/plain" "$T/gh.log")"
  { [ "$(git -C "$T/ghfork" config km.fork)" = "false https://github.com/o/plain.git" ] && [ "$n1" = 1 ] && [ "$n2" = 1 ] && out_has "fork=None)"; } \
    && ok "gh's 'not a fork' is remembered in km.fork: the second run asks nothing" || no "fork cache ($out; $n1 $n2 $(git -C "$T/ghfork" config km.fork))"
  git -C "$T/ghfork" config --unset km.fork; ask; n3="$(grep -c "repos/o/plain" "$T/gh.log")"
  [ "$n3" = 2 ] && ok "git config --unset km.fork asks gh again" || no "fork cache reset ($n3)"
  git -C "$T/ghfork" remote set-url origin https://github.com/o/r.git; : > "$T/gh.log"; ask; ask
  { [ "$(git -C "$T/ghfork" config km.fork)" = "o/r-1 https://github.com/o/r.git" ] && [ "$(grep -c "repos/o/r " "$T/gh.log")" = 1 ] && out_has "fork='o/r-1')"; } \
    && ok "a fork with its parent as the upstream remote is remembered too; a changed origin was asked afresh" || no "fork cache positive ($out; $(cat "$T/gh.log"))"
  git -C "$T/ghfork" config --unset km.fork
  mkdir -p "$T/bin" && ln -s "$(command -v git)" "$T/bin/git" && ln -s "$(command -v "$PY")" "$T/bin/python3"
  out="$(cd "$T/ghfork" && PATH="$T/bin" PYTHON=python3 kmpy -c 'import km.remotes as r; from pathlib import Path; print(r.find_upstream(Path.cwd()))' 2>&1)"
  out_has "fork='')" && ok "without gh, a fork cannot be confirmed: a plain push may bring origin along" || no "no gh ($out)"
  # a parent gh found becomes the remote `upstream`, and after the fetch its HEAD ref is known
  git clone -q "$F" "$T/ghclone"
  out="$(cd "$T/ghclone" && kmpy -c '
import sys, km.sync as s, km.remotes as r
from pathlib import Path
print(s.upstream_remote(Path.cwd(), r.Upstream(None, sys.argv[1], "main", "o/r-1")))' "$U" 2>&1)"
  { out_has "done  added the remote upstream, the fork's parent: " && out_has "Upstream(remote='upstream'" \
    && [ "$(git -C "$T/ghclone" remote get-url upstream)" = "$U" ]; } && ok "a parent gh found is added as the remote upstream" || no "add upstream ($out)"
  out="$(cd "$T/ghclone" && km sync 2>&1)"
  { ! out_has "Traceback" && [ "$(git -C "$T/ghclone" symbolic-ref refs/remotes/upstream/HEAD)" = refs/remotes/upstream/main ]; } \
    && ok "after the fetch the upstream's default branch is remembered as its HEAD ref" || no "set-head ($out)"
  sync >/dev/null; up thirteen; forkhead="$(sha "$F" main)"; : > "$T/gh.log"
  out="$(cd "$B" && PATH="$G:$PATH" kmpy -c '
import km.sync as s, km.remotes as r
from pathlib import Path
root = Path.cwd(); up = r.Upstream("upstream", "'"$U"'", "main", "o/r-1")
up, theirs, mine, net, stale = s.fetch(root, up, False); s.sync_fork(root, up, theirs, mine, net)' 2>&1)"
  { out_has "done  your fork's main updated on the host by 1 commit (gh repo sync)" && grep -q "^repo sync o/r-1 --branch main$" "$T/gh.log" \
    && ! grep -q -- "--force" "$T/gh.log" && [ "$(sha "$F" main)" = "$forkhead" ]; } \
    && ok "a GitHub fork is synced through gh without --force, nothing pushed" || no "gh repo sync ($out; $(cat "$T/gh.log"))"
  out="$(cd "$B" && GH_SYNC_RC=1 PATH="$G:$PATH" kmpy -c '
import km.sync as s, km.remotes as r
from pathlib import Path
root = Path.cwd(); up = r.Upstream("upstream", "'"$U"'", "main", "o/r-1")
up, theirs, mine, net, stale = s.fetch(root, up, False); s.sync_fork(root, up, theirs, mine, net)' 2>&1)"
  { out_has "FAIL  your fork's main is 1 commit behind upstream and gh could not sync it" && [ "$(sha "$F" main)" = "$forkhead" ]; } \
    && ok "when gh refuses to sync a fork it knows, nothing is pushed" || no "gh refused ($out)"
  sync >/dev/null
fi

# the plugin's SessionStart hook: silent outside a brain and within 15 minutes of a sync; otherwise km sync --quiet
hook(){ out="$(cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$REPO/hooks/session-start.sh" 2>&1)"; rc=$?; }
old(){ ( cd "$B" && touch -t 202001010000 "$(git rev-parse --git-path km-sync)" ); }   # the last sync long ago
hook "$T"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "the hook is silent outside a brain" || no "hook outside a brain ($out)"
mkdir -p "$T/plain" && git -C "$T/plain" init -q && hook "$T/plain"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "the hook is silent in a repository that is no brain" || no "hook in a plain repo ($out)"
printf -- '---\n---\n' > "$B/brains/peer/CONVENTIONS.md"; : > "$B/brains/peer/schema.local.yaml"   # the mount looks like a brain
hook "$B/brains/peer"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "the hook is silent inside a mounted brain" || no "hook inside a mount ($out)"
rm "$B/brains/peer/CONVENTIONS.md" "$B/brains/peer/schema.local.yaml"
sync >/dev/null; up fourteen; old; hook "$B"
{ [ "$rc" = 0 ] && out_has "^km sync: main fast-forwarded 1 commit to upstream main" && [ "$(sha "$B" HEAD)" = "$(sha "$W" HEAD)" ]; } \
  && ok "in a brain the hook syncs and reports what changed" || no "hook in a brain ($out)"
up fifteen; hook "$B"
{ [ "$rc" = 0 ] && [ -z "$out" ] && [ "$(sha "$B" HEAD)" != "$(sha "$W" HEAD)" ]; } \
  && ok "within 15 minutes the hook does nothing, in silence" || no "hook throttled ($out)"
# a repository that carries a `km` package of its own: the launcher never runs it (the brain's directory is off sys.path)
mkdir -p "$B/km" && printf 'open(%s, "w").write("shadowed")\nraise SystemExit(0)\n' "'$T/shadowed'" > "$B/km/__main__.py" && : > "$B/km/__init__.py"
old; up sixteen; hook "$B"
{ [ "$rc" = 0 ] && [ ! -e "$T/shadowed" ] && out_has "^km sync: main fast-forwarded" ; } \
  && ok "a km package in the brain is not what the hook runs" || no "shadowing package via the hook ($out)"
out="$(cd "$B" && "$REPO/skills/km/bin/km" sync --offline 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$T/shadowed" ] && out_has "ok    branch main has everything the last fetched upstream main (offline) has"; } \
  && ok "nor what the launcher runs from inside the brain" || no "shadowing package via the launcher ($out)"
printf 'python-preference = "only-managed"\npython-downloads = "never"\n' > "$B/uv.toml"   # read, this leaves uv no Python to run km with
mkdir -p "$T/nopy"; out="$(cd "$B" && UV_PYTHON_INSTALL_DIR="$T/nopy" "$REPO/skills/km/bin/km" sync --offline 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && out_has "ok    branch main has everything the last fetched upstream main (offline) has" && ! out_has "runs it$"; } \
  && ok "a uv.toml in the brain does not steer the launcher's uv" || no "uv.toml in the brain ($out)"
rm -r "$B/km" "$B/uv.toml"
expected="$(cd "$B" && km nosuch 2>&1)"; erc=$?   # what a failing km command prints, and its exit code
printf 'x' > "$T/keep"; out="$(KM_PENDING_FILE="$T/keep" km --version 2>&1)"; rc=$?   # the launcher's file is empty
{ [ "$rc" = 1 ] && [ -s "$T/keep" ] && out_has "^km: cannot remove KM_PENDING_FILE" && ! out_has "^$(km --version)$"; } \
  && ok "km deletes no file with content for the launcher, and then runs nothing" || no "KM_PENDING_FILE with content ($rc: $out)"
# km run by uv and failing: its output and exit code, once (where uv can set km up, online or cached)
if command -v uv >/dev/null 2>&1 && uv run -q --no-config --no-project --python '>=3.11' --with pyyaml==6.0.3 python -c '' 2>/dev/null; then
  out="$(cd "$B" && "$REPO/skills/km/bin/km" nosuch 2>&1)"; rc=$?
  { [ "$rc" = "$erc" ] && [ "$rc" != 0 ] && [ "$out" = "$expected" ]; } \
    && ok "a km command failing under uv fails the launcher with its own output, once" || no "km fails under the real uv ($rc/$erc: $out)"
fi
if [ "$SEP" = ":" ]; then   # a computer with git but nothing to run km with
  mkdir -p "$T/bare" && for c in bash git dirname find; do ln -s "$(command -v $c)" "$T/bare/$c"; done
  old
  out="$(cd "$B" && CLAUDE_PROJECT_DIR="$B" PATH="$T/bare" "$BASH" "$REPO/hooks/session-start.sh" 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "without uv or Python the hook stays silent" || no "hook on a fresh computer ($out)"
  # without uv the launcher probes for a Python with PyYAML from inside the brain: a yaml.py there does not run
  pyexe="$("$PY" -c 'import sys; print(sys.executable)')"
  mkdir -p "$T/pyonly" "$T/nohome" && ln -s "$(command -v dirname)" "$T/pyonly/dirname"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$pyexe" > "$T/pyonly/python3" && chmod +x "$T/pyonly/python3"
  printf 'open(%s, "w").write("yaml")\n' "'$T/shadowed'" > "$B/yaml.py"
  out="$(cd "$B" && HOME="$T/nohome" PATH="$T/pyonly" "$BASH" "$REPO/skills/km/bin/km" --version 2>&1)"; rc=$?
  { [ "$rc" = 0 ] && [ ! -e "$T/shadowed" ] && [ "$out" = "$(km --version)" ]; } \
    && ok "without uv, a yaml.py in the brain is not what the launcher's Python probe imports" || no "yaml.py via the launcher's probe ($rc: $out)"
  rm -f "$B/yaml.py" "$T/shadowed"
  # uv that cannot set km up (offline, nothing cached) hands over to a Python with PyYAML; a uv that
  # ran km hands over nothing. python3 logs each run, so a km started twice shows.
  mkdir -p "$T/uvfail"; for c in dirname mktemp rm; do ln -s "$(command -v $c)" "$T/uvfail/$c"; done
  printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$T/pylog" "$pyexe" > "$T/uvfail/python3"
  printf '#!/bin/sh\necho "error: Failed to fetch: https://pypi.org/simple/pyyaml/" >&2; exit 2\n' > "$T/uv-offline"
  chmod +x "$T/uvfail/python3" "$T/uv-offline" && cp "$T/uv-offline" "$T/uvfail/uv"
  plant(){ printf 'open(%s, "w").write("yaml")\n' "'$T/shadowed'" > "$B/yaml.py"; mkdir -p "$B/km"; : > "$B/km/__init__.py"
    printf 'open(%s, "w").write("km")\n' "'$T/shadowed'" > "$B/km/__main__.py"; }
  launch(){ : > "$T/pylog"; out="$(cd "$B" && PATH="$1" "$BASH" "$REPO/skills/km/bin/km" "${@:2}" 2>&1)"; rc=$?; runs="$(grep -c -- '-m km' "$T/pylog")"; }
  plant; launch "$T/uvfail" --version
  { [ "$rc" = 0 ] && [ "$runs" = 1 ] && [ "$(tail -n 1 <<< "$out")" = "$(km --version)" ] && out_has "Failed to fetch" \
    && out_has "km: km did not start under uv (above), so python3 runs it" && [ ! -e "$T/shadowed" ]; } \
    && ok "where uv cannot set km up, a Python with PyYAML runs it, and nothing from the brain" || no "uv fails, Python runs km ($rc, $runs runs: $out)"
  launch "$T/uvfail" nosuch
  { [ "$rc" = "$erc" ] && [ "$rc" != 0 ] && [ "$runs" = 1 ] && [ "${out#*runs it$'\n'}" = "$expected" ]; } \
    && ok "km failing on that Python fails the launcher, unchanged, once" || no "km fails after uv fails ($rc/$erc, $runs runs: $out)"
  printf '#!/bin/sh\nwhile [ "$1" != python ]; do shift; done; shift; exec python3 "$@"\n' > "$T/uvfail/uv"   # a uv that runs km
  launch "$T/uvfail" nosuch
  { [ "$rc" = "$erc" ] && [ "$runs" = 1 ] && [ "$out" = "$expected" ]; } \
    && ok "km failing under uv fails the launcher, unchanged, and is not run again" || no "km fails under uv ($rc/$erc, $runs runs: $out)"
  cp "$T/uv-offline" "$T/uvfail/uv"
  rm "$T/uvfail/python3"; launch "$T/uvfail" --version
  { [ "$rc" = 1 ] && out_has "Failed to fetch" && out_has "km cannot start: it did not start under uv" \
    && out_has "no Python 3.11+ with PyYAML is installed here" && [ ! -e "$T/shadowed" ]; } \
    && ok "where neither uv nor a Python can run km, the launcher names both" || no "uv fails, no Python ($rc: $out)"
  # the same with the real uv, offline in an empty home, and a Python whose PyYAML uv does not see
  # (no dist-info): uv has no pyyaml to resolve, the Python runs km
  if command -v uv >/dev/null 2>&1 && "$PY" -m venv --without-pip "$T/venv" 2>/dev/null; then
    mkdir -p "$T/yamlonly" "$T/uvhome" && ln -s "$("$PY" -c 'import os, yaml; print(os.path.dirname(yaml.__file__))')" "$T/yamlonly/yaml"
    "$T/venv/bin/python" -c 'import site, sys; open(site.getsitepackages()[0] + "/yamlonly.pth", "w").write(sys.argv[1])' "$T/yamlonly"
    rm "$T/uvfail/uv"; ln -s "$(command -v uv)" "$T/uvfail/uv"
    out="$(cd "$B" && env -u UV_CACHE_DIR -u XDG_CACHE_HOME -u XDG_DATA_HOME -u UV_PYTHON_INSTALL_DIR -u UV_PYTHON -u VIRTUAL_ENV -u CONDA_PREFIX \
      HOME="$T/uvhome" UV_OFFLINE=1 PATH="$T/venv/bin:$T/uvfail" "$BASH" "$REPO/skills/km/bin/km" --version 2>&1)"; rc=$?
    { [ "$rc" = 0 ] && [ "$(tail -n 1 <<< "$out")" = "$(km --version)" ] && out_has "so python3 runs it" && [ ! -e "$T/shadowed" ]; } \
      && ok "offline, the real uv hands over to a Python with PyYAML" || no "real uv offline ($rc: $out)"
  fi
  rm -rf "$B/yaml.py" "$B/km" "$T/shadowed"
fi
# the upstream renames its default branch: the stale ref is pruned, and the new name read from the host
sync >/dev/null; git -C "$U" branch -m main trunk && git -C "$U" symbolic-ref HEAD refs/heads/trunk
git -C "$W" fetch -q -p origin && git -C "$W" checkout -q trunk && git -C "$W" commit -q --allow-empty -m "on trunk" && git -C "$W" push -q origin trunk
sync
{ [ "$rc" = 0 ] && ! out_has "Traceback" && out_has "note  branch main is 1 commit behind upstream trunk; rebase it when you are ready" \
  && [ "$(git -C "$B" symbolic-ref refs/remotes/upstream/HEAD)" = refs/remotes/upstream/trunk ] && ! git -C "$B" rev-parse -q --verify refs/remotes/upstream/main >/dev/null; } \
  && ok "a renamed upstream default branch is read from the host again; the local main is then a branch of its own" || no "renamed default branch ($out)"
summary sync_smoke
