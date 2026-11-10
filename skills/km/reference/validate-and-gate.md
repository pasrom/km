# km reference: Lint, gate, promote and index completeness

## Contents

- Lint (`/km lint`)
  - Scope
  - Checks
  - Output format
- Gate — optional serving-lint (opt-in)
  - Promote (`km promote`)
- Index completeness (opt-in)

## Lint (`/km lint`)

Periodic health check for knowledge base consistency. Run all checks and report findings grouped by severity.

### Scope

Collect only **git-tracked** `.md` files via `git ls-files -z '*.md'`. Exclude files exempt from frontmatter per CONVENTIONS.md, plus `_index.md` files, `brains/`, and all shared resource submodules (they have their own conventions).

**Prefer the machine-readable validator.** In a repo with a `CONVENTIONS.md` from km (or a `schema.local.yaml`), run `km validate` and use its output verbatim as the 🔴 Errors section — it is deterministic, merges `schema.local.yaml` over km's base schema, and also catches non-`/km` writers. The prose checks below are the **fallback** for repos km does not validate, and still supply the 🟡 Warnings / 🔵 Suggestions the validator does not cover.

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
- A tracked doc whose path a clone on Windows cannot check out: a file or folder name with `< > : " / \ | ? *` or a control character, a device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, with any extension), or a trailing dot or space. `km validate` reports it as `portable-name`, a WARNING (gate on or off), never an error; rename it with `git mv`.

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

An **advisory** extension of `km validate` for brains whose content is read by a wider audience or an AI/RAG layer. Off by default (existing brains unaffected, bit-identical). It catches honest mistakes before commit; it is **not** an enforcement boundary (a determined author can flip a field or disable it — the real boundary is the publish/release step).

