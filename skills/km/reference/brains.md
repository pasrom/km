# km reference: Mounted brains and shared resources

## Contents

- Mounted brains and shared resources
  - Brains (peer knowledge bases)
  - Shared resources (self-describing repos)
  - `@all` sync
  - Pin-bump PR (newer content of a mount)
- Brain management
- Foreign-brain corrections (`brain fix @<name> ...`)
  - Workflow
  - Hard rules
- Contributing content to a brain (`contribute @<name> ...`)
  - `contribute --finish <PR-url>` (after the PR merges)
  - Hard rules

## Mounted brains and shared resources

### Brains (peer knowledge bases)

- Located under `brains/<name>/` (git submodules), read at the commit the brain pins
- Sync: `km sync --quiet --max-age 15m` before the query (see "Running km and keeping the copy current" in `${CLAUDE_SKILL_DIR}/reference/setup.md`); it
  checks every mount out at its pin and never moves one ahead of it. Pass its notes on: a mount
  with changes of its own or ahead of its pin is left as it is (`brain reset <name>` puts it
  back), never a silent skip. Newer content of a mount comes only with a moved pin, through a pull
  request: a team brain's bump-mounted-pins PR, or the pin-bump PR below when the user asks for it

### Shared resources (self-describing repos)

Any git submodule **not** under `brains/` is a shared resource. Discover them from `.gitmodules`.

- On first `@<name>` query in a session, read `<name>/CLAUDE.md` to learn the repo's search scope, file types, commands, and citation format. Cache this for the rest of the session
- If `<name>/CLAUDE.md` is missing, fall back to recursive `.md` search in `<name>/`
- Sync: as for brains, `km sync` keeps it at its pin; the pin moves only through a pull request

### `@all` sync

Before searching, `km sync --quiet --max-age 15m` once: every mount is then at its pin, and a
mount it could not bring there is named (pass that on, never fail silently). Then search in
order: current repo → brains → shared resources.

### Pin-bump PR (newer content of a mount)

A pin moves only on a branch and through a pull request, never on `main`. When the user wants a
mount at a newer commit (or km sync reports one ahead of its pin that they want to keep), offer:
`git switch -c chore/bump-<name>`, `git submodule update --remote -- brains/<name>` (this one
step may move the checkout past the pin: it is the bump), `git add brains/<name>`, commit
`chore(brains): bump <name> to <short sha>`, push, `gh pr create`; then `git switch main` and
`km sync`, which puts the mount back at main's pin until the PR merges. A team brain gets the
same bump from its bump-mounted-pins workflow (`chore/bump-mounted-pins`).

## Brain management

- `brain add <url> [name]` → `git submodule add <url> brains/<name>`, validate CONVENTIONS.md exists, `git config submodule.recurse true`, commit
- `brain list` → table: name, URL, commit, last updated. Discover shared resources from `.gitmodules` and list them in a separate section
- `brain remove <name>` → confirm, `git submodule deinit -f` + `git rm -f`, commit
- `brain reset <name>` → put a drifted submodule back at its pin (parent shows `+` / ` m`, or km sync reports it ahead or with changes). (1) `git -C brains/<name> status` and SHOW it; STOP if there are dirty files — they may be unpushed work, never discard them silently. (2) on OK: `git submodule update --init --checkout --force brains/<name>` (back to the pinned commit) and `git -C brains/<name> worktree prune`. (3) delete leftover local `fix/km-*` / `docs/km-*` branches whose PR has merged. With the throwaway-clone `brain fix` below, new drift no longer happens

## Foreign-brain corrections (`brain fix @<name> ...`)

Errors in a foreign brain are fixed as a **PR against the brain's own repo**, never silently overridden in the parent.

Trigger: user says e.g. "fix this in @<brain>" / "das in @<brain> stimmt nicht", or an `@`-query would otherwise have to cite a known wrong statement — offer the PR instead. For shared resources, defer to the resource's `CONTRIBUTING.md` or `CLAUDE.md` if present.

### Workflow

The fix is made in a THROWAWAY clone, never in the mounted `brains/<name>/` working tree, so that
tree stays on its pinned commit and the parent never drifts (no stray branch, no dirty pointer).
Show the proposed diff and wait for explicit OK. **Each step below runs in a fresh shell** — do not
rely on env vars or an `EXIT` trap surviving between steps; use a FIXED working dir you retype
verbatim in every command and delete explicitly at the end.

1. The gh check in "GitHub access" (SKILL.md); abort if it fails.
2. Pick a branch name `km-<short>-<YYYYMMDD>` (the date avoids colliding with a leftover branch) and a
   fixed working dir, e.g. `/tmp/km-fix-<name>`, reused literally below.
