---
name: km
description: Unified knowledge management skill. Handles everything — query, save, update, search across brains, manage brains, create decisions, process transcripts, and more. Just describe what you need in natural language.
argument-hint: anything — question, content to save, brain command, etc.
---

# Skill: km

Handle the following knowledge management request: $ARGUMENTS

## Prerequisites

- Verify this is a Git repo with a `CONVENTIONS.md` in the root. If not, offer to run the init workflow (see Init section below).
- Read `CONVENTIONS.md` to understand the repo structure, frontmatter schema, and folder layout.

## Intent detection

Analyze `$ARGUMENTS` to determine the action. Use these heuristics:

| Intent | Trigger patterns | Action |
|--------|-----------------|--------|
| **Query** | Starts with `@brain`, question words (what, how, why, where, when, which), "status of", "what do we know" | → Search |
| **Ingest** | "save this", "remember", "file this", raw content without a question, pasted text/mail/note | → Save |
| **Decision** | "we decided", "decision:", "ADR", contains rationale + alternatives | → Decision Record |
| **Update** | "update", "change", "modify", references an existing file | → Update |
| **Transcript** | Meeting notes, speaker names with timestamps, "transcript" | → Transcript |
| **Archive** | "archive", "obsolete", "supersede", "deprecate" | → Archive |
| **Sort inbox** | "sort inbox", "clean inbox", "organize inbox" | → Sort |
| **Review** | "review", "submit for review", references a file + PR/MR | → Review |
| **Summary** | "summary", "what changed", "weekly", "changelog" | → Weekly Summary |
| **Brain** | "brain add", "brain list", "brain remove", starts with "brain " | → Brain Management |
| **Init** | "init", "initialize", "bootstrap", "setup" | → Init |
| **Help** | "help", "what can you do", "skills", "commands" | → Help |

If ambiguous, ask the user to clarify.

## Action: Search (Query)

### Argument parsing for brains

Parse for `@` selectors at the beginning of the query:
- `@brain-name` → search only that brain in `brains/<name>/`
- `@all` → search all brains in `brains/` plus current repo
- Multiple: `@brain1 @brain2 query text`
- No `@` → search only the current repo

### Brain auto-update

For each target brain (skip if no `@` selectors):
1. Check freshness: `stat` the mtime of `.git/modules/brains/<name>/FETCH_HEAD`
2. If older than 15 minutes: `git submodule update --remote brains/<name>`
3. Fetch fails → use local state silently
4. Record commit hash: `git -C brains/<name> rev-parse --short HEAD`

### Search strategy (per target repo, in this order)

1. **Frontmatter scan:** Grep for relevant tags in YAML headers. Filter: `status: accepted` or `status: draft` (NOT `obsolete` or `superseded`, unless explicitly asked)
2. **Folder navigation:** Identify relevant folders per CONVENTIONS.md, read `_index.md` files
3. **Heading scan:** Scan H1/H2, only read files with matching headings in full
4. **Full-text search:** Only if above steps don't yield enough results
5. **Cross-references:** Follow `related:` and `supersedes:` fields

### Response format

- **Summary** (3-5 sentences)
- **Sources** with file paths. Brain sources: `[brain-name@abc1234] path/to/file.md`
- **Recency**, **Gaps**, **Related topics**

Scale response complexity to query complexity.

## Action: Save (Ingest)

1. Analyze content: determine type (note, concept, decision, transcript, artifact)
2. Generate YAML frontmatter per CONVENTIONS.md schema
3. Determine target folder per CONVENTIONS.md mapping. If unclear → `inbox/`
4. Filename: `YYYY-MM-DD-kebab-case.md` for notes/transcripts, `kebab-case.md` for concepts
5. Preserve raw content, only minimal formatting
6. Show proposed file path, type, and tags. Ask "Shall I save this?" before writing
7. Commit: `docs(<scope>): add <short description>`

## Action: Decision Record

1. Extract: title, context, decision, alternatives considered, consequences
2. Find next ADR number if repo uses numbered decisions
3. Generate frontmatter with `type: decision`
4. Write to decisions folder per CONVENTIONS.md
5. Ask for confirmation before writing
6. Commit: `docs(<scope>): ADR — <title>`

## Action: Update

