---
name: km
description: >-
  Knowledge management for a markdown knowledge base that follows CONVENTIONS.md:
  answer a question from it with sources, save a note, decision or meeting
  transcript with correct frontmatter and folder placement, update or supersede an
  existing page, run a consistency lint, and manage peer knowledge bases mounted as
  submodules, including corrections raised as a pull request against the other repo
  rather than edited in place. Use it whenever something should be written into the
  knowledge base or looked up from it, rather than writing a markdown file by hand.
  Triggers on: km, knowledge base, brain, save this, was steht im brain, ins brain
  speichern, dokumentiere das, Entscheidung festhalten, Meeting-Notiz, ADR, lint,
  "speicher das sauber ab", "was wissen wir über".
argument-hint: question, content, brain command, help, etc.
---

# Skill: km

$ARGUMENTS

## Setup

Read `CONVENTIONS.md` in the repo root. If missing, offer to initialize (`/km init`).

## Init (`/km init`)

When the user runs `/km init` (or confirms after "CONVENTIONS.md missing" prompt):

1. Ask for the user's author initials (e.g. `ABC`) — required for the `author` field default
2. Ask which domain folders to add (optional — skip to use `inbox/` only)
3. Read `CONVENTIONS.template.md` from the same directory as this SKILL.md
4. Replace `<initials>` placeholder with the provided initials
5. Add any domain folders to the Folder Structure table
6. Write `CONVENTIONS.md` to the repo root
7. Create `inbox/` folder with a minimal `_index.md` (frontmatter + one-line description)
8. Read `CLAUDE.template.md` from the same directory as this SKILL.md
9. Replace `<initials>` placeholder with the provided initials
10. Write `CLAUDE.md` to the repo root (skip if it already exists)
11. Copy `schema.base.yaml`, `validate.py` and `km_promote.py` from this SKILL.md's directory into the repo (`schema.base.yaml` at the root; the two scripts into `scripts/`). These are **km-owned** — refreshed via `/km upgrade`, never hand-edited
12. Write a minimal `schema.local.yaml` at the repo root for repo-specific `skip_prefixes` / `exempt_files` (start with just a header comment; lists here EXTEND the base), and copy `.pre-commit-config.template.yaml` → `.pre-commit-config.yaml`
13. Commit: `chore: initialize knowledge base conventions`

## Team brain init (`/km init --team`)

A **team brain** is a shared, served knowledge base: one maintainer merges, the team reads the repo,
everyone else contributes by fork PR or promotes from a personal brain. On top of a personal brain
it adds CI (validation, a generated `_index.md` Documents list, a served bundle, weekly staleness
demotion), domain folders instead of `inbox/`, and the single-writer rules. `team/km_team.py` next
to this SKILL.md does the rendering and copying, so the file list and placeholders live in one place.

