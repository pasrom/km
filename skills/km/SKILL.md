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
11. Copy `schema.base.yaml` and `validate.py` from this SKILL.md's directory into the repo (`schema.base.yaml` at the root; `validate.py` → `scripts/validate.py`). These are **km-owned** — refreshed via `/km upgrade`, never hand-edited
12. Write a minimal `schema.local.yaml` at the repo root for repo-specific `skip_prefixes` / `exempt_files` (start with just a header comment; lists here EXTEND the base), and copy `.pre-commit-config.template.yaml` → `.pre-commit-config.yaml`
13. Commit: `chore: initialize knowledge base conventions`

## Upgrade (`/km upgrade`)

Refresh the km-owned schema + validator without touching repo-specific overlays:

1. Copy `schema.base.yaml` and `validate.py` from this SKILL.md's directory over the repo's `schema.base.yaml` and `scripts/validate.py`
2. Leave `schema.local.yaml` untouched (repo-owned)
3. Report `meta.schema_version` before → after, then run `uv run scripts/validate.py` (fallback `python3`) to confirm the repo still passes with **0 errors**
4. Commit: `chore(km): upgrade schema/validator to <version>`

## `@` prefix — brains and shared resources

### Routing

- `@<name>` → resolve in this order: (1) `brains/<name>/` if it exists, (2) shared resource `<name>/` if it exists. First match wins
- `@all` → search current repo, then all brains, then all shared resources
- No `@` → current repo only

### Brains (peer knowledge bases)

- Located under `brains/<name>/` (git submodules)
- Sync: if `.git/modules/brains/<name>/FETCH_HEAD` is >15 min old, run `git submodule update --remote brains/<name>` (fail silently)

### Shared resources (self-describing repos)

Any git submodule **not** under `brains/` is a shared resource. Discover them from `.gitmodules`.

- On first `@<name>` query in a session, read `<name>/CLAUDE.md` to learn the repo's search scope, file types, commands, and citation format. Cache this for the rest of the session
- If `<name>/CLAUDE.md` is missing, fall back to recursive `.md` search in `<name>/`
- Sync: check `.git/modules/<name>/FETCH_HEAD` age before updating. Default threshold: 15 min. The resource's `CLAUDE.md` may specify a different interval

### `@all` sync

Before searching, sync all submodules that are stale (FETCH_HEAD older than their threshold):
1. `git submodule update --remote brains/` (fail silently)
2. For each shared resource: check FETCH_HEAD age against its threshold, update if stale (fail silently)

Then search in order: current repo → brains → shared resources.

### Citation format

- Brain sources: `[<name>@<hash>] path/file.md`
- Shared resource sources: `[<name>] path/file.md` (or as specified in the resource's `CLAUDE.md`)

## Brain management

- `brain add <url> [name]` → `git submodule add <url> brains/<name>`, validate CONVENTIONS.md exists, `git config submodule.recurse true`, commit
- `brain list` → table: name, URL, commit, last updated. Discover shared resources from `.gitmodules` and list them in a separate section
- `brain remove <name>` → confirm, `git submodule deinit -f` + `git rm -f`, commit

## Foreign-brain corrections (`brain fix @<name> ...`)

Errors in a foreign brain are fixed as a **PR against the brain's own repo**, never silently overridden in the parent.

Trigger: user says e.g. "fix this in @<brain>" / "das in @<brain> stimmt nicht", or an `@`-query would otherwise have to cite a known wrong statement — offer the PR instead. For shared resources, defer to the resource's `CONTRIBUTING.md` or `CLAUDE.md` if present.

### Workflow

Show the proposed diff and wait for explicit OK before any git write. Then, inside `brains/<name>/`:

1. `gh auth status` — abort if not authenticated
2. `git fetch origin && git checkout main && git pull --ff-only`
3. Branch `fix/km-<slug>` (or `docs/km-<slug>` for non-bug edits)
4. Apply the edit; follow the brain's own `CONVENTIONS.md` for frontmatter/naming and the Ripple update rules (see "Ripple update" below)
5. Commit per "Writing content" conventions
6. `git push -u origin <branch>` — if denied, `gh repo fork --remote=false`, push to fork, PR from fork
7. `gh pr create` — body must **paraphrase, not paste** any parent-repo source that surfaced the error
8. Return the PR URL

### Hard rules

- Never push to a brain's `main`, never `--force` push
- Never bump the parent's submodule pointer to an unmerged branch — wait for merge, then `git submodule update --remote brains/<name>` from the parent
- Never include parent-repo private content (memory, internal notes) verbatim in a brain PR
- If the brain has no `CONVENTIONS.md`, ask before editing — rules may live in `README` or `CONTRIBUTING`

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

`scripts/km_promote.py <slug> <source>` moves a note into the brain as a `status: review`
doc, **dedups by slug** (updates the existing topic doc, never a duplicate), gates the
candidate **before** placing it (a failing promote writes nothing), and prints a pointer to
paste back into personal scratch instead of a copy. `--replace` overwrites an existing served
doc and **invalidates its approval** (`status: review`, `approved_*` dropped); slug collisions
across folders are a hard stop.

Known limitations (advisory scope, follow-ups): whole-repo mode sees TRACKED files only;
per-file mode does not check reverse edges (a target flipping to `draft` is caught only in a
full run); link-form coverage is inline/reference/wiki/HTML/angle-bracket (not exhaustive).

## Rules

- Respond in the user's language
- Always cite sources (see "Citation format" above)
- Prefer current repo over brains in contradictions; prefer newer info; mention conflicts
- Never hallucinate — say if nothing found
