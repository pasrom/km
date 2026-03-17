---
name: km
description: Knowledge management — query, save, update, brain management, and more. Just describe what you need.
argument-hint: question, content, brain command, help, etc.
---

# Skill: km

$ARGUMENTS

## Setup

Read `CONVENTIONS.md` in the repo root. If missing, offer to initialize (`/km init`).

## Brain support (`@` prefix)

- `@name query` → search `brains/<name>/` (git submodule)
- `@all query` → search all brains + current repo
- No `@` → current repo only
- Before searching a named brain: if `.git/modules/brains/<name>/FETCH_HEAD` is >15 min old, run `git submodule update --remote brains/<name>` (fail silently)
- Before searching `@all`: run `git submodule update --remote brains/` to update all peer brains (fail silently)
- Cite brain sources as `[name@hash] path/file.md`

## Brain management

- `brain add <url> [name]` → `git submodule add <url> brains/<name>`, validate CONVENTIONS.md exists, `git config submodule.recurse true`, commit
- `brain list` → table: name, URL, commit, last updated
- `brain remove <name>` → confirm, `git submodule deinit -f` + `git rm -f`, commit

## Search strategy

1. Frontmatter tags (skip `status: obsolete/superseded` unless asked)
2. Folder structure + `_index.md` files
3. H1/H2 headings scan, read matching files
4. Full-text grep (only if needed)
5. Follow `related:` / `supersedes:` cross-references

Response: summary, sources (with paths), recency, gaps, related topics.

## Writing content

All writes follow CONVENTIONS.md for frontmatter, folder placement, and naming. Always confirm before writing. Commit with `docs(<scope>): <description>`.

- **Save:** Auto-detect type (note/concept/decision/transcript). Unclear folder → `inbox/`
- **Decision:** Extract title, context, alternatives, consequences. Use `type: decision`
- **Transcript:** Extract decisions + action items. Sections: Attendees, Summary, Decisions, Actions, Transcript
- **Update:** Preserve frontmatter, update `date` field, show diff
- **Archive:** Set `status: obsolete` or `superseded` + `superseded_by:` field. Never delete

## Rules

- Respond in the user's language
- Always cite sources. Brain sources: `[name@commit]`
- Prefer current repo over brains in contradictions; prefer newer info; mention conflicts
- Never hallucinate — say if nothing found