1. Ask for: the brain's name (e.g. `QA-Brain`), a one-line description of the team (e.g. `the QA
   team`), the maintainer's initials, and the top-level folders with a one-line purpose each
   (suggest `process/`, `projects/`, `reference/` plus the team's own domains). Optionally one or
   two placement rules that decide which folder a doc goes to; without them each folder's purpose
   becomes its rule.
2. In the empty repo (or an empty clone of a fresh remote):
   `python3 <this dir>/team/km_team.py init . --name <name> --team "<desc>" --initials <XX>
   --folder process="<purpose>" --folder ... [--rule "<rule>" ...]` (plain `python3`, no packages
   needed). It refuses to run if any file it would write already exists, such as a README the host
   created with the repo: delete that first.
3. `git add -A`, then `uv run scripts/gen_index.py` (fallback `python3`, as for every script here;
   it reads tracked files only, so add first, and it fills the root and folder lists), `git add -A`
   and `uv run scripts/validate.py`: expect **0 errors / 0 warnings**.
4. Commit: `chore: initialize <name> (team served knowledge base)`.
5. Tell the user what km does not do: create the repo (private), push `main`, give the team **read**
   access and the maintainer write, and ask members to add the brain to their personal brain with
   `/km brain add <url>`. Branch protection on a private repo needs a paid GitHub plan; without it
   the single-writer rule is held by the permission model alone. Contributions arrive as fork PRs,
   and GitHub does not run Actions on fork PRs of a private repo until "Run workflows from fork pull
   requests" is enabled (repository or organization settings, Actions): without it those PRs get
   no CI.

## Upgrade (`/km upgrade`)

Refresh the km-owned schema + validator without touching repo-specific overlays:

1. **Personal brain:** copy `schema.base.yaml`, `validate.py` and `km_promote.py` from this SKILL.md's directory over the repo's `schema.base.yaml`, `scripts/validate.py` and `scripts/km_promote.py`
2. **Team brain** (`team_brain: true` in `schema.local.yaml`): instead run `uv run <this dir>/team/km_team.py upgrade .` (fallback `python3`). It refreshes every km-owned file, those three included, adds a missing team script, and leaves a workflow the repo deleted deleted. Show `git diff` of what it changed before committing; a local edit to one of these files is overwritten, so point it out and ask where it should go (usually upstream into km)
3. Leave `schema.local.yaml`, `CONVENTIONS.md`, `CLAUDE.md`, `README.md` and every `_index.md` untouched (repo-owned)
4. Report `meta.schema_version` before → after, then run `uv run scripts/validate.py` (fallback `python3`) to confirm the repo still passes with **0 errors**; on a team brain also run `uv run scripts/gen_index.py --check` (a newer generator may list more, e.g. subfolder indexes: run it without `--check` and commit the result)
5. Commit: `chore(km): upgrade schema/validator to <version>`

## `@` prefix — brains and shared resources

### Routing

- `@<name>` → resolve in this order: (1) `brains/<name>/` if it exists, (2) shared resource `<name>/` if it exists. First match wins
- `@all` → search current repo, then all brains, then all shared resources
- No `@` → current repo only

### Brains (peer knowledge bases)

- Located under `brains/<name>/` (git submodules)
- Sync: run `git submodule update --remote brains/<name>` when `git rev-parse --git-path modules/brains/<name>/FETCH_HEAD` is >15 min old (that resolves correctly inside a linked worktree too, where `.git` is a file). If the update aborts because the submodule has a dirty or branch-checked-out working tree, do NOT swallow it — report `brains/<name> skipped: dirty (run brain reset <name>)` so the drift stays visible instead of a brain that silently stops syncing

### Shared resources (self-describing repos)

Any git submodule **not** under `brains/` is a shared resource. Discover them from `.gitmodules`.

- On first `@<name>` query in a session, read `<name>/CLAUDE.md` to learn the repo's search scope, file types, commands, and citation format. Cache this for the rest of the session
- If `<name>/CLAUDE.md` is missing, fall back to recursive `.md` search in `<name>/`
- Sync: check `.git/modules/<name>/FETCH_HEAD` age before updating. Default threshold: 15 min. The resource's `CLAUDE.md` may specify a different interval

### `@all` sync

Before searching, sync all submodules that are stale (FETCH_HEAD older than their threshold):
1. `git submodule update --remote brains/`; surface any `brains/<name> skipped: dirty (run brain reset <name>)` rather than failing silently
2. For each shared resource: check FETCH_HEAD age against its threshold, update if stale (report a dirty skip, do not fail silently)

Then search in order: current repo → brains → shared resources.

### Citation format

- Brain sources: `[<name>@<hash>] path/file.md`
- Shared resource sources: `[<name>] path/file.md` (or as specified in the resource's `CLAUDE.md`)

## Brain management

- `brain add <url> [name]` → `git submodule add <url> brains/<name>`, validate CONVENTIONS.md exists, `git config submodule.recurse true`, commit
- `brain list` → table: name, URL, commit, last updated. Discover shared resources from `.gitmodules` and list them in a separate section
- `brain remove <name>` → confirm, `git submodule deinit -f` + `git rm -f`, commit
- `brain reset <name>` → repair a drifted submodule (parent shows `+` / ` m`, or it stopped syncing). (1) `git -C brains/<name> status` and SHOW it; STOP if there are dirty files — they may be unpushed work, never discard them silently. (2) on OK: `git submodule update --init --checkout --force brains/<name>` (back to the pinned commit) and `git -C brains/<name> worktree prune`. (3) delete leftover local `fix/km-*` / `docs/km-*` branches whose PR has merged. With the throwaway-clone `brain fix` below, new drift no longer happens

## Foreign-brain corrections (`brain fix @<name> ...`)

Errors in a foreign brain are fixed as a **PR against the brain's own repo**, never silently overridden in the parent.

Trigger: user says e.g. "fix this in @<brain>" / "das in @<brain> stimmt nicht", or an `@`-query would otherwise have to cite a known wrong statement — offer the PR instead. For shared resources, defer to the resource's `CONTRIBUTING.md` or `CLAUDE.md` if present.

### Workflow

The fix is made in a THROWAWAY clone, never in the mounted `brains/<name>/` working tree, so that
tree stays on its pinned commit and the parent never drifts (no stray branch, no dirty pointer).
Show the proposed diff and wait for explicit OK. **Each step below runs in a fresh shell** — do not
rely on env vars or an `EXIT` trap surviving between steps; use a FIXED working dir you retype
verbatim in every command and delete explicitly at the end.

1. `gh auth status` — abort if not authenticated.
2. Pick a branch name `km-<short>-<YYYYMMDD>` (the date avoids colliding with a leftover branch) and a
   fixed working dir, e.g. `/tmp/km-fix-<name>`, reused literally below.
3. Clone the brain and detach (no local branch; the brain's real default branch is used):
   ```
   rm -rf /tmp/km-fix-<name>
   git clone "$(git -C brains/<name> remote get-url origin)" /tmp/km-fix-<name>
   git -C /tmp/km-fix-<name> checkout --detach origin/HEAD
   ```
4. Apply the edit under `/tmp/km-fix-<name>`; follow the brain's own `CONVENTIONS.md` for
   frontmatter/naming and the Ripple update rules (see "Ripple update" below). Commit there per "Writing content".
5. Push straight to a remote branch, no local branch: `git -C /tmp/km-fix-<name> push origin "HEAD:refs/heads/km-<short>-<YYYYMMDD>"`. If push is denied: `gh repo fork --remote=false <owner>/<repo>`, then push by URL: `git -C /tmp/km-fix-<name> push "https://github.com/<you>/<repo>.git" "HEAD:refs/heads/km-<short>-<YYYYMMDD>"`.
6. `gh pr create --head "km-<short>-<YYYYMMDD>"` (fork path: `--head "<you>:km-<short>-<YYYYMMDD>"`); the body must **paraphrase, not paste** any parent-repo source that surfaced the error.
7. Return the PR URL, then `rm -rf /tmp/km-fix-<name>`. The mounted submodule was never touched.

### Hard rules

- Never push to a brain's `main`, never `--force` push
- Never bump the parent's submodule pointer to an unmerged branch — wait for merge, then `git submodule update --remote brains/<name>` from the parent
- Never edit the mounted `brains/<name>/` working tree; every correction runs in the throwaway clone above (that is what keeps the parent drift-free). If a mounted submodule is already drifted, repair it with `brain reset <name>`
- Never include parent-repo private content (memory, internal notes) verbatim in a brain PR
- If the brain has no `CONVENTIONS.md`, ask before editing — rules may live in `README` or `CONTRIBUTING`

## Consuming vs. authoring a mounted brain

A `brains/<name>/` submodule is a **read-only, pinned mirror**: query it, cite it, resolve uphill
links against it, never write in it.

- **Read / cite** → the mounted submodule (pinned); a `[name@hash]` citation names a commit everyone can resolve.
- **Occasional correction** to a foreign brain → the throwaway-clone `brain fix` flow above; the submodule is untouched.
- **You are a PRIMARY author** of a brain (a team brain you feed regularly) → do NOT author it through a submodule. Keep a **standalone clone** of that brain and work there: `git switch -c <ticket>` for one change, or `git worktree add ../<brain>-<ticket> -b <ticket>` off that clone for two at once. Merges land in the brain's own repo; a personal brain only ever *reads* it (mounted submodule, or just point at the sibling clone).
- **Contribute without write access** (you have READ on a shared/team brain) → `contribute @<name>` below: the throwaway-clone + PR (fork PR if read-only) flow, with the doc gated by the target brain's rules.

Caveat when a brain you author in **itself mounts brains**: a fresh linked worktree has EMPTY
submodule dirs until `git submodule update --init`, and the sync-staleness path is
`git rev-parse --git-path modules/brains/<name>/FETCH_HEAD` (in a linked worktree `.git` is a file,
so a literal `.git/modules/...` path is wrong).

## Contributing content to a brain (`contribute @<name> ...`)

Add or update a doc in a brain you have READ (not write) on, e.g. a shared team brain, from your own
brain. Same throwaway-clone + PR recipe as `brain fix`; the edit is a **cross-repo `km_promote`**, so
the doc is placed and gated by the TARGET brain's schema.

**Prerequisites and invariants.** The target is mounted (`brain add <url>` first) so you can read/cite
it and so `--finish` can point at it. The source is a doc in YOUR brain: refuse a source under
`brains/<other>/` (route that to `brain fix`). **Each step runs in a fresh shell** — use a FIXED
working dir retyped verbatim below (no `mktemp`+trap), deleted at the end. Show the proposed doc and
wait for explicit OK. Then:

1. `gh auth status`. Choose a branch name `<BR>` (a ticket key if there is one, else a short slug plus
   date; a ticket is NOT required) and a fixed working dir `/tmp/km-contrib-<slug>`, reused below.
2. Clone the target and detach:
   ```
   rm -rf /tmp/km-contrib-<slug>
   git clone "$(git -C brains/<name> remote get-url origin)" /tmp/km-contrib-<slug>
   git -C /tmp/km-contrib-<slug> checkout --detach origin/HEAD
   ```
   To ADD to an already-open contribution, `checkout --detach origin/<BR>` instead, and in step 7 skip
   `gh pr create` if `gh pr list --head <BR>` already shows one.
3. **Trusted gate.** Copy your OWN km-owned `scripts/validate.py`, `scripts/km_promote.py` and
   `schema.base.yaml` into the clone (the target's `schema.local.yaml` stays), so trusted code gates
   against the target's schema rather than the clone's scripts. (A `meta.schema_version` mismatch is
   only a warning.)
4. **Terms hand-off.** If the target's `schema.local.yaml` sets `gate.forbidden_terms_file`, that file
   is out of git and the target's maintainer distributes it; put it at the path the target names,
   inside the clone, before promoting. If you cannot get it, STOP — by design, the leak check must not
   silently disable.
5. Promote the source into the clone (cross-repo mode auto-applies: `--author` from YOUR identity,
   source-repo refs/links stripped or refused):
   ```
   python3 /tmp/km-contrib-<slug>/scripts/km_promote.py <slug> "<ABS-path-to-source-in-your-brain>.md" \
       --folder <target-folder> --author <your-initials> [--ticket KEY] [--type T]
   ```
   To UPDATE a doc already `accepted` on the target, add `--replace` (the PR then shows the approval
   drop, which IS the review signal). A doc already in `review` on the target cannot be re-promoted;
   edit it in the clone as in `brain fix`.
6. Track the doc so `gen_index` sees it, regenerate the indexes, run the whole-repo gate, then commit
   ONLY the doc and the `_index.md` files that changed. If `<target-folder>` is new, first write its
   `_index.md` by hand (frontmatter with a `description:`, an empty `## Documents` heading) and track it
   too: a team brain's generator refuses a folder with docs but no index, and the parent folder's list
   gains a link to the new one.
   ```
   git -C /tmp/km-contrib-<slug> add -- <target-folder>/<slug>.md   # track it FIRST (and a new folder's _index.md): gen_index / check_index read git ls-files
   if [ -f /tmp/km-contrib-<slug>/scripts/gen_index.py ]; then python3 /tmp/km-contrib-<slug>/scripts/gen_index.py
   else echo "no gen_index: add the doc to its folder's _index.md by hand"; fi
   git -C /tmp/km-contrib-<slug> add -u -- '*_index.md'   # every index the generator rewrote, parents included
   python3 /tmp/km-contrib-<slug>/scripts/validate.py    # WHOLE-REPO gate; the per-file promote gate never sees index-incomplete. Fix any error.
   git -C /tmp/km-contrib-<slug> diff --cached --name-only   # MUST list ONLY the doc + _index.md files; the copied scripts/schema (and a terms file) stay UNSTAGED
   git -C /tmp/km-contrib-<slug> commit -m "docs(<scope>): <what>"
   ```
   Never `git add -A`: the copied scripts, `schema.base.yaml` and any terms file must NOT be committed.
   `gen_index.py` is TARGET code — read it before running. Hand-edit an index only in a brain without
   one: where CI runs `gen_index --check`, a hand-written list fails unless it matches the generator.
