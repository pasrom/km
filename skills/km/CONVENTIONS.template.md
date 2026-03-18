# CONVENTIONS.md

This file defines the rules every AI assistant must follow when working with this repository.

## Frontmatter Schema

Every markdown file (except CLAUDE.md, README.md, CONVENTIONS.md, and SKILL.md files) must have YAML frontmatter:

```yaml
---
title: "Descriptive title"
type: <note|decision|concept|transcript|artifact|summary>
date: YYYY-MM-DD
author: <initials>
status: <draft|accepted|superseded|obsolete>
tags: [tag1, tag2, tag3]
# Optional fields:
project: <project-name>
supersedes: <filename.md>
superseded_by: <filename.md>
related: [file1.md, file2.md]
participants: [name1, name2]
---
```

## Document Types

| Type | Purpose | Template |
|------|---------|----------|
| `concept` | Ideas, designs, evaluations, architecture | Problem → Solution → Implementation |
| `decision` | Architecture Decision Record (ADR) | Context → Options → Decision → Rationale |
| `note` | Unstructured notes, observations | Free-form, no template required |
| `transcript` | Meeting transcripts | Summary → Decisions → Actions → Raw transcript |
| `artifact` | Deliverables, specs, formal documents | Structured per content |
| `summary` | AI-generated summaries | Auto-generated with source references |

## Status Lifecycle

```
draft → accepted → superseded | obsolete
```

- `draft`: Work in progress
- `accepted`: Reviewed, current, valid
- `superseded`: Replaced by newer document (set `superseded_by:` field)
- `obsolete`: No longer relevant, no replacement

Obsolete/superseded documents are **never deleted** — they remain for historical context. AI ignores them in standard queries but can surface them when explicitly asked about history.

## Folder Structure

| Folder | Purpose |
|--------|---------|
| `inbox/` | Unsorted content — temporary landing zone |

<!-- Add domain-specific folders here, e.g.:
| `concepts/` | Core domain knowledge |
| `projects/` | Time-bound project work |
| `decisions/` | Architecture Decision Records |
| `topics/` | Cross-cutting themes |
-->

## Naming Conventions

- **Concepts:** `kebab-case.md` (e.g., `sensor-fusion.md`)
- **Dated documents:** `YYYY-MM-DD-kebab-case.md` (e.g., `2026-01-15-kickoff.md`)
- **Decisions:** `NNN-kebab-case.md` (e.g., `001-tech-selection.md`)
- **Folders:** `kebab-case/`

## Folder Navigation

Each main folder should have an `_index.md` with:
- What this folder contains
- Current status/overview
- Key documents listed

## Language

- All content: English
- Code comments: English

## Cross-References

- Use relative markdown links: `[Title](../path/to/file.md)`
- Prefer `related:` frontmatter field for machine-readable links
- Never duplicate content — link instead

## Obsolescence

- Never delete documents, set `status: obsolete` or `status: superseded`
- Set `superseded_by: new-file.md` when replacing
- AI filters out obsolete/superseded by default

## Git Workflow

- Conventional Commits: `type(scope): description`
- Commit after every logical unit of work
- Main branch for regular work, branches for experiments

If [dotclaude](https://github.com/pasrom/dotclaude) is installed, the `git-workflow` skill enforces these rules automatically — no manual commit prompts needed.
