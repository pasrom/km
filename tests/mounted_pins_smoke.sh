#!/usr/bin/env bash
# Smoke test for the bump-mounted-pins workflow and script a team brain gets: the commit selection
# against a stand-in GitHub API (tests/mounted_pins_check.py), the workflow's shape (which job holds
# which token), and its resolve step run against a local origin with a stand-in script.
# Run:  bash tests/mounted_pins_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
WF="$REPO/src/km/templates/team/bump-mounted-pins.yml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

out="$(kmpy "$REPO/tests/mounted_pins_check.py" 2>&1)"; rc=$?
echo "$out" | grep -E "FAIL|Traceback|Error" ; echo "$out" | tail -1
[ "$rc" = 0 ] && ok "commit selection and resolve against a stand-in API" || no "mounted_pins_check.py"

# --- the workflow's shape ---
kmpy - "$WF" <<'PY' && ok "the app token lives in resolve alone, behind the main-only environment; publish alone writes" || no "workflow shape"
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs, text = wf["jobs"], open(sys.argv[1], encoding="utf-8").read()
problems = []
def need(cond, what):
    cond or problems.append(what)
need(wf["defaults"]["run"]["shell"] == "bash", "defaults.run.shell is bash (a container job runs sh otherwise)")
need(wf["permissions"] == {"contents": "read"}, "read-only by default")
for name, job in jobs.items():
    need(job["runs-on"] == "${{ vars.MOUNTED_PINS_RUNNER || 'ubuntu-latest' }}", f"{name}: ubuntu-latest unless the brain names a runner")
    need("@sha256:" in job.get("container", ""), f"{name}: the image is pinned by digest")
    uses = [s["uses"].split("@")[0] for s in job["steps"] if "uses" in s]
    allowed = ["actions/checkout", "actions/create-github-app-token"] if name == "resolve" else ["actions/checkout"]
    need(set(uses) <= set(allowed), f"{name}: runs no other action ({uses})")
    need(all(s.get("with", {}).get("persist-credentials") is False for s in job["steps"] if s.get("uses", "").startswith("actions/checkout")),
         f"{name}: checkout keeps no credentials")
    need(not any("pip " in s.get("run", "") for s in job["steps"]), f"{name}: installs no Python package")
    secrets = "secrets." in yaml.safe_dump(job)
    need(secrets == (name == "resolve"), f"{name}: {'reads' if name == 'resolve' else 'never reads'} the app's secrets")
    need(("environment" in job) == (name == "resolve"), f"{name}: environment only where the key is")
need(jobs["resolve"]["environment"] == "mounted-pins", "the key's environment is mounted-pins")
need(jobs["resolve"]["if"] == "needs.mounts.outputs.names != ''", "no mounts: resolve does not run, no environment is created")
token = next(s for s in jobs["resolve"]["steps"] if s.get("uses", "").startswith("actions/create-github-app-token"))
need(token["with"]["owner"] == "${{ github.repository_owner }}", "the token's owner is the brain's owner")
need(token["with"]["permission-contents"] == "read" and token["with"]["permission-actions"] == "read", "a read-only token")
need(jobs["publish"]["permissions"] == {"contents": "write", "pull-requests": "write", "actions": "write"}, "publish permissions")
need(jobs["resolve"]["permissions"] == {"contents": "read", "pull-requests": "read"}, "resolve permissions")
need("--force-with-lease=" in text and "--ignore-submodules=none" in text, "lease push, gitlink diff that sees `ignore = all` mounts")
need("://x-access-token" not in text and "GIT_CONFIG_VALUE_0=" in text, "the token reaches git through the environment, not a URL")
for p in problems:
    print(f"    {p}")
sys.exit(1 if problems else 0)
PY

# --- the resolve step against a local origin ---
# A stand-in for the script: --branch-prs prints $PRS ("open seen"), --write sets the gitlink of
# brains/m to $NEW; $FAILED (paths) could not be resolved and stay at main's pin, and with
# --hold-if-moved REF it writes nothing when REF's commit moves one of them, as the script does.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "  skip: the resolve step needs bash 4 or newer (mapfile), this is ${BASH_VERSION}"
else
  kmpy -c 'import sys, yaml
step = next(s for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["resolve"]["steps"] if s.get("id") == "bump")
print(step["run"].replace("/tmp/pin-", sys.argv[2] + "/pin-"))' "$WF" "$T" > "$T/step.sh"   # files of its own, as in a fresh container
  mkdir -p "$T/bin" && printf '#!/bin/sh\n[ "$1" = -w0 ] && shift\nexec %s "$@"\n' "$(command -v base64)" > "$T/bin/base64" && chmod +x "$T/bin/base64"
  O="$T/origin.git"; W="$T/work"
  git init -q --bare -b main "$O" && git init -q -b main "$W"
  mkdir -p "$W/.github/scripts"
  printf '[submodule "m"]\n\tpath = brains/m\n\turl = ../m.git\n\tignore = all\n' > "$W/.gitmodules"
  cat > "$W/.github/scripts/bump-mounted-pins.py" <<'PY'
import os, subprocess, sys
args = sys.argv[1:]
if args[0] == "--branch-prs":
    print(os.environ["PRS"])
    sys.exit(0)