7. Push and open the PR: `git -C /tmp/km-contrib-<slug> push origin "HEAD:refs/heads/<BR>"` (fork path
   as in `brain fix` if push is denied), then `gh pr create --head "<BR>"`. Return the PR URL, then
   `rm -rf /tmp/km-contrib-<slug>`. **Leave the source in your brain until the PR merges** — do not stub
   a not-yet-merged contribution.

### `contribute --finish <PR-url>` (after the PR merges)

`gh pr view <PR> --json state,files` must show merged; take the merged path from `.files`. Then
`git submodule update --remote brains/<name>` to pin the brain to the merged state, and turn the
source in your brain into a redirect stub: keep its frontmatter but set `status: superseded` and
`superseded_by: brains/<name>/<merged-path>` (point at the MERGED content, canonical even if a
reviewer changed it on the branch), body a one-line pointer. Commit that in your brain (the stub plus
the bumped submodule pointer). Before the sync `superseded_by` only warns; after, it resolves.

### Hard rules

- Prerequisite: the target is mounted (`brain add` first); the source is a doc in YOUR brain, never one under `brains/`.
- Each step is a fresh shell: a FIXED working dir, no `mktemp`+trap; `rm -rf` it at the end.
- Gate with YOUR km-owned `validate.py`/`km_promote.py` copied into the clone; treat the target's other scripts (`gen_index.py`) as target code (read before running; step 6 says when a hand-edited index is acceptable).
- Run the WHOLE-REPO `validate.py` in the clone before pushing; the per-file promote gate does not catch index-incompleteness.
- Commit ONLY the doc and the `_index.md` files it changed (`git add -- ...`, never `add -A`); never the copied scripts, `schema.base.yaml`, or a terms file.
- `--author` is your identity; leave the source until merge, then `contribute --finish`.

