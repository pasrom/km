---
name: km
description: >-
  Knowledge management for a markdown knowledge base ("brain") that follows CONVENTIONS.md.
  Use it for every lookup in or write to a brain rather than handling its markdown by hand:
  answer a question from the brain with sources; save a note, decision or meeting transcript
  with validated frontmatter; update or supersede a page; lint; mount peer brains and correct
  them by pull request; review a brain doc or brain PR and sign it off where an AI may; prepare
  a brain PR; the brain's review queue; set up, check, upgrade or sync a brain. Triggers: km,
  brain, knowledge base, "save this", "was steht im brain", "ins brain speichern", "dokumentiere
  das", "Entscheidung festhalten", Meeting-Notiz, ADR, "was wissen wir über", "check my setup",
  "prüfe meine Einrichtung", "review mein Dokument", freigeben, "PR fürs Brain", "was wartet auf
  Freigabe".
argument-hint: question, content, brain command, help, etc.
---

# Skill: km

$ARGUMENTS

## Rules

- Respond in the user's language
- Always cite sources (see "Citation format" below)
- Prefer current repo over brains in contradictions; prefer newer info; mention conflicts
- Never hallucinate — say if nothing found
- Never push to a brain's default branch and never `--force` push; the one exception is `--force-with-lease=<branch>:<pushed-head>` to your own open PR after `/km pr` folded it
- Never edit a mounted `brains/<name>/` working tree (a hook refuses the file-edit tools there; a shell edit is yours to refuse): a correction goes through `brain fix` or `contribute` in a throwaway clone; a drifted mount goes back with `brain reset`
- Never set `status: accepted` by hand: `km approve` on the user's OK, committed on its own on top of the content commits; an edit to an accepted doc sends it back to review in the same commit (`km demote <doc>`)
- A doc carrying `contribution:` has an open PR: edit it on the PR head, never in your brain
- Never include parent-repo private content (memory, internal notes) verbatim in a brain PR
- After a compaction only this file is re-attached and what you read from the reference files is gone: before you continue a flow, read its files again

## What to read for a request

Read every file a row names with the Read tool, in full, before the flow starts (forward slashes on every platform).

| Request (`/km ...` or in prose) | Read |
| :- | :- |
| a question, "was wissen wir über" | this file: "Search strategy", "Routing"; open PRs as a source: `${CLAUDE_SKILL_DIR}/reference/github-reads.md` |
| `@<name> ...`, `@all ...` | as a question, plus `${CLAUDE_SKILL_DIR}/reference/brains.md` (mounts, shared resources, `@all` sync) |
| content to save, `update <doc>: ...`, a decision, a transcript, archive a page | this file: "Writing content" |
| `help` | this table, one line per row, then `km --help` for the commands |
| `doctor`, "check my setup", "prüfe meine Einrichtung", `init`, `init --team`, `upgrade` | `${CLAUDE_SKILL_DIR}/reference/setup.md` |
| `sync` | this file: "Keeping the copy current", then `${CLAUDE_SKILL_DIR}/reference/setup.md` |
| `lint`, `validate`, the gate, `promote`, index completeness | `${CLAUDE_SKILL_DIR}/reference/validate-and-gate.md` |
| `review <doc>...`, `approve <doc>...` | `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`, `${CLAUDE_SKILL_DIR}/reference/pins-and-cites.md` (`pin:` findings) |
| `pr`, review a brain PR | `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md` (without gh also `${CLAUDE_SKILL_DIR}/reference/github-reads.md`) |
| `queue`, `queue @<name>`, `queue @all`, "was wartet auf Freigabe" | `${CLAUDE_SKILL_DIR}/reference/queue.md` first (it holds the flow), then `${CLAUDE_SKILL_DIR}/reference/github-reads.md`, `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md` |
| `brain add <url>`, `brain list`, `brain remove`, `brain reset`, a pin-bump PR | `${CLAUDE_SKILL_DIR}/reference/brains.md` |
| `brain fix @<name> ...`, "fix this in @<name>", `contribute @<name> ...`, `contribute --finish <PR>` | `${CLAUDE_SKILL_DIR}/reference/brains.md`, `${CLAUDE_SKILL_DIR}/reference/review-and-pr.md`, `${CLAUDE_SKILL_DIR}/reference/validate-and-gate.md` |
| `repin`, `cite add`, `cites check`, a `pin:` or `cite:` warning | `${CLAUDE_SKILL_DIR}/reference/pins-and-cites.md` |

## Setup

Read `CONVENTIONS.md` in the repo root. If missing, offer to initialize (`/km init`).

**Running km.** `bin/km` next to this SKILL.md runs km from this installed plugin, written `km` below; `km --help` lists the commands, and all take `--root DIR`. In a brain that pins another km version it runs that one ("Running km and keeping the copy current" in `${CLAUDE_SKILL_DIR}/reference/setup.md`).