1. Parse which document and what changes
2. Read the target file, verify it exists
3. Apply changes, preserve frontmatter, update `date` field
4. Show diff and ask for confirmation
5. Commit: `docs(<scope>): update <document>`

## Action: Transcript

1. Parse speaker names, timestamps, content
2. Extract: decisions, action items, key topics
3. Generate structured markdown with sections: Attendees, Summary, Decisions, Action Items, Full Transcript
4. Save as `YYYY-MM-DD-<topic>.md` in transcripts/meetings folder
5. Commit: `docs(<scope>): add transcript — <topic>`

## Action: Archive

1. Parse which document and reason (obsolete or superseded)
2. Read the file, update `status` in frontmatter to `obsolete` or `superseded`
3. If superseded: add `superseded_by:` field pointing to the new document
4. Ask for confirmation
5. Commit: `docs(<scope>): archive <document>`

## Action: Sort Inbox

1. List all files in `inbox/`
2. For each file: read content, determine best target folder per CONVENTIONS.md
3. Show proposed moves as a table
4. Ask for confirmation before moving
5. Commit: `docs: sort inbox files`

## Action: Review

1. Parse which document to submit for review
2. Create a branch: `review/<document-name>`
3. Push and create PR/MR with the document as the focus
4. Report back with PR/MR link

## Action: Weekly Summary

1. Parse time range (default: last 7 days)
2. Run `git log --since=<date> --name-status` to find changed files
3. Group changes by folder/topic
4. Summarize: new documents, updated documents, archived documents
5. Report as structured summary

## Action: Brain Management

Parse subcommand after "brain":

**brain add `<git-url>` [name]:**
1. `mkdir -p brains/`, `git submodule add <url> brains/<name>`
2. Validate: `brains/<name>/CONVENTIONS.md` must exist, else remove and error
3. `git config submodule.recurse true`
4. Commit: `feat(brains): add <name>`

**brain list:**
1. List `brains/*/` with CONVENTIONS.md → table with name, URL, commit, last updated
2. No brains → suggest `/km brain add`

**brain remove `<name>`:**
1. Confirm with user
2. `git submodule deinit -f brains/<name>` + `git rm -f brains/<name>`
3. Commit: `feat(brains): remove <name>`

## Action: Init

1. Verify this is a Git repo, check if CONVENTIONS.md exists
2. Ask: description, topic areas, default author, language, projects folder?
3. Create folder structure with `_index.md` files
4. Generate CONVENTIONS.md
5. Commit: `feat: initialize knowledge management structure`

## Action: Help

Show this overview:

| Command | What it does | Example |
|---------|-------------|---------|
| `/km <question>` | Search knowledge | `/km What do we know about thermal management?` |
| `/km @brain <question>` | Search a linked brain | `/km @mko PROFINET stack options` |
| `/km @all <question>` | Search all brains | `/km @all Zephyr RTOS` |
| `/km <content>` | Save content | `/km We decided to use LTC6813 for cell monitoring` |
| `/km update <file> ...` | Modify a document | `/km update sensor-fusion: add calibration values` |
| `/km archive <file>` | Mark as obsolete/superseded | `/km archive old-concept.md` |
| `/km brain add <url>` | Link another brain | `/km brain add https://gitlab.com/org/team-brain.git` |
| `/km brain list` | Show linked brains | `/km brain list` |
| `/km brain remove <name>` | Unlink a brain | `/km brain remove team-brain` |
| `/km sort inbox` | Organize inbox files | `/km sort inbox` |
| `/km summary` | Weekly changelog | `/km summary` or `/km summary last 2 weeks` |
| `/km init` | Bootstrap a new knowledge repo | `/km init` |
| `/km help` | Show this overview | `/km help` |

**Tip:** You don't need exact commands — just describe what you need naturally. "Save this", "what changed last week?", "update the BMS concept" all work.

## Rules

- Respond in the language the user used
- Always cite source files in queries
- Never delete documents — use status: obsolete or superseded
- Always ask for confirmation before writing or modifying files
- Commit with Conventional Commits format
- Brain sources always include `[brain-name@commit]` attribution
- If contradictions exist: prefer current repo over brains, prefer newer info, mention the contradiction
- If nothing found: say so honestly, do not hallucinate