## Search strategy

1. Frontmatter tags (skip `status: obsolete/superseded` unless asked)
2. Folder structure + `_index.md` files
3. H1/H2 headings scan, read matching files
4. Full-text grep (only if needed)
5. Follow `related:` / `supersedes:` cross-references

Response: summary, sources (with paths), recency, gaps, related topics.

### Query-to-wiki

After answering, check: did the response synthesize information from 3+ sources or establish connections not found in any single file? If yes, offer to save the synthesis as a `type: summary` document. Use the standard save flow (frontmatter, folder placement, ripple update). The `related:` field should list all source files used in the synthesis.

Do not offer for simple lookups or single-source answers.

## Writing content

All writes follow CONVENTIONS.md for frontmatter, folder placement, and naming. Always confirm before writing. Commit with `docs(<scope>): <description>`.

- **Status:** New documents always start as `status: draft`. Never set `status: accepted` without explicit user confirmation — always ask first.
- **Save:** Auto-detect type (note/concept/decision/transcript). Unclear folder → `inbox/`
- **Decision:** Extract title, context, alternatives, consequences. Use `type: decision`
- **Transcript:** Extract decisions + action items. Sections: Attendees, Summary, Decisions, Actions, Transcript
- **Update:** Preserve frontmatter, update `date` field, show diff
- **Archive:** Set `status: obsolete` or `superseded` + `superseded_by:` field. Never delete