failed = os.environ.get("FAILED", "").split()
ls = lambda ref, p: subprocess.run(["git", "ls-tree", ref, "--", p], capture_output=True, text=True, check=True).stdout
hold = "--hold-if-moved" in args and any(ls(args[args.index("--hold-if-moved") + 1], p) != ls(args[args.index("--hold-if-moved") + 1] + "^", p)
                                          for p in failed)
if os.environ["NEW"] != os.environ["MAIN_PIN"] and "brains/m" not in failed and not hold:
    subprocess.run(["git", "update-index", "--cacheinfo", f"160000,{os.environ['NEW']},brains/m"], check=True)
    open(args[args.index("--emit-message") + 1], "w").write("move\n")
    open(args[args.index("--emit-body") + 1], "w").write("body\n")
sys.exit(1 if failed else 0)
PY
  A="$(printf 'a%.0s' {1..40})"; B="$(printf 'b%.0s' {1..40})"; C="$(printf 'c%.0s' {1..40})"
  ( cd "$W" && git update-index --add --cacheinfo "160000,$A,brains/m" && git add .gitmodules .github && git "${G[@]}" commit -q -m main \
    && git remote add origin "$O" && git push -q origin main ) && git clone -q "$O" "$T/side"
  branch_with(){   # the bump branch on origin, its commit setting pin $1 (of brains/m, or PATH=PIN);
    # none: no branch. Each further pin is a commit pushed by hand on top. Made in a clone of its
    # own, since the step's fetch makes the work tree's repository shallow.
    git -C "$O" update-ref -d refs/heads/chore/bump-mounted-pins
    [ "$1" = none ] && return
    ( cd "$T/side" && git checkout -q -B tmp origin/main || exit
      for p in "$@"; do
        [ "$p" = "${p#*=}" ] && p="brains/m=$p"
        git update-index --add --cacheinfo "160000,${p#*=},${p%%=*}" && git "${G[@]}" commit -q -m "$p" || exit
      done
      git push -q -f origin HEAD:refs/heads/chore/bump-mounted-pins )
  }
  step(){   # PRS NEW [FAILED]: run the step, print changed= and problems=
    ( cd "$W" && git reset -q --hard main && : > "$T/out" && rm -f "$T"/pin-* \
      && PATH="$T/bin:$PATH" PRS="$1" NEW="$2" FAILED="${3:-}" MAIN_PIN="$A" GITHUB_OUTPUT="$T/out" BRANCH=chore/bump-mounted-pins \
         GH_TOKEN=t GH_PIN_TOKEN=t bash --noprofile --norc -eo pipefail "$T/step.sh" >/dev/null 2>&1 ) || echo "step failed"
    grep -o "^changed=.*" "$T/out"; grep -o "^problems=.*" "$T/out"
  }
  r(){ echo $(step "$@"); }
  branch_with none; [ "$(r "false false" "$B")" = "changed=true problems=0" ] && ok "no bump branch: the move is proposed" || no "no branch ($(r "false false" "$B"))"
  branch_with "$B"; [ "$(r "true true" "$B")" = "changed=false problems=0" ] && ok "an open pull request already proposing these pins: nothing is pushed" || no "open PR, same pins ($(r "true true" "$B"))"
  branch_with "$B"; [ "$(r "true true" "$C")" = "changed=true problems=0" ] && ok "an open pull request with older pins is moved on" || no "open PR, newer pins ($(r "true true" "$C"))"
  # brains/f fails, brains/m moves on. "true false": --branch-prs rejects the head (a commit pushed onto it).
  branch_with "brains/f=$B"; [ "$(r "true true" "$C" brains/f)" = "changed=false problems=1" ] && ok "a mount that fails while the open pull request's own commit moves it: nothing is pushed, the run fails" || no "open PR moving a failing mount ($(r "true true" "$C" brains/f))"
  branch_with "brains/f=$B" "brains/f=$C"; [ "$(r "true false" "$C" brains/f)" = "changed=true problems=1" ] && ok "a commit pushed by hand onto the open pull request, a mount fails that it moves: the branch is regenerated, not held" || no "hand-pushed head, failing mount ($(r "true false" "$C" brains/f))"
  branch_with "$B"; [ "$(r "true true" "$C" brains/x)" = "changed=true problems=1" ] && ok "a mount that fails and the open pull request does not move: the others are still proposed, the run fails" || no "open PR, a failing mount it does not move ($(r "true true" "$C" brains/x))"
  branch_with none; [ "$(r "false false" "$B" brains/f)" = "changed=true problems=1" ] && ok "a mount that fails with no pull request open: the others are still proposed, the run fails" || no "no PR, a failing mount ($(r "false false" "$B" brains/f))"
  branch_with "$B"; [ "$(r "false false" "$B")" = "changed=true problems=0" ] && ok "a branch whose pull request never opened is pushed again, so the pull request opens" || no "M1 retry ($(r "false false" "$B"))"
  branch_with "$B"; [ "$(r "false true" "$B")" = "changed=false problems=0" ] && ok "a pull request closed on these pins is not proposed again" || no "closed PR ($(r "false true" "$B"))"
  branch_with none; [ "$(r "false false" "$A")" = "changed=false problems=0" ] && ok "nothing to move: no change" || no "nothing to move ($(r "false false" "$A"))"
fi
summary mounted_pins_smoke