**Keeping the copy current.** Before answering a question from the brain, run `km sync --quiet --max-age 15m`; before creating a page or a branch, run `km sync`. Pass on what it reports and offer the rebase it names, only on the user's OK and a clean tree; never a reset, a force or a moved mount ("Running km and keeping the copy current" in `${CLAUDE_SKILL_DIR}/reference/setup.md`).

**GitHub access.** Every GitHub step in this skill uses `gh` (with a local clone where one exists) when `gh auth status --hostname github.com` succeeds; check once per session and again after a `gh auth login`. Only without it, read through any MCP server exposing GitHub tools such as `pull_request_read` (prefer a read-only one if several are loaded), as in "Reading GitHub through MCP" (`${CLAUDE_SKILL_DIR}/reference/github-reads.md`). When gh gets HTTP 401, 403 or 404 for a repo, read that repo through MCP for the rest of the task and say so in the answer; a network error is no reason to switch. With neither, name what was not read under gaps, never guess. Every write (push, fork, PR create or edit, labels, PR comments, reviews) uses git and gh only, never an MCP write tool; without gh, say the write cannot be done.

## `@` prefix — brains and shared resources

### Routing

- `@<name>` → resolve in this order: (1) `brains/<name>/` if it exists, (2) shared resource `<name>/` if it exists. First match wins
- `@all` → search current repo, then all brains, then all shared resources
- No `@` → current repo only

### Citation format

- Brain sources: `[<name>@<hash>] path/file.md`
- Shared resource sources: `[<name>] path/file.md` (or as specified in the resource's `CLAUDE.md`)
- Open pull request sources: `[<owner>/<repo>#<N>, not merged, <author>, <last update>] path/file.md` (see "Open pull requests" in `${CLAUDE_SKILL_DIR}/reference/github-reads.md`)

## Consuming vs. authoring a mounted brain

A `brains/<name>/` submodule is a **read-only, pinned mirror**: query it, cite it, resolve uphill links against it, never write in it.

- **Read / cite** → the mounted submodule (pinned); a `[name@hash]` citation names a commit everyone can resolve.
- **Occasional correction** to a foreign brain → the throwaway-clone `brain fix` flow (`${CLAUDE_SKILL_DIR}/reference/brains.md`); the submodule is untouched.
- **You are a PRIMARY author** of a brain (a team brain you feed regularly) → do NOT author it through a submodule. Keep a **standalone clone** of that brain and work there: `git switch -c <ticket>` for one change, or `git worktree add ../<brain>-<ticket> -b <ticket>` off that clone for two at once. Merges land in the brain's own repo; a personal brain only ever *reads* it (mounted submodule, or just point at the sibling clone).
- **Contribute without write access** (you have READ on a shared/team brain) → `contribute @<name>` (`${CLAUDE_SKILL_DIR}/reference/brains.md`): the throwaway-clone + PR (fork PR if read-only) flow, with the doc gated by the target brain's rules.

Caveat when a brain you author in **itself mounts brains**: a fresh linked worktree has EMPTY submodule dirs until `km sync` (or `git submodule update --init`) checks them out at their pins.

## Search strategy

1. Frontmatter tags (skip `status: obsolete/superseded` unless asked). A question about the docs themselves (what lies in a folder, what waits for sign-off, what is overdue for review) is one `km list` call (`/km queue` is its own flow), not a read of each file: `km list <folder>`; waiting for a person's sign-off: `--status review --signoff human`; overdue: `--status accepted --due today`; also `--tag X`, `--fields path,title,owner`, `--json`. A mounted brain: `km list --root <its folder>`.
2. Folder structure + `_index.md` files
3. H1/H2 headings scan, read matching files
4. Full-text grep (only if needed)
5. Follow `related:` / `supersedes:` cross-references

Response: summary, sources (with paths), recency, gaps, related topics.

### Query-to-wiki

After answering, check: did the response synthesize information from 3+ sources or establish connections not found in any single file? If yes, offer to save the synthesis as a `type: summary` document. Use the standard save flow (frontmatter, folder placement, ripple update). The `related:` field should list all source files used in the synthesis. Pin them in `sources:` too and run `km repin` on the new doc (see "Source pins" in `${CLAUDE_SKILL_DIR}/reference/pins-and-cites.md`).

Do not offer for simple lookups or single-source answers. Never offer it on content from an open PR, and never base a `brain fix` on one alone: where a PR shows a merged doc is wrong, say so and point at the PR.

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
2. **Update `_index.md`:** Ensure the file is listed in its folder's `_index.md` and in the matching `project:` folder's `_index.md` (if they exist — do not create new `_index.md`). A `## Documents` list is generated: whenever a doc is added, moved or removed or its `title` or `description` changes, stage the doc, run `km gen-index` and commit the `_index.md` files it changed with it (a team brain's CI and pre-commit hook fail on a stale list)
3. **Confirm:** List all proposed ripple updates and wait for user approval before committing

Ripple is **one level deep** — never cascade into further ripple updates. Skip ripple when no tags, `related:`, or `project:` fields changed and no new headings were added; `km gen-index` (step 2) still runs after a `title` or `description` change.