### Ripple update (after every save/update)

After writing the main file, update related pages before committing:

1. **Cross-reference:** Find up to 5 related files (ranked by: shared `project:` > shared tags > same folder). Add the new file's repo-root-relative path to their `related:` frontmatter (create the field if absent). Only add genuinely useful links
2. **Update `_index.md`:** Ensure the file is listed in its folder's `_index.md` and in the matching `project:` folder's `_index.md` (if they exist — do not create new `_index.md`)
3. **Confirm:** List all proposed ripple updates and wait for user approval before committing

Ripple is **one level deep** — never cascade into further ripple updates. Skip ripple when no tags, `related:`, or `project:` fields changed and no new headings were added.

## Lint (`/km lint`)

Periodic health check for knowledge base consistency. Run all checks and report findings grouped by severity.

### Scope

Collect only **git-tracked** `.md` files via `git ls-files -z '*.md'`. Exclude files exempt from frontmatter per CONVENTIONS.md, plus `_index.md` files, `brains/`, and all shared resource submodules (they have their own conventions).

**Prefer a machine-readable validator when present.** If the repo root has `schema.base.yaml` (or a legacy `schema.yaml`) and `scripts/validate.py`, run `uv run scripts/validate.py` (fallback: `python3 scripts/validate.py`) and use its output verbatim as the 🔴 Errors section — it is deterministic, merges `schema.local.yaml` over the base, and also catches non-`/km` writers. The prose checks below are the **fallback** for repos without a validator, and still supply the 🟡 Warnings / 🔵 Suggestions the script does not cover.

