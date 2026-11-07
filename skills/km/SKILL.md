---
name: km
description: >-
  Knowledge management for a markdown knowledge base that follows CONVENTIONS.md:
  answer a question from it with sources; save a note, decision or meeting
  transcript with correct frontmatter and folder placement; update or supersede a
  page; run a consistency lint; manage peer knowledge bases mounted as submodules,
  with corrections raised as a pull request against their repo, not edited in place.
  Review a doc and sign it off where an AI review may, and prepare a pull request:
  review, fold the fixes, label what it still needs. Use it for every write to or
  lookup in the knowledge base instead of writing a markdown file by hand.
  Triggers on: km, knowledge base, brain, save this, was steht im brain, ins brain
  speichern, dokumentiere das, Entscheidung festhalten, Meeting-Notiz, ADR, lint,
  "speicher das sauber ab", "was wissen wir über", check my setup, "prüfe meine
  Einrichtung", km review, "review mein Dokument", freigeben, km pr, "PR fürs
  Brain vorbereiten", km queue, review queue, "was wartet auf Freigabe".
argument-hint: question, content, brain command, help, etc.
---

# Skill: km

$ARGUMENTS

## Setup

Read `CONVENTIONS.md` in the repo root. If missing, offer to initialize (`/km init`).

**Running km.** `bin/km` next to this SKILL.md runs km from this installed plugin, written `km`
below; `km --help` lists the commands, and all take `--root DIR`. Brains carry no km code: CI and
the pre-commit hook install the km release the brain pins, by its commit (`pasrom/km@<sha> # vX.Y.Z`,
so a moved tag cannot change what runs), and so does `km` here: in a brain that pins another version
it runs that commit through `uvx`, so results match CI (`KM_LOCAL=1` keeps the plugin's; `init`,
`upgrade`, `doctor`, `list` and `sync` always run the plugin's km, so `km upgrade` needs no `KM_LOCAL`). Without uv,
offline, for a pin to a movable tag, or when the workflows disagree, it runs the plugin's km and warns;
`/km upgrade` the brain then.

**Keeping the copy current.** A copy of the brain goes stale: answers then come from old knowledge
and new work starts on an old base. `km sync` fetches the upstream brain (the remote `upstream`,
else a fork's parent, else origin) and only ever fast-forwards: the checked-out default branch on a
clean tree, a fork's default branch on the host, and the mounted brains to the commit the brain
pins (a pin moves only through the host's automation and a reviewed PR). Everything else it only
reports, with how far behind. The plugin runs it when a session starts in a brain, and its lines
are then in your context. Before answering a question from the brain, run
`km sync --quiet --max-age 15m` (nothing happens within 15 minutes of the last run; it prints only
what changed or needs attention). Before creating a page or a branch, run `km sync`, so the work
starts from the current upstream. When it reports `branch <X> is <N> commits behind upstream
<default>; rebase it when you are ready`, tell the user and offer the rebase; run
`git rebase upstream/<default>` (`origin/<default>` without a fork) only on their OK and on a
clean tree (`git status --porcelain --ignore-submodules=all` prints nothing), never a reset or a
force. A default branch with commits of its own, a dirty tree, a mount with changes of its own or
a diverged fork are the user's call too: pass the note on and do nothing else.

**GitHub access.** Every GitHub step in this skill uses `gh` (with a local clone where one exists)
when `gh auth status --hostname github.com` succeeds; check once per session and again after a
`gh auth login`. Only without it, read through any MCP server exposing GitHub tools such as
`pull_request_read` (prefer a read-only one if several are loaded), as in "Reading GitHub through
MCP" (`${CLAUDE_SKILL_DIR}/reference/github-reads.md`). When gh gets HTTP 401, 403 or 404 for a repo, read that repo through MCP for the rest of the
task and say so in the answer; a network error is no reason to switch. With neither, name what was
not read under gaps, never guess. Every write (push, fork, PR create or edit, labels, PR comments,
reviews) uses git and gh only, never an MCP write tool; without gh, say the write cannot be done.

## `@` prefix — brains and shared resources

### Routing

- `@<name>` → resolve in this order: (1) `brains/<name>/` if it exists, (2) shared resource `<name>/` if it exists. First match wins
- `@all` → search current repo, then all brains, then all shared resources
- No `@` → current repo only

### Citation format

- Brain sources: `[<name>@<hash>] path/file.md`
- Shared resource sources: `[<name>] path/file.md` (or as specified in the resource's `CLAUDE.md`)
- Open pull request sources: `[<owner>/<repo>#<N>, not merged, <author>, <last update>] path/file.md`
  (see "Open pull requests" in `${CLAUDE_SKILL_DIR}/reference/github-reads.md`)

## Consuming vs. authoring a mounted brain

A `brains/<name>/` submodule is a **read-only, pinned mirror**: query it, cite it, resolve uphill
links against it, never write in it.

- **Read / cite** → the mounted submodule (pinned); a `[name@hash]` citation names a commit everyone can resolve.
- **Occasional correction** to a foreign brain → the throwaway-clone `brain fix` flow (`${CLAUDE_SKILL_DIR}/reference/brains.md`); the submodule is untouched.
- **You are a PRIMARY author** of a brain (a team brain you feed regularly) → do NOT author it through a submodule. Keep a **standalone clone** of that brain and work there: `git switch -c <ticket>` for one change, or `git worktree add ../<brain>-<ticket> -b <ticket>` off that clone for two at once. Merges land in the brain's own repo; a personal brain only ever *reads* it (mounted submodule, or just point at the sibling clone).
- **Contribute without write access** (you have READ on a shared/team brain) → `contribute @<name>` (`${CLAUDE_SKILL_DIR}/reference/brains.md`): the throwaway-clone + PR (fork PR if read-only) flow, with the doc gated by the target brain's rules.

Caveat when a brain you author in **itself mounts brains**: a fresh linked worktree has EMPTY
submodule dirs until `km sync` (or `git submodule update --init`) checks them out at their pins.

## Search strategy

1. Frontmatter tags (skip `status: obsolete/superseded` unless asked). A question about the docs
   themselves (what lies in a folder, what waits for sign-off, what is overdue for review) is one
   `km list` call, not a read of each file: `km list <folder>`; waiting for a person's sign-off:
   `--status review --signoff human`; overdue: `--status accepted --due today`; also `--tag X`,
   `--fields path,title,owner`, `--json`. A mounted brain: `km list --root <its folder>`.
2. Folder structure + `_index.md` files
3. H1/H2 headings scan, read matching files
4. Full-text grep (only if needed)
5. Follow `related:` / `supersedes:` cross-references

Response: summary, sources (with paths), recency, gaps, related topics.

### Query-to-wiki

After answering, check: did the response synthesize information from 3+ sources or establish connections not found in any single file? If yes, offer to save the synthesis as a `type: summary` document. Use the standard save flow (frontmatter, folder placement, ripple update). The `related:` field should list all source files used in the synthesis. Pin them in `sources:` too and run `km repin` on the new doc (see "Source pins" in `${CLAUDE_SKILL_DIR}/reference/pins-and-cites.md`).

Do not offer for simple lookups or single-source answers. Never offer it on content from an open PR, and never base a `brain fix` on one alone: where a PR
shows a merged doc is wrong, say so and point at the PR.

## Writing content

All writes follow CONVENTIONS.md for frontmatter, folder placement, and naming. Always confirm before writing. Commit with `docs(<scope>): <description>`.

- **Status:** New documents always start as `status: draft`. Never set `status: accepted` without explicit user confirmation — always ask first. Sign a doc off with `km approve <doc> --by <initials>` (see "Approval" in `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`), not by editing `status` by hand.
- **Save:** Auto-detect type (note/concept/decision/transcript). Unclear folder → `inbox/`
- **Decision:** Extract title, context, alternatives, consequences. Use `type: decision`
- **Transcript:** Extract decisions + action items. Sections: Attendees, Summary, Decisions, Actions, Transcript
- **Update:** Preserve frontmatter, update `date` field, show diff. A doc with `contribution:` is edited on its PR head instead (hard rule under "Contributing content" in `${CLAUDE_SKILL_DIR}/reference/brains.md`)
- **Archive:** Set `status: obsolete` or `superseded` + `superseded_by:` field. Never delete

### Ripple update (after every save/update)

After writing the main file, update related pages before committing:

1. **Cross-reference:** Find up to 5 related files (ranked by: shared `project:` > shared tags > same folder). Add the new file's repo-root-relative path to their `related:` frontmatter (create the field if absent). Only add genuinely useful links. When the brain sets `gate.project_prefix`, never add a path under a project folder to a doc outside that folder, nor rank by a `project:` code there: the gate reports a project code outside its own folder, frontmatter included. Project notes link up to neutral docs, not the other way
2. **Update `_index.md`:** Ensure the file is listed in its folder's `_index.md` and in the matching `project:` folder's `_index.md` (if they exist — do not create new `_index.md`)
3. **Confirm:** List all proposed ripple updates and wait for user approval before committing

Ripple is **one level deep** — never cascade into further ripple updates. Skip ripple when no tags, `related:`, or `project:` fields changed and no new headings were added.

## Reference files

The flows below are in reference files, read when a request needs them (paths are relative to this
skill, forward slashes on every platform):

- `${CLAUDE_SKILL_DIR}/reference/setup.md`: setup check (`/km doctor`, "check my setup"), `/km init`, `/km init --team`, `/km upgrade`
- `${CLAUDE_SKILL_DIR}/reference/brains.md`: mounted brains and shared resources, pin-bump PR, brain management (`brain add`, `list`, `remove`, `reset`), `brain fix @<name>`, `contribute @<name>` and `contribute --finish`
- `${CLAUDE_SKILL_DIR}/reference/github-reads.md`: open pull requests as a source, reading GitHub through MCP
- `${CLAUDE_SKILL_DIR}/reference/validate-and-gate.md`: `/km lint`, the gate, `km promote`, index completeness
- `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`: `/km review`, `/km pr`, review of a PR you did not open, `km approve`
- `${CLAUDE_SKILL_DIR}/reference/queue.md`: `/km queue`
- `${CLAUDE_SKILL_DIR}/reference/pins-and-cites.md`: `km repin`, `km cite add`, `km cites check`

## Rules

- Respond in the user's language
- Always cite sources (see "Citation format" above)
- Prefer current repo over brains in contradictions; prefer newer info; mention conflicts
- Never hallucinate — say if nothing found
