# CONVENTIONS.md

This file defines the rules every AI assistant must follow when working with this repository.

## Frontmatter Schema

The machine-readable schema is [`schema.base.yaml`](schema.base.yaml) — a strict profile of the
[Open Knowledge Format (OKF) v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf),
owned by `/km` and refreshed via `/km upgrade`. Repo-specific scope lives in
[`schema.local.yaml`](schema.local.yaml), merged over the base at runtime. Both are enforced by
[`scripts/validate.py`](scripts/validate.py) (run manually, in CI, or via the pre-commit hook).
The block below is the human summary; `schema.base.yaml` + `schema.local.yaml` are authoritative.

Every markdown file (except CLAUDE.md, README.md, CONVENTIONS.md, and SKILL.md files) must have YAML frontmatter:

```yaml
---
type: <note|concept|decision|transcript|artifact|summary|reference|verbatim-block>  # required (OKF)
title: "Descriptive title"                          # required
timestamp: 2026-01-15T09:00:00Z                     # required (OKF); legacy `date: YYYY-MM-DD` still accepted
author: <initials>                                  # required
status: <draft|review|accepted|superseded|obsolete> # required
tags: [tag1, tag2, tag3]                             # required
# Optional (OKF base):
description: "One-sentence summary."
resource: "https://…"                               # URI of the underlying asset (datasheet / repo / API)
# Optional (governance):
owner: <name>                                       # responsible for keeping the fact true
review_by: 2027-01-15                               # review-by date
project: <project-name>
supersedes: <path.md>
superseded_by: <path.md>
related: [path1.md, path2.md]
participants: [name1, name2]
sources: [path.md@abc1234]                          # provenance pinning (recommended for type: summary)
language: <en|de>
translates: <path.md@abc1234>                       # linked translation source
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
| `summary` | AI-generated summaries | Auto-generated with pinned `sources:` |
| `reference` | Reference material, lookups, how-tos, manuals | Structured per content |
| `verbatim-block` | Approved prose reused **verbatim** in customer materials | Verbatim; change only via supersede |

## Status Lifecycle

```
draft → review → accepted → superseded | obsolete
```

- `draft`: Work in progress
- `review`: Submitted for review, not yet approved
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

## Audience

Documents have different audiences. Set the optional `audience:` field to `customer` for
customer-shippable content; omit it (or set `internal`) otherwise. AI assistants can apply
stricter rules to `audience: customer` documents (e.g. no internal identifiers, no build-system
specifics) — define the exact rules for this repository here if needed.

## Cross-References

- Use relative markdown links: `[Title](../path/to/file.md)`
- `related:`, `supersedes:`, `superseded_by:` frontmatter fields use **repo-root-relative** paths
  (e.g., `concepts/foo.md`), not paths relative to the linking file
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