### Checks

**🔴 Errors** (break conventions — must fix):
- Missing required frontmatter fields (per CONVENTIONS.md Frontmatter Schema)
- Invalid `type` or `status` values (not in CONVENTIONS.md schema)
- `superseded` status without `superseded_by:` field (or vice versa)
- If file A has `supersedes: B.md`, file B must have `status: superseded` and `superseded_by: A.md`
- `related:`, `supersedes:`, `superseded_by:` pointing to non-existent files. Resolve repo-root-relative first, then file-relative
- Broken markdown links (`[text](path.md)`) to local files

**🟡 Warnings** (reduce quality — should fix):
- `status: draft` documents with no git commits touching them in >30 days (use `git log -1 --format=%ct -- <file>`)
- Folders containing `.md` files but no `_index.md`
- `_index.md` that doesn't link all non-index `.md` files in its folder
- Files in `inbox/` with first git commit date >14 days ago

**🔵 Suggestions** (nice to fix):
- Orphaned pages: no incoming `related:` references AND not listed in any `_index.md`
- Empty `tags: []` array

### Output format

```
## KB Lint Report — <date>

### 🔴 Errors (<count>)
...
### 🟡 Warnings (<count>)
...
### 🔵 Suggestions (<count>)
...
### Summary
<total files> files, <errors> errors, <warnings> warnings, <suggestions> suggestions
```

## Gate — optional serving-lint (opt-in)

An **advisory** extension of `validate.py` for brains whose content is read by a wider
audience or an AI/RAG layer. Off by default (existing brains unaffected, bit-identical).
It catches honest mistakes before commit; it is **not** an enforcement boundary (a determined
author can flip a field or disable it — the real boundary is the publish/release step).

Enable in `schema.local.yaml` (repo overlay; never touched by `/km upgrade`):

```yaml
gate:
  enabled: true
  served_status: accepted          # which status counts as "served/shared"
  customer_audience: customer      # audience value that must not name other customers
  forbidden_terms_file: .gate-terms.txt   # gitignored: keep real customer names out of the repo
  email_allowlist: [your-domain.com]
  # forbidden_terms: [ACME]        # or inline (test/demo only)
```

Checks, keyed per concern (so an internal `accepted` doc may legitimately name a customer):
- **secret** (ERROR) — AWS/GitHub keys, private-key headers in ANY tracked doc (incl. exempt/reserved
  files like README/_index; excl. skip_prefixes) — a key needs no frontmatter.
- **leak** (ERROR) — forbidden terms + external emails only in an `audience: customer` doc.
- **bergab** (ERROR) — a served doc links to an unfinished (`draft`/`review`) doc; a link to
  `superseded`/`obsolete` is a WARNING. Reuses the `status`/`audience` frontmatter, no new fields.
- **freshness** (WARNING) — a served doc past its `review_by`.

