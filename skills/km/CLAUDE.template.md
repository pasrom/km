# CLAUDE.md

## About This Repository

<!-- Describe what this knowledge base is for and who uses it -->

## How to Contribute

Knowledge management via the `/km` skill (requires [dotclaude](https://github.com/pasrom/dotclaude)).
Install once with `./install.sh`, then use natural language or explicit commands:

- **Save:** "save this", "save this as a decision", `/km save ...`
- **Query:** "what do we know about X", `/km what is X`
- **Update:** "update the X document", `/km update ...`
- **Brain search:** prefix with `@<name>` or `@all` to include peer brains
- **Brain management:** `/km brain add <url>`, `/km brain list`, `/km brain remove <name>`

See [CONVENTIONS.md](CONVENTIONS.md) for document structure, frontmatter schema, and naming rules.

## Repository Conventions

- Every markdown file must have YAML frontmatter (`title`, `type`, `date`, `author`, `status`, `tags`)
- Use your initials as `author` (e.g., `<initials>`)
- Use `inbox/` for unsorted content
- One idea per file — never duplicate, link instead
- Never delete documents — set `status: obsolete` or `status: superseded`

## Git Workflow

Conventional Commits format: `type(scope): description`. Commit after every logical unit of work.

## Language

- All content: English
- Code comments: English