Enable in `schema.local.yaml` (the repo's own overlay):

```yaml
gate:
  enabled: true
  served_status: accepted          # which status counts as "served/shared"
  customer_audience: customer      # audience value that must not name other customers
  forbidden_terms_file: .gate-terms.txt   # gitignored: keep real customer names out of the repo
  email_allowlist: [your-domain.com]
  # forbidden_terms: [ACME]        # or inline (test/demo only)
  # term_scan_prefixes: [bms, products]   # also term-scan these folders' docs, whatever their audience
  # project_prefix: projects/      # its subfolder names are project codes; flag them outside their folder
  # project_code_pattern: 'p[0-9]+' # only subfolders fully matching this count as codes
```

Checks, keyed per concern (so an internal `accepted` doc may legitimately name a customer):
- **secret** (ERROR) — AWS/GitHub keys, private-key headers in ANY tracked doc (incl. exempt/reserved files like README/_index; excl. skip_prefixes) — a key needs no frontmatter.
- **leak** (ERROR) — forbidden terms + external emails only in an `audience: customer` doc. `term_scan_prefixes` term-scans every doc under those folders too, and with `project_prefix` a project code (a tracked subfolder name) outside its own folder is an error; files directly in the project folder, such as its `_index.md`, may list every code. Both run over any tracked doc, `_index.md` and README included, frontmatter too (a `project:` value or a `related:` path naming a project folder counts), and the code check needs no terms file, so it also runs in CI where that file is absent.
- **bergab** (ERROR) — a served doc links to an unfinished (`draft`/`review`) doc. A link to an `obsolete` doc is a WARNING (`gate-bergab-old`), and so is one to a `superseded` doc unless its `superseded_by` chain reaches the linking doc or a doc it also links (body or `related:`): a successor may link what it replaced, a history page that links the old and the new is quiet. The warning names the first served successor on the chain; link it instead or as well. One finding per linked doc. Reuses the `status`/`audience` frontmatter, no new fields.
- **freshness** (WARNING) — a served doc past its `review_by`.
- **approval-stale** (ERROR; a WARNING with the gate off): a served doc whose body or content fields changed since `km approve` recorded `approved_digest`; send it back to review in the same commit (`km demote <doc>`) and approve it in a commit of its own, or revert the change.
- **signoff** (ERROR, gate on or off, only with `km validate --signoff-since <base>`, which km's team `ci.yml` passes on a pull request): a doc the branch adds or changes since its merge base with `<base>` that is not signed off. Retired passes, and served with an `approved_by` whose approval covers the content (one the PR changed after it is sent back with `km demote`); at level `human` a `review` doc with `reviewed_by` may wait for the person; anything else fails, a `draft` too. A doc whose status and approved content match the merge base is skipped, so a ripple edit asks for no sign-off. `km upgrade` turns it on in a `ci.yml` km wrote; docs already on main fail only once a pull request changes their content.

Findings are redacted. The link scan strips code fences; the secret/leak scans see the whole document (stricter, so a forbidden term inside a code sample still fails). A configured-but-missing `forbidden_terms_file` is a WARNING, not silent. Malformed OR unknown `gate:` config fails fast.

### Promote (`km promote`)

`km promote <slug> <source> --folder DIR [--type T] [--title T] [--author A] [--owner O] [--audience A] [--ticket KEY] [--replace] [--stub-source]` moves a note into the brain as a `status: review` doc, **dedups by slug** (updates the existing topic doc, never a duplicate), gates the candidate **before** placing it (a failing promote writes nothing), and prints a pointer to paste back into personal scratch instead of a copy. The source's own frontmatter is **carried forward** (`type`/`title`/`author`/`tags`/…) and its `status`/approval/ supersede fields are dropped and re-stamped, so a source that already has frontmatter never yields a double header; `--type`/`--title`/`--author` override it. A **new** doc needs `--folder` (no default) and a resolvable `type`+`author`. Author resolves `--author` > source frontmatter > `author_default` (a repo-local default in `schema.local.yaml`). **Cross-repo** (the source lives outside this repo, e.g. promoting from a personal brain into a team brain): `--author` is required (the target's `author_default` would mis-attribute the source's author), `related`/`sources`/`translates`/`project` are dropped (they point at the source repo) and any body link into the source repo is refused; `--ticket KEY` (optional, any key, need not be a Jira ticket) stamps the `ticket` field. `--replace` overwrites an existing served doc and **invalidates its approval** (`status: review`, `approved_*` dropped), but a `verbatim-block` is **never** `--replace`d (change it only via supersede); slug collisions across folders are a hard stop. `--stub-source` rewrites an in-repo source note into a superseded redirect stub pointing at the promoted doc (a source in another repo is left untouched), so the knowledge lives once, not twice.

The slug and every `--folder` part must be names a clone on Windows can check out, the rule `portable-name` checks: `km promote` refuses any other (exit 2) and writes nothing.

Known limitations (advisory scope, follow-ups): whole-repo mode sees TRACKED files only; per-file mode does not check reverse edges (a target flipping to `draft` is caught only in a full run); link-form coverage is inline/reference/wiki/HTML/angle-bracket (not exhaustive).

## Index completeness (opt-in)

Set `check_index: true` at the top of `schema.local.yaml` to have `km validate` lint each folder's `_index.md` deterministically (WARNINGS, non-fatal): every folder with **content docs**, or with a subfolder that has an `_index.md`, must have an `_index.md` (`index-missing`), each `_index.md` must link every content doc in its own folder and the `_index.md` of each direct subfolder (`index-incomplete`), and no `_index.md` may link a missing file (`index-dead-link`, scanned on every `_index.md`, including navigation hubs with no direct docs). "Content docs" excludes `_index.md`, exempt files (README/CLAUDE/CONVENTIONS/SKILL), and reserved files (index.md/log.md) — the same notion `is_validatable()` uses.

Linking each subfolder's index makes every folder reachable from the one above it; the root `_index.md` is optional, and where it exists it must link the top-level folders that have an index. Link targets resolve against the git-tracked file set (clone-stable, case-exact; a link into a `skip_prefixes` folder is therefore not dead) — document-relative first, then repo-root. To leave a folder out of the index lint *without* dropping it from article validation, list it under `index_skip_prefixes` in `schema.local.yaml` (e.g. generated or vendored trees).

Whole-repo only: skipped on per-file (pre-commit) runs. Off by default (a non-bool `check_index` is a config error). This machine-enforces the `/km lint` "`_index` doesn't link all docs" rule; `_index.md` files stay excluded from article-schema validation. Known limitations (by design): a dead `[[wiki]]` slug is not reported as `index-dead-link` (flagging bare-word targets would risk false positives), and unusual inline-link syntaxes (a parenthetical title, a query string, an angle-bracketed path combined with a title) may be misparsed by the shared markdown-link scanner.