3. Clone the brain and detach (no local branch; the brain's real default branch is used):
   ```
   rm -rf /tmp/km-fix-<name>
   git clone "$(git -C brains/<name> remote get-url origin)" /tmp/km-fix-<name>
   git -C /tmp/km-fix-<name> checkout --detach origin/HEAD
   ```
4. Apply the edit under `/tmp/km-fix-<name>`; follow the brain's own `CONVENTIONS.md` for
   frontmatter/naming and the Ripple update rules (see "Ripple update" in SKILL.md). Commit there per "Writing content" (SKILL.md).
5. Prepare the PR (`/km pr` steps 1–4, `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`), then push straight to a remote branch, no local branch: `git -C /tmp/km-fix-<name> push origin "HEAD:refs/heads/km-<short>-<YYYYMMDD>"`. If push is denied: `gh repo fork --remote=false <owner>/<repo>`, then push by URL: `git -C /tmp/km-fix-<name> push "https://github.com/<you>/<repo>.git" "HEAD:refs/heads/km-<short>-<YYYYMMDD>"`.
6. `gh pr create --head "km-<short>-<YYYYMMDD>"` (fork path: `--head "<you>:km-<short>-<YYYYMMDD>"`); the body must **paraphrase, not paste** any parent-repo source that surfaced the error. Then `/km pr` step 6 on the new PR.
7. Return the PR URL, then `rm -rf /tmp/km-fix-<name>`. The mounted submodule was never touched.

### Hard rules

- Never push to a brain's `main`, never `--force` push; the one exception is `--force-with-lease=<branch>:<pushed-head>` to your own open PR after `/km pr` folded it
- Never bump the parent's submodule pointer to an unmerged branch — wait for merge, then a pin-bump PR in the parent (see "Pin-bump PR")
- Never edit the mounted `brains/<name>/` working tree; every correction runs in the throwaway clone above (that is what keeps the parent drift-free). If a mounted submodule is already drifted, repair it with `brain reset <name>`
- Never include parent-repo private content (memory, internal notes) verbatim in a brain PR
- If the brain has no `CONVENTIONS.md`, ask before editing — rules may live in `README` or `CONTRIBUTING`

## Contributing content to a brain (`contribute @<name> ...`)

Add or update a doc in a brain you have READ (not write) on, e.g. a shared team brain, from your own
brain. Same throwaway-clone + PR recipe as `brain fix`; the edit is a **cross-repo `km promote`**, so
the doc is placed and gated by the TARGET brain's schema.

**Prerequisites and invariants.** The target is mounted (`brain add <url>` first) so you can read/cite
it and so `--finish` can point at it. The source is a doc in YOUR brain: refuse a source under
`brains/<other>/` (route that to `brain fix`). **Each step runs in a fresh shell** — use a FIXED
working dir retyped verbatim below (no `mktemp`+trap), deleted at the end. Show the proposed doc and
wait for explicit OK. Then:

1. The gh check in "GitHub access" (SKILL.md). Choose a branch name `<BR>` (a ticket key if there is
   one, else a short slug plus date; a ticket is NOT required) and a fixed working dir
   `/tmp/km-contrib-<slug>`, reused below.
2. Clone the target and detach:
   ```
   rm -rf /tmp/km-contrib-<slug>
   git clone "$(git -C brains/<name> remote get-url origin)" /tmp/km-contrib-<slug>
   git -C /tmp/km-contrib-<slug> checkout --detach origin/HEAD
   ```
   To ADD to or EDIT an already-open contribution (a source carrying `contribution:`), check out its
   PR head instead; `pull/<N>/head` exists on the target even when the branch lives in a fork:
   `git -C /tmp/km-contrib-<slug> fetch origin pull/<N>/head && git -C /tmp/km-contrib-<slug> checkout --detach FETCH_HEAD`.
   In step 7 push back to the PR's head (`gh pr view <N> --json headRepositoryOwner,headRepository,headRefName`:
   the target itself or the contributor's fork) and skip `gh pr create`.
3. **Trusted gate.** Run YOUR km against the clone (`--root /tmp/km-contrib-<slug>`), never code from
   the clone: it gates with the target's `schema.local.yaml`, and nothing is copied in. Where the
   target pins another km version, km runs that one (see "Running km and keeping the copy current" in `${CLAUDE_SKILL_DIR}/reference/setup.md`), so the PR matches its CI.
4. **Terms hand-off.** If the target's `schema.local.yaml` sets `gate.forbidden_terms_file`, that file
   is out of git and the target's maintainer distributes it; put it at the path the target names,
   inside the clone, before promoting. If you cannot get it, STOP — by design, the leak check must not
   silently disable.
5. Promote the source into the clone (cross-repo mode auto-applies: `--author` from YOUR identity,
   source-repo refs/links stripped or refused):
   ```
   km promote --root /tmp/km-contrib-<slug> <slug> "<ABS-path-to-source-in-your-brain>.md" \
       --folder <target-folder> --author <your-initials> [--ticket KEY] [--type T]
   ```
   To UPDATE a doc already `accepted` on the target, add `--replace` (the PR then shows the approval
   drop, which IS the review signal). A doc already in `review` on the target cannot be re-promoted;
   edit it in the clone as in `brain fix`.
6. Track the doc so `km gen-index` sees it, regenerate the indexes, run the whole-repo gate, then commit
   ONLY the doc and the `_index.md` files that changed. If `<target-folder>` is new, first write its
   `_index.md` by hand (frontmatter with a `description:`, an empty `## Documents` heading) and track it
   too: a team brain's generator refuses a folder with docs but no index, and the parent folder's list
   gains a link to the new one.
   ```
   git -C /tmp/km-contrib-<slug> add -- <target-folder>/<slug>.md   # track it FIRST (and a new folder's _index.md): gen-index / check_index read git ls-files
   km gen-index --root /tmp/km-contrib-<slug>              # rewrites only '## Documents' lists; an index without one is left alone
   git -C /tmp/km-contrib-<slug> add -u -- '*_index.md'   # every index the generator rewrote, parents included
   km validate --root /tmp/km-contrib-<slug>               # WHOLE-REPO gate; the per-file promote gate never sees index-incomplete. Fix any error.
   git -C /tmp/km-contrib-<slug> diff --cached --name-only   # MUST list ONLY the doc + _index.md files (never a terms file)
   git -C /tmp/km-contrib-<slug> commit -m "docs(<scope>): <what>"
   ```
   Never `git add -A`: a terms file must NOT be committed. In a brain whose indexes have no
   `## Documents` list, add the doc to its folder's `_index.md` by hand.
7. Prepare the PR (`/km pr` steps 1–4, `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`), push and open it: `git -C /tmp/km-contrib-<slug> push origin
   "HEAD:refs/heads/<BR>"` (fork path as in `brain fix` if push is denied), then `gh pr create --head
   "<BR>"` and `/km pr` step 6. Return the PR URL, then
   `rm -rf /tmp/km-contrib-<slug>`.
8. **Mark the source pending** in YOUR brain: add `contribution: "<owner>/<repo>#<N>"` to its
   frontmatter and commit (`docs(<scope>): mark <slug> pending in <owner>/<repo>#<N>`). It is a
   marker, not a stub: the doc stays complete and keeps its `status` until the PR is decided (see the
   hard rule on `contribution:`).

### `contribute --finish <PR-url>` (after the PR merges)

`gh pr view <PR> --json state,files` shows whether it merged or was closed. Every doc in your brain
carrying `contribution: "<owner>/<repo>#<N>"` belongs to it (`grep -rl` finds them).

- **Merged:** take each merged path from `.files` (canonical, even if a reviewer renamed or changed it
  on the branch). On a branch (`git switch -c chore/bump-<name>`), `git submodule update --remote --
  brains/<name>` to pin the brain to the merged state, then for each source
  `km promote stub <source> --to brains/<name>/<merged-path>`. It rewrites the source into a gated
  `superseded` redirect stub and drops `contribution:`; after the bump `superseded_by` resolves.
  Commit the stubs plus the bumped submodule pointer and open the PR (see "Pin-bump PR"); the
  stubs resolve once it merges and `km sync` brings main there.
- **Closed unmerged:** delete the `contribution:` line; the doc is an ordinary doc of your brain again.

### Hard rules

- Prerequisite: the target is mounted (`brain add` first); the source is a doc in YOUR brain, never one under `brains/`.
- Each step is a fresh shell: a FIXED working dir, no `mktemp`+trap; `rm -rf` it at the end.
- Gate with YOUR km (`--root <clone>`); never run code from the clone.
- Run the WHOLE-REPO `km validate` on the clone before pushing; the per-file promote gate does not catch index-incompleteness.
- Commit ONLY the doc and the `_index.md` files it changed (`git add -- ...`, never `add -A`); never a terms file.
- `--author` is your identity. Mark the source at PR-open (step 8); stub it only via `contribute --finish` after merge.
- **A doc carrying `contribution:` has an open PR:** edit it on the PR head (step 2), never in your brain, or the personal and team copies diverge. `km validate` warns if a superseded doc still carries the marker.