Findings are redacted. The link scan strips code fences; the secret/leak scans see the whole document
(stricter, so a forbidden term inside a code sample still fails). A configured-but-missing
`forbidden_terms_file` is a WARNING, not silent. Malformed OR unknown `gate:` config fails fast.

### Promote (`km_promote.py`)

`scripts/km_promote.py <slug> <source> --folder DIR [--type T] [--title T] [--author A] [--owner O] [--ticket KEY] [--replace] [--stub-source]`
moves a note into the brain as a `status: review` doc, **dedups by slug** (updates the existing
topic doc, never a duplicate), gates the candidate **before** placing it (a failing promote writes
nothing), and prints a pointer to paste back into personal scratch instead of a copy. The source's
own frontmatter is **carried forward** (`type`/`title`/`author`/`tags`/…) and its `status`/approval/
supersede fields are dropped and re-stamped, so a source that already has frontmatter never yields a
double header; `--type`/`--title`/`--author` override it. A **new** doc needs `--folder` (no default)
and a resolvable `type`+`author`. Author resolves `--author` > source frontmatter > `author_default`
(a repo-local default in `schema.local.yaml`). **Cross-repo** (the source lives outside this repo,
e.g. promoting from a personal brain into a team brain): `--author` is required (the target's
`author_default` would mis-attribute the source's author), `related`/`sources`/`translates`/`project`
are dropped (they point at the source repo) and any body link into the source repo is refused;
`--ticket KEY` (optional, any key, need not be a Jira ticket) stamps the `ticket` field. `--replace`
overwrites an existing served doc and
**invalidates its approval** (`status: review`, `approved_*` dropped), but a `verbatim-block` is
**never** `--replace`d (change it only via supersede); slug collisions across folders are a hard stop.
`--stub-source` rewrites an in-repo source note into a superseded redirect stub pointing at the
promoted doc (a source in another repo is left untouched), so the knowledge lives once, not twice.

Known limitations (advisory scope, follow-ups): whole-repo mode sees TRACKED files only;
per-file mode does not check reverse edges (a target flipping to `draft` is caught only in a
full run); link-form coverage is inline/reference/wiki/HTML/angle-bracket (not exhaustive).

## Index completeness (opt-in)

Set `check_index: true` at the top of `schema.local.yaml` to have `validate.py` lint each
folder's `_index.md` deterministically (WARNINGS, non-fatal): every folder with **content docs**,
or with a subfolder that has an `_index.md`, must have an `_index.md` (`index-missing`), each
`_index.md` must link every content doc in its own folder and the `_index.md` of each direct
subfolder (`index-incomplete`), and no `_index.md` may link a missing file (`index-dead-link`,
scanned on every `_index.md`, including navigation hubs with no direct docs). "Content docs"
excludes `_index.md`, exempt files (README/CLAUDE/CONVENTIONS/SKILL), and reserved files
(index.md/log.md) — the same notion `is_validatable()` uses. Linking each subfolder's index
makes every folder reachable from the one above it; the root `_index.md` is optional, and where it
exists it must link the top-level folders that have an index. Link targets
resolve against the git-tracked file set (clone-stable, case-exact; a link into a `skip_prefixes`
folder is therefore not dead) — document-relative first, then repo-root. To leave a folder out of
the index lint *without* dropping it from article validation, list it under `index_skip_prefixes`
in `schema.local.yaml` (e.g. generated or vendored trees). Whole-repo only: skipped on per-file
(pre-commit) runs. Off by default (a non-bool `check_index` is a config error). This
machine-enforces the `/km lint` "`_index` doesn't link all docs" rule; `_index.md` files stay
excluded from article-schema validation.
Known limitations (by design): a dead `[[wiki]]` slug is not reported as `index-dead-link`
(flagging bare-word targets would risk false positives), and unusual inline-link
syntaxes (a parenthetical title, a query string, an angle-bracketed path combined with a title)
may be misparsed by the shared markdown-link scanner.

## Rules

- Respond in the user's language
- Always cite sources (see "Citation format" above)
- Prefer current repo over brains in contradictions; prefer newer info; mention conflicts
- Never hallucinate — say if nothing found
